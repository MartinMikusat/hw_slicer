package features

import contracts "../contracts"
import polygon "../polygon"
import profiles "../profiles"

SCHEMA_VERSION_MOTION_PLAN_HASH :: u32(1)

motion_plan_result_hash :: proc(
	path_plan_hash: contracts.Content_Hash,
	extrusion_hash: contracts.Content_Hash,
	layer_ids: []contracts.Stable_ID,
	layer_z: []contracts.Micrometres,
	model_layers: []polygon.Polygon_Set,
	plan: Unified_Path_Plan_Result,
	extrusion: Extrusion_Result,
	profile: profiles.Resolved_Profiles,
	result: Motion_Plan_Result,
	limits := DEFAULT_MOTION_PLAN_LIMITS,
	allocator := context.allocator,
) -> (contracts.Content_Hash, bool) {
	expected, expected_error := motion_plan_build(
		layer_ids,
		layer_z,
		model_layers,
		plan,
		extrusion,
		profile,
		limits,
		allocator,
	)
	if expected_error != .None {return {}, false}
	defer motion_plan_result_destroy(&expected, allocator)
	if result.retraction_count != expected.retraction_count ||
	   result.travel_count != expected.travel_count ||
	   result.extrusion_count != expected.extrusion_count ||
	   result.dwell_count != expected.dwell_count ||
	   result.total_motion_duration_us != expected.total_motion_duration_us ||
	   result.total_dwell_duration_us != expected.total_dwell_duration_us ||
	   result.total_planned_duration_us != expected.total_planned_duration_us ||
	   len(result.layers) != len(expected.layers) ||
	   len(result.operations) != len(expected.operations) {
		return {}, false
	}
	for layer, layer_index in result.layers {
		if layer != expected.layers[layer_index] {return {}, false}
	}
	for operation, operation_index in result.operations {
		if operation != expected.operations[operation_index] {
			return {}, false
		}
	}

	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/motion-plan",
		SCHEMA_VERSION_MOTION_PLAN_HASH,
	)
	contracts.canonical_hash_append_content_hash(&hash, path_plan_hash)
	contracts.canonical_hash_append_content_hash(&hash, extrusion_hash)
	contracts.canonical_hash_append_content_hash(
		&hash,
		profiles.printer_profile_hash(profile.printer),
	)
	contracts.canonical_hash_append_content_hash(
		&hash,
		profiles.process_profile_hash(profile.process),
	)
	contracts.canonical_hash_append_u64(&hash, u64(len(layer_ids)))
	for layer_id, layer_index in layer_ids {
		contracts.canonical_hash_append_stable_id(&hash, layer_id)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(layer_z[layer_index]),
		)
		model_hash, model_ok :=
			polygon.polygon_set_hash(model_layers[layer_index])
		if !model_ok {return {}, false}
		contracts.canonical_hash_append_content_hash(&hash, model_hash)
	}
	contracts.canonical_hash_append_u64(&hash, result.retraction_count)
	contracts.canonical_hash_append_u64(&hash, result.travel_count)
	contracts.canonical_hash_append_u64(&hash, result.extrusion_count)
	contracts.canonical_hash_append_u64(&hash, result.dwell_count)
	contracts.canonical_hash_append_u64(
		&hash,
		result.total_motion_duration_us,
	)
	contracts.canonical_hash_append_u64(
		&hash,
		result.total_dwell_duration_us,
	)
	contracts.canonical_hash_append_u64(
		&hash,
		result.total_planned_duration_us,
	)
	contracts.canonical_hash_append_u64(&hash, u64(len(result.layers)))
	for layer in result.layers {
		contracts.canonical_hash_append_stable_id(&hash, layer.stable_id)
		contracts.canonical_hash_append_u32(&hash, layer.layer_index)
		contracts.canonical_hash_append_i64(&hash, i64(layer.z))
		contracts.canonical_hash_append_u64(&hash, layer.operation_offset)
		contracts.canonical_hash_append_u32(&hash, layer.operation_count)
		contracts.canonical_hash_append_u32(&hash, layer.speed_scale_ppm)
		contracts.canonical_hash_append_u64(&hash, layer.base_duration_us)
		contracts.canonical_hash_append_u64(&hash, layer.motion_duration_us)
		contracts.canonical_hash_append_u64(&hash, layer.dwell_duration_us)
		contracts.canonical_hash_append_u64(&hash, layer.planned_duration_us)
	}
	contracts.canonical_hash_append_u64(
		&hash,
		u64(len(result.operations)),
	)
	for operation in result.operations {
		contracts.canonical_hash_append_stable_id(
			&hash,
			operation.stable_id,
		)
		contracts.canonical_hash_append_stable_id(
			&hash,
			operation.source_move_id,
		)
		contracts.canonical_hash_append_u32(
			&hash,
			operation.source_move_index,
		)
		contracts.canonical_hash_append_stable_id(
			&hash,
			operation.path_id,
		)
		contracts.canonical_hash_append_u32(&hash, operation.layer_index)
		contracts.canonical_hash_append_u8(&hash, u8(operation.kind))
		contracts.canonical_hash_append_u8(&hash, u8(operation.role))
		contracts.canonical_hash_append_i64(
			&hash,
			i64(operation.point_a.x),
		)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(operation.point_a.y),
		)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(operation.point_b.x),
		)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(operation.point_b.y),
		)
		contracts.canonical_hash_append_i64(&hash, i64(operation.speed))
		contracts.canonical_hash_append_i64(
			&hash,
			i64(operation.acceleration),
		)
		contracts.canonical_hash_append_u32(
			&hash,
			u32(operation.fan_ratio),
		)
		contracts.canonical_hash_append_i128(
			&hash,
			operation.filament_delta_nm,
		)
		contracts.canonical_hash_append_u64(&hash, operation.duration_us)
		contracts.canonical_hash_append_u8(
			&hash,
			u8(operation.crosses_exterior),
		)
	}
	return contracts.canonical_hash_final(&hash), true
}
