package features

import contracts "../contracts"
import polygon "../polygon"
import profiles "../profiles"

MOTION_PLAN_ARTIFACT_SCHEMA_VERSION :: u32(1)
MOTION_PLAN_ARTIFACT_HEADER_SIZE    :: u32(288)
MOTION_PLAN_ARTIFACT_DEPENDENCY_SIZE :: u32(48)
MOTION_PLAN_ARTIFACT_LAYER_SIZE     :: u32(72)
MOTION_PLAN_ARTIFACT_OPERATION_SIZE :: u32(128)
MOTION_PLAN_ARTIFACT_FORMAT         :: "hws-motion-plan-le"

MOTION_PLAN_ARTIFACT_MAGIC :: [8]u8{
	'H', 'W', 'S', 'M', 'O', 'T', 'N', '\n',
}

Motion_Plan_Artifact_Limits :: struct {
	max_layers:     u64,
	max_operations: u64,
	max_bytes:      u64,
}

DEFAULT_MOTION_PLAN_ARTIFACT_LIMITS :: Motion_Plan_Artifact_Limits{
	max_layers = 10_000_000,
	max_operations = 100_000_000,
	max_bytes = 2*1024*1024*1024,
}

Motion_Plan_Artifact :: struct {
	dependencies: Motion_Plan_Hash_Dependencies,
	result_hash:  contracts.Content_Hash,
	result:       Motion_Plan_Result,
}

Motion_Plan_Artifact_Summary :: struct {
	layer_count:               u64,
	operation_count:           u64,
	byte_count:                u64,
	retraction_count:          u64,
	travel_count:              u64,
	extrusion_count:           u64,
	dwell_count:               u64,
	total_motion_duration_us:  u64,
	total_dwell_duration_us:   u64,
	total_planned_duration_us: u64,
}

Motion_Plan_Artifact_Error :: enum u8 {
	None,
	Invalid_Record,
	Unsupported_Version,
	Malformed,
	Limit,
	Allocation_Failed,
	Hash_Mismatch,
}

motion_plan_artifact_encode :: proc(
	path_plan_hash, extrusion_hash: contracts.Content_Hash,
	layer_ids: []contracts.Stable_ID,
	layer_z: []contracts.Micrometres,
	model_layers: []polygon.Polygon_Set,
	plan: Unified_Path_Plan_Result,
	extrusion: Extrusion_Result,
	profile: profiles.Resolved_Profiles,
	result: Motion_Plan_Result,
	limits := DEFAULT_MOTION_PLAN_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> ([]u8, Motion_Plan_Artifact_Error) {
	result_hash, result_ok := motion_plan_result_hash(
		path_plan_hash,
		extrusion_hash,
		layer_ids,
		layer_z,
		model_layers,
		plan,
		extrusion,
		profile,
		result,
		DEFAULT_MOTION_PLAN_LIMITS,
		allocator,
	)
	if !result_ok {return nil, .Invalid_Record}
	dependencies, dependencies_ok := motion_plan_hash_dependencies_make(
		path_plan_hash,
		extrusion_hash,
		layer_ids,
		layer_z,
		model_layers,
		profile,
		allocator,
	)
	if !dependencies_ok {return nil, .Invalid_Record}
	defer motion_plan_hash_dependencies_destroy(&dependencies, allocator)
	layer_count := u64(len(result.layers))
	operation_count := u64(len(result.operations))
	byte_count, size_ok :=
		motion_plan_artifact_byte_count(layer_count, operation_count)
	counts_fit := motion_plan_artifact_counts_fit_limits(
		layer_count,
		operation_count,
		byte_count,
		limits,
	)
	if !size_ok || !counts_fit ||
	   byte_count > u64(max(int)) {
		return nil, .Limit
	}
	bytes := make([]u8, int(byte_count), allocator)
	if bytes == nil {return nil, .Allocation_Failed}
	for byte, byte_index in MOTION_PLAN_ARTIFACT_MAGIC {
		bytes[byte_index] = byte
	}
	motion_plan_artifact_put_u32(
		bytes,
		8,
		MOTION_PLAN_ARTIFACT_SCHEMA_VERSION,
	)
	motion_plan_artifact_put_u32(
		bytes,
		12,
		MOTION_PLAN_ARTIFACT_HEADER_SIZE,
	)
	motion_plan_artifact_put_u32(
		bytes,
		16,
		MOTION_PLAN_ARTIFACT_DEPENDENCY_SIZE,
	)
	motion_plan_artifact_put_u32(
		bytes,
		20,
		MOTION_PLAN_ARTIFACT_LAYER_SIZE,
	)
	motion_plan_artifact_put_u32(
		bytes,
		24,
		MOTION_PLAN_ARTIFACT_OPERATION_SIZE,
	)
	motion_plan_artifact_put_u32(
		bytes,
		28,
		SCHEMA_VERSION_MOTION_PLAN_HASH,
	)
	motion_plan_artifact_put_hash(
		bytes,
		32,
		dependencies.path_plan_hash,
	)
	motion_plan_artifact_put_hash(
		bytes,
		64,
		dependencies.extrusion_hash,
	)
	motion_plan_artifact_put_hash(
		bytes,
		96,
		dependencies.printer_hash,
	)
	motion_plan_artifact_put_hash(
		bytes,
		128,
		dependencies.process_hash,
	)
	motion_plan_artifact_put_hash(bytes, 160, result_hash)
	motion_plan_artifact_put_u64(bytes, 192, layer_count)
	motion_plan_artifact_put_u64(bytes, 200, layer_count)
	motion_plan_artifact_put_u64(bytes, 208, operation_count)
	motion_plan_artifact_put_u64(bytes, 216, result.retraction_count)
	motion_plan_artifact_put_u64(bytes, 224, result.travel_count)
	motion_plan_artifact_put_u64(bytes, 232, result.extrusion_count)
	motion_plan_artifact_put_u64(bytes, 240, result.dwell_count)
	motion_plan_artifact_put_u64(
		bytes,
		248,
		result.total_motion_duration_us,
	)
	motion_plan_artifact_put_u64(
		bytes,
		256,
		result.total_dwell_duration_us,
	)
	motion_plan_artifact_put_u64(
		bytes,
		264,
		result.total_planned_duration_us,
	)
	offset := int(MOTION_PLAN_ARTIFACT_HEADER_SIZE)
	for dependency in dependencies.layers {
		motion_plan_artifact_put_u64(
			bytes,
			offset,
			u64(dependency.stable_id),
		)
		motion_plan_artifact_put_i64(bytes, offset+8, i64(dependency.z))
		motion_plan_artifact_put_hash(
			bytes,
			offset+16,
			dependency.model_hash,
		)
		offset += int(MOTION_PLAN_ARTIFACT_DEPENDENCY_SIZE)
	}
	for layer in result.layers {
		motion_plan_artifact_put_u64(
			bytes,
			offset,
			u64(layer.stable_id),
		)
		motion_plan_artifact_put_u32(bytes, offset+8, layer.layer_index)
		motion_plan_artifact_put_u32(
			bytes,
			offset+12,
			layer.operation_count,
		)
		motion_plan_artifact_put_i64(bytes, offset+16, i64(layer.z))
		motion_plan_artifact_put_u64(
			bytes,
			offset+24,
			layer.operation_offset,
		)
		motion_plan_artifact_put_u32(
			bytes,
			offset+32,
			layer.speed_scale_ppm,
		)
		motion_plan_artifact_put_u64(
			bytes,
			offset+40,
			layer.base_duration_us,
		)
		motion_plan_artifact_put_u64(
			bytes,
			offset+48,
			layer.motion_duration_us,
		)
		motion_plan_artifact_put_u64(
			bytes,
			offset+56,
			layer.dwell_duration_us,
		)
		motion_plan_artifact_put_u64(
			bytes,
			offset+64,
			layer.planned_duration_us,
		)
		offset += int(MOTION_PLAN_ARTIFACT_LAYER_SIZE)
	}
	for operation in result.operations {
		motion_plan_artifact_put_u64(
			bytes,
			offset,
			u64(operation.stable_id),
		)
		motion_plan_artifact_put_u64(
			bytes,
			offset+8,
			u64(operation.source_move_id),
		)
		motion_plan_artifact_put_u64(
			bytes,
			offset+16,
			u64(operation.path_id),
		)
		motion_plan_artifact_put_u32(
			bytes,
			offset+24,
			operation.source_move_index,
		)
		motion_plan_artifact_put_u32(
			bytes,
			offset+28,
			operation.layer_index,
		)
		bytes[offset+32] = u8(operation.kind)
		bytes[offset+33] = u8(operation.role)
		if operation.crosses_exterior {bytes[offset+34] = 1}
		motion_plan_artifact_put_i64(
			bytes,
			offset+40,
			i64(operation.point_a.x),
		)
		motion_plan_artifact_put_i64(
			bytes,
			offset+48,
			i64(operation.point_a.y),
		)
		motion_plan_artifact_put_i64(
			bytes,
			offset+56,
			i64(operation.point_b.x),
		)
		motion_plan_artifact_put_i64(
			bytes,
			offset+64,
			i64(operation.point_b.y),
		)
		motion_plan_artifact_put_i64(
			bytes,
			offset+72,
			i64(operation.speed),
		)
		motion_plan_artifact_put_i64(
			bytes,
			offset+80,
			i64(operation.acceleration),
		)
		motion_plan_artifact_put_u32(
			bytes,
			offset+88,
			u32(operation.fan_ratio),
		)
		motion_plan_artifact_put_i128(
			bytes,
			offset+96,
			operation.filament_delta_nm,
		)
		motion_plan_artifact_put_u64(
			bytes,
			offset+112,
			operation.duration_us,
		)
		offset += int(MOTION_PLAN_ARTIFACT_OPERATION_SIZE)
	}
	return bytes, .None
}

motion_plan_artifact_decode :: proc(
	bytes: []u8,
	limits := DEFAULT_MOTION_PLAN_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> (Motion_Plan_Artifact, Motion_Plan_Artifact_Error) {
	summary, preflight_error :=
		motion_plan_artifact_preflight(bytes, limits)
	if preflight_error != .None {return {}, preflight_error}
	artifact: Motion_Plan_Artifact
	motion_plan_artifact_get_hash(
		bytes,
		32,
		&artifact.dependencies.path_plan_hash,
	)
	motion_plan_artifact_get_hash(
		bytes,
		64,
		&artifact.dependencies.extrusion_hash,
	)
	motion_plan_artifact_get_hash(
		bytes,
		96,
		&artifact.dependencies.printer_hash,
	)
	motion_plan_artifact_get_hash(
		bytes,
		128,
		&artifact.dependencies.process_hash,
	)
	motion_plan_artifact_get_hash(bytes, 160, &artifact.result_hash)
	artifact.dependencies.layers = make(
		[]Motion_Plan_Layer_Dependency,
		int(summary.layer_count),
		allocator,
	)
	artifact.result.layers = make(
		[]Motion_Layer,
		int(summary.layer_count),
		allocator,
	)
	artifact.result.operations = make(
		[]Motion_Operation,
		int(summary.operation_count),
		allocator,
	)
	if summary.layer_count > 0 &&
	   (artifact.dependencies.layers == nil ||
	    artifact.result.layers == nil) ||
	   summary.operation_count > 0 && artifact.result.operations == nil {
		motion_plan_artifact_destroy(&artifact, allocator)
		return {}, .Allocation_Failed
	}
	artifact.result.retraction_count = summary.retraction_count
	artifact.result.travel_count = summary.travel_count
	artifact.result.extrusion_count = summary.extrusion_count
	artifact.result.dwell_count = summary.dwell_count
	artifact.result.total_motion_duration_us =
		summary.total_motion_duration_us
	artifact.result.total_dwell_duration_us =
		summary.total_dwell_duration_us
	artifact.result.total_planned_duration_us =
		summary.total_planned_duration_us
	offset := int(MOTION_PLAN_ARTIFACT_HEADER_SIZE)
	for &dependency in artifact.dependencies.layers {
		dependency.stable_id = contracts.Stable_ID(
			motion_plan_artifact_get_u64(bytes, offset),
		)
		dependency.z = contracts.Micrometres(
			motion_plan_artifact_get_i64(bytes, offset+8),
		)
		motion_plan_artifact_get_hash(
			bytes,
			offset+16,
			&dependency.model_hash,
		)
		offset += int(MOTION_PLAN_ARTIFACT_DEPENDENCY_SIZE)
	}
	for &layer in artifact.result.layers {
		if !motion_plan_artifact_bytes_zero(bytes, offset+36, offset+40) {
			motion_plan_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		layer.stable_id = contracts.Stable_ID(
			motion_plan_artifact_get_u64(bytes, offset),
		)
		layer.layer_index =
			motion_plan_artifact_get_u32(bytes, offset+8)
		layer.operation_count =
			motion_plan_artifact_get_u32(bytes, offset+12)
		layer.z = contracts.Micrometres(
			motion_plan_artifact_get_i64(bytes, offset+16),
		)
		layer.operation_offset =
			motion_plan_artifact_get_u64(bytes, offset+24)
		layer.speed_scale_ppm =
			motion_plan_artifact_get_u32(bytes, offset+32)
		layer.base_duration_us =
			motion_plan_artifact_get_u64(bytes, offset+40)
		layer.motion_duration_us =
			motion_plan_artifact_get_u64(bytes, offset+48)
		layer.dwell_duration_us =
			motion_plan_artifact_get_u64(bytes, offset+56)
		layer.planned_duration_us =
			motion_plan_artifact_get_u64(bytes, offset+64)
		offset += int(MOTION_PLAN_ARTIFACT_LAYER_SIZE)
	}
	for &operation in artifact.result.operations {
		if bytes[offset+34] > 1 ||
		   !motion_plan_artifact_bytes_zero(bytes, offset+35, offset+40) ||
		   !motion_plan_artifact_bytes_zero(bytes, offset+92, offset+96) ||
		   !motion_plan_artifact_bytes_zero(bytes, offset+120, offset+128) {
			motion_plan_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		operation.stable_id = contracts.Stable_ID(
			motion_plan_artifact_get_u64(bytes, offset),
		)
		operation.source_move_id = contracts.Stable_ID(
			motion_plan_artifact_get_u64(bytes, offset+8),
		)
		operation.path_id = contracts.Stable_ID(
			motion_plan_artifact_get_u64(bytes, offset+16),
		)
		operation.source_move_index =
			motion_plan_artifact_get_u32(bytes, offset+24)
		operation.layer_index =
			motion_plan_artifact_get_u32(bytes, offset+28)
		operation.kind =
			transmute(Motion_Operation_Kind)bytes[offset+32]
		operation.role =
			transmute(profiles.Printable_Role)bytes[offset+33]
		operation.crosses_exterior = bytes[offset+34] != 0
		operation.point_a = {
			contracts.Micrometres(
				motion_plan_artifact_get_i64(bytes, offset+40),
			),
			contracts.Micrometres(
				motion_plan_artifact_get_i64(bytes, offset+48),
			),
		}
		operation.point_b = {
			contracts.Micrometres(
				motion_plan_artifact_get_i64(bytes, offset+56),
			),
			contracts.Micrometres(
				motion_plan_artifact_get_i64(bytes, offset+64),
			),
		}
		operation.speed = profiles.Speed_Um_Per_Second(
			motion_plan_artifact_get_i64(bytes, offset+72),
		)
		operation.acceleration =
			profiles.Acceleration_Um_Per_Second_Squared(
				motion_plan_artifact_get_i64(bytes, offset+80),
			)
		operation.fan_ratio = profiles.Ratio_Ppm(
			motion_plan_artifact_get_u32(bytes, offset+88),
		)
		operation.filament_delta_nm =
			motion_plan_artifact_get_i128(bytes, offset+96)
		operation.duration_us =
			motion_plan_artifact_get_u64(bytes, offset+112)
		offset += int(MOTION_PLAN_ARTIFACT_OPERATION_SIZE)
	}
	calculated_hash, result_ok := motion_plan_result_content_hash(
		artifact.dependencies,
		artifact.result,
	)
	if !result_ok {
		motion_plan_artifact_destroy(&artifact, allocator)
		return {}, .Invalid_Record
	}
	if calculated_hash != artifact.result_hash {
		motion_plan_artifact_destroy(&artifact, allocator)
		return {}, .Hash_Mismatch
	}
	return artifact, .None
}

motion_plan_artifact_preflight :: proc(
	bytes: []u8,
	limits := DEFAULT_MOTION_PLAN_ARTIFACT_LIMITS,
) -> (Motion_Plan_Artifact_Summary, Motion_Plan_Artifact_Error) {
	if u64(len(bytes)) > limits.max_bytes {return {}, .Limit}
	if len(bytes) < int(MOTION_PLAN_ARTIFACT_HEADER_SIZE) ||
	   !motion_plan_artifact_magic_valid(bytes) {
		return {}, .Malformed
	}
	if motion_plan_artifact_get_u32(bytes, 8) !=
	   MOTION_PLAN_ARTIFACT_SCHEMA_VERSION {
		return {}, .Unsupported_Version
	}
	header_layout_valid :=
		motion_plan_artifact_get_u32(bytes, 12) ==
			MOTION_PLAN_ARTIFACT_HEADER_SIZE &&
		motion_plan_artifact_get_u32(bytes, 16) ==
			MOTION_PLAN_ARTIFACT_DEPENDENCY_SIZE &&
		motion_plan_artifact_get_u32(bytes, 20) ==
			MOTION_PLAN_ARTIFACT_LAYER_SIZE &&
		motion_plan_artifact_get_u32(bytes, 24) ==
			MOTION_PLAN_ARTIFACT_OPERATION_SIZE &&
		motion_plan_artifact_get_u32(bytes, 28) ==
			SCHEMA_VERSION_MOTION_PLAN_HASH
	if !header_layout_valid ||
	   !motion_plan_artifact_bytes_zero(bytes, 272, 288) {
		return {}, .Malformed
	}
	dependency_count := motion_plan_artifact_get_u64(bytes, 192)
	layer_count := motion_plan_artifact_get_u64(bytes, 200)
	operation_count := motion_plan_artifact_get_u64(bytes, 208)
	byte_count, size_ok :=
		motion_plan_artifact_byte_count(layer_count, operation_count)
	counts_fit := motion_plan_artifact_counts_fit_limits(
		layer_count,
		operation_count,
		byte_count,
		limits,
	)
	if dependency_count != layer_count {return {}, .Malformed}
	if !size_ok || !counts_fit ||
	   layer_count > u64(max(int)) ||
	   operation_count > u64(max(int)) {
		return {}, .Limit
	}
	if byte_count != u64(len(bytes)) {return {}, .Malformed}
	return {
		layer_count = layer_count,
		operation_count = operation_count,
		byte_count = byte_count,
		retraction_count = motion_plan_artifact_get_u64(bytes, 216),
		travel_count = motion_plan_artifact_get_u64(bytes, 224),
		extrusion_count = motion_plan_artifact_get_u64(bytes, 232),
		dwell_count = motion_plan_artifact_get_u64(bytes, 240),
		total_motion_duration_us =
			motion_plan_artifact_get_u64(bytes, 248),
		total_dwell_duration_us =
			motion_plan_artifact_get_u64(bytes, 256),
		total_planned_duration_us =
			motion_plan_artifact_get_u64(bytes, 264),
	}, .None
}

motion_plan_artifact_destroy :: proc(
	artifact: ^Motion_Plan_Artifact,
	allocator := context.allocator,
) {
	motion_plan_hash_dependencies_destroy(&artifact.dependencies, allocator)
	motion_plan_result_destroy(&artifact.result, allocator)
	artifact^ = {}
}

motion_plan_artifact_byte_count :: proc(
	layer_count, operation_count: u64,
) -> (u64, bool) {
	result := u64(MOTION_PLAN_ARTIFACT_HEADER_SIZE)
	per_layer_size :=
		u64(MOTION_PLAN_ARTIFACT_DEPENDENCY_SIZE)+
		u64(MOTION_PLAN_ARTIFACT_LAYER_SIZE)
	if layer_count > (max(u64)-result)/per_layer_size {
		return 0, false
	}
	result += layer_count*per_layer_size
	if operation_count >
	   (max(u64)-result)/u64(MOTION_PLAN_ARTIFACT_OPERATION_SIZE) {
		return 0, false
	}
	return result+
		operation_count*u64(MOTION_PLAN_ARTIFACT_OPERATION_SIZE), true
}

motion_plan_artifact_counts_fit_limits :: proc(
	layer_count, operation_count, byte_count: u64,
	limits: Motion_Plan_Artifact_Limits,
) -> bool {
	return layer_count <= limits.max_layers &&
		operation_count <= limits.max_operations &&
		byte_count <= limits.max_bytes
}

motion_plan_artifact_magic_valid :: proc(bytes: []u8) -> bool {
	for byte, byte_index in MOTION_PLAN_ARTIFACT_MAGIC {
		if bytes[byte_index] != byte {return false}
	}
	return true
}

motion_plan_artifact_bytes_zero :: proc(
	bytes: []u8,
	start, end: int,
) -> bool {
	for byte in bytes[start:end] {
		if byte != 0 {return false}
	}
	return true
}

motion_plan_artifact_put_hash :: proc(
	bytes: []u8,
	offset: int,
	hash: contracts.Content_Hash,
) {
	for byte, byte_index in hash {
		bytes[offset+byte_index] = byte
	}
}

motion_plan_artifact_get_hash :: proc(
	bytes: []u8,
	offset: int,
	hash: ^contracts.Content_Hash,
) {
	copy(hash[:], bytes[offset:offset+len(hash)])
}

motion_plan_artifact_put_u32 :: proc(
	bytes: []u8,
	offset: int,
	value: u32,
) {
	for byte_index in 0..<4 {
		bytes[offset+byte_index] = u8(value>>u32(byte_index*8))
	}
}

motion_plan_artifact_put_u64 :: proc(
	bytes: []u8,
	offset: int,
	value: u64,
) {
	for byte_index in 0..<8 {
		bytes[offset+byte_index] = u8(value>>u64(byte_index*8))
	}
}

motion_plan_artifact_put_i64 :: proc(
	bytes: []u8,
	offset: int,
	value: i64,
) {
	motion_plan_artifact_put_u64(bytes, offset, transmute(u64)value)
}

motion_plan_artifact_put_i128 :: proc(
	bytes: []u8,
	offset: int,
	value: i128,
) {
	bits := transmute(u128)value
	motion_plan_artifact_put_u64(bytes, offset, u64(bits))
	motion_plan_artifact_put_u64(bytes, offset+8, u64(bits>>64))
}

motion_plan_artifact_get_u32 :: proc(bytes: []u8, offset: int) -> u32 {
	result: u32
	for byte_index in 0..<4 {
		result |= u32(bytes[offset+byte_index])<<u32(byte_index*8)
	}
	return result
}

motion_plan_artifact_get_u64 :: proc(bytes: []u8, offset: int) -> u64 {
	result: u64
	for byte_index in 0..<8 {
		result |= u64(bytes[offset+byte_index])<<u64(byte_index*8)
	}
	return result
}

motion_plan_artifact_get_i64 :: proc(bytes: []u8, offset: int) -> i64 {
	return transmute(i64)motion_plan_artifact_get_u64(bytes, offset)
}

motion_plan_artifact_get_i128 :: proc(bytes: []u8, offset: int) -> i128 {
	bits :=
		u128(motion_plan_artifact_get_u64(bytes, offset)) |
		u128(motion_plan_artifact_get_u64(bytes, offset+8))<<64
	return transmute(i128)bits
}
