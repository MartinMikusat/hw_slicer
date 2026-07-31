package evidence

import contracts "../contracts"
import slicing "../slicing"

PLANAR_OWNERSHIP_MANIFEST_STAGE_REVISION :: u32(1)

Planar_Ownership_Manifest_Expectations :: struct {
	layer_count:               u64,
	segment_count:             u64,
	incidence_count:           u64,
	unresolved_group_count:    u64,
	suppressed_group_count:    u64,
	collapsed_incidence_count: u64,
	exact_predicate_count:     u64,
	result_hash:               contracts.Content_Hash,
}

Planar_Ownership_Manifest_Error :: enum u8 {
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

planar_ownership_manifest_preflight :: proc(
	manifest: Evidence_Manifest,
	artifact_path: string,
	artifact_bytes: []u8,
	limits := DEFAULT_PLANAR_OWNERSHIP_ARTIFACT_LIMITS,
) -> (
	Planar_Ownership_Manifest_Expectations,
	Planar_Ownership_Manifest_Error,
) {
	if !evidence_manifest_valid(manifest) {
		return {}, .Invalid_Manifest
	}
	if manifest.stage.name != "intersect" ||
	   manifest.stage.schema_version !=
		slicing.SCHEMA_VERSION_PLANAR_OWNERSHIP_HASH ||
	   manifest.stage.revision !=
		PLANAR_OWNERSHIP_MANIFEST_STAGE_REVISION {
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
	if descriptor.format != PLANAR_OWNERSHIP_ARTIFACT_FORMAT ||
	   descriptor.schema_version !=
		PLANAR_OWNERSHIP_ARTIFACT_SCHEMA_VERSION {
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
		planar_ownership_artifact_preflight(artifact_bytes, limits)
	if artifact_error != .None {return {}, .Summary_Mismatch}
	item_count, count_ok :=
		planar_ownership_capture_item_count(artifact_summary)
	if !count_ok || descriptor.item_count != item_count {
		return {}, .Summary_Mismatch
	}
	expectations := Planar_Ownership_Manifest_Expectations{
		layer_count = artifact_summary.layer_count,
		segment_count = artifact_summary.segment_count,
		incidence_count = artifact_summary.incidence_count,
		unresolved_group_count =
			artifact_summary.unresolved_group_count,
		suppressed_group_count =
			artifact_summary.suppressed_group_count,
		collapsed_incidence_count =
			artifact_summary.collapsed_incidence_count,
		exact_predicate_count =
			artifact_summary.exact_predicate_count,
	}
	summary_matches :=
		planar_ownership_manifest_counter_matches(
			manifest,
			"ownership_layers",
			expectations.layer_count,
		) &&
		planar_ownership_manifest_counter_matches(
			manifest,
			"owned_segments",
			expectations.segment_count,
		) &&
		planar_ownership_manifest_counter_matches(
			manifest,
			"planar_incidences",
			expectations.incidence_count,
		) &&
		planar_ownership_manifest_counter_matches(
			manifest,
			"unresolved_groups",
			expectations.unresolved_group_count,
		) &&
		planar_ownership_manifest_counter_matches(
			manifest,
			"suppressed_groups",
			expectations.suppressed_group_count,
		) &&
		planar_ownership_manifest_counter_matches(
			manifest,
			"collapsed_incidences",
			expectations.collapsed_incidence_count,
		) &&
		planar_ownership_manifest_counter_matches(
			manifest,
			"ownership_exact_predicates",
			expectations.exact_predicate_count,
		)
	if !summary_matches {return {}, .Summary_Mismatch}
	result_invariant, result_invariant_ok :=
		path_plan_manifest_invariant(
			manifest,
			"canonical_planar_ownership_result_hash",
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
			"source_independent_planar_ownership_replay",
		)
	if !replay_invariant_ok ||
	   !replay_invariant.passed ||
	   replay_invariant.observed != "passed" ||
	   replay_invariant.expected != "passed" {
		return {}, .Invariant_Mismatch
	}
	return expectations, .None
}

planar_ownership_manifest_replay_verify :: proc(
	expectations: Planar_Ownership_Manifest_Expectations,
	artifact: Planar_Ownership_Artifact,
) -> Planar_Ownership_Manifest_Error {
	summary := planar_ownership_artifact_summary(artifact.result)
	if summary.layer_count != expectations.layer_count ||
	   summary.segment_count != expectations.segment_count ||
	   summary.incidence_count != expectations.incidence_count ||
	   summary.unresolved_group_count !=
	   	expectations.unresolved_group_count ||
	   summary.suppressed_group_count !=
	   	expectations.suppressed_group_count ||
	   summary.collapsed_incidence_count !=
	   	expectations.collapsed_incidence_count ||
	   summary.exact_predicate_count !=
	   	expectations.exact_predicate_count ||
	   artifact.result_hash != expectations.result_hash {
		return .Result_Mismatch
	}
	return .None
}

planar_ownership_manifest_counter_matches :: proc(
	manifest: Evidence_Manifest,
	name: string,
	expected: u64,
) -> bool {
	value, found := path_plan_manifest_counter(manifest, name)
	return found && value == expected
}
