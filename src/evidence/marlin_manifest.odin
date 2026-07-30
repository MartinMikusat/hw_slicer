package evidence

import contracts "../contracts"
import gcode "../gcode"

MARLIN_MANIFEST_STAGE_REVISION :: u32(1)

Marlin_Manifest_Expectations :: struct {
	command_count:          u64,
	gcode_byte_count:       u64,
	layer_count:            u32,
	motion_operation_count: u64,
	emitted_dwell_ms:       u64,
	shutdown_retraction_nm: u64,
	result_hash:            contracts.Content_Hash,
}

Marlin_Manifest_Error :: enum u8 {
	None,
	Invalid_Manifest,
	Stage_Mismatch,
	Artifact_Missing,
	Artifact_Format_Mismatch,
	Artifact_Byte_Count_Mismatch,
	Artifact_Hash_Mismatch,
	Summary_Mismatch,
	Invariant_Mismatch,
	Result_Mismatch,
}

marlin_manifest_preflight :: proc(
	manifest: Evidence_Manifest,
	artifact_path: string,
	artifact_bytes: []u8,
	limits := gcode.DEFAULT_MARLIN_ARTIFACT_LIMITS,
) -> (Marlin_Manifest_Expectations, Marlin_Manifest_Error) {
	if !evidence_manifest_valid(manifest) {
		return {}, .Invalid_Manifest
	}
	if manifest.stage.name != "emit-gcode" ||
	   manifest.stage.schema_version != gcode.MARLIN_EMITTER_SCHEMA_VERSION ||
	   manifest.stage.revision != MARLIN_MANIFEST_STAGE_REVISION {
		return {}, .Stage_Mismatch
	}
	descriptor: Evidence_Artifact
	descriptor_found := false
	for primitive in manifest.primitives {
		if primitive.path == artifact_path {
			descriptor = primitive
			descriptor_found = true
			break
		}
	}
	if !descriptor_found {return {}, .Artifact_Missing}
	if descriptor.format != gcode.MARLIN_ARTIFACT_FORMAT ||
	   descriptor.schema_version != gcode.MARLIN_ARTIFACT_SCHEMA_VERSION {
		return {}, .Artifact_Format_Mismatch
	}
	switch evidence_artifact_verify(descriptor, artifact_bytes) {
	case .None:
	case .Invalid_Descriptor:
		return {}, .Invalid_Manifest
	case .Byte_Count_Mismatch:
		return {}, .Artifact_Byte_Count_Mismatch
	case .Hash_Mismatch:
		return {}, .Artifact_Hash_Mismatch
	}
	artifact_summary, artifact_error :=
		gcode.marlin_artifact_preflight(artifact_bytes, limits)
	if artifact_error != .None {
		return {}, .Summary_Mismatch
	}
	expectations := Marlin_Manifest_Expectations{
		command_count = artifact_summary.command_count,
		gcode_byte_count = artifact_summary.gcode_byte_count,
		layer_count = artifact_summary.layer_count,
		motion_operation_count =
			artifact_summary.motion_operation_count,
		emitted_dwell_ms = artifact_summary.emitted_dwell_ms,
		shutdown_retraction_nm =
			artifact_summary.shutdown_retraction_nm,
	}
	commands_match := marlin_manifest_counter_matches(
		manifest,
		"commands",
		expectations.command_count,
	)
	gcode_bytes_match := marlin_manifest_counter_matches(
		manifest,
		"gcode_bytes",
		expectations.gcode_byte_count,
	)
	layers_match := marlin_manifest_counter_matches(
		manifest,
		"layers",
		u64(expectations.layer_count),
	)
	motion_operations_match := marlin_manifest_counter_matches(
		manifest,
		"motion_operations",
		expectations.motion_operation_count,
	)
	dwell_match := marlin_manifest_counter_matches(
		manifest,
		"dwell_ms",
		expectations.emitted_dwell_ms,
	)
	shutdown_retraction_match := marlin_manifest_counter_matches(
		manifest,
		"shutdown_retraction_nm",
		expectations.shutdown_retraction_nm,
	)
	if descriptor.item_count != expectations.command_count ||
	   !commands_match ||
	   !gcode_bytes_match ||
	   !layers_match ||
	   !motion_operations_match ||
	   !dwell_match ||
	   !shutdown_retraction_match {
		return {}, .Summary_Mismatch
	}
	result_invariant, result_invariant_ok :=
		path_plan_manifest_invariant(manifest, "canonical_result_hash")
	if !result_invariant_ok ||
	   !result_invariant.passed ||
	   result_invariant.observed != result_invariant.expected {
		return {}, .Invariant_Mismatch
	}
	expectations.result_hash, result_invariant_ok =
		path_plan_manifest_hash_parse(result_invariant.expected)
	if !result_invariant_ok {return {}, .Invariant_Mismatch}
	replay_invariant, replay_invariant_ok :=
		path_plan_manifest_invariant(manifest, "source_independent_replay")
	if !replay_invariant_ok ||
	   !replay_invariant.passed ||
	   replay_invariant.observed != "passed" ||
	   replay_invariant.expected != "passed" {
		return {}, .Invariant_Mismatch
	}
	return expectations, .None
}

marlin_manifest_replay_verify :: proc(
	expectations: Marlin_Manifest_Expectations,
	artifact: gcode.Marlin_Artifact,
) -> Marlin_Manifest_Error {
	result := artifact.result
	shutdown_retraction_matches :=
		result.shutdown_retraction_nm ==
		expectations.shutdown_retraction_nm
	if u64(len(result.commands)) != expectations.command_count ||
	   u64(len(result.bytes)) != expectations.gcode_byte_count ||
	   result.layer_count != expectations.layer_count ||
	   result.motion_operation_count != expectations.motion_operation_count ||
	   result.emitted_dwell_ms != expectations.emitted_dwell_ms ||
	   !shutdown_retraction_matches ||
	   artifact.result_hash != expectations.result_hash {
		return .Result_Mismatch
	}
	return .None
}

marlin_manifest_counter_matches :: proc(
	manifest: Evidence_Manifest,
	name: string,
	expected: u64,
) -> bool {
	value, found := path_plan_manifest_counter(manifest, name)
	return found && value == expected
}
