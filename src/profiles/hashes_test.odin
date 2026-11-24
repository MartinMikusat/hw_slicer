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
