package evidence

import "core:encoding/json"

import contracts "../contracts"

EVIDENCE_BUNDLE_SCHEMA_VERSION :: u32(1)
EVIDENCE_BUNDLE_MANIFEST_BYTE_LIMIT :: u64(1024*1024)
EVIDENCE_BUNDLE_SUMMARY_BYTE_LIMIT :: u64(1024*1024)
EVIDENCE_STAGE_MANIFEST_BYTE_LIMIT :: u64(1024*1024)

Evidence_Bundle_Stage :: struct {
	ordinal:  u32,
	stage:    Evidence_Stage,
	provider: Evidence_Provider,
	manifest: Evidence_Artifact,
}

Evidence_Bundle_Manifest :: struct {
	schema_version: u32,
	request_hash:   string,
	source_root_id: string,
	summary:        Evidence_Artifact,
	stages:         []Evidence_Bundle_Stage,
	files:          []Evidence_Artifact,
}

Evidence_Bundle_Summary :: struct {
	schema_version: u32,
	request_hash:   string,
	source_root_id: string,
	stage_count:    u64,
	file_count:     u64,
}

Evidence_Bundle_Error :: enum u8 {
	None,
	Encode_Failed,
	Decode_Failed,
	Unsupported_Version,
	Invalid_Record,
	Byte_Limit,
}

evidence_bundle_manifest_encode :: proc(
	manifest: Evidence_Bundle_Manifest,
	allocator := context.allocator,
) -> ([]u8, Evidence_Bundle_Error) {
	if manifest.schema_version != EVIDENCE_BUNDLE_SCHEMA_VERSION {
		return nil, .Unsupported_Version
	}
	if !evidence_bundle_manifest_valid(manifest) {
		return nil, .Invalid_Record
	}
	bytes, error := json.marshal(
		manifest,
		{
			pretty = true,
			use_spaces = true,
			spaces = 2,
			sort_maps_by_key = true,
			use_enum_names = true,
		},
		allocator,
	)
	if error != nil {return nil, .Encode_Failed}
	if u64(len(bytes)+1) > EVIDENCE_BUNDLE_MANIFEST_BYTE_LIMIT {
		delete(bytes, allocator)
		return nil, .Byte_Limit
	}
	result := make([]u8, len(bytes)+1, allocator)
	if result == nil {
		delete(bytes, allocator)
		return nil, .Encode_Failed
	}
	copy(result, bytes)
	result[len(bytes)] = '\n'
	delete(bytes, allocator)
	return result, .None
}

evidence_bundle_manifest_decode :: proc(
	bytes: []u8,
	allocator := context.allocator,
) -> (Evidence_Bundle_Manifest, Evidence_Bundle_Error) {
	if u64(len(bytes)) > EVIDENCE_BUNDLE_MANIFEST_BYTE_LIMIT {
		return {}, .Byte_Limit
	}
	manifest: Evidence_Bundle_Manifest
	if error := json.unmarshal(bytes, &manifest, .JSON, allocator); error != nil {
		evidence_bundle_manifest_destroy(&manifest, allocator)
		return {}, .Decode_Failed
	}
	if manifest.schema_version != EVIDENCE_BUNDLE_SCHEMA_VERSION {
		evidence_bundle_manifest_destroy(&manifest, allocator)
		return {}, .Unsupported_Version
	}
	if !evidence_bundle_manifest_valid(manifest) {
		evidence_bundle_manifest_destroy(&manifest, allocator)
		return {}, .Invalid_Record
	}
	return manifest, .None
}

evidence_bundle_summary_encode :: proc(
	summary: Evidence_Bundle_Summary,
	allocator := context.allocator,
) -> ([]u8, Evidence_Bundle_Error) {
	if summary.schema_version != EVIDENCE_BUNDLE_SCHEMA_VERSION {
		return nil, .Unsupported_Version
	}
	if !evidence_bundle_summary_valid(summary) {
		return nil, .Invalid_Record
	}
	bytes, error := json.marshal(
		summary,
		{
			pretty = true,
			use_spaces = true,
			spaces = 2,
			sort_maps_by_key = true,
		},
		allocator,
	)
	if error != nil {return nil, .Encode_Failed}
	if u64(len(bytes)+1) > EVIDENCE_BUNDLE_SUMMARY_BYTE_LIMIT {
		delete(bytes, allocator)
		return nil, .Byte_Limit
	}
	result := make([]u8, len(bytes)+1, allocator)
	if result == nil {
		delete(bytes, allocator)
		return nil, .Encode_Failed
	}
	copy(result, bytes)
	result[len(bytes)] = '\n'
	delete(bytes, allocator)
	return result, .None
}

evidence_bundle_summary_decode :: proc(
	bytes: []u8,
	allocator := context.allocator,
) -> (Evidence_Bundle_Summary, Evidence_Bundle_Error) {
	if u64(len(bytes)) > EVIDENCE_BUNDLE_SUMMARY_BYTE_LIMIT {
		return {}, .Byte_Limit
	}
	summary: Evidence_Bundle_Summary
	if error := json.unmarshal(bytes, &summary, .JSON, allocator);
	   error != nil {
		evidence_bundle_summary_destroy(&summary, allocator)
		return {}, .Decode_Failed
	}
	if summary.schema_version != EVIDENCE_BUNDLE_SCHEMA_VERSION {
		evidence_bundle_summary_destroy(&summary, allocator)
		return {}, .Unsupported_Version
	}
	if !evidence_bundle_summary_valid(summary) {
		evidence_bundle_summary_destroy(&summary, allocator)
		return {}, .Invalid_Record
	}
	return summary, .None
}

evidence_bundle_summary_valid :: proc(
	summary: Evidence_Bundle_Summary,
) -> bool {
	return summary.schema_version == EVIDENCE_BUNDLE_SCHEMA_VERSION &&
		sha256_text_valid(summary.request_hash) &&
		stable_id_text_valid(summary.source_root_id) &&
		summary.stage_count > 0
}

evidence_bundle_manifest_valid :: proc(
	manifest: Evidence_Bundle_Manifest,
) -> bool {
	if manifest.schema_version != EVIDENCE_BUNDLE_SCHEMA_VERSION ||
	   !sha256_text_valid(manifest.request_hash) ||
	   !stable_id_text_valid(manifest.source_root_id) ||
	   !evidence_artifact_valid(manifest.summary) ||
	   manifest.summary.path != "summary.json" ||
	   manifest.summary.format != "json" ||
	   manifest.summary.schema_version != EVIDENCE_BUNDLE_SCHEMA_VERSION ||
	   manifest.summary.item_count != 1 ||
	   manifest.summary.byte_count == 0 ||
	   manifest.summary.byte_count > EVIDENCE_BUNDLE_SUMMARY_BYTE_LIMIT ||
	   len(manifest.stages) == 0 {
		return false
	}
	for stage, stage_index in manifest.stages {
		stage_kind, stage_ok := evidence_stage_kind_parse(stage.stage.name)
		if !stage_ok ||
		   stage.ordinal != u32(stage_kind) ||
		   stage.stage.schema_version == 0 ||
		   !evidence_provider_valid(stage.provider, stage.stage.name) ||
		   !evidence_artifact_valid(stage.manifest) ||
		   stage.manifest.format != "json" ||
		   stage.manifest.schema_version !=
		   	contracts.SCHEMA_VERSION_DEBUG_EVIDENCE ||
		   stage.manifest.item_count != 1 ||
		   stage.manifest.byte_count == 0 ||
		   stage.manifest.byte_count > EVIDENCE_STAGE_MANIFEST_BYTE_LIMIT ||
		   !evidence_bundle_path_matches_stage(
		   	stage.manifest.path,
		   	stage.ordinal,
		   	stage.stage.name,
		   	"manifest.json",
		   ) {
			return false
		}
		if stage_index > 0 &&
		   manifest.stages[stage_index-1].ordinal >= stage.ordinal {
			return false
		}
		if evidence_bundle_path_used_before(
			manifest,
			stage.manifest.path,
			stage_index,
			0,
		) {
			return false
		}
	}
	for file, file_index in manifest.files {
		owner_count := 0
		for stage in manifest.stages {
			if evidence_bundle_path_matches_stage(
				file.path,
				stage.ordinal,
				stage.stage.name,
				"",
			) {
				owner_count += 1
			}
		}
		if !evidence_artifact_valid(file) ||
		   file.path == "manifest.json" ||
		   owner_count != 1 ||
		   evidence_bundle_path_used_before(
		   	manifest,
		   	file.path,
		   	len(manifest.stages),
		   	file_index,
		   ) {
			return false
		}
	}
	return true
}

evidence_bundle_path_matches_stage :: proc(
	path: string,
	ordinal: u32,
	stage_name: string,
	tail: string,
) -> bool {
	if ordinal > 99 {return false}
	prefix_length := len("stages/00-/")+len(stage_name)
	if len(path) < prefix_length ||
	   path[:7] != "stages/" ||
	   path[7] != '0'+u8(ordinal/10) ||
	   path[8] != '0'+u8(ordinal%10) ||
	   path[9] != '-' ||
	   path[10:10+len(stage_name)] != stage_name ||
	   path[10+len(stage_name)] != '/' {
		return false
	}
	if tail == "" {return len(path) > prefix_length}
	return path[prefix_length:] == tail
}

evidence_bundle_path_used_before :: proc(
	manifest: Evidence_Bundle_Manifest,
	path: string,
	stage_limit, file_limit: int,
) -> bool {
	if path == "manifest.json" || path == manifest.summary.path {
		return true
	}
	for stage in manifest.stages[:stage_limit] {
		if stage.manifest.path == path {return true}
	}
	for file in manifest.files[:file_limit] {
		if file.path == path {return true}
	}
	return false
}

evidence_bundle_manifest_destroy :: proc(
	manifest: ^Evidence_Bundle_Manifest,
	allocator := context.allocator,
) {
	delete(manifest.request_hash, allocator)
	delete(manifest.source_root_id, allocator)
	evidence_artifact_destroy(&manifest.summary, allocator)
	for &stage in manifest.stages {
		delete(stage.stage.name, allocator)
		delete(stage.provider.id, allocator)
		delete(stage.provider.name, allocator)
		delete(stage.provider.version, allocator)
		evidence_artifact_destroy(&stage.manifest, allocator)
	}
	delete(manifest.stages, allocator)
	for &file in manifest.files {
		evidence_artifact_destroy(&file, allocator)
	}
	delete(manifest.files, allocator)
	manifest^ = {}
}

evidence_bundle_summary_destroy :: proc(
	summary: ^Evidence_Bundle_Summary,
	allocator := context.allocator,
) {
	delete(summary.request_hash, allocator)
	delete(summary.source_root_id, allocator)
	summary^ = {}
}
