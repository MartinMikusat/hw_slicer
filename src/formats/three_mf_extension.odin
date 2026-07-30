package formats

import crypto_hash "core:crypto/hash"
import xml "core:encoding/xml"

import contracts "../contracts"

THREE_MF_EXTENSION_PAYLOAD_SCHEMA_VERSION :: u32(1)
THREE_MF_EXTENSION_PAYLOAD_MAGIC :: [8]u8{
	'H',
	'W',
	'3',
	'M',
	'F',
	'X',
	'0',
	'1',
}

Three_MF_Extension_Payload_Error :: enum u8 {
	None,
	Limit,
	Allocation_Failed,
}

three_mf_extension_payload_size :: proc(
	document: ^xml.Document,
	element_id: xml.Element_ID,
	max_bytes: u64,
) -> (u64, bool) {
	size: u64 = len(THREE_MF_EXTENSION_PAYLOAD_MAGIC)+4
	if !three_mf_extension_element_size(
		document,
		element_id,
		max_bytes,
		&size,
	) {
		return 0, false
	}
	return size, true
}

three_mf_extension_payload_encode :: proc(
	document: ^xml.Document,
	element_id: xml.Element_ID,
	max_bytes: u64,
	allocator := context.allocator,
) -> (
	payload: []u8,
	hash: contracts.Content_Hash,
	error: Three_MF_Extension_Payload_Error,
) {
	byte_count, size_ok := three_mf_extension_payload_size(
		document,
		element_id,
		max_bytes,
	)
	if !size_ok || byte_count > u64(max(int)) {
		return nil, {}, .Limit
	}
	payload = make([]u8, int(byte_count), allocator)
	if byte_count > 0 && payload == nil {
		return nil, {}, .Allocation_Failed
	}
	cursor := 0
	for value in THREE_MF_EXTENSION_PAYLOAD_MAGIC {
		payload[cursor] = value
		cursor += 1
	}
	three_mf_extension_write_u32(
		payload,
		&cursor,
		THREE_MF_EXTENSION_PAYLOAD_SCHEMA_VERSION,
	)
	three_mf_extension_write_element(
		document,
		element_id,
		payload,
		&cursor,
	)
	if cursor != len(payload) {
		delete(payload, allocator)
		return nil, {}, .Limit
	}
	_ = crypto_hash.hash_bytes_to_buffer(.SHA256, payload, hash[:])
	return payload, hash, .None
}

three_mf_extension_element_size :: proc(
	document: ^xml.Document,
	element_id: xml.Element_ID,
	max_bytes: u64,
	size: ^u64,
) -> bool {
	element := document.elements[element_id]
	if !three_mf_extension_add_size(size, 8+u64(len(element.ident)), max_bytes) {
		return false
	}
	if !three_mf_extension_add_size(size, 8, max_bytes) {return false}
	for attribute in element.attribs {
		if !three_mf_extension_add_size(
			size,
			16+u64(len(attribute.key))+u64(len(attribute.val)),
			max_bytes,
		) {
			return false
		}
	}
	if !three_mf_extension_add_size(size, 8, max_bytes) {return false}
	for value in element.value {
		if !three_mf_extension_add_size(size, 1, max_bytes) {
			return false
		}
		switch child in value {
		case string:
			if !three_mf_extension_add_size(
				size,
				8+u64(len(child)),
				max_bytes,
			) {
				return false
			}
		case xml.Element_ID:
			if !three_mf_extension_element_size(
				document,
				child,
				max_bytes,
				size,
			) {
				return false
			}
		}
	}
	return true
}

three_mf_extension_add_size :: proc(
	size: ^u64,
	added, limit: u64,
) -> bool {
	if added > limit || size^ > limit-added {return false}
	size^ += added
	return true
}

three_mf_extension_write_element :: proc(
	document: ^xml.Document,
	element_id: xml.Element_ID,
	output: []u8,
	cursor: ^int,
) {
	element := document.elements[element_id]
	three_mf_extension_write_string(output, cursor, element.ident)
	three_mf_extension_write_u64(output, cursor, u64(len(element.attribs)))
	for attribute in element.attribs {
		three_mf_extension_write_string(output, cursor, attribute.key)
		three_mf_extension_write_string(output, cursor, attribute.val)
	}
	three_mf_extension_write_u64(output, cursor, u64(len(element.value)))
	for value in element.value {
		switch child in value {
		case string:
			output[cursor^] = 1
			cursor^ += 1
			three_mf_extension_write_string(output, cursor, child)
		case xml.Element_ID:
			output[cursor^] = 2
			cursor^ += 1
			three_mf_extension_write_element(
				document,
				child,
				output,
				cursor,
			)
		}
	}
}

three_mf_extension_write_string :: proc(
	output: []u8,
	cursor: ^int,
	value: string,
) {
	three_mf_extension_write_u64(output, cursor, u64(len(value)))
	cursor^ += copy(output[cursor^:], transmute([]u8)value)
}

three_mf_extension_write_u32 :: proc(
	output: []u8,
	cursor: ^int,
	value: u32,
) {
	for shift: u32 = 0; shift < 32; shift += 8 {
		output[cursor^] = u8(value>>shift)
		cursor^ += 1
	}
}

three_mf_extension_write_u64 :: proc(
	output: []u8,
	cursor: ^int,
	value: u64,
) {
	for shift: u32 = 0; shift < 64; shift += 8 {
		output[cursor^] = u8(value>>shift)
		cursor^ += 1
	}
}
