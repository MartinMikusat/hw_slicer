package slicing

import contracts "../contracts"

Fixed_Schedule_Input :: struct {
	request_hash:       contracts.Content_Hash,
	minimum_z:          contracts.Micrometres,
	maximum_z:          contracts.Micrometres,
	first_layer_height: contracts.Micrometres,
	layer_step:         contracts.Micrometres,
	max_layer_count:    u32,
}

// Each layer is sectioned at its mid-height (`layer_z`) and printed at its top (`print_z`).
// A layer exists while its section plane lies below `maximum_z`, so the printed height is the
// model height rounded to the nearest layer.
Fixed_Layer_Schedule :: struct {
	request_hash:       contracts.Content_Hash,
	minimum_z:          contracts.Micrometres,
	maximum_z:          contracts.Micrometres,
	first_plane_z:      contracts.Micrometres,
	first_layer_height: contracts.Micrometres,
	layer_step:         contracts.Micrometres,
	adaptive:           bool,
	layer_z:            []contracts.Micrometres, // section plane, at mid-layer
	print_z:            []contracts.Micrometres, // layer top, where the layer prints
	layer_ids:          []contracts.Stable_ID,
}

Schedule_Error :: enum u8 {
	None,
	Invalid_Bounds,
	Invalid_First_Plane,
	Invalid_Layer_Step,
	Layer_Limit,
	Allocation_Failed,
}

// The section plane and print height of fixed-schedule layer `layer_index`.
fixed_layer_planes :: proc(
	minimum_z, first_layer_height, layer_step: i64,
	layer_index: int,
) -> (section_z, print_z: i128) {
	print_z = i128(minimum_z)+i128(first_layer_height)+i128(layer_index)*i128(layer_step)
	if layer_index == 0 {
		section_z = i128(minimum_z)+i128(first_layer_height)/2
	} else {
		section_z = print_z-i128(layer_step)/2
	}
	return
}

// The number of fixed-schedule layers whose section plane lies below `maximum_z`.
fixed_layer_count :: proc(minimum_z, maximum_z, first_layer_height, layer_step: i64) -> i128 {
	first_section, first_print := fixed_layer_planes(minimum_z, first_layer_height, layer_step, 0)
	if first_section >= i128(maximum_z) {return 0}
	// Layer i >= 1 exists while first_print + i*step - step/2 < maximum_z.
	reach := i128(maximum_z)-first_print+i128(layer_step)/2
	if reach <= 0 {return 1}
	return 1+max(i128(0), (reach+i128(layer_step)-1)/i128(layer_step)-1)
}

fixed_layer_schedule_build :: proc(
	input: Fixed_Schedule_Input,
	allocator := context.allocator,
) -> (Fixed_Layer_Schedule, Schedule_Error) {
	minimum_z := i64(input.minimum_z)
	maximum_z := i64(input.maximum_z)
	first_layer_height := i64(input.first_layer_height)
	layer_step := i64(input.layer_step)
	if minimum_z >= maximum_z {return {}, .Invalid_Bounds}
	if first_layer_height <= 0 {return {}, .Invalid_First_Plane}
	if layer_step <= 0 {return {}, .Invalid_Layer_Step}

	count_128 := fixed_layer_count(minimum_z, maximum_z, first_layer_height, layer_step)
	if count_128 <= 0 {return {}, .Invalid_First_Plane}
	if count_128 > i128(input.max_layer_count) || count_128 > i128(max(int)) {
		return {}, .Layer_Limit
	}
	count := int(count_128)
	first_section, _ := fixed_layer_planes(minimum_z, first_layer_height, layer_step, 0)
	schedule := Fixed_Layer_Schedule{
		request_hash = input.request_hash,
		minimum_z = input.minimum_z,
		maximum_z = input.maximum_z,
		first_plane_z = contracts.Micrometres(i64(first_section)),
		first_layer_height = input.first_layer_height,
		layer_step = input.layer_step,
	}
	schedule.layer_z = make([]contracts.Micrometres, count, allocator)
	schedule.print_z = make([]contracts.Micrometres, count, allocator)
	schedule.layer_ids = make([]contracts.Stable_ID, count, allocator)
	if schedule.layer_z == nil || schedule.print_z == nil || schedule.layer_ids == nil {
		fixed_layer_schedule_destroy(&schedule, allocator)
		return {}, .Allocation_Failed
	}
	schedule_root_id := contracts.stable_id_root(input.request_hash, .Layer)
	for layer_index in 0..<count {
		section_z, print_z := fixed_layer_planes(minimum_z, first_layer_height, layer_step, layer_index)
		schedule.layer_z[layer_index] = contracts.Micrometres(i64(section_z))
		schedule.print_z[layer_index] = contracts.Micrometres(i64(print_z))
		schedule.layer_ids[layer_index] = contracts.stable_id_child(
			schedule_root_id,
			.Layer,
			u64(layer_index),
		)
	}
	return schedule, .None
}

fixed_layer_schedule_destroy :: proc(
	schedule: ^Fixed_Layer_Schedule,
	allocator := context.allocator,
) {
	delete(schedule.layer_z, allocator)
	delete(schedule.print_z, allocator)
	delete(schedule.layer_ids, allocator)
	schedule^ = {}
}
