package main

import "core:encoding/json"
import "core:fmt"
import "core:os"

import benchmark "../../src/benchmark"

ORIENT_2D_OPERATION_COUNT :: u64(100_000)
ORIENT_2D_EXPECTED_HASH :: u64(0xd9ae535aa26c3543)

Benchmark_Environment :: struct {
	hardware:      string,
	os_build:      string,
	odin_version:  string,
	clang_version: string,
	git_revision:  string,
	git_dirty:     string,
	thermal_state: string,
}

Benchmark_Wire :: struct {
	schema_version:        u32,
	benchmark:             string,
	fixture_version:       u32,
	seed:                  string,
	mode:                  string,
	environment:           Benchmark_Environment,
	warmup_count:          int,
	iteration_count:       int,
	operation_count:       u64,
	output_hash:           string,
	slow_path_count:       u64,
	samples_ns:            []u64,
	p50_ns:                u64,
	p95_ns:                u64,
	operations_per_second: f64,
	validated:             bool,
}

main :: proc() {
	config := benchmark.Benchmark_Config{
		name = "orient-2d-checked",
		fixture_version = 1,
		seed = benchmark.ORIENT_2D_BENCHMARK_SEED,
		warmup_count = 3,
		iteration_count = 11,
		operation_count = ORIENT_2D_OPERATION_COUNT,
		expected_hash = ORIENT_2D_EXPECTED_HASH,
	}
	report, benchmark_error := benchmark.benchmark_run(
		config,
		benchmark.orient_2d_checked_kernel,
	)
	if benchmark_error != .None {
		fmt.eprintf(
			"[hw_slicer] benchmark failed: %v\n",
			benchmark_error,
		)
		os.exit(1)
	}
	defer benchmark.benchmark_report_destroy(&report)

	wire := Benchmark_Wire{
		schema_version = report.schema_version,
		benchmark = report.name,
		fixture_version = report.fixture_version,
		seed = fmt.tprintf("%016x", report.seed),
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
		warmup_count = report.warmup_count,
		iteration_count = report.iteration_count,
		operation_count = report.operation_count,
		output_hash = fmt.tprintf("%016x", report.output_hash),
		slow_path_count = report.slow_path_count,
		samples_ns = report.samples_ns,
		p50_ns = report.p50_ns,
		p95_ns = report.p95_ns,
		operations_per_second = report.operations_per_second,
		validated = report.validated,
	}
	bytes, encode_error := json.marshal(
		wire,
		{
			pretty = true,
			use_spaces = true,
			spaces = 2,
			sort_maps_by_key = true,
		},
	)
	if encode_error != nil {
		fmt.eprintln("[hw_slicer] benchmark result encoding failed")
		os.exit(1)
	}
	defer delete(bytes)
	fmt.println(string(bytes))
}
