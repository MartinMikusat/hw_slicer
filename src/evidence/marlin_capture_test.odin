package evidence

import "core:testing"

import contracts "../contracts"
import gcode "../gcode"

@(test)
marlin_capture_preflights_validates_and_describes_artifact_test :: proc(
	t: ^testing.T,
) {
	bytes := marlin_capture_test_artifact(t)
	defer delete(bytes)
	request := contracts.Evidence_Request{
		level = .Primitives,
		item_limit = 1,
		byte_limit = u64(len(bytes)),
	}
	capture, capture_error := marlin_capture_describe(
		"stages/emit-gcode/marlin.bin",
		request,
		{},
		bytes,
	)
	defer marlin_capture_destroy(&capture)
	testing.expect_value(t, capture_error, Marlin_Capture_Error.None)
	testing.expect_value(t, capture.additional.item_count, u64(1))
	testing.expect_value(
		t,
		capture.additional.byte_count,
		u64(len(bytes)),
	)
	testing.expect_value(
		t,
		capture.artifact.path,
		"stages/emit-gcode/marlin.bin",
	)
	testing.expect_value(
		t,
		capture.artifact.format,
		gcode.MARLIN_ARTIFACT_FORMAT,
	)
	testing.expect_value(
		t,
		capture.artifact.schema_version,
		gcode.MARLIN_ARTIFACT_SCHEMA_VERSION,
	)
	decoded, decode_error := gcode.marlin_artifact_decode(capture.bytes)
	defer gcode.marlin_artifact_destroy(&decoded)
	testing.expect_value(t, decode_error, gcode.Marlin_Artifact_Error.None)
	testing.expect_value(t, len(decoded.result.commands), 1)
	testing.expect_value(t, string(decoded.result.bytes), "G21\n")
}

@(test)
marlin_capture_rejects_budget_level_path_and_content_failures_test :: proc(
	t: ^testing.T,
) {
	bytes := marlin_capture_test_artifact(t)
	defer delete(bytes)
	request := contracts.Evidence_Request{
		level = .Primitives,
		item_limit = 1,
		byte_limit = u64(len(bytes)),
	}
	_, item_error := marlin_capture_describe(
		"marlin.bin",
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
		Marlin_Capture_Error.Item_Limit,
	)
	_, byte_error := marlin_capture_describe(
		"marlin.bin",
		{
			level = .Primitives,
			item_limit = 1,
			byte_limit = u64(len(bytes)-1),
		},
		{},
		bytes,
	)
	testing.expect_value(
		t,
		byte_error,
		Marlin_Capture_Error.Byte_Limit,
	)
	_, level_error := marlin_capture_describe(
		"marlin.bin",
		{level = .Summary},
		{},
		bytes,
	)
	testing.expect_value(
		t,
		level_error,
		Marlin_Capture_Error.Level_Insufficient,
	)
	_, path_error := marlin_capture_describe(
		"../marlin.bin",
		request,
		{},
		bytes,
	)
	testing.expect_value(
		t,
		path_error,
		Marlin_Capture_Error.Invalid_Path,
	)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[len(corrupt)-2] = '3'
	_, content_error := marlin_capture_describe(
		"marlin.bin",
		request,
		{},
		corrupt,
	)
	testing.expect_value(
		t,
		content_error,
		Marlin_Capture_Error.Invalid_Record,
	)
}

marlin_capture_test_artifact :: proc(t: ^testing.T) -> []u8 {
	gcode_text := "G21\n"
	result := gcode.Marlin_Result{
		schema_version = gcode.MARLIN_EMITTER_SCHEMA_VERSION,
		bytes = transmute([]u8)gcode_text,
		commands = []gcode.Marlin_Command_Record{
			{
				stable_id = 10,
				kind = .Set_Millimetres,
				byte_count = 4,
				layer_index = max(u32),
			},
		},
		layer_count = 1,
		motion_operation_count = 1,
		positive_filament_nm = 1,
	}
	revisions: contracts.Profile_Revisions
	result_hash, result_ok :=
		gcode.marlin_result_content_hash({}, revisions, result)
	testing.expect(t, result_ok)
	byte_count, size_ok := gcode.marlin_artifact_byte_count(
		u64(len(result.commands)),
		u64(len(result.bytes)),
	)
	testing.expect(t, size_ok)
	bytes := make([]u8, int(byte_count))
	testing.expect(t, bytes != nil)
	for byte, byte_index in gcode.MARLIN_ARTIFACT_MAGIC {
		bytes[byte_index] = byte
	}
	gcode.marlin_artifact_put_u32(
		bytes,
		8,
		gcode.MARLIN_ARTIFACT_SCHEMA_VERSION,
	)
	gcode.marlin_artifact_put_u32(
		bytes,
		12,
		gcode.MARLIN_ARTIFACT_HEADER_SIZE,
	)
	gcode.marlin_artifact_put_u32(
		bytes,
		16,
		gcode.MARLIN_ARTIFACT_COMMAND_SIZE,
	)
	gcode.marlin_artifact_put_u32(
		bytes,
		20,
		gcode.MARLIN_EMITTER_SCHEMA_VERSION,
	)
	gcode.marlin_artifact_put_hash(bytes, 192, result_hash)
	gcode.marlin_artifact_put_u64(bytes, 224, u64(len(result.bytes)))
	gcode.marlin_artifact_put_u64(bytes, 232, u64(len(result.commands)))
	gcode.marlin_artifact_put_u32(bytes, 240, result.layer_count)
	gcode.marlin_artifact_put_u64(
		bytes,
		248,
		result.motion_operation_count,
	)
	gcode.marlin_artifact_put_u128(
		bytes,
		256,
		result.positive_filament_nm,
	)
	offset := int(gcode.MARLIN_ARTIFACT_HEADER_SIZE)
	command := result.commands[0]
	gcode.marlin_artifact_put_u64(bytes, offset, u64(command.stable_id))
	gcode.marlin_artifact_put_u32(
		bytes,
		offset+8,
		command.command_index,
	)
	bytes[offset+12] = u8(command.kind)
	gcode.marlin_artifact_put_u64(
		bytes,
		offset+16,
		command.byte_offset,
	)
	gcode.marlin_artifact_put_u32(
		bytes,
		offset+24,
		command.byte_count,
	)
	gcode.marlin_artifact_put_u32(
		bytes,
		offset+28,
		command.layer_index,
	)
	gcode.marlin_artifact_put_u64(
		bytes,
		offset+32,
		u64(command.source_operation_id),
	)
	offset += int(gcode.MARLIN_ARTIFACT_COMMAND_SIZE)
	copy(bytes[offset:], result.bytes)
	return bytes
}
