package contracts

import "core:testing"

@(test)
stage_sequence_has_eleven_named_stages_test :: proc(t: ^testing.T) {
	stages := [?]Stage_Kind{
		.Decode,
		.Resolve,
		.Normalize,
		.Schedule_Layers,
		.Build_Acceleration,
		.Intersect,
		.Reconstruct_Topology,
		.Calculate_Regions,
		.Generate_Features,
		.Plan_Paths,
		.Emit_GCode,
	}
	testing.expect_value(t, len(stages), 11)
	for stage in stages {
		testing.expect(t, stage_name(stage) != "invalid")
	}
}

@(test)
stable_ids_follow_parent_kind_and_canonical_order_test :: proc(t: ^testing.T) {
	source_hash: Content_Hash
	source_hash[0] = 0x48
	source_hash[31] = 0x53
	source_id := stable_id_root(source_hash, .Source)
	triangle_zero := stable_id_child(source_id, .Triangle, 0)
	triangle_one := stable_id_child(source_id, .Triangle, 1)
	layer_zero := stable_id_child(source_id, .Layer, 0)

	testing.expect(t, source_id != INVALID_STABLE_ID)
	testing.expect(t, triangle_zero != INVALID_STABLE_ID)
	testing.expect(t, triangle_zero != triangle_one)
	testing.expect(t, triangle_zero != layer_zero)
	testing.expect_value(t, u64(source_id), u64(0xc4d7d68f92ec5c7a))
	testing.expect_value(t, u64(triangle_zero), u64(0x1cbd50a2e33848ca))
	testing.expect_value(
		t,
		stable_id_child(source_id, .Triangle, 0),
		triangle_zero,
	)
}

@(test)
serialized_contract_versions_are_independent_test :: proc(t: ^testing.T) {
	testing.expect_value(t, SCHEMA_VERSION_SLICE_REQUEST, u32(1))
	testing.expect_value(t, SCHEMA_VERSION_STAGE_RESULT, u32(1))
	testing.expect_value(t, SCHEMA_VERSION_DEBUG_EVIDENCE, u32(1))
	testing.expect_value(t, STABLE_ID_ALGORITHM_VERSION, u32(1))
}

@(test)
authoritative_scalar_contract_widths_are_fixed_test :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(Stable_ID), 8)
	testing.expect_value(t, size_of(Micrometres), 8)
	testing.expect_value(t, size_of(Millimetres), 8)
	testing.expect_value(t, size_of(Content_Hash), 32)
}

@(test)
provider_descriptors_bind_name_version_and_stage_test :: proc(t: ^testing.T) {
	provider, provider_ok := provider_descriptor_make(
		"cpu-canonical-nearest",
		{0, 1, 0},
		.Plan_Paths,
	)
	other_stage, other_stage_ok := provider_descriptor_make(
		"cpu-canonical-nearest",
		{0, 1, 0},
		.Generate_Features,
	)
	_, empty_name_ok := provider_descriptor_make(
		"",
		{0, 1, 0},
		.Plan_Paths,
	)
	_, empty_version_ok := provider_descriptor_make(
		"cpu-canonical-nearest",
		{},
		.Plan_Paths,
	)
	_, invalid_stage_ok := provider_descriptor_make(
		"cpu-canonical-nearest",
		{0, 1, 0},
		transmute(Stage_Kind)u8(255),
	)
	_, control_name_ok := provider_descriptor_make(
		"cpu\nplanner",
		{0, 1, 0},
		.Plan_Paths,
	)
	invalid_utf8 := [2]u8{0xff, 'x'}
	_, invalid_utf8_name_ok := provider_descriptor_make(
		string(invalid_utf8[:]),
		{0, 1, 0},
		.Plan_Paths,
	)
	testing.expect(t, provider_ok)
	testing.expect(t, other_stage_ok)
	testing.expect(t, provider_descriptor_valid(provider))
	testing.expect(t, provider.id != other_stage.id)
	testing.expect(t, !empty_name_ok)
	testing.expect(t, !empty_version_ok)
	testing.expect(t, !invalid_stage_ok)
	testing.expect(t, !control_name_ok)
	testing.expect(t, !invalid_utf8_name_ok)
	testing.expect(t, provider_name_valid("plánovač-cpu"))
	testing.expect_value(
		t,
		u64(provider.id),
		u64(0x8d284a7409f377bb),
	)
}
