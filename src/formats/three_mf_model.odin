package formats

import "core:math"
import "core:mem"
import "core:strconv"
import "core:strings"
import xml "core:encoding/xml"

import contracts "../contracts"

THREE_MF_CORE_NAMESPACE ::
	"http://schemas.microsoft.com/3dmanufacturing/core/2015/02"
THREE_MF_INVALID_PROPERTY :: u32(0xffff_ffff)

Three_MF_Object_Kind :: enum u8 {
	Invalid,
	Mesh,
	Components,
}

Three_MF_Object_Type :: enum u8 {
	Model,
	Support,
	Solid_Support,
	Surface,
	Other,
}

Three_MF_Property_Group_Kind :: enum u8 {
	Invalid,
	Base_Materials,
	Extension,
}

Three_MF_Resource_Kind :: enum u8 {
	Invalid,
	Object,
	Base_Materials,
	Extension_Property_Group,
}

Three_MF_Transform :: [12]f64

Three_MF_Property_Group :: struct {
	resource_id:     u32,
	stable_id:       contracts.Stable_ID,
	kind:            Three_MF_Property_Group_Kind,
	material_offset: u64,
	material_count:  u32,
}

Three_MF_Base_Material :: struct {
	group_index:  u32,
	stable_id:    contracts.Stable_ID,
	name:         string,
	display_rgba: u32,
}

Three_MF_Metadata :: struct {
	stable_id:    contracts.Stable_ID,
	name:         string,
	namespace_uri: string,
	value:        string,
	value_type:   string,
	preserve:     bool,
}

Three_MF_Extension_Resource :: struct {
	resource_id:          u32,
	property_group_index: u32,
	stable_id:            contracts.Stable_ID,
	namespace_uri:        string,
	qualified_name:       string,
	payload_schema_version: u32,
	payload_hash:         contracts.Content_Hash,
	payload:              []u8,
}

Three_MF_Object :: struct {
	resource_id:        u32,
	stable_id:          contracts.Stable_ID,
	kind:               Three_MF_Object_Kind,
	object_type:        Three_MF_Object_Type,
	vertex_offset:      u64,
	vertex_count:       u32,
	triangle_offset:    u64,
	triangle_count:     u32,
	component_offset:   u64,
	component_count:    u32,
	property_resource:  u32,
	property_index:     u32,
	component_depth:    u32,
	contains_other:     bool,
}

Three_MF_Component :: struct {
	parent_object_index: u32,
	object_index:        u32,
	stable_id:           contracts.Stable_ID,
	transform:           Three_MF_Transform,
}

Three_MF_Build_Item :: struct {
	object_index: u32,
	transform:    Three_MF_Transform,
}

Three_MF_Vertex_SoA :: struct {
	x:          []f64,
	y:          []f64,
	z:          []f64,
	stable_ids: []contracts.Stable_ID,
}

Three_MF_Triangle_SoA :: struct {
	a:                 []u32,
	b:                 []u32,
	c:                 []u32,
	stable_ids:        []contracts.Stable_ID,
	object_indices:    []u32,
	property_resource: []u32,
	property_a:        []u32,
	property_b:        []u32,
	property_c:        []u32,
}

Three_MF_Scene :: struct {
	source:         contracts.Source_Asset,
	source_root_id: contracts.Stable_ID,
	model_part_path: string,
	vertices:       Three_MF_Vertex_SoA,
	triangles:      Three_MF_Triangle_SoA,
	objects:        []Three_MF_Object,
	components:     []Three_MF_Component,
	build_items:    []Three_MF_Build_Item,
	property_groups: []Three_MF_Property_Group,
	base_materials: []Three_MF_Base_Material,
	metadata:       []Three_MF_Metadata,
	extension_resources: []Three_MF_Extension_Resource,
}

Three_MF_Model_Limits :: struct {
	max_objects:    u32,
	max_vertices:   u64,
	max_triangles:  u64,
	max_components: u64,
	max_build_items: u32,
	max_component_depth: u32,
	max_property_groups: u32,
	max_base_materials: u64,
	max_metadata:      u32,
	max_extension_payload_bytes: u64,
}

DEFAULT_THREE_MF_MODEL_LIMITS :: Three_MF_Model_Limits{
	max_objects = 1_000_000,
	max_vertices = 100_000_000,
	max_triangles = 100_000_000,
	max_components = 100_000_000,
	max_build_items = 1_000_000,
	max_component_depth = 256,
	max_property_groups = 1_000_000,
	max_base_materials = 100_000_000,
	max_metadata = 1_000_000,
	max_extension_payload_bytes = 256*1024*1024,
}

Three_MF_Model_Error :: enum u8 {
	None,
	XML_Invalid,
	Root_Invalid,
	Namespace_Unsupported,
	Required_Extension_Unsupported,
	Unit_Invalid,
	Metadata_Invalid,
	Metadata_Duplicate,
	Resources_Invalid,
	Build_Invalid,
	Resource_ID_Invalid,
	Resource_ID_Duplicate,
	Object_Invalid,
	Object_Type_Invalid,
	Mesh_Invalid,
	Vertex_Invalid,
	Triangle_Invalid,
	Component_Invalid,
	Property_Group_Invalid,
	Property_Invalid,
	Reference_Invalid,
	Transform_Invalid,
	Object_Limit,
	Vertex_Limit,
	Triangle_Limit,
	Component_Limit,
	Component_Depth_Limit,
	Property_Group_Limit,
	Property_Limit,
	Extension_Payload_Limit,
	Build_Item_Limit,
	Allocation_Failed,
}

three_mf_model_decode :: proc(
	package_result: Three_MF_Package,
	limits := DEFAULT_THREE_MF_MODEL_LIMITS,
	allocator := context.allocator,
) -> (Three_MF_Scene, Three_MF_Model_Error) {
	document, package_error := three_mf_xml_parse(
		package_result.model_bytes,
		three_mf_model_xml_element_limit(limits),
		allocator,
	)
	if package_error != .None {return {}, .XML_Invalid}
	defer xml.destroy(document)
	if len(document.elements) == 0 ||
	   three_mf_xml_local_name(document.elements[0].ident) != "model" {
		return {}, .Root_Invalid
	}
	if !three_mf_model_namespace_valid(document, 0) {
		return {}, .Namespace_Unsupported
	}
	required_extensions, required_extensions_ok :=
		three_mf_model_attribute(
			document.elements[0],
			"requiredextensions",
		)
	if required_extensions_ok &&
	   len(strings.trim_space(required_extensions)) > 0 {
		return {}, .Required_Extension_Unsupported
	}
	unit_text, unit_ok := three_mf_model_attribute(
		document.elements[0],
		"unit",
	)
	units, units_ok := three_mf_model_units(unit_text, unit_ok)
	if !units_ok {return {}, .Unit_Invalid}
	metadata_count, metadata_error := three_mf_model_validate_metadata(
		document,
		limits.max_metadata,
	)
	if metadata_error != .None {return {}, metadata_error}
	resources_id, resources_count := three_mf_unique_child(
		document,
		0,
		"resources",
	)
	build_id, build_count := three_mf_unique_child(document, 0, "build")
	if resources_count != 1 {return {}, .Resources_Invalid}
	if build_count != 1 {return {}, .Build_Invalid}

	resource_child_count := three_mf_element_child_count(
		document,
		resources_id,
	)
	resource_ids := make([]u32, resource_child_count, allocator)
	resource_kinds := make(
		[]Three_MF_Resource_Kind,
		resource_child_count,
		allocator,
	)
	resource_property_counts := make(
		[]u32,
		resource_child_count,
		allocator,
	)
	if resource_child_count > 0 &&
	   (resource_ids == nil || resource_kinds == nil ||
	    resource_property_counts == nil) {
		return {}, .Allocation_Failed
	}
	defer delete(resource_ids, allocator)
	defer delete(resource_kinds, allocator)
	defer delete(resource_property_counts, allocator)
	resource_id_count := 0
	object_count: u64
	vertex_count: u64
	triangle_count: u64
	component_count: u64
	property_group_count: u64
	base_material_count: u64
	extension_resource_count: u64
	extension_payload_bytes: u64
	saw_object := false
	for value in document.elements[resources_id].value {
		switch child_id in value {
		case string:
		case xml.Element_ID:
			child := document.elements[child_id]
			if child.kind != .Element {continue}
			id_text, id_ok := three_mf_model_attribute(child, "id")
			if !id_ok {return {}, .Resource_ID_Invalid}
			resource_id, parse_ok := three_mf_parse_u32(id_text)
			if !parse_ok || resource_id == 0 ||
			   resource_id >= 0x8000_0000 {
				return {}, .Resource_ID_Invalid
			}
			for previous_id in resource_ids[:resource_id_count] {
				if previous_id == resource_id {
					return {}, .Resource_ID_Duplicate
				}
			}
			resource_ids[resource_id_count] = resource_id
			is_core := three_mf_model_namespace_valid(
				document,
				child_id,
			)
			local_name := three_mf_xml_local_name(child.ident)
			resource_kind: Three_MF_Resource_Kind
			if is_core {
				switch local_name {
				case "object":
					resource_kind = .Object
				case "basematerials":
					resource_kind = .Base_Materials
				case:
					return {}, .Resources_Invalid
				}
			} else {
				namespace_uri, namespace_found :=
					three_mf_xml_namespace_uri(document, child_id)
				if !namespace_found || namespace_uri == "" {
					return {}, .Namespace_Unsupported
				}
				payload_size, payload_size_ok :=
					three_mf_extension_payload_size(
						document,
						child_id,
						limits.max_extension_payload_bytes,
					)
				if !payload_size_ok ||
				   payload_size >
				   	limits.max_extension_payload_bytes ||
				   extension_payload_bytes >
				   	limits.max_extension_payload_bytes-payload_size {
					return {}, .Extension_Payload_Limit
				}
				extension_payload_bytes += payload_size
				extension_resource_count += 1
				resource_kind = .Extension_Property_Group
			}
			resource_kinds[resource_id_count] = resource_kind
			if resource_kind == .Base_Materials {
				local_material_count := three_mf_named_child_count(
					document,
					child_id,
					"base",
				)
				if local_material_count < 1 ||
				   u64(local_material_count) >= 0x8000_0000 {
					return {}, .Property_Group_Invalid
				}
				resource_property_counts[resource_id_count] =
					u32(local_material_count)
				base_material_count += u64(local_material_count)
			} else if resource_kind ==
			          .Extension_Property_Group {
				resource_property_counts[resource_id_count] =
					THREE_MF_INVALID_PROPERTY
			}
			resource_id_count += 1
			if resource_kind != .Object {
				if saw_object {return {}, .Resources_Invalid}
				property_group_count += 1
				continue
			}
			saw_object = true
			object_count += 1
			mesh_id, mesh_count := three_mf_unique_child(
				document,
				child_id,
				"mesh",
			)
			components_id, components_count := three_mf_unique_child(
				document,
				child_id,
				"components",
			)
			if mesh_count+components_count != 1 {
				return {}, .Object_Invalid
			}
			if mesh_count == 1 {
				vertices_id, vertices_count :=
					three_mf_unique_child(
						document,
						mesh_id,
						"vertices",
					)
				triangles_id, triangles_count :=
					three_mf_unique_child(
						document,
						mesh_id,
						"triangles",
					)
				if vertices_count != 1 || triangles_count != 1 {
					return {}, .Mesh_Invalid
				}
				local_vertex_count := three_mf_named_child_count(
					document,
					vertices_id,
					"vertex",
				)
				local_triangle_count := three_mf_named_child_count(
					document,
					triangles_id,
					"triangle",
				)
				if u64(local_vertex_count) >= 0x8000_0000 {
					return {}, .Vertex_Limit
				}
				if u64(local_triangle_count) >= 0x8000_0000 {
					return {}, .Triangle_Limit
				}
				vertex_count += u64(local_vertex_count)
				triangle_count += u64(local_triangle_count)
			} else {
				local_component_count := three_mf_named_child_count(
					document,
					components_id,
					"component",
				)
				if u64(local_component_count) >= 0x8000_0000 {
					return {}, .Component_Limit
				}
				component_count += u64(local_component_count)
			}
		}
	}
	if object_count == 0 || object_count > u64(limits.max_objects) {
		return {}, .Object_Limit
	}
	if vertex_count > limits.max_vertices ||
	   vertex_count > u64(max(u32)) ||
	   vertex_count > u64(max(int)) {
		return {}, .Vertex_Limit
	}
	if triangle_count > limits.max_triangles ||
	   triangle_count > u64(max(int)) {
		return {}, .Triangle_Limit
	}
	if component_count > limits.max_components ||
	   component_count > u64(max(int)) {
		return {}, .Component_Limit
	}
	if property_group_count > u64(limits.max_property_groups) ||
	   property_group_count > u64(max(int)) {
		return {}, .Property_Group_Limit
	}
	if base_material_count > limits.max_base_materials ||
	   base_material_count > u64(max(int)) {
		return {}, .Property_Limit
	}
	if extension_resource_count > u64(limits.max_property_groups) ||
	   extension_resource_count > u64(max(int)) {
		return {}, .Property_Group_Limit
	}
	build_item_count := three_mf_named_child_count(
		document,
		build_id,
		"item",
	)
	if build_item_count == 0 ||
	   u64(build_item_count) > u64(limits.max_build_items) {
		return {}, .Build_Item_Limit
	}

	scene: Three_MF_Scene
	scene.source = package_result.source
	scene.source.units = units
	scene.source_root_id = package_result.source_root_id
	if !three_mf_scene_allocate(
		&scene,
		int(object_count),
		int(vertex_count),
		int(triangle_count),
		int(component_count),
		build_item_count,
		int(property_group_count),
		int(base_material_count),
		metadata_count,
		int(extension_resource_count),
		allocator,
	) {
		three_mf_scene_destroy(&scene, allocator)
		return {}, .Allocation_Failed
	}
	scene.model_part_path = strings.clone(
		package_result.model_path,
		allocator,
	)
	if package_result.model_path != "" && scene.model_part_path == "" {
		three_mf_scene_destroy(&scene, allocator)
		return {}, .Allocation_Failed
	}
	metadata_decode_error := three_mf_decode_metadata(
		document,
		&scene,
		allocator,
	)
	if metadata_decode_error != .None {
		three_mf_scene_destroy(&scene, allocator)
		return {}, metadata_decode_error
	}
	object_write := 0
	vertex_write := 0
	triangle_write := 0
	component_write := 0
	property_group_write := 0
	base_material_write := 0
	extension_write := 0
	for value in document.elements[resources_id].value {
		switch child_id in value {
		case string:
		case xml.Element_ID:
			child := document.elements[child_id]
			if child.kind != .Element {
				continue
			}
			id_text, _ := three_mf_model_attribute(child, "id")
			resource_id, _ := three_mf_parse_u32(id_text)
			resource_index, _ := three_mf_resource_index(
				resource_ids[:resource_id_count],
				resource_id,
			)
			if resource_kinds[resource_index] != .Object {
				property_error := three_mf_decode_property_group(
					document,
					child_id,
					resource_kinds[resource_index],
					&scene,
					&property_group_write,
					&base_material_write,
					&extension_write,
					limits.max_extension_payload_bytes,
					allocator,
				)
				if property_error != .None {
					three_mf_scene_destroy(&scene, allocator)
					return {}, property_error
				}
				continue
			}
			object_error := three_mf_decode_object(
				document,
				child_id,
				resource_ids[:resource_id_count],
				resource_kinds[:resource_id_count],
				resource_property_counts[:resource_id_count],
				&scene,
				&object_write,
				&vertex_write,
				&triangle_write,
				&component_write,
				limits.max_component_depth,
			)
			if object_error != .None {
				three_mf_scene_destroy(&scene, allocator)
				return {}, object_error
			}
		}
	}
	build_error := three_mf_decode_build(
		document,
		build_id,
		&scene,
	)
	if build_error != .None {
		three_mf_scene_destroy(&scene, allocator)
		return {}, build_error
	}
	return scene, .None
}

three_mf_model_xml_element_limit :: proc(
	limits: Three_MF_Model_Limits,
) -> u32 {
	result: u64 = 16
	values := [8]u64{
		limits.max_vertices,
		limits.max_triangles,
		limits.max_components,
		limits.max_base_materials,
		u64(limits.max_objects),
		u64(limits.max_build_items),
		u64(limits.max_property_groups),
		u64(limits.max_metadata),
	}
	for value in values {
		if result >= u64(max(u32)) ||
		   value > u64(max(u32))-result {
			return max(u32)
		}
		result += value
	}
	return u32(result)
}

three_mf_model_validate_metadata :: proc(
	document: ^xml.Document,
	max_metadata: u32,
) -> (int, Three_MF_Model_Error) {
	metadata_names: [dynamic]string
	defer delete(metadata_names)
	saw_resources := false
	saw_build := false
	for value in document.elements[0].value {
		switch child_id in value {
		case string:
		case xml.Element_ID:
			child := document.elements[child_id]
			if child.kind != .Element {continue}
			if !three_mf_model_namespace_valid(document, child_id) {
				continue
			}
			switch three_mf_xml_local_name(child.ident) {
			case "metadata":
				if saw_resources || saw_build {
					return 0, .Metadata_Invalid
				}
				if len(metadata_names) >= int(max_metadata) {
					return 0, .Metadata_Invalid
				}
				name, name_present :=
					three_mf_model_attribute(child, "name")
				if !name_present ||
				   !three_mf_metadata_name_valid(
						document.elements[0],
						name,
					) {
					return 0, .Metadata_Invalid
				}
				for previous_name in metadata_names {
					if previous_name == name {
						return 0, .Metadata_Duplicate
					}
				}
				append(&metadata_names, name)
				preserve, preserve_present :=
					three_mf_model_attribute(child, "preserve")
				if preserve_present &&
				   preserve != "0" && preserve != "1" &&
				   preserve != "false" && preserve != "true" {
					return 0, .Metadata_Invalid
				}
				value_type, type_present :=
					three_mf_model_attribute(child, "type")
				if type_present &&
				   len(strings.trim_space(value_type)) == 0 {
					return 0, .Metadata_Invalid
				}
				for child_value in child.value {
					switch nested_id in child_value {
					case string:
					case xml.Element_ID:
						if document.elements[nested_id].kind ==
						   .Element {
							return 0, .Metadata_Invalid
						}
					}
				}
			case "resources":
				if saw_resources || saw_build {
					return 0, .Resources_Invalid
				}
				saw_resources = true
			case "build":
				if !saw_resources || saw_build {
					return 0, .Build_Invalid
				}
				saw_build = true
			case:
				return 0, .Root_Invalid
			}
		}
	}
	return len(metadata_names), .None
}

three_mf_metadata_name_valid :: proc(
	model: xml.Element,
	name: string,
) -> bool {
	if name == "" {return false}
	colon_index := -1
	for value, index in name {
		if value != ':' {continue}
		if colon_index >= 0 {return false}
		colon_index = index
	}
	if colon_index < 0 {return true}
	if colon_index <= 0 || colon_index+1 >= len(name) {return false}
	prefix := name[:colon_index]
	for attribute in model.attribs {
		if len(attribute.key) == len(prefix)+6 &&
		   attribute.key[:6] == "xmlns:" &&
		   attribute.key[6:] == prefix {
			return attribute.val != "" &&
				attribute.val != THREE_MF_CORE_NAMESPACE
		}
	}
	return false
}

three_mf_metadata_namespace_uri :: proc(
	model: xml.Element,
	name: string,
) -> string {
	for value, index in name {
		if value != ':' {continue}
		prefix := name[:index]
		for attribute in model.attribs {
			if len(attribute.key) == len(prefix)+6 &&
			   attribute.key[:6] == "xmlns:" &&
			   attribute.key[6:] == prefix {
				return attribute.val
			}
		}
		break
	}
	return ""
}

three_mf_decode_metadata :: proc(
	document: ^xml.Document,
	scene: ^Three_MF_Scene,
	allocator: mem.Allocator,
) -> Three_MF_Model_Error {
	write_index := 0
	for value in document.elements[0].value {
		switch child_id in value {
		case string:
		case xml.Element_ID:
			child := document.elements[child_id]
			if child.kind != .Element ||
			   !three_mf_model_namespace_valid(document, child_id) ||
			   three_mf_xml_local_name(child.ident) != "metadata" {
				continue
			}
			if write_index >= len(scene.metadata) {
				return .Metadata_Invalid
			}
			name, _ := three_mf_model_attribute(child, "name")
			namespace_uri := three_mf_metadata_namespace_uri(
				document.elements[0],
				name,
			)
			value_type, type_present :=
				three_mf_model_attribute(child, "type")
			preserve_text, preserve_present :=
				three_mf_model_attribute(child, "preserve")
			metadata_value, value_ok := three_mf_metadata_value(
				child,
				allocator,
			)
			if !value_ok {return .Allocation_Failed}
			cloned_name := strings.clone(name, allocator)
			if cloned_name == "" {
				delete(metadata_value, allocator)
				return .Allocation_Failed
			}
			cloned_namespace := strings.clone(namespace_uri, allocator)
			if namespace_uri != "" && cloned_namespace == "" {
				delete(metadata_value, allocator)
				delete(cloned_name, allocator)
				return .Allocation_Failed
			}
			cloned_type := strings.clone(value_type, allocator)
			if type_present && cloned_type == "" {
				delete(metadata_value, allocator)
				delete(cloned_name, allocator)
				delete(cloned_namespace, allocator)
				return .Allocation_Failed
			}
			scene.metadata[write_index] = {
				stable_id = contracts.stable_id_child(
					scene.source_root_id,
					.Metadata,
					u64(write_index),
				),
				name = cloned_name,
				namespace_uri = cloned_namespace,
				value = metadata_value,
				value_type = cloned_type,
				preserve = preserve_present &&
					(preserve_text == "1" || preserve_text == "true"),
			}
			write_index += 1
		}
	}
	if write_index != len(scene.metadata) {return .Metadata_Invalid}
	return .None
}

three_mf_metadata_value :: proc(
	element: xml.Element,
	allocator: mem.Allocator,
) -> (string, bool) {
	byte_count: u64
	for value in element.value {
		switch text in value {
		case string:
			if byte_count > u64(max(int))-u64(len(text)) {
				return "", false
			}
			byte_count += u64(len(text))
		case xml.Element_ID:
		}
	}
	if byte_count == 0 {return "", true}
	bytes := make([]u8, int(byte_count), allocator)
	if bytes == nil {return "", false}
	cursor := 0
	for value in element.value {
		switch text in value {
		case string:
			cursor += copy(bytes[cursor:], transmute([]u8)text)
		case xml.Element_ID:
		}
	}
	return string(bytes), true
}

three_mf_model_namespace_valid :: proc(
	document: ^xml.Document,
	element_id: xml.Element_ID,
) -> bool {
	return three_mf_xml_namespace_matches(
		document,
		element_id,
		THREE_MF_CORE_NAMESPACE,
	)
}

three_mf_model_attribute :: proc(
	element: xml.Element,
	name: string,
) -> (string, bool) {
	for attribute in element.attribs {
		if attribute.key == name {return attribute.val, true}
	}
	return "", false
}

three_mf_model_units :: proc(
	text: string,
	present: bool,
) -> (contracts.Source_Units, bool) {
	if !present || text == "millimeter" {
		return .Millimetres, true
	}
	switch text {
	case "micron":
		return .Micrometres, true
	case "centimeter":
		return .Centimetres, true
	case "meter":
		return .Metres, true
	case "inch":
		return .Inches, true
	case "foot":
		return .Feet, true
	}
	return .Unspecified, false
}

three_mf_unique_child :: proc(
	document: ^xml.Document,
	parent_id: xml.Element_ID,
	name: string,
) -> (xml.Element_ID, int) {
	result: xml.Element_ID
	count := 0
	for value in document.elements[parent_id].value {
		switch child_id in value {
		case string:
		case xml.Element_ID:
			child := document.elements[child_id]
			if child.kind == .Element &&
			   three_mf_model_namespace_valid(document, child_id) &&
			   three_mf_xml_local_name(child.ident) == name {
				result = child_id
				count += 1
			}
		}
	}
	return result, count
}

three_mf_element_child_count :: proc(
	document: ^xml.Document,
	parent_id: xml.Element_ID,
) -> int {
	count := 0
	for value in document.elements[parent_id].value {
		switch child_id in value {
		case string:
		case xml.Element_ID:
			if document.elements[child_id].kind == .Element {count += 1}
		}
	}
	return count
}

three_mf_named_child_count :: proc(
	document: ^xml.Document,
	parent_id: xml.Element_ID,
	name: string,
) -> int {
	count := 0
	for value in document.elements[parent_id].value {
		switch child_id in value {
		case string:
		case xml.Element_ID:
			child := document.elements[child_id]
			if child.kind == .Element &&
			   three_mf_model_namespace_valid(document, child_id) &&
			   three_mf_xml_local_name(child.ident) == name {
				count += 1
			}
		}
	}
	return count
}

three_mf_parse_u32 :: proc(text: string) -> (u32, bool) {
	value_text := strings.trim_space(text)
	if len(value_text) == 0 {return 0, false}
	if value_text[0] == '+' {
		value_text = value_text[1:]
		if len(value_text) == 0 {return 0, false}
	}
	value: u64
	for digit in value_text {
		if digit < '0' || digit > '9' {return 0, false}
		digit_value := u64(digit-'0')
		if value > (u64(0x7fff_ffff)-digit_value)/10 {
			return 0, false
		}
		value = value*10+digit_value
	}
	return u32(value), true
}

three_mf_parse_f64 :: proc(text: string) -> (f64, bool) {
	value_text := strings.trim_space(text)
	if len(value_text) == 0 {return 0, false}
	cursor := 0
	if value_text[cursor] == '+' || value_text[cursor] == '-' {
		cursor += 1
		if cursor == len(value_text) {return 0, false}
	}
	digit_count := 0
	for cursor < len(value_text) &&
	    value_text[cursor] >= '0' &&
	    value_text[cursor] <= '9' {
		cursor += 1
		digit_count += 1
	}
	if cursor < len(value_text) && value_text[cursor] == '.' {
		cursor += 1
		for cursor < len(value_text) &&
		    value_text[cursor] >= '0' &&
		    value_text[cursor] <= '9' {
			cursor += 1
			digit_count += 1
		}
	}
	if digit_count == 0 {return 0, false}
	if cursor < len(value_text) &&
	   (value_text[cursor] == 'e' || value_text[cursor] == 'E') {
		cursor += 1
		if cursor < len(value_text) &&
		   (value_text[cursor] == '+' || value_text[cursor] == '-') {
			cursor += 1
		}
		exponent_start := cursor
		for cursor < len(value_text) &&
		    value_text[cursor] >= '0' &&
		    value_text[cursor] <= '9' {
			cursor += 1
		}
		if cursor == exponent_start {return 0, false}
	}
	if cursor != len(value_text) {return 0, false}
	value, ok := strconv.parse_f64(value_text)
	if !ok || math.is_nan(value) || math.is_inf(value) {
		return 0, false
	}
	if value == 0 {value = 0}
	return value, true
}

three_mf_identity_transform :: proc() -> Three_MF_Transform {
	return {1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0}
}

three_mf_parse_transform :: proc(
	text: string,
	present: bool,
) -> (Three_MF_Transform, bool) {
	if !present {return three_mf_identity_transform(), true}
	result: Three_MF_Transform
	cursor := 0
	for field_index in 0..<12 {
		for cursor < len(text) && three_mf_transform_space(text[cursor]) {
			cursor += 1
		}
		field_start := cursor
		for cursor < len(text) &&
		    !three_mf_transform_space(text[cursor]) {
			cursor += 1
		}
		if field_start == cursor {return {}, false}
		value, ok := three_mf_parse_f64(text[field_start:cursor])
		if !ok {return {}, false}
		result[field_index] = value
	}
	for cursor < len(text) && three_mf_transform_space(text[cursor]) {
		cursor += 1
	}
	if cursor != len(text) {return {}, false}
	return result, true
}

three_mf_transform_space :: proc(value: u8) -> bool {
	return value == ' ' || value == '\t' ||
		value == '\r' || value == '\n'
}

three_mf_scene_allocate :: proc(
	scene: ^Three_MF_Scene,
	object_count: int,
	vertex_count: int,
	triangle_count: int,
	component_count: int,
	build_item_count: int,
	property_group_count: int,
	base_material_count: int,
	metadata_count: int,
	extension_resource_count: int,
	allocator: mem.Allocator,
) -> bool {
	scene.objects = make([]Three_MF_Object, object_count, allocator)
	scene.vertices.x = make([]f64, vertex_count, allocator)
	scene.vertices.y = make([]f64, vertex_count, allocator)
	scene.vertices.z = make([]f64, vertex_count, allocator)
	scene.vertices.stable_ids = make(
		[]contracts.Stable_ID,
		vertex_count,
		allocator,
	)
	scene.triangles.a = make([]u32, triangle_count, allocator)
	scene.triangles.b = make([]u32, triangle_count, allocator)
	scene.triangles.c = make([]u32, triangle_count, allocator)
	scene.triangles.stable_ids = make(
		[]contracts.Stable_ID,
		triangle_count,
		allocator,
	)
	scene.triangles.object_indices = make(
		[]u32,
		triangle_count,
		allocator,
	)
	scene.triangles.property_resource = make(
		[]u32,
		triangle_count,
		allocator,
	)
	scene.triangles.property_a = make([]u32, triangle_count, allocator)
	scene.triangles.property_b = make([]u32, triangle_count, allocator)
	scene.triangles.property_c = make([]u32, triangle_count, allocator)
	scene.components = make(
		[]Three_MF_Component,
		component_count,
		allocator,
	)
	scene.build_items = make(
		[]Three_MF_Build_Item,
		build_item_count,
		allocator,
	)
	scene.property_groups = make(
		[]Three_MF_Property_Group,
		property_group_count,
		allocator,
	)
	scene.base_materials = make(
		[]Three_MF_Base_Material,
		base_material_count,
		allocator,
	)
	scene.metadata = make(
		[]Three_MF_Metadata,
		metadata_count,
		allocator,
	)
	scene.extension_resources = make(
		[]Three_MF_Extension_Resource,
		extension_resource_count,
		allocator,
	)
	if object_count > 0 && scene.objects == nil {return false}
	if vertex_count > 0 &&
	   (scene.vertices.x == nil || scene.vertices.y == nil ||
	    scene.vertices.z == nil || scene.vertices.stable_ids == nil) {
		return false
	}
	if triangle_count > 0 &&
	   (scene.triangles.a == nil || scene.triangles.b == nil ||
	    scene.triangles.c == nil || scene.triangles.stable_ids == nil ||
	    scene.triangles.object_indices == nil ||
	    scene.triangles.property_resource == nil ||
	    scene.triangles.property_a == nil ||
	    scene.triangles.property_b == nil ||
	    scene.triangles.property_c == nil) {
		return false
	}
	if component_count > 0 && scene.components == nil {return false}
	if build_item_count > 0 && scene.build_items == nil {return false}
	if property_group_count > 0 && scene.property_groups == nil {
		return false
	}
	if base_material_count > 0 && scene.base_materials == nil {
		return false
	}
	if metadata_count > 0 && scene.metadata == nil {return false}
	if extension_resource_count > 0 &&
	   scene.extension_resources == nil {
		return false
	}
	return true
}

three_mf_resource_index :: proc(
	resource_ids: []u32,
	resource_id: u32,
) -> (int, bool) {
	for candidate, index in resource_ids {
		if candidate == resource_id {return index, true}
	}
	return 0, false
}

three_mf_object_index :: proc(
	scene: ^Three_MF_Scene,
	resource_id: u32,
	count: int,
) -> (int, bool) {
	for object, object_index in scene.objects[:count] {
		if object.resource_id == resource_id {return object_index, true}
	}
	return 0, false
}

three_mf_object_type :: proc(
	text: string,
	present: bool,
) -> (Three_MF_Object_Type, bool) {
	if !present || text == "model" {return .Model, true}
	switch text {
	case "support":
		return .Support, true
	case "solidsupport":
		return .Solid_Support, true
	case "surface":
		return .Surface, true
	case "other":
		return .Other, true
	}
	return .Model, false
}

three_mf_decode_property_group :: proc(
	document: ^xml.Document,
	element_id: xml.Element_ID,
	resource_kind: Three_MF_Resource_Kind,
	scene: ^Three_MF_Scene,
	group_write: ^int,
	material_write: ^int,
	extension_write: ^int,
	max_extension_payload_bytes: u64,
	allocator: mem.Allocator,
) -> Three_MF_Model_Error {
	element := document.elements[element_id]
	id_text, id_present := three_mf_model_attribute(element, "id")
	resource_id, id_ok := three_mf_parse_u32(id_text)
	if !id_present || !id_ok || resource_id == 0 {
		return .Resource_ID_Invalid
	}
	group_index := group_write^
	group := &scene.property_groups[group_index]
	group.resource_id = resource_id
	group.stable_id = contracts.stable_id_child(
		scene.source_root_id,
		.Property_Group,
		u64(group_index),
	)
	group.material_offset = u64(material_write^)
	switch resource_kind {
	case .Base_Materials:
		group.kind = .Base_Materials
		local_material_index := 0
		for value in element.value {
			switch child_id in value {
			case string:
			case xml.Element_ID:
				child := document.elements[child_id]
				if child.kind != .Element {continue}
				if !three_mf_model_namespace_valid(
					document,
					child_id,
				) ||
				   three_mf_xml_local_name(child.ident) != "base" {
					return .Property_Group_Invalid
				}
				name, name_present :=
					three_mf_model_attribute(child, "name")
				color_text, color_present :=
					three_mf_model_attribute(child, "displaycolor")
				display_rgba, color_ok :=
					three_mf_display_color(color_text)
				if !name_present || !color_present || !color_ok {
					return .Property_Invalid
				}
				cloned_name := strings.clone(name, allocator)
				if len(name) > 0 && cloned_name == "" {
					return .Allocation_Failed
				}
				write_index := material_write^
				scene.base_materials[write_index] = {
					group_index = u32(group_index),
					stable_id = contracts.stable_id_child(
						group.stable_id,
						.Property,
						u64(local_material_index),
					),
					name = cloned_name,
					display_rgba = display_rgba,
				}
				material_write^ += 1
				local_material_index += 1
			}
		}
		group.material_count = u32(local_material_index)
		if group.material_count == 0 {
			return .Property_Group_Invalid
		}
	case .Extension_Property_Group:
		group.kind = .Extension
		namespace_uri, namespace_found :=
			three_mf_xml_namespace_uri(document, element_id)
		if !namespace_found || namespace_uri == "" {
			return .Namespace_Unsupported
		}
		cloned_namespace := strings.clone(namespace_uri, allocator)
		cloned_name := strings.clone(element.ident, allocator)
		if cloned_namespace == "" || cloned_name == "" {
			delete(cloned_namespace, allocator)
			delete(cloned_name, allocator)
			return .Allocation_Failed
		}
		payload, payload_hash, payload_error :=
			three_mf_extension_payload_encode(
				document,
				element_id,
				max_extension_payload_bytes,
				allocator,
			)
		if payload_error != .None {
			delete(cloned_namespace, allocator)
			delete(cloned_name, allocator)
			if payload_error == .Limit {
				return .Extension_Payload_Limit
			}
			return .Allocation_Failed
		}
		extension_index := extension_write^
		scene.extension_resources[extension_index] = {
			resource_id = resource_id,
			property_group_index = u32(group_index),
			stable_id = contracts.stable_id_child(
				group.stable_id,
				.Extension_Resource,
				0,
			),
			namespace_uri = cloned_namespace,
			qualified_name = cloned_name,
			payload_schema_version =
				THREE_MF_EXTENSION_PAYLOAD_SCHEMA_VERSION,
			payload_hash = payload_hash,
			payload = payload,
		}
		extension_write^ += 1
	case .Object, .Invalid:
		return .Property_Group_Invalid
	}
	group_write^ += 1
	return .None
}

three_mf_display_color :: proc(text: string) -> (u32, bool) {
	if len(text) != 7 && len(text) != 9 {return 0, false}
	if text[0] != '#' {return 0, false}
	result: u32
	for cursor in 1..<len(text) {
		value, ok := three_mf_hex_digit(text[cursor])
		if !ok {return 0, false}
		result = result<<4 | u32(value)
	}
	if len(text) == 7 {result = result<<8 | 0xff}
	return result, true
}

three_mf_hex_digit :: proc(value: u8) -> (u8, bool) {
	switch {
	case value >= '0' && value <= '9':
		return value-'0', true
	case value >= 'a' && value <= 'f':
		return value-'a'+10, true
	case value >= 'A' && value <= 'F':
		return value-'A'+10, true
	}
	return 0, false
}

three_mf_property_pair :: proc(
	element: xml.Element,
	resource_ids: []u32,
	resource_kinds: []Three_MF_Resource_Kind,
	resource_property_counts: []u32,
	before_resource_index: int,
) -> (u32, u32, bool, bool) {
	resource_text, resource_present :=
		three_mf_model_attribute(element, "pid")
	index_text, index_present :=
		three_mf_model_attribute(element, "pindex")
	if index_present && !resource_present {
		return 0, 0, false, false
	}
	if !resource_present {
		return THREE_MF_INVALID_PROPERTY,
			THREE_MF_INVALID_PROPERTY,
			false,
			true
	}
	resource, resource_ok := three_mf_parse_u32(resource_text)
	resource_index, resource_found :=
		three_mf_resource_index(resource_ids, resource)
	if !resource_ok || resource == 0 || !resource_found ||
	   resource_index >= before_resource_index ||
	   resource_kinds[resource_index] == .Object ||
	   resource_kinds[resource_index] == .Invalid {
		return 0, 0, false, false
	}
	index := THREE_MF_INVALID_PROPERTY
	if index_present {
		index_ok: bool
		index, index_ok = three_mf_parse_u32(index_text)
		if !index_ok {return 0, 0, false, false}
		property_count := resource_property_counts[resource_index]
		if property_count != THREE_MF_INVALID_PROPERTY &&
		   index >= property_count {
			return 0, 0, false, false
		}
	}
	return resource, index, true, true
}

three_mf_decode_object :: proc(
	document: ^xml.Document,
	object_element_id: xml.Element_ID,
	resource_ids: []u32,
	resource_kinds: []Three_MF_Resource_Kind,
	resource_property_counts: []u32,
	scene: ^Three_MF_Scene,
	object_write: ^int,
	vertex_write: ^int,
	triangle_write: ^int,
	component_write: ^int,
	max_component_depth: u32,
) -> Three_MF_Model_Error {
	element := document.elements[object_element_id]
	id_text, id_present := three_mf_model_attribute(element, "id")
	resource_id, id_ok := three_mf_parse_u32(id_text)
	if !id_present || !id_ok || resource_id == 0 {
		return .Resource_ID_Invalid
	}
	resource_position, resource_found :=
		three_mf_resource_index(resource_ids, resource_id)
	if !resource_found {return .Reference_Invalid}
	type_text, type_present :=
		three_mf_model_attribute(element, "type")
	object_type, type_ok := three_mf_object_type(type_text, type_present)
	if !type_ok {return .Object_Type_Invalid}
	property_resource, property_index, property_present, property_ok :=
		three_mf_property_pair(
			element,
			resource_ids,
			resource_kinds,
			resource_property_counts,
			resource_position,
		)
	if !property_ok {return .Object_Invalid}

	mesh_id, mesh_count := three_mf_unique_child(
		document,
		object_element_id,
		"mesh",
	)
	components_id, components_count := three_mf_unique_child(
		document,
		object_element_id,
		"components",
	)
	if mesh_count+components_count != 1 {return .Object_Invalid}
	object_index := object_write^
	object := &scene.objects[object_index]
	object.resource_id = resource_id
	object.stable_id = contracts.stable_id_child(
		scene.source_root_id,
		.Object,
		u64(object_index),
	)
	object.object_type = object_type
	object.vertex_offset = u64(vertex_write^)
	object.triangle_offset = u64(triangle_write^)
	object.component_offset = u64(component_write^)
	object.property_resource = property_resource
	object.property_index = property_index

	if mesh_count == 1 {
		object.kind = .Mesh
		error := three_mf_decode_mesh(
			document,
			mesh_id,
			resource_ids,
			resource_kinds,
			resource_property_counts,
			resource_position,
			object_index,
			property_present,
			scene,
			vertex_write,
			triangle_write,
		)
		if error != .None {return error}
		object.vertex_count = u32(vertex_write^-int(object.vertex_offset))
		object.triangle_count = u32(
			triangle_write^-int(object.triangle_offset),
		)
		object.contains_other = object.object_type == .Other
	} else {
		if property_present {return .Object_Invalid}
		object.kind = .Components
		error := three_mf_decode_components(
			document,
			components_id,
			object_index,
			scene,
			object_write^,
			component_write,
			max_component_depth,
		)
		if error != .None {return error}
		object.component_count = u32(
			component_write^-int(object.component_offset),
		)
	}
	object_write^ += 1
	return .None
}

three_mf_decode_mesh :: proc(
	document: ^xml.Document,
	mesh_id: xml.Element_ID,
	resource_ids: []u32,
	resource_kinds: []Three_MF_Resource_Kind,
	resource_property_counts: []u32,
	resource_position: int,
	object_index: int,
	object_property_present: bool,
	scene: ^Three_MF_Scene,
	vertex_write: ^int,
	triangle_write: ^int,
) -> Three_MF_Model_Error {
	for value in document.elements[mesh_id].value {
		switch child_id in value {
		case string:
		case xml.Element_ID:
			child := document.elements[child_id]
			if child.kind != .Element ||
			   !three_mf_model_namespace_valid(document, child_id) {
				continue
			}
			name := three_mf_xml_local_name(child.ident)
			if name != "vertices" && name != "triangles" {
				return .Mesh_Invalid
			}
		}
	}
	vertices_id, vertices_count :=
		three_mf_unique_child(document, mesh_id, "vertices")
	triangles_id, triangles_count :=
		three_mf_unique_child(document, mesh_id, "triangles")
	if vertices_count != 1 || triangles_count != 1 {
		return .Mesh_Invalid
	}
	local_vertex_count := three_mf_named_child_count(
		document,
		vertices_id,
		"vertex",
	)
	local_triangle_count := three_mf_named_child_count(
		document,
		triangles_id,
		"triangle",
	)
	if local_vertex_count < 3 || local_triangle_count < 1 {
		return .Mesh_Invalid
	}
	if scene.objects[object_index].object_type == .Model &&
	   local_triangle_count < 4 {
		return .Mesh_Invalid
	}
	vertex_offset := vertex_write^
	local_vertex_index := 0
	for value in document.elements[vertices_id].value {
		switch child_id in value {
		case string:
		case xml.Element_ID:
			child := document.elements[child_id]
			if child.kind != .Element {continue}
			if !three_mf_model_namespace_valid(document, child_id) {
				return .Vertex_Invalid
			}
			if three_mf_xml_local_name(child.ident) != "vertex" {
				return .Vertex_Invalid
			}
			x_text, x_present := three_mf_model_attribute(child, "x")
			y_text, y_present := three_mf_model_attribute(child, "y")
			z_text, z_present := three_mf_model_attribute(child, "z")
			x, x_ok := three_mf_parse_f64(x_text)
			y, y_ok := three_mf_parse_f64(y_text)
			z, z_ok := three_mf_parse_f64(z_text)
			if !x_present || !y_present || !z_present ||
			   !x_ok || !y_ok || !z_ok {
				return .Vertex_Invalid
			}
			write_index := vertex_write^
			scene.vertices.x[write_index] = x
			scene.vertices.y[write_index] = y
			scene.vertices.z[write_index] = z
			scene.vertices.stable_ids[write_index] =
				contracts.stable_id_child(
					scene.objects[object_index].stable_id,
					.Vertex,
					u64(local_vertex_index),
				)
			vertex_write^ += 1
			local_vertex_index += 1
		}
	}

	local_triangle_index := 0
	for value in document.elements[triangles_id].value {
		switch child_id in value {
		case string:
		case xml.Element_ID:
			child := document.elements[child_id]
			if child.kind != .Element {continue}
			if !three_mf_model_namespace_valid(document, child_id) {
				return .Triangle_Invalid
			}
			if three_mf_xml_local_name(child.ident) != "triangle" {
				return .Triangle_Invalid
			}
			a_text, a_present := three_mf_model_attribute(child, "v1")
			b_text, b_present := three_mf_model_attribute(child, "v2")
			c_text, c_present := three_mf_model_attribute(child, "v3")
			a, a_ok := three_mf_parse_u32(a_text)
			b, b_ok := three_mf_parse_u32(b_text)
			c, c_ok := three_mf_parse_u32(c_text)
			if !a_present || !b_present || !c_present ||
			   !a_ok || !b_ok || !c_ok ||
			   a == b || b == c || c == a ||
			   u64(a) >= u64(local_vertex_count) ||
			   u64(b) >= u64(local_vertex_count) ||
			   u64(c) >= u64(local_vertex_count) {
				return .Triangle_Invalid
			}
			property_resource, property_a, property_b, property_c,
			property_assigned, property_ok := three_mf_triangle_properties(
				child,
				resource_ids,
				resource_kinds,
				resource_property_counts,
				resource_position,
				scene.objects[object_index].property_resource,
				scene.objects[object_index].property_index,
			)
			if !property_ok ||
			   (property_assigned &&
			    (!object_property_present ||
			     scene.objects[object_index].property_index ==
			     	THREE_MF_INVALID_PROPERTY)) {
				return .Triangle_Invalid
			}
			write_index := triangle_write^
			scene.triangles.a[write_index] = u32(vertex_offset)+a
			scene.triangles.b[write_index] = u32(vertex_offset)+b
			scene.triangles.c[write_index] = u32(vertex_offset)+c
			scene.triangles.stable_ids[write_index] =
				contracts.stable_id_child(
					scene.objects[object_index].stable_id,
					.Triangle,
					u64(local_triangle_index),
				)
			scene.triangles.object_indices[write_index] =
				u32(object_index)
			scene.triangles.property_resource[write_index] =
				property_resource
			scene.triangles.property_a[write_index] = property_a
			scene.triangles.property_b[write_index] = property_b
			scene.triangles.property_c[write_index] = property_c
			triangle_write^ += 1
			local_triangle_index += 1
		}
	}
	return .None
}

three_mf_triangle_properties :: proc(
	element: xml.Element,
	resource_ids: []u32,
	resource_kinds: []Three_MF_Resource_Kind,
	resource_property_counts: []u32,
	before_resource_index: int,
	object_resource: u32,
	object_index: u32,
) -> (
	resource: u32,
	a: u32,
	b: u32,
	c: u32,
	assigned: bool,
	ok: bool,
) {
	resource = object_resource
	a = object_index
	b = object_index
	c = object_index
	resource_text, resource_present :=
		three_mf_model_attribute(element, "pid")
	a_text, a_present := three_mf_model_attribute(element, "p1")
	b_text, b_present := three_mf_model_attribute(element, "p2")
	c_text, c_present := three_mf_model_attribute(element, "p3")
	assigned = resource_present || a_present || b_present || c_present
	if resource_present {
		resource, ok = three_mf_parse_u32(resource_text)
		if !ok || resource == 0 {
			return 0, 0, 0, 0, assigned, false
		}
	}
	if resource == THREE_MF_INVALID_PROPERTY {
		if assigned {return 0, 0, 0, 0, assigned, false}
		return resource, a, b, c, assigned, true
	}
	if a == THREE_MF_INVALID_PROPERTY && !assigned {
		return THREE_MF_INVALID_PROPERTY,
			THREE_MF_INVALID_PROPERTY,
			THREE_MF_INVALID_PROPERTY,
			THREE_MF_INVALID_PROPERTY,
			false,
			true
	}
	resource_position, resource_found := three_mf_resource_index(
		resource_ids,
		resource,
	)
	if !resource_found || resource_position >= before_resource_index ||
	   resource_kinds[resource_position] == .Object ||
	   resource_kinds[resource_position] == .Invalid {
		return 0, 0, 0, 0, assigned, false
	}
	if a_present {
		a, ok = three_mf_parse_u32(a_text)
		if !ok {return 0, 0, 0, 0, assigned, false}
	}
	if a == THREE_MF_INVALID_PROPERTY {
		return 0, 0, 0, 0, assigned, false
	}
	b = a
	c = a
	if b_present {
		b, ok = three_mf_parse_u32(b_text)
		if !ok {return 0, 0, 0, 0, assigned, false}
	}
	if c_present {
		c, ok = three_mf_parse_u32(c_text)
		if !ok {return 0, 0, 0, 0, assigned, false}
	}
	property_count := resource_property_counts[resource_position]
	if property_count != THREE_MF_INVALID_PROPERTY &&
	   (a >= property_count || b >= property_count ||
	    c >= property_count) {
		return 0, 0, 0, 0, assigned, false
	}
	if resource_kinds[resource_position] == .Base_Materials &&
	   (a != b || b != c) {
		return 0, 0, 0, 0, assigned, false
	}
	return resource, a, b, c, assigned, true
}

three_mf_decode_components :: proc(
	document: ^xml.Document,
	components_id: xml.Element_ID,
	parent_object_index: int,
	scene: ^Three_MF_Scene,
	defined_object_count: int,
	component_write: ^int,
	max_component_depth: u32,
) -> Three_MF_Model_Error {
	component_count := three_mf_named_child_count(
		document,
		components_id,
		"component",
	)
	if component_count < 1 {return .Component_Invalid}
	contains_other := false
	component_depth: u32
	local_component_index := 0
	for value in document.elements[components_id].value {
		switch child_id in value {
		case string:
		case xml.Element_ID:
			child := document.elements[child_id]
			if child.kind != .Element {continue}
			if !three_mf_model_namespace_valid(document, child_id) {
				return .Component_Invalid
			}
			if three_mf_xml_local_name(child.ident) != "component" {
				return .Component_Invalid
			}
			reference_text, reference_present :=
				three_mf_model_attribute(child, "objectid")
			reference, reference_ok :=
				three_mf_parse_u32(reference_text)
			reference_index, reference_found := three_mf_object_index(
				scene,
				reference,
				defined_object_count,
			)
			if !reference_present || !reference_ok || reference == 0 ||
			   !reference_found {
				return .Reference_Invalid
			}
			transform_text, transform_present :=
				three_mf_model_attribute(child, "transform")
			transform, transform_ok := three_mf_parse_transform(
				transform_text,
				transform_present,
			)
			if !transform_ok {return .Transform_Invalid}
			write_index := component_write^
			scene.components[write_index] = {
				parent_object_index = u32(parent_object_index),
				object_index = u32(reference_index),
				stable_id = contracts.stable_id_child(
					scene.objects[parent_object_index].stable_id,
					.Component,
					u64(local_component_index),
				),
				transform = transform,
			}
			if scene.objects[reference_index].contains_other {
				contains_other = true
			}
			child_depth := scene.objects[reference_index].component_depth
			if child_depth >= max_component_depth {
				return .Component_Depth_Limit
			}
			component_depth = max(component_depth, child_depth+1)
			component_write^ += 1
			local_component_index += 1
		}
	}
	scene.objects[parent_object_index].contains_other = contains_other
	scene.objects[parent_object_index].component_depth = component_depth
	return .None
}

three_mf_decode_build :: proc(
	document: ^xml.Document,
	build_id: xml.Element_ID,
	scene: ^Three_MF_Scene,
) -> Three_MF_Model_Error {
	write_index := 0
	for value in document.elements[build_id].value {
		switch child_id in value {
		case string:
		case xml.Element_ID:
			child := document.elements[child_id]
			if child.kind != .Element {continue}
			if !three_mf_model_namespace_valid(document, child_id) {
				return .Build_Invalid
			}
			if three_mf_xml_local_name(child.ident) != "item" {
				return .Build_Invalid
			}
			reference_text, reference_present :=
				three_mf_model_attribute(child, "objectid")
			reference, reference_ok :=
				three_mf_parse_u32(reference_text)
			object_index, object_found := three_mf_object_index(
				scene,
				reference,
				len(scene.objects),
			)
			if !reference_present || !reference_ok || reference == 0 ||
			   !object_found || scene.objects[object_index].contains_other {
				return .Reference_Invalid
			}
			transform_text, transform_present :=
				three_mf_model_attribute(child, "transform")
			transform, transform_ok := three_mf_parse_transform(
				transform_text,
				transform_present,
			)
			if !transform_ok {return .Transform_Invalid}
			scene.build_items[write_index] = {
				object_index = u32(object_index),
				transform = transform,
			}
			write_index += 1
		}
	}
	if write_index != len(scene.build_items) {return .Build_Invalid}
	return .None
}

three_mf_scene_destroy :: proc(
	scene: ^Three_MF_Scene,
	allocator := context.allocator,
) {
	delete(scene.vertices.x, allocator)
	delete(scene.vertices.y, allocator)
	delete(scene.vertices.z, allocator)
	delete(scene.vertices.stable_ids, allocator)
	delete(scene.triangles.a, allocator)
	delete(scene.triangles.b, allocator)
	delete(scene.triangles.c, allocator)
	delete(scene.triangles.stable_ids, allocator)
	delete(scene.triangles.object_indices, allocator)
	delete(scene.triangles.property_resource, allocator)
	delete(scene.triangles.property_a, allocator)
	delete(scene.triangles.property_b, allocator)
	delete(scene.triangles.property_c, allocator)
	delete(scene.objects, allocator)
	delete(scene.components, allocator)
	delete(scene.build_items, allocator)
	delete(scene.property_groups, allocator)
	for material in scene.base_materials {
		delete(material.name, allocator)
	}
	delete(scene.base_materials, allocator)
	for metadata in scene.metadata {
		delete(metadata.name, allocator)
		delete(metadata.namespace_uri, allocator)
		delete(metadata.value, allocator)
		delete(metadata.value_type, allocator)
	}
	delete(scene.metadata, allocator)
	for resource in scene.extension_resources {
		delete(resource.namespace_uri, allocator)
		delete(resource.qualified_name, allocator)
		delete(resource.payload, allocator)
	}
	delete(scene.extension_resources, allocator)
	delete(scene.model_part_path, allocator)
	scene^ = {}
}
