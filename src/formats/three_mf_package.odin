package formats

import crypto_hash "core:crypto/hash"
import "core:bytes"
import xml "core:encoding/xml"
import "core:mem"
import "core:strings"

import contracts "../contracts"

THREE_MF_CONTENT_TYPES_PATH :: "[Content_Types].xml"
THREE_MF_ROOT_RELATIONSHIPS_PATH :: "_rels/.rels"
OPC_CONTENT_TYPES_NAMESPACE ::
	"http://schemas.openxmlformats.org/package/2006/content-types"
OPC_RELATIONSHIPS_NAMESPACE ::
	"http://schemas.openxmlformats.org/package/2006/relationships"
THREE_MF_MODEL_RELATIONSHIP_TYPE ::
	"http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"
THREE_MF_MODEL_CONTENT_TYPE ::
	"application/vnd.ms-package.3dmanufacturing-3dmodel+xml"
THREE_MF_XML_MAX_DEPTH :: u32(256)
THREE_MF_XML_MAX_ATTRIBUTES :: u32(64)
THREE_MF_XML_MAX_TAG_BYTES :: u64(1024*1024)
THREE_MF_XML_MAX_TEXT_BYTES :: u64(16*1024*1024)

Three_MF_Package_Limits :: struct {
	zip:                    Bounded_Zip_Limits,
	max_control_part_bytes: u64,
	max_model_part_bytes:   u64,
	max_control_elements:   u32,
	max_model_elements:     u32,
}

DEFAULT_THREE_MF_PACKAGE_LIMITS :: Three_MF_Package_Limits{
	zip = DEFAULT_3MF_ZIP_LIMITS,
	max_control_part_bytes = 1024*1024,
	max_model_part_bytes = 256*1024*1024,
	max_control_elements = 10_000,
	max_model_elements = 10_000_000,
}

Three_MF_Package :: struct {
	source:         contracts.Source_Asset,
	source_root_id: contracts.Stable_ID,
	archive:        Bounded_Zip_Archive,
	parts:          []Three_MF_Package_Part,
	model_path:     string,
	model_bytes:    []u8,
}

Three_MF_Package_Part_Role :: enum u8 {
	Other,
	Content_Types,
	Root_Relationships,
	Model,
	Model_Relationships,
}

Three_MF_Package_Part :: struct {
	stable_id:           contracts.Stable_ID,
	archive_entry_index: u32,
	path:                string,
	role:                Three_MF_Package_Part_Role,
	compression_method:  u16,
	crc32:               u32,
	compressed_bytes:    u32,
	uncompressed_bytes:  u32,
}

Three_MF_Package_Error :: enum u8 {
	None,
	Zip,
	Missing_Content_Types,
	Missing_Relationships,
	Control_Part_Limit,
	XML_Prohibited_Construct,
	XML_Element_Limit,
	XML_Depth_Limit,
	XML_Attribute_Limit,
	XML_Text_Limit,
	XML_Invalid,
	Relationships_Invalid,
	Model_Relationship_Missing,
	Model_Relationship_Duplicate,
	External_Model_Relationship,
	External_Relationship,
	Model_Path_Invalid,
	Model_Part_Missing,
	Model_Content_Type,
	Model_Part_Limit,
	Allocation_Failed,
}

three_mf_package_open :: proc(
	source: []u8,
	limits := DEFAULT_THREE_MF_PACKAGE_LIMITS,
	allocator := context.allocator,
) -> (Three_MF_Package, Three_MF_Package_Error) {
	result: Three_MF_Package
	result.source = {
		byte_count = u64(len(source)),
		format = .Three_MF,
		units = .Unspecified,
	}
	_ = crypto_hash.hash_bytes_to_buffer(
		.SHA256,
		source,
		result.source.content_hash[:],
	)
	result.source_root_id = contracts.stable_id_root(
		result.source.content_hash,
		.Source,
	)
	zip_error: Bounded_Zip_Error
	result.archive, zip_error = bounded_zip_parse(
		source,
		limits.zip,
		allocator,
	)
	if zip_error != .None {return {}, .Zip}
	result.parts = make(
		[]Three_MF_Package_Part,
		len(result.archive.entries),
		allocator,
	)
	if len(result.archive.entries) > 0 && result.parts == nil {
		three_mf_package_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	for entry, entry_index in result.archive.entries {
		result.parts[entry_index] = {
			stable_id = contracts.stable_id_child(
				result.source_root_id,
				.Package_Part,
				u64(entry_index),
			),
			archive_entry_index = u32(entry_index),
			path = entry.name,
			role = .Other,
			compression_method = entry.method,
			crc32 = entry.crc32,
			compressed_bytes = entry.compressed_bytes,
			uncompressed_bytes = entry.uncompressed_bytes,
		}
	}
	content_index, content_found := bounded_zip_find(
		result.archive,
		THREE_MF_CONTENT_TYPES_PATH,
	)
	if !content_found {
		three_mf_package_destroy(&result, allocator)
		return {}, .Missing_Content_Types
	}
	relationships_index, relationships_found := bounded_zip_find(
		result.archive,
		THREE_MF_ROOT_RELATIONSHIPS_PATH,
	)
	if !relationships_found {
		three_mf_package_destroy(&result, allocator)
		return {}, .Missing_Relationships
	}
	result.parts[content_index].role = .Content_Types
	result.parts[relationships_index].role = .Root_Relationships
	if u64(result.archive.entries[content_index].uncompressed_bytes) >
	   	limits.max_control_part_bytes ||
	   u64(result.archive.entries[relationships_index].uncompressed_bytes) >
	   	limits.max_control_part_bytes {
		three_mf_package_destroy(&result, allocator)
		return {}, .Control_Part_Limit
	}
	content_bytes, content_error := bounded_zip_extract(
		result.archive,
		content_index,
		allocator,
	)
	if content_error != .None {
		three_mf_package_destroy(&result, allocator)
		return {}, .Zip
	}
	defer delete(content_bytes, allocator)
	relationships_bytes, relationships_error := bounded_zip_extract(
		result.archive,
		relationships_index,
		allocator,
	)
	if relationships_error != .None {
		three_mf_package_destroy(&result, allocator)
		return {}, .Zip
	}
	defer delete(relationships_bytes, allocator)

	target, target_error := three_mf_model_target(
		relationships_bytes,
		limits.max_control_elements,
		allocator,
	)
	if target_error != .None {
		three_mf_package_destroy(&result, allocator)
		return {}, target_error
	}
	result.model_path = target
	model_index, model_found := bounded_zip_find(
		result.archive,
		result.model_path,
	)
	if !model_found {
		three_mf_package_destroy(&result, allocator)
		return {}, .Model_Part_Missing
	}
	result.parts[model_index].role = .Model
	model_relationships_path := three_mf_relationships_part_path(
		result.model_path,
		allocator,
	)
	if model_relationships_path == "" {
		three_mf_package_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	defer delete(model_relationships_path, allocator)
	model_relationships_index, model_relationships_found :=
		bounded_zip_find(result.archive, model_relationships_path)
	if model_relationships_found {
		result.parts[model_relationships_index].role = .Model_Relationships
		if u64(
			result.archive.entries[
				model_relationships_index
			].uncompressed_bytes,
		) > limits.max_control_part_bytes {
			three_mf_package_destroy(&result, allocator)
			return {}, .Control_Part_Limit
		}
		model_relationships_bytes, model_relationships_zip_error :=
			bounded_zip_extract(
				result.archive,
				model_relationships_index,
				allocator,
			)
		if model_relationships_zip_error != .None {
			three_mf_package_destroy(&result, allocator)
			return {}, .Zip
		}
		model_relationships_error := three_mf_relationships_validate(
			model_relationships_bytes,
			limits.max_control_elements,
			allocator,
		)
		delete(model_relationships_bytes, allocator)
		if model_relationships_error != .None {
			three_mf_package_destroy(&result, allocator)
			return {}, model_relationships_error
		}
	}
	if u64(result.archive.entries[model_index].uncompressed_bytes) >
	   limits.max_model_part_bytes {
		three_mf_package_destroy(&result, allocator)
		return {}, .Model_Part_Limit
	}
	content_type_ok, content_type_error :=
		three_mf_content_type_accepts_model(
			content_bytes,
			limits.max_control_elements,
			result.model_path,
			allocator,
		)
	if content_type_error != .None {
		three_mf_package_destroy(&result, allocator)
		return {}, content_type_error
	}
	if !content_type_ok {
		three_mf_package_destroy(&result, allocator)
		return {}, .Model_Content_Type
	}
	result.model_bytes, zip_error = bounded_zip_extract(
		result.archive,
		model_index,
		allocator,
	)
	if zip_error != .None {
		three_mf_package_destroy(&result, allocator)
		return {}, .Zip
	}
	model_preflight_error := three_mf_xml_preflight(
		result.model_bytes,
		limits.max_model_elements,
	)
	if model_preflight_error != .None {
		three_mf_package_destroy(&result, allocator)
		return {}, model_preflight_error
	}
	return result, .None
}

three_mf_model_target :: proc(
	part: []u8,
	max_elements: u32,
	allocator: mem.Allocator,
) -> (string, Three_MF_Package_Error) {
	document, error := three_mf_xml_parse(part, max_elements, allocator)
	if error != .None {return "", error}
	defer xml.destroy(document)
	if len(document.elements) == 0 ||
	   three_mf_xml_local_name(document.elements[0].ident) !=
	   	"Relationships" ||
	   !three_mf_xml_namespace_matches(
			document,
			0,
			OPC_RELATIONSHIPS_NAMESPACE,
		) {
		return "", .Relationships_Invalid
	}
	target: string
	relationship_ids: [dynamic]string
	defer delete(relationship_ids)
	for value in document.elements[0].value {
		switch child_id in value {
		case string:
		case xml.Element_ID:
			child := document.elements[child_id]
			if child.kind != .Element ||
			   !three_mf_xml_namespace_matches(
					document,
					child_id,
					OPC_RELATIONSHIPS_NAMESPACE,
				) {
				continue
			}
			if three_mf_xml_local_name(child.ident) != "Relationship" {
				return "", .Relationships_Invalid
			}
			relationship_id, id_ok :=
				three_mf_xml_attribute(child, "Id")
			if !id_ok || len(relationship_id) == 0 {
				return "", .Relationships_Invalid
			}
			for previous_id in relationship_ids {
				if previous_id == relationship_id {
					return "", .Relationships_Invalid
				}
			}
			append(&relationship_ids, relationship_id)
			relationship_type, type_ok :=
				three_mf_xml_attribute(child, "Type")
			if !type_ok || len(relationship_type) == 0 {
				return "", .Relationships_Invalid
			}
			target_mode, target_mode_ok :=
				three_mf_xml_attribute(child, "TargetMode")
			if target_mode_ok && target_mode == "External" {
				if relationship_type ==
				   THREE_MF_MODEL_RELATIONSHIP_TYPE {
					return "", .External_Model_Relationship
				}
				return "", .External_Relationship
			}
			if target_mode_ok && target_mode != "Internal" {
				return "", .Relationships_Invalid
			}
			target_value, target_ok :=
				three_mf_xml_attribute(child, "Target")
			if !target_ok || len(target_value) == 0 {
				return "", .Relationships_Invalid
			}
			if three_mf_relationship_target_is_external(target_value) {
				if relationship_type ==
				   THREE_MF_MODEL_RELATIONSHIP_TYPE {
					return "", .External_Model_Relationship
				}
				return "", .External_Relationship
			}
			if relationship_type != THREE_MF_MODEL_RELATIONSHIP_TYPE {
				continue
			}
			if target != "" {
				return "", .Model_Relationship_Duplicate
			}
			if strings.contains(target_value, "%") ||
			   strings.contains(target_value, "?") ||
			   strings.contains(target_value, "#") {
				return "", .Model_Path_Invalid
			}
			if len(target_value) > 0 && target_value[0] == '/' {
				target_value = target_value[1:]
			}
			if !bounded_zip_path_valid(target_value) {
				return "", .Model_Path_Invalid
			}
			target = target_value
		}
	}
	if target == "" {return "", .Model_Relationship_Missing}
	cloned_target := strings.clone(target, allocator)
	if cloned_target == "" {return "", .Allocation_Failed}
	return cloned_target, .None
}

three_mf_relationships_validate :: proc(
	part: []u8,
	max_elements: u32,
	allocator: mem.Allocator,
) -> Three_MF_Package_Error {
	document, error := three_mf_xml_parse(part, max_elements, allocator)
	if error != .None {return error}
	defer xml.destroy(document)
	if len(document.elements) == 0 ||
	   three_mf_xml_local_name(document.elements[0].ident) !=
	   	"Relationships" ||
	   !three_mf_xml_namespace_matches(
			document,
			0,
			OPC_RELATIONSHIPS_NAMESPACE,
		) {
		return .Relationships_Invalid
	}
	relationship_ids: [dynamic]string
	defer delete(relationship_ids)
	for value in document.elements[0].value {
		switch child_id in value {
		case string:
		case xml.Element_ID:
			child := document.elements[child_id]
			if child.kind != .Element ||
			   three_mf_xml_local_name(child.ident) != "Relationship" ||
			   !three_mf_xml_namespace_matches(
					document,
					child_id,
					OPC_RELATIONSHIPS_NAMESPACE,
				) {
				return .Relationships_Invalid
			}
			relationship_id, id_ok :=
				three_mf_xml_attribute(child, "Id")
			relationship_type, type_ok :=
				three_mf_xml_attribute(child, "Type")
			target, target_ok := three_mf_xml_attribute(child, "Target")
			if !id_ok || len(relationship_id) == 0 ||
			   !type_ok || len(relationship_type) == 0 ||
			   !target_ok || len(target) == 0 {
				return .Relationships_Invalid
			}
			for previous_id in relationship_ids {
				if previous_id == relationship_id {
					return .Relationships_Invalid
				}
			}
			append(&relationship_ids, relationship_id)
			target_mode, target_mode_ok :=
				three_mf_xml_attribute(child, "TargetMode")
			if target_mode_ok && target_mode == "External" {
				return .External_Relationship
			}
			if target_mode_ok && target_mode != "Internal" {
				return .Relationships_Invalid
			}
			if three_mf_relationship_target_is_external(target) {
				return .External_Relationship
			}
		}
	}
	return .None
}

three_mf_relationship_target_is_external :: proc(target: string) -> bool {
	if len(target) >= 2 && target[0] == '/' && target[1] == '/' {
		return true
	}
	for value in target {
		if value == ':' || value == '\\' {return true}
	}
	return false
}

three_mf_relationships_part_path :: proc(
	part_path: string,
	allocator: mem.Allocator,
) -> string {
	if part_path == "" {return ""}
	slash_index := -1
	for value, index in part_path {
		if value == '/' {slash_index = index}
	}
	directory_length := slash_index+1
	name := part_path[directory_length:]
	if name == "" {return ""}
	middle := "_rels/"
	suffix := ".rels"
	path_bytes := make(
		[]u8,
		directory_length+len(middle)+len(name)+len(suffix),
		allocator,
	)
	if path_bytes == nil {return ""}
	cursor := 0
	cursor += copy(path_bytes[cursor:], transmute([]u8)part_path[:directory_length])
	cursor += copy(path_bytes[cursor:], transmute([]u8)middle)
	cursor += copy(path_bytes[cursor:], transmute([]u8)name)
	copy(path_bytes[cursor:], transmute([]u8)suffix)
	return string(path_bytes)
}

three_mf_content_type_accepts_model :: proc(
	part: []u8,
	max_elements: u32,
	model_path: string,
	allocator: mem.Allocator,
) -> (bool, Three_MF_Package_Error) {
	document, error := three_mf_xml_parse(
		part,
		max_elements,
		allocator,
	)
	if error != .None {return false, error}
	defer xml.destroy(document)
	if len(document.elements) == 0 ||
	   three_mf_xml_local_name(document.elements[0].ident) != "Types" ||
	   !three_mf_xml_namespace_matches(
			document,
			0,
			OPC_CONTENT_TYPES_NAMESPACE,
		) {
		return false, .Model_Content_Type
	}
	for value in document.elements[0].value {
		switch child_id in value {
		case string:
		case xml.Element_ID:
			child := document.elements[child_id]
			if child.kind != .Element {continue}
			if !three_mf_xml_namespace_matches(
				document,
				child_id,
				OPC_CONTENT_TYPES_NAMESPACE,
			) {
				continue
			}
			local_name := three_mf_xml_local_name(child.ident)
			if local_name != "Override" && local_name != "Default" {
				return false, .Model_Content_Type
			}
			content_type, content_type_ok :=
				three_mf_xml_attribute(child, "ContentType")
			if !content_type_ok ||
			   content_type != THREE_MF_MODEL_CONTENT_TYPE {
				continue
			}
			if local_name == "Override" {
				part_name, part_name_ok :=
					three_mf_xml_attribute(child, "PartName")
				if part_name_ok &&
				   len(part_name) == len(model_path)+1 &&
				   part_name[0] == '/' &&
				   part_name[1:] == model_path {
					return true, .None
				}
			}
			if local_name == "Default" {
				extension, extension_ok :=
					three_mf_xml_attribute(child, "Extension")
				if extension_ok && extension == "model" {
					return true, .None
				}
			}
		}
	}
	return false, .None
}

three_mf_xml_parse :: proc(
	part: []u8,
	max_elements: u32,
	allocator: mem.Allocator,
) -> (^xml.Document, Three_MF_Package_Error) {
	preflight_error := three_mf_xml_preflight(part, max_elements)
	if preflight_error != .None {return nil, preflight_error}
	document, parse_error := xml.parse_bytes(
		part,
		{
			flags = {
				.Error_on_Unsupported,
			},
		},
		error_handler = three_mf_xml_silent_error,
		allocator = allocator,
	)
	if parse_error != .None {
		xml.destroy(document)
		return nil, .XML_Invalid
	}
	if u64(len(document.elements)) > u64(max_elements) {
		xml.destroy(document)
		return nil, .XML_Element_Limit
	}
	return document, .None
}

three_mf_xml_preflight :: proc(
	part: []u8,
	max_elements: u32,
) -> Three_MF_Package_Error {
	doctype_token := "<!DOCTYPE"
	entity_token := "<!ENTITY"
	if bytes.contains(part, transmute([]u8)doctype_token) ||
	   bytes.contains(part, transmute([]u8)entity_token) {
		return .XML_Prohibited_Construct
	}
	element_count: u64
	depth: u32
	root_count: u32
	cursor := 0
	text_start := 0
	for cursor < len(part) {
		if part[cursor] != '<' {
			cursor += 1
			continue
		}
		if u64(cursor-text_start) > THREE_MF_XML_MAX_TEXT_BYTES {
			return .XML_Text_Limit
		}
		if three_mf_xml_token_at(part, cursor, "<!--") {
			end, found := three_mf_xml_find_token(part, cursor+4, "-->")
			if !found {return .XML_Invalid}
			if u64(end-(cursor+4)) > THREE_MF_XML_MAX_TEXT_BYTES {
				return .XML_Text_Limit
			}
			cursor = end+3
			text_start = cursor
			continue
		}
		if three_mf_xml_token_at(part, cursor, "<![CDATA[") {
			end, found := three_mf_xml_find_token(
				part,
				cursor+9,
				"]]>",
			)
			if !found {return .XML_Invalid}
			if u64(end-(cursor+9)) > THREE_MF_XML_MAX_TEXT_BYTES {
				return .XML_Text_Limit
			}
			cursor = end+3
			text_start = cursor
			continue
		}
		processing := three_mf_xml_token_at(part, cursor, "<?")
		declaration := three_mf_xml_token_at(part, cursor, "<!")
		closing := three_mf_xml_token_at(part, cursor, "</")
		tag_end, attribute_count, tag_ok :=
			three_mf_xml_scan_tag(part, cursor, processing)
		if !tag_ok {return .XML_Invalid}
		if u64(tag_end-cursor+1) > THREE_MF_XML_MAX_TAG_BYTES ||
		   attribute_count > THREE_MF_XML_MAX_ATTRIBUTES {
			return .XML_Attribute_Limit
		}
		if closing {
			if depth == 0 {return .XML_Invalid}
			depth -= 1
		} else if !processing && !declaration {
			element_count += 1
			if element_count > u64(max_elements) {
				return .XML_Element_Limit
			}
			if depth == 0 {
				root_count += 1
				if root_count > 1 {return .XML_Invalid}
			}
			depth += 1
			if depth > THREE_MF_XML_MAX_DEPTH {
				return .XML_Depth_Limit
			}
			last := tag_end-1
			for last > cursor && three_mf_xml_space(part[last]) {
				last -= 1
			}
			if part[last] == '/' {depth -= 1}
		}
		cursor = tag_end+1
		text_start = cursor
	}
	if u64(len(part)-text_start) > THREE_MF_XML_MAX_TEXT_BYTES {
		return .XML_Text_Limit
	}
	if depth != 0 || root_count != 1 {return .XML_Invalid}
	return .None
}

three_mf_xml_scan_tag :: proc(
	part: []u8,
	start: int,
	processing: bool,
) -> (int, u32, bool) {
	cursor := start+1
	quote: u8
	attribute_count: u32
	for cursor < len(part) {
		value := part[cursor]
		if quote != 0 {
			if value == quote {quote = 0}
			cursor += 1
			continue
		}
		if value == '"' || value == '\'' {
			quote = value
			cursor += 1
			continue
		}
		if value == '=' {
			if attribute_count == max(u32) {return 0, 0, false}
			attribute_count += 1
		}
		if value == '>' {
			if processing &&
			   (cursor == start+1 || part[cursor-1] != '?') {
				return 0, 0, false
			}
			return cursor, attribute_count, true
		}
		cursor += 1
	}
	return 0, 0, false
}

three_mf_xml_find_token :: proc(
	part: []u8,
	start: int,
	token: string,
) -> (int, bool) {
	if len(token) == 0 {return start, true}
	for cursor := start; cursor+len(token) <= len(part); cursor += 1 {
		if three_mf_xml_token_at(part, cursor, token) {
			return cursor, true
		}
	}
	return 0, false
}

three_mf_xml_token_at :: proc(
	part: []u8,
	offset: int,
	token: string,
) -> bool {
	if offset < 0 || offset+len(token) > len(part) {return false}
	for value, token_index in token {
		if part[offset+token_index] != u8(value) {return false}
	}
	return true
}

three_mf_xml_space :: proc(value: u8) -> bool {
	return value == ' ' || value == '\t' ||
		value == '\r' || value == '\n'
}

three_mf_xml_local_name :: proc(name: string) -> string {
	for value, index in name {
		if value == ':' {return name[index+1:]}
	}
	return name
}

three_mf_xml_attribute :: proc(
	element: xml.Element,
	local_name: string,
) -> (string, bool) {
	for attribute in element.attribs {
		if three_mf_xml_local_name(attribute.key) == local_name {
			return attribute.val, true
		}
	}
	return "", false
}

three_mf_xml_namespace_matches :: proc(
	document: ^xml.Document,
	element_id: xml.Element_ID,
	namespace: string,
) -> bool {
	resolved, found := three_mf_xml_namespace_uri(document, element_id)
	return found && resolved == namespace
}

three_mf_xml_namespace_uri :: proc(
	document: ^xml.Document,
	element_id: xml.Element_ID,
) -> (string, bool) {
	element := document.elements[element_id]
	prefix: string
	for value, index in element.ident {
		if value == ':' {
			prefix = element.ident[:index]
			break
		}
	}
	current_id := element_id
	for {
		current := document.elements[current_id]
		for attribute in current.attribs {
			if prefix == "" {
				if attribute.key == "xmlns" {
					return attribute.val, true
				}
			} else if len(attribute.key) == len(prefix)+6 &&
			          attribute.key[:6] == "xmlns:" &&
			          attribute.key[6:] == prefix {
				return attribute.val, true
			}
		}
		if current_id == 0 {break}
		current_id = current.parent
	}
	return "", false
}

three_mf_xml_silent_error :: proc(
	pos: xml.Pos,
	message: string,
	args: ..any,
) {
	_ = pos
	_ = message
	_ = args
}

three_mf_package_part_extract :: proc(
	result: Three_MF_Package,
	part_index: int,
	allocator := context.allocator,
) -> ([]u8, Bounded_Zip_Error) {
	if part_index < 0 || part_index >= len(result.parts) {
		return nil, .Local_Header
	}
	part := result.parts[part_index]
	if u64(part.archive_entry_index) >= u64(len(result.archive.entries)) {
		return nil, .Local_Header
	}
	entry := result.archive.entries[part.archive_entry_index]
	if entry.name != part.path ||
	   entry.method != part.compression_method ||
	   entry.crc32 != part.crc32 ||
	   entry.compressed_bytes != part.compressed_bytes ||
	   entry.uncompressed_bytes != part.uncompressed_bytes {
		return nil, .Size_Mismatch
	}
	return bounded_zip_extract(
		result.archive,
		int(part.archive_entry_index),
		allocator,
	)
}

three_mf_package_destroy :: proc(
	result: ^Three_MF_Package,
	allocator := context.allocator,
) {
	delete(result.model_bytes, allocator)
	delete(result.model_path, allocator)
	delete(result.parts, allocator)
	bounded_zip_destroy(&result.archive, allocator)
	result^ = {}
}
