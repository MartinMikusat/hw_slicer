package profiles

import contracts "../contracts"

PROFILE_STAGE_HASH_SCHEMA_VERSION :: u32(1)

Profile_Stage_Hashes :: struct {
	normalize:         contracts.Content_Hash,
	schedule_layers:   contracts.Content_Hash,
	generate_features: contracts.Content_Hash,
	plan_paths:        contracts.Content_Hash,
	emit_gcode:        contracts.Content_Hash,
}

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
	Display_Only,
}

Profile_Field_Contract :: struct {
	owner:               Profile_Owner,
	first_invalidated:   contracts.Stage_Kind,
}

Profile_Invalidation :: struct {
	first_stage: contracts.Stage_Kind,
	stage_mask:  u16,
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

profile_stage_hashes :: proc(
	profiles: Resolved_Profiles,
) -> Profile_Stage_Hashes {
	normalize: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&normalize,
		"hw-slicer/profile-stage/normalize",
		PROFILE_STAGE_HASH_SCHEMA_VERSION,
	)
	append_printer_build_geometry(&normalize, profiles.printer)

	schedule: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&schedule,
		"hw-slicer/profile-stage/schedule-layers",
		PROFILE_STAGE_HASH_SCHEMA_VERSION,
	)
	append_printer_layer_limits(&schedule, profiles.printer)
	append_process_layer_targets(&schedule, profiles.process.source)

	features: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&features,
		"hw-slicer/profile-stage/generate-features",
		PROFILE_STAGE_HASH_SCHEMA_VERSION,
	)
	append_printer_feature_geometry(&features, profiles.printer)
	append_process_feature_targets(&features, profiles.process)

	paths: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&paths,
		"hw-slicer/profile-stage/plan-paths",
		PROFILE_STAGE_HASH_SCHEMA_VERSION,
	)
	append_printer_motion_limits(&paths, profiles.printer)
	append_material_path_limits(&paths, profiles.material)
	append_process_path_targets(&paths, profiles.process.source)

	gcode: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&gcode,
		"hw-slicer/profile-stage/emit-gcode",
		PROFILE_STAGE_HASH_SCHEMA_VERSION,
	)
	append_dialect_profile(&gcode, profiles.dialect)

	return {
		normalize = contracts.canonical_hash_final(&normalize),
		schedule_layers = contracts.canonical_hash_final(&schedule),
		generate_features = contracts.canonical_hash_final(&features),
		plan_paths = contracts.canonical_hash_final(&paths),
		emit_gcode = contracts.canonical_hash_final(&gcode),
	}
}

profile_invalidation :: proc(
	previous: Resolved_Profiles,
	next: Resolved_Profiles,
) -> Profile_Invalidation {
	previous_hashes := profile_stage_hashes(previous)
	next_hashes := profile_stage_hashes(next)
	if previous_hashes.normalize != next_hashes.normalize {
		return profile_invalidation_suffix(.Normalize)
	}
	if previous_hashes.schedule_layers != next_hashes.schedule_layers {
		return profile_invalidation_suffix(.Schedule_Layers)
	}
	if previous_hashes.generate_features !=
	   	next_hashes.generate_features {
		return profile_invalidation_suffix(.Generate_Features)
	}
	if previous_hashes.plan_paths != next_hashes.plan_paths {
		return profile_invalidation_suffix(.Plan_Paths)
	}
	if previous_hashes.emit_gcode != next_hashes.emit_gcode {
		return profile_invalidation_suffix(.Emit_GCode)
	}
	return {}
}

profile_invalidation_suffix :: proc(
	first: contracts.Stage_Kind,
) -> Profile_Invalidation {
	mask: u16
	switch first {
	case .Normalize:
		mask |= profile_stage_bit(.Normalize)
		fallthrough
	case .Schedule_Layers:
		mask |= profile_stage_bit(.Schedule_Layers)
		fallthrough
	case .Build_Acceleration:
		mask |= profile_stage_bit(.Build_Acceleration)
		fallthrough
	case .Intersect:
		mask |= profile_stage_bit(.Intersect)
		fallthrough
	case .Reconstruct_Topology:
		mask |= profile_stage_bit(.Reconstruct_Topology)
		fallthrough
	case .Calculate_Regions:
		mask |= profile_stage_bit(.Calculate_Regions)
		fallthrough
	case .Generate_Features:
		mask |= profile_stage_bit(.Generate_Features)
		fallthrough
	case .Plan_Paths:
		mask |= profile_stage_bit(.Plan_Paths)
		fallthrough
	case .Emit_GCode:
		mask |= profile_stage_bit(.Emit_GCode)
	case .Invalid, .Decode, .Resolve:
		return {}
	}
	return {first_stage = first, stage_mask = mask}
}

profile_invalidation_contains :: proc(
	invalidation: Profile_Invalidation,
	stage: contracts.Stage_Kind,
) -> bool {
	return invalidation.stage_mask&profile_stage_bit(stage) != 0
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

profile_stage_bit :: proc(stage: contracts.Stage_Kind) -> u16 {
	value := u8(stage)
	if value >= 16 {return 0}
	return u16(1)<<value
}

append_printer_build_geometry :: proc(
	hash: ^contracts.Canonical_Hash,
	profile: Printer_Profile,
) {
	contracts.canonical_hash_append_i64(hash, i64(profile.build_size_x))
	contracts.canonical_hash_append_i64(hash, i64(profile.build_size_y))
	contracts.canonical_hash_append_i64(hash, i64(profile.build_size_z))
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
	contracts.canonical_hash_append_u8(hash, u8(profile.seam))
	contracts.canonical_hash_append_u8(hash, u8(profile.retraction))
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.retraction_distance),
	)
	contracts.canonical_hash_append_i64(
		hash,
		i64(profile.minimum_retraction_travel),
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
