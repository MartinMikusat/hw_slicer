package features

import contracts "../contracts"
import polygon "../polygon"
import slicing "../slicing"

Adhesion_Config :: struct {
	skirt_loops:                   u32,
	skirt_distance_um:             contracts.Micrometres,
	skirt_height_layers:           u32,
	brim_width_um:                 contracts.Micrometres,
	brim_gap_um:                   contracts.Micrometres,
	brim_inner:                    bool,
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

Adhesion_Result :: struct {
	loops: []Adhesion_Loop,
}

adhesion_result_destroy :: proc(result: ^Adhesion_Result, allocator := context.allocator) {
	for loop in result.loops {
		delete(loop.points, allocator)
		delete(loop.line_widths, allocator)
	}
	delete(result.loops, allocator)
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
	layer0 := regions.layers[0]
	if layer0.region_count == 0 {
		return {}
	}
	lw := i64(config.line_width_um)
	loops := make([dynamic]Adhesion_Loop, 0, 16, allocator)

	// Extract layer-0 outer footprint and hole contours as valid Polygon_Sets.
	outer_set := adhesion_extract_layer0_set(topology, regions, false, allocator)
	defer polygon.polygon_set_destroy(&outer_set, allocator)
	if len(outer_set.paths) == 0 {
		delete(loops)
		return {}
	}

	// 1. Skirt loops (outermost-to-innermost, up to skirt_height_layers).
	if config.skirt_loops > 0 {
		skirt_layers := config.skirt_height_layers
		if skirt_layers == 0 {skirt_layers = 1}
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
		if i64(config.brim_width_um) > 0 {
			base_dist = max(base_dist, i64(config.brim_width_um) + i64(config.brim_gap_um) + lw)
		}
		for li in 0..<skirt_layers {
			for k := int(config.skirt_loops) - 1; k >= 0; k -= 1 {
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
				// A skirt is the outer boundary only: merging islands can leave holes in the offset.
				outer_kept := 0
				for path in expanded.paths {
					if polygon.polygon_path_area_2(expanded.points[path.offset:path.offset+path.count]) > 0 {
						expanded.paths[outer_kept] = path
						outer_kept += 1
					}
				}
				expanded.paths = expanded.paths[:outer_kept]
				adhesion_append_loops(&loops, expanded, li, false, config, allocator)
				polygon.polygon_set_destroy(&expanded, allocator)
			}
		}
	}

	// 2. Outer Brim loops on layer 0 (outermost-to-innermost).
	if i64(config.brim_width_um) > 0 {
		brim_count := int((i64(config.brim_width_um) + lw - 1) / lw)
		if brim_count > 64 {brim_count = 64}
		for k := brim_count - 1; k >= 0; k -= 1 {
			offset_um := contracts.Micrometres(i64(config.brim_gap_um) + i64(k)*lw + lw/2)
			expanded, err := provider.offset(
				outer_set,
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
			adhesion_append_loops(&loops, expanded, 0, true, config, allocator)
			polygon.polygon_set_destroy(&expanded, allocator)
		}

		// 3. Optional Inner Brim loops inside layer-0 holes.
		if config.brim_inner {
			hole_set := adhesion_extract_layer0_set(topology, regions, true, allocator)
			defer polygon.polygon_set_destroy(&hole_set, allocator)
			if len(hole_set.paths) > 0 {
				for k := 0; k < brim_count; k += 1 {
					offset_um := contracts.Micrometres(-(i64(config.brim_gap_um) + i64(k)*lw + lw/2))
					inset, err := provider.offset(
						hole_set,
						offset_um,
						.Round,
						2.0,
						25.0,
						polygon.DEFAULT_POLYGON_LIMITS,
						allocator,
					)
					if err != .None || len(inset.paths) == 0 {
						polygon.polygon_set_destroy(&inset, allocator)
						break
					}
					adhesion_append_loops(&loops, inset, 0, true, config, allocator)
					polygon.polygon_set_destroy(&inset, allocator)
				}
			}
		}
	}

	return Adhesion_Result{loops = loops[:]}
}

@(private)
adhesion_extract_layer0_set :: proc(
	topology: slicing.Topology_Result,
	regions: slicing.Region_Result,
	extract_holes: bool,
	allocator := context.allocator,
) -> polygon.Polygon_Set {
	layer0 := regions.layers[0]
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
