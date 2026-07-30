package evidence

import "core:os"
import "core:strings"
import "core:sys/posix"

import formats "../formats"
import gcode "../gcode"

Evidence_Bundle_Replay :: struct {
	root:             Evidence_Bundle_Manifest,
	summary:          Evidence_Bundle_Summary,
	stage_manifests:  []Evidence_Manifest,
	topology:         Topology_Artifact,
	regions:          Region_Artifact,
	path_plan:        Path_Plan_Artifact,
	marlin:           gcode.Marlin_Artifact,
	topology_loaded:  bool,
	regions_loaded:   bool,
	path_plan_loaded: bool,
	marlin_loaded:    bool,
}

Evidence_Bundle_Source_Kind :: enum u8 {
	Unknown,
	Package,
	Directory,
}

Evidence_Bundle_Load_Error :: enum u8 {
	None,
	Invalid_Path,
	Source_Read_Failed,
	Invalid_Package,
	Invalid_Directory,
	Allocation_Failed,
}

evidence_bundle_replay_destroy :: proc(
	replay: ^Evidence_Bundle_Replay,
	allocator := context.allocator,
) {
	if replay == nil {return}
	for &manifest in replay.stage_manifests {
		evidence_manifest_destroy(&manifest, allocator)
	}
	delete(replay.stage_manifests, allocator)
	evidence_bundle_summary_destroy(&replay.summary, allocator)
	evidence_bundle_manifest_destroy(&replay.root, allocator)
	if replay.topology_loaded {
		topology_artifact_destroy(&replay.topology, allocator)
	}
	if replay.regions_loaded {
		region_artifact_destroy(&replay.regions, allocator)
	}
	if replay.path_plan_loaded {
		path_plan_artifact_destroy(&replay.path_plan, allocator)
	}
	if replay.marlin_loaded {
		gcode.marlin_artifact_destroy(&replay.marlin, allocator)
	}
	replay^ = {}
}

evidence_bundle_path_replay :: proc(
	path: string,
	limits := formats.DEFAULT_BOUNDED_ZIP_LIMITS,
	allocator := context.allocator,
) -> (
	replay: Evidence_Bundle_Replay,
	kind: Evidence_Bundle_Source_Kind,
	error: Evidence_Bundle_Load_Error,
) {
	if path == "" {return {}, .Unknown, .Invalid_Path}
	info, stat_error := os.stat(path, allocator)
	if stat_error != nil {return {}, .Unknown, .Invalid_Path}
	defer os.file_info_delete(info, allocator)
	if info.is_dir {
		directory_replay, directory_error :=
			evidence_bundle_directory_replay(path, limits, allocator)
		if directory_error != .None {
			if directory_error == .Allocation_Failed {
				return {}, .Directory, .Allocation_Failed
			}
			return {}, .Directory, .Invalid_Directory
		}
		return directory_replay, .Directory, .None
	}
	bytes, read_error := formats.source_file_read_bounded(
		path,
		22,
		limits.max_source_bytes,
		allocator,
	)
	if read_error != .None {
		if read_error == .Allocation_Failed {
			return {}, .Package, .Allocation_Failed
		}
		return {}, .Package, .Source_Read_Failed
	}
	defer delete(bytes, allocator)
	package_replay, package_error :=
		evidence_bundle_package_replay(bytes, limits, allocator)
	if package_error != .None {
		if package_error == .Allocation_Failed {
			return {}, .Package, .Allocation_Failed
		}
		return {}, .Package, .Invalid_Package
	}
	return package_replay, .Package, .None
}

evidence_bundle_package_replay :: proc(
	package_bytes: []u8,
	limits := formats.DEFAULT_BOUNDED_ZIP_LIMITS,
	allocator := context.allocator,
) -> (
	replay: Evidence_Bundle_Replay,
	error: Evidence_Bundle_Package_Error,
) {
	archive, parse_error := formats.bounded_zip_parse(
		package_bytes,
		limits,
		allocator,
	)
	if parse_error != .None {
		if parse_error == .Allocation_Failed {
			return {}, .Allocation_Failed
		}
		return {}, .Zip_Read_Failed
	}
	defer formats.bounded_zip_destroy(&archive, allocator)
	return evidence_bundle_archive_replay(archive, allocator)
}

evidence_bundle_archive_replay :: proc(
	archive: formats.Bounded_Zip_Archive,
	allocator := context.allocator,
) -> (Evidence_Bundle_Replay, Evidence_Bundle_Package_Error) {
	replay: Evidence_Bundle_Replay
	complete := false
	defer {
		if !complete {
			evidence_bundle_replay_destroy(&replay, allocator)
		}
	}
	root_index, root_found :=
		evidence_bundle_archive_entry_find(archive, "manifest.json")
	if !root_found {return {}, .Missing_Content}
	if u64(archive.entries[root_index].uncompressed_bytes) >
	   EVIDENCE_BUNDLE_MANIFEST_BYTE_LIMIT {
		return {}, .Invalid_Manifest
	}
	root_bytes, root_extract_error := formats.bounded_zip_extract(
		archive,
		root_index,
		allocator,
	)
	if root_extract_error != .None {
		if root_extract_error == .Allocation_Failed {
			return {}, .Allocation_Failed
		}
		return {}, .Zip_Read_Failed
	}
	defer delete(root_bytes, allocator)
	root, root_decode_error :=
		evidence_bundle_manifest_decode(root_bytes, allocator)
	if root_decode_error != .None {return {}, .Invalid_Manifest}
	replay.root = root
	expected_entry_count :=
		2+len(replay.root.stages)+len(replay.root.files)
	if len(archive.entries) < expected_entry_count {
		return {}, .Missing_Content
	}
	if len(archive.entries) > expected_entry_count {
		return {}, .Invalid_Content
	}
	for entry, entry_index in archive.entries {
		if entry.name == "manifest.json" {continue}
		descriptor, descriptor_ok :=
			evidence_bundle_descriptor_find(replay.root, entry.name)
		if !descriptor_ok ||
		   u64(entry.uncompressed_bytes) != descriptor.byte_count {
			return {}, .Invalid_Content
		}
		content_bytes, extract_error := formats.bounded_zip_extract(
			archive,
			entry_index,
			allocator,
		)
		if extract_error != .None {
			if extract_error == .Allocation_Failed {
				return {}, .Allocation_Failed
			}
			return {}, .Zip_Read_Failed
		}
		verify_error := evidence_artifact_verify(
			descriptor,
			content_bytes,
		)
		delete(content_bytes, allocator)
		if verify_error != .None {return {}, .Invalid_Content}
	}

	summary_index, summary_found :=
		evidence_bundle_archive_entry_find(archive, replay.root.summary.path)
	if !summary_found {return {}, .Missing_Content}
	summary_bytes, summary_extract_error := formats.bounded_zip_extract(
		archive,
		summary_index,
		allocator,
	)
	if summary_extract_error != .None {
		if summary_extract_error == .Allocation_Failed {
			return {}, .Allocation_Failed
		}
		return {}, .Zip_Read_Failed
	}
	defer delete(summary_bytes, allocator)
	if evidence_artifact_verify(
		replay.root.summary,
		summary_bytes,
	) != .None {
		return {}, .Invalid_Content
	}
	summary, summary_decode_error :=
		evidence_bundle_summary_decode(summary_bytes, allocator)
	if summary_decode_error != .None {return {}, .Invalid_Content}
	replay.summary = summary
	if replay.summary.request_hash != replay.root.request_hash ||
	   replay.summary.source_root_id != replay.root.source_root_id ||
	   replay.summary.stage_count != u64(len(replay.root.stages)) ||
	   replay.summary.file_count != u64(len(replay.root.files)) {
		return {}, .Invalid_Content
	}

	replay.stage_manifests = make(
		[]Evidence_Manifest,
		len(replay.root.stages),
		allocator,
	)
	if len(replay.root.stages) > 0 && replay.stage_manifests == nil {
		return {}, .Allocation_Failed
	}
	for stage, stage_index in replay.root.stages {
		manifest_index, manifest_found :=
			evidence_bundle_archive_entry_find(
				archive,
				stage.manifest.path,
			)
		if !manifest_found {return {}, .Missing_Content}
		manifest_bytes, manifest_extract_error :=
			formats.bounded_zip_extract(
				archive,
				manifest_index,
				allocator,
			)
		if manifest_extract_error != .None {
			if manifest_extract_error == .Allocation_Failed {
				return {}, .Allocation_Failed
			}
			return {}, .Zip_Read_Failed
		}
		if evidence_artifact_verify(
			stage.manifest,
			manifest_bytes,
		) != .None ||
		   !evidence_bundle_stage_manifest_matches(
			replay.root,
			stage,
			manifest_bytes,
			allocator,
		   ) {
			delete(manifest_bytes, allocator)
			return {}, .Invalid_Content
		}
		manifest, manifest_decode_error :=
			evidence_manifest_decode(manifest_bytes, allocator)
		delete(manifest_bytes, allocator)
		if manifest_decode_error != .None {
			return {}, .Invalid_Content
		}
		replay.stage_manifests[stage_index] = manifest
		primitive_format, supported :=
			evidence_bundle_replay_stage_format(stage.stage.name)
		if !supported {continue}
		primitive, primitive_found :=
			evidence_bundle_manifest_primitive_find(
				manifest,
				primitive_format,
			)
		if !primitive_found {return {}, .Invalid_Content}
		artifact_index, artifact_found :=
			evidence_bundle_archive_entry_find(archive, primitive.path)
		if !artifact_found {return {}, .Missing_Content}
		artifact_bytes, artifact_extract_error :=
			formats.bounded_zip_extract(
				archive,
				artifact_index,
				allocator,
			)
		if artifact_extract_error != .None {
			if artifact_extract_error == .Allocation_Failed {
				return {}, .Allocation_Failed
			}
			return {}, .Zip_Read_Failed
		}
		if evidence_artifact_verify(primitive, artifact_bytes) != .None {
			delete(artifact_bytes, allocator)
			return {}, .Invalid_Content
		}
		stage_error := evidence_bundle_replay_stage_decode(
			&replay,
			manifest,
			artifact_bytes,
			allocator,
		)
		delete(artifact_bytes, allocator)
		if stage_error != .None {return {}, stage_error}
	}
	complete = true
	return replay, .None
}

evidence_bundle_directory_replay :: proc(
	root_path: string,
	limits := formats.DEFAULT_BOUNDED_ZIP_LIMITS,
	allocator := context.allocator,
) -> (Evidence_Bundle_Replay, Evidence_Bundle_Directory_Error) {
	replay: Evidence_Bundle_Replay
	if root_path == "" {return {}, .Invalid_Destination}
	root_cstring :=
		strings.clone_to_cstring(root_path, context.temp_allocator)
	root_fd := posix.open(
		root_cstring,
		{.DIRECTORY, .CLOEXEC, .NOFOLLOW},
	)
	if root_fd < 0 {return {}, .Invalid_Destination}
	defer posix.close(root_fd)
	complete := false
	defer {
		if !complete {
			evidence_bundle_replay_destroy(&replay, allocator)
		}
	}
	root_manifest_bytes, root_read_error :=
		evidence_bundle_directory_read_file(
			root_fd,
			"manifest.json",
			0,
			EVIDENCE_BUNDLE_MANIFEST_BYTE_LIMIT,
			allocator,
		)
	if root_read_error != .None {return {}, root_read_error}
	defer delete(root_manifest_bytes, allocator)
	root, root_decode_error :=
		evidence_bundle_manifest_decode(root_manifest_bytes, allocator)
	if root_decode_error != .None {return {}, .Invalid_Manifest}
	replay.root = root
	if !evidence_bundle_directory_manifest_fits_limits(
		replay.root,
		u64(len(root_manifest_bytes)),
		limits,
	) {
		return {}, .Invalid_Manifest
	}
	node_count: u64
	node_limit :=
		evidence_bundle_directory_expected_node_limit(replay.root)
	walk_error := evidence_bundle_directory_walk_validate(
		root_fd,
		"",
		replay.root,
		&node_count,
		node_limit,
		limits.max_path_bytes,
		allocator,
	)
	if walk_error != .None {return {}, walk_error}
	for descriptor in replay.root.files {
		content_bytes, content_read_error :=
			evidence_bundle_directory_read_file(
				root_fd,
				descriptor.path,
				descriptor.byte_count,
				descriptor.byte_count,
				allocator,
			)
		if content_read_error != .None {
			return {}, content_read_error
		}
		verify_error :=
			evidence_artifact_verify(descriptor, content_bytes)
		delete(content_bytes, allocator)
		if verify_error != .None {return {}, .Invalid_Content}
	}

	summary_bytes, summary_read_error :=
		evidence_bundle_directory_read_file(
			root_fd,
			replay.root.summary.path,
			replay.root.summary.byte_count,
			replay.root.summary.byte_count,
			allocator,
		)
	if summary_read_error != .None {return {}, summary_read_error}
	defer delete(summary_bytes, allocator)
	if evidence_artifact_verify(
		replay.root.summary,
		summary_bytes,
	) != .None {
		return {}, .Invalid_Content
	}
	summary, summary_decode_error :=
		evidence_bundle_summary_decode(summary_bytes, allocator)
	if summary_decode_error != .None {return {}, .Invalid_Content}
	replay.summary = summary
	if replay.summary.request_hash != replay.root.request_hash ||
	   replay.summary.source_root_id != replay.root.source_root_id ||
	   replay.summary.stage_count != u64(len(replay.root.stages)) ||
	   replay.summary.file_count != u64(len(replay.root.files)) {
		return {}, .Invalid_Content
	}

	replay.stage_manifests = make(
		[]Evidence_Manifest,
		len(replay.root.stages),
		allocator,
	)
	if len(replay.root.stages) > 0 && replay.stage_manifests == nil {
		return {}, .Allocation_Failed
	}
	for stage, stage_index in replay.root.stages {
		manifest_bytes, manifest_read_error :=
			evidence_bundle_directory_read_file(
				root_fd,
				stage.manifest.path,
				stage.manifest.byte_count,
				stage.manifest.byte_count,
				allocator,
			)
		if manifest_read_error != .None {
			return {}, manifest_read_error
		}
		if evidence_artifact_verify(
			stage.manifest,
			manifest_bytes,
		) != .None ||
		   !evidence_bundle_stage_manifest_matches(
			replay.root,
			stage,
			manifest_bytes,
			allocator,
		   ) {
			delete(manifest_bytes, allocator)
			return {}, .Invalid_Content
		}
		manifest, manifest_decode_error :=
			evidence_manifest_decode(manifest_bytes, allocator)
		delete(manifest_bytes, allocator)
		if manifest_decode_error != .None {
			return {}, .Invalid_Content
		}
		replay.stage_manifests[stage_index] = manifest
		primitive_format, supported :=
			evidence_bundle_replay_stage_format(stage.stage.name)
		if !supported {continue}
		primitive, primitive_found :=
			evidence_bundle_manifest_primitive_find(
				manifest,
				primitive_format,
			)
		if !primitive_found {return {}, .Invalid_Content}
		artifact_bytes, artifact_read_error :=
			evidence_bundle_directory_read_file(
				root_fd,
				primitive.path,
				primitive.byte_count,
				primitive.byte_count,
				allocator,
			)
		if artifact_read_error != .None {
			return {}, artifact_read_error
		}
		if evidence_artifact_verify(primitive, artifact_bytes) != .None {
			delete(artifact_bytes, allocator)
			return {}, .Invalid_Content
		}
		stage_error := evidence_bundle_replay_stage_decode(
			&replay,
			manifest,
			artifact_bytes,
			allocator,
		)
		delete(artifact_bytes, allocator)
		if stage_error != .None {
			if stage_error == .Allocation_Failed {
				return {}, .Allocation_Failed
			}
			return {}, .Invalid_Content
		}
	}
	root_manifest_after, reread_error :=
		evidence_bundle_directory_read_file(
			root_fd,
			"manifest.json",
			u64(len(root_manifest_bytes)),
			u64(len(root_manifest_bytes)),
			allocator,
		)
	if reread_error != .None {return {}, reread_error}
	root_unchanged :=
		len(root_manifest_after) == len(root_manifest_bytes) &&
		evidence_bundle_bytes_equal(
			root_manifest_after,
			root_manifest_bytes,
		)
	delete(root_manifest_after, allocator)
	if !root_unchanged {return {}, .Invalid_Manifest}
	node_count = 0
	final_walk_error := evidence_bundle_directory_walk_validate(
		root_fd,
		"",
		replay.root,
		&node_count,
		node_limit,
		limits.max_path_bytes,
		allocator,
	)
	if final_walk_error != .None {return {}, final_walk_error}
	complete = true
	return replay, .None
}

evidence_bundle_replay_stage_format :: proc(
	stage_name: string,
) -> (string, bool) {
	switch stage_name {
	case "reconstruct-topology":
		return TOPOLOGY_ARTIFACT_FORMAT, true
	case "calculate-regions":
		return REGION_ARTIFACT_FORMAT, true
	case "plan-paths":
		return PATH_PLAN_ARTIFACT_FORMAT, true
	case "emit-gcode":
		return gcode.MARLIN_ARTIFACT_FORMAT, true
	case:
		return "", false
	}
}

evidence_bundle_replay_stage_decode :: proc(
	replay: ^Evidence_Bundle_Replay,
	manifest: Evidence_Manifest,
	artifact_bytes: []u8,
	allocator := context.allocator,
) -> Evidence_Bundle_Package_Error {
	switch manifest.stage.name {
	case "reconstruct-topology":
		if replay.topology_loaded {return .Invalid_Content}
		primitive, primitive_ok := evidence_bundle_manifest_primitive_find(
			manifest,
			TOPOLOGY_ARTIFACT_FORMAT,
		)
		if !primitive_ok {return .Invalid_Content}
		expectations, preflight_error := topology_manifest_preflight(
			manifest,
			primitive.path,
			artifact_bytes,
		)
		if preflight_error != .None {return .Invalid_Content}
		artifact, decode_error := topology_artifact_decode(
			artifact_bytes,
			DEFAULT_TOPOLOGY_ARTIFACT_LIMITS,
			allocator,
		)
		if decode_error != .None {
			if decode_error == .Allocation_Failed {
				return .Allocation_Failed
			}
			return .Invalid_Content
		}
		if topology_manifest_replay_verify(
			expectations,
			artifact,
		) != .None {
			topology_artifact_destroy(&artifact, allocator)
			return .Invalid_Content
		}
		replay.topology = artifact
		replay.topology_loaded = true
	case "calculate-regions":
		if replay.regions_loaded || !replay.topology_loaded {
			return .Invalid_Content
		}
		primitive, primitive_ok := evidence_bundle_manifest_primitive_find(
			manifest,
			REGION_ARTIFACT_FORMAT,
		)
		if !primitive_ok {return .Invalid_Content}
		expectations, preflight_error := region_manifest_preflight(
			manifest,
			primitive.path,
			artifact_bytes,
		)
		if preflight_error != .None {return .Invalid_Content}
		artifact, decode_error := region_artifact_decode(
			artifact_bytes,
			replay.topology.result_hash,
			replay.topology.result,
			DEFAULT_REGION_ARTIFACT_LIMITS,
			allocator,
		)
		if decode_error != .None {
			if decode_error == .Allocation_Failed {
				return .Allocation_Failed
			}
			return .Invalid_Content
		}
		if region_manifest_replay_verify(expectations, artifact) != .None {
			region_artifact_destroy(&artifact, allocator)
			return .Invalid_Content
		}
		replay.regions = artifact
		replay.regions_loaded = true
	case "plan-paths":
		if replay.path_plan_loaded {return .Invalid_Content}
		primitive, primitive_ok := evidence_bundle_manifest_primitive_find(
			manifest,
			PATH_PLAN_ARTIFACT_FORMAT,
		)
		if !primitive_ok {return .Invalid_Content}
		expectations, preflight_error := path_plan_manifest_preflight(
			manifest,
			primitive.path,
			artifact_bytes,
		)
		if preflight_error != .None {return .Invalid_Content}
		artifact, decode_error := path_plan_artifact_decode(
			artifact_bytes,
			DEFAULT_PATH_PLAN_ARTIFACT_LIMITS,
			allocator,
		)
		if decode_error != .None {
			if decode_error == .Allocation_Failed {
				return .Allocation_Failed
			}
			return .Invalid_Content
		}
		if path_plan_manifest_replay_verify(
			expectations,
			artifact,
		) != .None {
			path_plan_artifact_destroy(&artifact, allocator)
			return .Invalid_Content
		}
		replay.path_plan = artifact
		replay.path_plan_loaded = true
	case "emit-gcode":
		if replay.marlin_loaded {return .Invalid_Content}
		primitive, primitive_ok := evidence_bundle_manifest_primitive_find(
			manifest,
			gcode.MARLIN_ARTIFACT_FORMAT,
		)
		if !primitive_ok {return .Invalid_Content}
		expectations, preflight_error := marlin_manifest_preflight(
			manifest,
			primitive.path,
			artifact_bytes,
		)
		if preflight_error != .None {return .Invalid_Content}
		artifact, decode_error := gcode.marlin_artifact_decode(
			artifact_bytes,
			gcode.DEFAULT_MARLIN_ARTIFACT_LIMITS,
			allocator,
		)
		if decode_error != .None {
			if decode_error == .Allocation_Failed {
				return .Allocation_Failed
			}
			return .Invalid_Content
		}
		if marlin_manifest_replay_verify(
			expectations,
			artifact,
		) != .None {
			gcode.marlin_artifact_destroy(&artifact, allocator)
			return .Invalid_Content
		}
		replay.marlin = artifact
		replay.marlin_loaded = true
	case:
	}
	return .None
}
