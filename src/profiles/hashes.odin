package profiles

import contracts "../contracts"

PROFILE_FEATURE_HASH_SCHEMA_VERSION :: u32(2)

Profile_Field_Group :: enum u8 {
	Invalid,
	Build_Geometry,
	Nozzle_Geometry,
	Layer_Limits,
	Motion_Limits,
	Filament_Geometry,
	Thermal_And_Cooling_Limits,
	Volumetric_Flow_Limit,
	Layer_Targets,
	Shell_Geometry_Targets,
	Thin_Wall_And_Gap_Targets,
	Bridge_And_Support_Targets,
	Motion_Targets,
	Extrusion_Targets,
	Dialect_Syntax,
	Printer_GCode_Actions,
	Display_Only,
}

Profile_Field_Contract :: struct {
	owner:               Profile_Owner,
	first_invalidated:   contracts.Stage_Kind,
}

profile_revisions :: proc(
	profiles: Resolved_Profiles,
) -> contracts.Profile_Revisions {
	return {
		printer = printer_profile_hash(profiles.printer),
		process = process_profile_hash(profiles.process),
		material = material_profile_hash(profiles.material),
		dialect = dialect_profile_hash(profiles.dialect),
	}
}

// Hash of the printer and process fields that feature generation reads. Stages that take the
// whole process document include it, so they never miss a change.
profile_feature_hash :: proc(
	profiles: Resolved_Profiles,
) -> contracts.Content_Hash {
	features: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&features,
		"hw-slicer/profile-stage/generate-features",
		PROFILE_FEATURE_HASH_SCHEMA_VERSION,
	)
	append_printer_feature_geometry(&features, profiles.printer)
	append_process_feature_targets(&features, profiles.process)
	return contracts.canonical_hash_final(&features)
}

profile_field_contract :: proc(
	field: Profile_Field_Group,
) -> (Profile_Field_Contract, bool) {
	switch field {
	case .Build_Geometry:
		return {.Printer, .Normalize}, true
	case .Nozzle_Geometry:
		return {.Printer, .Generate_Features}, true
	case .Layer_Limits:
		return {.Printer, .Schedule_Layers}, true
	case .Motion_Limits:
		return {.Printer, .Plan_Paths}, true
	case .Filament_Geometry:
		return {.Material, .Plan_Paths}, true
	case .Thermal_And_Cooling_Limits:
		return {.Material, .Plan_Paths}, true
	case .Volumetric_Flow_Limit:
		return {.Material, .Plan_Paths}, true
	case .Layer_Targets:
		return {.Process, .Schedule_Layers}, true
	case .Shell_Geometry_Targets:
		return {.Process, .Generate_Features}, true
	case .Thin_Wall_And_Gap_Targets:
		return {.Process, .Generate_Features}, true
	case .Bridge_And_Support_Targets:
		return {.Process, .Generate_Features}, true
	case .Motion_Targets:
		return {.Process, .Plan_Paths}, true
	case .Extrusion_Targets:
		return {.Process, .Plan_Paths}, true
	case .Dialect_Syntax:
		return {.Dialect, .Emit_GCode}, true
	case .Printer_GCode_Actions:
		return {.Printer, .Emit_GCode}, true
	case .Display_Only:
		return {.Derived, .Invalid}, true
	case .Invalid:
		return {}, false
	}
	return {}, false
}

printer_profile_hash :: proc(
	profile: Printer_Profile,
) -> contracts.Content_Hash {
	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/printer-profile",
		PRINTER_PROFILE_SCHEMA_VERSION,
	)
	append_printer_build_geometry(&hash, profile)
	append_printer_feature_geometry(&hash, profile)
	append_printer_layer_limits(&hash, profile)
	append_printer_motion_limits(&hash, profile)
	return contracts.canonical_hash_final(&hash)
}

material_profile_hash :: proc(
	profile: Material_Profile,
) -> contracts.Content_Hash {
	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/material-profile",
		MATERIAL_PROFILE_SCHEMA_VERSION,
	)
	append_material_path_limits(&hash, profile)
	return contracts.canonical_hash_final(&hash)
}

process_profile_hash :: proc(
	profile: Resolved_Process_Profile,
) -> contracts.Content_Hash {
	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/process-profile",
		PROCESS_PROFILE_SCHEMA_VERSION,
	)
	append_process_layer_targets(&hash, profile.source)
	append_process_feature_targets(&hash, profile)
	append_process_path_targets(&hash, profile.source)
	return contracts.canonical_hash_final(&hash)
}

dialect_profile_hash :: proc(
	profile: Dialect_Profile,
) -> contracts.Content_Hash {
	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/dialect-profile",
		DIALECT_PROFILE_SCHEMA_VERSION,
	)
	append_dialect_profile(&hash, profile)
	return contracts.canonical_hash_final(&hash)
}

append_printer_build_geometry :: proc(
	hash: ^contracts.Canonical_Hash,
	profile: Printer_Profile,
) {
	contracts.canonical_hash_append_i64(hash, i64(profile.axis_minimum_x))
	contracts.canonical_hash_append_i64(hash, i64(profile.axis_maximum_x))
	contracts.canonical_hash_append_i64(hash, i64(profile.axis_minimum_y))
	contracts.canonical_hash_append_i64(hash, i64(profile.axis_maximum_y))
	contracts.canonical_hash_append_i64(hash, i64(profile.axis_minimum_z))
	contracts.canonical_hash_append_i64(hash, i64(profile.axis_maximum_z))
	contracts.canonical_hash_append_u8(hash, profile.extruder_count)
}

append_printer_feature_geometry :: proc(
	hash: ^contracts.Canonical_Hash,
	profile: Printer_Profile,
) {
	contracts.canonical_hash_append_i64(hash, i64(profile.nozzle_diameter))
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.minimum_line_width),
	)
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.maximum_line_width),
	)
}

append_printer_layer_limits :: proc(
	hash: ^contracts.Canonical_Hash,
	profile: Printer_Profile,
) {
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.minimum_layer_height),
	)
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.maximum_layer_height),
	)
}

append_printer_motion_limits :: proc(
	hash: ^contracts.Canonical_Hash,
	profile: Printer_Profile,
) {
	contracts.canonical_hash_append_i64(hash, i64(profile.maximum_speed))
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.maximum_acceleration),
	)
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.maximum_extruder_speed),
	)
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.maximum_extruder_acceleration),
	)
	contracts.canonical_hash_append_u32(hash, u32(profile.minimum_cruise_ratio))
}

append_material_path_limits :: proc(
	hash: ^contracts.Canonical_Hash,
	profile: Material_Profile,
) {
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.filament_diameter),
	)
	contracts.canonical_hash_append_u32(hash, u32(profile.density))
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.minimum_nozzle_temperature),
	)
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.maximum_nozzle_temperature),
	)
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.minimum_bed_temperature),
	)
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.maximum_bed_temperature),
	)
	contracts.canonical_hash_append_u32(
		hash,
		u32(profile.minimum_fan_ratio),
	)
	contracts.canonical_hash_append_u32(
		hash,
		u32(profile.maximum_fan_ratio),
	)
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.maximum_volumetric_flow),
	)
}

append_process_layer_targets :: proc(
	hash: ^contracts.Canonical_Hash,
	profile: Process_Profile,
) {
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.first_layer_height),
	)
	contracts.canonical_hash_append_i64(hash, i64(profile.layer_height))
	contracts.canonical_hash_append_u8(hash, u8(profile.adaptive_layers))
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.minimum_adaptive_height),
	)
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.maximum_adaptive_height),
	)
}

append_process_feature_targets :: proc(
	hash: ^contracts.Canonical_Hash,
	profile: Resolved_Process_Profile,
) {
	source := profile.source
	contracts.canonical_hash_append_u32(hash, source.perimeter_count)
	contracts.canonical_hash_append_i64(
		hash,
		i64(source.nominal_line_width),
	)
	append_skin_target(hash, source.top_skin)
	append_skin_target(hash, source.bottom_skin)
	contracts.canonical_hash_append_i64(
		hash,
		i64(source.solid_infill_spacing),
	)
	contracts.canonical_hash_append_i64(
		hash,
		i64(source.solid_infill_base_angle),
	)
	contracts.canonical_hash_append_i64(
		hash,
		i64(source.solid_infill_angle_step),
	)
	append_first_layer_overrides(hash, source.first_layer)
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.first_layer.line_width),
	)
	contracts.canonical_hash_append_u32(
		hash,
		profile.first_layer.perimeter_count,
	)
	append_skin_target(hash, profile.first_layer.top_skin)
	append_skin_target(hash, profile.first_layer.bottom_skin)
	contracts.canonical_hash_append_u8(hash, u8(source.role_overlap))
	contracts.canonical_hash_append_u32(
		hash,
		u32(source.thin_wall_minimum_ratio),
	)
	contracts.canonical_hash_append_u32(
		hash,
		u32(source.thin_wall_maximum_ratio),
	)
	contracts.canonical_hash_append_u8(
		hash,
		u8(source.thin_wall_remainder),
	)
	contracts.canonical_hash_append_u8(hash, u8(source.gap_allocation))
	contracts.canonical_hash_append_i64(
		hash,
		i64(source.maximum_centerline_deviation),
	)
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.thin_wall_minimum_width),
	)
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.thin_wall_maximum_width),
	)
	contracts.canonical_hash_append_u8(hash, u8(source.bridge_geometry))
	contracts.canonical_hash_append_i64(
		hash,
		i64(source.bridge_anchor_margin),
	)
	contracts.canonical_hash_append_u8(hash, u8(source.bridge_direction))
	contracts.canonical_hash_append_u8(hash, source.bridge_angle_count)
	for angle in source.bridge_angles {
		contracts.canonical_hash_append_i64(hash, i64(angle))
	}
	contracts.canonical_hash_append_i64(
		hash,
		i64(source.minimum_bridge_area),
	)
	contracts.canonical_hash_append_u8(hash, u8(source.support_demand))
	contracts.canonical_hash_append_u8(hash, u8(source.support_mode))
	contracts.canonical_hash_append_i64(
		hash,
		i64(source.support_overhang_angle),
	)
	contracts.canonical_hash_append_i64(
		hash,
		i64(source.support_clearance_xy),
	)
	contracts.canonical_hash_append_i64(
		hash,
		i64(source.support_clearance_z),
	)
	contracts.canonical_hash_append_i64(
		hash,
		i64(source.support_expansion),
	)
	contracts.canonical_hash_append_u32(
		hash,
		u32(source.support_density),
	)
	contracts.canonical_hash_append_u8(hash, u8(source.support_pattern))
	contracts.canonical_hash_append_u32(
		hash,
		source.support_interface_layers,
	)
	contracts.canonical_hash_append_i64(
		hash,
		i64(source.support_interface_spacing),
	)
}

append_process_path_targets :: proc(
	hash: ^contracts.Canonical_Hash,
	profile: Process_Profile,
) {
	append_role_target(hash, profile.perimeter)
	append_role_target(hash, profile.skin)
	append_role_target(hash, profile.sparse_infill)
	append_role_target(hash, profile.gap)
	append_role_target(hash, profile.bridge)
	append_role_target(hash, profile.support)
	append_role_target(hash, profile.support_interface)
	contracts.canonical_hash_append_i64(hash, i64(profile.travel.speed))
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.travel.acceleration),
	)
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.nozzle_temperature),
	)
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.bed_temperature),
	)
	contracts.canonical_hash_append_u32(
		hash,
		u32(profile.minimum_layer_time),
	)
	contracts.canonical_hash_append_u8(
		hash,
		u8(profile.minimum_layer_time_policy),
	)
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.minimum_print_speed),
	)
	contracts.canonical_hash_append_u8(hash, u8(profile.seam))
	contracts.canonical_hash_append_u8(hash, u8(profile.seam_visibility))
	contracts.canonical_hash_append_u8(hash, u8(profile.retraction))
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.retraction_distance),
	)
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.minimum_retraction_travel),
	)
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.retraction_speed),
	)
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.recovery_speed),
	)
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.retraction_acceleration),
	)
	contracts.canonical_hash_append_u8(hash, u8(profile.travel_policy))
	contracts.canonical_hash_append_u8(hash, u8(profile.z_hop_enabled))
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.z_hop_height),
	)
	contracts.canonical_hash_append_u8(
		hash,
		u8(profile.extrusion_accumulation),
	)
	contracts.canonical_hash_append_u32(
		hash,
		profile.extrusion_length_quantum_nm,
	)
}

append_dialect_profile :: proc(
	hash: ^contracts.Canonical_Hash,
	profile: Dialect_Profile,
) {
	contracts.canonical_hash_append_u8(hash, u8(profile.dialect))
	contracts.canonical_hash_append_u8(hash, u8(profile.coordinate_mode))
	contracts.canonical_hash_append_u8(hash, u8(profile.extrusion_mode))
	contracts.canonical_hash_append_u8(hash, profile.xy_decimal_places)
	contracts.canonical_hash_append_u8(hash, profile.z_decimal_places)
	contracts.canonical_hash_append_u8(hash, profile.e_decimal_places)
	contracts.canonical_hash_append_u8(hash, profile.feed_decimal_places)
	contracts.canonical_hash_append_u8(hash, u8(profile.line_ending))
	contracts.canonical_hash_append_u8(hash, u8(profile.line_numbers))
	contracts.canonical_hash_append_u8(hash, u8(profile.checksums))
	contracts.canonical_hash_append_u8(
		hash,
		u8(profile.acceleration_commands),
	)
	contracts.canonical_hash_append_u8(hash, u8(profile.output_mode))
	contracts.canonical_hash_append_u8(
		hash,
		u8(profile.emit_layer_comments),
	)
}

append_skin_target :: proc(
	hash: ^contracts.Canonical_Hash,
	target: Skin_Target,
) {
	contracts.canonical_hash_append_i64(hash, i64(target.thickness))
	contracts.canonical_hash_append_u32(hash, target.minimum_layers)
}

append_first_layer_overrides :: proc(
	hash: ^contracts.Canonical_Hash,
	override: First_Layer_Overrides,
) {
	contracts.canonical_hash_append_u8(
		hash,
		u8(override.line_width_enabled),
	)
	contracts.canonical_hash_append_i64(hash, i64(override.line_width))
	contracts.canonical_hash_append_u8(
		hash,
		u8(override.perimeter_count_enabled),
	)
	contracts.canonical_hash_append_u32(hash, override.perimeter_count)
	contracts.canonical_hash_append_u8(
		hash,
		u8(override.top_skin_enabled),
	)
	append_skin_target(hash, override.top_skin)
	contracts.canonical_hash_append_u8(
		hash,
		u8(override.bottom_skin_enabled),
	)
	append_skin_target(hash, override.bottom_skin)
}

append_role_target :: proc(
	hash: ^contracts.Canonical_Hash,
	target: Role_Target,
) {
	contracts.canonical_hash_append_i64(hash, i64(target.speed))
	contracts.canonical_hash_append_i64(hash, i64(target.acceleration))
	contracts.canonical_hash_append_u32(hash, u32(target.flow_ratio))
	contracts.canonical_hash_append_u32(hash, u32(target.fan_ratio))
}
