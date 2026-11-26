package profiles

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"

import contracts "../contracts"

Profile_JSON_Error :: enum u8 {
	None,
	Read_Failed,
	Parse_Failed,
	Invalid_Field,
	Unknown_Override,
	Invalid_Override_Value,
	Resolve_Failed,
}

Process_JSON_Extras :: struct {
	infill_density_percent:        f64,
	skirt_loops:                   u32,
	skirt_distance_mm:             f64,
	skirt_height_layers:           u32,
	brim_width_mm:                 f64,
	brim_gap_mm:                   f64,
	brim_inner:                    bool,
	elephant_foot_compensation_mm: f64,
	seam_position:                 string, // "aligned" | "rear" | "sharpest" | "nearest" | "random"
	wipe_distance_mm:              f64,
	overhang_slowdown_enabled:     bool,
	overhang_speed_percent:        u32,
	// Milestone 3
	infill_pattern:                string, // "rectilinear"|"grid"|"triangles"|"gyroid"|"cubic"|"honeycomb"|"lightning"
	monotonic_skin:                bool,
	ironing_enabled:               bool,
	ironing_type:                  string, // "none" | "top" | "topmost" | "all_solid"
	ironing_spacing_mm:            f64,
	ironing_flow_percent:          u32,
	ironing_speed_mm_s:            f64,
	ironing_inset_mm:              f64,
	arc_fitting_enabled:           bool,
	arc_tolerance_mm:              f64,
	variable_walls_enabled:        bool,
	// Milestone 4
	support_style:                 string, // "tree" | "grid"
	adaptive_layers:               bool,
	// OrcaSlicer Quality parity
	initial_layer_line_width_mm:         f64,
	outer_wall_line_width_mm:            f64,
	inner_wall_line_width_mm:            f64,
	top_surface_line_width_mm:           f64,
	internal_solid_infill_line_width_mm: f64,
	sparse_infill_line_width_mm:         f64,
	support_line_width_mm:               f64,
	resolution_mm:                       f64,
	xy_contour_compensation_mm:          f64,
	xy_hole_compensation_mm:             f64,
	precise_outer_wall:                  bool,
	wall_sequence:                       string, // "inner_outer" | "outer_inner" | "inner_outer_inner"
	infill_first:                        bool,
	only_one_wall_top:                   bool,
	only_one_wall_first_layer:           bool,
	seam_gap_percent:                    f64,
	staggered_inner_seams:               bool,
	scarf_seam_enabled:                  bool,
	scarf_length_mm:                     f64,
	scarf_start_height_percent:          u32,
	// OrcaSlicer Strength parity
	ensure_vertical_shells:              bool,
	detect_thin_wall:                    bool,
	top_surface_pattern:                 string, // "monotonic" | "rectilinear" | "concentric"
	bottom_surface_pattern:              string, // "monotonic" | "rectilinear" | "concentric"
	top_surface_flow_ratio:              f64,
	bottom_surface_flow_ratio:           f64,
	bridge_flow_ratio:                   f64,
	infill_direction_deg:                f64,
	infill_wall_overlap_percent:         f64,
	infill_combination_layers:           u32,
	minimum_sparse_infill_area_mm2:      f64,
	bridge_angle_deg:                    f64,
	thick_bridges:                       bool,
	gap_fill_target:                     string, // "everywhere" | "nowhere" | "top_bottom"
	// OrcaSlicer Speed & Acceleration parity
	initial_layer_speed_mm_s:            f64,
	initial_layer_infill_speed_mm_s:     f64,
	outer_wall_speed_mm_s:               f64,
	inner_wall_speed_mm_s:               f64,
	top_surface_speed_mm_s:              f64,
	internal_solid_infill_speed_mm_s:    f64,
	small_perimeter_speed_mm_s:          f64,
	small_perimeter_threshold_mm:        f64,
	overhang_1_4_speed_mm_s:             f64,
	overhang_2_4_speed_mm_s:             f64,
	overhang_3_4_speed_mm_s:             f64,
	overhang_4_4_speed_mm_s:             f64,
	initial_layer_accel_mm_s2:           f64,
	initial_layer_travel_accel_mm_s2:    f64,
	outer_wall_accel_mm_s2:              f64,
	inner_wall_accel_mm_s2:              f64,
	top_surface_accel_mm_s2:             f64,
	internal_solid_accel_mm_s2:          f64,
	bridge_accel_mm_s2:                  f64,
	accel_to_decel_enable:               bool,
	accel_to_decel_factor_percent:       f64,
	// OrcaSlicer Support & Adhesion parity
	enable_supports:                     bool,
	support_expansion_mm:                f64,
	tree_branch_angle_deg:               f64,
	tree_tip_diameter_mm:                f64,
	tree_branch_diameter_mm:             f64,
	tree_branch_distance_mm:             f64,
	brim_type:                           string, // "none" | "outer_only" | "inner_only" | "outer_and_inner"
	min_skirt_length_mm:                 f64,
	draft_shield:                        bool,
	raft_layers:                         u32,
	raft_contact_distance_mm:            f64,
	raft_expansion_mm:                   f64,
	// OrcaSlicer Others parity (Travel, Fuzzy, Spiral Vase)
	reduce_crossing_wall:                bool,
	max_travel_detour_distance_mm:       f64,
	reduce_infill_retraction:            bool,
	vase_mode:                           bool,
	fuzzy_skin_mode:                     string, // "none" | "contour" | "all" | "all_walls"
	fuzzy_skin_thickness_mm:             f64,
	fuzzy_skin_point_distance_mm:        f64,
	fuzzy_skin_first_layer:              bool,
}

@(private = "file")
Printer_JSON :: struct {
	bed_min_x_mm:                    f64,
	bed_max_x_mm:                    f64,
	bed_min_y_mm:                    f64,
	bed_max_y_mm:                    f64,
	bed_min_z_mm:                    f64,
	bed_max_z_mm:                    f64,
	extruder_count:                  u8,
	nozzle_diameter_mm:              f64,
	min_layer_height_mm:             f64,
	max_layer_height_mm:             f64,
	min_line_width_mm:               f64,
	max_line_width_mm:               f64,
	max_speed_mm_s:                  f64,
	max_acceleration_mm_s2:          f64,
	max_extruder_speed_mm_s:         f64,
	max_extruder_acceleration_mm_s2: f64,
	minimum_cruise_ratio:            f64,
}

@(private = "file")
Material_JSON :: struct {
	filament_diameter_mm:      f64,
	density_g_cm3:             f64,
	min_nozzle_temp_c:         i32,
	max_nozzle_temp_c:         i32,
	min_bed_temp_c:            i32,
	max_bed_temp_c:            i32,
	min_fan_percent:           f64,
	max_fan_percent:           f64,
	max_volumetric_flow_mm3_s: f64,
}

@(private = "file")
Process_JSON :: struct {
	first_layer_height_mm:        f64,
	layer_height_mm:              f64,
	perimeter_count:              u32,
	line_width_mm:                f64,
	top_skin_layers:              u32,
	top_skin_thickness_mm:        f64,
	bottom_skin_layers:           u32,
	bottom_skin_thickness_mm:     f64,
	infill_density_percent:       f64,
	nozzle_temp_c:                i32,
	bed_temp_c:                   i32,
	perimeter_speed_mm_s:         f64,
	skin_speed_mm_s:              f64,
	infill_speed_mm_s:            f64,
	gap_speed_mm_s:               f64,
	bridge_speed_mm_s:            f64,
	support_speed_mm_s:           f64,
	support_interface_speed_mm_s: f64,
	travel_speed_mm_s:            f64,
	perimeter_accel_mm_s2:        f64,
	infill_accel_mm_s2:           f64,
	travel_accel_mm_s2:           f64,
	fan_percent:                  f64,
	bridge_fan_percent:           f64,
	min_layer_time_s:             f64,
	min_print_speed_mm_s:         f64,
	retraction_distance_mm:       f64,
	min_retraction_travel_mm:     f64,
	retraction_speed_mm_s:        f64,
	recovery_speed_mm_s:          f64,
	retraction_accel_mm_s2:       f64,
	support_mode:                 string,
	support_overhang_angle_deg:   f64,
	support_clearance_xy_mm:      f64,
	support_clearance_z_mm:       f64,
	support_density_percent:       f64,
	support_interface_layers:      u32,
	support_interface_spacing_mm:  f64,
	skirt_loops:                   u32,
	skirt_distance_mm:             f64,
	skirt_height_layers:           u32,
	brim_width_mm:                 f64,
	brim_gap_mm:                   f64,
	brim_inner:                    bool,
	elephant_foot_compensation_mm: f64,
	seam_position:                 string,
	z_hop_mm:                      f64,
	wipe_distance_mm:              f64,
	overhang_slowdown_enabled:     bool,
	overhang_speed_percent:        u32,
	// Milestone 3
	infill_pattern:                string, // "rectilinear"|"grid"|"triangles"|"gyroid"|"cubic"|"honeycomb"|"lightning"
	monotonic_skin:                bool,
	ironing_enabled:               bool,
	ironing_type:                  string, // "none" | "top" | "topmost" | "all_solid"
	ironing_spacing_mm:            f64,
	ironing_flow_percent:          u32,
	ironing_speed_mm_s:            f64,
	ironing_inset_mm:              f64,
	arc_fitting_enabled:           bool,
	arc_tolerance_mm:              f64,
	variable_walls_enabled:        bool,
	// Milestone 4
	support_style:                 string, // "tree" | "grid"
	adaptive_layers:               bool,
	// OrcaSlicer Quality parity
	initial_layer_line_width_mm:         f64,
	outer_wall_line_width_mm:            f64,
	inner_wall_line_width_mm:            f64,
	top_surface_line_width_mm:           f64,
	internal_solid_infill_line_width_mm: f64,
	sparse_infill_line_width_mm:         f64,
	support_line_width_mm:               f64,
	resolution_mm:                       f64,
	xy_contour_compensation_mm:          f64,
	xy_hole_compensation_mm:             f64,
	precise_outer_wall:                  bool,
	wall_sequence:                       string, // "inner_outer" | "outer_inner" | "inner_outer_inner"
	infill_first:                        bool,
	only_one_wall_top:                   bool,
	only_one_wall_first_layer:           bool,
	seam_gap_percent:                    f64,
	staggered_inner_seams:               bool,
	scarf_seam_enabled:                  bool,
	scarf_length_mm:                     f64,
	scarf_start_height_percent:          u32,
	// OrcaSlicer Strength parity
	ensure_vertical_shells:              ^bool,
	detect_thin_wall:                    ^bool,
	top_surface_pattern:                 string, // "monotonic" | "rectilinear" | "concentric"
	bottom_surface_pattern:              string, // "monotonic" | "rectilinear" | "concentric"
	top_surface_flow_ratio:              f64,
	bottom_surface_flow_ratio:           f64,
	bridge_flow_ratio:                   f64,
	infill_direction_deg:                ^f64,
	infill_wall_overlap_percent:         f64,
	infill_combination_layers:           u32,
	minimum_sparse_infill_area_mm2:      f64,
	bridge_angle_deg:                    f64,
	thick_bridges:                       bool,
	gap_fill_target:                     string, // "everywhere" | "nowhere" | "top_bottom"
	// OrcaSlicer Speed & Acceleration parity
	initial_layer_speed_mm_s:            f64,
	initial_layer_infill_speed_mm_s:     f64,
	outer_wall_speed_mm_s:               f64,
	inner_wall_speed_mm_s:               f64,
	top_surface_speed_mm_s:              f64,
	internal_solid_infill_speed_mm_s:    f64,
	small_perimeter_speed_mm_s:          f64,
	small_perimeter_threshold_mm:        f64,
	overhang_1_4_speed_mm_s:             f64,
	overhang_2_4_speed_mm_s:             f64,
	overhang_3_4_speed_mm_s:             f64,
	overhang_4_4_speed_mm_s:             f64,
	initial_layer_accel_mm_s2:           f64,
	initial_layer_travel_accel_mm_s2:    f64,
	outer_wall_accel_mm_s2:              f64,
	inner_wall_accel_mm_s2:              f64,
	top_surface_accel_mm_s2:             f64,
	internal_solid_accel_mm_s2:          f64,
	bridge_accel_mm_s2:                  f64,
	accel_to_decel_enable:               bool,
	accel_to_decel_factor_percent:       f64,
	// OrcaSlicer Support & Adhesion parity
	enable_supports:                     bool,
	support_expansion_mm:                f64,
	tree_branch_angle_deg:               f64,
	tree_tip_diameter_mm:                f64,
	tree_branch_diameter_mm:             f64,
	tree_branch_distance_mm:             f64,
	brim_type:                           string, // "none" | "outer_only" | "inner_only" | "outer_and_inner"
	min_skirt_length_mm:                 f64,
	draft_shield:                        bool,
	raft_layers:                         u32,
	raft_contact_distance_mm:            f64,
	raft_expansion_mm:                   f64,
	// OrcaSlicer Others parity (Travel, Fuzzy, Spiral Vase)
	reduce_crossing_wall:                bool,
	max_travel_detour_distance_mm:       f64,
	reduce_infill_retraction:            bool,
	vase_mode:                           bool,
	fuzzy_skin_mode:                     string, // "none" | "contour" | "all" | "all_walls"
	fuzzy_skin_thickness_mm:             f64,
	fuzzy_skin_point_distance_mm:        f64,
	fuzzy_skin_first_layer:              bool,
}

@(private = "file")
mm_to_um :: proc(mm: f64) -> contracts.Micrometres {
	return contracts.Micrometres(i64(math.round(mm*1000.0)))
}

@(private = "file")
mm_s_to_um_s :: proc(v: f64) -> Speed_Um_Per_Second {
	return Speed_Um_Per_Second(i64(math.round(v*1000.0)))
}

@(private = "file")
mm_s2_to_um_s2 :: proc(a: f64) -> Acceleration_Um_Per_Second_Squared {
	return Acceleration_Um_Per_Second_Squared(i64(math.round(a*1000.0)))
}

@(private = "file")
pct_to_ppm :: proc(pct: f64) -> Ratio_Ppm {
	return Ratio_Ppm(u32(math.round(clamp(pct, 0, 100)*10_000.0)))
}

profiles_default_klipper_dialect :: proc() -> Dialect_Profile {
	return Dialect_Profile{
		schema_version        = DIALECT_PROFILE_SCHEMA_VERSION,
		dialect               = .Klipper,
		coordinate_mode       = .Absolute,
		extrusion_mode        = .Relative,
		xy_decimal_places     = 3,
		z_decimal_places      = 3,
		e_decimal_places      = 5,
		feed_decimal_places   = 0,
		line_ending           = .LF,
		line_numbers          = false,
		checksums             = false,
		acceleration_commands = .Profile_Approved,
		output_mode           = .File,
		emit_layer_comments   = true,
	}
}

printer_profile_load_json :: proc(
	path: string,
) -> (Printer_Profile, Profile_JSON_Error) {
	bytes, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {return {}, .Read_Failed}
	raw := Printer_JSON{minimum_cruise_ratio = KLIPPER_DEFAULT_MINIMUM_CRUISE_RATIO}
	if err := json.unmarshal(bytes, &raw, allocator = context.temp_allocator); err != nil {
		return {}, .Parse_Failed
	}
	if raw.minimum_cruise_ratio < 0 || raw.minimum_cruise_ratio >= 1 {return {}, .Parse_Failed}
	return Printer_Profile{
		schema_version                = PRINTER_PROFILE_SCHEMA_VERSION,
		axis_minimum_x                = mm_to_um(raw.bed_min_x_mm),
		axis_maximum_x                = mm_to_um(raw.bed_max_x_mm),
		axis_minimum_y                = mm_to_um(raw.bed_min_y_mm),
		axis_maximum_y                = mm_to_um(raw.bed_max_y_mm),
		axis_minimum_z                = mm_to_um(raw.bed_min_z_mm),
		axis_maximum_z                = mm_to_um(raw.bed_max_z_mm),
		extruder_count                = raw.extruder_count,
		nozzle_diameter               = mm_to_um(raw.nozzle_diameter_mm),
		minimum_layer_height          = mm_to_um(raw.min_layer_height_mm),
		maximum_layer_height          = mm_to_um(raw.max_layer_height_mm),
		minimum_line_width            = mm_to_um(raw.min_line_width_mm),
		maximum_line_width            = mm_to_um(raw.max_line_width_mm),
		maximum_speed                 = mm_s_to_um_s(raw.max_speed_mm_s),
		maximum_acceleration          = mm_s2_to_um_s2(raw.max_acceleration_mm_s2),
		maximum_extruder_speed        = mm_s_to_um_s(raw.max_extruder_speed_mm_s),
		maximum_extruder_acceleration = mm_s2_to_um_s2(raw.max_extruder_acceleration_mm_s2),
		minimum_cruise_ratio          = Ratio_Ppm(u32(math.round(raw.minimum_cruise_ratio*f64(RATIO_SCALE)))),
	}, .None
}

material_profile_load_json :: proc(
	path: string,
) -> (Material_Profile, Profile_JSON_Error) {
	bytes, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {return {}, .Read_Failed}
	raw: Material_JSON
	if err := json.unmarshal(bytes, &raw, allocator = context.temp_allocator); err != nil {
		return {}, .Parse_Failed
	}
	return Material_Profile{
		schema_version             = MATERIAL_PROFILE_SCHEMA_VERSION,
		filament_diameter          = mm_to_um(raw.filament_diameter_mm),
		density                    = Density_Milligrams_Per_Cubic_Centimetre(u32(math.round(raw.density_g_cm3*1000.0))),
		minimum_nozzle_temperature = Temperature_Celsius(raw.min_nozzle_temp_c),
		maximum_nozzle_temperature = Temperature_Celsius(raw.max_nozzle_temp_c),
		minimum_bed_temperature    = Temperature_Celsius(raw.min_bed_temp_c),
		maximum_bed_temperature    = Temperature_Celsius(raw.max_bed_temp_c),
		minimum_fan_ratio          = pct_to_ppm(raw.min_fan_percent),
		maximum_fan_ratio          = pct_to_ppm(raw.max_fan_percent),
		maximum_volumetric_flow    = Volume_Rate_Cubic_Micrometres_Per_Second(i64(math.round(raw.max_volumetric_flow_mm3_s*1_000_000_000.0))),
	}, .None
}

process_profile_load_json :: proc(
	path: string,
	printer: Printer_Profile,
) -> (Process_Profile, Process_JSON_Extras, Profile_JSON_Error) {
	bytes, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {return {}, {}, .Read_Failed}
	raw: Process_JSON
	if err := json.unmarshal(bytes, &raw, allocator = context.temp_allocator); err != nil {
		return {}, {}, .Parse_Failed
	}
	support_mode := Support_Mode.Build_Plate_Only
	if strings.equal_fold(raw.support_mode, "everywhere") {
		support_mode = .Everywhere
	} else if len(raw.support_mode) > 0 && !strings.equal_fold(raw.support_mode, "build_plate_only") {
		return {}, {}, .Invalid_Field
	}
	fan_ppm := pct_to_ppm(raw.fan_percent)
	bridge_fan_ppm := pct_to_ppm(raw.bridge_fan_percent)
	p_accel := mm_s2_to_um_s2(raw.perimeter_accel_mm_s2)
	i_accel := mm_s2_to_um_s2(raw.infill_accel_mm_s2)
	lw := mm_to_um(raw.line_width_mm)
	flow_one := Ratio_Ppm(RATIO_SCALE)

	p := Process_Profile{
		schema_version               = PROCESS_PROFILE_SCHEMA_VERSION,
		first_layer_height           = mm_to_um(raw.first_layer_height_mm),
		layer_height                 = mm_to_um(raw.layer_height_mm),
		adaptive_layers              = false,
		minimum_adaptive_height      = printer.minimum_layer_height,
		maximum_adaptive_height      = printer.maximum_layer_height,
		perimeter_count              = raw.perimeter_count,
		nominal_line_width           = lw,
		top_skin                     = {thickness = mm_to_um(raw.top_skin_thickness_mm), minimum_layers = raw.top_skin_layers},
		bottom_skin                  = {thickness = mm_to_um(raw.bottom_skin_thickness_mm), minimum_layers = raw.bottom_skin_layers},
		solid_infill_spacing         = lw,
		solid_infill_base_angle      = 45_000,
		solid_infill_angle_step      = 90_000,
		role_overlap                 = .Subtract_Higher_Priority,
		thin_wall_minimum_ratio      = 600_000,
		thin_wall_maximum_ratio      = 1_400_000,
		thin_wall_remainder          = .Preserve_Unprinted,
		gap_allocation               = .One_Then_Two_Lines,
		maximum_centerline_deviation = 50,
		bridge_geometry              = .Previous_Layer_Expanded_Support,
		bridge_anchor_margin         = lw,
		bridge_direction             = .Bounded_Candidate_Score,
		bridge_angle_count           = 4,
		bridge_angles                = {0, 45_000, 90_000, 135_000, 0, 0, 0, 0},
		minimum_bridge_area          = 1_000_000,
		support_demand               = .Mesh_And_Layer_Projection,
		support_mode                 = support_mode,
		support_overhang_angle       = Angle_Millidegrees(i32(math.round(raw.support_overhang_angle_deg*1000.0))),
		support_clearance_xy         = mm_to_um(raw.support_clearance_xy_mm),
		support_clearance_z          = mm_to_um(raw.support_clearance_z_mm),
		support_expansion            = mm_to_um(max(0.0, raw.support_expansion_mm)),
		support_density              = pct_to_ppm(raw.support_density_percent),
		support_pattern              = .Rectilinear,
		support_interface_layers     = raw.support_interface_layers,
		support_interface_spacing    = mm_to_um(raw.support_interface_spacing_mm),
		perimeter                    = {speed = mm_s_to_um_s(raw.perimeter_speed_mm_s), acceleration = p_accel, flow_ratio = flow_one, fan_ratio = fan_ppm},
		skin                         = {speed = mm_s_to_um_s(raw.skin_speed_mm_s), acceleration = p_accel, flow_ratio = flow_one, fan_ratio = fan_ppm},
		sparse_infill                = {speed = mm_s_to_um_s(raw.infill_speed_mm_s), acceleration = i_accel, flow_ratio = flow_one, fan_ratio = fan_ppm},
		gap                          = {speed = mm_s_to_um_s(raw.gap_speed_mm_s), acceleration = p_accel, flow_ratio = flow_one, fan_ratio = fan_ppm},
		bridge                       = {speed = mm_s_to_um_s(raw.bridge_speed_mm_s), acceleration = p_accel, flow_ratio = flow_one, fan_ratio = bridge_fan_ppm},
		support                      = {speed = mm_s_to_um_s(raw.support_speed_mm_s), acceleration = i_accel, flow_ratio = flow_one, fan_ratio = fan_ppm},
		support_interface            = {speed = mm_s_to_um_s(raw.support_interface_speed_mm_s), acceleration = p_accel, flow_ratio = flow_one, fan_ratio = fan_ppm},
		travel                       = {speed = mm_s_to_um_s(raw.travel_speed_mm_s), acceleration = mm_s2_to_um_s2(raw.travel_accel_mm_s2)},
		nozzle_temperature           = Temperature_Celsius(raw.nozzle_temp_c),
		bed_temperature              = Temperature_Celsius(raw.bed_temp_c),
		minimum_layer_time           = Duration_Milliseconds(u32(math.round(raw.min_layer_time_s*1000.0))),
		minimum_layer_time_policy    = .Slowdown_Then_Dwell,
		minimum_print_speed          = mm_s_to_um_s(raw.min_print_speed_mm_s),
		seam                         = .Deterministic_Cost,
		seam_visibility              = .Rear_Maximum_Y,
		retraction                   = .Distance_And_Exterior_Crossing,
		retraction_distance          = mm_to_um(raw.retraction_distance_mm),
		minimum_retraction_travel    = mm_to_um(raw.min_retraction_travel_mm),
		retraction_speed             = mm_s_to_um_s(raw.retraction_speed_mm_s),
		recovery_speed               = mm_s_to_um_s(raw.recovery_speed_mm_s),
		retraction_acceleration      = mm_s2_to_um_s2(raw.retraction_accel_mm_s2),
		travel_policy                = .Direct,
		z_hop_enabled                = raw.z_hop_mm > 0,
		z_hop_height                 = mm_to_um(raw.z_hop_mm) if raw.z_hop_mm > 0 else 0,
		extrusion_accumulation       = .Volume_Then_Fixed_Point_Length,
		extrusion_length_quantum_nm  = 10,
	}
	seam_pos := "aligned"
	switch {
	case strings.equal_fold(raw.seam_position, "rear"):
		seam_pos = "rear"
	case strings.equal_fold(raw.seam_position, "sharpest"), strings.equal_fold(raw.seam_position, "sharpest_corner"):
		seam_pos = "sharpest"
	case strings.equal_fold(raw.seam_position, "nearest"):
		seam_pos = "nearest"
	case strings.equal_fold(raw.seam_position, "random"):
		seam_pos = "random"
	}
	infill_pat := "gyroid"
	for pat in ([?]string{"rectilinear", "grid", "triangles", "gyroid", "cubic", "honeycomb", "lightning", "concentric", "aligned_rectilinear"}) {
		if strings.equal_fold(raw.infill_pattern, pat) {
			infill_pat = pat
			break
		}
	}
	support_style := "tree"
	if strings.equal_fold(raw.support_style, "grid") || strings.equal_fold(raw.support_style, "rectilinear") {
		support_style = "grid"
	}
	top_surf_pat := "monotonic" if raw.monotonic_skin else "rectilinear"
	switch {
	case strings.equal_fold(raw.top_surface_pattern, "monotonic"):
		top_surf_pat = "monotonic"
	case strings.equal_fold(raw.top_surface_pattern, "rectilinear"):
		top_surf_pat = "rectilinear"
	case strings.equal_fold(raw.top_surface_pattern, "concentric"):
		top_surf_pat = "concentric"
	}
	bot_surf_pat := top_surf_pat
	switch {
	case strings.equal_fold(raw.bottom_surface_pattern, "monotonic"):
		bot_surf_pat = "monotonic"
	case strings.equal_fold(raw.bottom_surface_pattern, "rectilinear"):
		bot_surf_pat = "rectilinear"
	case strings.equal_fold(raw.bottom_surface_pattern, "concentric"):
		bot_surf_pat = "concentric"
	}
	gap_target := "everywhere"
	switch {
	case strings.equal_fold(raw.gap_fill_target, "nowhere"):
		gap_target = "nowhere"
	case strings.equal_fold(raw.gap_fill_target, "top_bottom"), strings.equal_fold(raw.gap_fill_target, "topbottom"):
		gap_target = "top_bottom"
	}
	if raw.bridge_flow_ratio > 0 {
		p.bridge.flow_ratio = Ratio_Ppm(u32(math.round(clamp(raw.bridge_flow_ratio, 0.5, 2.0) * f64(RATIO_SCALE))))
	}
	if raw.infill_direction_deg != nil {
		ang := math.mod(raw.infill_direction_deg^, 180.0)
		if ang < 0 {ang += 180.0}
		p.solid_infill_base_angle = Angle_Millidegrees(i32(math.round(ang * 1000.0)))
	}
	if raw.bridge_angle_deg > 0 {
		ang := math.mod(raw.bridge_angle_deg, 180.0)
		if ang < 0 {ang += 180.0}
		p.bridge_angle_count = 1
		p.bridge_angles = {}
		p.bridge_angles[0] = Angle_Millidegrees(i32(math.round(ang * 1000.0)))
	}
	ensure_vert := raw.ensure_vertical_shells^ if raw.ensure_vertical_shells != nil else true
	detect_thin := raw.detect_thin_wall^ if raw.detect_thin_wall != nil else true
	infill_dir := raw.infill_direction_deg^ if raw.infill_direction_deg != nil else 0.0
	ironing_type := "none"
	switch {
	case strings.equal_fold(raw.ironing_type, "top"):
		ironing_type = "top"
	case strings.equal_fold(raw.ironing_type, "topmost"):
		ironing_type = "topmost"
	case strings.equal_fold(raw.ironing_type, "all_solid"):
		ironing_type = "all_solid"
	case raw.ironing_enabled:
		ironing_type = "top"
	}
	wall_seq := "inner_outer"
	switch {
	case strings.equal_fold(raw.wall_sequence, "outer_inner"):
		wall_seq = "outer_inner"
	case strings.equal_fold(raw.wall_sequence, "inner_outer_inner"):
		wall_seq = "inner_outer_inner"
	}
	if raw.initial_layer_line_width_mm > 0 {
		p.first_layer.line_width_enabled = true
		p.first_layer.line_width = mm_to_um(raw.initial_layer_line_width_mm)
	}
	if raw.only_one_wall_first_layer {
		p.first_layer.perimeter_count_enabled = true
		p.first_layer.perimeter_count = 1
	}
	extras := Process_JSON_Extras{
		infill_density_percent        = raw.infill_density_percent if raw.infill_density_percent > 0 else 15.0,
		skirt_loops                   = raw.skirt_loops,
		skirt_distance_mm             = raw.skirt_distance_mm if raw.skirt_distance_mm > 0 else 5.0,
		skirt_height_layers           = raw.skirt_height_layers if raw.skirt_height_layers > 0 else 1,
		brim_width_mm                 = max(0.0, raw.brim_width_mm),
		brim_gap_mm                   = max(0.0, raw.brim_gap_mm),
		brim_inner                    = raw.brim_inner,
		elephant_foot_compensation_mm = max(0.0, raw.elephant_foot_compensation_mm),
		seam_position                 = seam_pos,
		wipe_distance_mm              = max(0.0, raw.wipe_distance_mm),
		overhang_slowdown_enabled     = raw.overhang_slowdown_enabled,
		overhang_speed_percent        = raw.overhang_speed_percent if raw.overhang_speed_percent > 0 else 50,
		infill_pattern                = infill_pat,
		monotonic_skin                = raw.monotonic_skin,
		ironing_enabled               = ironing_type != "none",
		ironing_type                  = ironing_type,
		ironing_spacing_mm            = raw.ironing_spacing_mm if raw.ironing_spacing_mm > 0 else 0.15,
		ironing_flow_percent          = raw.ironing_flow_percent if raw.ironing_flow_percent > 0 else 15,
		ironing_speed_mm_s            = max(0.0, raw.ironing_speed_mm_s),
		ironing_inset_mm              = max(0.0, raw.ironing_inset_mm),
		arc_fitting_enabled           = raw.arc_fitting_enabled,
		arc_tolerance_mm              = raw.arc_tolerance_mm if raw.arc_tolerance_mm > 0 else 0.02,
		variable_walls_enabled        = raw.variable_walls_enabled,
		support_style                 = support_style,
		adaptive_layers               = raw.adaptive_layers,
		initial_layer_line_width_mm         = max(0.0, raw.initial_layer_line_width_mm),
		outer_wall_line_width_mm            = max(0.0, raw.outer_wall_line_width_mm),
		inner_wall_line_width_mm            = max(0.0, raw.inner_wall_line_width_mm),
		top_surface_line_width_mm           = max(0.0, raw.top_surface_line_width_mm),
		internal_solid_infill_line_width_mm = max(0.0, raw.internal_solid_infill_line_width_mm),
		sparse_infill_line_width_mm         = max(0.0, raw.sparse_infill_line_width_mm),
		support_line_width_mm               = max(0.0, raw.support_line_width_mm),
		resolution_mm                       = raw.resolution_mm if raw.resolution_mm > 0 else 0.012,
		xy_contour_compensation_mm          = raw.xy_contour_compensation_mm,
		xy_hole_compensation_mm             = raw.xy_hole_compensation_mm,
		precise_outer_wall                  = raw.precise_outer_wall,
		wall_sequence                       = wall_seq,
		infill_first                        = raw.infill_first,
		only_one_wall_top                   = raw.only_one_wall_top,
		only_one_wall_first_layer           = raw.only_one_wall_first_layer,
		seam_gap_percent                    = clamp(raw.seam_gap_percent, 0.0, 50.0),
		staggered_inner_seams               = raw.staggered_inner_seams,
		scarf_seam_enabled                  = raw.scarf_seam_enabled,
		scarf_length_mm                     = raw.scarf_length_mm if raw.scarf_length_mm > 0 else 15.0,
		scarf_start_height_percent          = raw.scarf_start_height_percent if raw.scarf_start_height_percent > 0 else 10,
		ensure_vertical_shells              = ensure_vert,
		detect_thin_wall                    = detect_thin,
		top_surface_pattern                 = top_surf_pat,
		bottom_surface_pattern              = bot_surf_pat,
		top_surface_flow_ratio              = clamp(raw.top_surface_flow_ratio, 0.5, 2.0) if raw.top_surface_flow_ratio > 0 else 1.0,
		bottom_surface_flow_ratio           = clamp(raw.bottom_surface_flow_ratio, 0.5, 2.0) if raw.bottom_surface_flow_ratio > 0 else 1.0,
		bridge_flow_ratio                   = clamp(raw.bridge_flow_ratio, 0.5, 2.0) if raw.bridge_flow_ratio > 0 else 1.0,
		infill_direction_deg                = infill_dir,
		infill_wall_overlap_percent         = clamp(raw.infill_wall_overlap_percent, 0.0, 100.0),
		infill_combination_layers           = raw.infill_combination_layers if raw.infill_combination_layers >= 1 else 1,
		minimum_sparse_infill_area_mm2      = max(0.0, raw.minimum_sparse_infill_area_mm2),
		bridge_angle_deg                    = max(0.0, raw.bridge_angle_deg),
		thick_bridges                       = raw.thick_bridges,
		gap_fill_target                     = gap_target,
		initial_layer_speed_mm_s            = max(0.0, raw.initial_layer_speed_mm_s),
		initial_layer_infill_speed_mm_s     = max(0.0, raw.initial_layer_infill_speed_mm_s),
		outer_wall_speed_mm_s               = max(0.0, raw.outer_wall_speed_mm_s),
		inner_wall_speed_mm_s               = max(0.0, raw.inner_wall_speed_mm_s),
		top_surface_speed_mm_s              = max(0.0, raw.top_surface_speed_mm_s),
		internal_solid_infill_speed_mm_s    = max(0.0, raw.internal_solid_infill_speed_mm_s),
		small_perimeter_speed_mm_s          = max(0.0, raw.small_perimeter_speed_mm_s),
		small_perimeter_threshold_mm        = raw.small_perimeter_threshold_mm if raw.small_perimeter_threshold_mm > 0 else 6.5,
		overhang_1_4_speed_mm_s             = max(0.0, raw.overhang_1_4_speed_mm_s),
		overhang_2_4_speed_mm_s             = max(0.0, raw.overhang_2_4_speed_mm_s),
		overhang_3_4_speed_mm_s             = max(0.0, raw.overhang_3_4_speed_mm_s),
		overhang_4_4_speed_mm_s             = max(0.0, raw.overhang_4_4_speed_mm_s),
		initial_layer_accel_mm_s2           = max(0.0, raw.initial_layer_accel_mm_s2),
		initial_layer_travel_accel_mm_s2    = max(0.0, raw.initial_layer_travel_accel_mm_s2),
		outer_wall_accel_mm_s2              = max(0.0, raw.outer_wall_accel_mm_s2),
		inner_wall_accel_mm_s2              = max(0.0, raw.inner_wall_accel_mm_s2),
		top_surface_accel_mm_s2             = max(0.0, raw.top_surface_accel_mm_s2),
		internal_solid_accel_mm_s2          = max(0.0, raw.internal_solid_accel_mm_s2),
		bridge_accel_mm_s2                  = max(0.0, raw.bridge_accel_mm_s2),
		accel_to_decel_enable               = raw.accel_to_decel_enable,
		accel_to_decel_factor_percent       = clamp(raw.accel_to_decel_factor_percent, 10.0, 100.0) if raw.accel_to_decel_factor_percent > 0 else 50.0,
		enable_supports                     = raw.enable_supports,
		support_expansion_mm                = max(0.0, raw.support_expansion_mm),
		tree_branch_angle_deg               = clamp(raw.tree_branch_angle_deg, 10.0, 70.0) if raw.tree_branch_angle_deg > 0 else 45.0,
		tree_tip_diameter_mm                = max(0.4, raw.tree_tip_diameter_mm) if raw.tree_tip_diameter_mm > 0 else 1.6,
		tree_branch_diameter_mm             = max(2.0, raw.tree_branch_diameter_mm) if raw.tree_branch_diameter_mm > 0 else 12.0,
		tree_branch_distance_mm             = max(1.0, raw.tree_branch_distance_mm) if raw.tree_branch_distance_mm > 0 else 4.0,
		brim_type                           = raw.brim_type,
		min_skirt_length_mm                 = max(0.0, raw.min_skirt_length_mm),
		draft_shield                        = raw.draft_shield,
		raft_layers                         = min(raw.raft_layers, u32(10)),
		raft_contact_distance_mm            = raw.raft_contact_distance_mm if raw.raft_contact_distance_mm > 0 else 0.1,
		raft_expansion_mm                   = raw.raft_expansion_mm if raw.raft_expansion_mm > 0 else 2.0,
		reduce_crossing_wall                = raw.reduce_crossing_wall,
		max_travel_detour_distance_mm       = max(0.0, raw.max_travel_detour_distance_mm),
		reduce_infill_retraction            = raw.reduce_infill_retraction,
		vase_mode                           = raw.vase_mode,
		fuzzy_skin_mode                     = raw.fuzzy_skin_mode if len(raw.fuzzy_skin_mode) > 0 else "none",
		fuzzy_skin_thickness_mm             = raw.fuzzy_skin_thickness_mm if raw.fuzzy_skin_thickness_mm > 0 else 0.3,
		fuzzy_skin_point_distance_mm        = raw.fuzzy_skin_point_distance_mm if raw.fuzzy_skin_point_distance_mm > 0 else 0.8,
		fuzzy_skin_first_layer              = raw.fuzzy_skin_first_layer,
	}
	return p, extras, .None
}

// Applies a CLI `--set key=value` override onto the loaded process/extras before `profiles_resolve`.
profile_apply_override :: proc(
	process: ^Process_Profile,
	extras: ^Process_JSON_Extras,
	key, val: string,
) -> Profile_JSON_Error {
	if key == "support_mode" {
		if strings.equal_fold(val, "everywhere") {
			process.support_mode = .Everywhere
			return .None
		}
		if strings.equal_fold(val, "build_plate_only") {
			process.support_mode = .Build_Plate_Only
			return .None
		}
		return .Invalid_Override_Value
	}
	if key == "seam_position" || key == "seam" {
		if strings.equal_fold(val, "aligned") {
			extras.seam_position = "aligned"
			return .None
		}
		if strings.equal_fold(val, "rear") {
			extras.seam_position = "rear"
			return .None
		}
		if strings.equal_fold(val, "sharpest") || strings.equal_fold(val, "sharpest_corner") {
			extras.seam_position = "sharpest"
			return .None
		}
		if strings.equal_fold(val, "nearest") {
			extras.seam_position = "nearest"
			return .None
		}
		if strings.equal_fold(val, "random") {
			extras.seam_position = "random"
			return .None
		}
		return .Invalid_Override_Value
	}
	if key == "wall_sequence" {
		if strings.equal_fold(val, "inner_outer") {
			extras.wall_sequence = "inner_outer"
			return .None
		}
		if strings.equal_fold(val, "outer_inner") {
			extras.wall_sequence = "outer_inner"
			return .None
		}
		if strings.equal_fold(val, "inner_outer_inner") {
			extras.wall_sequence = "inner_outer_inner"
			return .None
		}
		return .Invalid_Override_Value
	}
	if key == "ironing_type" {
		switch {
		case strings.equal_fold(val, "none"), strings.equal_fold(val, "no_ironing"):
			extras.ironing_type = "none"
			extras.ironing_enabled = false
			return .None
		case strings.equal_fold(val, "top"):
			extras.ironing_type = "top"
			extras.ironing_enabled = true
			return .None
		case strings.equal_fold(val, "topmost"):
			extras.ironing_type = "topmost"
			extras.ironing_enabled = true
			return .None
		case strings.equal_fold(val, "all_solid"):
			extras.ironing_type = "all_solid"
			extras.ironing_enabled = true
			return .None
		}
		return .Invalid_Override_Value
	}
	if key == "precise_outer_wall" {
		extras.precise_outer_wall = strings.equal_fold(val, "true") || val == "1"
		return .None
	}
	if key == "infill_first" || key == "is_infill_first" {
		extras.infill_first = strings.equal_fold(val, "true") || val == "1"
		return .None
	}
	if key == "only_one_wall_top" {
		extras.only_one_wall_top = strings.equal_fold(val, "true") || val == "1"
		return .None
	}
	if key == "only_one_wall_first_layer" {
		on := strings.equal_fold(val, "true") || val == "1"
		extras.only_one_wall_first_layer = on
		process.first_layer.perimeter_count_enabled = on
		process.first_layer.perimeter_count = 1 if on else 0
		return .None
	}
	if key == "staggered_inner_seams" {
		extras.staggered_inner_seams = strings.equal_fold(val, "true") || val == "1"
		return .None
	}
	if key == "scarf_seam" || key == "scarf_seam_enabled" {
		extras.scarf_seam_enabled = strings.equal_fold(val, "true") || val == "1"
		return .None
	}
	if key == "brim_inner" {
		extras.brim_inner = strings.equal_fold(val, "true") || val == "1"
		return .None
	}
	if key == "overhang_slowdown" || key == "overhang_slowdown_enabled" {
		extras.overhang_slowdown_enabled = strings.equal_fold(val, "true") || val == "1"
		return .None
	}
	if key == "infill_pattern" {
		pats := [?]string{"rectilinear", "grid", "triangles", "gyroid", "cubic", "honeycomb", "lightning", "concentric", "aligned_rectilinear"}
		for p in pats {
			if strings.equal_fold(val, p) {
				extras.infill_pattern = p
				return .None
			}
		}
		return .Invalid_Override_Value
	}
	if key == "top_surface_pattern" {
		for p in ([?]string{"monotonic", "rectilinear", "concentric"}) {
			if strings.equal_fold(val, p) {
				extras.top_surface_pattern = p
				extras.monotonic_skin = p == "monotonic"
				return .None
			}
		}
		return .Invalid_Override_Value
	}
	if key == "bottom_surface_pattern" {
		for p in ([?]string{"monotonic", "rectilinear", "concentric"}) {
			if strings.equal_fold(val, p) {
				extras.bottom_surface_pattern = p
				return .None
			}
		}
		return .Invalid_Override_Value
	}
	if key == "gap_fill_target" {
		switch {
		case strings.equal_fold(val, "everywhere"):
			extras.gap_fill_target = "everywhere"
			return .None
		case strings.equal_fold(val, "nowhere"):
			extras.gap_fill_target = "nowhere"
			return .None
		case strings.equal_fold(val, "top_bottom"), strings.equal_fold(val, "topbottom"):
			extras.gap_fill_target = "top_bottom"
			return .None
		}
		return .Invalid_Override_Value
	}
	if key == "ensure_vertical_shells" || key == "ensure_vertical_shell_thickness" {
		extras.ensure_vertical_shells = strings.equal_fold(val, "true") || val == "1"
		return .None
	}
	if key == "detect_thin_wall" {
		extras.detect_thin_wall = strings.equal_fold(val, "true") || val == "1"
		return .None
	}
	if key == "thick_bridges" {
		extras.thick_bridges = strings.equal_fold(val, "true") || val == "1"
		return .None
	}
	if key == "accel_to_decel_enable" {
		extras.accel_to_decel_enable = strings.equal_fold(val, "true") || val == "1"
		return .None
	}
	if key == "enable_supports" || key == "enable_support" {
		extras.enable_supports = strings.equal_fold(val, "true") || val == "1"
		return .None
	}
	if key == "draft_shield" {
		extras.draft_shield = strings.equal_fold(val, "true") || val == "1" || strings.equal_fold(val, "enabled")
		return .None
	}
	if key == "reduce_crossing_wall" || key == "avoid_crossing_walls" {
		extras.reduce_crossing_wall = strings.equal_fold(val, "true") || val == "1"
		return .None
	}
	if key == "reduce_infill_retraction" {
		extras.reduce_infill_retraction = strings.equal_fold(val, "true") || val == "1"
		return .None
	}
	if key == "vase_mode" || key == "spiral_mode" {
		extras.vase_mode = strings.equal_fold(val, "true") || val == "1"
		return .None
	}
	if key == "fuzzy_skin" || key == "fuzzy_skin_mode" {
		switch {
		case strings.equal_fold(val, "none"), strings.equal_fold(val, "false"), val == "0":
			extras.fuzzy_skin_mode = "none"
			return .None
		case strings.equal_fold(val, "contour"), strings.equal_fold(val, "true"), val == "1":
			extras.fuzzy_skin_mode = "contour"
			return .None
		case strings.equal_fold(val, "all"):
			extras.fuzzy_skin_mode = "all"
			return .None
		case strings.equal_fold(val, "all_walls"):
			extras.fuzzy_skin_mode = "all_walls"
			return .None
		}
		return .Invalid_Override_Value
	}
	if key == "fuzzy_skin_first_layer" {
		extras.fuzzy_skin_first_layer = strings.equal_fold(val, "true") || val == "1"
		return .None
	}
	if key == "brim_type" {
		switch {
		case strings.equal_fold(val, "none"), strings.equal_fold(val, "no_brim"):
			extras.brim_type = "none"
			return .None
		case strings.equal_fold(val, "outer_only"):
			extras.brim_type = "outer_only"
			extras.brim_inner = false
			return .None
		case strings.equal_fold(val, "inner_only"):
			extras.brim_type = "inner_only"
			extras.brim_inner = true
			return .None
		case strings.equal_fold(val, "outer_and_inner"):
			extras.brim_type = "outer_and_inner"
			extras.brim_inner = true
			return .None
		}
		return .Invalid_Override_Value
	}
	if key == "monotonic_skin" {
		extras.monotonic_skin = strings.equal_fold(val, "true") || val == "1"
		return .None
	}
	if key == "ironing" || key == "ironing_enabled" {
		on := strings.equal_fold(val, "true") || val == "1"
		extras.ironing_enabled = on
		if on && (len(extras.ironing_type) == 0 || extras.ironing_type == "none") {
			extras.ironing_type = "top"
		} else if !on {
			extras.ironing_type = "none"
		}
		return .None
	}
	if key == "arc_fitting" || key == "arc_fitting_enabled" {
		extras.arc_fitting_enabled = strings.equal_fold(val, "true") || val == "1"
		return .None
	}
	if key == "variable_walls" || key == "variable_walls_enabled" {
		extras.variable_walls_enabled = strings.equal_fold(val, "true") || val == "1"
		return .None
	}
	if key == "support_style" {
		if strings.equal_fold(val, "tree") || strings.equal_fold(val, "organic") {
			extras.support_style = "tree"
			return .None
		}
		if strings.equal_fold(val, "grid") || strings.equal_fold(val, "rectilinear") {
			extras.support_style = "grid"
			return .None
		}
		return .Invalid_Override_Value
	}
	if key == "adaptive_layers" {
		extras.adaptive_layers = strings.equal_fold(val, "true") || val == "1"
		return .None
	}
	num, ok := strconv.parse_f64(val)
	if !ok || math.is_nan(num) || math.is_inf(num, 0) {
		return .Invalid_Override_Value
	}
	switch key {
	case "layer_height", "layer_height_mm":
		process.layer_height = mm_to_um(num)
	case "first_layer_height", "first_layer_height_mm":
		process.first_layer_height = mm_to_um(num)
	case "line_width", "line_width_mm":
		lw := mm_to_um(num)
		process.nominal_line_width = lw
		process.solid_infill_spacing = lw
		process.bridge_anchor_margin = lw
	case "perimeters", "perimeter_count":
		if num < 1 {return .Invalid_Override_Value}
		process.perimeter_count = u32(math.round(num))
	case "infill_density", "infill_density_percent":
		extras.infill_density_percent = clamp(num, 0, 100)
	case "nozzle_temp", "nozzle_temp_c":
		process.nozzle_temperature = Temperature_Celsius(i32(math.round(num)))
	case "bed_temp", "bed_temp_c":
		process.bed_temperature = Temperature_Celsius(i32(math.round(num)))
	case "perimeter_speed", "perimeter_speed_mm_s":
		process.perimeter.speed = mm_s_to_um_s(num)
	case "infill_speed", "infill_speed_mm_s":
		process.sparse_infill.speed = mm_s_to_um_s(num)
	case "travel_speed", "travel_speed_mm_s":
		process.travel.speed = mm_s_to_um_s(num)
	case "fan", "fan_percent":
		ppm := pct_to_ppm(num)
		process.perimeter.fan_ratio = ppm
		process.skin.fan_ratio = ppm
		process.sparse_infill.fan_ratio = ppm
		process.gap.fan_ratio = ppm
		process.support.fan_ratio = ppm
		process.support_interface.fan_ratio = ppm
	case "min_layer_time", "min_layer_time_s":
		process.minimum_layer_time = Duration_Milliseconds(u32(math.round(max(0, num)*1000.0)))
	case "support_overhang_angle", "support_overhang_angle_deg":
		process.support_overhang_angle = Angle_Millidegrees(i32(math.round(num*1000.0)))
	case "support_density", "support_density_percent":
		process.support_density = pct_to_ppm(num)
	case "skirt_loops":
		extras.skirt_loops = u32(math.round(max(0.0, num)))
	case "skirt_distance", "skirt_distance_mm":
		extras.skirt_distance_mm = max(0.0, num)
	case "skirt_height", "skirt_height_layers":
		extras.skirt_height_layers = u32(math.round(max(1.0, num)))
	case "brim_width", "brim_width_mm":
		extras.brim_width_mm = max(0.0, num)
	case "brim_gap", "brim_gap_mm":
		extras.brim_gap_mm = max(0.0, num)
	case "elephant_foot", "elephant_foot_compensation_mm":
		extras.elephant_foot_compensation_mm = max(0.0, num)
	case "z_hop", "z_hop_mm":
		if num > 0 {
			process.z_hop_enabled = true
			process.z_hop_height = mm_to_um(num)
		} else {
			process.z_hop_enabled = false
			process.z_hop_height = 0
		}
	case "wipe_distance", "wipe_distance_mm":
		extras.wipe_distance_mm = max(0.0, num)
	case "overhang_speed", "overhang_speed_percent":
		extras.overhang_speed_percent = u32(math.round(clamp(num, 10.0, 100.0)))
	case "ironing_spacing", "ironing_spacing_mm":
		extras.ironing_spacing_mm = max(0.05, num)
	case "ironing_flow", "ironing_flow_percent":
		extras.ironing_flow_percent = u32(math.round(clamp(num, 5.0, 50.0)))
	case "ironing_speed", "ironing_speed_mm_s":
		extras.ironing_speed_mm_s = max(0.0, num)
	case "ironing_inset", "ironing_inset_mm":
		extras.ironing_inset_mm = max(0.0, num)
	case "arc_tolerance", "arc_tolerance_mm":
		extras.arc_tolerance_mm = max(0.005, num)
	case "initial_layer_line_width", "initial_layer_line_width_mm":
		extras.initial_layer_line_width_mm = max(0.0, num)
		if num > 0 {
			process.first_layer.line_width_enabled = true
			process.first_layer.line_width = mm_to_um(num)
		} else {
			process.first_layer.line_width_enabled = false
			process.first_layer.line_width = 0
		}
	case "outer_wall_line_width", "outer_wall_line_width_mm":
		extras.outer_wall_line_width_mm = max(0.0, num)
	case "inner_wall_line_width", "inner_wall_line_width_mm":
		extras.inner_wall_line_width_mm = max(0.0, num)
	case "top_surface_line_width", "top_surface_line_width_mm":
		extras.top_surface_line_width_mm = max(0.0, num)
	case "internal_solid_infill_line_width", "internal_solid_infill_line_width_mm":
		extras.internal_solid_infill_line_width_mm = max(0.0, num)
	case "sparse_infill_line_width", "sparse_infill_line_width_mm":
		extras.sparse_infill_line_width_mm = max(0.0, num)
	case "support_line_width", "support_line_width_mm":
		extras.support_line_width_mm = max(0.0, num)
	case "resolution", "resolution_mm":
		extras.resolution_mm = max(0.0, num)
	case "xy_contour_compensation", "xy_contour_compensation_mm":
		extras.xy_contour_compensation_mm = clamp(num, -5.0, 5.0)
	case "xy_hole_compensation", "xy_hole_compensation_mm":
		extras.xy_hole_compensation_mm = clamp(num, -5.0, 5.0)
	case "seam_gap", "seam_gap_percent":
		extras.seam_gap_percent = clamp(num, 0.0, 50.0)
	case "scarf_length", "scarf_length_mm":
		extras.scarf_length_mm = max(1.0, num)
	case "scarf_start_height", "scarf_start_height_percent":
		extras.scarf_start_height_percent = u32(math.round(clamp(num, 5.0, 50.0)))
	case "top_skin_layers", "top_shell_layers":
		if num < 1 {return .Invalid_Override_Value}
		process.top_skin.minimum_layers = u32(math.round(num))
	case "top_skin_thickness", "top_skin_thickness_mm", "top_shell_thickness":
		if num <= 0 {return .Invalid_Override_Value}
		process.top_skin.thickness = mm_to_um(num)
	case "bottom_skin_layers", "bottom_shell_layers":
		if num < 1 {return .Invalid_Override_Value}
		process.bottom_skin.minimum_layers = u32(math.round(num))
	case "bottom_skin_thickness", "bottom_skin_thickness_mm", "bottom_shell_thickness":
		if num <= 0 {return .Invalid_Override_Value}
		process.bottom_skin.thickness = mm_to_um(num)
	case "top_surface_flow_ratio", "top_solid_infill_flow_ratio":
		extras.top_surface_flow_ratio = clamp(num, 0.5, 2.0)
	case "bottom_surface_flow_ratio", "bottom_solid_infill_flow_ratio":
		extras.bottom_surface_flow_ratio = clamp(num, 0.5, 2.0)
	case "bridge_flow", "bridge_flow_ratio":
		r := clamp(num, 0.5, 2.0)
		extras.bridge_flow_ratio = r
		process.bridge.flow_ratio = Ratio_Ppm(u32(math.round(r * f64(RATIO_SCALE))))
	case "infill_direction", "infill_direction_deg":
		ang := math.mod(num, 180.0)
		if ang < 0 {ang += 180.0}
		extras.infill_direction_deg = ang
		process.solid_infill_base_angle = Angle_Millidegrees(i32(math.round(ang * 1000.0)))
	case "infill_wall_overlap", "infill_wall_overlap_percent":
		extras.infill_wall_overlap_percent = clamp(num, 0.0, 100.0)
	case "infill_combination", "infill_combination_layers":
		extras.infill_combination_layers = u32(math.round(clamp(num, 1.0, 8.0)))
	case "minimum_sparse_infill_area", "minimum_sparse_infill_area_mm2":
		extras.minimum_sparse_infill_area_mm2 = max(0.0, num)
	case "bridge_angle", "bridge_angle_deg":
		extras.bridge_angle_deg = max(0.0, num)
		if num > 0 {
			ang := math.mod(num, 180.0)
			if ang < 0 {ang += 180.0}
			process.bridge_angle_count = 1
			process.bridge_angles = {}
			process.bridge_angles[0] = Angle_Millidegrees(i32(math.round(ang * 1000.0)))
		} else {
			process.bridge_angle_count = 4
			process.bridge_angles = {0, 45_000, 90_000, 135_000, 0, 0, 0, 0}
		}
	case "skin_speed", "skin_speed_mm_s":
		process.skin.speed = mm_s_to_um_s(num)
	case "gap_speed", "gap_speed_mm_s", "gap_infill_speed":
		process.gap.speed = mm_s_to_um_s(num)
	case "bridge_speed", "bridge_speed_mm_s":
		process.bridge.speed = mm_s_to_um_s(num)
	case "support_speed", "support_speed_mm_s":
		process.support.speed = mm_s_to_um_s(num)
	case "support_interface_speed", "support_interface_speed_mm_s":
		process.support_interface.speed = mm_s_to_um_s(num)
	case "min_print_speed", "min_print_speed_mm_s":
		process.minimum_print_speed = mm_s_to_um_s(num)
	case "perimeter_accel", "perimeter_accel_mm_s2":
		a := mm_s2_to_um_s2(num)
		process.perimeter.acceleration = a
		process.skin.acceleration = a
		process.gap.acceleration = a
		process.bridge.acceleration = a
		process.support_interface.acceleration = a
	case "infill_accel", "infill_accel_mm_s2", "default_acceleration":
		a := mm_s2_to_um_s2(num)
		process.sparse_infill.acceleration = a
		process.support.acceleration = a
	case "travel_accel", "travel_accel_mm_s2", "travel_acceleration":
		process.travel.acceleration = mm_s2_to_um_s2(num)
	case "initial_layer_speed", "initial_layer_speed_mm_s":
		extras.initial_layer_speed_mm_s = max(0.0, num)
	case "initial_layer_infill_speed", "initial_layer_infill_speed_mm_s":
		extras.initial_layer_infill_speed_mm_s = max(0.0, num)
	case "outer_wall_speed", "outer_wall_speed_mm_s":
		extras.outer_wall_speed_mm_s = max(0.0, num)
	case "inner_wall_speed", "inner_wall_speed_mm_s":
		extras.inner_wall_speed_mm_s = max(0.0, num)
	case "top_surface_speed", "top_surface_speed_mm_s":
		extras.top_surface_speed_mm_s = max(0.0, num)
	case "internal_solid_infill_speed", "internal_solid_infill_speed_mm_s":
		extras.internal_solid_infill_speed_mm_s = max(0.0, num)
	case "small_perimeter_speed", "small_perimeter_speed_mm_s":
		extras.small_perimeter_speed_mm_s = max(0.0, num)
	case "small_perimeter_threshold", "small_perimeter_threshold_mm":
		extras.small_perimeter_threshold_mm = max(0.0, num)
	case "overhang_1_4_speed", "overhang_1_4_speed_mm_s":
		extras.overhang_1_4_speed_mm_s = max(0.0, num)
	case "overhang_2_4_speed", "overhang_2_4_speed_mm_s":
		extras.overhang_2_4_speed_mm_s = max(0.0, num)
	case "overhang_3_4_speed", "overhang_3_4_speed_mm_s":
		extras.overhang_3_4_speed_mm_s = max(0.0, num)
	case "overhang_4_4_speed", "overhang_4_4_speed_mm_s":
		extras.overhang_4_4_speed_mm_s = max(0.0, num)
	case "initial_layer_accel", "initial_layer_accel_mm_s2", "initial_layer_acceleration":
		extras.initial_layer_accel_mm_s2 = max(0.0, num)
	case "initial_layer_travel_accel", "initial_layer_travel_accel_mm_s2", "initial_layer_travel_acceleration":
		extras.initial_layer_travel_accel_mm_s2 = max(0.0, num)
	case "outer_wall_accel", "outer_wall_accel_mm_s2", "outer_wall_acceleration":
		extras.outer_wall_accel_mm_s2 = max(0.0, num)
	case "inner_wall_accel", "inner_wall_accel_mm_s2", "inner_wall_acceleration":
		extras.inner_wall_accel_mm_s2 = max(0.0, num)
	case "top_surface_accel", "top_surface_accel_mm_s2", "top_surface_acceleration":
		extras.top_surface_accel_mm_s2 = max(0.0, num)
	case "internal_solid_accel", "internal_solid_accel_mm_s2", "internal_solid_infill_acceleration":
		extras.internal_solid_accel_mm_s2 = max(0.0, num)
	case "bridge_accel", "bridge_accel_mm_s2", "bridge_acceleration":
		extras.bridge_accel_mm_s2 = max(0.0, num)
	case "accel_to_decel_factor", "accel_to_decel_factor_percent":
		extras.accel_to_decel_factor_percent = clamp(num, 10.0, 100.0)
	case "support_clearance_xy", "support_clearance_xy_mm", "support_object_xy_distance":
		process.support_clearance_xy = mm_to_um(max(0.0, num))
	case "support_clearance_z", "support_clearance_z_mm", "support_top_z_distance":
		process.support_clearance_z = mm_to_um(max(0.0, num))
	case "support_expansion", "support_expansion_mm":
		extras.support_expansion_mm = max(0.0, num)
		process.support_expansion = mm_to_um(max(0.0, num))
	case "support_interface_layers", "support_interface_top_layers":
		if num < 1 {return .Invalid_Override_Value}
		process.support_interface_layers = u32(math.round(num))
	case "support_interface_spacing", "support_interface_spacing_mm":
		if num <= 0 {return .Invalid_Override_Value}
		process.support_interface_spacing = mm_to_um(num)
	case "tree_branch_angle", "tree_branch_angle_deg", "tree_support_branch_angle":
		extras.tree_branch_angle_deg = clamp(num, 10.0, 70.0)
	case "tree_tip_diameter", "tree_tip_diameter_mm", "tree_support_tip_diameter":
		extras.tree_tip_diameter_mm = max(0.4, num)
	case "tree_branch_diameter", "tree_branch_diameter_mm", "tree_support_branch_diameter":
		extras.tree_branch_diameter_mm = max(2.0, num)
	case "tree_branch_distance", "tree_branch_distance_mm", "tree_support_branch_distance":
		extras.tree_branch_distance_mm = max(1.0, num)
	case "min_skirt_length", "min_skirt_length_mm":
		extras.min_skirt_length_mm = max(0.0, num)
	case "raft_layers":
		extras.raft_layers = u32(math.round(clamp(num, 0.0, 10.0)))
	case "raft_contact_distance", "raft_contact_distance_mm":
		extras.raft_contact_distance_mm = max(0.0, num)
	case "raft_expansion", "raft_expansion_mm":
		extras.raft_expansion_mm = max(0.0, num)
	case "max_travel_detour_distance", "max_travel_detour_distance_mm":
		extras.max_travel_detour_distance_mm = max(0.0, num)
	case "fuzzy_skin_thickness", "fuzzy_skin_thickness_mm":
		extras.fuzzy_skin_thickness_mm = clamp(num, 0.05, 2.0)
	case "fuzzy_skin_point_distance", "fuzzy_skin_point_distance_mm":
		extras.fuzzy_skin_point_distance_mm = clamp(num, 0.1, 5.0)
	case:
		return .Unknown_Override
	}
	return .None
}

// Clamps process motion speeds and accelerations to the selected printer's kinematic limits
// so any process JSON can be combined with any printer JSON cleanly.
profile_fit_printer :: proc(process: ^Process_Profile, printer: Printer_Profile) {
	clamp_role :: proc(r: ^Role_Target, p: Printer_Profile) {
		r.speed = min(r.speed, p.maximum_speed)
		r.acceleration = min(r.acceleration, p.maximum_acceleration)
	}
	clamp_role(&process.perimeter, printer)
	clamp_role(&process.skin, printer)
	clamp_role(&process.sparse_infill, printer)
	clamp_role(&process.gap, printer)
	clamp_role(&process.bridge, printer)
	clamp_role(&process.support, printer)
	clamp_role(&process.support_interface, printer)
	process.travel.speed = min(process.travel.speed, printer.maximum_speed)
	process.travel.acceleration = min(process.travel.acceleration, printer.maximum_acceleration)
	process.minimum_print_speed = min(process.minimum_print_speed, printer.maximum_speed)
	process.retraction_speed = min(process.retraction_speed, printer.maximum_extruder_speed)
	process.recovery_speed = min(process.recovery_speed, printer.maximum_extruder_speed)
	process.retraction_acceleration = min(process.retraction_acceleration, printer.maximum_extruder_acceleration)
}

// Clamps process thermal and fan targets to the selected material's envelope so mixing any
// material JSON (e.g. PETG or ABS) with any process JSON produces a valid resolved profile.
profile_fit_material :: proc(process: ^Process_Profile, material: Material_Profile) {
	process.nozzle_temperature = clamp(process.nozzle_temperature, material.minimum_nozzle_temperature, material.maximum_nozzle_temperature)
	process.bed_temperature = clamp(process.bed_temperature, material.minimum_bed_temperature, material.maximum_bed_temperature)
	clamp_fan :: proc(r: ^Ratio_Ppm, mat: Material_Profile) {
		r^ = clamp(r^, mat.minimum_fan_ratio, mat.maximum_fan_ratio)
	}
	clamp_fan(&process.perimeter.fan_ratio, material)
	clamp_fan(&process.skin.fan_ratio, material)
	clamp_fan(&process.sparse_infill.fan_ratio, material)
	clamp_fan(&process.gap.fan_ratio, material)
	clamp_fan(&process.bridge.fan_ratio, material)
	clamp_fan(&process.support.fan_ratio, material)
	clamp_fan(&process.support_interface.fan_ratio, material)
	// Clamp print speeds to the material's volumetric flow ceiling, quantized to 50 um/s.
	max_h := max(i64(process.first_layer_height), i64(process.layer_height))
	lw := i64(process.nominal_line_width)
	if max_h > 0 && lw > 0 && i64(material.maximum_volumetric_flow) > 0 {
		// Use a conservative rectangular cross-section (lw * max_h) so exact flow stays safely below ceiling.
		raw_v := i64(material.maximum_volumetric_flow) / (lw * max_h)
		max_v := Speed_Um_Per_Second((raw_v / 50) * 50)
		if i64(max_v) > 0 {
			process.perimeter.speed = min(process.perimeter.speed, max_v)
			process.skin.speed = min(process.skin.speed, max_v)
			process.sparse_infill.speed = min(process.sparse_infill.speed, max_v)
			process.gap.speed = min(process.gap.speed, max_v)
			process.bridge.speed = min(process.bridge.speed, max_v)
			process.support.speed = min(process.support.speed, max_v)
			process.support_interface.speed = min(process.support_interface.speed, max_v)
			process.minimum_print_speed = min(process.minimum_print_speed, max_v)
		}
	}
}

profile_json_error_text :: proc(err: Profile_JSON_Error) -> string {
	switch err {
	case .None:                   return "none"
	case .Read_Failed:            return "failed to read profile file"
	case .Parse_Failed:           return "invalid JSON in profile file"
	case .Invalid_Field:          return "invalid field value in profile"
	case .Unknown_Override:       return "unknown --set override key"
	case .Invalid_Override_Value: return "invalid --set override value"
	case .Resolve_Failed:         return "profile validation failed"
	}
	return fmt.tprintf("profile error %v", err)
}
