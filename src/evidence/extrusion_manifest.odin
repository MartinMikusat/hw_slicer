package evidence

import contracts "../contracts"
import features "../features"

EXTRUSION_MANIFEST_STAGE_REVISION :: u32(1)

Extrusion_Manifest_Expectations :: struct {
	layer_count:            u64,
	move_count:             u64,
	total_volume_cubic_um:  u64,
	total_volume_numerator: u128,
	total_filament_nm:      u128,
	result_hash:            contracts.Content_Hash,
}

Extrusion_Manifest_Error :: enum u8 {
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

extrusion_manifest_preflight :: proc(
	manifest: Evidence_Manifest,
	artifact_path: string,
	artifact_bytes: []u8,
	limits := features.DEFAULT_EXTRUSION_ARTIFACT_LIMITS,
) -> (
	Extrusion_Manifest_Expectations,
	Extrusion_Manifest_Error,
) {
	if !evidence_manifest_valid(manifest) {
		return {}, .Invalid_Manifest
	}
	if manifest.stage.name != "plan-paths" ||
	   manifest.stage.schema_version !=
		features.SCHEMA_VERSION_EXTRUSION_HASH ||
	   manifest.stage.revision != EXTRUSION_MANIFEST_STAGE_REVISION {
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
	if descriptor.format != features.EXTRUSION_ARTIFACT_FORMAT ||
	   descriptor.schema_version !=
		features.EXTRUSION_ARTIFACT_SCHEMA_VERSION {
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
		features.extrusion_artifact_preflight(artifact_bytes, limits)
	if artifact_error != .None {return {}, .Summary_Mismatch}
	if artifact_summary.layer_count >
	   max(u64)-artifact_summary.move_count ||
	   descriptor.item_count !=
		artifact_summary.layer_count+artifact_summary.move_count {
		return {}, .Summary_Mismatch
	}
	expectations := Extrusion_Manifest_Expectations{
		layer_count = artifact_summary.layer_count,
		move_count = artifact_summary.move_count,
		total_volume_cubic_um =
			artifact_summary.total_volume_cubic_um,
		total_volume_numerator =
			artifact_summary.total_volume_numerator,
		total_filament_nm = artifact_summary.total_filament_nm,
	}
	summary_matches :=
		extrusion_manifest_counter_matches(
			manifest,
			"extrusion_layers",
			expectations.layer_count,
		) &&
		extrusion_manifest_counter_matches(
			manifest,
			"extrusion_moves",
			expectations.move_count,
		) &&
		extrusion_manifest_counter_matches(
			manifest,
			"extrusion_volume_cubic_um",
			expectations.total_volume_cubic_um,
		)
	if !summary_matches {return {}, .Summary_Mismatch}
	result_invariant, result_invariant_ok :=
		path_plan_manifest_invariant(
			manifest,
			"canonical_extrusion_result_hash",
		)
	if !result_invariant_ok ||
	   !result_invariant.passed ||
	   result_invariant.observed != result_invariant.expected {
		return {}, .Invariant_Mismatch
	}
	expectations.result_hash, result_invariant_ok =
		path_plan_manifest_hash_parse(result_invariant.expected)
	if !result_invariant_ok {return {}, .Invariant_Mismatch}
	replay_invariant, replay_invariant_ok :=
		path_plan_manifest_invariant(
			manifest,
			"source_independent_extrusion_replay",
		)
	if !replay_invariant_ok ||
	   !replay_invariant.passed ||
	   replay_invariant.observed != "passed" ||
	   replay_invariant.expected != "passed" {
		return {}, .Invariant_Mismatch
	}
	return expectations, .None
}

extrusion_manifest_replay_verify :: proc(
	expectations: Extrusion_Manifest_Expectations,
	artifact: features.Extrusion_Artifact,
) -> Extrusion_Manifest_Error {
	result := artifact.result
	if u64(len(result.layers)) != expectations.layer_count ||
	   u64(len(result.moves)) != expectations.move_count ||
	   result.total_volume_cubic_um !=
		expectations.total_volume_cubic_um ||
	   result.total_volume_numerator !=
		expectations.total_volume_numerator ||
	   result.total_filament_nm != expectations.total_filament_nm ||
	   artifact.result_hash != expectations.result_hash {
		return .Result_Mismatch
	}
	return .None
}

extrusion_manifest_counter_matches :: proc(
	manifest: Evidence_Manifest,
	name: string,
	expected: u64,
) -> bool {
	value, found := path_plan_manifest_counter(manifest, name)
	return found && value == expected
}
