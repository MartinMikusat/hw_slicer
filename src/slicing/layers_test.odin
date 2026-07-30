package slicing

import "core:testing"

import contracts "../contracts"

@(test)
fixed_schedule_excludes_upper_bound_and_preserves_exact_step_test :: proc(
	t: ^testing.T,
) {
	request_hash: contracts.Content_Hash
	request_hash[0] = 0x48
	schedule, error := fixed_layer_schedule_build({
		request_hash = request_hash,
		minimum_z = 0,
		maximum_z = 1050,
		first_plane_z = 200,
		layer_step = 200,
		max_layer_count = 10,
	})
	defer fixed_layer_schedule_destroy(&schedule)
	testing.expect_value(t, error, Schedule_Error.None)
	testing.expect_value(t, len(schedule.layer_z), 5)
	testing.expect_value(t, schedule.layer_z[0], contracts.Micrometres(200))
	testing.expect_value(t, schedule.layer_z[4], contracts.Micrometres(1000))
	for layer_index in 1..<len(schedule.layer_z) {
		testing.expect_value(
			t,
			i64(schedule.layer_z[layer_index]-
				schedule.layer_z[layer_index-1]),
			i64(200),
		)
		testing.expect(t, schedule.layer_ids[layer_index] != schedule.layer_ids[0])
	}
}

@(test)
fixed_schedule_rejects_invalid_bounds_step_and_limit_test :: proc(t: ^testing.T) {
	_, bounds_error := fixed_layer_schedule_build({
		minimum_z = 1000,
		maximum_z = 1000,
		first_plane_z = 1000,
		layer_step = 200,
		max_layer_count = 10,
	})
	_, first_error := fixed_layer_schedule_build({
		minimum_z = 0,
		maximum_z = 1000,
		first_plane_z = 1000,
		layer_step = 200,
		max_layer_count = 10,
	})
	_, step_error := fixed_layer_schedule_build({
		minimum_z = 0,
		maximum_z = 1000,
		first_plane_z = 200,
		layer_step = 0,
		max_layer_count = 10,
	})
	_, limit_error := fixed_layer_schedule_build({
		minimum_z = 0,
		maximum_z = 1000,
		first_plane_z = 100,
		layer_step = 100,
		max_layer_count = 5,
	})
	testing.expect_value(t, bounds_error, Schedule_Error.Invalid_Bounds)
	testing.expect_value(t, first_error, Schedule_Error.Invalid_First_Plane)
	testing.expect_value(t, step_error, Schedule_Error.Invalid_Layer_Step)
	testing.expect_value(t, limit_error, Schedule_Error.Layer_Limit)
}
