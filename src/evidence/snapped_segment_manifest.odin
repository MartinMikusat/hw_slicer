package evidence

import contracts "../contracts"
import slicing "../slicing"

SNAPPED_SEGMENT_MANIFEST_STAGE_REVISION :: u32(1)

Snapped_Segment_Manifest_Expectations :: struct {
	layer_count:     u64,
	segment_count:   u64,
	collapsed_count: u64,
	result_hash:     contracts.Content_Hash,
}

Snapped_Segment_Manifest_Error :: enum u8 {
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

snapped_segment_manifest_preflight :: proc(
	manifest: Evidence_Manifest,
	artifact_path: string,
	artifact_bytes: []u8,
	limits := DEFAULT_SNAPPED_SEGMENT_ARTIFACT_LIMITS,
) -> (
	Snapped_Segment_Manifest_Expectations,
	Snapped_Segment_Manifest_Error,
) {
	if !evidence_manifest_valid(manifest) {
		return {}, .Invalid_Manifest
	}
	if manifest.stage.name != "intersect" ||
	   manifest.stage.schema_version !=
		slicing.SCHEMA_VERSION_SNAPPED_SEGMENT_HASH ||
	   manifest.stage.revision !=
		SNAPPED_SEGMENT_MANIFEST_STAGE_REVISION {
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
	if descriptor.format != SNAPPED_SEGMENT_ARTIFACT_FORMAT ||
	   descriptor.schema_version !=
		SNAPPED_SEGMENT_ARTIFACT_SCHEMA_VERSION {
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
		snapped_segment_artifact_preflight(artifact_bytes, limits)
	if artifact_error != .None {return {}, .Summary_Mismatch}
	item_count, count_ok :=
		snapped_segment_capture_item_count(artifact_summary)
	if !count_ok || descriptor.item_count != item_count {
		return {}, .Summary_Mismatch
	}
	expectations := Snapped_Segment_Manifest_Expectations{
		layer_count = artifact_summary.layer_count,
		segment_count = artifact_summary.segment_count,
		collapsed_count = artifact_summary.collapsed_count,
	}
	summary_matches :=
		snapped_segment_manifest_counter_matches(
			manifest,
			"snapped_layers",
			expectations.layer_count,
		) &&
		snapped_segment_manifest_counter_matches(
			manifest,
			"snapped_segments",
			expectations.segment_count,
		) &&
		snapped_segment_manifest_counter_matches(
			manifest,
			"collapsed_segments",
			expectations.collapsed_count,
		) &&
		snapped_segment_manifest_counter_matches(
			manifest,
			"snap_grid_um",
			u64(slicing.ENDPOINT_SNAP_GRID_UM),
		)
	if !summary_matches {return {}, .Summary_Mismatch}
	result_invariant, result_invariant_ok :=
		path_plan_manifest_invariant(
			manifest,
			"canonical_snapped_segment_result_hash",
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
			"source_independent_snapped_segment_replay",
		)
	if !replay_invariant_ok ||
	   !replay_invariant.passed ||
	   replay_invariant.observed != "passed" ||
	   replay_invariant.expected != "passed" {
		return {}, .Invariant_Mismatch
	}
	return expectations, .None
}

snapped_segment_manifest_replay_verify :: proc(
	expectations: Snapped_Segment_Manifest_Expectations,
	artifact: Snapped_Segment_Artifact,
) -> Snapped_Segment_Manifest_Error {
	summary := snapped_segment_artifact_summary(artifact.result)
	if summary.layer_count != expectations.layer_count ||
	   summary.segment_count != expectations.segment_count ||
	   summary.collapsed_count != expectations.collapsed_count ||
	   artifact.result_hash != expectations.result_hash {
		return .Result_Mismatch
	}
	return .None
}

snapped_segment_manifest_counter_matches :: proc(
	manifest: Evidence_Manifest,
	name: string,
	expected: u64,
) -> bool {
	value, found := path_plan_manifest_counter(manifest, name)
	return found && value == expected
}
