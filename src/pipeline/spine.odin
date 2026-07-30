package pipeline

import "core:mem"

import contracts "../contracts"
import formats "../formats"
import geometry "../geometry"
import slicing "../slicing"

SLICE_SPINE_REQUEST_SCHEMA_VERSION :: u32(1)

Slice_Spine_Config :: struct {
	source_units:       contracts.Source_Units,
	first_layer_height: contracts.Micrometres,
	layer_height:       contracts.Micrometres,
	max_layer_count:    u32,
}

Slice_Spine_Layer_Config :: struct {
	first_layer_height: contracts.Micrometres,
	layer_height:       contracts.Micrometres,
	max_layer_count:    u32,
}

Slice_Spine_Hashes :: struct {
	request:          contracts.Content_Hash,
	three_mf_scene:   contracts.Content_Hash,
	decoded_mesh:     contracts.Content_Hash,
	canonical_mesh:   contracts.Content_Hash,
	mesh_audit:       contracts.Content_Hash,
	layer_schedule:   contracts.Content_Hash,
	layer_spans:      contracts.Content_Hash,
	intersections:    contracts.Content_Hash,
	primary_snapped:  contracts.Content_Hash,
	planar_ownership: contracts.Content_Hash,
	snapped:          contracts.Content_Hash,
	topology:         contracts.Content_Hash,
}

Slice_Spine_Result :: struct {
	mesh:             geometry.Canonical_Mesh,
	mesh_audit:       geometry.Mesh_Audit_Result,
	schedule:         slicing.Fixed_Layer_Schedule,
	span_index:       slicing.Layer_Span_Index,
	intersections:    slicing.CPU_Intersection_Result,
	primary_snapped:  slicing.Snapped_Segment_Result,
	planar_ownership: slicing.Planar_Ownership_Result,
	snapped:          slicing.Snapped_Segment_Result,
	topology:         slicing.Topology_Result,
	hashes:           Slice_Spine_Hashes,
}

Slice_Spine_Error :: enum u8 {
	None,
	Invalid_Config,
	Decode,
	Three_MF_Package,
	Three_MF_Model,
	Three_MF_Scene_Hash,
	Three_MF_Flatten,
	Decoded_Hash,
	Normalize,
	Mesh_Hash,
	Mesh_Audit,
	Mesh_Audit_Hash,
	Schedule,
	Schedule_Hash,
	Layer_Spans,
	Layer_Span_Hash,
	Intersections,
	Intersection_Hash,
	Snap,
	Snapped_Hash,
	Planar_Ownership,
	Planar_Ownership_Hash,
	Merge,
	Merged_Hash,
	Topology,
	Topology_Hash,
}

slice_spine_binary_stl :: proc(
	bytes: []u8,
	config: Slice_Spine_Config,
	allocator := context.allocator,
) -> (Slice_Spine_Result, Slice_Spine_Error) {
	if config.source_units == .Unspecified ||
	   i64(config.first_layer_height) <= 0 ||
	   i64(config.layer_height) <= 0 ||
	   config.max_layer_count == 0 {
		return {}, .Invalid_Config
	}
	decoded, decode_error := formats.binary_stl_decode(
		bytes,
		config.source_units,
		allocator = allocator,
	)
	if decode_error != .None {return {}, .Decode}
	defer formats.decoded_mesh_destroy(&decoded, allocator)
	return slice_spine_stl_decoded(decoded, config, allocator)
}

slice_spine_ascii_stl :: proc(
	bytes: []u8,
	config: Slice_Spine_Config,
	allocator := context.allocator,
) -> (Slice_Spine_Result, Slice_Spine_Error) {
	if config.source_units == .Unspecified ||
	   i64(config.first_layer_height) <= 0 ||
	   i64(config.layer_height) <= 0 ||
	   config.max_layer_count == 0 {
		return {}, .Invalid_Config
	}
	decoded, decode_error := formats.ascii_stl_decode(
		bytes,
		config.source_units,
		allocator = allocator,
	)
	if decode_error != .None {return {}, .Decode}
	defer formats.decoded_mesh_destroy(&decoded, allocator)
	return slice_spine_stl_decoded(decoded, config, allocator)
}

slice_spine_stl :: proc(
	bytes: []u8,
	config: Slice_Spine_Config,
	allocator := context.allocator,
) -> (Slice_Spine_Result, Slice_Spine_Error) {
	if config.source_units == .Unspecified ||
	   i64(config.first_layer_height) <= 0 ||
	   i64(config.layer_height) <= 0 ||
	   config.max_layer_count == 0 {
		return {}, .Invalid_Config
	}
	decoded, decode_error := formats.stl_decode(
		bytes,
		config.source_units,
		allocator = allocator,
	)
	if decode_error != .None {return {}, .Decode}
	defer formats.decoded_mesh_destroy(&decoded, allocator)
	return slice_spine_stl_decoded(decoded, config, allocator)
}

slice_spine_obj :: proc(
	bytes: []u8,
	config: Slice_Spine_Config,
	allocator := context.allocator,
) -> (Slice_Spine_Result, Slice_Spine_Error) {
	if config.source_units == .Unspecified ||
	   i64(config.first_layer_height) <= 0 ||
	   i64(config.layer_height) <= 0 ||
	   config.max_layer_count == 0 {
		return {}, .Invalid_Config
	}
	decoded, decode_error := formats.obj_decode(
		bytes,
		config.source_units,
		allocator = allocator,
	)
	if decode_error != .None {return {}, .Decode}
	defer formats.obj_decoded_mesh_destroy(&decoded, allocator)
	return slice_spine_stl_decoded(decoded.mesh, config, allocator)
}

slice_spine_mesh :: proc(
	bytes: []u8,
	config: Slice_Spine_Config,
	allocator := context.allocator,
) -> (Slice_Spine_Result, Slice_Spine_Error) {
	if formats.obj_source_likely(bytes) {
		return slice_spine_obj(bytes, config, allocator)
	}
	return slice_spine_stl(bytes, config, allocator)
}

slice_spine_stl_decoded :: proc(
	decoded: formats.Decoded_Mesh,
	config: Slice_Spine_Config,
	allocator: mem.Allocator,
) -> (Slice_Spine_Result, Slice_Spine_Error) {
	decoded_hash, decoded_hash_ok := formats.decoded_mesh_hash(decoded)
	if !decoded_hash_ok {return {}, .Decoded_Hash}
	hashes := Slice_Spine_Hashes{
		request = slice_spine_request_hash(decoded.source, config),
		decoded_mesh = decoded_hash,
	}
	return slice_spine_decoded_mesh(decoded, config, hashes, allocator)
}

slice_spine_three_mf :: proc(
	bytes: []u8,
	config: Slice_Spine_Layer_Config,
	allocator := context.allocator,
) -> (Slice_Spine_Result, Slice_Spine_Error) {
	if i64(config.first_layer_height) <= 0 ||
	   i64(config.layer_height) <= 0 ||
	   config.max_layer_count == 0 {
		return {}, .Invalid_Config
	}
	package_result, package_error := formats.three_mf_package_open(
		bytes,
		allocator = allocator,
	)
	if package_error != .None {return {}, .Three_MF_Package}
	defer formats.three_mf_package_destroy(&package_result, allocator)
	scene, model_error := formats.three_mf_model_decode(
		package_result,
		allocator = allocator,
	)
	if model_error != .None {return {}, .Three_MF_Model}
	defer formats.three_mf_scene_destroy(&scene, allocator)
	scene_hash, scene_hash_ok := formats.three_mf_scene_hash(scene)
	if !scene_hash_ok {return {}, .Three_MF_Scene_Hash}
	flattened, flatten_error := formats.three_mf_scene_flatten(
		scene,
		allocator = allocator,
	)
	if flatten_error != .None {return {}, .Three_MF_Flatten}
	defer formats.three_mf_flattened_mesh_destroy(&flattened, allocator)
	decoded_hash, decoded_hash_ok :=
		formats.decoded_mesh_hash(flattened.mesh)
	if !decoded_hash_ok {return {}, .Decoded_Hash}
	spine_config := Slice_Spine_Config{
		source_units = scene.source.units,
		first_layer_height = config.first_layer_height,
		layer_height = config.layer_height,
		max_layer_count = config.max_layer_count,
	}
	hashes := Slice_Spine_Hashes{
		request = slice_spine_three_mf_request_hash(
			scene.source,
			config,
		),
		three_mf_scene = scene_hash,
		decoded_mesh = decoded_hash,
	}
	return slice_spine_decoded_mesh(
		flattened.mesh,
		spine_config,
		hashes,
		allocator,
	)
}

slice_spine_decoded_mesh :: proc(
	decoded: formats.Decoded_Mesh,
	config: Slice_Spine_Config,
	hashes: Slice_Spine_Hashes,
	allocator: mem.Allocator,
) -> (Slice_Spine_Result, Slice_Spine_Error) {
	result := Slice_Spine_Result{hashes = hashes}
	normalize_error: geometry.Normalize_Error
	result.mesh, normalize_error = geometry.mesh_normalize_units(
		decoded,
		allocator,
	)
	if normalize_error != .None {
		slice_spine_result_destroy(&result, allocator)
		return {}, .Normalize
	}
	mesh_hash_ok: bool
	result.hashes.canonical_mesh, mesh_hash_ok =
		geometry.canonical_mesh_hash(result.mesh)
	if !mesh_hash_ok {
		slice_spine_result_destroy(&result, allocator)
		return {}, .Mesh_Hash
	}
	audit_error: geometry.Mesh_Audit_Error
	result.mesh_audit, audit_error = geometry.mesh_audit(
		result.mesh,
		allocator = allocator,
	)
	if audit_error != .None {
		slice_spine_result_destroy(&result, allocator)
		return {}, .Mesh_Audit
	}
	audit_hash_ok: bool
	result.hashes.mesh_audit, audit_hash_ok = geometry.mesh_audit_hash(
		result.hashes.canonical_mesh,
		result.mesh_audit,
	)
	if !audit_hash_ok {
		slice_spine_result_destroy(&result, allocator)
		return {}, .Mesh_Audit_Hash
	}

	minimum_z, minimum_error :=
		geometry.millimetres_to_micrometres_quantized(
			result.mesh.bounds.minimum.z,
			.Floor,
		)
	maximum_z, maximum_error :=
		geometry.millimetres_to_micrometres_quantized(
			result.mesh.bounds.maximum.z,
			.Ceil,
		)
	if minimum_error != .None || maximum_error != .None {
		slice_spine_result_destroy(&result, allocator)
		return {}, .Schedule
	}
	first_plane_128 := i128(i64(minimum_z))+
		i128(i64(config.first_layer_height))
	if first_plane_128 > i128(max(i64)) {
		slice_spine_result_destroy(&result, allocator)
		return {}, .Schedule
	}
	schedule_error: slicing.Schedule_Error
	result.schedule, schedule_error = slicing.fixed_layer_schedule_build(
		{
			request_hash = result.hashes.request,
			minimum_z = minimum_z,
			maximum_z = maximum_z,
			first_plane_z = contracts.Micrometres(i64(first_plane_128)),
			layer_step = config.layer_height,
			max_layer_count = config.max_layer_count,
		},
		allocator,
	)
	if schedule_error != .None {
		slice_spine_result_destroy(&result, allocator)
		return {}, .Schedule
	}
	schedule_hash_ok: bool
	result.hashes.layer_schedule, schedule_hash_ok =
		slicing.fixed_layer_schedule_hash(result.schedule)
	if !schedule_hash_ok {
		slice_spine_result_destroy(&result, allocator)
		return {}, .Schedule_Hash
	}

	span_error: slicing.Layer_Span_Error
	result.span_index, span_error = slicing.layer_span_index_build(
		result.mesh,
		result.schedule,
		allocator = allocator,
	)
	if span_error != .None {
		slice_spine_result_destroy(&result, allocator)
		return {}, .Layer_Spans
	}
	span_hash_ok: bool
	result.hashes.layer_spans, span_hash_ok = slicing.layer_span_index_hash(
		result.hashes.layer_schedule,
		result.span_index,
	)
	if !span_hash_ok {
		slice_spine_result_destroy(&result, allocator)
		return {}, .Layer_Span_Hash
	}

	intersection_error: slicing.CPU_Intersection_Error
	result.intersections, intersection_error =
		slicing.cpu_intersections_build(
			result.mesh,
			result.schedule,
			result.span_index,
			allocator = allocator,
		)
	if intersection_error != .None {
		slice_spine_result_destroy(&result, allocator)
		return {}, .Intersections
	}
	intersection_hash_ok: bool
	result.hashes.intersections, intersection_hash_ok =
		slicing.cpu_intersection_result_hash(
			result.hashes.layer_spans,
			result.intersections,
		)
	if !intersection_hash_ok {
		slice_spine_result_destroy(&result, allocator)
		return {}, .Intersection_Hash
	}

	snap_error: slicing.Snapped_Segment_Error
	result.primary_snapped, snap_error = slicing.snapped_segments_build(
		result.intersections,
		allocator,
	)
	if snap_error != .None {
		slice_spine_result_destroy(&result, allocator)
		return {}, .Snap
	}
	snapped_hash_ok: bool
	result.hashes.primary_snapped, snapped_hash_ok =
		slicing.snapped_segment_result_hash(
			result.hashes.intersections,
			result.primary_snapped,
		)
	if !snapped_hash_ok {
		slice_spine_result_destroy(&result, allocator)
		return {}, .Snapped_Hash
	}

	planar_error: slicing.Planar_Ownership_Error
	result.planar_ownership, planar_error =
		slicing.planar_ownership_resolve(
			result.mesh,
			result.schedule,
			result.intersections,
			allocator = allocator,
		)
	if planar_error != .None {
		slice_spine_result_destroy(&result, allocator)
		return {}, .Planar_Ownership
	}
	planar_hash_ok: bool
	result.hashes.planar_ownership, planar_hash_ok =
		slicing.planar_ownership_result_hash(
			result.hashes.intersections,
			result.planar_ownership,
		)
	if !planar_hash_ok {
		slice_spine_result_destroy(&result, allocator)
		return {}, .Planar_Ownership_Hash
	}
	owned_segments := slicing.Snapped_Segment_Result{
		layers = result.planar_ownership.layers,
		segments = result.planar_ownership.segments,
	}
	result.snapped, snap_error = slicing.snapped_segments_merge(
		result.primary_snapped,
		owned_segments,
		allocator,
	)
	if snap_error != .None {
		slice_spine_result_destroy(&result, allocator)
		return {}, .Merge
	}
	result.hashes.snapped, snapped_hash_ok =
		slicing.snapped_segment_result_hash(
			result.hashes.planar_ownership,
			result.snapped,
		)
	if !snapped_hash_ok {
		slice_spine_result_destroy(&result, allocator)
		return {}, .Merged_Hash
	}

	topology_error: slicing.Topology_Error
	result.topology, topology_error = slicing.topology_reconstruct(
		result.schedule,
		result.snapped,
		allocator = allocator,
	)
	if topology_error != .None {
		slice_spine_result_destroy(&result, allocator)
		return {}, .Topology
	}
	topology_hash_ok: bool
	result.hashes.topology, topology_hash_ok = slicing.topology_result_hash(
		result.hashes.snapped,
		len(result.snapped.segments.segment_ids),
		result.topology,
	)
	if !topology_hash_ok {
		slice_spine_result_destroy(&result, allocator)
		return {}, .Topology_Hash
	}
	return result, .None
}

slice_spine_request_hash :: proc(
	source: contracts.Source_Asset,
	config: Slice_Spine_Config,
) -> contracts.Content_Hash {
	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/binary-stl-spine-request",
		SLICE_SPINE_REQUEST_SCHEMA_VERSION,
	)
	contracts.canonical_hash_append_content_hash(&hash, source.content_hash)
	contracts.canonical_hash_append_u64(&hash, source.byte_count)
	contracts.canonical_hash_append_u8(&hash, u8(source.format))
	contracts.canonical_hash_append_u8(&hash, u8(config.source_units))
	contracts.canonical_hash_append_i64(
		&hash,
		i64(config.first_layer_height),
	)
	contracts.canonical_hash_append_i64(&hash, i64(config.layer_height))
	contracts.canonical_hash_append_u32(&hash, config.max_layer_count)
	return contracts.canonical_hash_final(&hash)
}

slice_spine_three_mf_request_hash :: proc(
	source: contracts.Source_Asset,
	config: Slice_Spine_Layer_Config,
) -> contracts.Content_Hash {
	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/three-mf-spine-request",
		SLICE_SPINE_REQUEST_SCHEMA_VERSION,
	)
	contracts.canonical_hash_append_content_hash(&hash, source.content_hash)
	contracts.canonical_hash_append_u64(&hash, source.byte_count)
	contracts.canonical_hash_append_u8(&hash, u8(source.format))
	contracts.canonical_hash_append_u8(&hash, u8(source.units))
	contracts.canonical_hash_append_i64(
		&hash,
		i64(config.first_layer_height),
	)
	contracts.canonical_hash_append_i64(&hash, i64(config.layer_height))
	contracts.canonical_hash_append_u32(&hash, config.max_layer_count)
	return contracts.canonical_hash_final(&hash)
}

slice_spine_result_destroy :: proc(
	result: ^Slice_Spine_Result,
	allocator := context.allocator,
) {
	slicing.topology_result_destroy(&result.topology, allocator)
	slicing.snapped_segments_destroy(&result.snapped, allocator)
	slicing.planar_ownership_destroy(&result.planar_ownership, allocator)
	slicing.snapped_segments_destroy(&result.primary_snapped, allocator)
	slicing.cpu_intersections_destroy(&result.intersections, allocator)
	slicing.layer_span_index_destroy(&result.span_index, allocator)
	slicing.fixed_layer_schedule_destroy(&result.schedule, allocator)
	geometry.mesh_audit_result_destroy(&result.mesh_audit, allocator)
	geometry.canonical_mesh_destroy(&result.mesh, allocator)
	result^ = {}
}
