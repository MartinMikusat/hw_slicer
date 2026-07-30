package evidence

import contracts "../contracts"
import features "../features"

UNIFIED_PATH_SOURCE_MANIFEST_STAGE_REVISION :: u32(1)

Unified_Path_Source_Manifest_Expectations :: struct {
	layer_count:  u64,
	source_count: u64,
	point_count:  u64,
	result_hash:  contracts.Content_Hash,
}

Unified_Path_Source_Manifest_Error :: enum u8 {
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

unified_path_source_manifest_preflight :: proc(
	manifest: Evidence_Manifest,
	artifact_path: string,
	artifact_bytes: []u8,
	limits := features.DEFAULT_UNIFIED_PATH_SOURCE_ARTIFACT_LIMITS,
) -> (
	Unified_Path_Source_Manifest_Expectations,
	Unified_Path_Source_Manifest_Error,
) {
	if !evidence_manifest_valid(manifest) {
		return {}, .Invalid_Manifest
	}
	if manifest.stage.name != "generate-features" ||
	   manifest.stage.schema_version !=
		features.SCHEMA_VERSION_UNIFIED_PATH_SOURCE_HASH ||
	   manifest.stage.revision !=
		UNIFIED_PATH_SOURCE_MANIFEST_STAGE_REVISION {
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
	if descriptor.format !=
		features.UNIFIED_PATH_SOURCE_ARTIFACT_FORMAT ||
	   descriptor.schema_version !=
		features.UNIFIED_PATH_SOURCE_ARTIFACT_SCHEMA_VERSION {
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
		features.unified_path_source_artifact_preflight(
			artifact_bytes,
			limits,
		)
	if artifact_error != .None {return {}, .Summary_Mismatch}
	if artifact_summary.layer_count >
	   max(u64)-artifact_summary.source_count ||
	   artifact_summary.layer_count+artifact_summary.source_count >
		max(u64)-artifact_summary.point_count ||
	   descriptor.item_count !=
		artifact_summary.layer_count+
		artifact_summary.source_count+
		artifact_summary.point_count {
		return {}, .Summary_Mismatch
	}
	expectations := Unified_Path_Source_Manifest_Expectations{
		layer_count = artifact_summary.layer_count,
		source_count = artifact_summary.source_count,
		point_count = artifact_summary.point_count,
	}
	summary_matches :=
		unified_path_source_manifest_counter_matches(
			manifest,
			"feature_source_layers",
			expectations.layer_count,
		) &&
		unified_path_source_manifest_counter_matches(
			manifest,
			"feature_sources",
			expectations.source_count,
		) &&
		unified_path_source_manifest_counter_matches(
			manifest,
			"feature_source_points",
			expectations.point_count,
		)
	if !summary_matches {return {}, .Summary_Mismatch}
	result_invariant, result_invariant_ok :=
		path_plan_manifest_invariant(
			manifest,
			"canonical_unified_source_result_hash",
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
			"source_independent_unified_source_replay",
		)
	if !replay_invariant_ok ||
	   !replay_invariant.passed ||
	   replay_invariant.observed != "passed" ||
	   replay_invariant.expected != "passed" {
		return {}, .Invariant_Mismatch
	}
	return expectations, .None
}

unified_path_source_manifest_replay_verify :: proc(
	expectations: Unified_Path_Source_Manifest_Expectations,
	artifact: features.Unified_Path_Source_Artifact,
) -> Unified_Path_Source_Manifest_Error {
	result := artifact.result
	if u64(len(result.layers)) != expectations.layer_count ||
	   u64(len(result.sources)) != expectations.source_count ||
	   u64(len(result.points)) != expectations.point_count ||
	   artifact.result_hash != expectations.result_hash {
		return .Result_Mismatch
	}
	return .None
}

unified_path_source_manifest_counter_matches :: proc(
	manifest: Evidence_Manifest,
	name: string,
	expected: u64,
) -> bool {
	value, found := path_plan_manifest_counter(manifest, name)
	return found && value == expected
}
