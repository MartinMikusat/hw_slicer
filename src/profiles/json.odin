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
	seam_position:                 string, // "aligned" | "rear" | "sharpest" | "nearest"
	wipe_distance_mm:              f64,
	overhang_slowdown_enabled:     bool,
	overhang_speed_percent:        u32,
	// Milestone 3
	infill_pattern:                string, // "rectilinear"|"grid"|"triangles"|"gyroid"|"cubic"|"honeycomb"|"lightning"
	monotonic_skin:                bool,
	ironing_enabled:               bool,
	ironing_spacing_mm:            f64,
	ironing_flow_percent:          u32,
	arc_fitting_enabled:           bool,
	arc_tolerance_mm:              f64,
	variable_walls_enabled:        bool,
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
	ironing_spacing_mm:            f64,
	ironing_flow_percent:          u32,
	arc_fitting_enabled:           bool,
	arc_tolerance_mm:              f64,
	variable_walls_enabled:        bool,
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
	raw: Printer_JSON
	if err := json.unmarshal(bytes, &raw, allocator = context.temp_allocator); err != nil {
		return {}, .Parse_Failed
	}
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
		support_expansion            = 0,
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
	seam_pos := raw.seam_position
	if len(seam_pos) == 0 {seam_pos = "aligned"}
	infill_pat := raw.infill_pattern
	if len(infill_pat) == 0 {infill_pat = "gyroid"}
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
		ironing_enabled               = raw.ironing_enabled,
		ironing_spacing_mm            = raw.ironing_spacing_mm if raw.ironing_spacing_mm > 0 else 0.15,
		ironing_flow_percent          = raw.ironing_flow_percent if raw.ironing_flow_percent > 0 else 15,
		arc_fitting_enabled           = raw.arc_fitting_enabled,
		arc_tolerance_mm              = raw.arc_tolerance_mm if raw.arc_tolerance_mm > 0 else 0.02,
		variable_walls_enabled        = raw.variable_walls_enabled,
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
		return .Invalid_Override_Value
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
		pats := [?]string{"rectilinear", "grid", "triangles", "gyroid", "cubic", "honeycomb", "lightning"}
		for p in pats {
			if strings.equal_fold(val, p) {
				extras.infill_pattern = p
				return .None
			}
		}
		return .Invalid_Override_Value
	}
	if key == "monotonic_skin" {
		extras.monotonic_skin = strings.equal_fold(val, "true") || val == "1"
		return .None
	}
	if key == "ironing" || key == "ironing_enabled" {
		extras.ironing_enabled = strings.equal_fold(val, "true") || val == "1"
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
	case "arc_tolerance", "arc_tolerance_mm":
		extras.arc_tolerance_mm = max(0.005, num)
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
