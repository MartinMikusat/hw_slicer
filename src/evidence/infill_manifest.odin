package evidence

import contracts "../contracts"
import features "../features"

INFILL_MANIFEST_STAGE_REVISION :: u32(1)

Infill_Manifest_Expectations :: struct {
	layer_count:    u64,
	segment_count:  u64,
	hit_count:      u64,
	scanline_count: u64,
	result_hash:    contracts.Content_Hash,
}

Infill_Manifest_Error :: enum u8 {
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

infill_manifest_preflight :: proc(
	manifest: Evidence_Manifest,
	artifact_path: string,
	artifact_bytes: []u8,
	limits := features.DEFAULT_INFILL_ARTIFACT_LIMITS,
) -> (Infill_Manifest_Expectations, Infill_Manifest_Error) {
	if !evidence_manifest_valid(manifest) {
		return {}, .Invalid_Manifest
	}
	if manifest.stage.name != "generate-features" ||
	   manifest.stage.schema_version !=
		features.SCHEMA_VERSION_INFILL_HASH ||
	   manifest.stage.revision != INFILL_MANIFEST_STAGE_REVISION {
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
	if descriptor.format != features.INFILL_ARTIFACT_FORMAT ||
	   descriptor.schema_version !=
		features.INFILL_ARTIFACT_SCHEMA_VERSION {
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
		features.infill_artifact_preflight(artifact_bytes, limits)
	if artifact_error != .None {return {}, .Summary_Mismatch}
	if artifact_summary.layer_count >
	   max(u64)-artifact_summary.segment_count ||
	   artifact_summary.layer_count+artifact_summary.segment_count >
		max(u64)-artifact_summary.hit_count ||
	   descriptor.item_count !=
		artifact_summary.layer_count+
		artifact_summary.segment_count+
		artifact_summary.hit_count {
		return {}, .Summary_Mismatch
	}
	expectations := Infill_Manifest_Expectations{
		layer_count = artifact_summary.layer_count,
		segment_count = artifact_summary.segment_count,
		hit_count = artifact_summary.hit_count,
		scanline_count = artifact_summary.scanline_count,
	}
	summary_matches :=
		infill_manifest_counter_matches(
			manifest,
			"infill_layers",
			expectations.layer_count,
		) &&
		infill_manifest_counter_matches(
			manifest,
			"infill_segments",
			expectations.segment_count,
		) &&
		infill_manifest_counter_matches(
			manifest,
			"infill_boundary_hits",
			expectations.hit_count,
		) &&
		infill_manifest_counter_matches(
			manifest,
			"infill_scanlines",
			expectations.scanline_count,
		)
	if !summary_matches {return {}, .Summary_Mismatch}
	result_invariant, result_invariant_ok :=
		path_plan_manifest_invariant(
			manifest,
			"canonical_infill_result_hash",
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
			"source_independent_infill_replay",
		)
	if !replay_invariant_ok ||
	   !replay_invariant.passed ||
	   replay_invariant.observed != "passed" ||
	   replay_invariant.expected != "passed" {
		return {}, .Invariant_Mismatch
	}
	return expectations, .None
}

infill_manifest_replay_verify :: proc(
	expectations: Infill_Manifest_Expectations,
	artifact: features.Infill_Artifact,
) -> Infill_Manifest_Error {
	result := artifact.result
	if u64(len(result.layers)) != expectations.layer_count ||
	   u64(len(result.segments)) != expectations.segment_count ||
	   u64(len(result.boundary_hits)) != expectations.hit_count ||
	   result.scanline_count != expectations.scanline_count ||
	   artifact.result_hash != expectations.result_hash {
		return .Result_Mismatch
	}
	return .None
}

infill_manifest_counter_matches :: proc(
	manifest: Evidence_Manifest,
	name: string,
	expected: u64,
) -> bool {
	value, found := path_plan_manifest_counter(manifest, name)
	return found && value == expected
}
