package slicing

import "core:testing"

import contracts "../contracts"
import geometry "../geometry"

@(test)
regions_classify_outer_hole_and_nested_island_test :: proc(
	t: ^testing.T,
) {
	topology := region_test_nested_topology()
	defer topology_result_destroy(&topology)
	failure: Region_Failure
	result, error := regions_build(
		topology,
		failure = &failure,
	)
	defer region_result_destroy(&result)
	testing.expect_value(t, error, Region_Error.None)
	testing.expect_value(t, failure.error, Region_Error.None)
	testing.expect_value(
		t,
		failure.layer_index,
		REGION_INVALID_INDEX,
	)
	testing.expect_value(t, len(result.layers), 1)
	testing.expect_value(t, len(result.contours), 3)
	testing.expect_value(t, len(result.regions), 2)
	testing.expect_value(t, result.hole_count, u64(1))
	testing.expect_value(t, result.layers[0].contour_count, u32(3))
	testing.expect_value(t, result.layers[0].region_count, u32(2))

	outer := result.contours[0]
	testing.expect_value(t, outer.parent_contour, REGION_INVALID_INDEX)
	testing.expect_value(t, outer.depth, u32(0))
	testing.expect_value(t, outer.role, Region_Contour_Role.Outer)
	testing.expect_value(t, outer.region_index, u32(0))
	testing.expect(t, !outer.reverse_path)

	hole := result.contours[1]
	testing.expect_value(t, hole.parent_contour, u32(0))
	testing.expect_value(t, hole.depth, u32(1))
	testing.expect_value(t, hole.role, Region_Contour_Role.Hole)
	testing.expect_value(t, hole.region_index, u32(0))
	testing.expect(t, hole.reverse_path)

	island := result.contours[2]
	testing.expect_value(t, island.parent_contour, u32(1))
	testing.expect_value(t, island.depth, u32(2))
	testing.expect_value(t, island.role, Region_Contour_Role.Outer)
	testing.expect_value(t, island.region_index, u32(1))
	testing.expect(t, !island.reverse_path)

	testing.expect_value(t, result.regions[0].contour_count, u32(2))
	testing.expect_value(t, result.regions[1].contour_count, u32(1))
	testing.expect_value(t, result.regions[0].filled_area_2, u128(12_800))
	testing.expect_value(t, result.regions[1].filled_area_2, u128(800))
	expected_membership := [?]u32{0, 1, 2}
	for contour_index, index in expected_membership {
		testing.expect_value(
			t,
			result.region_contour_indices[index],
			contour_index,
		)
	}
	testing.expect(
		t,
		result.regions[0].stable_id != outer.stable_id,
	)
	outer_inside, outer_inside_error :=
		region_point_locate(topology, result, 0, {10, 10})
	hole_inside, hole_inside_error :=
		region_point_locate(topology, result, 0, {30, 30})
	hole_boundary, hole_boundary_error :=
		region_point_locate(topology, result, 0, {20, 20})
	island_inside, island_inside_error :=
		region_point_locate(topology, result, 1, {50, 50})
	_, invalid_query_error :=
		region_point_locate(topology, result, 2, {50, 50})
	testing.expect_value(t, outer_inside_error, Region_Error.None)
	testing.expect_value(t, outer_inside, Region_Point_Location.Inside)
	testing.expect_value(t, hole_inside_error, Region_Error.None)
	testing.expect_value(t, hole_inside, Region_Point_Location.Outside)
	testing.expect_value(t, hole_boundary_error, Region_Error.None)
	testing.expect_value(t, hole_boundary, Region_Point_Location.Boundary)
	testing.expect_value(t, island_inside_error, Region_Error.None)
	testing.expect_value(t, island_inside, Region_Point_Location.Inside)
	testing.expect_value(
		t,
		invalid_query_error,
		Region_Error.Invalid_Input,
	)
	region_hash, hash_ok := region_result_hash({}, topology, result)
	testing.expect(t, hash_ok)
	expected_hash := contracts.Content_Hash{
		0xb1, 0x98, 0x6f, 0x54, 0x4c, 0xd3, 0x09, 0x53,
		0x8d, 0x19, 0x41, 0xf1, 0xf2, 0x2e, 0x15, 0x61,
		0xe9, 0xef, 0x2b, 0xbc, 0x0d, 0xd8, 0x50, 0x65,
		0x91, 0x27, 0x36, 0x29, 0xa4, 0xca, 0xcf, 0x78,
	}
	testing.expect_value(t, region_hash, expected_hash)
}

@(test)
regions_reject_touching_or_crossing_contours_test :: proc(t: ^testing.T) {
	touching := region_test_two_contour_topology(
		{0, 0},
		{100, 100},
		{100, 20},
		{200, 80},
	)
	defer topology_result_destroy(&touching)
	touching_failure: Region_Failure
	_, touching_error := regions_build(
		touching,
		failure = &touching_failure,
	)
	crossing := region_test_two_contour_topology(
		{0, 0},
		{100, 100},
		{50, -20},
		{150, 80},
	)
	defer topology_result_destroy(&crossing)
	crossing_failure: Region_Failure
	_, crossing_error := regions_build(
		crossing,
		failure = &crossing_failure,
	)
	testing.expect_value(
		t,
		touching_error,
		Region_Error.Contour_Intersection,
	)
	testing.expect_value(
		t,
		crossing_error,
		Region_Error.Contour_Intersection,
	)
	testing.expect_value(
		t,
		touching_failure.error,
		Region_Error.Contour_Intersection,
	)
	testing.expect_value(t, touching_failure.layer_index, u32(0))
	testing.expect_value(t, touching_failure.contour_index_a, u32(0))
	testing.expect_value(t, touching_failure.contour_index_b, u32(1))
	testing.expect_value(t, touching_failure.path_index_a, u32(0))
	testing.expect_value(t, touching_failure.path_index_b, u32(1))
	testing.expect_value(t, touching_failure.edge_index_a, u32(1))
	testing.expect_value(t, touching_failure.edge_index_b, u32(0))
	testing.expect_value(
		t,
		crossing_failure.error,
		Region_Error.Contour_Intersection,
	)
	testing.expect_value(t, crossing_failure.edge_index_a, u32(0))
	testing.expect_value(t, crossing_failure.edge_index_b, u32(3))
}

@(test)
regions_report_self_intersection_edges_test :: proc(t: ^testing.T) {
	topology := region_test_self_intersecting_topology()
	defer topology_result_destroy(&topology)
	failure: Region_Failure
	_, error := regions_build(topology, failure = &failure)
	testing.expect_value(
		t,
		error,
		Region_Error.Contour_Intersection,
	)
	testing.expect_value(
		t,
		failure.error,
		Region_Error.Contour_Intersection,
	)
	testing.expect_value(t, failure.layer_index, u32(0))
	testing.expect_value(t, failure.contour_index_a, u32(0))
	testing.expect_value(t, failure.contour_index_b, u32(0))
	testing.expect_value(t, failure.path_index_a, u32(0))
	testing.expect_value(t, failure.path_index_b, u32(0))
	testing.expect_value(t, failure.edge_index_a, u32(0))
	testing.expect_value(t, failure.edge_index_b, u32(2))
}

@(test)
regions_ignore_open_chains_and_enforce_pair_limits_test :: proc(
	t: ^testing.T,
) {
	topology := region_test_nested_topology()
	defer topology_result_destroy(&topology)
	topology.paths[2].kind = .Open_Chain
	topology.paths[2].signed_area_2 = 0
	topology.paths[2].winding = .Zero
	topology.paths[2].segment_count = 3
	result, error := regions_build(topology)
	defer region_result_destroy(&result)
	testing.expect_value(t, error, Region_Error.None)
	testing.expect_value(t, len(result.contours), 2)
	testing.expect_value(t, len(result.regions), 1)

	limited_topology := region_test_nested_topology()
	defer topology_result_destroy(&limited_topology)
	_, pair_error := regions_build(
		limited_topology,
		{
			max_contours = 3,
			max_regions = 3,
			max_contour_pairs = 0,
			max_edge_pair_tests = 0,
		},
	)
	testing.expect_value(t, pair_error, Region_Error.Pair_Test_Limit)
}

region_test_nested_topology :: proc() -> Topology_Result {
	points := [?]Snapped_Point{
		{0, 0},
		{100, 0},
		{100, 100},
		{0, 100},
		{20, 20},
		{80, 20},
		{80, 80},
		{20, 80},
		{40, 40},
		{60, 40},
		{60, 60},
		{40, 60},
	}
	vertices: [12]Topology_Vertex
	indices: [12]u32
	for point, index in points {
		vertices[index] = {
			id = contracts.Stable_ID(index+1),
			layer_index = 0,
			point = point,
			degree = 2,
		}
		indices[index] = u32(index)
	}
	paths := [3]Topology_Path{
		{
			id = 100,
			layer_index = 0,
			kind = .Loop,
			vertex_offset = 0,
			vertex_count = 4,
			segment_offset = 0,
			segment_count = 4,
			signed_area_2 = 20_000,
			winding = .Positive,
		},
		{
			id = 101,
			layer_index = 0,
			kind = .Loop,
			vertex_offset = 4,
			vertex_count = 4,
			segment_offset = 4,
			segment_count = 4,
			signed_area_2 = 7_200,
			winding = .Positive,
		},
		{
			id = 102,
			layer_index = 0,
			kind = .Loop,
			vertex_offset = 8,
			vertex_count = 4,
			segment_offset = 8,
			segment_count = 4,
			signed_area_2 = 800,
			winding = .Positive,
		},
	}
	result: Topology_Result
	result.layers = make([]Topology_Layer, 1)
	result.vertices = make([]Topology_Vertex, len(vertices))
	result.paths = make([]Topology_Path, len(paths))
	result.path_vertex_indices = make([]u32, len(indices))
	result.layers[0] = {0, 12, 0, 3}
	copy(result.vertices, vertices[:])
	copy(result.paths, paths[:])
	copy(result.path_vertex_indices, indices[:])
	return result
}

region_test_self_intersecting_topology :: proc() -> Topology_Result {
	points := [?]Snapped_Point{
		{0, 0},
		{100, 100},
		{0, 100},
		{80, 0},
	}
	result: Topology_Result
	result.layers = make([]Topology_Layer, 1)
	result.vertices = make([]Topology_Vertex, len(points))
	result.paths = make([]Topology_Path, 1)
	result.path_vertex_indices = make([]u32, len(points))
	result.layers[0] = {0, 4, 0, 1}
	for point, index in points {
		result.vertices[index] = {
			id = contracts.Stable_ID(index+1),
			layer_index = 0,
			point = point,
			degree = 2,
		}
		result.path_vertex_indices[index] = u32(index)
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

region_test_two_contour_topology :: proc(
	a_min, a_max, b_min, b_max: Snapped_Point,
) -> Topology_Result {
	points := [?]Snapped_Point{
		{a_min.x, a_min.y},
		{a_max.x, a_min.y},
		{a_max.x, a_max.y},
		{a_min.x, a_max.y},
		{b_min.x, b_min.y},
		{b_max.x, b_min.y},
		{b_max.x, b_max.y},
		{b_min.x, b_max.y},
	}
	vertices: [8]Topology_Vertex
	indices: [8]u32
	for point, index in points {
		vertices[index] = {
			id = contracts.Stable_ID(index+1),
			layer_index = 0,
			point = point,
			degree = 2,
		}
		indices[index] = u32(index)
	}
	area_a :=
		i128(i64(a_max.x-a_min.x))*
		i128(i64(a_max.y-a_min.y))*2
	area_b :=
		i128(i64(b_max.x-b_min.x))*
		i128(i64(b_max.y-b_min.y))*2
	paths := [2]Topology_Path{
		{
			id = 100,
			layer_index = 0,
			kind = .Loop,
			vertex_offset = 0,
			vertex_count = 4,
			segment_count = 4,
			signed_area_2 = area_a,
			winding = geometry.Predicate_Sign.Positive,
		},
		{
			id = 101,
			layer_index = 0,
			kind = .Loop,
			vertex_offset = 4,
			vertex_count = 4,
			segment_offset = 4,
			segment_count = 4,
			signed_area_2 = area_b,
			winding = geometry.Predicate_Sign.Positive,
		},
	}
	result: Topology_Result
	result.layers = make([]Topology_Layer, 1)
	result.vertices = make([]Topology_Vertex, len(vertices))
	result.paths = make([]Topology_Path, len(paths))
	result.path_vertex_indices = make([]u32, len(indices))
	result.layers[0] = {0, 8, 0, 2}
	copy(result.vertices, vertices[:])
	copy(result.paths, paths[:])
	copy(result.path_vertex_indices, indices[:])
	return result
}
