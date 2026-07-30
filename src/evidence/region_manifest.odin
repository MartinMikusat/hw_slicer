package evidence

import contracts "../contracts"
import slicing "../slicing"

REGION_MANIFEST_STAGE_REVISION :: u32(1)

Region_Manifest_Expectations :: struct {
	layer_count:        u64,
	contour_count:      u64,
	region_count:       u64,
	index_count:        u64,
	hole_count:         u64,
	result_hash:        contracts.Content_Hash,
	bounds_valid:       bool,
	bounds_minimum:     [2]i64,
	bounds_maximum:     [2]i64,
}

Region_Manifest_Error :: enum u8 {
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
	Bounds_Mismatch,
}

region_manifest_preflight :: proc(
	manifest: Evidence_Manifest,
	artifact_path: string,
	artifact_bytes: []u8,
) -> (Region_Manifest_Expectations, Region_Manifest_Error) {
	if !evidence_manifest_valid(manifest) {
		return {}, .Invalid_Manifest
	}
	if manifest.stage.name != "calculate-regions" ||
	   manifest.stage.schema_version != slicing.SCHEMA_VERSION_REGION_HASH ||
	   manifest.stage.revision != REGION_MANIFEST_STAGE_REVISION {
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
	if descriptor.format != REGION_ARTIFACT_FORMAT ||
	   descriptor.schema_version != REGION_ARTIFACT_SCHEMA_VERSION {
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
	expectations: Region_Manifest_Expectations
	counts_ok: bool
	expectations.layer_count, counts_ok =
		path_plan_manifest_counter(manifest, "layers")
	if !counts_ok {return {}, .Summary_Mismatch}
	expectations.contour_count, counts_ok =
		path_plan_manifest_counter(manifest, "contours")
	if !counts_ok {return {}, .Summary_Mismatch}
	expectations.region_count, counts_ok =
		path_plan_manifest_counter(manifest, "regions")
	if !counts_ok {return {}, .Summary_Mismatch}
	expectations.index_count, counts_ok =
		path_plan_manifest_counter(manifest, "region_contour_indices")
	if !counts_ok {return {}, .Summary_Mismatch}
	expectations.hole_count, counts_ok =
		path_plan_manifest_counter(manifest, "holes")
	if !counts_ok {return {}, .Summary_Mismatch}
	item_count, item_count_ok := region_manifest_item_count(expectations)
	if !item_count_ok || item_count != descriptor.item_count {
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
	expectations.bounds_valid = manifest.planar_bounds.valid
	expectations.bounds_minimum = manifest.planar_bounds.minimum
	expectations.bounds_maximum = manifest.planar_bounds.maximum
	return expectations, .None
}

region_manifest_replay_verify :: proc(
	expectations: Region_Manifest_Expectations,
	artifact: Region_Artifact,
) -> Region_Manifest_Error {
	if u64(len(artifact.result.layers)) != expectations.layer_count ||
	   u64(len(artifact.result.contours)) != expectations.contour_count ||
	   u64(len(artifact.result.regions)) != expectations.region_count ||
	   u64(len(artifact.result.region_contour_indices)) !=
	   	expectations.index_count ||
	   artifact.result.hole_count != expectations.hole_count ||
	   artifact.result_hash != expectations.result_hash {
		return .Result_Mismatch
	}
	bounds_valid := len(artifact.result.regions) > 0
	bounds_minimum, bounds_maximum: [2]i64
	for region, region_index in artifact.result.regions {
		minimum := [2]i64{
			i64(region.bounds.minimum.x),
			i64(region.bounds.minimum.y),
		}
		maximum := [2]i64{
			i64(region.bounds.maximum.x),
			i64(region.bounds.maximum.y),
		}
		if region_index == 0 {
			bounds_minimum = minimum
			bounds_maximum = maximum
			continue
		}
		bounds_minimum[0] = min(bounds_minimum[0], minimum[0])
		bounds_minimum[1] = min(bounds_minimum[1], minimum[1])
		bounds_maximum[0] = max(bounds_maximum[0], maximum[0])
		bounds_maximum[1] = max(bounds_maximum[1], maximum[1])
	}
	if bounds_valid != expectations.bounds_valid ||
	   bounds_valid &&
	   	(bounds_minimum != expectations.bounds_minimum ||
	   	 bounds_maximum != expectations.bounds_maximum) {
		return .Bounds_Mismatch
	}
	return .None
}

region_manifest_item_count :: proc(
	expectations: Region_Manifest_Expectations,
) -> (u64, bool) {
	counts := [4]u64{
		expectations.layer_count,
		expectations.contour_count,
		expectations.region_count,
		expectations.index_count,
	}
	result: u64
	for count in counts {
		if result > max(u64)-count {return 0, false}
		result += count
	}
	return result, true
}
