package slicing

import contracts "../contracts"

Fixed_Schedule_Input :: struct {
	request_hash:   contracts.Content_Hash,
	minimum_z:      contracts.Micrometres,
	maximum_z:      contracts.Micrometres,
	first_plane_z:  contracts.Micrometres,
	layer_step:     contracts.Micrometres,
	max_layer_count: u32,
}

Fixed_Layer_Schedule :: struct {
	request_hash:  contracts.Content_Hash,
	minimum_z:     contracts.Micrometres,
	maximum_z:     contracts.Micrometres,
	first_plane_z: contracts.Micrometres,
	layer_step:    contracts.Micrometres,
	layer_z:       []contracts.Micrometres,
	layer_ids:     []contracts.Stable_ID,
}

Schedule_Error :: enum u8 {
	None,
	Invalid_Bounds,
	Invalid_First_Plane,
	Invalid_Layer_Step,
	Layer_Limit,
	Allocation_Failed,
}

fixed_layer_schedule_build :: proc(
	input: Fixed_Schedule_Input,
	allocator := context.allocator,
) -> (Fixed_Layer_Schedule, Schedule_Error) {
	minimum_z := i64(input.minimum_z)
	maximum_z := i64(input.maximum_z)
	first_plane_z := i64(input.first_plane_z)
	layer_step := i64(input.layer_step)
	if minimum_z >= maximum_z {return {}, .Invalid_Bounds}
	if first_plane_z < minimum_z || first_plane_z >= maximum_z {
		return {}, .Invalid_First_Plane
	}
	if layer_step <= 0 {return {}, .Invalid_Layer_Step}

	span := i128(maximum_z)-i128(first_plane_z)
	count_128 := (span+i128(layer_step)-1)/i128(layer_step)
	if count_128 <= 0 || count_128 > i128(input.max_layer_count) ||
	   count_128 > i128(max(int)) {
		return {}, .Layer_Limit
	}
	count := int(count_128)
	schedule := Fixed_Layer_Schedule{
		request_hash = input.request_hash,
		minimum_z = input.minimum_z,
		maximum_z = input.maximum_z,
		first_plane_z = input.first_plane_z,
		layer_step = input.layer_step,
	}
	schedule.layer_z = make([]contracts.Micrometres, count, allocator)
	schedule.layer_ids = make([]contracts.Stable_ID, count, allocator)
	if schedule.layer_z == nil || schedule.layer_ids == nil {
		fixed_layer_schedule_destroy(&schedule, allocator)
		return {}, .Allocation_Failed
	}
	schedule_root_id := contracts.stable_id_root(input.request_hash, .Layer)
	for layer_index in 0..<count {
		z := i128(first_plane_z)+i128(layer_index)*i128(layer_step)
		schedule.layer_z[layer_index] = contracts.Micrometres(i64(z))
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
	delete(schedule.layer_ids, allocator)
	schedule^ = {}
}
