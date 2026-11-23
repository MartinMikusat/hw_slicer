package pipeline

import "core:fmt"
import "core:math"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:time"

import contracts "../contracts"
import features "../features"
import formats "../formats"
import gcode "../gcode"
import geometry "../geometry"
import polygon "../polygon"
import profiles "../profiles"
import repair "../repair"
import slicing "../slicing"

Stage_Trace :: struct {
	name:        string,
	duration_ms: f64,
	count_a:     u64,
	count_b:     u64,
}

Slice_Run_Options :: struct {
	source_units:                  contracts.Source_Units,
	infill_density_percent:        f64,
	enable_supports:               bool,
	inner_perimeters_first:        bool,
	max_layer_count:               u32,
	max_contour_repairs:           u32,
	center_on_bed:                 bool,
	// Milestone 2: Adhesion, seams, wipe, overhang cooling, EXCLUDE_OBJECT
	skirt_loops:                   u32,
	skirt_distance_um:             contracts.Micrometres,
	skirt_height_layers:           u32,
	brim_width_um:                 contracts.Micrometres,
	brim_gap_um:                   contracts.Micrometres,
	brim_inner:                    bool,
	elephant_foot_compensation_um: contracts.Micrometres,
	seam_strategy:                 features.Seam_Strategy,
	wipe_distance_um:              contracts.Micrometres,
	overhang_slowdown_enabled:     bool,
	overhang_speed_percent:        u32,
	object_name:                   string,
	// Milestone 3: Infill patterns, monotonic/ironing, G2/G3 arcs, variable walls
	infill_pattern:                features.Infill_Pattern,
	monotonic_skin:                bool,
	ironing_enabled:               bool,
	ironing_spacing_um:            contracts.Micrometres,
	ironing_flow_percent:          u32,
	arc_fitting_enabled:           bool,
	arc_tolerance_um:              f64,
	variable_walls_enabled:        bool,
	// Milestone 4: Tree supports & Adaptive layer height
	support_style_tree:            bool,
	adaptive_layers:               bool,
	// Milestone 5: Pure-Odin polygon engine toggle
	use_native_polygon:            bool,
	// Milestone 6: Metal GPU compute & CPU thread count
	use_gpu:                       bool,
	worker_threads:                int,
	// Phase 2 Workstream 3: Pro-tier slicer features
	scarf_seam_enabled:            bool,
	scarf_length_um:               contracts.Micrometres,
	vase_mode:                     bool,
	fuzzy_skin_enabled:            bool,
	fuzzy_thickness_um:            contracts.Micrometres,
	fuzzy_point_dist_um:           contracts.Micrometres,
	mesh_auto_repair:              bool,
	contour_simplify_tolerance_um: f64,
	modifiers:                     []Modifier_Zone,
	pause_layers:                  []u32,
	color_change_layers:           []u32,
}

DEFAULT_SLICE_RUN_OPTIONS :: Slice_Run_Options{
	source_units                  = .Millimetres,
	infill_density_percent        = 15.0,
	enable_supports               = false,
	inner_perimeters_first        = true,
	max_layer_count               = 10_000,
	max_contour_repairs           = 256,
	center_on_bed                 = true,
	skirt_loops                   = 1,
	skirt_distance_um             = 5_000,
	skirt_height_layers           = 1,
	brim_width_um                 = 0,
	brim_gap_um                   = 100,
	brim_inner                    = false,
	elephant_foot_compensation_um = 150,
	seam_strategy                 = .Aligned,
	wipe_distance_um              = 1_500,
	overhang_slowdown_enabled     = true,
	overhang_speed_percent        = 50,
	object_name                   = "",
	infill_pattern                = .Gyroid,
	monotonic_skin                = true,
	ironing_enabled               = false,
	ironing_spacing_um            = 150,
	ironing_flow_percent          = 15,
	arc_fitting_enabled           = true,
	arc_tolerance_um              = 20.0,
	variable_walls_enabled        = true,
	support_style_tree            = true,
	adaptive_layers               = false,
	use_native_polygon            = true,
	use_gpu                       = true,
	worker_threads                = 8,
	scarf_seam_enabled            = false,
	scarf_length_um               = 15_000,
	vase_mode                     = false,
	fuzzy_skin_enabled            = false,
	fuzzy_thickness_um            = 300,
	fuzzy_point_dist_um           = 800,
	mesh_auto_repair              = true,
	contour_simplify_tolerance_um = 12.0,
}

Slice_Run_Result :: struct {
	spine:             Slice_Spine_Result,
	repaired_topology: slicing.Topology_Result,
	has_repaired:      bool,
	contour_repairs:   u32,
	regions:           slicing.Region_Result,
	unified_plan:      features.Unified_Path_Plan_Result,
	extrusion:         features.Extrusion_Result,
	motion:            features.Motion_Plan_Result,
	klipper:           gcode.Klipper_Result,
	validation:        gcode.Klipper_Validation_Report,
	time_estimate:     features.Print_Time_Estimate,
	mesh_repair_stats: repair.Mesh_Repair_Stats,
	stages:            [dynamic]Stage_Trace,
	total_duration_ms: f64,
}

Slice_Run_Error :: struct {
	stage:  string,
	detail: string,
}

slice_run_result_destroy :: proc(r: ^Slice_Run_Result, allocator := context.allocator) {
	if r == nil {return}
	gcode.klipper_result_destroy(&r.klipper, allocator)
	features.motion_plan_result_destroy(&r.motion, allocator)
	features.extrusion_result_destroy(&r.extrusion, allocator)
	features.unified_path_plan_result_destroy(&r.unified_plan, allocator)
	slicing.region_result_destroy(&r.regions, allocator)
	if r.has_repaired {
		slicing.topology_result_destroy(&r.repaired_topology, allocator)
	}
	slice_spine_result_destroy(&r.spine, allocator)
	delete(r.stages)
	r^ = {}
}

@(private = "file")
center_decoded_on_bed :: proc(
	decoded: ^formats.Decoded_Mesh,
	printer: profiles.Printer_Profile,
) {
	if len(decoded.vertex_x) == 0 {return}
	min_x, max_x := decoded.vertex_x[0], decoded.vertex_x[0]
	min_y, max_y := decoded.vertex_y[0], decoded.vertex_y[0]
	min_z := decoded.vertex_z[0]
	for i in 1..<len(decoded.vertex_x) {
		x, y, z := decoded.vertex_x[i], decoded.vertex_y[i], decoded.vertex_z[i]
		if x < min_x {min_x = x}
		if x > max_x {max_x = x}
		if y < min_y {min_y = y}
		if y > max_y {max_y = y}
		if z < min_z {min_z = z}
	}
	bed_cx := f64(i64(printer.axis_minimum_x)+i64(printer.axis_maximum_x))*0.5/1000.0
	bed_cy := f64(i64(printer.axis_minimum_y)+i64(printer.axis_maximum_y))*0.5/1000.0
	dx := bed_cx-(min_x+max_x)*0.5
	dy := bed_cy-(min_y+max_y)*0.5
	dz := -min_z
	for i in 0..<len(decoded.vertex_x) {
		decoded.vertex_x[i] += dx
		decoded.vertex_y[i] += dy
		decoded.vertex_z[i] += dz
	}
}

@(private = "file")
record_stage :: proc(stages: ^[dynamic]Stage_Trace, name: string, start: time.Tick, a, b: u64) {
	ms := time.duration_seconds(time.tick_since(start))*1000.0
	append(stages, Stage_Trace{name = name, duration_ms = ms, count_a = a, count_b = b})
}

@(private = "file")
build_model_polygon_sets :: proc(
	topology: slicing.Topology_Result,
	regions: slicing.Region_Result,
	allocator: mem.Allocator,
) -> []polygon.Polygon_Set {
	layer_count := len(regions.layers)
	sets := make([]polygon.Polygon_Set, layer_count, allocator)
	for layer_idx in 0..<layer_count {
		rl := regions.layers[layer_idx]
		raw_paths := make([dynamic][]polygon.Polygon_Point, 0, int(rl.region_count)*2, context.temp_allocator)
		all_pts := make([dynamic]polygon.Polygon_Point, 0, int(rl.region_count)*16, context.temp_allocator)
		path_ranges := make([dynamic][2]int, 0, int(rl.region_count)*2, context.temp_allocator)
		for r_off in 0..<u64(rl.region_count) {
			reg := regions.regions[rl.region_offset+r_off]
			for c_off in 0..<u64(reg.contour_count) {
				c_idx := regions.region_contour_indices[reg.contour_offset+c_off]
				contour := regions.contours[c_idx]
				tp := topology.paths[contour.path_index]
				start := len(all_pts)
				for k in 0..<u64(tp.vertex_count) {
					v_idx := topology.path_vertex_indices[tp.vertex_offset+k]
					v := topology.vertices[v_idx]
					pt := polygon.Polygon_Point{x = v.point.x, y = v.point.y}
					if len(all_pts) > start && pt == all_pts[len(all_pts)-1] {continue}
					append(&all_pts, pt)
				}
				for len(all_pts)-start >= 2 && all_pts[start] == all_pts[len(all_pts)-1] {
					pop(&all_pts)
				}
				if len(all_pts)-start < 3 {
					resize(&all_pts, start)
					continue
				}
				ring := all_pts[start:]
				if polygon.polygon_path_area_2(ring) == 0 {
					resize(&all_pts, start)
					continue
				}
				rot := polygon.polygon_minimum_rotation(ring)
				if rot > 0 {slice.rotate_left(ring, rot)}
				append(&path_ranges, [2]int{start, len(all_pts)})
			}
		}
		if len(path_ranges) == 0 {continue}
		for rng in path_ranges {append(&raw_paths, all_pts[rng[0]:rng[1]])}
		slice.sort_by(raw_paths[:], proc(a, b: []polygon.Polygon_Point) -> bool {
			return polygon.polygon_path_slice_less(a, b)
		})
		paths := make([]polygon.Polygon_Path, len(raw_paths), allocator)
		points := make([]polygon.Polygon_Point, len(all_pts), allocator)
		pw := 0
		for rp, idx in raw_paths {
			paths[idx] = {offset = u64(pw), count = u64(len(rp))}
			copy(points[pw:pw+len(rp)], rp)
			pw += len(rp)
		}
		sets[layer_idx] = {paths = paths, points = points[:pw]}
	}
	return sets
}

@(private = "file")
destroy_model_polygon_sets :: proc(sets: []polygon.Polygon_Set, allocator: mem.Allocator) {
	for &s in sets {
		polygon.polygon_set_destroy(&s, allocator)
	}
	delete(sets, allocator)
}

@(private = "file")
polygon_set_total_area_2 :: proc(set: polygon.Polygon_Set) -> i128 {
	total: i128
	for p in set.paths {
		s := int(p.offset)
		e := s + int(p.count)
		total += polygon.polygon_path_area_2(set.points[s:e])
	}
	return total
}

@(private = "file")
make_role_overlap_sources :: proc(
	layer_ids: []contracts.Stable_ID,
	bridges: features.Bridge_Evidence_Result,
	skins: features.Skin_Result,
	allocator: mem.Allocator,
) -> (sources: []features.Role_Overlap_Source, owned_sets: [dynamic]polygon.Polygon_Set) {
	list := make([dynamic]features.Role_Overlap_Source, 0, len(bridges.masks)+len(skins.masks), allocator)
	owned_sets = make([dynamic]polygon.Polygon_Set, 0, len(bridges.masks)+len(skins.masks), allocator)

	for m in bridges.masks {
		if m.kind != .Eligible_Unsupported || m.path_count == 0 {continue}
		paths := make([]polygon.Polygon_Path, m.path_count, allocator)
		pts := make([]polygon.Polygon_Point, m.point_count, allocator)
		pti: u64
		for k in 0..<u64(m.path_count) {
			bp := bridges.paths[m.path_offset+k]
			paths[k] = {offset = pti, count = u64(bp.point_count)}
			for j in 0..<u64(bp.point_count) {
				pts[pti] = bridges.points[bp.point_offset+j]
				pti += 1
			}
		}
		set := polygon.Polygon_Set{paths = paths, points = pts}
		if _, ok := polygon.polygon_set_hash(set); !ok || polygon_set_total_area_2(set) <= 0 {
			polygon.polygon_set_destroy(&set, allocator)
			continue
		}
		append(&owned_sets, set)
		append(&list, features.Role_Overlap_Source{
			stable_id   = m.stable_id,
			layer_id    = layer_ids[m.layer_index],
			layer_index = m.layer_index,
			role        = .Bridge,
			geometry    = set,
		})
	}

	for m in skins.masks {
		if m.path_count == 0 {continue}
		role: profiles.Printable_Role
		switch m.kind {
		case .Top:        role = .Top_Skin
		case .Bottom:     role = .Bottom_Skin
		case .Top_Bottom: role = .Top_Bottom_Skin
		case .Invalid:    continue
		}
		paths := make([]polygon.Polygon_Path, m.path_count, allocator)
		pts := make([]polygon.Polygon_Point, m.point_count, allocator)
		pti: u64
		for k in 0..<u64(m.path_count) {
			sp := skins.paths[m.path_offset+k]
			paths[k] = {offset = pti, count = u64(sp.point_count)}
			for j in 0..<u64(sp.point_count) {
				pts[pti] = skins.points[sp.point_offset+j]
				pti += 1
			}
		}
		set := polygon.Polygon_Set{paths = paths, points = pts}
		if _, ok := polygon.polygon_set_hash(set); !ok || polygon_set_total_area_2(set) <= 0 {
			polygon.polygon_set_destroy(&set, allocator)
			continue
		}
		append(&owned_sets, set)
		append(&list, features.Role_Overlap_Source{
			stable_id   = m.stable_id,
			layer_id    = layer_ids[m.layer_index],
			layer_index = m.layer_index,
			role        = role,
			geometry    = set,
		})
	}
	return list[:], owned_sets
}

// Executes the full staged STL/OBJ/3MF slicing pipeline into validated Klipper G-code.
// Decodes STL (binary/ASCII), OBJ, or 3MF bytes into a Decoded_Mesh.
decode_mesh_bytes :: proc(
	bytes: []u8,
	filename: string,
	default_units := contracts.Source_Units.Millimetres,
	allocator := context.allocator,
) -> (mesh: formats.Decoded_Mesh, units: contracts.Source_Units, err: Slice_Run_Error) {
	is_3mf := strings.has_suffix(strings.to_lower(filename, context.temp_allocator), ".3mf")
	is_obj := strings.has_suffix(strings.to_lower(filename, context.temp_allocator), ".obj") || formats.obj_source_likely(bytes)
	if is_3mf {
		pkg, pkg_err := formats.three_mf_package_open(bytes, allocator = allocator)
		if pkg_err != .None {return {}, default_units, {stage = "decode_3mf", detail = fmt.tprintf("3mf package error: %v", pkg_err)}}
		defer formats.three_mf_package_destroy(&pkg, allocator)
		scene, scene_err := formats.three_mf_model_decode(pkg, allocator = allocator)
		if scene_err != .None {return {}, default_units, {stage = "decode_3mf", detail = fmt.tprintf("3mf scene error: %v", scene_err)}}
		defer formats.three_mf_scene_destroy(&scene, allocator)
		flat, flat_err := formats.three_mf_scene_flatten(scene, allocator = allocator)
		if flat_err != .None {return {}, default_units, {stage = "decode_3mf", detail = fmt.tprintf("3mf flatten error: %v", flat_err)}}
		// Transfer flat.mesh ownership directly to caller.
		return flat.mesh, scene.source.units, {}
	}
	if is_obj {
		obj_dec, obj_err := formats.obj_decode(bytes, default_units, allocator = allocator)
		if obj_err != .None {return {}, default_units, {stage = "decode_obj", detail = fmt.tprintf("obj decode error: %v", obj_err)}}
		return obj_dec.mesh, default_units, {}
	}
	stl_dec, stl_err := formats.stl_decode(bytes, default_units, allocator = allocator)
	if stl_err != .None {return {}, default_units, {stage = "decode_stl", detail = fmt.tprintf("stl decode error: %v", stl_err)}}
	return stl_dec, default_units, {}
}

slice_run_bytes :: proc(
	bytes: []u8,
	filename: string,
	profile: profiles.Resolved_Profiles,
	options := DEFAULT_SLICE_RUN_OPTIONS,
	allocator := context.allocator,
) -> (result: Slice_Run_Result, err: Slice_Run_Error) {
	decoded, units, dec_err := decode_mesh_bytes(bytes, filename, options.source_units, allocator)
	if len(dec_err.stage) > 0 {return {}, dec_err}
	defer formats.decoded_mesh_destroy(&decoded, allocator)
	opts := options
	opts.source_units = units
	return slice_run_decoded_mesh(&decoded, profile, opts, allocator)
}

slice_run_decoded_mesh :: proc(
	decoded: ^formats.Decoded_Mesh,
	profile: profiles.Resolved_Profiles,
	options := DEFAULT_SLICE_RUN_OPTIONS,
	allocator := context.allocator,
) -> (result: Slice_Run_Result, err: Slice_Run_Error) {
	t_total := time.tick_now()
	result.stages = make([dynamic]Stage_Trace, 0, 20, allocator)
	features.set_worker_threads(options.worker_threads)
	slicing.slicing_set_worker_threads(options.worker_threads)
	provider := polygon.NATIVE_PROVIDER if options.use_native_polygon else polygon.CLIPPER2_PROVIDER
	process := profile.process
	proc_src := process.source

	// Stage 1: Optional 3D mesh auto-repair, center on bed, and run Slice Spine.
	t0 := time.tick_now()
	if options.mesh_auto_repair {
		result.mesh_repair_stats = repair.mesh_auto_repair(decoded, allocator)
	}
	if options.center_on_bed {center_decoded_on_bed(decoded, profile.printer)}
	spine_cfg := Slice_Spine_Config{
		source_units        = options.source_units,
		first_layer_height  = proc_src.first_layer_height,
		layer_height        = proc_src.layer_height,
		max_layer_count     = options.max_layer_count,
		adaptive_layers     = options.adaptive_layers,
		min_adaptive_height = profile.printer.minimum_layer_height,
		max_adaptive_height = profile.printer.maximum_layer_height,
		fast_headless       = true,
	}
	spine_err: Slice_Spine_Error
	result.spine, spine_err = slice_spine_stl_decoded(decoded^, spine_cfg, allocator)
	if spine_err != .None {
		slice_run_result_destroy(&result, allocator)
		return {}, {stage = "slice_spine", detail = fmt.tprintf("spine error: %v", spine_err)}
	}
	record_stage(&result.stages, "slice_spine", t0, u64(len(result.spine.mesh.triangle_ids)), u64(len(result.spine.schedule.layer_ids)))

	// Stage 2: Contour simplification (Douglas-Peucker) + regions + automatic repair loop.
	t0 = time.tick_now()
	active_topo := result.spine.topology
	if options.contour_simplify_tolerance_um > 0.0 {
		if simp_topo, simp_ok := slicing.topology_simplify_contours(
			active_topo,
			options.contour_simplify_tolerance_um,
			allocator,
		); simp_ok {
			result.repaired_topology = simp_topo
			result.has_repaired = true
			active_topo = result.repaired_topology
		}
	}
	for {
		failure: slicing.Region_Failure
		reg_err: slicing.Region_Error
		result.regions, reg_err = slicing.regions_build(active_topo, allocator = allocator, failure = &failure)
		if reg_err == .None {break}
		if reg_err == .Contour_Intersection && result.contour_repairs < options.max_contour_repairs {
			rep, rep_err := repair.contour_path_repair(
				active_topo,
				provider,
				{failure = failure, fill_rule = .Non_Zero, lineage_tolerance = 50},
				allocator = allocator,
			)
			if rep_err != .None {
				slice_run_result_destroy(&result, allocator)
				return {}, {stage = "contour_repair", detail = fmt.tprintf("repair error: %v (layer %d)", rep_err, failure.layer_index)}
			}
			next_topo, apply_err := repair.contour_repair_apply_for_regions(active_topo, rep, allocator)
			repair.contour_repair_result_destroy(&rep, allocator)
			if apply_err != .None {
				slice_run_result_destroy(&result, allocator)
				return {}, {stage = "contour_repair_apply", detail = fmt.tprintf("apply error: %v", apply_err)}
			}
			if result.has_repaired {
				slicing.topology_result_destroy(&result.repaired_topology, allocator)
			}
			result.repaired_topology = next_topo
			result.has_repaired = true
			active_topo = result.repaired_topology
			result.contour_repairs += 1
			continue
		}
		slice_run_result_destroy(&result, allocator)
		return {}, {stage = "regions", detail = fmt.tprintf("regions error: %v (layer %d, repairs=%d)", reg_err, failure.layer_index, result.contour_repairs)}
	}
	record_stage(&result.stages, "regions_and_repair", t0, u64(len(result.regions.regions)), u64(result.contour_repairs))

	layer_count := len(result.spine.schedule.layer_ids)
	layer_heights := make([]contracts.Micrometres, layer_count, allocator)
	defer delete(layer_heights, allocator)
	for i in 0..<layer_count {
		if options.adaptive_layers {
			prev_z := i64(result.spine.schedule.minimum_z) if i == 0 else i64(result.spine.schedule.layer_z[i-1])
			dz := i64(result.spine.schedule.layer_z[i]) - prev_z
			layer_heights[i] = contracts.Micrometres(max(i64(10), dz))
		} else {
			layer_heights[i] = proc_src.first_layer_height if i == 0 else proc_src.layer_height
		}
	}

	// Stage 3: Perimeters (with optional layer-0 elephant-foot compensation) & Bed Adhesion.
	t0 = time.tick_now()
	perimeters, perim_err := features.perimeters_generate(
		active_topo,
		result.regions,
		provider,
		{
			count                = proc_src.perimeter_count,
			line_width           = proc_src.nominal_line_width,
			first_layer_inset_um = options.elephant_foot_compensation_um,
			topology_policy      = .Diagnostic_Closed_Regions,
			join_type            = .Miter,
			miter_limit          = 2.0,
			arc_tolerance        = 0.0,
		},
		allocator = allocator,
	)
	if perim_err != .None {
		slice_run_result_destroy(&result, allocator)
		return {}, {stage = "perimeters", detail = fmt.tprintf("perimeters error: %v", perim_err)}
	}
	defer features.perimeter_result_destroy(&perimeters, allocator)
	adhesion := features.adhesion_build(
		provider,
		active_topo,
		result.regions,
		{
			skirt_loops                   = options.skirt_loops,
			skirt_distance_um             = options.skirt_distance_um,
			skirt_height_layers           = options.skirt_height_layers,
			brim_width_um                 = options.brim_width_um,
			brim_gap_um                   = options.brim_gap_um,
			brim_inner                    = options.brim_inner,
			elephant_foot_compensation_um = options.elephant_foot_compensation_um,
			line_width_um                 = proc_src.nominal_line_width,
			bed_min_x                     = profile.printer.axis_minimum_x,
			bed_max_x                     = profile.printer.axis_maximum_x,
			bed_min_y                     = profile.printer.axis_minimum_y,
			bed_max_y                     = profile.printer.axis_maximum_y,
		},
		allocator = allocator,
	)
	defer features.adhesion_result_destroy(&adhesion, allocator)
	record_stage(&result.stages, "perimeters", t0, u64(len(perimeters.paths)), u64(len(adhesion.loops)))

	// Stage 4: Surfaces & Skin propagation.
	t0 = time.tick_now()
	surfaces, surf_err := features.surfaces_classify(
		active_topo,
		result.regions,
		provider,
		{fill_rule = .Non_Zero, topology_policy = .Diagnostic_Closed_Regions},
		allocator = allocator,
	)
	if surf_err != .None {
		slice_run_result_destroy(&result, allocator)
		return {}, {stage = "surfaces", detail = fmt.tprintf("surfaces error: %v", surf_err)}
	}
	defer features.surface_result_destroy(&surfaces, allocator)
	skins, skin_err := features.skins_propagate(
		active_topo,
		result.regions,
		surfaces,
		layer_heights,
		provider,
		{fill_rule = .Non_Zero, top = proc_src.top_skin, bottom = proc_src.bottom_skin, skip_source_filtering = true},
		allocator = allocator,
	)
	if skin_err != .None {
		slice_run_result_destroy(&result, allocator)
		return {}, {stage = "skins", detail = fmt.tprintf("skins error: %v", skin_err)}
	}
	defer features.skin_result_destroy(&skins, allocator)
	record_stage(&result.stages, "surfaces_and_skin", t0, u64(len(surfaces.masks)), u64(len(skins.masks)))

	// Stage 5: Bridges (evidence -> directions -> paths).
	t0 = time.tick_now()
	bridge_ev, bev_err := features.bridge_evidence_build(
		active_topo,
		result.regions,
		process,
		provider,
		{fill_rule = .Non_Zero, join_type = .Miter, miter_limit = 2.0, arc_tolerance = 0.0},
		allocator = allocator,
	)
	if bev_err != .None {
		slice_run_result_destroy(&result, allocator)
		return {}, {stage = "bridge_evidence", detail = fmt.tprintf("bridge evidence error: %v", bev_err)}
	}
	defer features.bridge_evidence_result_destroy(&bridge_ev, allocator)
	bridge_dir, bdir_err := features.bridge_directions_score(
		active_topo,
		result.regions,
		bridge_ev,
		process,
		provider,
		allocator = allocator,
	)
	if bdir_err != .None {
		slice_run_result_destroy(&result, allocator)
		return {}, {stage = "bridge_directions", detail = fmt.tprintf("bridge directions error: %v", bdir_err)}
	}
	defer features.bridge_direction_result_destroy(&bridge_dir, allocator)
	bridges, bpath_err := features.bridge_paths_generate(bridge_ev, bridge_dir, process, allocator = allocator)
	if bpath_err != .None {
		slice_run_result_destroy(&result, allocator)
		return {}, {stage = "bridge_paths", detail = fmt.tprintf("bridge paths error: %v", bpath_err)}
	}
	defer features.bridge_path_result_destroy(&bridges, allocator)
	record_stage(&result.stages, "bridges", t0, u64(len(bridge_ev.masks)), u64(len(bridges.paths)))

	// Stage 6: Role overlap resolution & solid skin paths.
	t0 = time.tick_now()
	overlap_sources, owned_overlap_sets := make_role_overlap_sources(result.spine.schedule.layer_ids, bridge_ev, skins, allocator)
	defer {
		for &oset in owned_overlap_sets {polygon.polygon_set_destroy(&oset, allocator)}
		delete(owned_overlap_sets)
		delete(overlap_sources, allocator)
	}
	overlap, ov_err := features.role_overlap_resolve(
		result.spine.schedule.layer_ids,
		overlap_sources,
		process,
		provider,
		.Non_Zero,
		allocator = allocator,
	)
	if ov_err != .None {
		slice_run_result_destroy(&result, allocator)
		return {}, {stage = "role_overlap", detail = fmt.tprintf("role overlap error: %v", ov_err)}
	}
	defer features.role_overlap_result_destroy(&overlap, allocator)
	solids, sol_err := features.solid_paths_generate(overlap, process, provider, allocator = allocator)
	if sol_err != .None {
		slice_run_result_destroy(&result, allocator)
		return {}, {stage = "solid_paths", detail = fmt.tprintf("solid paths error: %v", sol_err)}
	}
	defer features.solid_path_result_destroy(&solids, allocator)
	if options.monotonic_skin {
		features.solid_paths_sort_monotonic(&solids)
	}
	max_lh := max(proc_src.first_layer_height, proc_src.layer_height)
	ironing := features.ironing_paths_generate(
		overlap,
		{
			enabled      = options.ironing_enabled,
			spacing_um   = options.ironing_spacing_um,
			flow_percent = options.ironing_flow_percent,
			line_width   = proc_src.nominal_line_width,
			min_width_um = max_lh,
		},
		allocator,
	)
	defer features.ironing_result_destroy(&ironing, allocator)
	record_stage(&result.stages, "solid_paths", t0, u64(len(solids.paths)), u64(len(ironing.paths)))

	// Stage 7: Sparse infill (Rectilinear fast path or general pattern generator).
	t0 = time.tick_now()
	density := clamp(options.infill_density_percent, 1.0, 100.0)
	infill_spacing := contracts.Micrometres(max(i64(proc_src.nominal_line_width), i64(math.round(f64(proc_src.nominal_line_width)*100.0/density))))
	infill_inset := contracts.Micrometres(i64(proc_src.perimeter_count)*i64(proc_src.nominal_line_width))
	infill: features.Infill_Result
	pattern_infill: features.Infill_Pattern_Result
	if options.infill_pattern == .Rectilinear {
		inf_err: features.Infill_Error
		infill, inf_err = features.infill_generate(
			active_topo,
			result.regions,
			provider,
			{
				spacing              = infill_spacing,
				boundary_inset       = infill_inset,
				phase                = 0,
				base_axis            = .Vertical,
				alternate_each_layer = true,
				topology_policy      = .Diagnostic_Closed_Regions,
				join_type            = .Miter,
				miter_limit          = 2.0,
				arc_tolerance        = 0.0,
			},
			allocator = allocator,
		)
		if inf_err != .None {
			slice_run_result_destroy(&result, allocator)
			return {}, {stage = "infill", detail = fmt.tprintf("infill error: %v", inf_err)}
		}
		record_stage(&result.stages, "infill", t0, u64(len(infill.segments)), u64(infill_spacing))
	} else {
		infill.layers = make([]features.Infill_Layer, layer_count, allocator)
		pattern_infill = features.infill_pattern_generate(
			active_topo,
			result.regions,
			skins,
			result.spine.schedule.layer_z,
			provider,
			{
				pattern        = options.infill_pattern,
				spacing_um     = infill_spacing,
				line_width_um  = proc_src.nominal_line_width,
				boundary_inset = infill_inset,
				worker_threads = options.worker_threads,
			},
			allocator,
		)
		record_stage(&result.stages, "infill", t0, u64(len(pattern_infill.paths)), u64(infill_spacing))
	}
	defer features.infill_result_destroy(&infill, allocator)
	defer features.infill_pattern_result_destroy(&pattern_infill, allocator)

	// Stage 8: Gap fill (evidence -> samples -> centerlines).
	t0 = time.tick_now()
	gap_ev, gev_err := features.gap_evidence_build(
		active_topo,
		result.regions,
		perimeters,
		provider,
		{
			fill_rule          = .Non_Zero,
			minimum_line_width = process.thin_wall_minimum_width,
			maximum_line_width = process.thin_wall_maximum_width,
			join_type          = .Miter,
			miter_limit        = 2.0,
			arc_tolerance      = 0.0,
			uncovered_only     = true,
		},
		allocator = allocator,
	)
	if gev_err != .None {
		slice_run_result_destroy(&result, allocator)
		return {}, {stage = "gap_evidence", detail = fmt.tprintf("gap evidence error: %v", gev_err)}
	}
	defer features.gap_evidence_result_destroy(&gap_ev, allocator)
	gap_samp, gs_err := features.gap_samples_build(
		gap_ev,
		process,
		{spacing = proc_src.nominal_line_width, phase = 0},
		allocator = allocator,
	)
	if gs_err != .None {
		slice_run_result_destroy(&result, allocator)
		return {}, {stage = "gap_samples", detail = fmt.tprintf("gap samples error: %v", gs_err)}
	}
	defer features.gap_sample_result_destroy(&gap_samp, allocator)
	gaps, gc_err := features.gap_centerlines_build(gap_ev, gap_samp, 2, allocator = allocator)
	if gc_err != .None {
		slice_run_result_destroy(&result, allocator)
		return {}, {stage = "gap_centerlines", detail = fmt.tprintf("gap centerlines error: %v", gc_err)}
	}
	defer features.gap_centerline_result_destroy(&gaps, allocator)
	record_stage(&result.stages, "gap_fill", t0, u64(len(gaps.paths)), u64(len(gaps.vertices)))

	// Stage 9: Supports (Tree/Organic or Grid/Rectilinear), or empty layers when disabled.
	t0 = time.tick_now()
	supports: features.Support_Path_Result
	tree_supports: features.Tree_Support_Result
	if options.enable_supports && options.support_style_tree {
		supports.pattern = proc_src.support_pattern
		supports.line_width = proc_src.nominal_line_width
		supports.layers = make([]features.Support_Path_Layer, layer_count, allocator)
		model_sets_sup := build_model_polygon_sets(active_topo, result.regions, allocator)
		defer destroy_model_polygon_sets(model_sets_sup, allocator)
		tree_supports = features.tree_supports_generate(
			active_topo,
			result.regions,
			model_sets_sup,
			result.spine.schedule.layer_z,
			{
				overhang_angle_deg  = f64(i32(proc_src.support_overhang_angle)) / 1000.0,
				branch_angle_deg    = 45.0,
				tip_radius_um       = 800,
				trunk_max_radius_um = 6_000,
				tip_spacing_um      = 4_000,
				xy_clearance_um     = proc_src.support_clearance_xy,
				interface_layers    = proc_src.support_interface_layers,
				line_width_um       = proc_src.nominal_line_width,
				bed_min_x           = profile.printer.axis_minimum_x,
				bed_max_x           = profile.printer.axis_maximum_x,
				bed_min_y           = profile.printer.axis_minimum_y,
				bed_max_y           = profile.printer.axis_maximum_y,
			},
			allocator,
		)
	} else if options.enable_supports {
		sup_faces, sf_err := features.support_faces_classify(result.spine.mesh, process, allocator = allocator)
		if sf_err != .None {
			slice_run_result_destroy(&result, allocator)
			return {}, {stage = "support_faces", detail = fmt.tprintf("support faces error: %v", sf_err)}
		}
		defer features.support_face_result_destroy(&sup_faces, allocator)
		sup_demand, sd_err := features.support_demand_build(
			result.spine.schedule,
			active_topo,
			result.regions,
			sup_faces,
			process,
			provider,
			{fill_rule = .Non_Zero, join_type = .Miter, miter_limit = 2.0, arc_tolerance = 0.0},
			allocator = allocator,
		)
		if sd_err != .None {
			slice_run_result_destroy(&result, allocator)
			return {}, {stage = "support_demand", detail = fmt.tprintf("support demand error: %v", sd_err)}
		}
		defer features.support_demand_result_destroy(&sup_demand, allocator)
		sup_geom, sg_err := features.support_geometry_build(
			result.spine.schedule,
			active_topo,
			result.regions,
			sup_demand,
			process,
			provider,
			allocator = allocator,
		)
		if sg_err != .None {
			slice_run_result_destroy(&result, allocator)
			return {}, {stage = "support_geometry", detail = fmt.tprintf("support geometry error: %v", sg_err)}
		}
		defer features.support_geometry_result_destroy(&sup_geom, allocator)
		sp_err: features.Support_Path_Error
		supports, sp_err = features.support_paths_generate(sup_geom, process, provider, allocator = allocator)
		if sp_err != .None {
			slice_run_result_destroy(&result, allocator)
			return {}, {stage = "support_paths", detail = fmt.tprintf("support paths error: %v", sp_err)}
		}
	} else {
		supports.pattern = proc_src.support_pattern
		supports.line_width = proc_src.nominal_line_width
		supports.layers = make([]features.Support_Path_Layer, layer_count, allocator)
	}
	defer features.support_path_result_destroy(&supports, allocator)
	defer features.tree_support_result_destroy(&tree_supports, allocator)
	sup_count := u64(len(tree_supports.paths)) if (options.enable_supports && options.support_style_tree) else u64(len(supports.paths))
	record_stage(&result.stages, "supports", t0, sup_count, 2 if (options.enable_supports && options.support_style_tree) else (1 if options.enable_supports else 0))

	// Stage 10: Unified path sources & unified path plan (seam + travel ordering).
	t0 = time.tick_now()
	u_sources, us_err := features.unified_path_sources_build(
		result.spine.schedule.layer_ids,
		perimeters,
		bridges,
		gaps,
		solids,
		infill,
		supports,
		process,
		options.inner_perimeters_first,
		allocator = allocator,
	)
	if us_err != .None {
		slice_run_result_destroy(&result, allocator)
		return {}, {stage = "unified_sources", detail = fmt.tprintf("unified sources error: %v", us_err)}
	}
	defer features.unified_path_source_result_destroy(&u_sources, allocator)
	// Inject adhesion loops (skirt & brim), custom pattern infill, and top-surface ironing passes.
	all_sources := make(
		[dynamic]features.Unified_Path_Source,
		0,
		len(u_sources.sources) + len(adhesion.loops) + len(pattern_infill.paths) + len(ironing.paths),
		allocator,
	)
	defer delete(all_sources)
	for loop, li in adhesion.loops {
		if int(loop.layer_index) >= len(result.spine.schedule.layer_ids) {continue}
		layer_id := result.spine.schedule.layer_ids[loop.layer_index]
		append(&all_sources, features.Unified_Path_Source{
			stable_id    = contracts.stable_id_child(layer_id, .Feature, u64(1)<<62 | u64(li)),
			layer_id     = layer_id,
			layer_index  = loop.layer_index,
			role         = .Perimeter,
			source_kind  = .Adhesion,
			source_index = u32(li),
			source_order = u64(li),
			closed       = true,
			points       = loop.points,
			line_widths  = loop.line_widths,
		})
	}
	for s in u_sources.sources {
		append(&all_sources, s)
	}
	for ip, pi in pattern_infill.paths {
		if int(ip.layer_index) >= len(result.spine.schedule.layer_ids) {continue}
		layer_id := result.spine.schedule.layer_ids[ip.layer_index]
		append(&all_sources, features.Unified_Path_Source{
			stable_id    = contracts.stable_id_child(layer_id, .Feature, u64(1)<<61 | u64(pi)),
			layer_id     = layer_id,
			layer_index  = ip.layer_index,
			role         = .Sparse_Infill,
			source_kind  = .Sparse_Infill,
			source_index = u32(pi),
			source_order = u64(pi),
			closed       = false,
			points       = ip.points,
			line_widths  = ip.line_widths,
		})
	}
	for ir, ii in ironing.paths {
		if int(ir.layer_index) >= len(result.spine.schedule.layer_ids) {continue}
		layer_id := result.spine.schedule.layer_ids[ir.layer_index]
		append(&all_sources, features.Unified_Path_Source{
			stable_id    = contracts.stable_id_child(layer_id, .Feature, u64(1)<<60 | u64(ii)),
			layer_id     = layer_id,
			layer_index  = ir.layer_index,
			role         = .Top_Skin,
			source_kind  = .Solid,
			source_index = u32(ii),
			source_order = (u64(1) << 40) + u64(ii),
			closed       = false,
			points       = ir.points,
			line_widths  = ir.line_widths,
		})
	}
	for tp, ti in tree_supports.paths {
		if int(tp.layer_index) >= len(result.spine.schedule.layer_ids) {continue}
		layer_id := result.spine.schedule.layer_ids[tp.layer_index]
		append(&all_sources, features.Unified_Path_Source{
			stable_id    = contracts.stable_id_child(layer_id, .Feature, u64(1)<<59 | u64(ti)),
			layer_id     = layer_id,
			layer_index  = tp.layer_index,
			role         = .Support_Interface if tp.is_interface else .Support,
			source_kind  = .Support,
			source_index = u32(ti),
			source_order = u64(ti),
			closed       = true,
			points       = tp.points,
			line_widths  = tp.line_widths,
		})
	}
	if options.variable_walls_enabled {
		_ = features.variable_walls_adapt(all_sources[:], {
			enabled          = true,
			nominal_width_um = proc_src.nominal_line_width,
			min_width_um     = max(max_lh, contracts.Micrometres((i64(proc_src.nominal_line_width)*65)/100)),
		})
	}
	fuzzy_owned_pts := make([dynamic][]polygon.Polygon_Point, 0, 16, allocator)
	fuzzy_owned_ws := make([dynamic][]contracts.Micrometres, 0, 16, allocator)
	defer {
		for p in fuzzy_owned_pts {delete(p, allocator)}
		for w in fuzzy_owned_ws {delete(w, allocator)}
		delete(fuzzy_owned_pts)
		delete(fuzzy_owned_ws)
	}
	if options.fuzzy_skin_enabled {
		_ = features.fuzzy_skin_apply(
			all_sources[:],
			perimeters,
			{
				enabled       = true,
				thickness_um  = options.fuzzy_thickness_um,
				point_dist_um = options.fuzzy_point_dist_um,
			},
			profile.printer,
			&fuzzy_owned_pts,
			&fuzzy_owned_ws,
			allocator,
		)
	}
	// Guarantee every extrusion vertex meets rounded-bead invariant (line_width >= layer_height).
	for &src in all_sources {
		if int(src.layer_index) >= len(layer_heights) {continue}
		lh := layer_heights[src.layer_index]
		for wi in 0..<len(src.line_widths) {
			if i64(src.line_widths[wi]) < i64(lh) {
				src.line_widths[wi] = lh
			}
		}
	}
	plan_err: features.Unified_Path_Plan_Error
	result.unified_plan, plan_err = features.unified_path_plan_build(
		result.spine.schedule.layer_ids,
		all_sources[:],
		{
			start           = {x = profile.printer.axis_minimum_x, y = profile.printer.axis_minimum_y},
			seam            = proc_src.seam,
			seam_visibility = proc_src.seam_visibility,
			seam_strategy   = options.seam_strategy,
		},
		allocator = allocator,
	)
	if plan_err != .None {
		slice_run_result_destroy(&result, allocator)
		return {}, {stage = "unified_path_plan", detail = fmt.tprintf("unified path plan error: %v", plan_err)}
	}
	record_stage(&result.stages, "unified_path_plan", t0, result.unified_plan.extrude_move_count, result.unified_plan.travel_move_count)

	// Stage 11: Extrusion & Motion Plan.
	t0 = time.tick_now()
	ext_err: features.Extrusion_Error
	result.extrusion, ext_err = features.extrusion_calculate(
		result.unified_plan,
		layer_heights,
		profile.material,
		process,
		allocator = allocator,
	)
	if ext_err != .None {
		slice_run_result_destroy(&result, allocator)
		return {}, {stage = "extrusion", detail = fmt.tprintf("extrusion error: %v", ext_err)}
	}
	model_sets := build_model_polygon_sets(active_topo, result.regions, allocator)
	defer destroy_model_polygon_sets(model_sets, allocator)
	mot_err: features.Motion_Plan_Error
	result.motion, mot_err = features.motion_plan_build(
		result.spine.schedule.layer_ids,
		result.spine.schedule.layer_z,
		model_sets,
		result.unified_plan,
		result.extrusion,
		profile,
		allocator = allocator,
		options = {
			wipe_distance_um          = options.wipe_distance_um,
			overhang_slowdown_enabled = options.overhang_slowdown_enabled,
			overhang_speed_percent    = options.overhang_speed_percent,
			use_gpu                   = options.use_gpu,
			worker_threads            = options.worker_threads,
		},
	)
	if mot_err != .None {
		slice_run_result_destroy(&result, allocator)
		return {}, {stage = "motion_plan", detail = fmt.tprintf("motion plan error: %v", mot_err)}
	}
	record_stage(&result.stages, "extrusion_and_motion", t0, u64(len(result.motion.operations)), u64(result.extrusion.total_filament_nm/1_000_000))

	// Stage 11b: G2/G3 Circular Arc Fitting (skip when scarf/vase Z ramps need linear segments).
	if options.arc_fitting_enabled && !options.vase_mode {
		t0 = time.tick_now()
		arc_cfg := features.DEFAULT_ARC_FIT_CONFIG
		if options.arc_tolerance_um > 0 {arc_cfg.max_chord_error_um = options.arc_tolerance_um}
		arc_stats := features.motion_plan_fit_arcs(&result.motion, profile.printer, arc_cfg, allocator)
		record_stage(&result.stages, "arc_fitting", t0, arc_stats.arcs_fitted, arc_stats.segments_replaced)
	}

	// Stage 11c: Scarf Seam / Spiral Vase Z Ramps, Modifiers, and Klipper Lookahead Time Estimate.
	if options.scarf_seam_enabled || options.vase_mode {
		_ = features.motion_plan_apply_z_ramps(
			&result.motion,
			layer_heights,
			{enabled = options.scarf_seam_enabled, length_um = options.scarf_length_um, start_height_pct = 10},
			options.vase_mode,
			proc_src.bottom_skin.minimum_layers,
			proc_src,
			result.unified_plan,
			perimeters,
		)
	}
	if len(options.modifiers) > 0 {
		_ = modifiers_apply_motion(&result.motion, options.modifiers, profile)
	}
	result.time_estimate = features.motion_plan_estimate_klipper_time(result.motion)

	// Stage 12: Klipper G-code emission & validation.
	t0 = time.tick_now()
	klip_err: gcode.Klipper_Error
	result.klipper, klip_err = gcode.klipper_emit(
		result.motion,
		profile,
		allocator = allocator,
		object_name = options.object_name,
		pause_layers = options.pause_layers,
		color_change_layers = options.color_change_layers,
	)
	if klip_err != .None {
		slice_run_result_destroy(&result, allocator)
		return {}, {stage = "klipper_emit", detail = fmt.tprintf("klipper emit error: %v", klip_err)}
	}
	result.validation = result.klipper.validation
	record_stage(&result.stages, "klipper_emit_validate", t0, u64(len(result.klipper.bytes)), u64(len(result.klipper.commands)))

	result.total_duration_ms = time.duration_seconds(time.tick_since(t_total))*1000.0
	return result, {}
}
