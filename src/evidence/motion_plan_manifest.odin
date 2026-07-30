package evidence

import contracts "../contracts"
import features "../features"

MOTION_PLAN_MANIFEST_STAGE_REVISION :: u32(1)

Motion_Plan_Manifest_Expectations :: struct {
	layer_count:               u64,
	operation_count:           u64,
	retraction_count:          u64,
	travel_count:              u64,
	extrusion_count:           u64,
	dwell_count:               u64,
	total_motion_duration_us:  u64,
	total_dwell_duration_us:   u64,
	total_planned_duration_us: u64,
	result_hash:               contracts.Content_Hash,
}

Motion_Plan_Manifest_Error :: enum u8 {
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

motion_plan_manifest_preflight :: proc(
	manifest: Evidence_Manifest,
	artifact_path: string,
	artifact_bytes: []u8,
	limits := features.DEFAULT_MOTION_PLAN_ARTIFACT_LIMITS,
) -> (
	Motion_Plan_Manifest_Expectations,
	Motion_Plan_Manifest_Error,
) {
	if !evidence_manifest_valid(manifest) {
		return {}, .Invalid_Manifest
	}
	if manifest.stage.name != "plan-paths" ||
	   manifest.stage.schema_version !=
		features.SCHEMA_VERSION_MOTION_PLAN_HASH ||
	   manifest.stage.revision != MOTION_PLAN_MANIFEST_STAGE_REVISION {
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
	if descriptor.format != features.MOTION_PLAN_ARTIFACT_FORMAT ||
	   descriptor.schema_version !=
		features.MOTION_PLAN_ARTIFACT_SCHEMA_VERSION {
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
		features.motion_plan_artifact_preflight(artifact_bytes, limits)
	if artifact_error != .None {return {}, .Summary_Mismatch}
	if artifact_summary.layer_count >
	   max(u64)-artifact_summary.operation_count ||
	   descriptor.item_count !=
		artifact_summary.layer_count+artifact_summary.operation_count {
		return {}, .Summary_Mismatch
	}
	expectations := Motion_Plan_Manifest_Expectations{
		layer_count = artifact_summary.layer_count,
		operation_count = artifact_summary.operation_count,
		retraction_count = artifact_summary.retraction_count,
		travel_count = artifact_summary.travel_count,
		extrusion_count = artifact_summary.extrusion_count,
		dwell_count = artifact_summary.dwell_count,
		total_motion_duration_us =
			artifact_summary.total_motion_duration_us,
		total_dwell_duration_us =
			artifact_summary.total_dwell_duration_us,
		total_planned_duration_us =
			artifact_summary.total_planned_duration_us,
	}
	summary_matches :=
		motion_plan_manifest_counter_matches(
			manifest,
			"motion_layers",
			expectations.layer_count,
		) &&
		motion_plan_manifest_counter_matches(
			manifest,
			"motion_operations",
			expectations.operation_count,
		) &&
		motion_plan_manifest_counter_matches(
			manifest,
			"retractions",
			expectations.retraction_count,
		) &&
		motion_plan_manifest_counter_matches(
			manifest,
			"motion_travels",
			expectations.travel_count,
		) &&
		motion_plan_manifest_counter_matches(
			manifest,
			"motion_extrusions",
			expectations.extrusion_count,
		) &&
		motion_plan_manifest_counter_matches(
			manifest,
			"motion_dwells",
			expectations.dwell_count,
		) &&
		motion_plan_manifest_counter_matches(
			manifest,
			"motion_duration_us",
			expectations.total_motion_duration_us,
		) &&
		motion_plan_manifest_counter_matches(
			manifest,
			"dwell_duration_us",
			expectations.total_dwell_duration_us,
		) &&
		motion_plan_manifest_counter_matches(
			manifest,
			"planned_duration_us",
			expectations.total_planned_duration_us,
		)
	if !summary_matches {return {}, .Summary_Mismatch}
	result_invariant, result_invariant_ok :=
		path_plan_manifest_invariant(
			manifest,
			"canonical_motion_result_hash",
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
			"source_independent_motion_replay",
		)
	if !replay_invariant_ok ||
	   !replay_invariant.passed ||
	   replay_invariant.observed != "passed" ||
	   replay_invariant.expected != "passed" {
		return {}, .Invariant_Mismatch
	}
	return expectations, .None
}

motion_plan_manifest_replay_verify :: proc(
	expectations: Motion_Plan_Manifest_Expectations,
	artifact: features.Motion_Plan_Artifact,
) -> Motion_Plan_Manifest_Error {
	result := artifact.result
	if u64(len(result.layers)) != expectations.layer_count ||
	   u64(len(result.operations)) != expectations.operation_count ||
	   result.retraction_count != expectations.retraction_count ||
	   result.travel_count != expectations.travel_count ||
	   result.extrusion_count != expectations.extrusion_count ||
	   result.dwell_count != expectations.dwell_count ||
	   result.total_motion_duration_us !=
		expectations.total_motion_duration_us ||
	   result.total_dwell_duration_us !=
		expectations.total_dwell_duration_us ||
	   result.total_planned_duration_us !=
		expectations.total_planned_duration_us ||
	   artifact.result_hash != expectations.result_hash {
		return .Result_Mismatch
	}
	return .None
}

motion_plan_manifest_counter_matches :: proc(
	manifest: Evidence_Manifest,
	name: string,
	expected: u64,
) -> bool {
	value, found := path_plan_manifest_counter(manifest, name)
	return found && value == expected
}
