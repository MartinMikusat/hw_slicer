package main

import "base:intrinsics"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:time"

import benchmark "../../src/benchmark"
import contracts "../../src/contracts"
import polygon "../../src/polygon"

POLYGON_BENCHMARK_GRID_SIZE :: 64
POLYGON_BENCHMARK_WARMUP_COUNT :: 2
POLYGON_BENCHMARK_ITERATION_COUNT :: 7
POLYGON_BENCHMARK_MINIMUM_EDGES_PER_SECOND :: f64(1_000_000)
POLYGON_BENCHMARK_EXPECTED_HASH :: contracts.Content_Hash{
	0xd4, 0x7f, 0x8d, 0x5c, 0x57, 0xb0, 0xe8, 0xb8,
	0x51, 0x1c, 0xdc, 0xd8, 0x0f, 0xa9, 0x26, 0xd0,
	0x9a, 0x8c, 0x31, 0xad, 0x43, 0x16, 0x84, 0x80,
	0x6c, 0xc4, 0x82, 0x31, 0xbc, 0x26, 0x82, 0x52,
}

Polygon_Benchmark_Environment :: struct {
	hardware:      string,
	os_build:      string,
	odin_version:  string,
	clang_version: string,
	git_revision:  string,
	git_dirty:     string,
	thermal_state: string,
}

Polygon_Benchmark_Wire :: struct {
	schema_version:          u32,
	benchmark:               string,
	fixture_version:         u32,
	provider:                string,
	provider_version:        string,
	mode:                    string,
	environment:             Polygon_Benchmark_Environment,
	warmup_count:            int,
	iteration_count:         int,
	input_path_count:        u64,
	input_edge_count:        u64,
	output_path_count:       u64,
	output_point_count:      u64,
	output_hash:             string,
	samples_ns:              []u64,
	p50_ns:                  u64,
	p95_ns:                  u64,
	input_edges_per_second:  f64,
	minimum_edges_per_second: f64,
	validated:               bool,
}

polygon_benchmark_sink: u64

main :: proc() {
	input := polygon_benchmark_fixture()
	defer polygon.polygon_set_destroy(&input)
	for _ in 0..<POLYGON_BENCHMARK_WARMUP_COUNT {
		hash, path_count, point_count, ok := polygon_benchmark_run_once(input)
		if !ok {os.exit(1)}
		intrinsics.volatile_store(
			&polygon_benchmark_sink,
			polygon_benchmark_hash_word(hash)~path_count~point_count,
		)
	}
	samples := make([]u64, POLYGON_BENCHMARK_ITERATION_COUNT)
	defer delete(samples)
	reference_hash: contracts.Content_Hash
	reference_path_count, reference_point_count: u64
	for iteration in 0..<POLYGON_BENCHMARK_ITERATION_COUNT {
		started := time.tick_now()
		hash, path_count, point_count, ok :=
			polygon_benchmark_run_once(input)
		elapsed := time.tick_since(started)
		if !ok {os.exit(1)}
		if iteration == 0 {
			reference_hash = hash
			reference_path_count = path_count
			reference_point_count = point_count
		} else if hash != reference_hash ||
		          path_count != reference_path_count ||
		          point_count != reference_point_count {
			fmt.eprintln("[hw_slicer] polygon benchmark output changed")
			os.exit(1)
		}
		samples[iteration] = u64(max(i64(elapsed), 1))
		intrinsics.volatile_store(
			&polygon_benchmark_sink,
			polygon_benchmark_hash_word(hash)~path_count~point_count,
		)
	}
	if reference_hash != POLYGON_BENCHMARK_EXPECTED_HASH {
		hash_text := hex.encode(reference_hash[:])
		fmt.eprintf(
			"[hw_slicer] polygon benchmark hash mismatch: %s\n",
			string(hash_text),
		)
		delete(hash_text)
		os.exit(1)
	}
	benchmark.sort_u64(samples)
	p50_ns := samples[len(samples)/2]
	p95_index := (95*len(samples)+99)/100-1
	p95_ns := samples[p95_index]
	input_edge_count := u64(len(input.points))
	edges_per_second :=
		f64(input_edge_count)*1_000_000_000/f64(p50_ns)
	if edges_per_second < POLYGON_BENCHMARK_MINIMUM_EDGES_PER_SECOND {
		fmt.eprintf(
			"[hw_slicer] polygon benchmark below minimum: %.0f edges/s\n",
			edges_per_second,
		)
		os.exit(1)
	}
	hash_text := hex.encode(reference_hash[:])
	defer delete(hash_text)
	wire := Polygon_Benchmark_Wire{
		schema_version = 1,
		benchmark = "clipper2-medium-disjoint-union",
		fixture_version = 1,
		provider = polygon.CLIPPER2_PROVIDER.name,
		provider_version = "2.0.1",
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
		warmup_count = POLYGON_BENCHMARK_WARMUP_COUNT,
		iteration_count = POLYGON_BENCHMARK_ITERATION_COUNT,
		input_path_count = u64(len(input.paths)),
		input_edge_count = input_edge_count,
		output_path_count = reference_path_count,
		output_point_count = reference_point_count,
		output_hash = string(hash_text),
		samples_ns = samples,
		p50_ns = p50_ns,
		p95_ns = p95_ns,
		input_edges_per_second = edges_per_second,
		minimum_edges_per_second =
			POLYGON_BENCHMARK_MINIMUM_EDGES_PER_SECOND,
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
		fmt.eprintln("[hw_slicer] polygon benchmark encoding failed")
		os.exit(1)
	}
	defer delete(output)
	fmt.println(string(output))
}

polygon_benchmark_fixture :: proc() -> polygon.Polygon_Set {
	path_count := POLYGON_BENCHMARK_GRID_SIZE*
		POLYGON_BENCHMARK_GRID_SIZE
	result: polygon.Polygon_Set
	result.points = make([]polygon.Polygon_Point, path_count*4)
	result.paths = make([]polygon.Polygon_Path, path_count)
	for path_index in 0..<path_count {
		column := path_index%POLYGON_BENCHMARK_GRID_SIZE
		row := path_index/POLYGON_BENCHMARK_GRID_SIZE
		minimum_x := contracts.Micrometres(column*100)
		minimum_y := contracts.Micrometres(row*100)
		maximum_x := minimum_x+80
		maximum_y := minimum_y+80
		offset := path_index*4
		result.paths[path_index] = {u64(offset), 4}
		result.points[offset+0] = {minimum_x, minimum_y}
		result.points[offset+1] = {maximum_x, minimum_y}
		result.points[offset+2] = {maximum_x, maximum_y}
		result.points[offset+3] = {minimum_x, maximum_y}
	}
	return result
}

polygon_benchmark_run_once :: proc(
	input: polygon.Polygon_Set,
) -> (
	hash: contracts.Content_Hash,
	path_count, point_count: u64,
	ok: bool,
) {
	empty: polygon.Polygon_Set
	result, error := polygon.CLIPPER2_PROVIDER.boolean(
		input,
		empty,
		.Union,
		.Non_Zero,
		polygon.DEFAULT_POLYGON_LIMITS,
		context.allocator,
	)
	if error != .None {
		fmt.eprintf("[hw_slicer] polygon benchmark failed: %v\n", error)
		return {}, 0, 0, false
	}
	defer polygon.polygon_set_destroy(&result)
	hash_ok: bool
	hash, hash_ok = polygon.polygon_set_hash(result)
	if !hash_ok {
		fmt.eprintln("[hw_slicer] polygon benchmark hash failed")
		return {}, 0, 0, false
	}
	return hash, u64(len(result.paths)), u64(len(result.points)), true
}

polygon_benchmark_hash_word :: proc(
	hash: contracts.Content_Hash,
) -> u64 {
	result: u64
	for index in 0..<8 {
		result |= u64(hash[index])<<u64(index*8)
	}
	return result
}
