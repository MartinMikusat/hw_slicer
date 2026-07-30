package features

import contracts "../contracts"
import geometry "../geometry"

FEATURE_PIPELINE_REQUEST_SCHEMA_VERSION :: u32(1)
CPU_PATH_PLAN_PROVIDER_NAME              :: "cpu-canonical-nearest"
CPU_PATH_PLAN_PROVIDER_VERSION           :: contracts.Semantic_Version{0, 1, 0}

Feature_Pipeline_Request :: struct {
	schema_version:           u32,
	spine_request_hash:       contracts.Content_Hash,
	surface:                  Surface_Config,
	perimeter:                Perimeter_Config,
	infill:                   Infill_Config,
	path_plan:                Path_Plan_Config,
	polygon_provider_name:    string,
	polygon_provider_version: contracts.Semantic_Version,
	path_plan_provider:       contracts.Provider_Descriptor,
}

cpu_path_plan_provider_descriptor :: proc() -> contracts.Provider_Descriptor {
	provider, ok := contracts.provider_descriptor_make(
		CPU_PATH_PLAN_PROVIDER_NAME,
		CPU_PATH_PLAN_PROVIDER_VERSION,
		.Plan_Paths,
	)
	assert(ok)
	return provider
}

feature_pipeline_request_hash :: proc(
	request: Feature_Pipeline_Request,
) -> (contracts.Content_Hash, bool) {
	if request.schema_version != FEATURE_PIPELINE_REQUEST_SCHEMA_VERSION ||
	   !feature_request_hash_nonzero(request.spine_request_hash) ||
	   !surface_config_valid(request.surface) ||
	   !perimeter_config_valid(request.perimeter) ||
	   !infill_config_valid(request.infill) ||
	   geometry.point_2_validate({
	   	request.path_plan.start.x,
	   	request.path_plan.start.y,
	   }) != .None ||
	   request.surface.topology_policy !=
	   	request.perimeter.topology_policy ||
	   request.surface.topology_policy !=
	   	request.infill.topology_policy ||
	   !contracts.provider_name_valid(request.polygon_provider_name) ||
	   request.polygon_provider_version.major == 0 &&
	   	request.polygon_provider_version.minor == 0 &&
	   	request.polygon_provider_version.patch == 0 ||
	   !contracts.provider_descriptor_valid(request.path_plan_provider) ||
	   request.path_plan_provider.stage != .Plan_Paths {
		return {}, false
	}

	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/feature-pipeline-request",
		FEATURE_PIPELINE_REQUEST_SCHEMA_VERSION,
	)
	contracts.canonical_hash_append_content_hash(
		&hash,
		request.spine_request_hash,
	)
	contracts.canonical_hash_append_u8(
		&hash,
		u8(request.surface.fill_rule),
	)
	contracts.canonical_hash_append_u32(
		&hash,
		u32(request.surface.topology_policy),
	)
	contracts.canonical_hash_append_u32(&hash, request.perimeter.count)
	contracts.canonical_hash_append_i64(
		&hash,
		i64(request.perimeter.line_width),
	)
	contracts.canonical_hash_append_u32(
		&hash,
		u32(request.perimeter.topology_policy),
	)
	contracts.canonical_hash_append_u8(
		&hash,
		u8(request.perimeter.join_type),
	)
	contracts.canonical_hash_append_f64_bits(
		&hash,
		request.perimeter.miter_limit,
	)
	contracts.canonical_hash_append_f64_bits(
		&hash,
		request.perimeter.arc_tolerance,
	)
	contracts.canonical_hash_append_i64(
		&hash,
		i64(request.infill.spacing),
	)
	contracts.canonical_hash_append_i64(
		&hash,
		i64(request.infill.boundary_inset),
	)
	contracts.canonical_hash_append_i64(
		&hash,
		i64(request.infill.phase),
	)
	contracts.canonical_hash_append_u8(&hash, u8(request.infill.base_axis))
	contracts.canonical_hash_append_u8(
		&hash,
		u8(request.infill.alternate_each_layer),
	)
	contracts.canonical_hash_append_u32(
		&hash,
		u32(request.infill.topology_policy),
	)
	contracts.canonical_hash_append_u8(
		&hash,
		u8(request.infill.join_type),
	)
	contracts.canonical_hash_append_f64_bits(
		&hash,
		request.infill.miter_limit,
	)
	contracts.canonical_hash_append_f64_bits(
		&hash,
		request.infill.arc_tolerance,
	)
	contracts.canonical_hash_append_i64(
		&hash,
		i64(request.path_plan.start.x),
	)
	contracts.canonical_hash_append_i64(
		&hash,
		i64(request.path_plan.start.y),
	)
	contracts.canonical_hash_append_u8(
		&hash,
		u8(request.path_plan.inner_perimeters_first),
	)
	contracts.canonical_hash_append_string(
		&hash,
		request.polygon_provider_name,
	)
	contracts.canonical_hash_append_u32(
		&hash,
		u32(request.polygon_provider_version.major),
	)
	contracts.canonical_hash_append_u32(
		&hash,
		u32(request.polygon_provider_version.minor),
	)
	contracts.canonical_hash_append_u32(
		&hash,
		u32(request.polygon_provider_version.patch),
	)
	contracts.canonical_hash_append_stable_id(
		&hash,
		request.path_plan_provider.id,
	)
	return contracts.canonical_hash_final(&hash), true
}

feature_request_hash_nonzero :: proc(hash: contracts.Content_Hash) -> bool {
	for byte in hash {
		if byte != 0 {return true}
	}
	return false
}
