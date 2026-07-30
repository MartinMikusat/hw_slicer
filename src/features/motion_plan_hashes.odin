package features

import contracts "../contracts"
import polygon "../polygon"
import profiles "../profiles"

SCHEMA_VERSION_MOTION_PLAN_HASH :: u32(1)

Motion_Plan_Layer_Dependency :: struct {
	stable_id:  contracts.Stable_ID,
	z:          contracts.Micrometres,
	model_hash: contracts.Content_Hash,
}

Motion_Plan_Hash_Dependencies :: struct {
	path_plan_hash:  contracts.Content_Hash,
	extrusion_hash:  contracts.Content_Hash,
	printer_hash:    contracts.Content_Hash,
	process_hash:    contracts.Content_Hash,
	layers:          []Motion_Plan_Layer_Dependency,
}

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
	dependencies, dependencies_ok := motion_plan_hash_dependencies_make(
		path_plan_hash,
		extrusion_hash,
		layer_ids,
		layer_z,
		model_layers,
		profile,
		allocator,
	)
	if !dependencies_ok {return {}, false}
	defer motion_plan_hash_dependencies_destroy(&dependencies, allocator)
	return motion_plan_result_content_hash(dependencies, result)
}

motion_plan_hash_dependencies_make :: proc(
	path_plan_hash, extrusion_hash: contracts.Content_Hash,
	layer_ids: []contracts.Stable_ID,
	layer_z: []contracts.Micrometres,
	model_layers: []polygon.Polygon_Set,
	profile: profiles.Resolved_Profiles,
	allocator := context.allocator,
) -> (Motion_Plan_Hash_Dependencies, bool) {
	if len(layer_ids) != len(layer_z) ||
	   len(layer_ids) != len(model_layers) {
		return {}, false
	}
	dependencies := Motion_Plan_Hash_Dependencies{
		path_plan_hash = path_plan_hash,
		extrusion_hash = extrusion_hash,
		printer_hash = profiles.printer_profile_hash(profile.printer),
		process_hash = profiles.process_profile_hash(profile.process),
		layers = make(
			[]Motion_Plan_Layer_Dependency,
			len(layer_ids),
			allocator,
		),
	}
	if len(layer_ids) > 0 && dependencies.layers == nil {
		return {}, false
	}
	for &dependency, layer_index in dependencies.layers {
		model_hash, model_ok :=
			polygon.polygon_set_hash(model_layers[layer_index])
		if !model_ok {
			motion_plan_hash_dependencies_destroy(
				&dependencies,
				allocator,
			)
			return {}, false
		}
		dependency = {
			stable_id = layer_ids[layer_index],
			z = layer_z[layer_index],
			model_hash = model_hash,
		}
	}
	return dependencies, true
}

motion_plan_hash_dependencies_destroy :: proc(
	dependencies: ^Motion_Plan_Hash_Dependencies,
	allocator := context.allocator,
) {
	delete(dependencies.layers, allocator)
	dependencies^ = {}
}

motion_plan_result_content_hash :: proc(
	dependencies: Motion_Plan_Hash_Dependencies,
	result: Motion_Plan_Result,
) -> (contracts.Content_Hash, bool) {
	if !motion_plan_result_structurally_valid(dependencies, result) {
		return {}, false
	}
	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/motion-plan",
		SCHEMA_VERSION_MOTION_PLAN_HASH,
	)
	contracts.canonical_hash_append_content_hash(
		&hash,
		dependencies.path_plan_hash,
	)
	contracts.canonical_hash_append_content_hash(
		&hash,
		dependencies.extrusion_hash,
	)
	contracts.canonical_hash_append_content_hash(
		&hash,
		dependencies.printer_hash,
	)
	contracts.canonical_hash_append_content_hash(
		&hash,
		dependencies.process_hash,
	)
	contracts.canonical_hash_append_u64(
		&hash,
		u64(len(dependencies.layers)),
	)
	for dependency in dependencies.layers {
		contracts.canonical_hash_append_stable_id(
			&hash,
			dependency.stable_id,
		)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(dependency.z),
		)
		contracts.canonical_hash_append_content_hash(
			&hash,
			dependency.model_hash,
		)
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

motion_plan_result_structurally_valid :: proc(
	dependencies: Motion_Plan_Hash_Dependencies,
	result: Motion_Plan_Result,
) -> bool {
	if len(dependencies.layers) != len(result.layers) {
		return false
	}
	expected_operation_offset: u64
	retraction_count: u64
	recovery_count: u64
	travel_count: u64
	extrusion_count: u64
	dwell_count: u64
	total_motion: u64
	total_dwell: u64
	total_planned: u64
	for layer, layer_index in result.layers {
		dependency := dependencies.layers[layer_index]
		operation_end :=
			layer.operation_offset+u64(layer.operation_count)
		planned_duration, planned_ok := motion_checked_add_u64(
			layer.motion_duration_us,
			layer.dwell_duration_us,
		)
		if dependency.stable_id == contracts.INVALID_STABLE_ID ||
		   layer.stable_id != dependency.stable_id ||
		   layer.layer_index != u32(layer_index) ||
		   layer.z != dependency.z ||
		   layer.operation_offset != expected_operation_offset ||
		   operation_end < layer.operation_offset ||
		   operation_end > u64(len(result.operations)) ||
		   layer.speed_scale_ppm > profiles.RATIO_SCALE ||
		   layer.motion_duration_us < layer.base_duration_us ||
		   !planned_ok ||
		   layer.planned_duration_us != planned_duration {
			return false
		}
		layer_motion: u64
		layer_dwell: u64
		operation_start_index := int(layer.operation_offset)
		operation_end_index := int(operation_end)
		for operation in
		    result.operations[operation_start_index:operation_end_index] {
			kind_valid :=
				u8(operation.kind) <= u8(Motion_Operation_Kind.Dwell)
			if operation.stable_id == contracts.INVALID_STABLE_ID ||
			   operation.layer_index != u32(layer_index) ||
			   operation.kind == .Invalid ||
			   !kind_valid ||
			   u32(operation.fan_ratio) > profiles.RATIO_SCALE ||
			   operation.duration_us == 0 {
				return false
			}
			switch operation.kind {
			case .Retract:
				source_valid :=
					operation.source_move_id !=
					contracts.INVALID_STABLE_ID
				if !motion_operation_stationary(operation) ||
				   !source_valid ||
				   operation.path_id == contracts.INVALID_STABLE_ID ||
				   operation.role != .Invalid ||
				   i64(operation.speed) <= 0 ||
				   i64(operation.acceleration) <= 0 ||
				   operation.fan_ratio != 0 ||
				   operation.filament_delta_nm >= 0 ||
				   !operation.crosses_exterior {
					return false
				}
				retraction_count += 1
			case .Travel:
				source_valid :=
					operation.source_move_id !=
					contracts.INVALID_STABLE_ID
				if !source_valid ||
				   operation.path_id == contracts.INVALID_STABLE_ID ||
				   operation.role != .Invalid ||
				   operation.point_a == operation.point_b ||
				   i64(operation.speed) <= 0 ||
				   i64(operation.acceleration) <= 0 ||
				   operation.fan_ratio != 0 ||
				   operation.filament_delta_nm != 0 {
					return false
				}
				travel_count += 1
			case .Recover:
				source_valid :=
					operation.source_move_id !=
					contracts.INVALID_STABLE_ID
				if !motion_operation_stationary(operation) ||
				   !source_valid ||
				   operation.path_id == contracts.INVALID_STABLE_ID ||
				   operation.role != .Invalid ||
				   i64(operation.speed) <= 0 ||
				   i64(operation.acceleration) <= 0 ||
				   operation.fan_ratio != 0 ||
				   operation.filament_delta_nm <= 0 ||
				   !operation.crosses_exterior {
					return false
				}
				recovery_count += 1
			case .Extrude:
				source_valid :=
					operation.source_move_id !=
					contracts.INVALID_STABLE_ID
				if !source_valid ||
				   operation.path_id == contracts.INVALID_STABLE_ID ||
				   operation.role == .Invalid ||
				   operation.point_a == operation.point_b ||
				   i64(operation.speed) <= 0 ||
				   i64(operation.acceleration) <= 0 ||
				   operation.filament_delta_nm <= 0 ||
				   operation.crosses_exterior {
					return false
				}
				extrusion_count += 1
			case .Dwell:
				source_absent :=
					operation.source_move_id ==
					contracts.INVALID_STABLE_ID
				if !motion_operation_stationary(operation) ||
				   !source_absent ||
				   operation.path_id != contracts.INVALID_STABLE_ID ||
				   operation.role != .Invalid ||
				   operation.speed != 0 ||
				   operation.acceleration != 0 ||
				   operation.fan_ratio != 0 ||
				   operation.filament_delta_nm != 0 ||
				   operation.crosses_exterior {
					return false
				}
				dwell_count += 1
			case .Invalid:
				return false
			}
			duration_ok: bool
			if operation.kind == .Dwell {
				layer_dwell, duration_ok = motion_checked_add_u64(
					layer_dwell,
					operation.duration_us,
				)
			} else {
				layer_motion, duration_ok = motion_checked_add_u64(
					layer_motion,
					operation.duration_us,
				)
			}
			if !duration_ok {return false}
		}
		if layer_motion != layer.motion_duration_us ||
		   layer_dwell != layer.dwell_duration_us {
			return false
		}
		total_ok: bool
		total_motion, total_ok =
			motion_checked_add_u64(total_motion, layer_motion)
		if total_ok {
			total_dwell, total_ok =
				motion_checked_add_u64(total_dwell, layer_dwell)
		}
		if total_ok {
			total_planned, total_ok =
				motion_checked_add_u64(
					total_planned,
					layer.planned_duration_us,
				)
		}
		if !total_ok {return false}
		expected_operation_offset = operation_end
	}
	return expected_operation_offset == u64(len(result.operations)) &&
		retraction_count == result.retraction_count &&
		recovery_count == result.retraction_count &&
		travel_count == result.travel_count &&
		extrusion_count == result.extrusion_count &&
		dwell_count == result.dwell_count &&
		total_motion == result.total_motion_duration_us &&
		total_dwell == result.total_dwell_duration_us &&
		total_planned == result.total_planned_duration_us
}

motion_operation_stationary :: proc(operation: Motion_Operation) -> bool {
	return operation.point_a == operation.point_b
}
