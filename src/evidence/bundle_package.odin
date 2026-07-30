package evidence

import formats "../formats"

Evidence_Bundle_Content :: struct {
	path:  string,
	bytes: []u8,
}

Evidence_Bundle_Package_Error :: enum u8 {
	None,
	Invalid_Manifest,
	Invalid_Content,
	Missing_Content,
	Duplicate_Content,
	Manifest_Encode_Failed,
	Zip_Write_Failed,
	Zip_Read_Failed,
	Allocation_Failed,
}

evidence_bundle_package_encode :: proc(
	manifest: Evidence_Bundle_Manifest,
	contents: []Evidence_Bundle_Content,
	limits := formats.DEFAULT_BOUNDED_ZIP_LIMITS,
	allocator := context.allocator,
) -> ([]u8, Evidence_Bundle_Package_Error) {
	content_error :=
		evidence_bundle_contents_validate(manifest, contents, allocator)
	if content_error != .None {return nil, content_error}

	manifest_bytes, manifest_error :=
		evidence_bundle_manifest_encode(manifest, allocator)
	if manifest_error != .None {
		if manifest_error == .Encode_Failed {
			return nil, .Allocation_Failed
		}
		return nil, .Manifest_Encode_Failed
	}
	defer delete(manifest_bytes, allocator)
	entries := make(
		[]formats.Bounded_Zip_Write_Entry,
		len(contents)+1,
		allocator,
	)
	if entries == nil {return nil, .Allocation_Failed}
	defer delete(entries, allocator)
	entries[0] = {"manifest.json", manifest_bytes}
	for content, content_index in contents {
		entries[content_index+1] = {content.path, content.bytes}
	}
	package_bytes, zip_error := formats.bounded_zip_write_stored(
		entries,
		limits,
		allocator,
	)
	if zip_error != .None {
		if zip_error == .Allocation_Failed {
			return nil, .Allocation_Failed
		}
		return nil, .Zip_Write_Failed
	}
	return package_bytes, .None
}

evidence_bundle_contents_validate :: proc(
	manifest: Evidence_Bundle_Manifest,
	contents: []Evidence_Bundle_Content,
	allocator := context.allocator,
) -> Evidence_Bundle_Package_Error {
	if !evidence_bundle_manifest_valid(manifest) {
		return .Invalid_Manifest
	}
	expected_content_count := 1+len(manifest.stages)+len(manifest.files)
	if len(contents) < expected_content_count {
		return .Missing_Content
	}
	if len(contents) > expected_content_count {
		return .Invalid_Content
	}
	for content, content_index in contents {
		for previous in contents[:content_index] {
			if previous.path == content.path {
				return .Duplicate_Content
			}
		}
		descriptor, descriptor_ok :=
			evidence_bundle_descriptor_find(manifest, content.path)
		if !descriptor_ok ||
		   evidence_artifact_verify(descriptor, content.bytes) != .None {
			return .Invalid_Content
		}
	}
	summary_content, summary_content_ok :=
		evidence_bundle_content_find(contents, manifest.summary.path)
	if !summary_content_ok ||
	   !evidence_bundle_summary_matches(
	   	manifest,
	   	summary_content.bytes,
	   	allocator,
	   ) {
		return .Invalid_Content
	}
	for stage in manifest.stages {
		stage_content, stage_content_ok :=
			evidence_bundle_content_find(contents, stage.manifest.path)
		if !stage_content_ok ||
		   !evidence_bundle_stage_manifest_matches(
		   	manifest,
		   	stage,
		   	stage_content.bytes,
		   	allocator,
		   ) {
			return .Invalid_Content
		}
	}
	return .None
}

evidence_bundle_package_validate :: proc(
	package_bytes: []u8,
	limits := formats.DEFAULT_BOUNDED_ZIP_LIMITS,
	allocator := context.allocator,
) -> Evidence_Bundle_Package_Error {
	replay, error :=
		evidence_bundle_package_replay(package_bytes, limits, allocator)
	evidence_bundle_replay_destroy(&replay, allocator)
	return error
}

evidence_bundle_summary_matches :: proc(
	root: Evidence_Bundle_Manifest,
	bytes: []u8,
	allocator := context.allocator,
) -> bool {
	if u64(len(bytes)) > EVIDENCE_BUNDLE_SUMMARY_BYTE_LIMIT {return false}
	summary, decode_error := evidence_bundle_summary_decode(bytes, allocator)
	if decode_error != .None {return false}
	defer evidence_bundle_summary_destroy(&summary, allocator)
	return summary.request_hash == root.request_hash &&
		summary.source_root_id == root.source_root_id &&
		summary.stage_count == u64(len(root.stages)) &&
		summary.file_count == u64(len(root.files))
}

evidence_bundle_manifest_primitive_find :: proc(
	manifest: Evidence_Manifest,
	format: string,
) -> (Evidence_Artifact, bool) {
	result: Evidence_Artifact
	found := false
	for primitive in manifest.primitives {
		if primitive.format != format {continue}
		if found {return {}, false}
		result = primitive
		found = true
	}
	return result, found
}

evidence_bundle_archive_entry_find :: proc(
	archive: formats.Bounded_Zip_Archive,
	path: string,
) -> (int, bool) {
	for entry, entry_index in archive.entries {
		if entry.name == path {return entry_index, true}
	}
	return 0, false
}

evidence_bundle_descriptor_find :: proc(
	manifest: Evidence_Bundle_Manifest,
	path: string,
) -> (Evidence_Artifact, bool) {
	if manifest.summary.path == path {return manifest.summary, true}
	for stage in manifest.stages {
		if stage.manifest.path == path {return stage.manifest, true}
	}
	for file in manifest.files {
		if file.path == path {return file, true}
	}
	return {}, false
}

evidence_bundle_content_find :: proc(
	contents: []Evidence_Bundle_Content,
	path: string,
) -> (Evidence_Bundle_Content, bool) {
	for content in contents {
		if content.path == path {return content, true}
	}
	return {}, false
}

evidence_bundle_stage_manifest_matches :: proc(
	root: Evidence_Bundle_Manifest,
	stage: Evidence_Bundle_Stage,
	bytes: []u8,
	allocator := context.allocator,
) -> bool {
	if u64(len(bytes)) > EVIDENCE_STAGE_MANIFEST_BYTE_LIMIT {return false}
	manifest, decode_error := evidence_manifest_decode(bytes, allocator)
	if decode_error != .None {return false}
	defer evidence_manifest_destroy(&manifest, allocator)
	if manifest.request_hash != root.request_hash ||
	   manifest.source_root_id != root.source_root_id ||
	   manifest.stage != stage.stage ||
	   manifest.provider != stage.provider {
		return false
	}
	for artifact in manifest.primitives {
		root_artifact, found := evidence_bundle_file_find(root, artifact.path)
		if !evidence_bundle_path_matches_stage(
			artifact.path,
			stage.ordinal,
			stage.stage.name,
			"",
		) ||
		   !found ||
		   !evidence_artifact_equal(root_artifact, artifact) {
			return false
		}
	}
	for artifact in manifest.renders {
		root_artifact, found := evidence_bundle_file_find(root, artifact.path)
		if !evidence_bundle_path_matches_stage(
			artifact.path,
			stage.ordinal,
			stage.stage.name,
			"",
		) ||
		   !found ||
		   !evidence_artifact_equal(root_artifact, artifact) {
			return false
		}
	}
	for file in root.files {
		if !evidence_bundle_path_matches_stage(
			file.path,
			stage.ordinal,
			stage.stage.name,
			"",
		) {
			continue
		}
		found := false
		for artifact in manifest.primitives {
			if evidence_artifact_equal(file, artifact) {found = true}
		}
		for artifact in manifest.renders {
			if evidence_artifact_equal(file, artifact) {found = true}
		}
		if !found {return false}
	}
	return true
}

evidence_bundle_file_find :: proc(
	manifest: Evidence_Bundle_Manifest,
	path: string,
) -> (Evidence_Artifact, bool) {
	for file in manifest.files {
		if file.path == path {return file, true}
	}
	return {}, false
}

evidence_artifact_equal :: proc(
	left, right: Evidence_Artifact,
) -> bool {
	return left.path == right.path &&
		left.format == right.format &&
		left.schema_version == right.schema_version &&
		left.item_count == right.item_count &&
		left.byte_count == right.byte_count &&
		left.sha256 == right.sha256
}
