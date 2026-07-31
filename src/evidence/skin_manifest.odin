package evidence

import contracts "../contracts"
import features "../features"

SKIN_MANIFEST_STAGE_REVISION :: u32(1)

Skin_Manifest_Expectations :: struct {
	layer_count:            u64,
	mask_count:             u64,
	path_count:             u64,
	point_count:            u64,
	source_reference_count: u64,
	bottom_mask_count:      u64,
	top_mask_count:         u64,
	top_bottom_mask_count:  u64,
	result_hash:            contracts.Content_Hash,
}

Skin_Manifest_Error :: enum u8 {
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

skin_manifest_preflight :: proc(
	manifest: Evidence_Manifest,
	artifact_path: string,
	artifact_bytes: []u8,
	limits := features.DEFAULT_SKIN_ARTIFACT_LIMITS,
) -> (Skin_Manifest_Expectations, Skin_Manifest_Error) {
	if !evidence_manifest_valid(manifest) {
		return {}, .Invalid_Manifest
	}
	if manifest.stage.name != "generate-features" ||
	   manifest.stage.schema_version != features.SCHEMA_VERSION_SKIN_HASH ||
	   manifest.stage.revision != SKIN_MANIFEST_STAGE_REVISION {
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
	if descriptor.format != features.SKIN_ARTIFACT_FORMAT ||
	   descriptor.schema_version != features.SKIN_ARTIFACT_SCHEMA_VERSION {
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
		features.skin_artifact_preflight(artifact_bytes, limits)
	if artifact_error != .None {return {}, .Summary_Mismatch}
	item_count, count_ok := skin_capture_item_count(artifact_summary)
	if !count_ok || descriptor.item_count != item_count {
		return {}, .Summary_Mismatch
	}
	expectations := Skin_Manifest_Expectations{
		layer_count = artifact_summary.layer_count,
		mask_count = artifact_summary.mask_count,
		path_count = artifact_summary.path_count,
		point_count = artifact_summary.point_count,
		source_reference_count = artifact_summary.source_reference_count,
		bottom_mask_count = artifact_summary.bottom_mask_count,
		top_mask_count = artifact_summary.top_mask_count,
		top_bottom_mask_count = artifact_summary.top_bottom_mask_count,
	}
	summary_matches :=
		skin_manifest_counter_matches(
			manifest,
			"skin_layers",
			expectations.layer_count,
		) &&
		skin_manifest_counter_matches(
			manifest,
			"skin_masks",
			expectations.mask_count,
		) &&
		skin_manifest_counter_matches(
			manifest,
			"skin_paths",
			expectations.path_count,
		) &&
		skin_manifest_counter_matches(
			manifest,
			"skin_points",
			expectations.point_count,
		) &&
		skin_manifest_counter_matches(
			manifest,
			"skin_source_references",
			expectations.source_reference_count,
		) &&
		skin_manifest_counter_matches(
			manifest,
			"skin_bottom_masks",
			expectations.bottom_mask_count,
		) &&
		skin_manifest_counter_matches(
			manifest,
			"skin_top_masks",
			expectations.top_mask_count,
		) &&
		skin_manifest_counter_matches(
			manifest,
			"skin_top_bottom_masks",
			expectations.top_bottom_mask_count,
		)
	if !summary_matches {return {}, .Summary_Mismatch}
	result_invariant, result_invariant_ok := path_plan_manifest_invariant(
		manifest,
		"canonical_skin_result_hash",
	)
	if !result_invariant_ok ||
	   !result_invariant.passed ||
	   result_invariant.observed != result_invariant.expected {
		return {}, .Invariant_Mismatch
	}
	expectations.result_hash, result_invariant_ok =
		path_plan_manifest_hash_parse(result_invariant.expected)
	if !result_invariant_ok {return {}, .Invariant_Mismatch}
	replay_invariant, replay_invariant_ok := path_plan_manifest_invariant(
		manifest,
		"source_independent_skin_replay",
	)
	if !replay_invariant_ok ||
	   !replay_invariant.passed ||
	   replay_invariant.observed != "passed" ||
	   replay_invariant.expected != "passed" {
		return {}, .Invariant_Mismatch
	}
	return expectations, .None
}

skin_manifest_replay_verify :: proc(
	expectations: Skin_Manifest_Expectations,
	artifact: features.Skin_Artifact,
) -> Skin_Manifest_Error {
	result := artifact.result
	if u64(len(result.layers)) != expectations.layer_count ||
	   u64(len(result.masks)) != expectations.mask_count ||
	   u64(len(result.paths)) != expectations.path_count ||
	   u64(len(result.points)) != expectations.point_count ||
	   u64(len(result.source_references)) !=
	    expectations.source_reference_count ||
	   result.bottom_mask_count != expectations.bottom_mask_count ||
	   result.top_mask_count != expectations.top_mask_count ||
	   result.top_bottom_mask_count != expectations.top_bottom_mask_count ||
	   artifact.result_hash != expectations.result_hash {
		return .Result_Mismatch
	}
	return .None
}

skin_manifest_counter_matches :: proc(
	manifest: Evidence_Manifest,
	name: string,
	expected: u64,
) -> bool {
	value, found := path_plan_manifest_counter(manifest, name)
	return found && value == expected
}
