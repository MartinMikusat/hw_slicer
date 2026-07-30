package evidence

import "core:testing"

import contracts "../contracts"
import features "../features"
import profiles "../profiles"

@(test)
extrusion_capture_preflights_validates_and_describes_artifact_test :: proc(
	t: ^testing.T,
) {
	bytes := extrusion_capture_test_artifact(t)
	defer delete(bytes)
	request := contracts.Evidence_Request{
		level = .Primitives,
		item_limit = 1,
		byte_limit = u64(len(bytes)),
	}
	capture, capture_error := extrusion_capture_describe(
		"stages/10-plan-paths/primitives/extrusion.bin",
		request,
		{},
		bytes,
	)
	defer extrusion_capture_destroy(&capture)
	testing.expect_value(
		t,
		capture_error,
		Extrusion_Capture_Error.None,
	)
	testing.expect_value(t, capture.additional.item_count, u64(1))
	testing.expect_value(
		t,
		capture.additional.byte_count,
		u64(len(bytes)),
	)
	testing.expect_value(
		t,
		capture.artifact.format,
		features.EXTRUSION_ARTIFACT_FORMAT,
	)
	decoded, decode_error := features.extrusion_artifact_decode(
		capture.bytes,
	)
	defer features.extrusion_artifact_destroy(&decoded)
	testing.expect_value(
		t,
		decode_error,
		features.Extrusion_Artifact_Error.None,
	)
	testing.expect_value(t, len(decoded.result.layers), 1)
	testing.expect_value(t, len(decoded.result.moves), 0)
}

@(test)
extrusion_capture_rejects_budget_path_and_content_failures_test :: proc(
	t: ^testing.T,
) {
	bytes := extrusion_capture_test_artifact(t)
	defer delete(bytes)
	request := contracts.Evidence_Request{
		level = .Primitives,
		item_limit = 1,
		byte_limit = u64(len(bytes)),
	}
	_, item_error := extrusion_capture_describe(
		"extrusion.bin",
		{
			level = .Primitives,
			item_limit = 0,
			byte_limit = u64(len(bytes)),
		},
		{},
		bytes,
	)
	testing.expect_value(
		t,
		item_error,
		Extrusion_Capture_Error.Item_Limit,
	)
	_, path_error := extrusion_capture_describe(
		"../extrusion.bin",
		request,
		{},
		bytes,
	)
	testing.expect_value(
		t,
		path_error,
		Extrusion_Capture_Error.Invalid_Path,
	)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[32] = corrupt[32] ~ 1
	_, content_error := extrusion_capture_describe(
		"extrusion.bin",
		request,
		{},
		corrupt,
	)
	testing.expect_value(
		t,
		content_error,
		Extrusion_Capture_Error.Invalid_Record,
	)
}

extrusion_capture_test_artifact :: proc(t: ^testing.T) -> []u8 {
	filament_diameter := u128(1_750)
	filament_denominator :=
		u128(features.EXTRUSION_PI_SCALED)*
		filament_diameter*filament_diameter*
		u128(profiles.RATIO_SCALE)
	result := features.Extrusion_Result{
		policy = .Volume_Then_Fixed_Point_Length,
		cross_section_model = .Rounded_Bead,
		pi_scale = features.EXTRUSION_PI_SCALE,
		pi_scaled = features.EXTRUSION_PI_SCALED,
		filament_diameter = 1_750,
		length_quantum_nm = 10,
		cross_section_denominator =
			u64(4)*features.EXTRUSION_PI_SCALE,
		volume_denominator =
			u64(4)*features.EXTRUSION_PI_SCALE*
			1_000*u64(profiles.RATIO_SCALE),
		filament_length_denominator = filament_denominator,
		quantized_length_denominator = filament_denominator*10,
		layers = []features.Extrusion_Layer{{}},
	}
	dependencies := features.Extrusion_Hash_Dependencies{
		path_plan_hash = EXTRUSION_CAPTURE_TEST_HASH,
		layer_schedule_hash = EXTRUSION_CAPTURE_TEST_HASH,
		material_hash = EXTRUSION_CAPTURE_TEST_HASH,
		process_hash = EXTRUSION_CAPTURE_TEST_HASH,
	}
	result_hash, result_ok :=
		features.extrusion_result_content_hash(dependencies, result)
	testing.expect(t, result_ok)
	byte_count, byte_count_ok :=
		features.extrusion_artifact_byte_count(1, 0)
	testing.expect(t, byte_count_ok)
	bytes := make([]u8, int(byte_count))
	testing.expect(t, bytes != nil)
	for byte, byte_index in features.EXTRUSION_ARTIFACT_MAGIC {
		bytes[byte_index] = byte
	}
	features.extrusion_artifact_put_u32(
		bytes,
		8,
		features.EXTRUSION_ARTIFACT_SCHEMA_VERSION,
	)
	features.extrusion_artifact_put_u32(
		bytes,
		12,
		features.EXTRUSION_ARTIFACT_HEADER_SIZE,
	)
	features.extrusion_artifact_put_u32(
		bytes,
		16,
		features.EXTRUSION_ARTIFACT_LAYER_SIZE,
	)
	features.extrusion_artifact_put_u32(
		bytes,
		20,
		features.EXTRUSION_ARTIFACT_MOVE_SIZE,
	)
	features.extrusion_artifact_put_u32(
		bytes,
		24,
		features.SCHEMA_VERSION_EXTRUSION_HASH,
	)
	features.extrusion_artifact_put_hash(
		bytes,
		32,
		dependencies.path_plan_hash,
	)
	features.extrusion_artifact_put_hash(
		bytes,
		64,
		dependencies.layer_schedule_hash,
	)
	features.extrusion_artifact_put_hash(
		bytes,
		96,
		dependencies.material_hash,
	)
	features.extrusion_artifact_put_hash(
		bytes,
		128,
		dependencies.process_hash,
	)
	features.extrusion_artifact_put_hash(bytes, 160, result_hash)
	bytes[192] = u8(result.policy)
	bytes[193] = u8(result.cross_section_model)
	features.extrusion_artifact_put_u64(bytes, 200, result.pi_scale)
	features.extrusion_artifact_put_u64(bytes, 208, result.pi_scaled)
	features.extrusion_artifact_put_i64(
		bytes,
		216,
		i64(result.filament_diameter),
	)
	features.extrusion_artifact_put_u32(
		bytes,
		224,
		result.length_quantum_nm,
	)
	features.extrusion_artifact_put_u64(
		bytes,
		232,
		result.cross_section_denominator,
	)
	features.extrusion_artifact_put_u64(
		bytes,
		240,
		result.volume_denominator,
	)
	features.extrusion_artifact_put_u128(
		bytes,
		248,
		result.filament_length_denominator,
	)
	features.extrusion_artifact_put_u128(
		bytes,
		264,
		result.quantized_length_denominator,
	)
	features.extrusion_artifact_put_u64(bytes, 280, 1)
	return bytes
}

EXTRUSION_CAPTURE_TEST_HASH :: contracts.Content_Hash{
	0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
	0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe,
	0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
	0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0x01,
}
