package features

import "core:math"
import "core:mem"

import contracts "../contracts"
import polygon "../polygon"
import slicing "../slicing"

Brim_Type :: enum u8 {
	Default,         // legacy: outer if brim_width_um > 0, plus inner if brim_inner
	None,
	Outer_Only,
	Inner_Only,
	Outer_And_Inner,
}

Adhesion_Config :: struct {
	skirt_loops:                   u32,
	skirt_distance_um:             contracts.Micrometres,
	skirt_height_layers:           u32,
	min_skirt_length_um:           contracts.Micrometres,
	draft_shield:                  bool,
	brim_type:                     Brim_Type,
	brim_width_um:                 contracts.Micrometres,
	brim_gap_um:                   contracts.Micrometres,
	brim_inner:                    bool,
	raft_layers:                   u32,
	raft_expansion_um:             contracts.Micrometres,
	elephant_foot_compensation_um: contracts.Micrometres,
	line_width_um:                 contracts.Micrometres,
	bed_min_x:                     contracts.Micrometres,
	bed_max_x:                     contracts.Micrometres,
	bed_min_y:                     contracts.Micrometres,
	bed_max_y:                     contracts.Micrometres,
}

Adhesion_Loop :: struct {
	layer_index: u32,
	is_brim:     bool,
	points:      []polygon.Polygon_Point,
	line_widths: []contracts.Micrometres,
}

Adhesion_Raft_Path :: struct {
	layer_index:  u32,
	is_interface: bool,
	points:       []polygon.Polygon_Point,
	line_widths:  []contracts.Micrometres,
}

Adhesion_Result :: struct {
	loops:      []Adhesion_Loop,
	raft_paths: []Adhesion_Raft_Path,
}

adhesion_result_destroy :: proc(result: ^Adhesion_Result, allocator := context.allocator) {
	for loop in result.loops {
		delete(loop.points, allocator)
		delete(loop.line_widths, allocator)
	}
	delete(result.loops, allocator)
	for rp in result.raft_paths {
		delete(rp.points, allocator)
		delete(rp.line_widths, allocator)
	}
	delete(result.raft_paths, allocator)
	result^ = {}
}

// Generates skirt and/or outer+inner brim loops from layer-0 regions, clipped to bed bounds.
adhesion_build :: proc(
	provider: polygon.Polygon_Provider,
	topology: slicing.Topology_Result,
	regions: slicing.Region_Result,
	config: Adhesion_Config,
	allocator := context.allocator,
	support_footprint: polygon.Polygon_Set = {}, // first-layer support area that the skirt also surrounds
) -> Adhesion_Result {
	if provider.offset == nil || len(regions.layers) == 0 || i64(config.line_width_um) <= 0 {
		return {}
	}
	// Find first layer with model geometry (layer 0 normally, or first model layer above raft).
	base_layer_idx := -1
	for layer, li in regions.layers {
		if layer.region_count > 0 {
			base_layer_idx = li
			break
		}
	}
	if base_layer_idx < 0 {
		return {}
	}
	lw := i64(config.line_width_um)
	loops := make([dynamic]Adhesion_Loop, 0, 16, allocator)
	raft_paths := make([dynamic]Adhesion_Raft_Path, 0, 64, allocator)

	// Extract base layer outer footprint as a valid Polygon_Set.
	outer_set := adhesion_extract_layer_set(topology, regions, u32(base_layer_idx), false, allocator)
	defer polygon.polygon_set_destroy(&outer_set, allocator)
	if len(outer_set.paths) == 0 {
		delete(loops)
		delete(raft_paths)
		return {}
	}

	// 0. Optional Raft layers (0 ..< raft_layers) below the model.
	if config.raft_layers > 0 {
		raft_exp := config.raft_expansion_um if i64(config.raft_expansion_um) > 0 else contracts.Micrometres(2_000)
		raft_pad, pad_err := provider.offset(outer_set, raft_exp, .Round, 2.0, 25.0, polygon.DEFAULT_POLYGON_LIMITS, allocator)
		defer polygon.polygon_set_destroy(&raft_pad, allocator)
		if pad_err == .None && len(raft_pad.paths) > 0 {
			min_x, min_y, max_x, max_y := infill_pat_bounds(raft_pad)
			if max_x > min_x && max_y > min_y {
				n_raft := min(config.raft_layers, u32(len(regions.layers)))
				for rli in 0..<n_raft {
					is_iface := rli == n_raft - 1
					spacing := f64(lw) if is_iface else f64(lw) * 2.0
					ang := 0.0 if (rli % 2 == 0) else math.PI * 0.5
					tmp := make([dynamic]Infill_Pattern_Path, 0, 32, context.temp_allocator)
					infill_pat_hatch(&tmp, raft_pad, rli, min_x, min_y, max_x, max_y, ang, spacing, 0.0, config.line_width_um, allocator)
					for tp in tmp {
						append(&raft_paths, Adhesion_Raft_Path{
							layer_index  = tp.layer_index,
							is_interface = is_iface,
							points       = tp.points,
							line_widths  = tp.line_widths,
						})
					}
				}
			}
		}
	}

	// 1. Skirt loops (outermost-to-innermost, up to skirt_height_layers; draft_shield spans all layers).
	eff_skirt_loops := config.skirt_loops
	if config.draft_shield && eff_skirt_loops == 0 {
		eff_skirt_loops = 1
	}
	if eff_skirt_loops > 0 {
		skirt_layers := config.skirt_height_layers
		if skirt_layers == 0 {skirt_layers = 1}
		if config.draft_shield {
			skirt_layers = u32(len(regions.layers))
		}
		if skirt_layers > u32(len(regions.layers)) {
			skirt_layers = u32(len(regions.layers))
		}
		// The skirt surrounds the model and the first-layer supports; the brim stays on the model.
		skirt_set := outer_set
		owned_skirt_set: polygon.Polygon_Set
		defer polygon.polygon_set_destroy(&owned_skirt_set, allocator)
		if len(support_footprint.paths) > 0 && provider.boolean != nil {
			union_set, union_err := provider.boolean(
				outer_set,
				support_footprint,
				.Union,
				.Non_Zero,
				polygon.DEFAULT_POLYGON_LIMITS,
				allocator,
			)
			if union_err == .None && len(union_set.paths) > 0 {
				// Keep only outer boundaries: holes enclosed between the model and supports would
				// otherwise get skirt loops of their own.
				kept := 0
				for path in union_set.paths {
					ring := union_set.points[path.offset:path.offset+path.count]
					if polygon.polygon_path_area_2(ring) > 0 {
						union_set.paths[kept] = path
						kept += 1
					}
				}
				if kept > 0 {
					union_set.paths = union_set.paths[:kept]
					owned_skirt_set = union_set
					skirt_set = owned_skirt_set
				} else {
					polygon.polygon_set_destroy(&union_set, allocator)
				}
			} else {
				polygon.polygon_set_destroy(&union_set, allocator)
			}
		}
		base_dist := i64(config.skirt_distance_um)
		if i64(config.brim_width_um) > 0 && config.brim_type != .None {
			base_dist = max(base_dist, i64(config.brim_width_um) + i64(config.brim_gap_um) + lw)
		}
		// Auto-increase layer-0 skirt loops to satisfy min_skirt_length_um.
		layer0_skirt_loops := eff_skirt_loops
		probe_k0: polygon.Polygon_Set
		has_probe_k0 := false
		defer if has_probe_k0 {polygon.polygon_set_destroy(&probe_k0, allocator)}
		if i64(config.min_skirt_length_um) > 0 {
			probe_off := contracts.Micrometres(base_dist + lw/2)
			probe, perr := provider.offset(skirt_set, probe_off, .Round, 2.0, 25.0, polygon.DEFAULT_POLYGON_LIMITS, allocator)
			if perr == .None && len(probe.paths) > 0 {
				outer_kept := 0
				loop_len := 0.0
				for pp in probe.paths {
					ring := probe.points[pp.offset:pp.offset+pp.count]
					if polygon.polygon_path_area_2(ring) <= 0 {continue}
					probe.paths[outer_kept] = pp
					outer_kept += 1
					for pi in 0..<len(ring) {
						pa := ring[pi]
						pb := ring[(pi+1)%len(ring)]
						loop_len += math.hypot(f64(i64(pb.x)-i64(pa.x)), f64(i64(pb.y)-i64(pa.y)))
					}
				}
				probe.paths = probe.paths[:outer_kept]
				probe_k0 = probe
				has_probe_k0 = true
				if loop_len > 1.0 {
					needed := u32(math.ceil(f64(i64(config.min_skirt_length_um)) / loop_len))
					layer0_skirt_loops = min(u32(32), max(layer0_skirt_loops, needed))
				}
			} else {
				polygon.polygon_set_destroy(&probe, allocator)
			}
		}
		max_k := int(max(layer0_skirt_loops, eff_skirt_loops))
		cached_skirts := make([]polygon.Polygon_Set, max_k, allocator)
		defer {
			for &cs in cached_skirts {polygon.polygon_set_destroy(&cs, allocator)}
			delete(cached_skirts, allocator)
		}
		for k in 0..<max_k {
			if k == 0 && has_probe_k0 {
				cached_skirts[0] = probe_k0
				probe_k0 = {}
				has_probe_k0 = false
				continue
			}
			offset_um := contracts.Micrometres(base_dist + i64(k)*lw + lw/2)
			expanded, err := provider.offset(
				skirt_set,
				offset_um,
				.Round,
				2.0,
				25.0,
				polygon.DEFAULT_POLYGON_LIMITS,
				allocator,
			)
			if err != .None {
				polygon.polygon_set_destroy(&expanded, allocator)
				continue
			}
			outer_kept := 0
			for path in expanded.paths {
				if polygon.polygon_path_area_2(expanded.points[path.offset:path.offset+path.count]) > 0 {
					expanded.paths[outer_kept] = path
					outer_kept += 1
				}
			}
			expanded.paths = expanded.paths[:outer_kept]
			cached_skirts[k] = expanded
		}
		for li in 0..<skirt_layers {
			n_loops := layer0_skirt_loops if li == 0 else eff_skirt_loops
			for k := int(n_loops) - 1; k >= 0; k -= 1 {
				if len(cached_skirts[k].paths) == 0 {continue}
				adhesion_append_loops(&loops, cached_skirts[k], li, false, config, allocator)
			}
		}
	}

	// 2. Outer and/or Inner Brim loops on layer 0 (skipped when raft is active or brim_type == .None).
	want_outer_brim := i64(config.brim_width_um) > 0 && config.raft_layers == 0 &&
		(config.brim_type == .Default || config.brim_type == .Outer_Only || config.brim_type == .Outer_And_Inner)
	want_inner_brim := i64(config.brim_width_um) > 0 && config.raft_layers == 0 &&
		((config.brim_type == .Default && config.brim_inner) || config.brim_type == .Inner_Only || config.brim_type == .Outer_And_Inner)
	if want_outer_brim || want_inner_brim {
		brim_count := int((i64(config.brim_width_um) + lw - 1) / lw)
		if brim_count > 64 {brim_count = 64}
		if want_outer_brim {
			adhesion_append_brim(&loops, provider, outer_set, config, brim_count, false, allocator)
		}
		if want_inner_brim {
			hole_set := adhesion_extract_layer_set(topology, regions, u32(base_layer_idx), true, allocator)
			defer polygon.polygon_set_destroy(&hole_set, allocator)
			adhesion_append_brim(&loops, provider, hole_set, config, brim_count, true, allocator)
		}
	}

	return Adhesion_Result{loops = loops[:], raft_paths = raft_paths[:]}
}

@(private = "file")
adhesion_append_brim :: proc(
	loops: ^[dynamic]Adhesion_Loop,
	provider: polygon.Polygon_Provider,
	boundary: polygon.Polygon_Set,
	config: Adhesion_Config,
	count: int,
	inner: bool,
	allocator: mem.Allocator,
) {
	if len(boundary.paths) == 0 {return}
	rings: [64]polygon.Polygon_Set
	assert(count > 0 && count <= len(rings))
	Brim_Job :: struct {
		provider: polygon.Polygon_Provider,
		boundary: polygon.Polygon_Set,
		rings: []polygon.Polygon_Set,
		first_distance, step: i64,
		allocator: mem.Allocator,
	}
	width := i64(config.line_width_um)
	sign := i64(-1) if inner else i64(1)
	job := Brim_Job{
		provider = provider,
		boundary = boundary,
		rings = rings[:count],
		first_distance = sign * (i64(config.brim_gap_um) + width/2),
		step = sign * width,
		allocator = allocator,
	}
	parallel_for(count, &job, proc(c: ^Brim_Job, i: int) {
		distance := contracts.Micrometres(c.first_distance + i64(i)*c.step)
		ring, err := c.provider.offset(
			c.boundary, distance, .Round, 2.0, 25.0, polygon.DEFAULT_POLYGON_LIMITS, c.allocator,
		)
		if err == .None {
			c.rings[i] = ring
		} else {
			polygon.polygon_set_destroy(&ring, c.allocator)
		}
	})
	defer for &ring in rings[:count] {
		polygon.polygon_set_destroy(&ring, allocator)
	}
	for i in 0..<count {
		index := i if inner else count-1-i
		if inner && len(rings[index].paths) == 0 {break}
		adhesion_append_loops(loops, rings[index], 0, true, config, allocator)
	}
}

@(private)
adhesion_extract_layer_set :: proc(
	topology: slicing.Topology_Result,
	regions: slicing.Region_Result,
	layer_index: u32,
	extract_holes: bool,
	allocator := context.allocator,
) -> polygon.Polygon_Set {
	layer0 := regions.layers[layer_index]
	points := make([dynamic]polygon.Polygon_Point, 0, 256, allocator)
	paths := make([dynamic]polygon.Polygon_Path, 0, 16, allocator)

	reg_start := int(layer0.region_offset)
	reg_end := reg_start + int(layer0.region_count)
	for ri in reg_start..<reg_end {
		reg := regions.regions[ri]
		c_start := int(reg.contour_offset)
		c_end := c_start + int(reg.contour_count)
		for ci, local_ci in regions.region_contour_indices[c_start:c_end] {
			is_hole := local_ci > 0
			if is_hole != extract_holes {continue}
			contour := regions.contours[ci]
			path := topology.paths[contour.path_index]
			v_count := int(path.vertex_count)
			if v_count < 3 {continue}
			// Reverse hole orientation (xor with contour.reverse_path) so negative offset shrinks inward into the hole.
			reverse := contour.reverse_path != extract_holes
			offset := u64(len(points))
			added := 0
			for idx in 0..<v_count {
				src_idx := v_count - 1 - idx if reverse else idx
				pt2 := slicing.region_path_point(topology, path, src_idx)
				pt := polygon.Polygon_Point{x = pt2.x, y = pt2.y}
				if added > 0 && points[len(points)-1] == pt {continue}
				append(&points, pt)
				added += 1
			}
			for added > 1 && points[len(points)-1] == points[int(offset)] {
				pop(&points)
				added -= 1
			}
			if added < 3 {
				resize(&points, int(offset))
				continue
			}
			append(&paths, polygon.Polygon_Path{offset = offset, count = u64(added)})
		}
	}
	if len(paths) == 0 {
		delete(points)
		delete(paths)
		return {}
	}
	return polygon.Polygon_Set{points = points[:], paths = paths[:]}
}

@(private)
adhesion_append_loops :: proc(
	out: ^[dynamic]Adhesion_Loop,
	set: polygon.Polygon_Set,
	layer_index: u32,
	is_brim: bool,
	config: Adhesion_Config,
	allocator := context.allocator,
) {
	for path in set.paths {
		if path.count < 3 {continue}
		start := int(path.offset)
		end := start + int(path.count)
		if end > len(set.points) {continue}
		in_bounds := true
		for pt in set.points[start:end] {
			if i64(pt.x) < i64(config.bed_min_x) || i64(pt.x) > i64(config.bed_max_x) ||
			   i64(pt.y) < i64(config.bed_min_y) || i64(pt.y) > i64(config.bed_max_y) {
				in_bounds = false
				break
			}
		}
		if !in_bounds {continue}
		pts := make([dynamic]polygon.Polygon_Point, 0, int(path.count), allocator)
		for pt in set.points[start:end] {
			if len(pts) == 0 || pts[len(pts)-1] != pt {
				append(&pts, pt)
			}
		}
		for len(pts) > 1 && pts[len(pts)-1] == pts[0] {
			pop(&pts)
		}
		if len(pts) < 3 {
			delete(pts)
			continue
		}
		widths := make([]contracts.Micrometres, len(pts), allocator)
		for wi in 0..<len(pts) {
			widths[wi] = config.line_width_um
		}
		append(out, Adhesion_Loop{
			layer_index = layer_index,
			is_brim     = is_brim,
			points      = pts[:],
			line_widths = widths,
		})
	}
}
