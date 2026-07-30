package evidence

import contracts "../contracts"
import slicing "../slicing"

LAYER_SPAN_MANIFEST_STAGE_REVISION :: u32(1)

Layer_Span_Manifest_Expectations :: struct {
	triangle_count:          u64,
	layer_count:             u64,
	pair_count:              u64,
	crossing_triangle_count: u64,
	planar_triangle_count:   u64,
	inactive_triangle_count: u64,
	result_hash:             contracts.Content_Hash,
}

Layer_Span_Manifest_Error :: enum u8 {
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

layer_span_manifest_preflight :: proc(
	manifest: Evidence_Manifest,
	artifact_path: string,
	artifact_bytes: []u8,
	limits := DEFAULT_LAYER_SPAN_ARTIFACT_LIMITS,
) -> (
	Layer_Span_Manifest_Expectations,
	Layer_Span_Manifest_Error,
) {
	if !evidence_manifest_valid(manifest) {
		return {}, .Invalid_Manifest
	}
	if manifest.stage.name != "build-acceleration" ||
	   manifest.stage.schema_version !=
		slicing.SCHEMA_VERSION_LAYER_SPAN_INDEX_HASH ||
	   manifest.stage.revision !=
		LAYER_SPAN_MANIFEST_STAGE_REVISION {
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
	if descriptor.format != LAYER_SPAN_ARTIFACT_FORMAT ||
	   descriptor.schema_version != LAYER_SPAN_ARTIFACT_SCHEMA_VERSION {
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
		layer_span_artifact_preflight(artifact_bytes, limits)
	if artifact_error != .None {return {}, .Summary_Mismatch}
	item_count, count_ok := layer_span_capture_item_count(artifact_summary)
	if !count_ok || descriptor.item_count != item_count {
		return {}, .Summary_Mismatch
	}
	expectations := Layer_Span_Manifest_Expectations{
		triangle_count = artifact_summary.triangle_count,
		layer_count = artifact_summary.layer_count,
		pair_count = artifact_summary.pair_count,
		crossing_triangle_count =
			artifact_summary.crossing_triangle_count,
		planar_triangle_count =
			artifact_summary.planar_triangle_count,
		inactive_triangle_count =
			artifact_summary.inactive_triangle_count,
	}
	summary_matches :=
		layer_span_manifest_counter_matches(
			manifest,
			"span_triangles",
			expectations.triangle_count,
		) &&
		layer_span_manifest_counter_matches(
			manifest,
			"span_layers",
			expectations.layer_count,
		) &&
		layer_span_manifest_counter_matches(
			manifest,
			"triangle_layer_pairs",
			expectations.pair_count,
		) &&
		layer_span_manifest_counter_matches(
			manifest,
			"crossing_triangles",
			expectations.crossing_triangle_count,
		) &&
		layer_span_manifest_counter_matches(
			manifest,
			"planar_triangles",
			expectations.planar_triangle_count,
		) &&
		layer_span_manifest_counter_matches(
			manifest,
			"inactive_triangles",
			expectations.inactive_triangle_count,
		)
	if !summary_matches {return {}, .Summary_Mismatch}
	result_invariant, result_invariant_ok :=
		path_plan_manifest_invariant(
			manifest,
			"canonical_layer_span_result_hash",
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
			"source_independent_layer_span_replay",
		)
	if !replay_invariant_ok ||
	   !replay_invariant.passed ||
	   replay_invariant.observed != "passed" ||
	   replay_invariant.expected != "passed" {
		return {}, .Invariant_Mismatch
	}
	return expectations, .None
}

layer_span_manifest_replay_verify :: proc(
	expectations: Layer_Span_Manifest_Expectations,
	artifact: Layer_Span_Artifact,
) -> Layer_Span_Manifest_Error {
	summary, summary_error := layer_span_artifact_preflight_summary(
		artifact.result,
	)
	if summary_error ||
	   summary.triangle_count != expectations.triangle_count ||
	   summary.layer_count != expectations.layer_count ||
	   summary.pair_count != expectations.pair_count ||
	   summary.crossing_triangle_count !=
	   	expectations.crossing_triangle_count ||
	   summary.planar_triangle_count !=
	   	expectations.planar_triangle_count ||
	   summary.inactive_triangle_count !=
	   	expectations.inactive_triangle_count ||
	   artifact.result_hash != expectations.result_hash {
		return .Result_Mismatch
	}
	return .None
}

layer_span_artifact_preflight_summary :: proc(
	result: slicing.Layer_Span_Index,
) -> (Layer_Span_Artifact_Summary, bool) {
	summary := Layer_Span_Artifact_Summary{
		triangle_count = u64(len(result.triangle_ranges)),
		layer_count = u64(len(result.layers)),
		pair_count = u64(len(result.triangle_ids)),
	}
	for range_value in result.triangle_ranges {
		switch range_value.kind {
		case .None:
			summary.inactive_triangle_count += 1
		case .Crossing_Candidates:
			summary.crossing_triangle_count += 1
		case .Quantized_Planar:
			summary.planar_triangle_count += 1
		case:
			return {}, true
		}
	}
	return summary, false
}

layer_span_manifest_counter_matches :: proc(
	manifest: Evidence_Manifest,
	name: string,
	expected: u64,
) -> bool {
	value, found := path_plan_manifest_counter(manifest, name)
	return found && value == expected
}
