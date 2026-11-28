package pipeline

import "core:fmt"
import "core:math"
import "core:os"

import contracts "../contracts"
import profiles "../profiles"

// The most worker threads a stage starts; the parallel helpers clamp to this as well.
WORKER_THREADS_MAX :: 16

// Worker threads for a requested count: the count itself, or every logical core for 0. Measured on
// a 10-core M-series machine (4 performance, 6 efficiency), 10 threads slice Benchy 6 % faster than
// 8 (optimization ledger OPT-12).
resolved_worker_threads :: proc(requested: int) -> int {
	if requested > 0 {return min(requested, WORKER_THREADS_MAX)}
	return clamp(os.get_processor_core_count(), 1, WORKER_THREADS_MAX)
}

// Everything a slice reads besides the model: the unresolved profile documents and the run flags
// that no profile carries. The CLI and the application edit one of these and resolve it into the
// profiles and options that a Slice_Session takes.
Slice_Configuration :: struct {
	printer:             profiles.Printer_Profile,
	material:            profiles.Material_Profile,
	process:             profiles.Process_Profile,
	extras:              profiles.Process_JSON_Extras,
	dialect:             profiles.Dialect_Profile,
	enable_supports:     bool,
	adaptive_layers:     bool,
	use_native_polygon:  bool,
	use_gpu:             bool,
	// 0 uses every logical core (see `resolved_worker_threads`).
	worker_threads:      int,
	scarf_seam:          bool,
	vase_mode:           bool,
	fuzzy_skin:          bool,
	source_units:        contracts.Source_Units,
	object_name:         string,
	modifiers:           []Modifier_Zone,
	pause_layers:        []u32,
	color_change_layers: []u32,
}

// Loads the three profile files. On failure `detail` names the file and the reason.
slice_configuration_load :: proc(
	printer_path, material_path, process_path: string,
) -> (config: Slice_Configuration, detail: string, ok: bool) {
	printer, p_err := profiles.printer_profile_load_json(printer_path)
	if p_err != .None {
		return {}, fmt.tprintf("printer profile '%s': %s", printer_path, profiles.profile_json_error_text(p_err)), false
	}
	material, m_err := profiles.material_profile_load_json(material_path)
	if m_err != .None {
		return {}, fmt.tprintf("material profile '%s': %s", material_path, profiles.profile_json_error_text(m_err)), false
	}
	process, extras, pr_err := profiles.process_profile_load_json(process_path, printer)
	if pr_err != .None {
		return {}, fmt.tprintf("process profile '%s': %s", process_path, profiles.profile_json_error_text(pr_err)), false
	}
	profiles.profile_fit_printer(&process, printer)
	profiles.profile_fit_material(&process, material)
	config = {
		printer            = printer,
		material           = material,
		process            = process,
		extras             = extras,
		dialect            = profiles.profiles_default_klipper_dialect(),
		use_native_polygon = true,
		use_gpu            = true,
	}
	return config, "", true
}

// Applies one `key=value` profile setting.
slice_configuration_override :: proc(
	config: ^Slice_Configuration,
	key, value: string,
) -> (detail: string, ok: bool) {
	err := profiles.profile_apply_override(&config.process, &config.extras, key, value)
	if err != .None {
		return fmt.tprintf("override '%s=%s': %s", key, value, profiles.profile_json_error_text(err)), false
	}
	return "", true
}

slice_configuration_resolve :: proc(
	config: Slice_Configuration,
) -> (resolved: profiles.Resolved_Profiles, options: Slice_Run_Options, detail: string, ok: bool) {
	process := config.process
	extras := config.extras
	if config.vase_mode || extras.vase_mode {
		process.perimeter_count = 1
		extras.infill_density_percent = 0.0
	}
	err: profiles.Profile_Resolve_Error
	resolved, err = profiles.profiles_resolve(config.printer, config.material, process, config.dialect)
	if err != .None {
		return {}, {}, fmt.tprintf("profile resolution failed: %v", err), false
	}

	run := DEFAULT_SLICE_RUN_OPTIONS
	if config.source_units != .Unspecified {run.source_units = config.source_units}
	run.infill_density_percent = extras.infill_density_percent
	run.enable_supports = config.enable_supports || extras.enable_supports
	run.skirt_loops = extras.skirt_loops
	run.skirt_distance_um = contracts.Micrometres(i64(math.round(extras.skirt_distance_mm*1000.0)))
	run.skirt_height_layers = extras.skirt_height_layers
	run.min_skirt_length_um = contracts.Micrometres(i64(math.round(extras.min_skirt_length_mm*1000.0)))
	run.draft_shield = extras.draft_shield
	switch extras.brim_type {
	case "none":            run.brim_type = .None
	case "outer_only":      run.brim_type = .Outer_Only
	case "inner_only":      run.brim_type = .Inner_Only
	case "outer_and_inner": run.brim_type = .Outer_And_Inner
	case:                   run.brim_type = .Default
	}
	run.brim_width_um = contracts.Micrometres(i64(math.round(extras.brim_width_mm*1000.0)))
	run.brim_gap_um = contracts.Micrometres(i64(math.round(extras.brim_gap_mm*1000.0)))
	run.brim_inner = extras.brim_inner
	run.raft_layers = extras.raft_layers
	run.raft_contact_distance_um = contracts.Micrometres(i64(math.round(extras.raft_contact_distance_mm*1000.0)))
	run.raft_expansion_um = contracts.Micrometres(i64(math.round(extras.raft_expansion_mm*1000.0)))
	if extras.tree_branch_angle_deg > 0 {run.tree_branch_angle_deg = extras.tree_branch_angle_deg}
	if extras.tree_tip_diameter_mm > 0 {run.tree_tip_radius_um = contracts.Micrometres(i64(math.round(extras.tree_tip_diameter_mm*500.0)))}
	if extras.tree_branch_diameter_mm > 0 {run.tree_trunk_max_radius_um = contracts.Micrometres(i64(math.round(extras.tree_branch_diameter_mm*500.0)))}
	if extras.tree_branch_distance_mm > 0 {run.tree_tip_spacing_um = contracts.Micrometres(i64(math.round(extras.tree_branch_distance_mm*1000.0)))}
	run.elephant_foot_compensation_um = contracts.Micrometres(i64(math.round(extras.elephant_foot_compensation_mm*1000.0)))
	run.wipe_distance_um = contracts.Micrometres(i64(math.round(extras.wipe_distance_mm*1000.0)))
	run.overhang_slowdown_enabled = extras.overhang_slowdown_enabled
	run.overhang_speed_percent = extras.overhang_speed_percent
	switch extras.seam_position {
	case "rear":     run.seam_strategy = .Rear
	case "sharpest": run.seam_strategy = .Sharpest_Corner
	case "nearest":  run.seam_strategy = .Nearest
	case "random":   run.seam_strategy = .Random
	case:            run.seam_strategy = .Aligned
	}
	switch extras.infill_pattern {
	case "rectilinear":         run.infill_pattern = .Rectilinear
	case "grid":                run.infill_pattern = .Grid
	case "triangles":           run.infill_pattern = .Triangles
	case "cubic":               run.infill_pattern = .Cubic
	case "honeycomb":           run.infill_pattern = .Honeycomb
	case "lightning":           run.infill_pattern = .Lightning
	case "concentric":          run.infill_pattern = .Concentric
	case "aligned_rectilinear": run.infill_pattern = .Aligned_Rectilinear
	case:                       run.infill_pattern = .Gyroid
	}
	run.monotonic_skin = extras.monotonic_skin
	run.ironing_enabled = extras.ironing_enabled
	switch extras.ironing_type {
	case "top":       run.ironing_type = .Top
	case "topmost":   run.ironing_type = .Topmost
	case "all_solid": run.ironing_type = .All_Solid
	case:             run.ironing_type = .Top if extras.ironing_enabled else .None
	}
	run.ironing_spacing_um = contracts.Micrometres(i64(math.round(extras.ironing_spacing_mm*1000.0)))
	run.ironing_flow_percent = extras.ironing_flow_percent
	run.ironing_speed_um_s = profiles.Speed_Um_Per_Second(i64(math.round(extras.ironing_speed_mm_s*1000.0)))
	run.ironing_inset_um = contracts.Micrometres(i64(math.round(extras.ironing_inset_mm*1000.0)))
	run.arc_fitting_enabled = extras.arc_fitting_enabled
	run.arc_tolerance_um = extras.arc_tolerance_mm * 1000.0
	if extras.klipper_arc_resolution_mm >= 0 {
		run.klipper_arc_resolution_um = extras.klipper_arc_resolution_mm * 1000.0
	}
	run.variable_walls_enabled = extras.variable_walls_enabled
	run.support_style_tree = extras.support_style != "grid"
	run.adaptive_layers = config.adaptive_layers || extras.adaptive_layers
	run.use_native_polygon = config.use_native_polygon
	run.use_gpu = config.use_gpu
	run.worker_threads = config.worker_threads
	run.scarf_seam_enabled = config.scarf_seam || extras.scarf_seam_enabled
	if extras.scarf_length_mm > 0 {
		run.scarf_length_um = contracts.Micrometres(i64(math.round(extras.scarf_length_mm*1000.0)))
	}
	if extras.scarf_start_height_percent > 0 {
		run.scarf_start_height_percent = extras.scarf_start_height_percent
	}
	run.initial_layer_line_width_um = contracts.Micrometres(i64(math.round(extras.initial_layer_line_width_mm*1000.0)))
	run.outer_wall_line_width_um = contracts.Micrometres(i64(math.round(extras.outer_wall_line_width_mm*1000.0)))
	run.inner_wall_line_width_um = contracts.Micrometres(i64(math.round(extras.inner_wall_line_width_mm*1000.0)))
	run.top_surface_line_width_um = contracts.Micrometres(i64(math.round(extras.top_surface_line_width_mm*1000.0)))
	run.internal_solid_infill_line_width_um = contracts.Micrometres(i64(math.round(extras.internal_solid_infill_line_width_mm*1000.0)))
	run.sparse_infill_line_width_um = contracts.Micrometres(i64(math.round(extras.sparse_infill_line_width_mm*1000.0)))
	run.support_line_width_um = contracts.Micrometres(i64(math.round(extras.support_line_width_mm*1000.0)))
	if extras.resolution_mm > 0 {
		run.contour_simplify_tolerance_um = extras.resolution_mm * 1000.0
	}
	run.xy_contour_compensation_um = contracts.Micrometres(i64(math.round(extras.xy_contour_compensation_mm*1000.0)))
	run.xy_hole_compensation_um = contracts.Micrometres(i64(math.round(extras.xy_hole_compensation_mm*1000.0)))
	run.precise_outer_wall = extras.precise_outer_wall
	switch extras.wall_sequence {
	case "outer_inner":
		run.wall_sequence = .Outer_Inner
		run.inner_perimeters_first = false
	case "inner_outer_inner":
		run.wall_sequence = .Inner_Outer_Inner
		run.inner_perimeters_first = true
	case:
		run.wall_sequence = .Inner_Outer
		run.inner_perimeters_first = true
	}
	run.infill_first = extras.infill_first
	run.only_one_wall_top = extras.only_one_wall_top
	run.only_one_wall_first_layer = extras.only_one_wall_first_layer
	run.seam_gap_percent = extras.seam_gap_percent
	run.staggered_inner_seams = extras.staggered_inner_seams
	run.ensure_vertical_shells = extras.ensure_vertical_shells
	run.detect_thin_wall = extras.detect_thin_wall
	run.top_surface_concentric = extras.top_surface_pattern == "concentric"
	run.bottom_surface_concentric = extras.bottom_surface_pattern == "concentric"
	if extras.top_surface_flow_ratio > 0 && extras.top_surface_flow_ratio != 1.0 {
		run.top_surface_flow_ppm = profiles.Ratio_Ppm(u32(math.round(extras.top_surface_flow_ratio * f64(profiles.RATIO_SCALE))))
	}
	if extras.bottom_surface_flow_ratio > 0 && extras.bottom_surface_flow_ratio != 1.0 {
		run.bottom_surface_flow_ppm = profiles.Ratio_Ppm(u32(math.round(extras.bottom_surface_flow_ratio * f64(profiles.RATIO_SCALE))))
	}
	run.infill_direction_deg = extras.infill_direction_deg
	run.infill_wall_overlap_percent = extras.infill_wall_overlap_percent
	run.infill_combination_layers = extras.infill_combination_layers if extras.infill_combination_layers >= 1 else 1
	run.minimum_sparse_infill_area_um2 = i64(math.round(extras.minimum_sparse_infill_area_mm2 * 1_000_000.0))
	run.thick_bridges = extras.thick_bridges
	switch extras.gap_fill_target {
	case "nowhere":    run.gap_fill_target = 1
	case "top_bottom": run.gap_fill_target = 2
	case:              run.gap_fill_target = 0
	}
	spd_um :: proc(v: f64) -> profiles.Speed_Um_Per_Second {
		return profiles.Speed_Um_Per_Second(i64(math.round(v * 1000.0)))
	}
	acc_um :: proc(a: f64) -> profiles.Acceleration_Um_Per_Second_Squared {
		return profiles.Acceleration_Um_Per_Second_Squared(i64(math.round(a * 1000.0)))
	}
	run.initial_layer_speed_um_s = spd_um(extras.initial_layer_speed_mm_s)
	run.initial_layer_infill_speed_um_s = spd_um(extras.initial_layer_infill_speed_mm_s)
	run.outer_wall_speed_um_s = spd_um(extras.outer_wall_speed_mm_s)
	run.inner_wall_speed_um_s = spd_um(extras.inner_wall_speed_mm_s)
	run.top_surface_speed_um_s = spd_um(extras.top_surface_speed_mm_s)
	run.internal_solid_speed_um_s = spd_um(extras.internal_solid_infill_speed_mm_s)
	run.small_perimeter_speed_um_s = spd_um(extras.small_perimeter_speed_mm_s)
	if extras.small_perimeter_speed_mm_s > 0 && extras.small_perimeter_threshold_mm > 0 {
		run.small_perimeter_threshold_um = contracts.Micrometres(i64(math.round(extras.small_perimeter_threshold_mm * 2.0 * math.PI * 1000.0)))
	}
	run.overhang_tier_speeds_um_s = {
		spd_um(extras.overhang_1_4_speed_mm_s),
		spd_um(extras.overhang_2_4_speed_mm_s),
		spd_um(extras.overhang_3_4_speed_mm_s),
		spd_um(extras.overhang_4_4_speed_mm_s),
	}
	run.initial_layer_accel_um_s2 = acc_um(extras.initial_layer_accel_mm_s2)
	run.initial_layer_travel_accel_um_s2 = acc_um(extras.initial_layer_travel_accel_mm_s2)
	run.outer_wall_accel_um_s2 = acc_um(extras.outer_wall_accel_mm_s2)
	run.inner_wall_accel_um_s2 = acc_um(extras.inner_wall_accel_mm_s2)
	run.top_surface_accel_um_s2 = acc_um(extras.top_surface_accel_mm_s2)
	run.internal_solid_accel_um_s2 = acc_um(extras.internal_solid_accel_mm_s2)
	run.bridge_accel_um_s2 = acc_um(extras.bridge_accel_mm_s2)
	if extras.accel_to_decel_enable {
		run.accel_to_decel_pct = i64(math.round(clamp(extras.accel_to_decel_factor_percent, 10.0, 100.0)))
	}
	run.vase_mode = config.vase_mode || extras.vase_mode
	switch extras.fuzzy_skin_mode {
	case "contour":   run.fuzzy_skin_mode = .Contour
	case "all":       run.fuzzy_skin_mode = .All
	case "all_walls": run.fuzzy_skin_mode = .All_Walls
	case:             run.fuzzy_skin_mode = .All if config.fuzzy_skin else .None
	}
	run.fuzzy_skin_enabled = config.fuzzy_skin || run.fuzzy_skin_mode != .None
	if extras.fuzzy_skin_thickness_mm > 0 {
		run.fuzzy_thickness_um = contracts.Micrometres(i64(math.round(extras.fuzzy_skin_thickness_mm*1000.0)))
	}
	if extras.fuzzy_skin_point_distance_mm > 0 {
		run.fuzzy_point_dist_um = contracts.Micrometres(i64(math.round(extras.fuzzy_skin_point_distance_mm*1000.0)))
	}
	run.fuzzy_first_layer = extras.fuzzy_skin_first_layer
	run.reduce_crossing_wall = extras.reduce_crossing_wall
	run.max_travel_detour_distance_um = contracts.Micrometres(i64(math.round(extras.max_travel_detour_distance_mm*1000.0)))
	run.reduce_infill_retraction = extras.reduce_infill_retraction
	run.modifiers = config.modifiers
	run.pause_layers = config.pause_layers
	run.color_change_layers = config.color_change_layers
	run.object_name = config.object_name
	return resolved, run, "", true
}
