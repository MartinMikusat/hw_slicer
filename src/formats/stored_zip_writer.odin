package formats

Bounded_Zip_Write_Entry :: struct {
	name: string,
	data: []u8,
}

bounded_zip_write_stored :: proc(
	entries: []Bounded_Zip_Write_Entry,
	limits := DEFAULT_3MF_ZIP_LIMITS,
	allocator := context.allocator,
) -> ([]u8, Bounded_Zip_Error) {
	if u64(len(entries)) > u64(limits.max_entries) ||
	   len(entries) > int(max(u16)) {
		return nil, .Entry_Limit
	}
	order := make([]int, len(entries), allocator)
	local_offsets := make([]u32, len(entries), allocator)
	crcs := make([]u32, len(entries), allocator)
	defer delete(order, allocator)
	defer delete(local_offsets, allocator)
	defer delete(crcs, allocator)
	if len(entries) > 0 &&
	   (order == nil || local_offsets == nil || crcs == nil) {
		return nil, .Allocation_Failed
	}
	for &entry_index, index in order {
		entry_index = index
	}
	for index in 1..<len(order) {
		entry_index := order[index]
		position := index
		for position > 0 &&
		    bounded_zip_name_less(
		    	entries[entry_index].name,
		    	entries[order[position-1]].name,
		    ) {
			order[position] = order[position-1]
			position -= 1
		}
		order[position] = entry_index
	}

	local_bytes: u64
	central_bytes: u64
	total_uncompressed: u64
	for entry_index, sorted_index in order {
		entry := entries[entry_index]
		if !bounded_zip_path_valid(entry.name) {
			return nil, .Invalid_Path
		}
		if len(entry.name) > int(limits.max_path_bytes) ||
		   len(entry.name) > int(max(u16)) {
			return nil, .Path_Limit
		}
		if sorted_index > 0 &&
		   entries[order[sorted_index-1]].name == entry.name {
			return nil, .Duplicate_Path
		}
		if u64(len(entry.data)) > limits.max_entry_bytes ||
		   u64(len(entry.data)) > u64(max(u32)) {
			return nil, .Entry_Size_Limit
		}
		if u64(len(entry.data)) > limits.max_total_bytes ||
		   total_uncompressed >
		   	limits.max_total_bytes-u64(len(entry.data)) {
			return nil, .Total_Size_Limit
		}
		total_uncompressed += u64(len(entry.data))
		local_add := u64(30+len(entry.name))+u64(len(entry.data))
		central_add := u64(46+len(entry.name))
		if local_bytes > max(u64)-local_add ||
		   central_bytes > max(u64)-central_add {
			return nil, .Source_Size_Limit
		}
		local_bytes += local_add
		central_bytes += central_add
	}
	if local_bytes > u64(max(u32)) ||
	   central_bytes > u64(max(u32)) ||
	   local_bytes > max(u64)-central_bytes ||
	   local_bytes+central_bytes > max(u64)-22 {
		return nil, .Source_Size_Limit
	}
	output_bytes := local_bytes+central_bytes+22
	if output_bytes > limits.max_source_bytes ||
	   output_bytes > u64(max(int)) {
		return nil, .Source_Size_Limit
	}
	output := make([]u8, int(output_bytes), allocator)
	if output_bytes > 0 && output == nil {
		return nil, .Allocation_Failed
	}

	cursor := 0
	for entry_index, sorted_index in order {
		entry := entries[entry_index]
		local_offsets[sorted_index] = u32(cursor)
		crcs[sorted_index] = bounded_zip_crc32(entry.data)
		bounded_zip_write_u32(output, cursor, ZIP_LOCAL_HEADER_SIGNATURE)
		bounded_zip_write_u16(output, cursor+4, 20)
		bounded_zip_write_u16(output, cursor+6, 0x0800)
		bounded_zip_write_u16(output, cursor+8, 0)
		bounded_zip_write_u16(output, cursor+10, 0)
		bounded_zip_write_u16(output, cursor+12, 33)
		bounded_zip_write_u32(output, cursor+14, crcs[sorted_index])
		bounded_zip_write_u32(output, cursor+18, u32(len(entry.data)))
		bounded_zip_write_u32(output, cursor+22, u32(len(entry.data)))
		bounded_zip_write_u16(output, cursor+26, u16(len(entry.name)))
		bounded_zip_write_u16(output, cursor+28, 0)
		cursor += 30
		copy(output[cursor:], transmute([]u8)entry.name)
		cursor += len(entry.name)
		copy(output[cursor:], entry.data)
		cursor += len(entry.data)
	}

	central_offset := cursor
	for entry_index, sorted_index in order {
		entry := entries[entry_index]
		bounded_zip_write_u32(output, cursor, ZIP_CENTRAL_HEADER_SIGNATURE)
		bounded_zip_write_u16(output, cursor+4, 20)
		bounded_zip_write_u16(output, cursor+6, 20)
		bounded_zip_write_u16(output, cursor+8, 0x0800)
		bounded_zip_write_u16(output, cursor+10, 0)
		bounded_zip_write_u16(output, cursor+12, 0)
		bounded_zip_write_u16(output, cursor+14, 33)
		bounded_zip_write_u32(output, cursor+16, crcs[sorted_index])
		bounded_zip_write_u32(output, cursor+20, u32(len(entry.data)))
		bounded_zip_write_u32(output, cursor+24, u32(len(entry.data)))
		bounded_zip_write_u16(output, cursor+28, u16(len(entry.name)))
		bounded_zip_write_u16(output, cursor+30, 0)
		bounded_zip_write_u16(output, cursor+32, 0)
		bounded_zip_write_u16(output, cursor+34, 0)
		bounded_zip_write_u16(output, cursor+36, 0)
		bounded_zip_write_u32(output, cursor+38, 0)
		bounded_zip_write_u32(
			output,
			cursor+42,
			local_offsets[sorted_index],
		)
		cursor += 46
		copy(output[cursor:], transmute([]u8)entry.name)
		cursor += len(entry.name)
	}
	central_size := cursor-central_offset
	bounded_zip_write_u32(output, cursor, ZIP_END_SIGNATURE)
	bounded_zip_write_u16(output, cursor+4, 0)
	bounded_zip_write_u16(output, cursor+6, 0)
	bounded_zip_write_u16(output, cursor+8, u16(len(entries)))
	bounded_zip_write_u16(output, cursor+10, u16(len(entries)))
	bounded_zip_write_u32(output, cursor+12, u32(central_size))
	bounded_zip_write_u32(output, cursor+16, u32(central_offset))
	bounded_zip_write_u16(output, cursor+20, 0)
	cursor += 22
	assert(cursor == len(output))
	return output, .None
}

bounded_zip_name_less :: proc(left, right: string) -> bool {
	byte_count := min(len(left), len(right))
	for byte_index in 0..<byte_count {
		if left[byte_index] < right[byte_index] {return true}
		if left[byte_index] > right[byte_index] {return false}
	}
	return len(left) < len(right)
}

bounded_zip_write_u16 :: proc(bytes: []u8, offset: int, value: u16) {
	bytes[offset] = u8(value)
	bytes[offset+1] = u8(value>>8)
}

bounded_zip_write_u32 :: proc(bytes: []u8, offset: int, value: u32) {
	bytes[offset] = u8(value)
	bytes[offset+1] = u8(value>>8)
	bytes[offset+2] = u8(value>>16)
	bytes[offset+3] = u8(value>>24)
}
