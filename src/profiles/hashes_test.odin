package profiles

import "core:testing"

import contracts "../contracts"

@(test)
profile_revisions_bind_each_normalized_document_test :: proc(t: ^testing.T) {
	resolved := profile_test_resolved(t)
	revisions := profile_revisions(resolved)
	testing.expect(t, hash_nonzero(revisions.printer))
	testing.expect(t, hash_nonzero(revisions.material))
	testing.expect(t, hash_nonzero(revisions.process))
	testing.expect(t, hash_nonzero(revisions.dialect))

	mutated := resolved
	mutated.printer.nozzle_diameter += 1
	mutated_revisions := profile_revisions(mutated)
	testing.expect(t, mutated_revisions.printer != revisions.printer)
	testing.expect_value(t, mutated_revisions.material, revisions.material)
	testing.expect_value(t, mutated_revisions.process, revisions.process)
	testing.expect_value(t, mutated_revisions.dialect, revisions.dialect)
}

@(test)
profile_invalidation_starts_at_normalize_for_build_geometry_test :: proc(
	t: ^testing.T,
) {
	previous := profile_test_resolved(t)
	next := previous
	next.printer.axis_maximum_x += 1
	expect_invalidation_suffix(t, previous, next, .Normalize)
}

@(test)
profile_invalidation_starts_at_schedule_for_layer_fields_test :: proc(
	t: ^testing.T,
) {
	previous := profile_test_resolved(t)
	next := previous
	next.process.source.layer_height += 1
	expect_invalidation_suffix(t, previous, next, .Schedule_Layers)
}

@(test)
profile_invalidation_starts_at_features_for_shell_fields_test :: proc(
	t: ^testing.T,
) {
	previous := profile_test_resolved(t)
	printer := previous.printer
	material := previous.material
	process := previous.process.source
	dialect := previous.dialect
	process.top_skin.thickness += 1
	next, error := profiles_resolve(printer, material, process, dialect)
	testing.expect_value(t, error, Profile_Resolve_Error.None)
	expect_invalidation_suffix(t, previous, next, .Generate_Features)
}

@(test)
profile_invalidation_starts_at_paths_for_motion_and_extrusion_test :: proc(
	t: ^testing.T,
) {
	previous := profile_test_resolved(t)
	next := previous
	next.process.source.perimeter.speed += 1
	expect_invalidation_suffix(t, previous, next, .Plan_Paths)

	next = previous
	next.material.filament_diameter += 1
	expect_invalidation_suffix(t, previous, next, .Plan_Paths)
}

@(test)
profile_invalidation_starts_at_gcode_for_dialect_fields_test :: proc(
	t: ^testing.T,
) {
	previous := profile_test_resolved(t)
	next := previous
	next.dialect.e_decimal_places += 1
	expect_invalidation_suffix(t, previous, next, .Emit_GCode)

	next = previous
	next.printer.bed_leveling = .Probe_Before_Print
	expect_invalidation_suffix(t, previous, next, .Emit_GCode)
}

@(test)
profile_invalidation_is_empty_for_equal_profiles_test :: proc(t: ^testing.T) {
	profile := profile_test_resolved(t)
	invalidation := profile_invalidation(profile, profile)
	testing.expect_value(
		t,
		invalidation.first_stage,
		contracts.Stage_Kind.Invalid,
	)
	testing.expect_value(t, invalidation.stage_mask, u16(0))
}

@(test)
profile_field_contract_covers_every_selected_owner_group_test :: proc(
	t: ^testing.T,
) {
	fields := [?]Profile_Field_Group{
		.Build_Geometry,
		.Nozzle_Geometry,
		.Layer_Limits,
		.Motion_Limits,
		.Filament_Geometry,
		.Thermal_And_Cooling_Limits,
		.Volumetric_Flow_Limit,
		.Layer_Targets,
		.Shell_Geometry_Targets,
		.Thin_Wall_And_Gap_Targets,
		.Bridge_And_Support_Targets,
		.Motion_Targets,
		.Extrusion_Targets,
		.Dialect_Syntax,
		.Printer_GCode_Actions,
		.Display_Only,
	}
	for field in fields {
		contract, ok := profile_field_contract(field)
		testing.expect(t, ok)
		testing.expect(t, contract.owner != .Invalid)
		if field == .Display_Only {
			testing.expect_value(
				t,
				contract.first_invalidated,
				contracts.Stage_Kind.Invalid,
			)
		} else {
			testing.expect(
				t,
				contract.first_invalidated != .Invalid,
			)
		}
	}
	_, invalid_ok := profile_field_contract(.Invalid)
	testing.expect(t, !invalid_ok)
}

expect_invalidation_suffix :: proc(
	t: ^testing.T,
	previous: Resolved_Profiles,
	next: Resolved_Profiles,
	expected_first: contracts.Stage_Kind,
) {
	invalidation := profile_invalidation(previous, next)
	testing.expect_value(t, invalidation.first_stage, expected_first)
	testing.expect(
		t,
		profile_invalidation_contains(invalidation, expected_first),
	)
	testing.expect(
		t,
		profile_invalidation_contains(invalidation, .Emit_GCode),
	)
	if expected_first != .Normalize {
		testing.expect(
			t,
			!profile_invalidation_contains(invalidation, .Normalize),
		)
	}
	if expected_first == .Emit_GCode {
		testing.expect(
			t,
			!profile_invalidation_contains(invalidation, .Plan_Paths),
		)
	}
}

profile_test_resolved :: proc(t: ^testing.T) -> Resolved_Profiles {
	printer, material, process, dialect := profile_test_documents()
	resolved, error := profiles_resolve(
		printer,
		material,
		process,
		dialect,
	)
	testing.expect_value(t, error, Profile_Resolve_Error.None)
	return resolved
}

hash_nonzero :: proc(hash: contracts.Content_Hash) -> bool {
	for byte in hash {
		if byte != 0 {return true}
	}
	return false
}
