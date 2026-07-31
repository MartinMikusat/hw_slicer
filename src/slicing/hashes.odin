package slicing

import "core:math"

import contracts "../contracts"
import geometry "../geometry"

SCHEMA_VERSION_FIXED_LAYER_SCHEDULE_HASH :: u32(1)
SCHEMA_VERSION_LAYER_SPAN_INDEX_HASH :: u32(1)
SCHEMA_VERSION_CPU_INTERSECTION_HASH :: u32(1)
SCHEMA_VERSION_SNAPPED_SEGMENT_HASH :: u32(1)
SCHEMA_VERSION_TOPOLOGY_HASH :: u32(1)
SCHEMA_VERSION_PLANAR_OWNERSHIP_HASH :: u32(1)
SCHEMA_VERSION_REGION_HASH :: u32(2)

fixed_layer_schedule_hash :: proc(
	schedule: Fixed_Layer_Schedule,
) -> (contracts.Content_Hash, bool) {
	layer_count := len(schedule.layer_z)
	if layer_count == 0 || len(schedule.layer_ids) != layer_count {
		return {}, false
	}
	minimum_z := i64(schedule.minimum_z)
	maximum_z := i64(schedule.maximum_z)
	first_plane_z := i64(schedule.first_plane_z)
	layer_step := i64(schedule.layer_step)
	if minimum_z >= maximum_z ||
	   first_plane_z < minimum_z ||
	   first_plane_z >= maximum_z ||
	   layer_step <= 0 {
		return {}, false
	}
	span := i128(maximum_z)-i128(first_plane_z)
	expected_count := (span+i128(layer_step)-1)/i128(layer_step)
	if expected_count != i128(layer_count) {return {}, false}
	schedule_root_id :=
		contracts.stable_id_root(schedule.request_hash, .Layer)
	for layer_z, layer_index in schedule.layer_z {
		expected_z :=
			i128(first_plane_z)+i128(layer_index)*i128(layer_step)
		expected_id := contracts.stable_id_child(
			schedule_root_id,
			.Layer,
			u64(layer_index),
		)
		if expected_z >= i128(maximum_z) ||
		   i128(i64(layer_z)) != expected_z ||
		   schedule.layer_ids[layer_index] != expected_id {
			return {}, false
		}
	}
	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/fixed-layer-schedule",
		SCHEMA_VERSION_FIXED_LAYER_SCHEDULE_HASH,
	)
	contracts.canonical_hash_append_content_hash(
		&hash,
		schedule.request_hash,
	)
	contracts.canonical_hash_append_i64(&hash, i64(schedule.minimum_z))
	contracts.canonical_hash_append_i64(&hash, i64(schedule.maximum_z))
	contracts.canonical_hash_append_i64(&hash, i64(schedule.first_plane_z))
	contracts.canonical_hash_append_i64(&hash, i64(schedule.layer_step))
	contracts.canonical_hash_append_u64(&hash, u64(layer_count))
	for layer_z, layer_index in schedule.layer_z {
		contracts.canonical_hash_append_i64(&hash, i64(layer_z))
		contracts.canonical_hash_append_stable_id(
			&hash,
			schedule.layer_ids[layer_index],
		)
	}
	return contracts.canonical_hash_final(&hash), true
}

cpu_intersection_result_hash :: proc(
	span_hash: contracts.Content_Hash,
	result: CPU_Intersection_Result,
) -> (contracts.Content_Hash, bool) {
	segment_count := len(result.segments.segment_ids)
	planar_count := len(result.planar_candidates)
	if len(result.layers) == 0 ||
	   !raw_segment_soa_shape_valid(result.segments, segment_count) {
		return {}, false
	}
	expected_segment_offset: u64
	expected_planar_offset: u64
	for layer, layer_index in result.layers {
		if layer.segment_offset != expected_segment_offset ||
		   layer.planar_offset != expected_planar_offset ||
		   u64(layer.segment_count) >
		   	u64(segment_count)-expected_segment_offset ||
		   u64(layer.planar_count) >
		   	u64(planar_count)-expected_planar_offset {
			return {}, false
		}
		expected_segment_offset += u64(layer.segment_count)
		expected_planar_offset += u64(layer.planar_count)
		previous_triangle_index: u32
		for local_index in 0..<int(layer.segment_count) {
			segment_index := int(layer.segment_offset)+local_index
			triangle_index :=
				result.segments.triangle_indices[segment_index]
			wrong_layer :=
				result.segments.layer_indices[segment_index] !=
				u32(layer_index)
			out_of_order :=
				local_index > 0 &&
				triangle_index <= previous_triangle_index
			if wrong_layer || out_of_order {return {}, false}
			previous_triangle_index = triangle_index
		}
		previous_triangle_index = 0
		for local_index in 0..<int(layer.planar_count) {
			planar_index := int(layer.planar_offset)+local_index
			triangle_index :=
				result.planar_candidates[planar_index].triangle_index
			wrong_layer :=
				result.planar_candidates[planar_index].layer_index !=
				u32(layer_index)
			out_of_order :=
				local_index > 0 &&
				triangle_index <= previous_triangle_index
			if wrong_layer || out_of_order {return {}, false}
			previous_triangle_index = triangle_index
		}
	}
	if expected_segment_offset != u64(segment_count) ||
	   expected_planar_offset != u64(planar_count) {
		return {}, false
	}
	for segment_index in 0..<segment_count {
		edge_a := result.segments.edge_a[segment_index]
		edge_b := result.segments.edge_b[segment_index]
		x0 := result.segments.x0[segment_index]
		y0 := result.segments.y0[segment_index]
		x1 := result.segments.x1[segment_index]
		y1 := result.segments.y1[segment_index]
		if result.segments.segment_ids[segment_index] ==
		   	contracts.INVALID_STABLE_ID ||
		   result.segments.triangle_ids[segment_index] ==
		   	contracts.INVALID_STABLE_ID ||
		   !slicing_hash_triangle_edge_valid(edge_a) ||
		   !slicing_hash_triangle_edge_valid(edge_b) ||
		   edge_a == edge_b ||
		   !slicing_hash_f64_valid(x0) ||
		   !slicing_hash_f64_valid(y0) ||
		   !slicing_hash_f64_valid(x1) ||
		   !slicing_hash_f64_valid(y1) ||
		   x1 < x0 || x1 == x0 && y1 <= y0 {
			return {}, false
		}
	}
	for planar in result.planar_candidates {
		if planar.triangle_id == contracts.INVALID_STABLE_ID {
			return {}, false
		}
		switch planar.kind {
		case .Quantized_Face, .Exact_Face:
			if planar.source_edge != .Invalid {return {}, false}
		case .Exact_Edge:
			if !slicing_hash_triangle_edge_valid(planar.source_edge) {
				return {}, false
			}
		case .Invalid:
			return {}, false
		case:
			return {}, false
		}
	}

	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/cpu-intersections",
		SCHEMA_VERSION_CPU_INTERSECTION_HASH,
	)
	contracts.canonical_hash_append_content_hash(&hash, span_hash)
	contracts.canonical_hash_append_u64(&hash, result.tangent_count)
	contracts.canonical_hash_append_u64(&hash, result.degenerate_count)
	contracts.canonical_hash_append_u64(
		&hash,
		result.exact_predicate_count,
	)
	contracts.canonical_hash_append_u64(&hash, u64(len(result.layers)))
	for layer in result.layers {
		contracts.canonical_hash_append_u64(&hash, layer.segment_offset)
		contracts.canonical_hash_append_u32(&hash, layer.segment_count)
		contracts.canonical_hash_append_u64(&hash, layer.planar_offset)
		contracts.canonical_hash_append_u32(&hash, layer.planar_count)
	}
	contracts.canonical_hash_append_u64(&hash, u64(segment_count))
	for segment_index in 0..<segment_count {
		contracts.canonical_hash_append_u32(
			&hash,
			result.segments.layer_indices[segment_index],
		)
		contracts.canonical_hash_append_u32(
			&hash,
			result.segments.triangle_indices[segment_index],
		)
		contracts.canonical_hash_append_stable_id(
			&hash,
			result.segments.segment_ids[segment_index],
		)
		contracts.canonical_hash_append_stable_id(
			&hash,
			result.segments.triangle_ids[segment_index],
		)
		contracts.canonical_hash_append_u8(
			&hash,
			u8(result.segments.edge_a[segment_index]),
		)
		contracts.canonical_hash_append_u8(
			&hash,
			u8(result.segments.edge_b[segment_index]),
		)
		contracts.canonical_hash_append_f64_bits(
			&hash,
			result.segments.x0[segment_index],
		)
		contracts.canonical_hash_append_f64_bits(
			&hash,
			result.segments.y0[segment_index],
		)
		contracts.canonical_hash_append_f64_bits(
			&hash,
			result.segments.x1[segment_index],
		)
		contracts.canonical_hash_append_f64_bits(
			&hash,
			result.segments.y1[segment_index],
		)
	}
	contracts.canonical_hash_append_u64(&hash, u64(planar_count))
	for planar in result.planar_candidates {
		contracts.canonical_hash_append_u32(&hash, planar.layer_index)
		contracts.canonical_hash_append_u32(&hash, planar.triangle_index)
		contracts.canonical_hash_append_stable_id(
			&hash,
			planar.triangle_id,
		)
		contracts.canonical_hash_append_u8(&hash, u8(planar.kind))
		contracts.canonical_hash_append_u8(&hash, u8(planar.source_edge))
	}
	return contracts.canonical_hash_final(&hash), true
}

slicing_hash_triangle_edge_valid :: proc(edge: Triangle_Edge) -> bool {
	switch edge {
	case .AB, .BC, .CA:
		return true
	case .Invalid:
	}
	return false
}

snapped_segment_result_hash :: proc(
	intersection_hash: contracts.Content_Hash,
	result: Snapped_Segment_Result,
) -> (contracts.Content_Hash, bool) {
	segment_count := len(result.segments.segment_ids)
	if len(result.layers) == 0 ||
	   !snapped_segment_soa_shape_valid(result.segments, segment_count) {
		return {}, false
	}
	expected_offset: u64
	for layer, layer_index in result.layers {
		if layer.offset != expected_offset ||
		   u64(layer.count) > u64(segment_count)-expected_offset {
			return {}, false
		}
		for local_segment in 0..<int(layer.count) {
			segment_index := int(layer.offset)+local_segment
			if result.segments.layer_indices[segment_index] !=
			   	u32(layer_index) {
				return {}, false
			}
			if local_segment > 0 &&
			   snapped_segment_at_less(
			   	result.segments,
			   	segment_index,
			   	segment_index-1,
			   ) {
				return {}, false
			}
		}
		expected_offset += u64(layer.count)
	}
	if expected_offset != u64(segment_count) {return {}, false}
	for segment_index in 0..<segment_count {
		point_a := Snapped_Point{
			result.segments.x0[segment_index],
			result.segments.y0[segment_index],
		}
		point_b := Snapped_Point{
			result.segments.x1[segment_index],
			result.segments.y1[segment_index],
		}
		if result.segments.segment_ids[segment_index] ==
		   	contracts.INVALID_STABLE_ID ||
		   result.segments.triangle_ids[segment_index] ==
		   	contracts.INVALID_STABLE_ID ||
		   !slicing_hash_triangle_edge_valid(
				result.segments.edge_a[segment_index],
		   ) ||
		   !slicing_hash_triangle_edge_valid(
				result.segments.edge_b[segment_index],
		   ) ||
		   geometry.point_2_validate(geometry.Point_2(point_a)) != .None ||
		   geometry.point_2_validate(geometry.Point_2(point_b)) != .None ||
		   !snapped_point_less(point_a, point_b) {
			return {}, false
		}
	}

	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/snapped-segments",
		SCHEMA_VERSION_SNAPPED_SEGMENT_HASH,
	)
	contracts.canonical_hash_append_content_hash(&hash, intersection_hash)
	contracts.canonical_hash_append_i64(&hash, i64(ENDPOINT_SNAP_GRID_UM))
	contracts.canonical_hash_append_u64(&hash, result.collapsed_count)
	contracts.canonical_hash_append_u64(&hash, u64(len(result.layers)))
	for layer in result.layers {
		contracts.canonical_hash_append_u64(&hash, layer.offset)
		contracts.canonical_hash_append_u32(&hash, layer.count)
	}
	contracts.canonical_hash_append_u64(&hash, u64(segment_count))
	for segment_index in 0..<segment_count {
		contracts.canonical_hash_append_u32(
			&hash,
			result.segments.layer_indices[segment_index],
		)
		contracts.canonical_hash_append_u32(
			&hash,
			result.segments.triangle_indices[segment_index],
		)
		contracts.canonical_hash_append_stable_id(
			&hash,
			result.segments.segment_ids[segment_index],
		)
		contracts.canonical_hash_append_stable_id(
			&hash,
			result.segments.triangle_ids[segment_index],
		)
		contracts.canonical_hash_append_u8(
			&hash,
			u8(result.segments.edge_a[segment_index]),
		)
		contracts.canonical_hash_append_u8(
			&hash,
			u8(result.segments.edge_b[segment_index]),
		)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(result.segments.x0[segment_index]),
		)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(result.segments.y0[segment_index]),
		)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(result.segments.x1[segment_index]),
		)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(result.segments.y1[segment_index]),
		)
	}
	return contracts.canonical_hash_final(&hash), true
}

slicing_hash_f64_valid :: proc(value: f64) -> bool {
	if math.is_nan(value) || math.is_inf(value) {return false}
	return value != 0 || transmute(u64)value == 0
}

snapped_segment_at_less :: proc(
	segments: Snapped_Segment_SoA,
	a, b: int,
) -> bool {
	if segments.x0[a] != segments.x0[b] {
		return segments.x0[a] < segments.x0[b]
	}
	if segments.y0[a] != segments.y0[b] {
		return segments.y0[a] < segments.y0[b]
	}
	if segments.x1[a] != segments.x1[b] {
		return segments.x1[a] < segments.x1[b]
	}
	if segments.y1[a] != segments.y1[b] {
		return segments.y1[a] < segments.y1[b]
	}
	if segments.triangle_ids[a] != segments.triangle_ids[b] {
		return u64(segments.triangle_ids[a]) < u64(segments.triangle_ids[b])
	}
	if segments.edge_a[a] != segments.edge_a[b] {
		return segments.edge_a[a] < segments.edge_a[b]
	}
	if segments.edge_b[a] != segments.edge_b[b] {
		return segments.edge_b[a] < segments.edge_b[b]
	}
	return u64(segments.segment_ids[a]) < u64(segments.segment_ids[b])
}

topology_result_hash :: proc(
	snapped_hash: contracts.Content_Hash,
	source_segment_count: int,
	result: Topology_Result,
) -> (contracts.Content_Hash, bool) {
	if source_segment_count < 0 || len(result.layers) == 0 {
		return {}, false
	}
	expected_vertex_offset: u64
	expected_path_offset: u64
	for layer in result.layers {
		if layer.vertex_offset != expected_vertex_offset ||
		   layer.path_offset != expected_path_offset ||
		   u64(layer.vertex_count) >
		   	u64(len(result.vertices))-expected_vertex_offset ||
		   u64(layer.path_count) >
		   	u64(len(result.paths))-expected_path_offset {
			return {}, false
		}
		expected_vertex_offset += u64(layer.vertex_count)
		expected_path_offset += u64(layer.path_count)
	}
	if expected_vertex_offset != u64(len(result.vertices)) ||
	   expected_path_offset != u64(len(result.paths)) {
		return {}, false
	}
	for vertex in result.vertices {
		if vertex.id == contracts.INVALID_STABLE_ID ||
		   u64(vertex.layer_index) >= u64(len(result.layers)) ||
		   vertex.degree == 0 ||
		   geometry.point_2_validate({
		   	vertex.point.x,
		   	vertex.point.y,
		   }) != .None {
			return {}, false
		}
	}
	expected_path_vertex_offset: u64
	expected_path_segment_offset: u64
	for path in result.paths {
		if path.id == contracts.INVALID_STABLE_ID ||
		   path.kind == .Invalid ||
		   u64(path.layer_index) >= u64(len(result.layers)) ||
		   path.vertex_offset != expected_path_vertex_offset ||
		   path.segment_offset != expected_path_segment_offset ||
		   u64(path.vertex_count) >
		   	u64(len(result.path_vertex_indices))-
		   	expected_path_vertex_offset ||
		   u64(path.segment_count) >
		   	u64(len(result.path_segment_indices))-
		   	expected_path_segment_offset {
			return {}, false
		}
		switch path.kind {
		case .Loop, .Degenerate_Loop:
			if path.vertex_count != path.segment_count {return {}, false}
		case .Open_Chain:
			if path.vertex_count != path.segment_count+1 {return {}, false}
		case .Invalid:
			return {}, false
		}
		expected_path_vertex_offset += u64(path.vertex_count)
		expected_path_segment_offset += u64(path.segment_count)
	}
	if expected_path_vertex_offset !=
	   u64(len(result.path_vertex_indices)) ||
	   expected_path_segment_offset !=
	   u64(len(result.path_segment_indices)) ||
	   expected_path_segment_offset != u64(source_segment_count) {
		return {}, false
	}
	for vertex_index in result.path_vertex_indices {
		if u64(vertex_index) >= u64(len(result.vertices)) {
			return {}, false
		}
	}
	for segment_index in result.path_segment_indices {
		if u64(segment_index) >= u64(source_segment_count) {
			return {}, false
		}
	}

	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/topology",
		SCHEMA_VERSION_TOPOLOGY_HASH,
	)
	contracts.canonical_hash_append_content_hash(&hash, snapped_hash)
	contracts.canonical_hash_append_u64(&hash, result.open_chain_count)
	contracts.canonical_hash_append_u64(
		&hash,
		result.degenerate_loop_count,
	)
	contracts.canonical_hash_append_u64(
		&hash,
		result.non_manifold_vertex_count,
	)
	contracts.canonical_hash_append_u64(&hash, u64(len(result.layers)))
	for layer in result.layers {
		contracts.canonical_hash_append_u64(&hash, layer.vertex_offset)
		contracts.canonical_hash_append_u32(&hash, layer.vertex_count)
		contracts.canonical_hash_append_u64(&hash, layer.path_offset)
		contracts.canonical_hash_append_u32(&hash, layer.path_count)
	}
	contracts.canonical_hash_append_u64(&hash, u64(len(result.vertices)))
	for vertex in result.vertices {
		contracts.canonical_hash_append_stable_id(&hash, vertex.id)
		contracts.canonical_hash_append_u32(&hash, vertex.layer_index)
		contracts.canonical_hash_append_i64(&hash, i64(vertex.point.x))
		contracts.canonical_hash_append_i64(&hash, i64(vertex.point.y))
		contracts.canonical_hash_append_u32(&hash, vertex.degree)
	}
	contracts.canonical_hash_append_u64(&hash, u64(len(result.paths)))
	for path in result.paths {
		contracts.canonical_hash_append_stable_id(&hash, path.id)
		contracts.canonical_hash_append_u32(&hash, path.layer_index)
		contracts.canonical_hash_append_u8(&hash, u8(path.kind))
		contracts.canonical_hash_append_u64(&hash, path.vertex_offset)
		contracts.canonical_hash_append_u32(&hash, path.vertex_count)
		contracts.canonical_hash_append_u64(&hash, path.segment_offset)
		contracts.canonical_hash_append_u32(&hash, path.segment_count)
		contracts.canonical_hash_append_i128(&hash, path.signed_area_2)
		contracts.canonical_hash_append_u8(
			&hash,
			u8(i8(path.winding)+1),
		)
	}
	contracts.canonical_hash_append_u64(
		&hash,
		u64(len(result.path_vertex_indices)),
	)
	for vertex_index in result.path_vertex_indices {
		contracts.canonical_hash_append_u32(&hash, vertex_index)
	}
	contracts.canonical_hash_append_u64(
		&hash,
		u64(len(result.path_segment_indices)),
	)
	for segment_index in result.path_segment_indices {
		contracts.canonical_hash_append_u32(&hash, segment_index)
	}
	return contracts.canonical_hash_final(&hash), true
}

region_result_hash :: proc(
	topology_hash: contracts.Content_Hash,
	topology: Topology_Result,
	result: Region_Result,
) -> (contracts.Content_Hash, bool) {
	if len(result.layers) != len(topology.layers) {
		return {}, false
	}
	expected_contour_offset: u64
	expected_region_offset: u64
	for layer, layer_index in result.layers {
		if layer.contour_offset != expected_contour_offset ||
		   layer.region_offset != expected_region_offset ||
		   layer.contour_offset+u64(layer.contour_count) >
		   	u64(len(result.contours)) ||
		   layer.region_offset+u64(layer.region_count) >
		   	u64(len(result.regions)) {
			return {}, false
		}
		contour_start := int(layer.contour_offset)
		contour_end := contour_start+int(layer.contour_count)
		for contour in result.contours[contour_start:contour_end] {
			if u64(contour.path_index) >= u64(len(topology.paths)) ||
			   topology.paths[contour.path_index].layer_index !=
			   	u32(layer_index) {
				return {}, false
			}
		}
		region_start := int(layer.region_offset)
		region_end := region_start+int(layer.region_count)
		for region in result.regions[region_start:region_end] {
			if region.layer_index != u32(layer_index) {
				return {}, false
			}
		}
		expected_contour_offset += u64(layer.contour_count)
		expected_region_offset += u64(layer.region_count)
	}
	if expected_contour_offset != u64(len(result.contours)) ||
	   expected_region_offset != u64(len(result.regions)) {
		return {}, false
	}
	hole_count: u64
	for contour, contour_index in result.contours {
		if u64(contour.path_index) >= u64(len(topology.paths)) ||
		   u64(contour.region_index) >= u64(len(result.regions)) {
			return {}, false
		}
		path := topology.paths[contour.path_index]
		if path.kind != .Loop ||
		   contour.stable_id != contracts.stable_id_child(
				path.id,
				.Region_Contour,
				0,
			) ||
		   geometry.point_2_validate({
				x = contour.bounds.minimum.x,
				y = contour.bounds.minimum.y,
			}) != .None ||
		   geometry.point_2_validate({
				x = contour.bounds.maximum.x,
				y = contour.bounds.maximum.y,
			}) != .None ||
		   contour.bounds.minimum.x > contour.bounds.maximum.x ||
		   contour.bounds.minimum.y > contour.bounds.maximum.y {
			return {}, false
		}
		if contour.parent_contour == REGION_INVALID_INDEX {
			if contour.depth != 0 || contour.role != .Outer {
				return {}, false
			}
		} else {
			if u64(contour.parent_contour) >=
			   	u64(len(result.contours)) ||
			   contour.parent_contour == u32(contour_index) {
				return {}, false
			}
			parent := result.contours[contour.parent_contour]
			if contour.depth != parent.depth+1 {
				return {}, false
			}
		}
		if contour.depth&1 == 0 {
			if contour.role != .Outer {return {}, false}
		} else {
			if contour.role != .Hole {return {}, false}
			hole_count += 1
		}
		expected_reverse :=
			contour.role == .Outer && path.winding == .Negative ||
			contour.role == .Hole && path.winding == .Positive
		if contour.reverse_path != expected_reverse {
			return {}, false
		}
	}
	if hole_count != result.hole_count {return {}, false}

	expected_member_offset: u64
	previous_outer := REGION_INVALID_INDEX
	for region, region_index in result.regions {
		if region.contour_offset != expected_member_offset ||
		   region.contour_count == 0 ||
		   region.contour_offset+u64(region.contour_count) >
		   	u64(len(result.region_contour_indices)) ||
		   u64(region.outer_contour_index) >=
		   	u64(len(result.contours)) {
			return {}, false
		}
		if previous_outer != REGION_INVALID_INDEX &&
		   region.outer_contour_index <= previous_outer {
			return {}, false
		}
		previous_outer = region.outer_contour_index
		outer := result.contours[region.outer_contour_index]
		path := topology.paths[outer.path_index]
		if outer.role != .Outer ||
		   outer.region_index != u32(region_index) ||
		   region.layer_index != path.layer_index ||
		   region.stable_id != contracts.stable_id_child(
				path.id,
				.Region,
				0,
			) ||
		   region.bounds != outer.bounds {
			return {}, false
		}
		start := int(region.contour_offset)
		end := start+int(region.contour_count)
		if result.region_contour_indices[start] !=
		   region.outer_contour_index {
			return {}, false
		}
		expected_area := region_area_magnitude(path.signed_area_2)
		previous_hole := REGION_INVALID_INDEX
		for member_index in start+1..<end {
			contour_index :=
				result.region_contour_indices[member_index]
			if u64(contour_index) >= u64(len(result.contours)) ||
			   previous_hole != REGION_INVALID_INDEX &&
			   	contour_index <= previous_hole {
				return {}, false
			}
			previous_hole = contour_index
			contour := result.contours[contour_index]
			if contour.role != .Hole ||
			   contour.region_index != u32(region_index) ||
			   contour.parent_contour != region.outer_contour_index {
				return {}, false
			}
			hole_path := topology.paths[contour.path_index]
			hole_area := region_area_magnitude(
				hole_path.signed_area_2,
			)
			if hole_area >= expected_area {return {}, false}
			expected_area -= hole_area
		}
		if region.filled_area_2 != expected_area {return {}, false}
		expected_member_offset += u64(region.contour_count)
	}
	if expected_member_offset !=
	   u64(len(result.region_contour_indices)) ||
	   expected_member_offset != u64(len(result.contours)) {
		return {}, false
	}

	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/regions",
		SCHEMA_VERSION_REGION_HASH,
	)
	contracts.canonical_hash_append_content_hash(&hash, topology_hash)
	contracts.canonical_hash_append_u64(&hash, result.hole_count)
	contracts.canonical_hash_append_u64(&hash, u64(len(result.layers)))
	for layer in result.layers {
		contracts.canonical_hash_append_u64(&hash, layer.contour_offset)
		contracts.canonical_hash_append_u32(&hash, layer.contour_count)
		contracts.canonical_hash_append_u64(&hash, layer.region_offset)
		contracts.canonical_hash_append_u32(&hash, layer.region_count)
	}
	contracts.canonical_hash_append_u64(&hash, u64(len(result.contours)))
	for contour in result.contours {
		contracts.canonical_hash_append_stable_id(
			&hash,
			contour.stable_id,
		)
		contracts.canonical_hash_append_u32(&hash, contour.path_index)
		contracts.canonical_hash_append_u32(
			&hash,
			contour.parent_contour,
		)
		contracts.canonical_hash_append_u32(&hash, contour.region_index)
		contracts.canonical_hash_append_u32(&hash, contour.depth)
		contracts.canonical_hash_append_u8(&hash, u8(contour.role))
		reverse_path := u8(0)
		if contour.reverse_path {reverse_path = 1}
		contracts.canonical_hash_append_u8(&hash, reverse_path)
		region_hash_append_bounds(&hash, contour.bounds)
	}
	contracts.canonical_hash_append_u64(&hash, u64(len(result.regions)))
	for region in result.regions {
		contracts.canonical_hash_append_stable_id(
			&hash,
			region.stable_id,
		)
		contracts.canonical_hash_append_u32(&hash, region.layer_index)
		contracts.canonical_hash_append_u32(
			&hash,
			region.outer_contour_index,
		)
		contracts.canonical_hash_append_u64(&hash, region.contour_offset)
		contracts.canonical_hash_append_u32(&hash, region.contour_count)
		contracts.canonical_hash_append_u64(
			&hash,
			u64(region.filled_area_2),
		)
		contracts.canonical_hash_append_u64(
			&hash,
			u64(region.filled_area_2>>64),
		)
		region_hash_append_bounds(&hash, region.bounds)
	}
	contracts.canonical_hash_append_u64(
		&hash,
		u64(len(result.region_contour_indices)),
	)
	for contour_index in result.region_contour_indices {
		contracts.canonical_hash_append_u32(&hash, contour_index)
	}
	return contracts.canonical_hash_final(&hash), true
}

region_hash_append_bounds :: proc(
	hash: ^contracts.Canonical_Hash,
	bounds: Region_Bounds,
) {
	contracts.canonical_hash_append_i64(
		hash,
		i64(bounds.minimum.x),
	)
	contracts.canonical_hash_append_i64(
		hash,
		i64(bounds.minimum.y),
	)
	contracts.canonical_hash_append_i64(
		hash,
		i64(bounds.maximum.x),
	)
	contracts.canonical_hash_append_i64(
		hash,
		i64(bounds.maximum.y),
	)
}

planar_ownership_result_hash :: proc(
	intersection_hash: contracts.Content_Hash,
	result: Planar_Ownership_Result,
) -> (contracts.Content_Hash, bool) {
	segment_result := Snapped_Segment_Result{
		layers = result.layers,
		segments = result.segments,
	}
	segment_hash, segment_hash_ok := snapped_segment_result_hash(
		intersection_hash,
		segment_result,
	)
	if !segment_hash_ok {return {}, false}
	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/planar-ownership",
		SCHEMA_VERSION_PLANAR_OWNERSHIP_HASH,
	)
	contracts.canonical_hash_append_content_hash(&hash, intersection_hash)
	contracts.canonical_hash_append_content_hash(&hash, segment_hash)
	contracts.canonical_hash_append_u64(&hash, result.incidence_count)
	contracts.canonical_hash_append_u64(
		&hash,
		result.unresolved_group_count,
	)
	contracts.canonical_hash_append_u64(
		&hash,
		result.suppressed_group_count,
	)
	contracts.canonical_hash_append_u64(
		&hash,
		result.collapsed_incidence_count,
	)
	contracts.canonical_hash_append_u64(
		&hash,
		result.exact_predicate_count,
	)
	return contracts.canonical_hash_final(&hash), true
}

layer_span_index_hash :: proc(
	schedule_hash: contracts.Content_Hash,
	index: Layer_Span_Index,
) -> (contracts.Content_Hash, bool) {
	pair_count := len(index.triangle_ids)
	if len(index.triangle_indices) != pair_count ||
	   len(index.triangle_ranges) == 0 ||
	   len(index.layers) == 0 {
		return {}, false
	}
	expected_offset: u64
	for layer in index.layers {
		if layer.offset != expected_offset ||
		   u64(layer.count) > u64(pair_count)-expected_offset {
			return {}, false
		}
		expected_offset += u64(layer.count)
	}
	if expected_offset != u64(pair_count) {return {}, false}
	expected_pair_count: u64
	for range_value in index.triangle_ranges {
		range_end := u64(range_value.first_layer)+
			u64(range_value.layer_count)
		switch range_value.kind {
		case .None:
			if range_value.first_layer != 0 ||
			   range_value.layer_count != 0 {
				return {}, false
			}
		case .Crossing_Candidates:
			if range_value.layer_count == 0 ||
			   range_end > u64(len(index.layers)) {
				return {}, false
			}
		case .Quantized_Planar:
			if range_value.layer_count != 1 ||
			   range_end > u64(len(index.layers)) {
				return {}, false
			}
		case:
			return {}, false
		}
		if expected_pair_count > max(u64)-
		   u64(range_value.layer_count) {
			return {}, false
		}
		expected_pair_count += u64(range_value.layer_count)
	}
	if expected_pair_count != u64(pair_count) {return {}, false}
	for layer, layer_index in index.layers {
		start := int(layer.offset)
		end := start+int(layer.count)
		previous_triangle_index: u32
		for triangle_index, pair_index in index.triangle_indices[start:end] {
			if u64(triangle_index) >=
			   u64(len(index.triangle_ranges)) {
				return {}, false
			}
			range_value := index.triangle_ranges[triangle_index]
			range_end := u64(range_value.first_layer)+
				u64(range_value.layer_count)
			out_of_order :=
				pair_index > 0 &&
				triangle_index <= previous_triangle_index
			wrong_layer :=
				u64(layer_index) < u64(range_value.first_layer) ||
				u64(layer_index) >= range_end
			invalid_id :=
				index.triangle_ids[start+pair_index] ==
				contracts.INVALID_STABLE_ID
			if out_of_order || wrong_layer || invalid_id {
				return {}, false
			}
			previous_triangle_index = triangle_index
		}
	}

	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/layer-span-index",
		SCHEMA_VERSION_LAYER_SPAN_INDEX_HASH,
	)
	contracts.canonical_hash_append_content_hash(&hash, schedule_hash)
	contracts.canonical_hash_append_u64(
		&hash,
		u64(len(index.triangle_ranges)),
	)
	for range_value in index.triangle_ranges {
		contracts.canonical_hash_append_u32(&hash, range_value.first_layer)
		contracts.canonical_hash_append_u32(&hash, range_value.layer_count)
		contracts.canonical_hash_append_u8(&hash, u8(range_value.kind))
	}
	contracts.canonical_hash_append_u64(&hash, u64(len(index.layers)))
	for layer in index.layers {
		contracts.canonical_hash_append_u64(&hash, layer.offset)
		contracts.canonical_hash_append_u32(&hash, layer.count)
	}
	contracts.canonical_hash_append_u64(&hash, u64(pair_count))
	for triangle_index, pair_index in index.triangle_indices {
		contracts.canonical_hash_append_u32(&hash, triangle_index)
		contracts.canonical_hash_append_stable_id(
			&hash,
			index.triangle_ids[pair_index],
		)
	}
	return contracts.canonical_hash_final(&hash), true
}
