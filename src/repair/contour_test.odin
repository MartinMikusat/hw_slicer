package repair

import "core:testing"

import contracts "../contracts"
import polygon "../polygon"
import slicing "../slicing"

@(test)
contour_repair_preserves_source_edge_lineage_test :: proc(
	t: ^testing.T,
) {
	topology := contour_repair_test_topology()
	defer slicing.topology_result_destroy(&topology)
	failure := contour_repair_test_failure(topology)
	testing.expect_value(
		t,
		failure.error,
		slicing.Region_Error.Contour_Intersection,
	)
	result, error := contour_path_repair(
		topology,
		polygon.CLIPPER2_PROVIDER,
		{
			failure = failure,
			fill_rule = .Even_Odd,
			lineage_tolerance = 2,
		},
	)
	defer contour_repair_result_destroy(&result)
	testing.expect_value(t, error, Contour_Repair_Error.None)
	testing.expect_value(t, result.source_path_id, contracts.Stable_ID(100))
	testing.expect_value(t, result.source_path_index, u32(0))
	testing.expect_value(t, result.failure_edge_a, u32(0))
	testing.expect_value(t, result.failure_edge_b, u32(2))
	testing.expect_value(t, len(result.output.paths), 2)
	testing.expect_value(t, len(result.output.points), 6)
	testing.expect_value(t, len(result.edges), 6)
	testing.expect(t, len(result.sources) >= len(result.edges))
	testing.expect_value(t, result.maximum_deviation_um, u64(2))
	for edge in result.edges {
		testing.expect(t, edge.source_count > 0)
	}
	for source in result.sources {
		testing.expect_value(t, source.path_id, contracts.Stable_ID(100))
		testing.expect_value(t, source.path_index, u32(0))
		testing.expect(t, source.edge_index < 4)
		testing.expect(t, source.segment_index < 4)
		testing.expect(t, source.maximum_deviation_um <= 2)
	}
	topology_hash: contracts.Content_Hash
	topology_hash[0] = 0x42
	result_hash, hash_ok := contour_repair_result_hash(
		topology_hash,
		result,
	)
	testing.expect(t, hash_ok)
	testing.expect(t, result_hash != contracts.Content_Hash{})
}

@(test)
contour_repair_requires_an_explicit_lineage_tolerance_test :: proc(
	t: ^testing.T,
) {
	topology := contour_repair_test_topology()
	defer slicing.topology_result_destroy(&topology)
	failure := contour_repair_test_failure(topology)
	result, error := contour_path_repair(
		topology,
		polygon.CLIPPER2_PROVIDER,
		{
			failure = failure,
			fill_rule = .Even_Odd,
			lineage_tolerance = 0,
		},
	)
	defer contour_repair_result_destroy(&result)
	testing.expect_value(
		t,
		error,
		Contour_Repair_Error.Lineage_Incomplete,
	)
}

@(test)
contour_repair_rejects_wrong_provenance_and_work_limits_test :: proc(
	t: ^testing.T,
) {
	topology := contour_repair_test_topology()
	defer slicing.topology_result_destroy(&topology)
	failure := contour_repair_test_failure(topology)
	wrong_failure := failure
	wrong_failure.edge_index_b = 3
	wrong_result, wrong_error := contour_path_repair(
		topology,
		polygon.CLIPPER2_PROVIDER,
		{
			failure = wrong_failure,
			fill_rule = .Even_Odd,
			lineage_tolerance = 2,
		},
	)
	defer contour_repair_result_destroy(&wrong_result)
	limited_result, limited_error := contour_path_repair(
		topology,
		polygon.CLIPPER2_PROVIDER,
		{
			failure = failure,
			fill_rule = .Even_Odd,
			lineage_tolerance = 2,
		},
		{
			max_lineage_tests = 1,
			max_sources = 100,
			polygon = polygon.DEFAULT_POLYGON_LIMITS,
		},
	)
	defer contour_repair_result_destroy(&limited_result)
	testing.expect_value(
		t,
		wrong_error,
		Contour_Repair_Error.Not_Self_Intersection,
	)
	testing.expect_value(
		t,
		limited_error,
		Contour_Repair_Error.Lineage_Limit,
	)
}

@(test)
contour_repair_hash_rejects_mutated_lineage_spans_test :: proc(
	t: ^testing.T,
) {
	topology := contour_repair_test_topology()
	defer slicing.topology_result_destroy(&topology)
	failure := contour_repair_test_failure(topology)
	result, error := contour_path_repair(
		topology,
		polygon.CLIPPER2_PROVIDER,
		{
			failure = failure,
			fill_rule = .Non_Zero,
			lineage_tolerance = 2,
		},
	)
	defer contour_repair_result_destroy(&result)
	testing.expect_value(t, error, Contour_Repair_Error.None)
	if len(result.edges) == 0 {return}
	result.edges[0].source_count = 0
	topology_hash: contracts.Content_Hash
	topology_hash[0] = 0x42
	_, hash_ok := contour_repair_result_hash(
		topology_hash,
		result,
	)
	testing.expect(t, !hash_ok)
}

@(test)
contour_repair_builds_a_separate_region_topology_test :: proc(
	t: ^testing.T,
) {
	topology := contour_repair_test_topology()
	defer slicing.topology_result_destroy(&topology)
	failure := contour_repair_test_failure(topology)
	result, repair_error := contour_path_repair(
		topology,
		polygon.CLIPPER2_PROVIDER,
		{
			failure = failure,
			fill_rule = .Even_Odd,
			lineage_tolerance = 2,
		},
	)
	defer contour_repair_result_destroy(&result)
	applied, apply_error := contour_repair_apply_for_regions(
		topology,
		result,
	)
	defer slicing.topology_result_destroy(&applied)
	testing.expect_value(t, repair_error, Contour_Repair_Error.None)
	testing.expect_value(t, apply_error, Contour_Repair_Error.None)
	testing.expect(t, slicing.regions_topology_shape_valid(applied))
	testing.expect_value(t, len(applied.layers), 1)
	testing.expect_value(t, len(applied.vertices), 6)
	testing.expect_value(t, len(applied.paths), 2)
	testing.expect_value(t, len(applied.path_vertex_indices), 6)
	testing.expect_value(t, len(applied.path_segment_indices), 6)
	testing.expect_value(t, applied.open_chain_count, u64(0))
	testing.expect_value(t, applied.degenerate_loop_count, u64(0))
	testing.expect_value(t, applied.non_manifold_vertex_count, u64(0))
	testing.expect_value(t, topology.paths[0].id, contracts.Stable_ID(100))
	for vertex in applied.vertices {
		testing.expect_value(t, vertex.degree, u32(2))
	}
	for path in applied.paths {
		testing.expect_value(t, path.kind, slicing.Topology_Path_Kind.Loop)
		testing.expect(t, path.id != contracts.INVALID_STABLE_ID)
		testing.expect(t, path.signed_area_2 != 0)
	}
}

@(test)
contour_repair_removes_a_replaced_degree_four_vertex_test :: proc(
	t: ^testing.T,
) {
	topology := contour_repair_branch_test_topology()
	defer slicing.topology_result_destroy(&topology)
	failure := contour_repair_test_failure(topology)
	testing.expect_value(
		t,
		failure.error,
		slicing.Region_Error.Contour_Intersection,
	)
	result, repair_error := contour_path_repair(
		topology,
		polygon.CLIPPER2_PROVIDER,
		{
			failure = failure,
			fill_rule = .Even_Odd,
			lineage_tolerance = 2,
		},
	)
	defer contour_repair_result_destroy(&result)
	applied, apply_error := contour_repair_apply_for_regions(
		topology,
		result,
	)
	defer slicing.topology_result_destroy(&applied)
	testing.expect_value(t, repair_error, Contour_Repair_Error.None)
	testing.expect_value(t, apply_error, Contour_Repair_Error.None)
	testing.expect_value(t, applied.open_chain_count, u64(0))
	testing.expect_value(t, applied.degenerate_loop_count, u64(0))
	testing.expect_value(t, applied.non_manifold_vertex_count, u64(0))
	for vertex in applied.vertices {
		testing.expect_value(t, vertex.degree, u32(2))
	}
	testing.expect(t, slicing.regions_topology_shape_valid(applied))
}

contour_repair_test_topology :: proc() -> slicing.Topology_Result {
	points := [?]slicing.Snapped_Point{
		{0, 0},
		{100, 100},
		{0, 100},
		{80, 0},
	}
	result: slicing.Topology_Result
	result.layers = make([]slicing.Topology_Layer, 1)
	result.vertices = make([]slicing.Topology_Vertex, len(points))
	result.paths = make([]slicing.Topology_Path, 1)
	result.path_vertex_indices = make([]u32, len(points))
	result.path_segment_indices = make([]u32, len(points))
	result.layers[0] = {0, 4, 0, 1}
	for point, index in points {
		result.vertices[index] = {
			id = contracts.Stable_ID(index+1),
			layer_index = 0,
			point = point,
			degree = 2,
		}
		result.path_vertex_indices[index] = u32(index)
		result.path_segment_indices[index] = u32(index)
	}
	result.paths[0] = {
		id = 100,
		layer_index = 0,
		kind = .Loop,
		vertex_count = 4,
		segment_count = 4,
		signed_area_2 = 2_000,
		winding = .Positive,
	}
	return result
}

contour_repair_branch_test_topology :: proc() -> slicing.Topology_Result {
	points := [?]slicing.Snapped_Point{
		{0, 0},
		{50, 50},
		{80, 80},
		{0, 100},
		{100, 0},
	}
	path_vertices := [?]u32{0, 1, 2, 3, 1, 4}
	result: slicing.Topology_Result
	result.layers = make([]slicing.Topology_Layer, 1)
	result.vertices = make([]slicing.Topology_Vertex, len(points))
	result.paths = make([]slicing.Topology_Path, 1)
	result.path_vertex_indices = make([]u32, len(path_vertices))
	result.path_segment_indices = make([]u32, len(path_vertices))
	result.layers[0] = {0, u32(len(points)), 0, 1}
	for point, index in points {
		degree: u32 = 2
		if index == 1 {degree = 4}
		result.vertices[index] = {
			id = contracts.Stable_ID(index+1),
			layer_index = 0,
			point = point,
			degree = degree,
		}
	}
	for vertex_index, local_index in path_vertices {
		result.path_vertex_indices[local_index] = vertex_index
		result.path_segment_indices[local_index] = u32(local_index)
	}
	result.paths[0] = {
		id = 100,
		layer_index = 0,
		kind = .Loop,
		vertex_count = u32(len(path_vertices)),
		segment_count = u32(len(path_vertices)),
		signed_area_2 = -2_000,
		winding = .Negative,
	}
	result.non_manifold_vertex_count = 1
	return result
}

contour_repair_test_failure :: proc(
	topology: slicing.Topology_Result,
) -> slicing.Region_Failure {
	failure: slicing.Region_Failure
	regions, error := slicing.regions_build(
		topology,
		failure = &failure,
	)
	slicing.region_result_destroy(&regions)
	if error != failure.error {return {}}
	return failure
}
