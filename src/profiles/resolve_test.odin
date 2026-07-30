package profiles

import "core:testing"

import contracts "../contracts"

@(test)
profiles_resolve_produces_selected_v1_policies_test :: proc(t: ^testing.T) {
	printer, material, process, dialect := profile_test_documents()
	resolved, error := profiles_resolve(
		printer,
		material,
		process,
		dialect,
	)
	testing.expect_value(t, error, Profile_Resolve_Error.None)
	testing.expect_value(
		t,
		resolved.process.first_layer.line_width,
		process.nominal_line_width,
	)
	testing.expect_value(
		t,
		resolved.process.first_layer.perimeter_count,
		process.perimeter_count,
	)
	testing.expect_value(
		t,
		resolved.process.thin_wall_minimum_width,
		contracts.Micrometres(270),
	)
	testing.expect_value(
		t,
		resolved.process.thin_wall_maximum_width,
		contracts.Micrometres(585),
	)
	testing.expect_value(
		t,
		resolved.process.source.role_overlap,
		Role_Overlap_Policy.Subtract_Higher_Priority,
	)
	testing.expect_value(
		t,
		resolved.dialect.dialect,
		GCode_Dialect.Marlin_Conservative,
	)
}

@(test)
profiles_resolve_applies_only_explicit_first_layer_overrides_test :: proc(
	t: ^testing.T,
) {
	printer, material, process, dialect := profile_test_documents()
	process.first_layer.line_width_enabled = true
	process.first_layer.line_width = 500
	process.first_layer.perimeter_count_enabled = true
	process.first_layer.perimeter_count = 4
	resolved, error := profiles_resolve(
		printer,
		material,
		process,
		dialect,
	)
	testing.expect_value(t, error, Profile_Resolve_Error.None)
	testing.expect_value(
		t,
		resolved.process.first_layer.line_width,
		contracts.Micrometres(500),
	)
	testing.expect_value(
		t,
		resolved.process.first_layer.perimeter_count,
		u32(4),
	)
	testing.expect_value(
		t,
		resolved.process.first_layer.top_skin,
		process.top_skin,
	)
}

@(test)
profiles_resolve_rejects_targets_outside_hard_limits_test :: proc(
	t: ^testing.T,
) {
	printer, material, process, dialect := profile_test_documents()
	process.layer_height = printer.maximum_layer_height+1
	_, layer_error := profiles_resolve(
		printer,
		material,
		process,
		dialect,
	)
	testing.expect_value(
		t,
		layer_error,
		Profile_Resolve_Error.Process_Layer_Target,
	)

	_, _, process, _ = profile_test_documents()
	process.bridge.speed = printer.maximum_speed+1
	_, speed_error := profiles_resolve(
		printer,
		material,
		process,
		dialect,
	)
	testing.expect_value(
		t,
		speed_error,
		Profile_Resolve_Error.Process_Motion_Target,
	)

	_, _, process, _ = profile_test_documents()
	process.nozzle_temperature =
		material.maximum_nozzle_temperature+1
	_, thermal_error := profiles_resolve(
		printer,
		material,
		process,
		dialect,
	)
	testing.expect_value(
		t,
		thermal_error,
		Profile_Resolve_Error.Process_Thermal_Target,
	)
}

@(test)
profiles_resolve_rejects_noncanonical_policy_documents_test :: proc(
	t: ^testing.T,
) {
	printer, material, process, dialect := profile_test_documents()
	process.bridge_angles[1] = process.bridge_angles[0]
	_, bridge_error := profiles_resolve(
		printer,
		material,
		process,
		dialect,
	)
	testing.expect_value(
		t,
		bridge_error,
		Profile_Resolve_Error.Process_Bridge_Target,
	)

	_, _, process, _ = profile_test_documents()
	process.first_layer.line_width = 450
	_, override_error := profiles_resolve(
		printer,
		material,
		process,
		dialect,
	)
	testing.expect_value(
		t,
		override_error,
		Profile_Resolve_Error.Process_Shell_Target,
	)

	_, _, process, dialect = profile_test_documents()
	dialect.dialect = transmute(GCode_Dialect)u8(2)
	_, dialect_error := profiles_resolve(
		printer,
		material,
		process,
		dialect,
	)
	testing.expect_value(
		t,
		dialect_error,
		Profile_Resolve_Error.Dialect_Target,
	)
}

@(test)
printable_role_priority_matches_the_selected_subtraction_order_test :: proc(
	t: ^testing.T,
) {
	roles := [?]Printable_Role{
		.Perimeter,
		.Bridge,
		.Gap,
		.Thin_Wall,
		.Top_Skin,
		.Bottom_Skin,
		.Top_Bottom_Skin,
		.Sparse_Infill,
	}
	expected := [?]u8{1, 2, 3, 3, 4, 4, 4, 5}
	for role, index in roles {
		priority, ok := printable_role_priority(role)
		testing.expect(t, ok)
		testing.expect_value(t, priority, expected[index])
	}
	_, invalid_ok := printable_role_priority(.Invalid)
	testing.expect(t, !invalid_ok)
}

profile_test_documents :: proc() -> (
	Printer_Profile,
	Material_Profile,
	Process_Profile,
	Dialect_Profile,
) {
	printer := Printer_Profile{
		schema_version = PRINTER_PROFILE_SCHEMA_VERSION,
		build_size_x = 220_000,
		build_size_y = 220_000,
		build_size_z = 250_000,
		nozzle_diameter = 400,
		minimum_layer_height = 80,
		maximum_layer_height = 320,
		minimum_line_width = 200,
		maximum_line_width = 800,
		maximum_speed = 300_000,
		maximum_acceleration = 5_000_000,
	}
	material := Material_Profile{
		schema_version = MATERIAL_PROFILE_SCHEMA_VERSION,
		filament_diameter = 1_750,
		density = 1_240,
		minimum_nozzle_temperature = 180,
		maximum_nozzle_temperature = 230,
		minimum_bed_temperature = 0,
		maximum_bed_temperature = 70,
		minimum_fan_ratio = 0,
		maximum_fan_ratio = Ratio_Ppm(RATIO_SCALE),
		maximum_volumetric_flow = 12_000_000_000,
	}
	base_role := Role_Target{
		speed = 40_000,
		acceleration = 1_000_000,
		flow_ratio = Ratio_Ppm(RATIO_SCALE),
		fan_ratio = Ratio_Ppm(RATIO_SCALE),
	}
	process := Process_Profile{
		schema_version = PROCESS_PROFILE_SCHEMA_VERSION,
		first_layer_height = 240,
		layer_height = 200,
		adaptive_layers = false,
		minimum_adaptive_height = 120,
		maximum_adaptive_height = 280,
		perimeter_count = 3,
		nominal_line_width = 450,
		top_skin = {800, 3},
		bottom_skin = {800, 3},
		solid_infill_spacing = 450,
		solid_infill_base_angle = 45_000,
		solid_infill_angle_step = 90_000,
		role_overlap = .Subtract_Higher_Priority,
		thin_wall_minimum_ratio = 600_000,
		thin_wall_maximum_ratio = 1_300_000,
		thin_wall_remainder = .Preserve_Unprinted,
		gap_allocation = .One_Then_Two_Lines,
		maximum_centerline_deviation = 100,
		bridge_geometry = .Previous_Layer_Expanded_Support,
		bridge_anchor_margin = 200,
		bridge_direction = .Bounded_Candidate_Score,
		bridge_angle_count = 4,
		bridge_angles = {
			0,
			45_000,
			90_000,
			135_000,
			0,
			0,
			0,
			0,
		},
		minimum_bridge_area = 1_000_000,
		support_demand = .Mesh_And_Layer_Projection,
		support_mode = .Everywhere,
		support_overhang_angle = 45_000,
		support_clearance_xy = 300,
		support_clearance_z = 200,
		support_expansion = 200,
		support_density = 150_000,
		support_pattern = .Rectilinear,
		support_interface_layers = 3,
		support_interface_spacing = 250,
		perimeter = base_role,
		skin = base_role,
		sparse_infill = base_role,
		gap = base_role,
		bridge = {
			speed = 25_000,
			acceleration = 500_000,
			flow_ratio = 900_000,
			fan_ratio = Ratio_Ppm(RATIO_SCALE),
		},
		support = base_role,
		support_interface = base_role,
		travel = {150_000, 2_000_000},
		nozzle_temperature = 210,
		bed_temperature = 60,
		minimum_layer_time = 5_000,
		seam = .Deterministic_Cost,
		retraction = .Distance_And_Exterior_Crossing,
		retraction_distance = 800,
		minimum_retraction_travel = 1_500,
		travel_policy = .Direct,
		z_hop_enabled = false,
		z_hop_height = 0,
		extrusion_accumulation = .Volume_Then_Fixed_Point_Length,
		extrusion_length_quantum_nm = 1,
	}
	dialect := Dialect_Profile{
		schema_version = DIALECT_PROFILE_SCHEMA_VERSION,
		dialect = .Marlin_Conservative,
		coordinate_mode = .Absolute,
		extrusion_mode = .Relative,
		xy_decimal_places = 3,
		z_decimal_places = 3,
		e_decimal_places = 5,
		feed_decimal_places = 0,
		line_ending = .LF,
		line_numbers = false,
		checksums = false,
	}
	return printer, material, process, dialect
}
