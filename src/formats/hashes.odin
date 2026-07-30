package formats

import crypto_hash "core:crypto/hash"
import "core:math"

import contracts "../contracts"

SCHEMA_VERSION_DECODED_MESH_HASH :: u32(1)
SCHEMA_VERSION_THREE_MF_SCENE_HASH :: u32(3)

decoded_mesh_hash :: proc(
	mesh: Decoded_Mesh,
) -> (contracts.Content_Hash, bool) {
	vertex_count := len(mesh.vertex_x)
	triangle_count := len(mesh.triangle_ids)
	if vertex_count == 0 || triangle_count == 0 ||
	   len(mesh.vertex_y) != vertex_count ||
	   len(mesh.vertex_z) != vertex_count ||
	   len(mesh.vertex_ids) != vertex_count ||
	   len(mesh.triangle_a) != triangle_count ||
	   len(mesh.triangle_b) != triangle_count ||
	   len(mesh.triangle_c) != triangle_count ||
	   len(mesh.source_record_offsets) != triangle_count ||
	   mesh.source.format == .Invalid ||
	   mesh.source_root_id == contracts.INVALID_STABLE_ID {
		return {}, false
	}
	for vertex_index in 0..<vertex_count {
		if !decoded_mesh_hash_coordinate_valid(mesh.vertex_x[vertex_index]) ||
		   !decoded_mesh_hash_coordinate_valid(mesh.vertex_y[vertex_index]) ||
		   !decoded_mesh_hash_coordinate_valid(mesh.vertex_z[vertex_index]) ||
		   mesh.vertex_ids[vertex_index] == contracts.INVALID_STABLE_ID {
			return {}, false
		}
	}
	for triangle_index in 0..<triangle_count {
		if u64(mesh.triangle_a[triangle_index]) >= u64(vertex_count) ||
		   u64(mesh.triangle_b[triangle_index]) >= u64(vertex_count) ||
		   u64(mesh.triangle_c[triangle_index]) >= u64(vertex_count) ||
		   mesh.triangle_ids[triangle_index] == contracts.INVALID_STABLE_ID {
			return {}, false
		}
	}

	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/decoded-mesh",
		SCHEMA_VERSION_DECODED_MESH_HASH,
	)
	contracts.canonical_hash_append_content_hash(
		&hash,
		mesh.source.content_hash,
	)
	contracts.canonical_hash_append_u64(&hash, mesh.source.byte_count)
	contracts.canonical_hash_append_u8(&hash, u8(mesh.source.format))
	contracts.canonical_hash_append_u8(&hash, u8(mesh.source.units))
	contracts.canonical_hash_append_stable_id(&hash, mesh.source_root_id)
	contracts.canonical_hash_append_u64(&hash, u64(vertex_count))
	for vertex_index in 0..<vertex_count {
		contracts.canonical_hash_append_f64_bits(
			&hash,
			mesh.vertex_x[vertex_index],
		)
		contracts.canonical_hash_append_f64_bits(
			&hash,
			mesh.vertex_y[vertex_index],
		)
		contracts.canonical_hash_append_f64_bits(
			&hash,
			mesh.vertex_z[vertex_index],
		)
		contracts.canonical_hash_append_stable_id(
			&hash,
			mesh.vertex_ids[vertex_index],
		)
	}
	contracts.canonical_hash_append_u64(&hash, u64(triangle_count))
	for triangle_index in 0..<triangle_count {
		contracts.canonical_hash_append_u32(
			&hash,
			mesh.triangle_a[triangle_index],
		)
		contracts.canonical_hash_append_u32(
			&hash,
			mesh.triangle_b[triangle_index],
		)
		contracts.canonical_hash_append_u32(
			&hash,
			mesh.triangle_c[triangle_index],
		)
		contracts.canonical_hash_append_stable_id(
			&hash,
			mesh.triangle_ids[triangle_index],
		)
		contracts.canonical_hash_append_u64(
			&hash,
			mesh.source_record_offsets[triangle_index],
		)
	}
	return contracts.canonical_hash_final(&hash), true
}

decoded_mesh_hash_coordinate_valid :: proc(value: f64) -> bool {
	if math.is_nan(value) || math.is_inf(value) {return false}
	return value != 0 || transmute(u64)value == 0
}

three_mf_scene_hash :: proc(
	scene: Three_MF_Scene,
) -> (contracts.Content_Hash, bool) {
	vertex_count := len(scene.vertices.x)
	triangle_count := len(scene.triangles.a)
	object_count := len(scene.objects)
	component_count := len(scene.components)
	property_group_count := len(scene.property_groups)
	base_material_count := len(scene.base_materials)
	metadata_count := len(scene.metadata)
	extension_resource_count := len(scene.extension_resources)
	if vertex_count == 0 || triangle_count == 0 || object_count == 0 ||
	   len(scene.build_items) == 0 ||
	   scene.model_part_path == "" ||
	   len(scene.vertices.y) != vertex_count ||
	   len(scene.vertices.z) != vertex_count ||
	   len(scene.vertices.stable_ids) != vertex_count ||
	   len(scene.triangles.b) != triangle_count ||
	   len(scene.triangles.c) != triangle_count ||
	   len(scene.triangles.stable_ids) != triangle_count ||
	   len(scene.triangles.object_indices) != triangle_count ||
	   len(scene.triangles.property_resource) != triangle_count ||
	   len(scene.triangles.property_a) != triangle_count ||
	   len(scene.triangles.property_b) != triangle_count ||
	   len(scene.triangles.property_c) != triangle_count ||
	   scene.source.format != .Three_MF ||
	   scene.source.units == .Unspecified ||
	   scene.source_root_id == contracts.INVALID_STABLE_ID {
		return {}, false
	}
	for vertex_index in 0..<vertex_count {
		if !decoded_mesh_hash_coordinate_valid(
				scene.vertices.x[vertex_index],
			) ||
		   !decoded_mesh_hash_coordinate_valid(
				scene.vertices.y[vertex_index],
			) ||
		   !decoded_mesh_hash_coordinate_valid(
				scene.vertices.z[vertex_index],
			) ||
		   scene.vertices.stable_ids[vertex_index] ==
		   	contracts.INVALID_STABLE_ID {
			return {}, false
		}
	}
	for triangle_index in 0..<triangle_count {
		if u64(scene.triangles.a[triangle_index]) >= u64(vertex_count) ||
		   u64(scene.triangles.b[triangle_index]) >= u64(vertex_count) ||
		   u64(scene.triangles.c[triangle_index]) >= u64(vertex_count) ||
		   scene.triangles.a[triangle_index] ==
		   	scene.triangles.b[triangle_index] ||
		   scene.triangles.b[triangle_index] ==
		   	scene.triangles.c[triangle_index] ||
		   scene.triangles.c[triangle_index] ==
		   	scene.triangles.a[triangle_index] ||
		   scene.triangles.stable_ids[triangle_index] ==
		   	contracts.INVALID_STABLE_ID ||
		   u64(scene.triangles.object_indices[triangle_index]) >=
		   	u64(object_count) ||
		   !three_mf_hash_property_valid(
				scene.triangles.property_resource[triangle_index],
				scene.triangles.property_a[triangle_index],
				scene.triangles.property_b[triangle_index],
				scene.triangles.property_c[triangle_index],
			) {
			return {}, false
		}
	}
	expected_vertex_offset: u64
	expected_triangle_offset: u64
	expected_component_offset: u64
	for object, object_index in scene.objects {
		if object.stable_id == contracts.INVALID_STABLE_ID ||
		   object.resource_id == 0 ||
		   object.resource_id >= 0x8000_0000 ||
		   object.kind == .Invalid ||
		   object.vertex_offset != expected_vertex_offset ||
		   object.triangle_offset != expected_triangle_offset ||
		   object.component_offset != expected_component_offset ||
		   !three_mf_hash_object_spans_valid(
				object,
				vertex_count,
				triangle_count,
				component_count,
			) ||
		   !three_mf_hash_object_relationships_valid(
				scene,
				object_index,
			) {
			return {}, false
		}
		expected_vertex_offset += u64(object.vertex_count)
		expected_triangle_offset += u64(object.triangle_count)
		expected_component_offset += u64(object.component_count)
	}
	if expected_vertex_offset != u64(vertex_count) ||
	   expected_triangle_offset != u64(triangle_count) ||
	   expected_component_offset != u64(component_count) {
		return {}, false
	}
	for component in scene.components {
		if u64(component.parent_object_index) >= u64(object_count) ||
		   u64(component.object_index) >= u64(object_count) ||
		   component.stable_id == contracts.INVALID_STABLE_ID ||
		   !three_mf_hash_transform_valid(component.transform) {
			return {}, false
		}
	}
	for item in scene.build_items {
		if u64(item.object_index) >= u64(object_count) ||
		   scene.objects[item.object_index].contains_other ||
		   !three_mf_hash_transform_valid(item.transform) {
			return {}, false
		}
	}
	expected_material_offset: u64
	expected_extension_index := 0
	for group, group_index in scene.property_groups {
		if group.resource_id == 0 ||
		   group.resource_id >= 0x8000_0000 ||
		   group.stable_id == contracts.INVALID_STABLE_ID ||
		   group.kind == .Invalid ||
		   group.material_offset != expected_material_offset ||
		   group.material_offset+u64(group.material_count) >
		   	u64(base_material_count) {
			return {}, false
		}
		switch group.kind {
		case .Base_Materials:
			if group.material_count == 0 {return {}, false}
		case .Extension:
			if group.material_count != 0 {return {}, false}
			if expected_extension_index >= extension_resource_count {
				return {}, false
			}
			resource :=
				scene.extension_resources[expected_extension_index]
			if resource.resource_id != group.resource_id ||
			   resource.property_group_index != u32(group_index) ||
			   resource.stable_id != contracts.stable_id_child(
					group.stable_id,
					.Extension_Resource,
					0,
				) ||
			   resource.namespace_uri == "" ||
			   resource.qualified_name == "" ||
			   resource.payload_schema_version !=
			   	THREE_MF_EXTENSION_PAYLOAD_SCHEMA_VERSION ||
			   len(resource.payload) == 0 {
				return {}, false
			}
			payload_hash: contracts.Content_Hash
			_ = crypto_hash.hash_bytes_to_buffer(
				.SHA256,
				resource.payload,
				payload_hash[:],
			)
			if payload_hash != resource.payload_hash {
				return {}, false
			}
			expected_extension_index += 1
		case .Invalid:
			return {}, false
		}
		start := int(group.material_offset)
		end := start+int(group.material_count)
		for material in scene.base_materials[start:end] {
			if material.group_index != u32(group_index) ||
			   material.stable_id == contracts.INVALID_STABLE_ID {
				return {}, false
			}
		}
		expected_material_offset += u64(group.material_count)
	}
	if expected_material_offset != u64(base_material_count) {
		return {}, false
	}
	if expected_extension_index != extension_resource_count {
		return {}, false
	}
	for metadata in scene.metadata {
		if metadata.stable_id == contracts.INVALID_STABLE_ID ||
		   metadata.name == "" {
			return {}, false
		}
	}

	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/three-mf-scene",
		SCHEMA_VERSION_THREE_MF_SCENE_HASH,
	)
	contracts.canonical_hash_append_content_hash(
		&hash,
		scene.source.content_hash,
	)
	contracts.canonical_hash_append_u64(&hash, scene.source.byte_count)
	contracts.canonical_hash_append_u8(&hash, u8(scene.source.format))
	contracts.canonical_hash_append_u8(&hash, u8(scene.source.units))
	contracts.canonical_hash_append_stable_id(&hash, scene.source_root_id)
	contracts.canonical_hash_append_string(&hash, scene.model_part_path)
	contracts.canonical_hash_append_u64(&hash, u64(metadata_count))
	for metadata in scene.metadata {
		contracts.canonical_hash_append_stable_id(
			&hash,
			metadata.stable_id,
		)
		contracts.canonical_hash_append_string(&hash, metadata.name)
		contracts.canonical_hash_append_string(
			&hash,
			metadata.namespace_uri,
		)
		contracts.canonical_hash_append_string(&hash, metadata.value)
		contracts.canonical_hash_append_string(
			&hash,
			metadata.value_type,
		)
		contracts.canonical_hash_append_u8(
			&hash,
			u8(metadata.preserve),
		)
	}
	contracts.canonical_hash_append_u64(
		&hash,
		u64(property_group_count),
	)
	for group in scene.property_groups {
		contracts.canonical_hash_append_u32(&hash, group.resource_id)
		contracts.canonical_hash_append_stable_id(&hash, group.stable_id)
		contracts.canonical_hash_append_u8(&hash, u8(group.kind))
		contracts.canonical_hash_append_u64(
			&hash,
			group.material_offset,
		)
		contracts.canonical_hash_append_u32(&hash, group.material_count)
	}
	contracts.canonical_hash_append_u64(
		&hash,
		u64(base_material_count),
	)
	for material in scene.base_materials {
		contracts.canonical_hash_append_u32(&hash, material.group_index)
		contracts.canonical_hash_append_stable_id(
			&hash,
			material.stable_id,
		)
		contracts.canonical_hash_append_string(&hash, material.name)
		contracts.canonical_hash_append_u32(&hash, material.display_rgba)
	}
	contracts.canonical_hash_append_u64(
		&hash,
		u64(extension_resource_count),
	)
	for resource in scene.extension_resources {
		contracts.canonical_hash_append_u32(&hash, resource.resource_id)
		contracts.canonical_hash_append_u32(
			&hash,
			resource.property_group_index,
		)
		contracts.canonical_hash_append_stable_id(
			&hash,
			resource.stable_id,
		)
		contracts.canonical_hash_append_string(
			&hash,
			resource.namespace_uri,
		)
		contracts.canonical_hash_append_string(
			&hash,
			resource.qualified_name,
		)
		contracts.canonical_hash_append_u32(
			&hash,
			resource.payload_schema_version,
		)
		contracts.canonical_hash_append_content_hash(
			&hash,
			resource.payload_hash,
		)
		contracts.canonical_hash_append_u64(
			&hash,
			u64(len(resource.payload)),
		)
	}
	contracts.canonical_hash_append_u64(&hash, u64(vertex_count))
	for vertex_index in 0..<vertex_count {
		contracts.canonical_hash_append_f64_bits(
			&hash,
			scene.vertices.x[vertex_index],
		)
		contracts.canonical_hash_append_f64_bits(
			&hash,
			scene.vertices.y[vertex_index],
		)
		contracts.canonical_hash_append_f64_bits(
			&hash,
			scene.vertices.z[vertex_index],
		)
		contracts.canonical_hash_append_stable_id(
			&hash,
			scene.vertices.stable_ids[vertex_index],
		)
	}
	contracts.canonical_hash_append_u64(&hash, u64(triangle_count))
	for triangle_index in 0..<triangle_count {
		contracts.canonical_hash_append_u32(
			&hash,
			scene.triangles.a[triangle_index],
		)
		contracts.canonical_hash_append_u32(
			&hash,
			scene.triangles.b[triangle_index],
		)
		contracts.canonical_hash_append_u32(
			&hash,
			scene.triangles.c[triangle_index],
		)
		contracts.canonical_hash_append_stable_id(
			&hash,
			scene.triangles.stable_ids[triangle_index],
		)
		contracts.canonical_hash_append_u32(
			&hash,
			scene.triangles.object_indices[triangle_index],
		)
		contracts.canonical_hash_append_u32(
			&hash,
			scene.triangles.property_resource[triangle_index],
		)
		contracts.canonical_hash_append_u32(
			&hash,
			scene.triangles.property_a[triangle_index],
		)
		contracts.canonical_hash_append_u32(
			&hash,
			scene.triangles.property_b[triangle_index],
		)
		contracts.canonical_hash_append_u32(
			&hash,
			scene.triangles.property_c[triangle_index],
		)
	}
	contracts.canonical_hash_append_u64(&hash, u64(object_count))
	for object in scene.objects {
		contracts.canonical_hash_append_u32(&hash, object.resource_id)
		contracts.canonical_hash_append_stable_id(&hash, object.stable_id)
		contracts.canonical_hash_append_u8(&hash, u8(object.kind))
		contracts.canonical_hash_append_u8(&hash, u8(object.object_type))
		contracts.canonical_hash_append_u64(&hash, object.vertex_offset)
		contracts.canonical_hash_append_u32(&hash, object.vertex_count)
		contracts.canonical_hash_append_u64(&hash, object.triangle_offset)
		contracts.canonical_hash_append_u32(&hash, object.triangle_count)
		contracts.canonical_hash_append_u64(&hash, object.component_offset)
		contracts.canonical_hash_append_u32(&hash, object.component_count)
		contracts.canonical_hash_append_u32(
			&hash,
			object.property_resource,
		)
		contracts.canonical_hash_append_u32(&hash, object.property_index)
		contracts.canonical_hash_append_u32(&hash, object.component_depth)
		contracts.canonical_hash_append_u8(
			&hash,
			u8(object.contains_other),
		)
	}
	contracts.canonical_hash_append_u64(&hash, u64(component_count))
	for component in scene.components {
		contracts.canonical_hash_append_u32(
			&hash,
			component.parent_object_index,
		)
		contracts.canonical_hash_append_u32(
			&hash,
			component.object_index,
		)
		contracts.canonical_hash_append_stable_id(
			&hash,
			component.stable_id,
		)
		three_mf_hash_append_transform(&hash, component.transform)
	}
	contracts.canonical_hash_append_u64(
		&hash,
		u64(len(scene.build_items)),
	)
	for item in scene.build_items {
		contracts.canonical_hash_append_u32(&hash, item.object_index)
		three_mf_hash_append_transform(&hash, item.transform)
	}
	return contracts.canonical_hash_final(&hash), true
}

three_mf_hash_property_valid :: proc(
	resource: u32,
	a: u32,
	b: u32,
	c: u32,
) -> bool {
	if resource == THREE_MF_INVALID_PROPERTY {
		return a == THREE_MF_INVALID_PROPERTY &&
			b == THREE_MF_INVALID_PROPERTY &&
			c == THREE_MF_INVALID_PROPERTY
	}
	return resource > 0 && resource < 0x8000_0000 &&
		a < 0x8000_0000 &&
		b < 0x8000_0000 &&
		c < 0x8000_0000
}

three_mf_hash_object_spans_valid :: proc(
	object: Three_MF_Object,
	vertex_count: int,
	triangle_count: int,
	component_count: int,
) -> bool {
	vertex_end := object.vertex_offset+u64(object.vertex_count)
	triangle_end := object.triangle_offset+u64(object.triangle_count)
	component_end := object.component_offset+u64(object.component_count)
	if vertex_end > u64(vertex_count) ||
	   triangle_end > u64(triangle_count) ||
	   component_end > u64(component_count) {
		return false
	}
	switch object.kind {
	case .Mesh:
		return object.vertex_count >= 3 &&
			object.triangle_count >= 1 &&
			object.component_count == 0
	case .Components:
		return object.vertex_count == 0 &&
			object.triangle_count == 0 &&
			object.component_count >= 1
	case .Invalid:
	}
	return false
}

three_mf_hash_object_relationships_valid :: proc(
	scene: Three_MF_Scene,
	object_index: int,
) -> bool {
	object := scene.objects[object_index]
	if object.property_resource == THREE_MF_INVALID_PROPERTY {
		if object.property_index != THREE_MF_INVALID_PROPERTY {
			return false
		}
	} else if object.property_resource == 0 ||
	          object.property_resource >= 0x8000_0000 ||
	          object.property_index >= 0x8000_0000 &&
	          	object.property_index != THREE_MF_INVALID_PROPERTY {
		return false
	}
	switch object.kind {
	case .Mesh:
		if object.component_depth != 0 ||
		   object.contains_other != (object.object_type == .Other) {
			return false
		}
		start := int(object.triangle_offset)
		end := start+int(object.triangle_count)
		vertex_start := u32(object.vertex_offset)
		vertex_end := vertex_start+object.vertex_count
		for triangle_index in start..<end {
			if scene.triangles.object_indices[triangle_index] !=
			   	u32(object_index) ||
			   scene.triangles.a[triangle_index] < vertex_start ||
			   scene.triangles.a[triangle_index] >= vertex_end ||
			   scene.triangles.b[triangle_index] < vertex_start ||
			   scene.triangles.b[triangle_index] >= vertex_end ||
			   scene.triangles.c[triangle_index] < vertex_start ||
			   scene.triangles.c[triangle_index] >= vertex_end {
				return false
			}
		}
	case .Components:
		if object.property_resource != THREE_MF_INVALID_PROPERTY ||
		   object.property_index != THREE_MF_INVALID_PROPERTY {
			return false
		}
		expected_depth: u32
		expected_contains_other := false
		start := int(object.component_offset)
		end := start+int(object.component_count)
		for component in scene.components[start:end] {
			if component.parent_object_index != u32(object_index) ||
			   component.object_index >= u32(object_index) {
				return false
			}
			child := scene.objects[component.object_index]
			expected_depth = max(expected_depth, child.component_depth+1)
			expected_contains_other =
				expected_contains_other || child.contains_other
		}
		if object.component_depth != expected_depth ||
		   object.contains_other != expected_contains_other {
			return false
		}
	case .Invalid:
		return false
	}
	return true
}

three_mf_hash_transform_valid :: proc(
	transform: Three_MF_Transform,
) -> bool {
	for value in transform {
		if !decoded_mesh_hash_coordinate_valid(value) {return false}
	}
	return true
}

three_mf_hash_append_transform :: proc(
	hash: ^contracts.Canonical_Hash,
	transform: Three_MF_Transform,
) {
	for value in transform {
		contracts.canonical_hash_append_f64_bits(hash, value)
	}
}
