package profiles

import contracts "../contracts"

profiles_resolve :: proc(
	printer: Printer_Profile,
	material: Material_Profile,
	process: Process_Profile,
	dialect: Dialect_Profile,
) -> (Resolved_Profiles, Profile_Resolve_Error) {
	if error := printer_profile_validate(printer); error != .None {
		return {}, error
	}
	if error := material_profile_validate(material); error != .None {
		return {}, error
	}
	if error := process_profile_validate(process, printer); error != .None {
		return {}, error
	}
	if error := dialect_profile_validate(dialect); error != .None {
		return {}, error
	}
	if !process_thermal_targets_valid(process, material) {
		return {}, .Process_Thermal_Target
	}
	if !process_role_volumetric_targets_valid(process, material) {
		return {}, .Volumetric_Flow_Target
	}

	first_layer := Effective_First_Layer{
		line_width = process.nominal_line_width,
		perimeter_count = process.perimeter_count,
		top_skin = process.top_skin,
		bottom_skin = process.bottom_skin,
	}
	if process.first_layer.line_width_enabled {
		first_layer.line_width = process.first_layer.line_width
	}
	if process.first_layer.perimeter_count_enabled {
		first_layer.perimeter_count = process.first_layer.perimeter_count
	}
	if process.first_layer.top_skin_enabled {
		first_layer.top_skin = process.first_layer.top_skin
	}
	if process.first_layer.bottom_skin_enabled {
		first_layer.bottom_skin = process.first_layer.bottom_skin
	}

	minimum_width, minimum_ok := ratio_scale_micrometres(
		process.nominal_line_width,
		process.thin_wall_minimum_ratio,
	)
	maximum_width, maximum_ok := ratio_scale_micrometres(
		process.nominal_line_width,
		process.thin_wall_maximum_ratio,
	)
	if !minimum_ok || !maximum_ok ||
	   i64(minimum_width) < i64(printer.minimum_line_width) ||
	   i64(maximum_width) > i64(printer.maximum_line_width) {
		return {}, .Process_Thin_Wall_Target
	}

	return {
		printer = printer,
		material = material,
		process = {
			source = process,
			first_layer = first_layer,
			thin_wall_minimum_width = minimum_width,
			thin_wall_maximum_width = maximum_width,
		},
		dialect = dialect,
	}, .None
}

printer_profile_validate :: proc(
	profile: Printer_Profile,
) -> Profile_Resolve_Error {
	if profile.schema_version != PRINTER_PROFILE_SCHEMA_VERSION {
		return .Printer_Schema
	}
	if i64(profile.build_size_x) <= 0 ||
	   i64(profile.build_size_y) <= 0 ||
	   i64(profile.build_size_z) <= 0 ||
	   i64(profile.nozzle_diameter) <= 0 {
		return .Printer_Geometry
	}
	if i64(profile.minimum_layer_height) <= 0 ||
	   i64(profile.maximum_layer_height) <
	   	i64(profile.minimum_layer_height) ||
	   i64(profile.minimum_line_width) <= 0 ||
	   i64(profile.maximum_line_width) <
	   	i64(profile.minimum_line_width) ||
	   i64(profile.maximum_speed) <= 0 ||
	   i64(profile.maximum_acceleration) <= 0 {
		return .Printer_Limits
	}
	return .None
}

material_profile_validate :: proc(
	profile: Material_Profile,
) -> Profile_Resolve_Error {
	if profile.schema_version != MATERIAL_PROFILE_SCHEMA_VERSION {
		return .Material_Schema
	}
	if i64(profile.filament_diameter) <= 0 ||
	   u32(profile.density) == 0 ||
	   i64(profile.maximum_volumetric_flow) <= 0 {
		return .Material_Geometry
	}
	if i32(profile.minimum_nozzle_temperature) < 0 ||
	   i32(profile.maximum_nozzle_temperature) <
	   	i32(profile.minimum_nozzle_temperature) ||
	   i32(profile.minimum_bed_temperature) < 0 ||
	   i32(profile.maximum_bed_temperature) <
	   	i32(profile.minimum_bed_temperature) {
		return .Material_Thermal_Limits
	}
	if u32(profile.minimum_fan_ratio) > RATIO_SCALE ||
	   u32(profile.maximum_fan_ratio) >
	   	RATIO_SCALE ||
	   u32(profile.maximum_fan_ratio) <
	   	u32(profile.minimum_fan_ratio) {
		return .Material_Cooling_Limits
	}
	return .None
}

process_profile_validate :: proc(
	profile: Process_Profile,
	printer: Printer_Profile,
) -> Profile_Resolve_Error {
	if profile.schema_version != PROCESS_PROFILE_SCHEMA_VERSION {
		return .Process_Schema
	}
	if !process_layer_targets_valid(profile, printer) {
		return .Process_Layer_Target
	}
	if !process_shell_targets_valid(profile, printer) {
		return .Process_Shell_Target
	}
	if !process_thin_wall_targets_valid(profile) {
		return .Process_Thin_Wall_Target
	}
	if !process_bridge_targets_valid(profile) {
		return .Process_Bridge_Target
	}
	if !process_support_targets_valid(profile) {
		return .Process_Support_Target
	}
	if !process_motion_targets_valid(profile, printer) {
		return .Process_Motion_Target
	}
	if !process_travel_targets_valid(profile) {
		return .Process_Travel_Target
	}
	if profile.extrusion_accumulation !=
	   	.Volume_Then_Fixed_Point_Length ||
	   profile.extrusion_length_quantum_nm == 0 {
		return .Process_Extrusion_Target
	}
	return .None
}

dialect_profile_validate :: proc(
	profile: Dialect_Profile,
) -> Profile_Resolve_Error {
	if profile.schema_version != DIALECT_PROFILE_SCHEMA_VERSION {
		return .Dialect_Schema
	}
	if profile.dialect != .Marlin_Conservative ||
	   profile.coordinate_mode == .Invalid ||
	   profile.extrusion_mode == .Invalid ||
	   profile.xy_decimal_places > 6 ||
	   profile.z_decimal_places > 6 ||
	   profile.e_decimal_places > 9 ||
	   profile.feed_decimal_places > 3 ||
	   profile.line_ending == .Invalid ||
	   profile.checksums && !profile.line_numbers {
		return .Dialect_Target
	}
	return .None
}

process_layer_targets_valid :: proc(
	profile: Process_Profile,
	printer: Printer_Profile,
) -> bool {
	minimum := i64(printer.minimum_layer_height)
	maximum := i64(printer.maximum_layer_height)
	return i64(profile.first_layer_height) >= minimum &&
	       i64(profile.first_layer_height) <= maximum &&
	       i64(profile.layer_height) >= minimum &&
	       i64(profile.layer_height) <= maximum &&
	       i64(profile.minimum_adaptive_height) >= minimum &&
	       i64(profile.maximum_adaptive_height) <= maximum &&
	       i64(profile.minimum_adaptive_height) <=
	       	i64(profile.maximum_adaptive_height) &&
	       (!profile.adaptive_layers ||
	       	i64(profile.layer_height) >=
	       		i64(profile.minimum_adaptive_height) &&
	       	i64(profile.layer_height) <=
	       		i64(profile.maximum_adaptive_height))
}

process_shell_targets_valid :: proc(
	profile: Process_Profile,
	printer: Printer_Profile,
) -> bool {
	if profile.perimeter_count == 0 ||
	   i64(profile.nominal_line_width) <
	   	i64(printer.minimum_line_width) ||
	   i64(profile.nominal_line_width) >
	   	i64(printer.maximum_line_width) ||
	   !skin_target_valid(profile.top_skin) ||
	   !skin_target_valid(profile.bottom_skin) ||
	   i64(profile.solid_infill_spacing) <= 0 ||
	   !angle_valid(profile.solid_infill_base_angle) ||
	   !angle_valid(profile.solid_infill_angle_step) ||
	   profile.role_overlap != .Subtract_Higher_Priority {
		return false
	}
	override := profile.first_layer
	if override.line_width_enabled {
		if i64(override.line_width) <
		   	i64(printer.minimum_line_width) ||
		   i64(override.line_width) >
		   	i64(printer.maximum_line_width) {
			return false
		}
	} else if i64(override.line_width) != 0 {
		return false
	}
	if override.perimeter_count_enabled {
		if override.perimeter_count == 0 {return false}
	} else if override.perimeter_count != 0 {
		return false
	}
	if override.top_skin_enabled {
		if !skin_target_valid(override.top_skin) {return false}
	} else if i64(override.top_skin.thickness) != 0 ||
	          override.top_skin.minimum_layers != 0 {
		return false
	}
	if override.bottom_skin_enabled {
		if !skin_target_valid(override.bottom_skin) {return false}
	} else if i64(override.bottom_skin.thickness) != 0 ||
	          override.bottom_skin.minimum_layers != 0 {
		return false
	}
	return true
}

process_thin_wall_targets_valid :: proc(profile: Process_Profile) -> bool {
	return u32(profile.thin_wall_minimum_ratio) > 0 &&
	       u32(profile.thin_wall_minimum_ratio) <=
	       	u32(profile.thin_wall_maximum_ratio) &&
	       u32(profile.thin_wall_maximum_ratio) <= RATIO_SCALE*2 &&
	       profile.thin_wall_remainder == .Preserve_Unprinted &&
	       profile.gap_allocation == .One_Then_Two_Lines &&
	       i64(profile.maximum_centerline_deviation) >= 0
}

process_bridge_targets_valid :: proc(profile: Process_Profile) -> bool {
	if profile.bridge_geometry != .Previous_Layer_Expanded_Support ||
	   profile.bridge_direction != .Bounded_Candidate_Score ||
	   i64(profile.bridge_anchor_margin) < 0 ||
	   profile.bridge_angle_count == 0 ||
	   int(profile.bridge_angle_count) > len(profile.bridge_angles) ||
	   i64(profile.minimum_bridge_area) <= 0 {
		return false
	}
	previous := i32(-1)
	for angle, index in profile.bridge_angles {
		if index < int(profile.bridge_angle_count) {
			value := i32(angle)
			if !angle_valid(angle) || value <= previous {return false}
			previous = value
		} else if angle != Angle_Millidegrees(0) {
			return false
		}
	}
	return true
}

process_support_targets_valid :: proc(profile: Process_Profile) -> bool {
	return profile.support_demand == .Mesh_And_Layer_Projection &&
	       profile.support_mode != .Invalid &&
	       i32(profile.support_overhang_angle) > 0 &&
	       i32(profile.support_overhang_angle) < 90_000 &&
	       i64(profile.support_clearance_xy) >= 0 &&
	       i64(profile.support_clearance_z) >= 0 &&
	       i64(profile.support_expansion) >= 0 &&
	       u32(profile.support_density) > 0 &&
	       u32(profile.support_density) <= RATIO_SCALE &&
	       profile.support_pattern == .Rectilinear &&
	       profile.support_interface_layers > 0 &&
	       i64(profile.support_interface_spacing) > 0
}

process_motion_targets_valid :: proc(
	profile: Process_Profile,
	printer: Printer_Profile,
) -> bool {
	roles := [?]Role_Target{
		profile.perimeter,
		profile.skin,
		profile.sparse_infill,
		profile.gap,
		profile.bridge,
		profile.support,
		profile.support_interface,
	}
	for target in roles {
		if !role_target_valid(target, printer) {return false}
	}
	return i64(profile.travel.speed) > 0 &&
	       i64(profile.travel.speed) <= i64(printer.maximum_speed) &&
	       i64(profile.travel.acceleration) > 0 &&
	       i64(profile.travel.acceleration) <=
	       	i64(printer.maximum_acceleration) &&
	       u32(profile.minimum_layer_time) > 0
}

process_thermal_targets_valid :: proc(
	profile: Process_Profile,
	material: Material_Profile,
) -> bool {
	if i32(profile.nozzle_temperature) <
	   	i32(material.minimum_nozzle_temperature) ||
	   i32(profile.nozzle_temperature) >
	   	i32(material.maximum_nozzle_temperature) ||
	   i32(profile.bed_temperature) <
	   	i32(material.minimum_bed_temperature) ||
	   i32(profile.bed_temperature) >
	   	i32(material.maximum_bed_temperature) {
		return false
	}
	roles := [?]Role_Target{
		profile.perimeter,
		profile.skin,
		profile.sparse_infill,
		profile.gap,
		profile.bridge,
		profile.support,
		profile.support_interface,
	}
	for target in roles {
		if u32(target.fan_ratio) < u32(material.minimum_fan_ratio) ||
		   u32(target.fan_ratio) > u32(material.maximum_fan_ratio) {
			return false
		}
	}
	return true
}

process_travel_targets_valid :: proc(profile: Process_Profile) -> bool {
	return profile.seam == .Deterministic_Cost &&
	       profile.retraction == .Distance_And_Exterior_Crossing &&
	       i64(profile.retraction_distance) >= 0 &&
	       i64(profile.minimum_retraction_travel) > 0 &&
	       profile.travel_policy == .Direct &&
	       (!profile.z_hop_enabled &&
	       	i64(profile.z_hop_height) == 0 ||
	        profile.z_hop_enabled &&
	       	i64(profile.z_hop_height) > 0)
}

process_role_volumetric_targets_valid :: proc(
	profile: Process_Profile,
	material: Material_Profile,
) -> bool {
	roles := [?]Role_Target{
		profile.perimeter,
		profile.skin,
		profile.sparse_infill,
		profile.gap,
		profile.bridge,
		profile.support,
		profile.support_interface,
	}
	for target in roles {
		rate, ok := role_target_volume_rate(
			profile.nominal_line_width,
			profile.layer_height,
			target,
		)
		if !ok ||
		   i64(rate) > i64(material.maximum_volumetric_flow) {
			return false
		}
	}
	return true
}

role_target_valid :: proc(
	target: Role_Target,
	printer: Printer_Profile,
) -> bool {
	return i64(target.speed) > 0 &&
	       i64(target.speed) <= i64(printer.maximum_speed) &&
	       i64(target.acceleration) > 0 &&
	       i64(target.acceleration) <=
	       	i64(printer.maximum_acceleration) &&
	       u32(target.flow_ratio) > 0 &&
	       u32(target.flow_ratio) <= RATIO_SCALE*2 &&
	       u32(target.fan_ratio) <= RATIO_SCALE
}

role_target_volume_rate :: proc(
	line_width: contracts.Micrometres,
	layer_height: contracts.Micrometres,
	target: Role_Target,
) -> (Volume_Rate_Cubic_Micrometres_Per_Second, bool) {
	product := i128(line_width)*
		i128(layer_height)*
		i128(target.speed)*
		i128(target.flow_ratio)
	rate := product/i128(RATIO_SCALE)
	if rate <= 0 || rate > i128(max(i64)) {return 0, false}
	return Volume_Rate_Cubic_Micrometres_Per_Second(rate), true
}

ratio_scale_micrometres :: proc(
	value: contracts.Micrometres,
	ratio: Ratio_Ppm,
) -> (contracts.Micrometres, bool) {
	product := i128(value)*i128(ratio)
	rounded := (product+i128(RATIO_SCALE/2))/i128(RATIO_SCALE)
	if rounded <= 0 || rounded > i128(max(i64)) {return 0, false}
	return contracts.Micrometres(rounded), true
}

skin_target_valid :: proc(target: Skin_Target) -> bool {
	return i64(target.thickness) > 0 && target.minimum_layers > 0
}

angle_valid :: proc(angle: Angle_Millidegrees) -> bool {
	return i32(angle) >= 0 && i32(angle) < 180_000
}
