package evidence

import contracts "../contracts"
import features "../features"

PATH_PLAN_MANIFEST_STAGE_REVISION :: u32(1)

Path_Plan_Manifest_Expectations :: struct {
	layer_count:        u64,
	path_count:         u64,
	move_count:         u64,
	travel_move_count:  u64,
	extrude_move_count: u64,
	result_hash:        contracts.Content_Hash,
	bounds_valid:       bool,
	bounds_minimum:     [2]i64,
	bounds_maximum:     [2]i64,
}

Path_Plan_Manifest_Error :: enum u8 {
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

path_plan_manifest_preflight :: proc(
	manifest: Evidence_Manifest,
	artifact_path: string,
	artifact_bytes: []u8,
) -> (Path_Plan_Manifest_Expectations, Path_Plan_Manifest_Error) {
	if !evidence_manifest_valid(manifest) {
		return {}, .Invalid_Manifest
	}
	if manifest.stage.name != "plan-paths" ||
	   manifest.stage.schema_version != features.SCHEMA_VERSION_PATH_PLAN_HASH ||
	   manifest.stage.revision != PATH_PLAN_MANIFEST_STAGE_REVISION {
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
	if descriptor.format != PATH_PLAN_ARTIFACT_FORMAT ||
	   descriptor.schema_version != PATH_PLAN_ARTIFACT_SCHEMA_VERSION {
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

	expectations: Path_Plan_Manifest_Expectations
	counts_ok: bool
	expectations.layer_count, counts_ok =
		path_plan_manifest_counter(manifest, "layers")
	if !counts_ok {return {}, .Summary_Mismatch}
	expectations.path_count, counts_ok =
		path_plan_manifest_counter(manifest, "paths")
	if !counts_ok {return {}, .Summary_Mismatch}
	expectations.move_count, counts_ok =
		path_plan_manifest_counter(manifest, "moves")
	if !counts_ok {return {}, .Summary_Mismatch}
	expectations.travel_move_count, counts_ok =
		path_plan_manifest_counter(manifest, "travel_moves")
	if !counts_ok {return {}, .Summary_Mismatch}
	expectations.extrude_move_count, counts_ok =
		path_plan_manifest_counter(manifest, "extrude_moves")
	if !counts_ok {return {}, .Summary_Mismatch}
	if expectations.layer_count > max(u64)-expectations.path_count ||
	   expectations.layer_count+expectations.path_count >
	   	max(u64)-expectations.move_count ||
	   expectations.layer_count+expectations.path_count+
	   	expectations.move_count != descriptor.item_count ||
	   expectations.travel_move_count >
	   	max(u64)-expectations.extrude_move_count ||
	   expectations.travel_move_count+expectations.extrude_move_count !=
	   	expectations.move_count {
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

path_plan_manifest_replay_verify :: proc(
	expectations: Path_Plan_Manifest_Expectations,
	artifact: Path_Plan_Artifact,
) -> Path_Plan_Manifest_Error {
	if u64(len(artifact.result.layers)) != expectations.layer_count ||
	   u64(len(artifact.result.paths)) != expectations.path_count ||
	   u64(len(artifact.result.moves)) != expectations.move_count ||
	   artifact.result.travel_move_count != expectations.travel_move_count ||
	   artifact.result.extrude_move_count != expectations.extrude_move_count ||
	   artifact.result_hash != expectations.result_hash {
		return .Result_Mismatch
	}

	bounds_valid := false
	bounds_minimum, bounds_maximum: [2]i64
	for move, move_index in artifact.result.moves {
		points := [2][2]i64{
			{i64(move.point_a.x), i64(move.point_a.y)},
			{i64(move.point_b.x), i64(move.point_b.y)},
		}
		for point, point_index in points {
			if move_index == 0 && point_index == 0 {
				bounds_minimum = point
				bounds_maximum = point
				bounds_valid = true
				continue
			}
			bounds_minimum[0] = min(bounds_minimum[0], point[0])
			bounds_minimum[1] = min(bounds_minimum[1], point[1])
			bounds_maximum[0] = max(bounds_maximum[0], point[0])
			bounds_maximum[1] = max(bounds_maximum[1], point[1])
		}
	}
	if bounds_valid != expectations.bounds_valid ||
	   bounds_valid &&
	   	(bounds_minimum != expectations.bounds_minimum ||
	   	 bounds_maximum != expectations.bounds_maximum) {
		return .Bounds_Mismatch
	}
	return .None
}

path_plan_manifest_counter :: proc(
	manifest: Evidence_Manifest,
	name: string,
) -> (u64, bool) {
	for counter in manifest.summary {
		if counter.name == name {return counter.value, true}
	}
	return 0, false
}

path_plan_manifest_invariant :: proc(
	manifest: Evidence_Manifest,
	code: string,
) -> (Evidence_Invariant, bool) {
	for invariant in manifest.invariants {
		if invariant.code == code {return invariant, true}
	}
	return {}, false
}

path_plan_manifest_hash_parse :: proc(
	text: string,
) -> (contracts.Content_Hash, bool) {
	if !sha256_text_valid(text) {return {}, false}
	bytes := transmute([]u8)text
	result: contracts.Content_Hash
	for &byte, byte_index in result {
		high, high_ok := path_plan_manifest_hex_value(bytes[byte_index*2])
		low, low_ok := path_plan_manifest_hex_value(bytes[byte_index*2+1])
		if !high_ok || !low_ok {return {}, false}
		byte = high<<4 | low
	}
	return result, true
}

path_plan_manifest_hex_value :: proc(value: u8) -> (u8, bool) {
	if value >= '0' && value <= '9' {return value-'0', true}
	if value >= 'a' && value <= 'f' {return value-'a'+10, true}
	return 0, false
}
