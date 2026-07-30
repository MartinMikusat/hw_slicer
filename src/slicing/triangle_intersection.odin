package slicing

import contracts "../contracts"
import geometry "../geometry"

Triangle_Edge :: enum u8 {
	Invalid,
	AB,
	BC,
	CA,
}

Triangle_Plane_Kind :: enum u8 {
	None,
	Segment,
	Tangent_Vertex,
	Coplanar_Edge,
	Coplanar_Face,
	Degenerate_Segment,
}

Raw_Point_2 :: struct {
	x: f64,
	y: f64,
}

Triangle_Plane_Result :: struct {
	kind:                  Triangle_Plane_Kind,
	point_a:               Raw_Point_2,
	point_b:               Raw_Point_2,
	edge_a:                Triangle_Edge,
	edge_b:                Triangle_Edge,
	exact_predicate_count: u8,
}

Triangle_Plane_Error :: enum u8 {
	None,
	Invalid_Coordinate,
	Arithmetic,
}

triangle_plane_intersect :: proc(
	vertex_x, vertex_y, vertex_z: [3]f64,
	plane_z: contracts.Micrometres,
) -> (Triangle_Plane_Result, Triangle_Plane_Error) {
	result: Triangle_Plane_Result
	sides: [3]geometry.Plane_Side
	on_count: u8
	above_count: u8
	below_count: u8
	for vertex_index in 0..<3 {
		_, x_error := geometry.millimetres_to_micrometres(
			contracts.Millimetres(vertex_x[vertex_index]),
		)
		_, y_error := geometry.millimetres_to_micrometres(
			contracts.Millimetres(vertex_y[vertex_index]),
		)
		side, z_error := geometry.plane_side_classify(
			contracts.Millimetres(vertex_z[vertex_index]),
			plane_z,
		)
		if x_error != .None || y_error != .None || z_error != .None {
			return {}, .Invalid_Coordinate
		}
		sides[vertex_index] = side.side
		if side.path == .Exact {result.exact_predicate_count += 1}
		switch side.side {
		case .Below: below_count += 1
		case .On:    on_count += 1
		case .Above: above_count += 1
		}
	}

	if on_count == 3 {
		result.kind = .Coplanar_Face
		return result, .None
	}
	if on_count == 2 {
		on_vertices: [2]int
		on_vertex_count := 0
		for side, vertex_index in sides {
			if side == .On {
				on_vertices[on_vertex_count] = vertex_index
				on_vertex_count += 1
			}
		}
		result.kind = .Coplanar_Edge
		result.point_a = {
			vertex_x[on_vertices[0]],
			vertex_y[on_vertices[0]],
		}
		result.point_b = {
			vertex_x[on_vertices[1]],
			vertex_y[on_vertices[1]],
		}
		result.edge_a = triangle_edge_from_vertices(
			on_vertices[0],
			on_vertices[1],
		)
		result.edge_b = result.edge_a
		triangle_plane_order_points(&result)
		return result, .None
	}
	if on_count == 1 && (above_count == 0 || below_count == 0) {
		result.kind = .Tangent_Vertex
		return result, .None
	}

	edges := [3][2]int{{0, 1}, {1, 2}, {2, 0}}
	edge_kinds := [3]Triangle_Edge{.AB, .BC, .CA}
	points: [2]Raw_Point_2
	point_edges: [2]Triangle_Edge
	point_count := 0
	// Treat an on-plane vertex as the lower endpoint.
	for edge_vertices, edge_index in edges {
		a := edge_vertices[0]
		b := edge_vertices[1]
		a_is_upper := sides[a] == .Above
		b_is_upper := sides[b] == .Above
		if a_is_upper == b_is_upper {continue}
		if point_count == len(points) {return {}, .Arithmetic}
		point, point_ok := triangle_plane_edge_point(
			vertex_x,
			vertex_y,
			vertex_z,
			sides,
			a,
			b,
			plane_z,
		)
		if !point_ok {return {}, .Arithmetic}
		points[point_count] = point
		point_edges[point_count] = edge_kinds[edge_index]
		point_count += 1
	}
	if point_count == 0 {
		if on_count == 1 {result.kind = .Tangent_Vertex}
		return result, .None
	}
	if point_count != 2 {return {}, .Arithmetic}
	result.kind = .Segment
	result.point_a = points[0]
	result.point_b = points[1]
	result.edge_a = point_edges[0]
	result.edge_b = point_edges[1]
	triangle_plane_order_points(&result)
	if result.point_a == result.point_b {
		result.kind = .Degenerate_Segment
	}
	return result, .None
}

triangle_plane_edge_point :: proc(
	vertex_x, vertex_y, vertex_z: [3]f64,
	sides: [3]geometry.Plane_Side,
	a, b: int,
	plane_z: contracts.Micrometres,
) -> (Raw_Point_2, bool) {
	if sides[a] == .On {
		return {vertex_x[a], vertex_y[a]}, true
	}
	if sides[b] == .On {
		return {vertex_x[b], vertex_y[b]}, true
	}
	plane_mm := f64(geometry.micrometres_to_millimetres(plane_z))
	denominator := vertex_z[b]-vertex_z[a]
	if denominator == 0 {return {}, false}
	t := (plane_mm-vertex_z[a])/denominator
	if t < 0 || t > 1 {return {}, false}
	x := vertex_x[a]+t*(vertex_x[b]-vertex_x[a])
	y := vertex_y[a]+t*(vertex_y[b]-vertex_y[a])
	if x == 0 {x = 0}
	if y == 0 {y = 0}
	return {x, y}, true
}

triangle_plane_order_points :: proc(result: ^Triangle_Plane_Result) {
	if result.point_b.x < result.point_a.x ||
	   (result.point_b.x == result.point_a.x &&
	    result.point_b.y < result.point_a.y) {
		result.point_a, result.point_b = result.point_b, result.point_a
		result.edge_a, result.edge_b = result.edge_b, result.edge_a
	}
}

triangle_edge_from_vertices :: proc(a, b: int) -> Triangle_Edge {
	minimum := min(a, b)
	maximum := max(a, b)
	switch {
	case minimum == 0 && maximum == 1: return .AB
	case minimum == 1 && maximum == 2: return .BC
	case minimum == 0 && maximum == 2: return .CA
	}
	return .Invalid
}
