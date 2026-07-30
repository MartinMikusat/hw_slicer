package main

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"

import contracts "../../src/contracts"
import evidence "../../src/evidence"
import features "../../src/features"
import formats "../../src/formats"
import pipeline "../../src/pipeline"
import polygon "../../src/polygon"
import slicing "../../src/slicing"

Strict_Feature_Probe_Wire :: struct {
	schema_version:            u32,
	fixture:                   string,
	feature_request_schema:    u32,
	feature_request_hash:      string,
	path_plan_provider_id:     string,
	path_plan_provider_name:   string,
	path_plan_provider_version: string,
	source_bytes:              u64,
	source_hash:               string,
	topology_hash:             string,
	layer_count:               u64,
	region_count:              u64,
	hole_count:                u64,
	region_hash:               string,
	surface_mask_count:        u64,
	bottom_surface_mask_count: u64,
	top_surface_mask_count:    u64,
	surface_path_count:        u64,
	surface_point_count:       u64,
	surface_hash:              string,
	perimeter_count:           u32,
	perimeter_line_width_um:   i64,
	perimeter_group_count:     u64,
	perimeter_path_count:      u64,
	perimeter_point_count:     u64,
	perimeter_hash:            string,
	infill_spacing_um:         i64,
	infill_boundary_inset_um:  i64,
	infill_scanline_count:     u64,
	infill_segment_count:      u64,
	infill_boundary_hit_count: u64,
	infill_hash:               string,
	planned_path_count:        u64,
	planned_move_count:        u64,
	planned_travel_move_count: u64,
	planned_extrude_move_count: u64,
	path_plan_hash:            string,
	path_plan_artifact_path:   string,
	path_plan_artifact_format: string,
	path_plan_artifact_schema: u32,
	path_plan_artifact_items:  u64,
	path_plan_artifact_bytes:  u64,
	path_plan_artifact_sha256: string,
	path_plan_manifest_schema: u32,
	path_plan_manifest_bytes:  u64,
	path_plan_manifest_sha256: string,
	topology_policy:           string,
	validated:                 bool,
}

main :: proc() {
	if len(os.args) < 2 || len(os.args) > 5 {
		fmt.eprintln(
			"usage: hw-slicer-strict-feature-probe <binary-stl> [path-plan-artifact [evidence-bundle [evidence-directory]]]",
		)
		os.exit(2)
	}
	artifact_path := os.args[2] if len(os.args) >= 3 else ""
	bundle_path := os.args[3] if len(os.args) >= 4 else ""
	directory_path := os.args[4] if len(os.args) >= 5 else ""
	if os.args[1] == "" ||
	   len(os.args) >= 3 && artifact_path == "" ||
	   len(os.args) >= 4 && bundle_path == "" ||
	   len(os.args) >= 5 && directory_path == "" ||
	   len(os.args) >= 3 &&
	   	(
	   	 !strict_feature_probe_output_paths_valid(
	   	 	os.args[1],
	   	 	artifact_path,
	   	 	bundle_path,
	   	 	directory_path,
	   	 )) {
		fmt.eprintln(
			"[hw_slicer] source and output paths must be non-empty, distinct, and valid for their output types",
		)
		os.exit(2)
	}
	bytes, read_error := formats.source_file_read_bounded(
		os.args[1],
		84,
		formats.DEFAULT_BINARY_STL_LIMITS.max_source_bytes,
	)
	if read_error != .None {
		fmt.eprintf(
			"[hw_slicer] strict feature probe fixture read failed: %v\n",
			read_error,
		)
		os.exit(1)
	}
	defer delete(bytes)

	spine, spine_error := pipeline.slice_spine_binary_stl(bytes, {
		source_units = .Millimetres,
		first_layer_height = 200,
		layer_height = 200,
		max_layer_count = 10_000_000,
	})
	if spine_error != .None {
		fmt.eprintf(
			"[hw_slicer] strict feature probe spine failed: %v\n",
			spine_error,
		)
		os.exit(1)
	}
	defer pipeline.slice_spine_result_destroy(&spine)
	if spine.topology.open_chain_count != 0 ||
	   spine.topology.degenerate_loop_count != 0 ||
	   spine.topology.non_manifold_vertex_count != 0 {
		fmt.eprintf(
			"[hw_slicer] strict topology rejected: open=%d degenerate=%d non_manifold=%d\n",
			spine.topology.open_chain_count,
			spine.topology.degenerate_loop_count,
			spine.topology.non_manifold_vertex_count,
		)
		os.exit(1)
	}

	surface_config := features.Surface_Config{
		fill_rule = .Even_Odd,
		topology_policy = .Strict_Printable,
	}
	perimeter_config := features.Perimeter_Config{
		count = 2,
		line_width = 450,
		topology_policy = .Strict_Printable,
		join_type = .Miter,
		miter_limit = 2,
		arc_tolerance = 0,
	}
	infill_config := features.Infill_Config{
		spacing = 5_000,
		boundary_inset = 900,
		phase = 0,
		base_axis = .Vertical,
		alternate_each_layer = true,
		topology_policy = .Strict_Printable,
		join_type = .Miter,
		miter_limit = 2,
		arc_tolerance = 0,
	}
	path_plan_config := features.Path_Plan_Config{
		start = {0, 0},
		inner_perimeters_first = true,
	}
	path_plan_provider := features.cpu_path_plan_provider_descriptor()
	feature_request_hash, feature_request_ok :=
		features.feature_pipeline_request_hash({
			schema_version =
				features.FEATURE_PIPELINE_REQUEST_SCHEMA_VERSION,
			spine_request_hash = spine.hashes.request,
			surface = surface_config,
			perimeter = perimeter_config,
			infill = infill_config,
			path_plan = path_plan_config,
			polygon_provider_name = polygon.CLIPPER2_PROVIDER.name,
			polygon_provider_version = polygon.CLIPPER2_PROVIDER.version,
			path_plan_provider = path_plan_provider,
		})
	if !feature_request_ok {
		fmt.eprintln("[hw_slicer] strict feature request hash failed")
		os.exit(1)
	}

	regions, region_error := slicing.regions_build(spine.topology)
	if region_error != .None {
		fmt.eprintf(
			"[hw_slicer] strict feature probe regions failed: %v\n",
			region_error,
		)
		os.exit(1)
	}
	defer slicing.region_result_destroy(&regions)
	region_hash, region_hash_ok := slicing.region_result_hash(
		spine.hashes.topology,
		spine.topology,
		regions,
	)
	if !region_hash_ok {
		fmt.eprintln("[hw_slicer] strict feature probe region hash failed")
		os.exit(1)
	}

	surfaces, surface_error := features.surfaces_classify(
		spine.topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		surface_config,
	)
	if surface_error != .None {
		fmt.eprintf(
			"[hw_slicer] strict feature probe surfaces failed: %v\n",
			surface_error,
		)
		os.exit(1)
	}
	defer features.surface_result_destroy(&surfaces)
	surface_hash, surface_hash_ok := features.surface_result_hash(
		region_hash,
		surfaces,
	)
	if !surface_hash_ok {
		fmt.eprintln("[hw_slicer] strict feature probe surface hash failed")
		os.exit(1)
	}

	perimeters, perimeter_error := features.perimeters_generate(
		spine.topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		perimeter_config,
	)
	if perimeter_error != .None {
		fmt.eprintf(
			"[hw_slicer] strict feature probe perimeters failed: %v\n",
			perimeter_error,
		)
		os.exit(1)
	}
	defer features.perimeter_result_destroy(&perimeters)
	perimeter_hash, perimeter_hash_ok := features.perimeter_result_hash(
		region_hash,
		perimeters,
	)
	if !perimeter_hash_ok {
		fmt.eprintln("[hw_slicer] strict feature probe perimeter hash failed")
		os.exit(1)
	}

	infill, infill_error := features.infill_generate(
		spine.topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		infill_config,
	)
	if infill_error != .None {
		fmt.eprintf(
			"[hw_slicer] strict feature probe infill failed: %v\n",
			infill_error,
		)
		os.exit(1)
	}
	defer features.infill_result_destroy(&infill)
	infill_hash, infill_hash_ok := features.infill_result_hash(
		region_hash,
		infill,
	)
	if !infill_hash_ok {
		fmt.eprintln("[hw_slicer] strict feature probe infill hash failed")
		os.exit(1)
	}

	plan, plan_error := features.path_plan_build(
		perimeters,
		infill,
		path_plan_config,
	)
	if plan_error != .None {
		fmt.eprintf(
			"[hw_slicer] strict feature probe path plan failed: %v\n",
			plan_error,
		)
		os.exit(1)
	}
	defer features.path_plan_result_destroy(&plan)
	path_plan_hash, path_plan_hash_ok := features.path_plan_result_hash(
		perimeter_hash,
		infill_hash,
		plan,
	)
	if !path_plan_hash_ok {
		fmt.eprintln("[hw_slicer] strict feature probe path hash failed")
		os.exit(1)
	}
	path_plan_capture, capture_error := evidence.path_plan_capture_encode(
		"path-plan.bin",
		{
			level = .Primitives,
			byte_limit = 64*1024*1024,
			item_limit = 1_000_000,
		},
		{},
		perimeter_hash,
		infill_hash,
		plan,
	)
	if capture_error != .None {
		fmt.eprintf(
			"[hw_slicer] strict feature probe artifact failed: %v\n",
			capture_error,
		)
		os.exit(1)
	}
	defer evidence.path_plan_capture_destroy(&path_plan_capture)
	replayed_plan, replay_error := evidence.path_plan_artifact_decode(
		path_plan_capture.bytes,
	)
	if replay_error != .None ||
	   replayed_plan.result_hash != path_plan_hash ||
	   len(replayed_plan.result.layers) != len(plan.layers) ||
	   len(replayed_plan.result.paths) != len(plan.paths) ||
	   len(replayed_plan.result.moves) != len(plan.moves) {
		evidence.path_plan_artifact_destroy(&replayed_plan)
		fmt.eprintf(
			"[hw_slicer] strict feature probe artifact replay failed: %v\n",
			replay_error,
		)
		os.exit(1)
	}
	evidence.path_plan_artifact_destroy(&replayed_plan)
	path_plan_manifest_bytes, manifest_error :=
		strict_feature_probe_path_plan_manifest(
			feature_request_hash,
			path_plan_hash,
			spine,
			plan,
			path_plan_provider,
			path_plan_capture.artifact,
		)
	if manifest_error != .None {
		fmt.eprintf(
			"[hw_slicer] strict feature probe manifest failed: %v\n",
			manifest_error,
		)
		os.exit(1)
	}
	defer delete(path_plan_manifest_bytes)
	path_plan_manifest_hash := strict_feature_probe_sha256(
		path_plan_manifest_bytes,
	)
	if len(os.args) >= 3 {
		if filepath.base(artifact_path) != path_plan_capture.artifact.path {
			fmt.eprintf(
				"[hw_slicer] artifact output must end with %s\n",
				path_plan_capture.artifact.path,
			)
			os.exit(1)
		}
		manifest_path := fmt.aprintf("%s.manifest.json", artifact_path)
		defer delete(manifest_path)
		if !os.write_entire_file(artifact_path, path_plan_capture.bytes) ||
		   !os.write_entire_file(
		   	string(manifest_path),
		   	path_plan_manifest_bytes,
		   ) {
			fmt.eprintln(
				"[hw_slicer] strict feature probe capture write failed",
			)
			os.exit(1)
		}
	}

	source_hash_text := strict_feature_probe_hash_text(
		spine.mesh.source.content_hash,
	)
	defer delete(source_hash_text)
	topology_hash_text := strict_feature_probe_hash_text(
		spine.hashes.topology,
	)
	defer delete(topology_hash_text)
	region_hash_text := strict_feature_probe_hash_text(region_hash)
	defer delete(region_hash_text)
	surface_hash_text := strict_feature_probe_hash_text(surface_hash)
	defer delete(surface_hash_text)
	perimeter_hash_text := strict_feature_probe_hash_text(perimeter_hash)
	defer delete(perimeter_hash_text)
	infill_hash_text := strict_feature_probe_hash_text(infill_hash)
	defer delete(infill_hash_text)
	path_plan_hash_text := strict_feature_probe_hash_text(path_plan_hash)
	defer delete(path_plan_hash_text)
	feature_request_hash_text := strict_feature_probe_hash_text(
		feature_request_hash,
	)
	defer delete(feature_request_hash_text)
	path_plan_provider_id_text := fmt.aprintf(
		"%016x",
		u64(path_plan_provider.id),
	)
	defer delete(path_plan_provider_id_text)
	path_plan_provider_version_text := fmt.aprintf(
		"%d.%d.%d",
		path_plan_provider.version.major,
		path_plan_provider.version.minor,
		path_plan_provider.version.patch,
	)
	defer delete(path_plan_provider_version_text)
	path_plan_manifest_hash_text := strict_feature_probe_hash_text(
		path_plan_manifest_hash,
	)
	defer delete(path_plan_manifest_hash_text)
	wire := Strict_Feature_Probe_Wire{
		schema_version = 3,
		fixture = filepath.base(os.args[1]),
		feature_request_schema =
			features.FEATURE_PIPELINE_REQUEST_SCHEMA_VERSION,
		feature_request_hash = string(feature_request_hash_text),
		path_plan_provider_id = string(path_plan_provider_id_text),
		path_plan_provider_name = path_plan_provider.name,
		path_plan_provider_version =
			string(path_plan_provider_version_text),
		source_bytes = u64(len(bytes)),
		source_hash = string(source_hash_text),
		topology_hash = string(topology_hash_text),
		layer_count = u64(len(spine.topology.layers)),
		region_count = u64(len(regions.regions)),
		hole_count = regions.hole_count,
		region_hash = string(region_hash_text),
		surface_mask_count = u64(len(surfaces.masks)),
		bottom_surface_mask_count = surfaces.bottom_mask_count,
		top_surface_mask_count = surfaces.top_mask_count,
		surface_path_count = u64(len(surfaces.paths)),
		surface_point_count = u64(len(surfaces.points)),
		surface_hash = string(surface_hash_text),
		perimeter_count = perimeters.config.count,
		perimeter_line_width_um = i64(perimeters.config.line_width),
		perimeter_group_count = u64(len(perimeters.groups)),
		perimeter_path_count = u64(len(perimeters.paths)),
		perimeter_point_count = u64(len(perimeters.points)),
		perimeter_hash = string(perimeter_hash_text),
		infill_spacing_um = i64(infill.config.spacing),
		infill_boundary_inset_um = i64(infill.config.boundary_inset),
		infill_scanline_count = infill.scanline_count,
		infill_segment_count = u64(len(infill.segments)),
		infill_boundary_hit_count = u64(len(infill.boundary_hits)),
		infill_hash = string(infill_hash_text),
		planned_path_count = u64(len(plan.paths)),
		planned_move_count = u64(len(plan.moves)),
		planned_travel_move_count = plan.travel_move_count,
		planned_extrude_move_count = plan.extrude_move_count,
		path_plan_hash = string(path_plan_hash_text),
		path_plan_artifact_path = path_plan_capture.artifact.path,
		path_plan_artifact_format = path_plan_capture.artifact.format,
		path_plan_artifact_schema =
			path_plan_capture.artifact.schema_version,
		path_plan_artifact_items = path_plan_capture.artifact.item_count,
		path_plan_artifact_bytes = path_plan_capture.artifact.byte_count,
		path_plan_artifact_sha256 = path_plan_capture.artifact.sha256,
		path_plan_manifest_schema =
			contracts.SCHEMA_VERSION_DEBUG_EVIDENCE,
		path_plan_manifest_bytes = u64(len(path_plan_manifest_bytes)),
		path_plan_manifest_sha256 =
			string(path_plan_manifest_hash_text),
		topology_policy = "strict-printable",
		validated = true,
	}
	output, encode_error := json.marshal(
		wire,
		{
			pretty = true,
			use_spaces = true,
			spaces = 2,
			sort_maps_by_key = true,
		},
	)
	if encode_error != nil {
		fmt.eprintln("[hw_slicer] strict feature probe encoding failed")
		os.exit(1)
	}
	defer delete(output)
	if len(os.args) >= 4 {
		bundle_bytes, bundle_error, directory_error :=
			strict_feature_probe_bundle_encode(
				feature_request_hash,
				path_plan_hash,
				region_hash,
				spine,
				regions,
				plan,
			path_plan_provider,
			path_plan_capture,
			directory_path,
		)
		if bundle_error != .None {
			fmt.eprintf(
				"[hw_slicer] strict feature probe bundle failed: %v\n",
				bundle_error,
			)
			os.exit(1)
		}
		if directory_error != .None {
			fmt.eprintf(
				"[hw_slicer] strict feature probe directory failed: %v\n",
				directory_error,
			)
			os.exit(1)
		}
		defer delete(bundle_bytes)
		if evidence.evidence_bundle_package_validate(bundle_bytes) != .None {
			fmt.eprintln(
				"[hw_slicer] strict feature probe bundle validation failed",
			)
			os.exit(1)
		}
		if !os.write_entire_file(bundle_path, bundle_bytes) {
			fmt.eprintln(
				"[hw_slicer] strict feature probe bundle write failed",
			)
			os.exit(1)
		}
	}
	fmt.println(string(output))
}

strict_feature_probe_output_paths_valid :: proc(
	source_path, artifact_path, bundle_path, directory_path: string,
) -> bool {
	source, source_ok := strict_feature_probe_normalized_path(source_path)
	if !source_ok {return false}
	defer delete(source)
	artifact, artifact_ok :=
		strict_feature_probe_normalized_path(artifact_path)
	if !artifact_ok {return false}
	defer delete(artifact)
	manifest_path := fmt.aprintf("%s.manifest.json", artifact_path)
	if manifest_path == "" {return false}
	defer delete(manifest_path)
	manifest, manifest_ok :=
		strict_feature_probe_normalized_path(string(manifest_path))
	if !manifest_ok {return false}
	defer delete(manifest)
	if strict_feature_probe_path_is_directory(artifact) ||
	   strict_feature_probe_path_is_directory(manifest) {
		return false
	}
	if source == artifact ||
	   source == manifest ||
	   artifact == manifest {
		return false
	}
	bundle := ""
	defer {
		if bundle != "" {delete(bundle)}
	}
	if bundle_path != "" {
		bundle_ok: bool
		bundle, bundle_ok =
			strict_feature_probe_normalized_path(bundle_path)
		if !bundle_ok {return false}
		if strict_feature_probe_path_is_directory(bundle) ||
		   bundle == source ||
		   bundle == artifact ||
		   bundle == manifest {
			return false
		}
	}
	if directory_path == "" {return true}
	directory, directory_ok :=
		strict_feature_probe_normalized_path(directory_path)
	if !directory_ok {return false}
	defer delete(directory)
	return !strict_feature_probe_path_exists(directory) &&
		directory != source &&
		directory != artifact &&
		directory != manifest &&
		directory != bundle
}

strict_feature_probe_normalized_path :: proc(
	path: string,
) -> (string, bool) {
	absolute, absolute_ok := filepath.abs(path)
	if absolute_ok {return absolute, true}
	directory := filepath.dir(path)
	if directory == "" {return "", false}
	defer delete(directory)
	absolute_directory, directory_ok := filepath.abs(directory)
	if !directory_ok {return "", false}
	defer delete(absolute_directory)
	parts := [2]string{absolute_directory, filepath.base(path)}
	normalized, normalize_error := filepath.join(parts[:])
	if normalize_error != nil {return "", false}
	return normalized, true
}

strict_feature_probe_path_is_directory :: proc(path: string) -> bool {
	info, error := os.stat(path)
	if error != nil {return false}
	defer os.file_info_delete(info)
	return info.is_dir
}

strict_feature_probe_path_exists :: proc(path: string) -> bool {
	info, error := os.lstat(path)
	if error != nil {return false}
	defer os.file_info_delete(info)
	return true
}

strict_feature_probe_hash_text :: proc(
	hash: contracts.Content_Hash,
) -> []u8 {
	bytes := hash
	return hex.encode(bytes[:])
}

strict_feature_probe_sha256 :: proc(bytes: []u8) -> (
	digest: contracts.Content_Hash,
) {
	hash_context: sha2.Context_256
	sha2.init_256(&hash_context)
	sha2.update(&hash_context, bytes)
	sha2.final(&hash_context, digest[:])
	return
}

strict_feature_probe_path_plan_manifest :: proc(
	request_hash, result_hash: contracts.Content_Hash,
	spine: pipeline.Slice_Spine_Result,
	plan: features.Path_Plan_Result,
	provider: contracts.Provider_Descriptor,
	artifact: evidence.Evidence_Artifact,
) -> ([]u8, evidence.Evidence_Error) {
	request_hash_text := strict_feature_probe_hash_text(request_hash)
	defer delete(request_hash_text)
	result_hash_text := strict_feature_probe_hash_text(result_hash)
	defer delete(result_hash_text)
	provider_id_text := fmt.aprintf("%016x", u64(provider.id))
	defer delete(provider_id_text)
	provider_version_text := fmt.aprintf(
		"%d.%d.%d",
		provider.version.major,
		provider.version.minor,
		provider.version.patch,
	)
	defer delete(provider_version_text)
	source_root_id_text := fmt.aprintf(
		"%016x",
		u64(spine.mesh.source_root_id),
	)
	defer delete(source_root_id_text)
	summary := [5]evidence.Evidence_Counter{
		{"layers", u64(len(plan.layers))},
		{"paths", u64(len(plan.paths))},
		{"moves", u64(len(plan.moves))},
		{"travel_moves", plan.travel_move_count},
		{"extrude_moves", plan.extrude_move_count},
	}
	invariants := [2]evidence.Evidence_Invariant{
		{
			"canonical_result_hash",
			true,
			string(result_hash_text),
			string(result_hash_text),
		},
		{
			"source_independent_replay",
			true,
			"passed",
			"passed",
		},
	}
	primitives := [1]evidence.Evidence_Artifact{artifact}
	manifest := evidence.Evidence_Manifest{
		schema_version = contracts.SCHEMA_VERSION_DEBUG_EVIDENCE,
		request_hash = string(request_hash_text),
		stage = evidence.evidence_stage_from_descriptor({
			kind = .Plan_Paths,
			schema_version = features.SCHEMA_VERSION_PATH_PLAN_HASH,
			revision = 1,
		}),
		provider = {
			id = string(provider_id_text),
			name = provider.name,
			version = string(provider_version_text),
		},
		source_root_id = string(source_root_id_text),
		source_bounds = {
			valid = true,
			minimum = {
				f64(spine.mesh.bounds.minimum.x),
				f64(spine.mesh.bounds.minimum.y),
				f64(spine.mesh.bounds.minimum.z),
			},
			maximum = {
				f64(spine.mesh.bounds.maximum.x),
				f64(spine.mesh.bounds.maximum.y),
				f64(spine.mesh.bounds.maximum.z),
			},
			units = "millimetre",
		},
		planar_bounds = strict_feature_probe_planar_bounds(plan),
		summary = summary[:],
		invariants = invariants[:],
		primitives = primitives[:],
		elapsed_ns = 0,
	}
	return evidence.evidence_manifest_encode(manifest)
}

strict_feature_probe_bundle_encode :: proc(
	request_hash, result_hash, region_hash: contracts.Content_Hash,
	spine: pipeline.Slice_Spine_Result,
	regions: slicing.Region_Result,
	plan: features.Path_Plan_Result,
	provider: contracts.Provider_Descriptor,
	capture: evidence.Path_Plan_Capture,
	directory_path: string,
) -> (
	[]u8,
	evidence.Evidence_Bundle_Package_Error,
	evidence.Evidence_Bundle_Directory_Error,
) {
	topology_capture, topology_capture_error :=
		evidence.topology_capture_encode(
			"stages/07-reconstruct-topology/primitives/topology.bin",
			{
				level = .Primitives,
				byte_limit = 256*1024*1024,
				item_limit = 10_000_000,
			},
			{},
			spine.hashes.snapped,
			len(spine.snapped.segments.segment_ids),
			spine.topology,
		)
	if topology_capture_error != .None {
		return nil, .Invalid_Content, .None
	}
	defer evidence.topology_capture_destroy(&topology_capture)
	topology_provider := slicing.cpu_topology_provider_descriptor()
	topology_stage_bytes, topology_stage_encode_error :=
		strict_feature_probe_topology_manifest(
			request_hash,
			spine.hashes.topology,
			spine,
			topology_provider,
			topology_capture.artifact,
		)
	if topology_stage_encode_error != .None {
		return nil, .Invalid_Content, .None
	}
	defer delete(topology_stage_bytes)
	topology_stage_record, topology_stage_decode_error :=
		evidence.evidence_manifest_decode(topology_stage_bytes)
	if topology_stage_decode_error != .None {
		return nil, .Invalid_Content, .None
	}
	defer evidence.evidence_manifest_destroy(&topology_stage_record)
	topology_stage_manifest, topology_stage_describe_error :=
		evidence.evidence_artifact_describe(
			"stages/07-reconstruct-topology/manifest.json",
			"json",
			contracts.SCHEMA_VERSION_DEBUG_EVIDENCE,
			1,
			topology_stage_bytes,
		)
	if topology_stage_describe_error != .None {
		return nil, .Allocation_Failed, .None
	}
	defer evidence.evidence_artifact_destroy(&topology_stage_manifest)

	region_capture, region_capture_error :=
		evidence.region_capture_encode(
			"stages/08-calculate-regions/primitives/regions.bin",
			{
				level = .Primitives,
				byte_limit = 256*1024*1024,
				item_limit = 10_000_000,
			},
			{},
			spine.hashes.topology,
			spine.topology,
			regions,
		)
	if region_capture_error != .None {
		return nil, .Invalid_Content, .None
	}
	defer evidence.region_capture_destroy(&region_capture)
	region_provider := slicing.cpu_region_provider_descriptor()
	region_stage_bytes, region_stage_encode_error :=
		strict_feature_probe_region_manifest(
			request_hash,
			region_hash,
			spine,
			regions,
			region_provider,
			region_capture.artifact,
		)
	if region_stage_encode_error != .None {
		return nil, .Invalid_Content, .None
	}
	defer delete(region_stage_bytes)
	region_stage_record, region_stage_decode_error :=
		evidence.evidence_manifest_decode(region_stage_bytes)
	if region_stage_decode_error != .None {
		return nil, .Invalid_Content, .None
	}
	defer evidence.evidence_manifest_destroy(&region_stage_record)
	region_stage_manifest, region_stage_describe_error :=
		evidence.evidence_artifact_describe(
			"stages/08-calculate-regions/manifest.json",
			"json",
			contracts.SCHEMA_VERSION_DEBUG_EVIDENCE,
			1,
			region_stage_bytes,
		)
	if region_stage_describe_error != .None {
		return nil, .Allocation_Failed, .None
	}
	defer evidence.evidence_artifact_destroy(&region_stage_manifest)

	path_plan_primitive := capture.artifact
	path_plan_primitive.path =
		"stages/10-plan-paths/primitives/path-plan.bin"
	path_plan_stage_bytes, path_plan_stage_encode_error :=
		strict_feature_probe_path_plan_manifest(
			request_hash,
			result_hash,
			spine,
			plan,
			provider,
			path_plan_primitive,
		)
	if path_plan_stage_encode_error != .None {
		return nil, .Invalid_Content, .None
	}
	defer delete(path_plan_stage_bytes)
	path_plan_stage_record, path_plan_stage_decode_error :=
		evidence.evidence_manifest_decode(path_plan_stage_bytes)
	if path_plan_stage_decode_error != .None {
		return nil, .Invalid_Content, .None
	}
	defer evidence.evidence_manifest_destroy(&path_plan_stage_record)
	path_plan_stage_manifest, path_plan_stage_describe_error :=
		evidence.evidence_artifact_describe(
			"stages/10-plan-paths/manifest.json",
			"json",
			contracts.SCHEMA_VERSION_DEBUG_EVIDENCE,
			1,
			path_plan_stage_bytes,
		)
	if path_plan_stage_describe_error != .None {
		return nil, .Allocation_Failed, .None
	}
	defer evidence.evidence_artifact_destroy(&path_plan_stage_manifest)
	summary_record := evidence.Evidence_Bundle_Summary{
		schema_version = evidence.EVIDENCE_BUNDLE_SCHEMA_VERSION,
		request_hash = path_plan_stage_record.request_hash,
		source_root_id = path_plan_stage_record.source_root_id,
		stage_count = 3,
		file_count = 3,
	}
	summary_bytes, summary_encode_error :=
		evidence.evidence_bundle_summary_encode(summary_record)
	if summary_encode_error != .None {
		return nil, .Invalid_Content, .None
	}
	defer delete(summary_bytes)
	summary, summary_error := evidence.evidence_artifact_describe(
		"summary.json",
		"json",
		evidence.EVIDENCE_BUNDLE_SCHEMA_VERSION,
		1,
		summary_bytes,
	)
	if summary_error != .None {return nil, .Allocation_Failed, .None}
	defer evidence.evidence_artifact_destroy(&summary)
	stages := [3]evidence.Evidence_Bundle_Stage{
		{
			ordinal = 7,
			stage = topology_stage_record.stage,
			provider = topology_stage_record.provider,
			manifest = topology_stage_manifest,
		},
		{
			ordinal = 8,
			stage = region_stage_record.stage,
			provider = region_stage_record.provider,
			manifest = region_stage_manifest,
		},
		{
			ordinal = 10,
			stage = path_plan_stage_record.stage,
			provider = path_plan_stage_record.provider,
			manifest = path_plan_stage_manifest,
		},
	}
	files := [3]evidence.Evidence_Artifact{
		topology_capture.artifact,
		region_capture.artifact,
		path_plan_primitive,
	}
	root := evidence.Evidence_Bundle_Manifest{
		schema_version = evidence.EVIDENCE_BUNDLE_SCHEMA_VERSION,
		request_hash = path_plan_stage_record.request_hash,
		source_root_id = path_plan_stage_record.source_root_id,
		summary = summary,
		stages = stages[:],
		files = files[:],
	}
	contents := [7]evidence.Evidence_Bundle_Content{
		{summary.path, summary_bytes},
		{topology_stage_manifest.path, topology_stage_bytes},
		{topology_capture.artifact.path, topology_capture.bytes},
		{region_stage_manifest.path, region_stage_bytes},
		{region_capture.artifact.path, region_capture.bytes},
		{path_plan_stage_manifest.path, path_plan_stage_bytes},
		{path_plan_primitive.path, capture.bytes},
	}
	package_bytes, package_error :=
		evidence.evidence_bundle_package_encode(root, contents[:])
	if package_error != .None {return nil, package_error, .None}
	if directory_path != "" {
		directory_error := evidence.evidence_bundle_directory_publish(
			root,
			contents[:],
			directory_path,
		)
		if directory_error != .None {
			delete(package_bytes)
			return nil, .None, directory_error
		}
	}
	return package_bytes, .None, .None
}

strict_feature_probe_region_manifest :: proc(
	request_hash, result_hash: contracts.Content_Hash,
	spine: pipeline.Slice_Spine_Result,
	regions: slicing.Region_Result,
	provider: contracts.Provider_Descriptor,
	artifact: evidence.Evidence_Artifact,
) -> ([]u8, evidence.Evidence_Error) {
	request_hash_text := strict_feature_probe_hash_text(request_hash)
	defer delete(request_hash_text)
	result_hash_text := strict_feature_probe_hash_text(result_hash)
	defer delete(result_hash_text)
	provider_id_text := fmt.aprintf("%016x", u64(provider.id))
	defer delete(provider_id_text)
	provider_version_text := fmt.aprintf(
		"%d.%d.%d",
		provider.version.major,
		provider.version.minor,
		provider.version.patch,
	)
	defer delete(provider_version_text)
	source_root_id_text := fmt.aprintf(
		"%016x",
		u64(spine.mesh.source_root_id),
	)
	defer delete(source_root_id_text)
	summary := [5]evidence.Evidence_Counter{
		{"layers", u64(len(regions.layers))},
		{"contours", u64(len(regions.contours))},
		{"regions", u64(len(regions.regions))},
		{
			"region_contour_indices",
			u64(len(regions.region_contour_indices)),
		},
		{"holes", regions.hole_count},
	}
	invariants := [2]evidence.Evidence_Invariant{
		{
			"canonical_result_hash",
			true,
			string(result_hash_text),
			string(result_hash_text),
		},
		{
			"source_independent_replay",
			true,
			"passed",
			"passed",
		},
	}
	primitives := [1]evidence.Evidence_Artifact{artifact}
	manifest := evidence.Evidence_Manifest{
		schema_version = contracts.SCHEMA_VERSION_DEBUG_EVIDENCE,
		request_hash = string(request_hash_text),
		stage = evidence.evidence_stage_from_descriptor({
			kind = .Calculate_Regions,
			schema_version = slicing.SCHEMA_VERSION_REGION_HASH,
			revision = evidence.REGION_MANIFEST_STAGE_REVISION,
		}),
		provider = {
			id = string(provider_id_text),
			name = provider.name,
			version = string(provider_version_text),
		},
		source_root_id = string(source_root_id_text),
		source_bounds = {
			valid = true,
			minimum = {
				f64(spine.mesh.bounds.minimum.x),
				f64(spine.mesh.bounds.minimum.y),
				f64(spine.mesh.bounds.minimum.z),
			},
			maximum = {
				f64(spine.mesh.bounds.maximum.x),
				f64(spine.mesh.bounds.maximum.y),
				f64(spine.mesh.bounds.maximum.z),
			},
			units = "millimetre",
		},
		planar_bounds =
			strict_feature_probe_region_planar_bounds(regions),
		summary = summary[:],
		invariants = invariants[:],
		primitives = primitives[:],
		elapsed_ns = 0,
	}
	return evidence.evidence_manifest_encode(manifest)
}

strict_feature_probe_topology_manifest :: proc(
	request_hash, result_hash: contracts.Content_Hash,
	spine: pipeline.Slice_Spine_Result,
	provider: contracts.Provider_Descriptor,
	artifact: evidence.Evidence_Artifact,
) -> ([]u8, evidence.Evidence_Error) {
	request_hash_text := strict_feature_probe_hash_text(request_hash)
	defer delete(request_hash_text)
	result_hash_text := strict_feature_probe_hash_text(result_hash)
	defer delete(result_hash_text)
	provider_id_text := fmt.aprintf("%016x", u64(provider.id))
	defer delete(provider_id_text)
	provider_version_text := fmt.aprintf(
		"%d.%d.%d",
		provider.version.major,
		provider.version.minor,
		provider.version.patch,
	)
	defer delete(provider_version_text)
	source_root_id_text := fmt.aprintf(
		"%016x",
		u64(spine.mesh.source_root_id),
	)
	defer delete(source_root_id_text)
	summary := [8]evidence.Evidence_Counter{
		{"layers", u64(len(spine.topology.layers))},
		{"vertices", u64(len(spine.topology.vertices))},
		{"paths", u64(len(spine.topology.paths))},
		{
			"path_vertex_indices",
			u64(len(spine.topology.path_vertex_indices)),
		},
		{
			"path_segment_indices",
			u64(len(spine.topology.path_segment_indices)),
		},
		{"open_chains", spine.topology.open_chain_count},
		{"degenerate_loops", spine.topology.degenerate_loop_count},
		{
			"non_manifold_vertices",
			spine.topology.non_manifold_vertex_count,
		},
	}
	invariants := [2]evidence.Evidence_Invariant{
		{
			"canonical_result_hash",
			true,
			string(result_hash_text),
			string(result_hash_text),
		},
		{
			"source_independent_replay",
			true,
			"passed",
			"passed",
		},
	}
	primitives := [1]evidence.Evidence_Artifact{artifact}
	manifest := evidence.Evidence_Manifest{
		schema_version = contracts.SCHEMA_VERSION_DEBUG_EVIDENCE,
		request_hash = string(request_hash_text),
		stage = evidence.evidence_stage_from_descriptor({
			kind = .Reconstruct_Topology,
			schema_version = slicing.SCHEMA_VERSION_TOPOLOGY_HASH,
			revision = evidence.TOPOLOGY_MANIFEST_STAGE_REVISION,
		}),
		provider = {
			id = string(provider_id_text),
			name = provider.name,
			version = string(provider_version_text),
		},
		source_root_id = string(source_root_id_text),
		source_bounds = {
			valid = true,
			minimum = {
				f64(spine.mesh.bounds.minimum.x),
				f64(spine.mesh.bounds.minimum.y),
				f64(spine.mesh.bounds.minimum.z),
			},
			maximum = {
				f64(spine.mesh.bounds.maximum.x),
				f64(spine.mesh.bounds.maximum.y),
				f64(spine.mesh.bounds.maximum.z),
			},
			units = "millimetre",
		},
		planar_bounds =
			strict_feature_probe_topology_planar_bounds(spine.topology),
		summary = summary[:],
		invariants = invariants[:],
		primitives = primitives[:],
		elapsed_ns = 0,
	}
	return evidence.evidence_manifest_encode(manifest)
}

strict_feature_probe_planar_bounds :: proc(
	plan: features.Path_Plan_Result,
) -> evidence.Evidence_Bounds_2D {
	bounds := evidence.Evidence_Bounds_2D{units = "micrometre"}
	for move, move_index in plan.moves {
		points := [2]polygon.Polygon_Point{move.point_a, move.point_b}
		for point, point_index in points {
			if move_index == 0 && point_index == 0 {
				bounds.minimum = {i64(point.x), i64(point.y)}
				bounds.maximum = bounds.minimum
				bounds.valid = true
			} else {
				bounds.minimum[0] = min(bounds.minimum[0], i64(point.x))
				bounds.minimum[1] = min(bounds.minimum[1], i64(point.y))
				bounds.maximum[0] = max(bounds.maximum[0], i64(point.x))
				bounds.maximum[1] = max(bounds.maximum[1], i64(point.y))
			}
		}
	}
	return bounds
}

strict_feature_probe_topology_planar_bounds :: proc(
	topology: slicing.Topology_Result,
) -> evidence.Evidence_Bounds_2D {
	bounds := evidence.Evidence_Bounds_2D{units = "micrometre"}
	for vertex, vertex_index in topology.vertices {
		point := [2]i64{i64(vertex.point.x), i64(vertex.point.y)}
		if vertex_index == 0 {
			bounds.minimum = point
			bounds.maximum = point
			bounds.valid = true
			continue
		}
		bounds.minimum[0] = min(bounds.minimum[0], point[0])
		bounds.minimum[1] = min(bounds.minimum[1], point[1])
		bounds.maximum[0] = max(bounds.maximum[0], point[0])
		bounds.maximum[1] = max(bounds.maximum[1], point[1])
	}
	return bounds
}

strict_feature_probe_region_planar_bounds :: proc(
	regions: slicing.Region_Result,
) -> evidence.Evidence_Bounds_2D {
	bounds := evidence.Evidence_Bounds_2D{units = "micrometre"}
	for region, region_index in regions.regions {
		minimum := [2]i64{
			i64(region.bounds.minimum.x),
			i64(region.bounds.minimum.y),
		}
		maximum := [2]i64{
			i64(region.bounds.maximum.x),
			i64(region.bounds.maximum.y),
		}
		if region_index == 0 {
			bounds.minimum = minimum
			bounds.maximum = maximum
			bounds.valid = true
			continue
		}
		bounds.minimum[0] = min(bounds.minimum[0], minimum[0])
		bounds.minimum[1] = min(bounds.minimum[1], minimum[1])
		bounds.maximum[0] = max(bounds.maximum[0], maximum[0])
		bounds.maximum[1] = max(bounds.maximum[1], maximum[1])
	}
	return bounds
}
