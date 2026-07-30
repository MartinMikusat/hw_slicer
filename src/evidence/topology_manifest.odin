package evidence

import contracts "../contracts"
import slicing "../slicing"

TOPOLOGY_MANIFEST_STAGE_REVISION :: u32(1)

Topology_Manifest_Expectations :: struct {
	layer_count:                u64,
	vertex_count:               u64,
	path_count:                 u64,
	path_vertex_index_count:    u64,
	path_segment_index_count:   u64,
	open_chain_count:           u64,
	degenerate_loop_count:      u64,
	non_manifold_vertex_count:  u64,
	result_hash:                contracts.Content_Hash,
	bounds_valid:               bool,
	bounds_minimum:             [2]i64,
	bounds_maximum:             [2]i64,
}

Topology_Manifest_Error :: enum u8 {
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

topology_manifest_preflight :: proc(
	manifest: Evidence_Manifest,
	artifact_path: string,
	artifact_bytes: []u8,
) -> (Topology_Manifest_Expectations, Topology_Manifest_Error) {
	if !evidence_manifest_valid(manifest) {
		return {}, .Invalid_Manifest
	}
	if manifest.stage.name != "reconstruct-topology" ||
	   manifest.stage.schema_version != slicing.SCHEMA_VERSION_TOPOLOGY_HASH ||
	   manifest.stage.revision != TOPOLOGY_MANIFEST_STAGE_REVISION {
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
	if descriptor.format != TOPOLOGY_ARTIFACT_FORMAT ||
	   descriptor.schema_version != TOPOLOGY_ARTIFACT_SCHEMA_VERSION {
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

	expectations: Topology_Manifest_Expectations
	counts_ok: bool
	expectations.layer_count, counts_ok =
		path_plan_manifest_counter(manifest, "layers")
	if !counts_ok {return {}, .Summary_Mismatch}
	expectations.vertex_count, counts_ok =
		path_plan_manifest_counter(manifest, "vertices")
	if !counts_ok {return {}, .Summary_Mismatch}
	expectations.path_count, counts_ok =
		path_plan_manifest_counter(manifest, "paths")
	if !counts_ok {return {}, .Summary_Mismatch}
	expectations.path_vertex_index_count, counts_ok =
		path_plan_manifest_counter(manifest, "path_vertex_indices")
	if !counts_ok {return {}, .Summary_Mismatch}
	expectations.path_segment_index_count, counts_ok =
		path_plan_manifest_counter(manifest, "path_segment_indices")
	if !counts_ok {return {}, .Summary_Mismatch}
	expectations.open_chain_count, counts_ok =
		path_plan_manifest_counter(manifest, "open_chains")
	if !counts_ok {return {}, .Summary_Mismatch}
	expectations.degenerate_loop_count, counts_ok =
		path_plan_manifest_counter(manifest, "degenerate_loops")
	if !counts_ok {return {}, .Summary_Mismatch}
	expectations.non_manifold_vertex_count, counts_ok =
		path_plan_manifest_counter(manifest, "non_manifold_vertices")
	if !counts_ok {return {}, .Summary_Mismatch}
	item_count, item_count_ok := topology_manifest_item_count(expectations)
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

topology_manifest_replay_verify :: proc(
	expectations: Topology_Manifest_Expectations,
	artifact: Topology_Artifact,
) -> Topology_Manifest_Error {
	if u64(len(artifact.result.layers)) != expectations.layer_count ||
	   u64(len(artifact.result.vertices)) != expectations.vertex_count ||
	   u64(len(artifact.result.paths)) != expectations.path_count ||
	   u64(len(artifact.result.path_vertex_indices)) !=
	   	expectations.path_vertex_index_count ||
	   u64(len(artifact.result.path_segment_indices)) !=
	   	expectations.path_segment_index_count ||
	   artifact.result.open_chain_count != expectations.open_chain_count ||
	   artifact.result.degenerate_loop_count !=
	   	expectations.degenerate_loop_count ||
	   artifact.result.non_manifold_vertex_count !=
	   	expectations.non_manifold_vertex_count ||
	   artifact.result_hash != expectations.result_hash {
		return .Result_Mismatch
	}

	bounds_valid := len(artifact.result.vertices) > 0
	bounds_minimum, bounds_maximum: [2]i64
	for vertex, vertex_index in artifact.result.vertices {
		point := [2]i64{i64(vertex.point.x), i64(vertex.point.y)}
		if vertex_index == 0 {
			bounds_minimum = point
			bounds_maximum = point
			continue
		}
		bounds_minimum[0] = min(bounds_minimum[0], point[0])
		bounds_minimum[1] = min(bounds_minimum[1], point[1])
		bounds_maximum[0] = max(bounds_maximum[0], point[0])
		bounds_maximum[1] = max(bounds_maximum[1], point[1])
	}
	if bounds_valid != expectations.bounds_valid ||
	   bounds_valid &&
	   	(bounds_minimum != expectations.bounds_minimum ||
	   	 bounds_maximum != expectations.bounds_maximum) {
		return .Bounds_Mismatch
	}
	return .None
}

topology_manifest_item_count :: proc(
	expectations: Topology_Manifest_Expectations,
) -> (u64, bool) {
	counts := [5]u64{
		expectations.layer_count,
		expectations.vertex_count,
		expectations.path_count,
		expectations.path_vertex_index_count,
		expectations.path_segment_index_count,
	}
	result: u64
	for count in counts {
		if result > max(u64)-count {return 0, false}
		result += count
	}
	return result, true
}
