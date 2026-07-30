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
import features "../../src/features"
import formats "../../src/formats"

Path_Plan_Replay_Wire :: struct {
	schema_version:          u32,
	artifact:                string,
	artifact_format:         string,
	artifact_schema_version: u32,
	artifact_bytes:          u64,
	artifact_sha256:         string,
	perimeter_hash:          string,
	infill_hash:             string,
	result_hash:             string,
	start_x_um:              i64,
	start_y_um:              i64,
	inner_perimeters_first:  bool,
	topology_policy:         string,
	layer_count:             u64,
	path_count:              u64,
	move_count:              u64,
	travel_move_count:       u64,
	extrude_move_count:      u64,
	validated:               bool,
}

Path_Plan_Replay_Benchmark_Environment :: struct {
	hardware:      string,
	os_build:      string,
	odin_version:  string,
	clang_version: string,
	git_revision:  string,
	git_dirty:     string,
	thermal_state: string,
}

Path_Plan_Replay_Benchmark_Wire :: struct {
	schema_version:        u32,
	benchmark:             string,
	fixture:               string,
	mode:                  string,
	environment:           Path_Plan_Replay_Benchmark_Environment,
	warmup_count:          int,
	iteration_count:       int,
	artifact_bytes:        u64,
	artifact_sha256:       string,
	result_hash:           string,
	layer_count:           u64,
	path_count:            u64,
	move_count:            u64,
	capture_samples_ns:    []u64,
	capture_p50_ns:        u64,
	capture_p95_ns:        u64,
	capture_mib_per_second: f64,
	replay_samples_ns:     []u64,
	replay_p50_ns:         u64,
	replay_p95_ns:         u64,
	replay_mib_per_second: f64,
	validated:             bool,
}

main :: proc() {
	benchmark_mode := false
	render_mode := false
	render_layer: u32
	manifest_path := ""
	artifact_path := ""
	if len(os.args) == 2 {
		artifact_path = os.args[1]
	} else if len(os.args) == 3 && os.args[1] == "--benchmark" {
		benchmark_mode = true
		artifact_path = os.args[2]
	} else if len(os.args) == 4 && os.args[1] == "--manifest" {
		manifest_path = os.args[2]
		artifact_path = os.args[3]
	} else if len(os.args) == 4 && os.args[1] == "--render-layer" {
		render_mode = true
		layer_ok: bool
		render_layer, layer_ok = path_plan_replay_parse_u32(os.args[2])
		if !layer_ok {
			fmt.eprintln("[hw_slicer] render layer must be a u32 index")
			os.exit(2)
		}
		artifact_path = os.args[3]
	} else if len(os.args) == 6 &&
	          os.args[1] == "--manifest" &&
	          os.args[3] == "--render-layer" {
		manifest_path = os.args[2]
		render_mode = true
		layer_ok: bool
		render_layer, layer_ok = path_plan_replay_parse_u32(os.args[4])
		if !layer_ok {
			fmt.eprintln("[hw_slicer] render layer must be a u32 index")
			os.exit(2)
		}
		artifact_path = os.args[5]
	} else {
		fmt.eprintln(
			"usage: hw-slicer-path-plan-replay [--benchmark] [--manifest <manifest>] [--render-layer <index>] <path-plan-artifact>",
		)
		os.exit(2)
	}
	bytes, read_ok := path_plan_replay_read_bounded(artifact_path)
	if !read_ok {os.exit(1)}
	defer delete(bytes)
	manifest_expectations: evidence.Path_Plan_Manifest_Expectations
	manifest_verified := false
	if manifest_path != "" {
		manifest_expectations, manifest_verified =
			path_plan_replay_verify_manifest(
				manifest_path,
				artifact_path,
				bytes,
			)
		if !manifest_verified {os.exit(1)}
	}
	if benchmark_mode {
		path_plan_replay_benchmark(artifact_path, bytes)
		return
	}

	artifact, decode_error := evidence.path_plan_artifact_decode(bytes)
	if decode_error != .None {
		fmt.eprintf(
			"[hw_slicer] path-plan replay failed: %v\n",
			decode_error,
		)
		os.exit(1)
	}
	defer evidence.path_plan_artifact_destroy(&artifact)
	if manifest_verified {
		manifest_error := evidence.path_plan_manifest_replay_verify(
			manifest_expectations,
			artifact,
		)
		if manifest_error != .None {
			fmt.eprintf(
				"[hw_slicer] path-plan manifest replay mismatch: %v\n",
				manifest_error,
			)
			os.exit(1)
		}
	}
	if render_mode {
		svg, render_error := evidence.path_plan_svg_render_layer(
			artifact,
			render_layer,
		)
		if render_error != .None {
			fmt.eprintf(
				"[hw_slicer] path-plan layer render failed: %v\n",
				render_error,
			)
			os.exit(1)
		}
		defer delete(svg)
		fmt.print(string(svg))
		return
	}

	artifact_digest := path_plan_replay_sha256(bytes)
	artifact_hash_text := path_plan_replay_hash_text(artifact_digest)
	defer delete(artifact_hash_text)
	perimeter_hash_text := path_plan_replay_hash_text(
		artifact.perimeter_hash,
	)
	defer delete(perimeter_hash_text)
	infill_hash_text := path_plan_replay_hash_text(artifact.infill_hash)
	defer delete(infill_hash_text)
	result_hash_text := path_plan_replay_hash_text(artifact.result_hash)
	defer delete(result_hash_text)
	wire := Path_Plan_Replay_Wire{
		schema_version = 1,
		artifact = filepath.base(artifact_path),
		artifact_format = evidence.PATH_PLAN_ARTIFACT_FORMAT,
		artifact_schema_version =
			evidence.PATH_PLAN_ARTIFACT_SCHEMA_VERSION,
		artifact_bytes = u64(len(bytes)),
		artifact_sha256 = string(artifact_hash_text),
		perimeter_hash = string(perimeter_hash_text),
		infill_hash = string(infill_hash_text),
		result_hash = string(result_hash_text),
		start_x_um = i64(artifact.result.config.start.x),
		start_y_um = i64(artifact.result.config.start.y),
		inner_perimeters_first =
			artifact.result.config.inner_perimeters_first,
		topology_policy = path_plan_replay_topology_policy_name(
			artifact.result.topology_policy,
		),
		layer_count = u64(len(artifact.result.layers)),
		path_count = u64(len(artifact.result.paths)),
		move_count = u64(len(artifact.result.moves)),
		travel_move_count = artifact.result.travel_move_count,
		extrude_move_count = artifact.result.extrude_move_count,
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
		fmt.eprintln("[hw_slicer] path-plan replay encoding failed")
		os.exit(1)
	}
	defer delete(output)
	fmt.println(string(output))
}

path_plan_replay_benchmark :: proc(path: string, bytes: []u8) {
	WARMUP_COUNT :: 2
	ITERATION_COUNT :: 20
	P95_LIMIT_NS :: u64(3_000_000_000)

	reference, reference_error := evidence.path_plan_artifact_decode(bytes)
	if reference_error != .None {
		fmt.eprintf(
			"[hw_slicer] path-plan replay benchmark fixture failed: %v\n",
			reference_error,
		)
		os.exit(1)
	}
	expected_hash := reference.result_hash
	layer_count := u64(len(reference.result.layers))
	path_count := u64(len(reference.result.paths))
	move_count := u64(len(reference.result.moves))
	defer evidence.path_plan_artifact_destroy(&reference)
	item_count := layer_count+path_count+move_count
	artifact_digest := path_plan_replay_sha256(bytes)
	artifact_hash_text := path_plan_replay_hash_text(artifact_digest)
	defer delete(artifact_hash_text)
	capture_request := contracts.Evidence_Request{
		level = .Primitives,
		item_limit = item_count,
		byte_limit = u64(len(bytes)),
	}

	for _ in 0..<WARMUP_COUNT {
		capture, capture_error := evidence.path_plan_capture_encode(
			"path-plan.bin",
			capture_request,
			{},
			reference.perimeter_hash,
			reference.infill_hash,
			reference.result,
		)
		if !path_plan_replay_benchmark_capture_valid(
			capture,
			capture_error,
			string(artifact_hash_text),
			u64(len(bytes)),
			item_count,
		) {
			evidence.path_plan_capture_destroy(&capture)
			fmt.eprintln("[hw_slicer] path-plan capture warmup changed")
			os.exit(1)
		}
		evidence.path_plan_capture_destroy(&capture)

		replayed, replay_error := evidence.path_plan_artifact_decode(bytes)
		if !path_plan_replay_benchmark_result_valid(
			replayed,
			replay_error,
			expected_hash,
			layer_count,
			path_count,
			move_count,
		) {
			evidence.path_plan_artifact_destroy(&replayed)
			fmt.eprintln("[hw_slicer] path-plan replay warmup changed")
			os.exit(1)
		}
		evidence.path_plan_artifact_destroy(&replayed)
	}

	capture_samples := make([]u64, ITERATION_COUNT)
	replay_samples := make([]u64, ITERATION_COUNT)
	if capture_samples == nil || replay_samples == nil {
		delete(capture_samples)
		delete(replay_samples)
		fmt.eprintln("[hw_slicer] path-plan replay samples allocation failed")
		os.exit(1)
	}
	defer delete(capture_samples)
	defer delete(replay_samples)
	for sample_index in 0..<ITERATION_COUNT {
		started := time.tick_now()
		capture, capture_error := evidence.path_plan_capture_encode(
			"path-plan.bin",
			capture_request,
			{},
			reference.perimeter_hash,
			reference.infill_hash,
			reference.result,
		)
		capture_elapsed := time.tick_since(started)
		if !path_plan_replay_benchmark_capture_valid(
			capture,
			capture_error,
			string(artifact_hash_text),
			u64(len(bytes)),
			item_count,
		) {
			evidence.path_plan_capture_destroy(&capture)
			fmt.eprintln("[hw_slicer] path-plan capture benchmark changed")
			os.exit(1)
		}
		evidence.path_plan_capture_destroy(&capture)
		capture_samples[sample_index] =
			u64(max(i64(capture_elapsed), 1))

		started = time.tick_now()
		replayed, replay_error := evidence.path_plan_artifact_decode(bytes)
		replay_elapsed := time.tick_since(started)
		if !path_plan_replay_benchmark_result_valid(
			replayed,
			replay_error,
			expected_hash,
			layer_count,
			path_count,
			move_count,
		) {
			evidence.path_plan_artifact_destroy(&replayed)
			fmt.eprintln("[hw_slicer] path-plan replay benchmark changed")
			os.exit(1)
		}
		evidence.path_plan_artifact_destroy(&replayed)
		replay_samples[sample_index] =
			u64(max(i64(replay_elapsed), 1))
	}
	path_plan_replay_sort_u64(capture_samples)
	path_plan_replay_sort_u64(replay_samples)
	capture_p50_ns := capture_samples[len(capture_samples)/2]
	replay_p50_ns := replay_samples[len(replay_samples)/2]
	p95_index := (95*ITERATION_COUNT+99)/100-1
	capture_p95_ns := capture_samples[p95_index]
	replay_p95_ns := replay_samples[p95_index]
	if capture_p95_ns > P95_LIMIT_NS {
		fmt.eprintf(
			"[hw_slicer] path-plan capture p95 exceeded limit: %d > %d ns\n",
			capture_p95_ns,
			P95_LIMIT_NS,
		)
		os.exit(1)
	}
	if replay_p95_ns > P95_LIMIT_NS {
		fmt.eprintf(
			"[hw_slicer] path-plan replay p95 exceeded limit: %d > %d ns\n",
			replay_p95_ns,
			P95_LIMIT_NS,
		)
		os.exit(1)
	}
	result_hash_text := path_plan_replay_hash_text(expected_hash)
	defer delete(result_hash_text)
	wire := Path_Plan_Replay_Benchmark_Wire{
		schema_version = 2,
		benchmark = "path-plan-artifact-capture-replay",
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
		result_hash = string(result_hash_text),
		layer_count = layer_count,
		path_count = path_count,
		move_count = move_count,
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
		fmt.eprintln("[hw_slicer] path-plan benchmark encoding failed")
		os.exit(1)
	}
	defer delete(output)
	fmt.println(string(output))
}

path_plan_replay_benchmark_capture_valid :: proc(
	capture: evidence.Path_Plan_Capture,
	capture_error: evidence.Path_Plan_Capture_Error,
	expected_sha256: string,
	byte_count, item_count: u64,
) -> bool {
	return capture_error == .None &&
	       capture.artifact.sha256 == expected_sha256 &&
	       capture.artifact.byte_count == byte_count &&
	       capture.artifact.item_count == item_count &&
	       u64(len(capture.bytes)) == byte_count
}

path_plan_replay_benchmark_result_valid :: proc(
	artifact: evidence.Path_Plan_Artifact,
	decode_error: evidence.Path_Plan_Artifact_Error,
	expected_hash: contracts.Content_Hash,
	layer_count, path_count, move_count: u64,
) -> bool {
	return decode_error == .None &&
	       artifact.result_hash == expected_hash &&
	       u64(len(artifact.result.layers)) == layer_count &&
	       u64(len(artifact.result.paths)) == path_count &&
	       u64(len(artifact.result.moves)) == move_count
}

path_plan_replay_sort_u64 :: proc(values: []u64) {
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

path_plan_replay_read_bounded :: proc(path: string) -> ([]u8, bool) {
	return path_plan_replay_read_file_bounded(
		path,
		u64(evidence.PATH_PLAN_ARTIFACT_HEADER_SIZE),
		evidence.DEFAULT_PATH_PLAN_ARTIFACT_LIMITS.max_bytes,
		"path-plan artifact",
	)
}

path_plan_replay_read_file_bounded :: proc(
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

path_plan_replay_verify_manifest :: proc(
	manifest_path, artifact_path: string,
	artifact_bytes: []u8,
) -> (evidence.Path_Plan_Manifest_Expectations, bool) {
	MANIFEST_BYTE_LIMIT :: u64(1024*1024)
	manifest_bytes, read_ok := path_plan_replay_read_file_bounded(
		manifest_path,
		1,
		MANIFEST_BYTE_LIMIT,
		"path-plan manifest",
	)
	if !read_ok {return {}, false}
	defer delete(manifest_bytes)
	manifest, decode_error :=
		evidence.evidence_manifest_decode(manifest_bytes)
	if decode_error != .None {
		fmt.eprintf(
			"[hw_slicer] path-plan manifest decode failed: %v\n",
			decode_error,
		)
		return {}, false
	}
	defer evidence.evidence_manifest_destroy(&manifest)
	expectations, verify_error := evidence.path_plan_manifest_preflight(
		manifest,
		filepath.base(artifact_path),
		artifact_bytes,
	)
	if verify_error != .None {
		fmt.eprintf(
			"[hw_slicer] path-plan manifest verification failed: %v\n",
			verify_error,
		)
		return {}, false
	}
	return expectations, true
}

path_plan_replay_parse_u32 :: proc(value: string) -> (u32, bool) {
	if value == "" {return 0, false}
	result: u64
	for byte in transmute([]u8)value {
		if byte < '0' || byte > '9' {return 0, false}
		digit := u64(byte-'0')
		if result > (u64(max(u32))-digit)/10 {return 0, false}
		result = result*10+digit
	}
	return u32(result), true
}

path_plan_replay_sha256 :: proc(bytes: []u8) -> (
	digest: contracts.Content_Hash,
) {
	hash_context: sha2.Context_256
	sha2.init_256(&hash_context)
	sha2.update(&hash_context, bytes)
	sha2.final(&hash_context, digest[:])
	return
}

path_plan_replay_hash_text :: proc(
	hash: contracts.Content_Hash,
) -> []u8 {
	bytes := hash
	return hex.encode(bytes[:])
}

path_plan_replay_topology_policy_name :: proc(
	policy: features.Feature_Topology_Policy,
) -> string {
	switch policy {
	case .Strict_Printable:          return "strict-printable"
	case .Diagnostic_Closed_Regions: return "diagnostic-closed-regions"
	}
	return "invalid"
}
