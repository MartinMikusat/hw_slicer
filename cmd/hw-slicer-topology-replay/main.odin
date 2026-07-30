package main

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:time"

import contracts "../../src/contracts"
import evidence "../../src/evidence"
import formats "../../src/formats"
import slicing "../../src/slicing"

Topology_Replay_Wire :: struct {
	schema_version:             u32,
	artifact:                   string,
	artifact_format:            string,
	artifact_schema_version:    u32,
	artifact_bytes:             u64,
	artifact_sha256:            string,
	snapped_hash:               string,
	topology_hash:              string,
	source_segment_count:       u64,
	layer_count:                u64,
	vertex_count:               u64,
	path_count:                 u64,
	path_vertex_index_count:    u64,
	path_segment_index_count:   u64,
	open_chain_count:           u64,
	degenerate_loop_count:      u64,
	non_manifold_vertex_count:  u64,
	region_count:               u64,
	contour_count:              u64,
	region_contour_index_count: u64,
	hole_count:                 u64,
	region_hash:                string,
	validated:                  bool,
}

Topology_Only_Replay_Wire :: struct {
	schema_version:            u32,
	artifact:                  string,
	artifact_format:           string,
	artifact_schema_version:   u32,
	artifact_bytes:            u64,
	artifact_sha256:           string,
	snapped_hash:              string,
	topology_hash:             string,
	source_segment_count:      u64,
	layer_count:               u64,
	vertex_count:              u64,
	path_count:                u64,
	path_vertex_index_count:   u64,
	path_segment_index_count:  u64,
	open_chain_count:          u64,
	degenerate_loop_count:     u64,
	non_manifold_vertex_count: u64,
	validated:                 bool,
}

Topology_Replay_Benchmark_Environment :: struct {
	hardware:      string,
	os_build:      string,
	odin_version:  string,
	clang_version: string,
	git_revision:  string,
	git_dirty:     string,
	thermal_state: string,
}

Topology_Replay_Benchmark_Wire :: struct {
	schema_version:          u32,
	benchmark:               string,
	fixture:                 string,
	mode:                    string,
	environment:             Topology_Replay_Benchmark_Environment,
	warmup_count:            int,
	iteration_count:         int,
	artifact_bytes:          u64,
	artifact_sha256:         string,
	topology_hash:           string,
	region_hash:             string,
	layer_count:             u64,
	vertex_count:            u64,
	path_count:              u64,
	path_vertex_index_count: u64,
	path_segment_index_count: u64,
	capture_samples_ns:      []u64,
	capture_p50_ns:          u64,
	capture_p95_ns:          u64,
	capture_mib_per_second:  f64,
	replay_samples_ns:       []u64,
	replay_p50_ns:           u64,
	replay_p95_ns:           u64,
	replay_mib_per_second:   f64,
	validated:               bool,
}

Region_Replay_Benchmark_Wire :: struct {
	schema_version:          u32,
	benchmark:               string,
	fixture:                 string,
	mode:                    string,
	environment:             Topology_Replay_Benchmark_Environment,
	warmup_count:            int,
	iteration_count:         int,
	topology_hash:           string,
	artifact_bytes:          u64,
	artifact_sha256:         string,
	region_hash:             string,
	layer_count:             u64,
	contour_count:           u64,
	region_count:            u64,
	region_contour_index_count: u64,
	hole_count:              u64,
	capture_samples_ns:      []u64,
	capture_p50_ns:          u64,
	capture_p95_ns:          u64,
	capture_mib_per_second:  f64,
	replay_samples_ns:       []u64,
	replay_p50_ns:           u64,
	replay_p95_ns:           u64,
	replay_mib_per_second:   f64,
	validated:               bool,
}

main :: proc() {
	benchmark_mode := false
	region_benchmark_mode := false
	topology_only_mode := false
	manifest_path := ""
	artifact_path := ""
	if len(os.args) == 2 {
		artifact_path = os.args[1]
	} else if len(os.args) == 3 && os.args[1] == "--benchmark" {
		benchmark_mode = true
		artifact_path = os.args[2]
	} else if len(os.args) == 3 &&
	          os.args[1] == "--benchmark-regions" {
		region_benchmark_mode = true
		artifact_path = os.args[2]
	} else if len(os.args) == 3 && os.args[1] == "--topology-only" {
		topology_only_mode = true
		artifact_path = os.args[2]
	} else if len(os.args) == 4 && os.args[1] == "--manifest" {
		manifest_path = os.args[2]
		artifact_path = os.args[3]
	} else if len(os.args) == 5 &&
	          os.args[1] == "--topology-only" &&
	          os.args[2] == "--manifest" {
		topology_only_mode = true
		manifest_path = os.args[3]
		artifact_path = os.args[4]
	} else {
		fmt.eprintln(
			"usage: hw-slicer-topology-replay [--benchmark] [--benchmark-regions] [--topology-only] [--manifest <manifest>] <topology-artifact>",
		)
		os.exit(2)
	}
	bytes, read_ok := topology_replay_read_file_bounded(
		artifact_path,
		u64(evidence.TOPOLOGY_ARTIFACT_HEADER_SIZE),
		evidence.DEFAULT_TOPOLOGY_ARTIFACT_LIMITS.max_bytes,
		"topology artifact",
	)
	if !read_ok {os.exit(1)}
	defer delete(bytes)
	if benchmark_mode {
		topology_replay_benchmark(artifact_path, bytes)
		return
	}
	if region_benchmark_mode {
		region_replay_benchmark(artifact_path, bytes)
		return
	}

	manifest_expectations: evidence.Topology_Manifest_Expectations
	manifest_verified := false
	if manifest_path != "" {
		manifest_expectations, manifest_verified =
			topology_replay_verify_manifest(manifest_path, bytes)
		if !manifest_verified {os.exit(1)}
	}
	artifact, decode_error := evidence.topology_artifact_decode(bytes)
	if decode_error != .None {
		fmt.eprintf(
			"[hw_slicer] topology replay failed: %v\n",
			decode_error,
		)
		os.exit(1)
	}
	defer evidence.topology_artifact_destroy(&artifact)
	if manifest_verified {
		manifest_error := evidence.topology_manifest_replay_verify(
			manifest_expectations,
			artifact,
		)
		if manifest_error != .None {
			fmt.eprintf(
				"[hw_slicer] topology manifest replay mismatch: %v\n",
				manifest_error,
			)
			os.exit(1)
		}
	}
	if topology_only_mode {
		artifact_digest := topology_replay_sha256(bytes)
		artifact_hash_text := topology_replay_hash_text(artifact_digest)
		defer delete(artifact_hash_text)
		snapped_hash_text :=
			topology_replay_hash_text(artifact.snapped_hash)
		defer delete(snapped_hash_text)
		topology_hash_text :=
			topology_replay_hash_text(artifact.result_hash)
		defer delete(topology_hash_text)
		wire := Topology_Only_Replay_Wire{
			schema_version = 1,
			artifact = filepath.base(artifact_path),
			artifact_format = evidence.TOPOLOGY_ARTIFACT_FORMAT,
			artifact_schema_version =
				evidence.TOPOLOGY_ARTIFACT_SCHEMA_VERSION,
			artifact_bytes = u64(len(bytes)),
			artifact_sha256 = string(artifact_hash_text),
			snapped_hash = string(snapped_hash_text),
			topology_hash = string(topology_hash_text),
			source_segment_count = artifact.source_segment_count,
			layer_count = u64(len(artifact.result.layers)),
			vertex_count = u64(len(artifact.result.vertices)),
			path_count = u64(len(artifact.result.paths)),
			path_vertex_index_count =
				u64(len(artifact.result.path_vertex_indices)),
			path_segment_index_count =
				u64(len(artifact.result.path_segment_indices)),
			open_chain_count = artifact.result.open_chain_count,
			degenerate_loop_count =
				artifact.result.degenerate_loop_count,
			non_manifold_vertex_count =
				artifact.result.non_manifold_vertex_count,
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
			fmt.eprintln("[hw_slicer] topology replay encoding failed")
			os.exit(1)
		}
		defer delete(output)
		fmt.println(string(output))
		return
	}
	regions, region_error := slicing.regions_build(artifact.result)
	if region_error != .None {
		fmt.eprintf(
			"[hw_slicer] topology region reconstruction failed: %v\n",
			region_error,
		)
		os.exit(1)
	}
	defer slicing.region_result_destroy(&regions)
	region_hash, region_hash_ok := slicing.region_result_hash(
		artifact.result_hash,
		artifact.result,
		regions,
	)
	if !region_hash_ok {
		fmt.eprintln("[hw_slicer] topology region hash failed")
		os.exit(1)
	}

	artifact_digest := topology_replay_sha256(bytes)
	artifact_hash_text := topology_replay_hash_text(artifact_digest)
	defer delete(artifact_hash_text)
	snapped_hash_text := topology_replay_hash_text(artifact.snapped_hash)
	defer delete(snapped_hash_text)
	topology_hash_text := topology_replay_hash_text(artifact.result_hash)
	defer delete(topology_hash_text)
	region_hash_text := topology_replay_hash_text(region_hash)
	defer delete(region_hash_text)
	wire := Topology_Replay_Wire{
		schema_version = 1,
		artifact = filepath.base(artifact_path),
		artifact_format = evidence.TOPOLOGY_ARTIFACT_FORMAT,
		artifact_schema_version =
			evidence.TOPOLOGY_ARTIFACT_SCHEMA_VERSION,
		artifact_bytes = u64(len(bytes)),
		artifact_sha256 = string(artifact_hash_text),
		snapped_hash = string(snapped_hash_text),
		topology_hash = string(topology_hash_text),
		source_segment_count = artifact.source_segment_count,
		layer_count = u64(len(artifact.result.layers)),
		vertex_count = u64(len(artifact.result.vertices)),
		path_count = u64(len(artifact.result.paths)),
		path_vertex_index_count =
			u64(len(artifact.result.path_vertex_indices)),
		path_segment_index_count =
			u64(len(artifact.result.path_segment_indices)),
		open_chain_count = artifact.result.open_chain_count,
		degenerate_loop_count = artifact.result.degenerate_loop_count,
		non_manifold_vertex_count =
			artifact.result.non_manifold_vertex_count,
		region_count = u64(len(regions.regions)),
		contour_count = u64(len(regions.contours)),
		region_contour_index_count =
			u64(len(regions.region_contour_indices)),
		hole_count = regions.hole_count,
		region_hash = string(region_hash_text),
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
		fmt.eprintln("[hw_slicer] topology replay encoding failed")
		os.exit(1)
	}
	defer delete(output)
	fmt.println(string(output))
}

region_replay_benchmark :: proc(path: string, topology_bytes: []u8) {
	WARMUP_COUNT :: 2
	ITERATION_COUNT :: 20
	P95_LIMIT_NS :: u64(3_000_000_000)

	topology, topology_error :=
		evidence.topology_artifact_decode(topology_bytes)
	if topology_error != .None {
		fmt.eprintf(
			"[hw_slicer] region benchmark topology failed: %v\n",
			topology_error,
		)
		os.exit(1)
	}
	defer evidence.topology_artifact_destroy(&topology)
	regions, region_error := slicing.regions_build(topology.result)
	if region_error != .None {
		fmt.eprintf(
			"[hw_slicer] region benchmark reconstruction failed: %v\n",
			region_error,
		)
		os.exit(1)
	}
	defer slicing.region_result_destroy(&regions)
	region_hash, region_hash_ok := slicing.region_result_hash(
		topology.result_hash,
		topology.result,
		regions,
	)
	if !region_hash_ok {
		fmt.eprintln("[hw_slicer] region benchmark hash failed")
		os.exit(1)
	}
	item_count := u64(len(regions.layers))+
		u64(len(regions.contours))+
		u64(len(regions.regions))+
		u64(len(regions.region_contour_indices))
	reference_capture, reference_capture_error :=
		evidence.region_capture_encode(
			"regions.bin",
			{
				level = .Primitives,
				item_limit = item_count,
				byte_limit =
					evidence.DEFAULT_REGION_ARTIFACT_LIMITS.max_bytes,
			},
			{},
			topology.result_hash,
			topology.result,
			regions,
		)
	if reference_capture_error != .None {
		fmt.eprintf(
			"[hw_slicer] region benchmark capture fixture failed: %v\n",
			reference_capture_error,
		)
		os.exit(1)
	}
	defer evidence.region_capture_destroy(&reference_capture)
	artifact_bytes := reference_capture.artifact.byte_count
	artifact_sha256 := reference_capture.artifact.sha256
	capture_request := contracts.Evidence_Request{
		level = .Primitives,
		item_limit = item_count,
		byte_limit = artifact_bytes,
	}
	layer_count := u64(len(regions.layers))
	contour_count := u64(len(regions.contours))
	region_count := u64(len(regions.regions))
	index_count := u64(len(regions.region_contour_indices))

	for _ in 0..<WARMUP_COUNT {
		capture, capture_error := evidence.region_capture_encode(
			"regions.bin",
			capture_request,
			{},
			topology.result_hash,
			topology.result,
			regions,
		)
		if !region_replay_benchmark_capture_valid(
			capture,
			capture_error,
			artifact_sha256,
			artifact_bytes,
			item_count,
		) {
			evidence.region_capture_destroy(&capture)
			fmt.eprintln("[hw_slicer] region capture warmup changed")
			os.exit(1)
		}
		evidence.region_capture_destroy(&capture)
		replayed, replay_error := evidence.region_artifact_decode(
			reference_capture.bytes,
			topology.result_hash,
			topology.result,
		)
		if !region_replay_benchmark_result_valid(
			replayed,
			replay_error,
			region_hash,
			layer_count,
			contour_count,
			region_count,
			index_count,
		) {
			evidence.region_artifact_destroy(&replayed)
			fmt.eprintln("[hw_slicer] region replay warmup changed")
			os.exit(1)
		}
		evidence.region_artifact_destroy(&replayed)
	}
	capture_samples := make([]u64, ITERATION_COUNT)
	replay_samples := make([]u64, ITERATION_COUNT)
	if capture_samples == nil || replay_samples == nil {
		delete(capture_samples)
		delete(replay_samples)
		fmt.eprintln("[hw_slicer] region benchmark samples allocation failed")
		os.exit(1)
	}
	defer delete(capture_samples)
	defer delete(replay_samples)
	for sample_index in 0..<ITERATION_COUNT {
		started := time.tick_now()
		capture, capture_error := evidence.region_capture_encode(
			"regions.bin",
			capture_request,
			{},
			topology.result_hash,
			topology.result,
			regions,
		)
		capture_elapsed := time.tick_since(started)
		if !region_replay_benchmark_capture_valid(
			capture,
			capture_error,
			artifact_sha256,
			artifact_bytes,
			item_count,
		) {
			evidence.region_capture_destroy(&capture)
			fmt.eprintln("[hw_slicer] region capture benchmark changed")
			os.exit(1)
		}
		evidence.region_capture_destroy(&capture)
		capture_samples[sample_index] =
			u64(max(i64(capture_elapsed), 1))
		started = time.tick_now()
		replayed, replay_error := evidence.region_artifact_decode(
			reference_capture.bytes,
			topology.result_hash,
			topology.result,
		)
		replay_elapsed := time.tick_since(started)
		if !region_replay_benchmark_result_valid(
			replayed,
			replay_error,
			region_hash,
			layer_count,
			contour_count,
			region_count,
			index_count,
		) {
			evidence.region_artifact_destroy(&replayed)
			fmt.eprintln("[hw_slicer] region replay benchmark changed")
			os.exit(1)
		}
		evidence.region_artifact_destroy(&replayed)
		replay_samples[sample_index] =
			u64(max(i64(replay_elapsed), 1))
	}
	topology_replay_sort_u64(capture_samples)
	topology_replay_sort_u64(replay_samples)
	capture_p50_ns := capture_samples[len(capture_samples)/2]
	replay_p50_ns := replay_samples[len(replay_samples)/2]
	p95_index := (95*ITERATION_COUNT+99)/100-1
	capture_p95_ns := capture_samples[p95_index]
	replay_p95_ns := replay_samples[p95_index]
	if capture_p95_ns > P95_LIMIT_NS {
		fmt.eprintf(
			"[hw_slicer] region capture p95 exceeded limit: %d > %d ns\n",
			capture_p95_ns,
			P95_LIMIT_NS,
		)
		os.exit(1)
	}
	if replay_p95_ns > P95_LIMIT_NS {
		fmt.eprintf(
			"[hw_slicer] region replay p95 exceeded limit: %d > %d ns\n",
			replay_p95_ns,
			P95_LIMIT_NS,
		)
		os.exit(1)
	}
	topology_hash_text := topology_replay_hash_text(topology.result_hash)
	defer delete(topology_hash_text)
	region_hash_text := topology_replay_hash_text(region_hash)
	defer delete(region_hash_text)
	wire := Region_Replay_Benchmark_Wire{
		schema_version = 1,
		benchmark = "region-artifact-capture-replay",
		fixture = filepath.base(path),
		mode = "release",
		environment = topology_replay_benchmark_environment(),
		warmup_count = WARMUP_COUNT,
		iteration_count = ITERATION_COUNT,
		topology_hash = string(topology_hash_text),
		artifact_bytes = artifact_bytes,
		artifact_sha256 = artifact_sha256,
		region_hash = string(region_hash_text),
		layer_count = layer_count,
		contour_count = contour_count,
		region_count = region_count,
		region_contour_index_count = index_count,
		hole_count = regions.hole_count,
		capture_samples_ns = capture_samples,
		capture_p50_ns = capture_p50_ns,
		capture_p95_ns = capture_p95_ns,
		capture_mib_per_second =
			f64(artifact_bytes)*1_000_000_000/
			f64(capture_p50_ns)/(1024*1024),
		replay_samples_ns = replay_samples,
		replay_p50_ns = replay_p50_ns,
		replay_p95_ns = replay_p95_ns,
		replay_mib_per_second =
			f64(artifact_bytes)*1_000_000_000/
			f64(replay_p50_ns)/(1024*1024),
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
		fmt.eprintln("[hw_slicer] region benchmark encoding failed")
		os.exit(1)
	}
	defer delete(output)
	fmt.println(string(output))
}

region_replay_benchmark_capture_valid :: proc(
	capture: evidence.Region_Capture,
	capture_error: evidence.Region_Capture_Error,
	expected_sha256: string,
	byte_count, item_count: u64,
) -> bool {
	return capture_error == .None &&
	       capture.artifact.sha256 == expected_sha256 &&
	       capture.artifact.byte_count == byte_count &&
	       capture.artifact.item_count == item_count &&
	       u64(len(capture.bytes)) == byte_count
}

region_replay_benchmark_result_valid :: proc(
	artifact: evidence.Region_Artifact,
	decode_error: evidence.Region_Artifact_Error,
	expected_hash: contracts.Content_Hash,
	layer_count, contour_count, region_count, index_count: u64,
) -> bool {
	return decode_error == .None &&
	       artifact.result_hash == expected_hash &&
	       u64(len(artifact.result.layers)) == layer_count &&
	       u64(len(artifact.result.contours)) == contour_count &&
	       u64(len(artifact.result.regions)) == region_count &&
	       u64(len(artifact.result.region_contour_indices)) == index_count
}

topology_replay_benchmark_environment :: proc() ->
	Topology_Replay_Benchmark_Environment {
	return {
		hardware = os.get_env("HW_SLICER_BENCH_HARDWARE"),
		os_build = os.get_env("HW_SLICER_BENCH_OS_BUILD"),
		odin_version = os.get_env("HW_SLICER_BENCH_ODIN"),
		clang_version = os.get_env("HW_SLICER_BENCH_CLANG"),
		git_revision = os.get_env("HW_SLICER_BENCH_GIT"),
		git_dirty = os.get_env("HW_SLICER_BENCH_DIRTY"),
		thermal_state = os.get_env("HW_SLICER_BENCH_THERMAL"),
	}
}

topology_replay_benchmark :: proc(path: string, bytes: []u8) {
	WARMUP_COUNT :: 2
	ITERATION_COUNT :: 20
	P95_LIMIT_NS :: u64(3_000_000_000)

	reference, reference_error := evidence.topology_artifact_decode(bytes)
	if reference_error != .None {
		fmt.eprintf(
			"[hw_slicer] topology replay benchmark fixture failed: %v\n",
			reference_error,
		)
		os.exit(1)
	}
	defer evidence.topology_artifact_destroy(&reference)
	expected_hash := reference.result_hash
	layer_count := u64(len(reference.result.layers))
	vertex_count := u64(len(reference.result.vertices))
	path_count := u64(len(reference.result.paths))
	path_vertex_index_count :=
		u64(len(reference.result.path_vertex_indices))
	path_segment_index_count :=
		u64(len(reference.result.path_segment_indices))
	item_count := layer_count+vertex_count+path_count+
		path_vertex_index_count+path_segment_index_count
	artifact_digest := topology_replay_sha256(bytes)
	artifact_hash_text := topology_replay_hash_text(artifact_digest)
	defer delete(artifact_hash_text)
	capture_request := contracts.Evidence_Request{
		level = .Primitives,
		item_limit = item_count,
		byte_limit = u64(len(bytes)),
	}
	regions, region_error := slicing.regions_build(reference.result)
	if region_error != .None {
		fmt.eprintf(
			"[hw_slicer] topology benchmark region reconstruction failed: %v\n",
			region_error,
		)
		os.exit(1)
	}
	defer slicing.region_result_destroy(&regions)
	region_hash, region_hash_ok := slicing.region_result_hash(
		reference.result_hash,
		reference.result,
		regions,
	)
	if !region_hash_ok {
		fmt.eprintln("[hw_slicer] topology benchmark region hash failed")
		os.exit(1)
	}

	for _ in 0..<WARMUP_COUNT {
		capture, capture_error := evidence.topology_capture_encode(
			"topology.bin",
			capture_request,
			{},
			reference.snapped_hash,
			int(reference.source_segment_count),
			reference.result,
		)
		if !topology_replay_benchmark_capture_valid(
			capture,
			capture_error,
			string(artifact_hash_text),
			u64(len(bytes)),
			item_count,
		) {
			evidence.topology_capture_destroy(&capture)
			fmt.eprintln("[hw_slicer] topology capture warmup changed")
			os.exit(1)
		}
		evidence.topology_capture_destroy(&capture)

		replayed, replay_error := evidence.topology_artifact_decode(bytes)
		if !topology_replay_benchmark_result_valid(
			replayed,
			replay_error,
			expected_hash,
			layer_count,
			vertex_count,
			path_count,
			path_vertex_index_count,
			path_segment_index_count,
		) {
			evidence.topology_artifact_destroy(&replayed)
			fmt.eprintln("[hw_slicer] topology replay warmup changed")
			os.exit(1)
		}
		evidence.topology_artifact_destroy(&replayed)
	}

	capture_samples := make([]u64, ITERATION_COUNT)
	replay_samples := make([]u64, ITERATION_COUNT)
	if capture_samples == nil || replay_samples == nil {
		delete(capture_samples)
		delete(replay_samples)
		fmt.eprintln("[hw_slicer] topology replay samples allocation failed")
		os.exit(1)
	}
	defer delete(capture_samples)
	defer delete(replay_samples)
	for sample_index in 0..<ITERATION_COUNT {
		started := time.tick_now()
		capture, capture_error := evidence.topology_capture_encode(
			"topology.bin",
			capture_request,
			{},
			reference.snapped_hash,
			int(reference.source_segment_count),
			reference.result,
		)
		capture_elapsed := time.tick_since(started)
		if !topology_replay_benchmark_capture_valid(
			capture,
			capture_error,
			string(artifact_hash_text),
			u64(len(bytes)),
			item_count,
		) {
			evidence.topology_capture_destroy(&capture)
			fmt.eprintln("[hw_slicer] topology capture benchmark changed")
			os.exit(1)
		}
		evidence.topology_capture_destroy(&capture)
		capture_samples[sample_index] =
			u64(max(i64(capture_elapsed), 1))

		started = time.tick_now()
		replayed, replay_error := evidence.topology_artifact_decode(bytes)
		replay_elapsed := time.tick_since(started)
		if !topology_replay_benchmark_result_valid(
			replayed,
			replay_error,
			expected_hash,
			layer_count,
			vertex_count,
			path_count,
			path_vertex_index_count,
			path_segment_index_count,
		) {
			evidence.topology_artifact_destroy(&replayed)
			fmt.eprintln("[hw_slicer] topology replay benchmark changed")
			os.exit(1)
		}
		evidence.topology_artifact_destroy(&replayed)
		replay_samples[sample_index] =
			u64(max(i64(replay_elapsed), 1))
	}
	topology_replay_sort_u64(capture_samples)
	topology_replay_sort_u64(replay_samples)
	capture_p50_ns := capture_samples[len(capture_samples)/2]
	replay_p50_ns := replay_samples[len(replay_samples)/2]
	p95_index := (95*ITERATION_COUNT+99)/100-1
	capture_p95_ns := capture_samples[p95_index]
	replay_p95_ns := replay_samples[p95_index]
	if capture_p95_ns > P95_LIMIT_NS {
		fmt.eprintf(
			"[hw_slicer] topology capture p95 exceeded limit: %d > %d ns\n",
			capture_p95_ns,
			P95_LIMIT_NS,
		)
		os.exit(1)
	}
	if replay_p95_ns > P95_LIMIT_NS {
		fmt.eprintf(
			"[hw_slicer] topology replay p95 exceeded limit: %d > %d ns\n",
			replay_p95_ns,
			P95_LIMIT_NS,
		)
		os.exit(1)
	}
	topology_hash_text := topology_replay_hash_text(expected_hash)
	defer delete(topology_hash_text)
	region_hash_text := topology_replay_hash_text(region_hash)
	defer delete(region_hash_text)
	wire := Topology_Replay_Benchmark_Wire{
		schema_version = 1,
		benchmark = "topology-artifact-capture-replay",
		fixture = filepath.base(path),
		mode = "release",
		environment = {
			hardware = os.get_env("HW_SLICER_BENCH_HARDWARE"),
			os_build = os.get_env("HW_SLICER_BENCH_OS_BUILD"),
			odin_version = os.get_env("HW_SLICER_BENCH_ODIN"),
			clang_version = os.get_env("HW_SLICER_BENCH_CLANG"),
			git_revision = os.get_env("HW_SLICER_BENCH_GIT"),
			git_dirty = os.get_env("HW_SLICER_BENCH_DIRTY"),
			thermal_state = os.get_env("HW_SLICER_BENCH_THERMAL"),
		},
		warmup_count = WARMUP_COUNT,
		iteration_count = ITERATION_COUNT,
		artifact_bytes = u64(len(bytes)),
		artifact_sha256 = string(artifact_hash_text),
		topology_hash = string(topology_hash_text),
		region_hash = string(region_hash_text),
		layer_count = layer_count,
		vertex_count = vertex_count,
		path_count = path_count,
		path_vertex_index_count = path_vertex_index_count,
		path_segment_index_count = path_segment_index_count,
		capture_samples_ns = capture_samples,
		capture_p50_ns = capture_p50_ns,
		capture_p95_ns = capture_p95_ns,
		capture_mib_per_second =
			f64(len(bytes))*1_000_000_000/
			f64(capture_p50_ns)/(1024*1024),
		replay_samples_ns = replay_samples,
		replay_p50_ns = replay_p50_ns,
		replay_p95_ns = replay_p95_ns,
		replay_mib_per_second =
			f64(len(bytes))*1_000_000_000/
			f64(replay_p50_ns)/(1024*1024),
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
		fmt.eprintln("[hw_slicer] topology benchmark encoding failed")
		os.exit(1)
	}
	defer delete(output)
	fmt.println(string(output))
}

topology_replay_benchmark_capture_valid :: proc(
	capture: evidence.Topology_Capture,
	capture_error: evidence.Topology_Capture_Error,
	expected_sha256: string,
	byte_count, item_count: u64,
) -> bool {
	return capture_error == .None &&
	       capture.artifact.sha256 == expected_sha256 &&
	       capture.artifact.byte_count == byte_count &&
	       capture.artifact.item_count == item_count &&
	       u64(len(capture.bytes)) == byte_count
}

topology_replay_benchmark_result_valid :: proc(
	artifact: evidence.Topology_Artifact,
	decode_error: evidence.Topology_Artifact_Error,
	expected_hash: contracts.Content_Hash,
	layer_count, vertex_count, path_count: u64,
	path_vertex_index_count, path_segment_index_count: u64,
) -> bool {
	return decode_error == .None &&
	       artifact.result_hash == expected_hash &&
	       u64(len(artifact.result.layers)) == layer_count &&
	       u64(len(artifact.result.vertices)) == vertex_count &&
	       u64(len(artifact.result.paths)) == path_count &&
	       u64(len(artifact.result.path_vertex_indices)) ==
	       	path_vertex_index_count &&
	       u64(len(artifact.result.path_segment_indices)) ==
	       	path_segment_index_count
}

topology_replay_sort_u64 :: proc(values: []u64) {
	for index in 1..<len(values) {
		value := values[index]
		position := index
		for position > 0 && values[position-1] > value {
			values[position] = values[position-1]
			position -= 1
		}
		values[position] = value
	}
}

topology_replay_verify_manifest :: proc(
	manifest_path: string,
	artifact_bytes: []u8,
) -> (evidence.Topology_Manifest_Expectations, bool) {
	MANIFEST_BYTE_LIMIT :: u64(1024*1024)
	manifest_bytes, read_ok := topology_replay_read_file_bounded(
		manifest_path,
		1,
		MANIFEST_BYTE_LIMIT,
		"topology manifest",
	)
	if !read_ok {return {}, false}
	defer delete(manifest_bytes)
	manifest, decode_error :=
		evidence.evidence_manifest_decode(manifest_bytes)
	if decode_error != .None {
		fmt.eprintf(
			"[hw_slicer] topology manifest decode failed: %v\n",
			decode_error,
		)
		return {}, false
	}
	defer evidence.evidence_manifest_destroy(&manifest)
	artifact_path := ""
	for primitive in manifest.primitives {
		if primitive.format != evidence.TOPOLOGY_ARTIFACT_FORMAT {
			continue
		}
		if artifact_path != "" {
			fmt.eprintln(
				"[hw_slicer] topology manifest verification failed: Artifact_Missing",
			)
			return {}, false
		}
		artifact_path = primitive.path
	}
	if artifact_path == "" {
		fmt.eprintln(
			"[hw_slicer] topology manifest verification failed: Artifact_Missing",
		)
		return {}, false
	}
	expectations, verify_error := evidence.topology_manifest_preflight(
		manifest,
		artifact_path,
		artifact_bytes,
	)
	if verify_error != .None {
		fmt.eprintf(
			"[hw_slicer] topology manifest verification failed: %v\n",
			verify_error,
		)
		return {}, false
	}
	return expectations, true
}

topology_replay_read_file_bounded :: proc(
	path: string,
	minimum_byte_count: u64,
	maximum_byte_count: u64,
	label: string,
) -> ([]u8, bool) {
	bytes, read_error := formats.source_file_read_bounded(
		path,
		minimum_byte_count,
		maximum_byte_count,
	)
	switch read_error {
	case .None:
		return bytes, true
	case .Open_Failed:
		fmt.eprintf("[hw_slicer] cannot open %s: %s\n", label, path)
	case .Size_Limit:
		fmt.eprintf("[hw_slicer] %s size is outside the limit\n", label)
	case .Allocation_Failed:
		fmt.eprintf("[hw_slicer] %s allocation failed\n", label)
	case .Read_Failed:
		fmt.eprintf("[hw_slicer] %s read failed\n", label)
	case .Changed_During_Read:
		fmt.eprintf("[hw_slicer] %s changed during read\n", label)
	}
	return nil, false
}

topology_replay_sha256 :: proc(bytes: []u8) -> (
	digest: contracts.Content_Hash,
) {
	hash_context: sha2.Context_256
	sha2.init_256(&hash_context)
	sha2.update(&hash_context, bytes)
	sha2.final(&hash_context, digest[:])
	return
}

topology_replay_hash_text :: proc(
	hash: contracts.Content_Hash,
) -> []u8 {
	bytes := hash
	return hex.encode(bytes[:])
}
