package benchmark

import "base:intrinsics"
import "core:time"

BENCHMARK_SCHEMA_VERSION :: u32(1)

Benchmark_Config :: struct {
	name:              string,
	fixture_version:   u32,
	seed:              u64,
	warmup_count:      int,
	iteration_count:   int,
	operation_count:   u64,
	expected_hash:     u64,
}

Kernel_Input :: struct {
	seed:            u64,
	operation_count: u64,
}

Kernel_Result :: struct {
	output_hash:     u64,
	operation_count: u64,
	slow_path_count: u64,
}

Kernel_Proc :: #type proc(input: Kernel_Input) -> Kernel_Result

Benchmark_Report :: struct {
	schema_version:        u32,
	name:                  string,
	fixture_version:       u32,
	seed:                  u64,
	warmup_count:          int,
	iteration_count:       int,
	operation_count:       u64,
	output_hash:           u64,
	slow_path_count:       u64,
	samples_ns:            []u64,
	p50_ns:                u64,
	p95_ns:                u64,
	operations_per_second: f64,
	validated:             bool,
}

Benchmark_Error :: enum u8 {
	None,
	Invalid_Config,
	Wrong_Result,
	Operation_Count_Mismatch,
	Counter_Mismatch,
	Input_Not_Consumed,
	Allocation_Failed,
}

benchmark_sink: u64

benchmark_run :: proc(
	config: Benchmark_Config,
	kernel: Kernel_Proc,
	allocator := context.allocator,
) -> (Benchmark_Report, Benchmark_Error) {
	if config.name == "" || config.fixture_version == 0 ||
	   config.warmup_count < 0 || config.iteration_count < 1 ||
	   config.operation_count < 2 {
		return {}, .Invalid_Config
	}
	input := Kernel_Input{config.seed, config.operation_count}
	reference := kernel(input)
	if reference.operation_count != config.operation_count {
		return {}, .Operation_Count_Mismatch
	}
	if reference.output_hash != config.expected_hash {
		return {}, .Wrong_Result
	}
	alternate := kernel({
		seed = config.seed~0x9e3779b97f4a7c15,
		operation_count = config.operation_count,
	})
	if alternate.operation_count != config.operation_count {
		return {}, .Operation_Count_Mismatch
	}
	if alternate.output_hash == reference.output_hash {
		return {}, .Input_Not_Consumed
	}
	intrinsics.volatile_store(&benchmark_sink, alternate.output_hash)

	for _ in 0..<config.warmup_count {
		result := kernel(input)
		if result.output_hash != config.expected_hash {
			return {}, .Wrong_Result
		}
		if result.operation_count != config.operation_count {
			return {}, .Operation_Count_Mismatch
		}
		if result.slow_path_count != reference.slow_path_count {
			return {}, .Counter_Mismatch
		}
		intrinsics.volatile_store(&benchmark_sink, result.output_hash)
	}

	samples := make([]u64, config.iteration_count, allocator)
	if samples == nil {return {}, .Allocation_Failed}
	for index in 0..<config.iteration_count {
		started := time.tick_now()
		result := kernel(input)
		elapsed := time.tick_since(started)
		if result.output_hash != config.expected_hash {
			delete(samples, allocator)
			return {}, .Wrong_Result
		}
		if result.operation_count != config.operation_count {
			delete(samples, allocator)
			return {}, .Operation_Count_Mismatch
		}
		if result.slow_path_count != reference.slow_path_count {
			delete(samples, allocator)
			return {}, .Counter_Mismatch
		}
		samples[index] = u64(max(i64(elapsed), 1))
		intrinsics.volatile_store(&benchmark_sink, result.output_hash)
	}

	sort_u64(samples)
	p50_ns := samples[len(samples)/2]
	p95_index := (95*len(samples)+99)/100-1
	p95_ns := samples[p95_index]
	return {
		schema_version = BENCHMARK_SCHEMA_VERSION,
		name = config.name,
		fixture_version = config.fixture_version,
		seed = config.seed,
		warmup_count = config.warmup_count,
		iteration_count = config.iteration_count,
		operation_count = config.operation_count,
		output_hash = reference.output_hash,
		slow_path_count = reference.slow_path_count,
		samples_ns = samples,
		p50_ns = p50_ns,
		p95_ns = p95_ns,
		operations_per_second =
			f64(config.operation_count)*1_000_000_000/f64(p50_ns),
		validated = true,
	}, .None
}

benchmark_report_destroy :: proc(
	report: ^Benchmark_Report,
	allocator := context.allocator,
) {
	delete(report.samples_ns, allocator)
	report^ = {}
}

sort_u64 :: proc(values: []u64) {
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
