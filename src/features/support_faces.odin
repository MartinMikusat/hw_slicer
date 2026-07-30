package features

import "core:math"

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import profiles "../profiles"

Support_Face_Kind :: enum u8 {
	Invalid,
	Degenerate,
	Upward_Or_Vertical,
	Downward_Within_Limit,
	Downward_Overhang,
}

Support_Face_Record :: struct {
	stable_id:             contracts.Stable_ID,
	triangle_id:           contracts.Stable_ID,
	triangle_index:        u32,
	kind:                  Support_Face_Kind,
	normal_x:              f64,
	normal_y:              f64,
	normal_z:              f64,
	normal_length_squared: f64,
	downward_z_squared:    f64,
	minimum_z:             contracts.Micrometres,
	maximum_z:             contracts.Micrometres,
	point_offset:          u64,
	point_count:           u8,
	projected_area_2:      i128,
}

Support_Face_Result :: struct {
	policy:                  profiles.Support_Demand_Policy,
	overhang_angle:          profiles.Angle_Millidegrees,
	threshold_sine_squared:  f64,
	faces:                   []Support_Face_Record,
	points:                  []polygon.Polygon_Point,
	degenerate_count:        u64,
	upward_or_vertical_count: u64,
	within_limit_count:      u64,
	overhang_count:          u64,
}

Support_Face_Limits :: struct {
	max_faces:             u64,
	max_projection_points: u64,
}

DEFAULT_SUPPORT_FACE_LIMITS :: Support_Face_Limits{
	max_faces = 100_000_000,
	max_projection_points = 300_000_000,
}

Support_Face_Error :: enum u8 {
	None,
	Invalid_Config,
	Invalid_Input,
	Face_Limit,
	Point_Limit,
	Coordinate_Range,
	Allocation_Failed,
	Arithmetic,
}

support_faces_classify :: proc(
	mesh: geometry.Canonical_Mesh,
	process: profiles.Resolved_Process_Profile,
	limits := DEFAULT_SUPPORT_FACE_LIMITS,
	allocator := context.allocator,
) -> (Support_Face_Result, Support_Face_Error) {
	if !profiles.process_support_targets_valid(process.source) ||
	   process.source.support_demand != .Mesh_And_Layer_Projection {
		return {}, .Invalid_Config
	}
	_, mesh_ok := geometry.canonical_mesh_hash(mesh)
	if !mesh_ok {return {}, .Invalid_Input}
	triangle_count := len(mesh.triangle_ids)
	if u64(triangle_count) > limits.max_faces {
		return {}, .Face_Limit
	}
	if u64(triangle_count) > limits.max_projection_points/3 {
		return {}, .Point_Limit
	}
	if triangle_count > max(int)/3 ||
	   u64(triangle_count) > u64(max(u32)) {
		return {}, .Arithmetic
	}

	angle_radians :=
		f64(process.source.support_overhang_angle)*
		math.PI/(180.0*1_000.0)
	threshold_sine := math.sin(angle_radians)
	threshold_sine_squared := threshold_sine*threshold_sine
	if math.is_nan(threshold_sine_squared) ||
	   math.is_inf(threshold_sine_squared) {
		return {}, .Invalid_Config
	}

	overhang_count: u64
	for triangle_index in 0..<triangle_count {
		normal_x, normal_y, normal_z, length_squared, normal_ok :=
			support_face_normal(mesh, u32(triangle_index))
		if !normal_ok {return {}, .Arithmetic}
		if length_squared > 0 && normal_z < 0 &&
		   normal_z*normal_z >
		    length_squared*threshold_sine_squared {
			overhang_count += 1
		}
	}
	if overhang_count > limits.max_projection_points/3 ||
	   overhang_count > u64(max(int))/3 {
		return {}, .Point_Limit
	}

	result := Support_Face_Result{
		policy = process.source.support_demand,
		overhang_angle = process.source.support_overhang_angle,
		threshold_sine_squared = threshold_sine_squared,
	}
	result.faces = make(
		[]Support_Face_Record,
		triangle_count,
		allocator,
	)
	result.points = make(
		[]polygon.Polygon_Point,
		int(overhang_count*3),
		allocator,
	)
	if triangle_count > 0 && result.faces == nil ||
	   overhang_count > 0 && result.points == nil {
		support_face_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	point_write := 0
	for triangle_id, triangle_index in mesh.triangle_ids {
		normal_x, normal_y, normal_z, length_squared, normal_ok :=
			support_face_normal(mesh, u32(triangle_index))
		if !normal_ok {
			support_face_result_destroy(&result, allocator)
			return {}, .Arithmetic
		}
		indices := [3]u32{
			mesh.triangle_a[triangle_index],
			mesh.triangle_b[triangle_index],
			mesh.triangle_c[triangle_index],
		}
		minimum_z := min(
			mesh.vertex_z[indices[0]],
			min(
				mesh.vertex_z[indices[1]],
				mesh.vertex_z[indices[2]],
			),
		)
		maximum_z := max(
			mesh.vertex_z[indices[0]],
			max(
				mesh.vertex_z[indices[1]],
				mesh.vertex_z[indices[2]],
			),
		)
		minimum_z_um, minimum_error :=
			geometry.millimetres_to_micrometres_quantized(
				contracts.Millimetres(minimum_z),
				.Floor,
			)
		maximum_z_um, maximum_error :=
			geometry.millimetres_to_micrometres_quantized(
				contracts.Millimetres(maximum_z),
				.Ceil,
			)
		if minimum_error != .None || maximum_error != .None {
			support_face_result_destroy(&result, allocator)
			return {}, .Coordinate_Range
		}
		kind := Support_Face_Kind.Upward_Or_Vertical
		downward_z_squared: f64
		if length_squared == 0 {
			kind = .Degenerate
			result.degenerate_count += 1
		} else if normal_z < 0 {
			downward_z_squared = normal_z*normal_z
			if downward_z_squared >
			   length_squared*threshold_sine_squared {
				kind = .Downward_Overhang
				result.overhang_count += 1
			} else {
				kind = .Downward_Within_Limit
				result.within_limit_count += 1
			}
		} else {
			result.upward_or_vertical_count += 1
		}

		record := Support_Face_Record{
			stable_id = triangle_id,
			triangle_id = triangle_id,
			triangle_index = u32(triangle_index),
			kind = kind,
			normal_x = normal_x,
			normal_y = normal_y,
			normal_z = normal_z,
			normal_length_squared = length_squared,
			downward_z_squared = downward_z_squared,
			minimum_z = minimum_z_um,
			maximum_z = maximum_z_um,
		}
		if kind == .Downward_Overhang {
			projected, projection_ok :=
				support_face_projected_triangle(mesh, indices)
			if !projection_ok {
				support_face_result_destroy(&result, allocator)
				return {}, .Coordinate_Range
			}
			if point_write+len(projected) > len(result.points) {
				support_face_result_destroy(&result, allocator)
				return {}, .Arithmetic
			}
			record.point_offset = u64(point_write)
			record.point_count = 3
			record.projected_area_2 =
				polygon.polygon_path_area_2(projected[:])
			copy(
				result.points[point_write:point_write+3],
				projected[:],
			)
			point_write += 3
		}
		result.faces[triangle_index] = record
	}
	if point_write != len(result.points) ||
	   result.degenerate_count+
	    result.upward_or_vertical_count+
	    result.within_limit_count+
	    result.overhang_count != u64(len(result.faces)) {
		support_face_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
}

support_face_normal :: proc(
	mesh: geometry.Canonical_Mesh,
	triangle_index: u32,
) -> (f64, f64, f64, f64, bool) {
	if u64(triangle_index) >= u64(len(mesh.triangle_ids)) {
		return 0, 0, 0, 0, false
	}
	a := mesh.triangle_a[triangle_index]
	b := mesh.triangle_b[triangle_index]
	c := mesh.triangle_c[triangle_index]
	if u64(a) >= u64(len(mesh.vertex_x)) ||
	   u64(b) >= u64(len(mesh.vertex_x)) ||
	   u64(c) >= u64(len(mesh.vertex_x)) {
		return 0, 0, 0, 0, false
	}
	ab_x := mesh.vertex_x[b]-mesh.vertex_x[a]
	ab_y := mesh.vertex_y[b]-mesh.vertex_y[a]
	ab_z := mesh.vertex_z[b]-mesh.vertex_z[a]
	ac_x := mesh.vertex_x[c]-mesh.vertex_x[a]
	ac_y := mesh.vertex_y[c]-mesh.vertex_y[a]
	ac_z := mesh.vertex_z[c]-mesh.vertex_z[a]
	normal_x := ab_y*ac_z-ab_z*ac_y
	normal_y := ab_z*ac_x-ab_x*ac_z
	normal_z := ab_x*ac_y-ab_y*ac_x
	length_squared :=
		normal_x*normal_x+
		normal_y*normal_y+
		normal_z*normal_z
	if math.is_nan(normal_x) || math.is_inf(normal_x) ||
	   math.is_nan(normal_y) || math.is_inf(normal_y) ||
	   math.is_nan(normal_z) || math.is_inf(normal_z) ||
	   math.is_nan(length_squared) || math.is_inf(length_squared) {
		return 0, 0, 0, 0, false
	}
	if normal_x == 0 {normal_x = 0}
	if normal_y == 0 {normal_y = 0}
	if normal_z == 0 {normal_z = 0}
	if length_squared == 0 {length_squared = 0}
	return normal_x, normal_y, normal_z, length_squared, true
}

support_face_projected_triangle :: proc(
	mesh: geometry.Canonical_Mesh,
	indices: [3]u32,
) -> ([3]polygon.Polygon_Point, bool) {
	points: [3]polygon.Polygon_Point
	for index in 0..<3 {
		x, x_error := geometry.millimetres_to_micrometres(
			contracts.Millimetres(mesh.vertex_x[indices[index]]),
		)
		y, y_error := geometry.millimetres_to_micrometres(
			contracts.Millimetres(mesh.vertex_y[indices[index]]),
		)
		if x_error != .None || y_error != .None {
			return {}, false
		}
		points[index] = {x, y}
	}
	area_2 := polygon.polygon_path_area_2(points[:])
	if area_2 == 0 {return {}, false}
	if area_2 < 0 {
		points[1], points[2] = points[2], points[1]
	}
	rotation := polygon.polygon_minimum_rotation(points[:])
	if rotation != 0 {
		source := points
		for index in 0..<len(points) {
			points[index] = source[(rotation+index)%len(points)]
		}
	}
	return points, true
}

support_face_result_destroy :: proc(
	result: ^Support_Face_Result,
	allocator := context.allocator,
) {
	delete(result.faces, allocator)
	delete(result.points, allocator)
	result^ = {}
}
