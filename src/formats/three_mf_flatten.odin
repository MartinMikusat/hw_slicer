package formats

import "core:math"
import "core:mem"

import contracts "../contracts"

THREE_MF_SOURCE_OFFSET_UNAVAILABLE :: max(u64)

Three_MF_Flatten_Limits :: struct {
	max_instances: u64,
	max_vertices:  u64,
	max_triangles: u64,
	max_component_depth: u32,
}

DEFAULT_THREE_MF_FLATTEN_LIMITS :: Three_MF_Flatten_Limits{
	max_instances = 10_000_000,
	max_vertices = 100_000_000,
	max_triangles = 100_000_000,
	max_component_depth = 256,
}

Three_MF_Flattened_Mesh :: struct {
	mesh:                  Decoded_Mesh,
	source_vertex_ids:     []contracts.Stable_ID,
	source_triangle_ids:   []contracts.Stable_ID,
	triangle_instance_ids: []contracts.Stable_ID,
	source_object_indices: []u32,
	object_types:          []Three_MF_Object_Type,
	property_resource:     []u32,
	property_a:            []u32,
	property_b:            []u32,
	property_c:            []u32,
}

Three_MF_Flatten_Error :: enum u8 {
	None,
	Invalid_Scene,
	Instance_Limit,
	Component_Depth_Limit,
	Vertex_Limit,
	Triangle_Limit,
	Non_Finite,
	Allocation_Failed,
}

Three_MF_Flatten_Writes :: struct {
	vertex:   int,
	triangle: int,
}

three_mf_scene_flatten :: proc(
	scene: Three_MF_Scene,
	limits := DEFAULT_THREE_MF_FLATTEN_LIMITS,
	allocator := context.allocator,
) -> (Three_MF_Flattened_Mesh, Three_MF_Flatten_Error) {
	_, scene_ok := three_mf_scene_hash(scene)
	if !scene_ok {return {}, .Invalid_Scene}
	occurrences := make([]u64, len(scene.objects), allocator)
	if len(scene.objects) > 0 && occurrences == nil {
		return {}, .Allocation_Failed
	}
	defer delete(occurrences, allocator)
	for item in scene.build_items {
		object_index := int(item.object_index)
		if occurrences[object_index] == max(u64) {
			return {}, .Instance_Limit
		}
		occurrences[object_index] += 1
	}

	instance_count: u64
	vertex_count: u64
	triangle_count: u64
	for reverse_index in 0..<len(scene.objects) {
		object_index := len(scene.objects)-1-reverse_index
		object := scene.objects[object_index]
		occurrence_count := occurrences[object_index]
		if occurrence_count == 0 {continue}
		if object.component_depth > limits.max_component_depth {
			return {}, .Component_Depth_Limit
		}
		if instance_count > max(u64)-occurrence_count {
			return {}, .Instance_Limit
		}
		instance_count += occurrence_count
		if instance_count > limits.max_instances {
			return {}, .Instance_Limit
		}
		switch object.kind {
		case .Mesh:
			if !three_mf_flatten_accumulate_count(
					&vertex_count,
					occurrence_count,
					u64(object.vertex_count),
					limits.max_vertices,
				) {
				return {}, .Vertex_Limit
			}
			if !three_mf_flatten_accumulate_count(
					&triangle_count,
					occurrence_count,
					u64(object.triangle_count),
					limits.max_triangles,
				) {
				return {}, .Triangle_Limit
			}
		case .Components:
			start := int(object.component_offset)
			end := start+int(object.component_count)
			for component in scene.components[start:end] {
				child_index := int(component.object_index)
				if occurrences[child_index] >
				   max(u64)-occurrence_count {
					return {}, .Instance_Limit
				}
				occurrences[child_index] += occurrence_count
			}
		case .Invalid:
			return {}, .Invalid_Scene
		}
	}
	if vertex_count == 0 || triangle_count == 0 {
		return {}, .Invalid_Scene
	}
	if vertex_count > u64(max(int)) || vertex_count > u64(max(u32)) {
		return {}, .Vertex_Limit
	}
	if triangle_count > u64(max(int)) {
		return {}, .Triangle_Limit
	}

	result: Three_MF_Flattened_Mesh
	if !three_mf_flatten_allocate(
		&result,
		int(vertex_count),
		int(triangle_count),
		allocator,
	) {
		three_mf_flattened_mesh_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	result.mesh.source = scene.source
	result.mesh.source_root_id = scene.source_root_id
	writes: Three_MF_Flatten_Writes
	for item, build_index in scene.build_items {
		instance_id := contracts.stable_id_child(
			scene.source_root_id,
			.Instance,
			u64(build_index),
		)
		error := three_mf_flatten_emit_object(
			scene,
			int(item.object_index),
			item.transform,
			instance_id,
			&result,
			&writes,
		)
		if error != .None {
			three_mf_flattened_mesh_destroy(&result, allocator)
			return {}, error
		}
	}
	if writes.vertex != int(vertex_count) ||
	   writes.triangle != int(triangle_count) {
		three_mf_flattened_mesh_destroy(&result, allocator)
		return {}, .Invalid_Scene
	}
	return result, .None
}

three_mf_flatten_accumulate_count :: proc(
	total: ^u64,
	occurrences: u64,
	per_instance: u64,
	limit: u64,
) -> bool {
	if per_instance > 0 && occurrences > max(u64)/per_instance {
		return false
	}
	added := occurrences*per_instance
	if total^ > max(u64)-added {return false}
	total^ += added
	return total^ <= limit
}

three_mf_flatten_allocate :: proc(
	result: ^Three_MF_Flattened_Mesh,
	vertex_count: int,
	triangle_count: int,
	allocator: mem.Allocator,
) -> bool {
	result.mesh.vertex_x = make([]f64, vertex_count, allocator)
	result.mesh.vertex_y = make([]f64, vertex_count, allocator)
	result.mesh.vertex_z = make([]f64, vertex_count, allocator)
	result.mesh.vertex_ids = make(
		[]contracts.Stable_ID,
		vertex_count,
		allocator,
	)
	result.source_vertex_ids = make(
		[]contracts.Stable_ID,
		vertex_count,
		allocator,
	)
	result.mesh.triangle_a = make([]u32, triangle_count, allocator)
	result.mesh.triangle_b = make([]u32, triangle_count, allocator)
	result.mesh.triangle_c = make([]u32, triangle_count, allocator)
	result.mesh.triangle_ids = make(
		[]contracts.Stable_ID,
		triangle_count,
		allocator,
	)
	result.mesh.source_record_offsets = make(
		[]u64,
		triangle_count,
		allocator,
	)
	result.source_triangle_ids = make(
		[]contracts.Stable_ID,
		triangle_count,
		allocator,
	)
	result.triangle_instance_ids = make(
		[]contracts.Stable_ID,
		triangle_count,
		allocator,
	)
	result.source_object_indices = make([]u32, triangle_count, allocator)
	result.object_types = make(
		[]Three_MF_Object_Type,
		triangle_count,
		allocator,
	)
	result.property_resource = make([]u32, triangle_count, allocator)
	result.property_a = make([]u32, triangle_count, allocator)
	result.property_b = make([]u32, triangle_count, allocator)
	result.property_c = make([]u32, triangle_count, allocator)
	return result.mesh.vertex_x != nil &&
		result.mesh.vertex_y != nil &&
		result.mesh.vertex_z != nil &&
		result.mesh.vertex_ids != nil &&
		result.source_vertex_ids != nil &&
		result.mesh.triangle_a != nil &&
		result.mesh.triangle_b != nil &&
		result.mesh.triangle_c != nil &&
		result.mesh.triangle_ids != nil &&
		result.mesh.source_record_offsets != nil &&
		result.source_triangle_ids != nil &&
		result.triangle_instance_ids != nil &&
		result.source_object_indices != nil &&
		result.object_types != nil &&
		result.property_resource != nil &&
		result.property_a != nil &&
		result.property_b != nil &&
		result.property_c != nil
}

three_mf_flatten_emit_object :: proc(
	scene: Three_MF_Scene,
	object_index: int,
	transform: Three_MF_Transform,
	instance_id: contracts.Stable_ID,
	result: ^Three_MF_Flattened_Mesh,
	writes: ^Three_MF_Flatten_Writes,
) -> Three_MF_Flatten_Error {
	object := scene.objects[object_index]
	switch object.kind {
	case .Mesh:
		vertex_offset := int(object.vertex_offset)
		output_vertex_offset := writes.vertex
		for local_vertex_index in 0..<int(object.vertex_count) {
			source_vertex_index := vertex_offset+local_vertex_index
			x, y, z, ok := three_mf_transform_point(
				transform,
				scene.vertices.x[source_vertex_index],
				scene.vertices.y[source_vertex_index],
				scene.vertices.z[source_vertex_index],
			)
			if !ok {return .Non_Finite}
			output_vertex_index := writes.vertex
			result.mesh.vertex_x[output_vertex_index] = x
			result.mesh.vertex_y[output_vertex_index] = y
			result.mesh.vertex_z[output_vertex_index] = z
			result.mesh.vertex_ids[output_vertex_index] =
				contracts.stable_id_child(
					instance_id,
					.Vertex,
					u64(local_vertex_index),
				)
			result.source_vertex_ids[output_vertex_index] =
				scene.vertices.stable_ids[source_vertex_index]
			writes.vertex += 1
		}
		determinant, determinant_ok :=
			three_mf_transform_determinant(transform)
		if !determinant_ok {return .Non_Finite}
		reverse_winding := determinant < 0
		triangle_offset := int(object.triangle_offset)
		for local_triangle_index in 0..<int(object.triangle_count) {
			source_triangle_index :=
				triangle_offset+local_triangle_index
			source_a := scene.triangles.a[source_triangle_index]
			source_b := scene.triangles.b[source_triangle_index]
			source_c := scene.triangles.c[source_triangle_index]
			local_a := source_a-u32(vertex_offset)
			local_b := source_b-u32(vertex_offset)
			local_c := source_c-u32(vertex_offset)
			property_a :=
				scene.triangles.property_a[source_triangle_index]
			property_b :=
				scene.triangles.property_b[source_triangle_index]
			property_c :=
				scene.triangles.property_c[source_triangle_index]
			if reverse_winding {
				local_a, local_c = local_c, local_a
				property_a, property_c = property_c, property_a
			}
			output_triangle_index := writes.triangle
			result.mesh.triangle_a[output_triangle_index] =
				u32(output_vertex_offset)+local_a
			result.mesh.triangle_b[output_triangle_index] =
				u32(output_vertex_offset)+local_b
			result.mesh.triangle_c[output_triangle_index] =
				u32(output_vertex_offset)+local_c
			result.mesh.triangle_ids[output_triangle_index] =
				contracts.stable_id_child(
					instance_id,
					.Triangle,
					u64(local_triangle_index),
				)
			result.mesh.source_record_offsets[output_triangle_index] =
				THREE_MF_SOURCE_OFFSET_UNAVAILABLE
			result.source_triangle_ids[output_triangle_index] =
				scene.triangles.stable_ids[source_triangle_index]
			result.triangle_instance_ids[output_triangle_index] =
				instance_id
			result.source_object_indices[output_triangle_index] =
				u32(object_index)
			result.object_types[output_triangle_index] = object.object_type
			result.property_resource[output_triangle_index] =
				scene.triangles.property_resource[source_triangle_index]
			result.property_a[output_triangle_index] = property_a
			result.property_b[output_triangle_index] = property_b
			result.property_c[output_triangle_index] = property_c
			writes.triangle += 1
		}
	case .Components:
		component_offset := int(object.component_offset)
		for local_component_index in 0..<int(object.component_count) {
			component :=
				scene.components[component_offset+local_component_index]
			child_transform, transform_ok := three_mf_transform_compose(
				component.transform,
				transform,
			)
			if !transform_ok {return .Non_Finite}
			child_instance_id := contracts.stable_id_child(
				instance_id,
				.Instance,
				u64(local_component_index),
			)
			error := three_mf_flatten_emit_object(
				scene,
				int(component.object_index),
				child_transform,
				child_instance_id,
				result,
				writes,
			)
			if error != .None {return error}
		}
	case .Invalid:
		return .Invalid_Scene
	}
	return .None
}

three_mf_transform_point :: proc(
	transform: Three_MF_Transform,
	x: f64,
	y: f64,
	z: f64,
) -> (f64, f64, f64, bool) {
	result_x :=
		x*transform[0]+y*transform[3]+z*transform[6]+transform[9]
	result_y :=
		x*transform[1]+y*transform[4]+z*transform[7]+transform[10]
	result_z :=
		x*transform[2]+y*transform[5]+z*transform[8]+transform[11]
	if math.is_nan(result_x) || math.is_inf(result_x) ||
	   math.is_nan(result_y) || math.is_inf(result_y) ||
	   math.is_nan(result_z) || math.is_inf(result_z) {
		return 0, 0, 0, false
	}
	if result_x == 0 {result_x = 0}
	if result_y == 0 {result_y = 0}
	if result_z == 0 {result_z = 0}
	return result_x, result_y, result_z, true
}

three_mf_transform_compose :: proc(
	first: Three_MF_Transform,
	second: Three_MF_Transform,
) -> (Three_MF_Transform, bool) {
	result: Three_MF_Transform
	for row in 0..<3 {
		for column in 0..<3 {
			result[row*3+column] =
				first[row*3]*second[column]+
				first[row*3+1]*second[3+column]+
				first[row*3+2]*second[6+column]
		}
	}
	for column in 0..<3 {
		result[9+column] =
			first[9]*second[column]+
			first[10]*second[3+column]+
			first[11]*second[6+column]+
			second[9+column]
	}
	for &value in result {
		if math.is_nan(value) || math.is_inf(value) {
			return {}, false
		}
		if value == 0 {value = 0}
	}
	return result, true
}

three_mf_transform_determinant :: proc(
	transform: Three_MF_Transform,
) -> (f64, bool) {
	result :=
		transform[0]*(transform[4]*transform[8]-transform[5]*transform[7])-
		transform[1]*(transform[3]*transform[8]-transform[5]*transform[6])+
		transform[2]*(transform[3]*transform[7]-transform[4]*transform[6])
	if math.is_nan(result) || math.is_inf(result) {
		return 0, false
	}
	if result == 0 {result = 0}
	return result, true
}

three_mf_flattened_mesh_destroy :: proc(
	result: ^Three_MF_Flattened_Mesh,
	allocator := context.allocator,
) {
	decoded_mesh_destroy(&result.mesh, allocator)
	delete(result.source_vertex_ids, allocator)
	delete(result.source_triangle_ids, allocator)
	delete(result.triangle_instance_ids, allocator)
	delete(result.source_object_indices, allocator)
	delete(result.object_types, allocator)
	delete(result.property_resource, allocator)
	delete(result.property_a, allocator)
	delete(result.property_b, allocator)
	delete(result.property_c, allocator)
	result^ = {}
}
