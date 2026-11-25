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
	// Where the first travel starts; the printer's axis minimum unless has_plan_start is set.
	has_plan_start:                bool,
	plan_start:                    polygon.Polygon_Point,
	// Milestone 3: Infill patterns, monotonic/ironing, G2/G3 arcs, variable walls
	infill_pattern:                features.Infill_Pattern,
	monotonic_skin:                bool,
	ironing_enabled:               bool,
	ironing_type:                  features.Ironing_Type,
	ironing_spacing_um:            contracts.Micrometres,
	ironing_flow_percent:          u32,
	ironing_speed_um_s:            profiles.Speed_Um_Per_Second,
	ironing_inset_um:              contracts.Micrometres,
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
	scarf_start_height_percent:    u32,
	vase_mode:                     bool,
	fuzzy_skin_enabled:            bool,
	fuzzy_skin_mode:               features.Fuzzy_Skin_Mode,
	fuzzy_thickness_um:            contracts.Micrometres,
	fuzzy_point_dist_um:           contracts.Micrometres,
	fuzzy_first_layer:             bool,
	reduce_crossing_wall:          bool,
	max_travel_detour_distance_um: contracts.Micrometres,
	reduce_infill_retraction:      bool,
	mesh_auto_repair:              bool,
	// Solid bands under sloped surfaces so shells keep their thickness (Orca "ensure vertical
	// shell thickness", all surfaces).
	ensure_vertical_shells:        bool,
	contour_simplify_tolerance_um: f64,
	// OrcaSlicer Quality parity
	initial_layer_line_width_um:         contracts.Micrometres,
	outer_wall_line_width_um:            contracts.Micrometres,
	inner_wall_line_width_um:            contracts.Micrometres,
	top_surface_line_width_um:           contracts.Micrometres,
	internal_solid_infill_line_width_um: contracts.Micrometres,
	sparse_infill_line_width_um:         contracts.Micrometres,
	support_line_width_um:               contracts.Micrometres,
	xy_contour_compensation_um:          contracts.Micrometres,
	xy_hole_compensation_um:             contracts.Micrometres,
	precise_outer_wall:                  bool,
	wall_sequence:                       features.Wall_Sequence,
	infill_first:                        bool,
	only_one_wall_top:                   bool,
	only_one_wall_first_layer:           bool,
	seam_gap_percent:                    f64,
	staggered_inner_seams:               bool,
	// OrcaSlicer Strength parity
	detect_thin_wall:                    bool,
	top_surface_concentric:              bool,
	bottom_surface_concentric:           bool,
	top_surface_flow_ppm:                profiles.Ratio_Ppm,
	bottom_surface_flow_ppm:             profiles.Ratio_Ppm,
	infill_direction_deg:                f64,
	infill_wall_overlap_percent:         f64,
	infill_combination_layers:           u32,
	minimum_sparse_infill_area_um2:      i64,
	thick_bridges:                       bool,
	gap_fill_target:                     u8, // 0 = everywhere, 1 = nowhere, 2 = top_bottom
	// OrcaSlicer Speed & Acceleration parity
	initial_layer_speed_um_s:            profiles.Speed_Um_Per_Second,
	initial_layer_infill_speed_um_s:     profiles.Speed_Um_Per_Second,
	outer_wall_speed_um_s:               profiles.Speed_Um_Per_Second,
	inner_wall_speed_um_s:               profiles.Speed_Um_Per_Second,
	top_surface_speed_um_s:              profiles.Speed_Um_Per_Second,
	internal_solid_speed_um_s:           profiles.Speed_Um_Per_Second,
	small_perimeter_speed_um_s:          profiles.Speed_Um_Per_Second,
	small_perimeter_threshold_um:        contracts.Micrometres, // circumference threshold (2*pi*r)
	overhang_tier_speeds_um_s:           [4]profiles.Speed_Um_Per_Second,
	initial_layer_accel_um_s2:           profiles.Acceleration_Um_Per_Second_Squared,
	initial_layer_travel_accel_um_s2:    profiles.Acceleration_Um_Per_Second_Squared,
	outer_wall_accel_um_s2:              profiles.Acceleration_Um_Per_Second_Squared,
	inner_wall_accel_um_s2:              profiles.Acceleration_Um_Per_Second_Squared,
	top_surface_accel_um_s2:             profiles.Acceleration_Um_Per_Second_Squared,
	internal_solid_accel_um_s2:          profiles.Acceleration_Um_Per_Second_Squared,
	bridge_accel_um_s2:                  profiles.Acceleration_Um_Per_Second_Squared,
	accel_to_decel_pct:                  i64, // 0 = disabled, 10..100 = enabled
	// OrcaSlicer Support & Adhesion parity
	tree_branch_angle_deg:               f64,
	tree_tip_radius_um:                  contracts.Micrometres,
	tree_trunk_max_radius_um:            contracts.Micrometres,
	tree_tip_spacing_um:                 contracts.Micrometres,
	brim_type:                           features.Brim_Type,
	min_skirt_length_um:                 contracts.Micrometres,
	draft_shield:                        bool,
	raft_layers:                         u32,
	raft_contact_distance_um:            contracts.Micrometres,
	raft_expansion_um:                   contracts.Micrometres,
	modifiers:                     []Modifier_Zone,
	pause_layers:                  []u32,
	color_change_layers:           []u32,
	evidence_level:                contracts.Evidence_Level,
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
	tree_branch_angle_deg         = 45.0,
	tree_tip_radius_um            = 800,
	tree_trunk_max_radius_um      = 6_000,
	tree_tip_spacing_um           = 4_000,
	raft_contact_distance_um      = 100,
	raft_expansion_um             = 2_000,
	adaptive_layers               = false,
	use_native_polygon            = true,
	use_gpu                       = true,
	worker_threads                = 0,
	scarf_seam_enabled            = false,
	scarf_length_um               = 15_000,
	scarf_start_height_percent    = 10,
	vase_mode                     = false,
	fuzzy_skin_enabled            = false,
	fuzzy_thickness_um            = 300,
	fuzzy_point_dist_um           = 800,
	mesh_auto_repair              = true,
	ensure_vertical_shells        = true,
	detect_thin_wall              = true,
	infill_combination_layers     = 1,
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
	stages:                [dynamic]Stage_Trace,
	total_duration_ms:     f64,
	evidence_bundle_bytes: []u8,
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
	delete(r.evidence_bundle_bytes, allocator)
	delete(r.stages)
	r^ = {}
}

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

// One polygon set per layer holding every role-overlap mask (the solid skin and bridge areas).
role_overlap_layer_sets :: proc(
	overlap: features.Role_Overlap_Result,
	layer_count: int,
	allocator: mem.Allocator,
) -> []polygon.Polygon_Set {
	sets := make([]polygon.Polygon_Set, layer_count, allocator)
	for layer, layer_index in overlap.layers {
		if layer_index >= layer_count || layer.mask_count == 0 {continue}
		point_total := 0
		path_total := 0
		for mask in overlap.masks[layer.mask_offset:layer.mask_offset+u64(layer.mask_count)] {
			for path in overlap.paths[mask.path_offset:mask.path_offset+u64(mask.path_count)] {
				point_total += int(path.point_count)
				path_total += 1
			}
		}
		points := make([]polygon.Polygon_Point, point_total, allocator)
		paths := make([]polygon.Polygon_Path, path_total, allocator)
		point_write := 0
		path_write := 0
		for mask in overlap.masks[layer.mask_offset:layer.mask_offset+u64(layer.mask_count)] {
			for path in overlap.paths[mask.path_offset:mask.path_offset+u64(mask.path_count)] {
				count := int(path.point_count)
				copy(points[point_write:point_write+count], overlap.points[path.point_offset:path.point_offset+u64(count)])
				paths[path_write] = {offset = u64(point_write), count = u64(count)}
				point_write += count
				path_write += 1
			}
		}
		sets[layer_index] = {points = points, paths = paths}
	}
	return sets
}

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
				// Outer contours counter-clockwise and holes clockwise, as offsets expect.
				if contour.reverse_path {slice.reverse(ring)}
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

destroy_model_polygon_sets :: proc(sets: []polygon.Polygon_Set, allocator: mem.Allocator) {
	for &s in sets {
		polygon.polygon_set_destroy(&s, allocator)
	}
	delete(sets, allocator)
}

polygon_set_total_area_2 :: proc(set: polygon.Polygon_Set) -> i128 {
	total: i128
	for p in set.paths {
		s := int(p.offset)
		e := s + int(p.count)
		total += polygon.polygon_path_area_2(set.points[s:e])
	}
	return total
}

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
	session := slice_session_create_owned(&decoded, profile, opts, allocator)
	defer slice_session_destroy(session)
	run_err := slice_session_run_all(session)
	if len(run_err.stage) > 0 {return {}, run_err}
	evidence_bytes: []u8
	if opts.evidence_level != .Disabled {
		ev_err: Slice_Run_Error
		evidence_bytes, ev_err = slice_session_export_evidence_bundle(session, opts.evidence_level, allocator)
		if len(ev_err.stage) > 0 {return {}, ev_err}
	}
	res := slice_session_take_result(session)
	res.evidence_bundle_bytes = evidence_bytes
	return res, {}
}

slice_run_decoded_mesh :: proc(
	decoded: ^formats.Decoded_Mesh,
	profile: profiles.Resolved_Profiles,
	options := DEFAULT_SLICE_RUN_OPTIONS,
	allocator := context.allocator,
) -> (result: Slice_Run_Result, err: Slice_Run_Error) {
	session := slice_session_create(decoded^, profile, options, allocator)
	defer slice_session_destroy(session)
	run_err := slice_session_run_all(session)
	if len(run_err.stage) > 0 {return {}, run_err}
	evidence_bytes: []u8
	if options.evidence_level != .Disabled {
		ev_err: Slice_Run_Error
		evidence_bytes, ev_err = slice_session_export_evidence_bundle(session, options.evidence_level, allocator)
		if len(ev_err.stage) > 0 {return {}, ev_err}
	}
	res := slice_session_take_result(session)
	res.evidence_bundle_bytes = evidence_bytes
	return res, {}
}
