package evidence

import contracts "../contracts"
import slicing "../slicing"

CPU_INTERSECTION_MANIFEST_STAGE_REVISION :: u32(1)

CPU_Intersection_Manifest_Expectations :: struct {
	layer_count:           u64,
	segment_count:         u64,
	planar_candidate_count: u64,
	tangent_count:         u64,
	degenerate_count:      u64,
	exact_predicate_count: u64,
	result_hash:           contracts.Content_Hash,
}

CPU_Intersection_Manifest_Error :: enum u8 {
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

cpu_intersection_manifest_preflight :: proc(
	manifest: Evidence_Manifest,
	artifact_path: string,
	artifact_bytes: []u8,
	limits := DEFAULT_CPU_INTERSECTION_ARTIFACT_LIMITS,
) -> (
	CPU_Intersection_Manifest_Expectations,
	CPU_Intersection_Manifest_Error,
) {
	if !evidence_manifest_valid(manifest) {
		return {}, .Invalid_Manifest
	}
	if manifest.stage.name != "intersect" ||
	   manifest.stage.schema_version !=
		slicing.SCHEMA_VERSION_CPU_INTERSECTION_HASH ||
	   manifest.stage.revision !=
		CPU_INTERSECTION_MANIFEST_STAGE_REVISION {
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
	if descriptor.format != CPU_INTERSECTION_ARTIFACT_FORMAT ||
	   descriptor.schema_version !=
		CPU_INTERSECTION_ARTIFACT_SCHEMA_VERSION {
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
		cpu_intersection_artifact_preflight(artifact_bytes, limits)
	if artifact_error != .None {return {}, .Summary_Mismatch}
	item_count, count_ok :=
		cpu_intersection_capture_item_count(artifact_summary)
	if !count_ok || descriptor.item_count != item_count {
		return {}, .Summary_Mismatch
	}
	expectations := CPU_Intersection_Manifest_Expectations{
		layer_count = artifact_summary.layer_count,
		segment_count = artifact_summary.segment_count,
		planar_candidate_count =
			artifact_summary.planar_candidate_count,
		tangent_count = artifact_summary.tangent_count,
		degenerate_count = artifact_summary.degenerate_count,
		exact_predicate_count =
			artifact_summary.exact_predicate_count,
	}
	summary_matches :=
		cpu_intersection_manifest_counter_matches(
			manifest,
			"intersection_layers",
			expectations.layer_count,
		) &&
		cpu_intersection_manifest_counter_matches(
			manifest,
			"raw_segments",
			expectations.segment_count,
		) &&
		cpu_intersection_manifest_counter_matches(
			manifest,
			"planar_candidates",
			expectations.planar_candidate_count,
		) &&
		cpu_intersection_manifest_counter_matches(
			manifest,
			"tangent_pairs",
			expectations.tangent_count,
		) &&
		cpu_intersection_manifest_counter_matches(
			manifest,
			"degenerate_pairs",
			expectations.degenerate_count,
		) &&
		cpu_intersection_manifest_counter_matches(
			manifest,
			"exact_predicates",
			expectations.exact_predicate_count,
		)
	if !summary_matches {return {}, .Summary_Mismatch}
	result_invariant, result_invariant_ok :=
		path_plan_manifest_invariant(
			manifest,
			"canonical_intersection_result_hash",
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
			"source_independent_intersection_replay",
		)
	if !replay_invariant_ok ||
	   !replay_invariant.passed ||
	   replay_invariant.observed != "passed" ||
	   replay_invariant.expected != "passed" {
		return {}, .Invariant_Mismatch
	}
	return expectations, .None
}

cpu_intersection_manifest_replay_verify :: proc(
	expectations: CPU_Intersection_Manifest_Expectations,
	artifact: CPU_Intersection_Artifact,
) -> CPU_Intersection_Manifest_Error {
	summary := cpu_intersection_artifact_summary(artifact.result)
	if summary.layer_count != expectations.layer_count ||
	   summary.segment_count != expectations.segment_count ||
	   summary.planar_candidate_count !=
	   	expectations.planar_candidate_count ||
	   summary.tangent_count != expectations.tangent_count ||
	   summary.degenerate_count != expectations.degenerate_count ||
	   summary.exact_predicate_count !=
	   	expectations.exact_predicate_count ||
	   artifact.result_hash != expectations.result_hash {
		return .Result_Mismatch
	}
	return .None
}

cpu_intersection_manifest_counter_matches :: proc(
	manifest: Evidence_Manifest,
	name: string,
	expected: u64,
) -> bool {
	value, found := path_plan_manifest_counter(manifest, name)
	return found && value == expected
}
