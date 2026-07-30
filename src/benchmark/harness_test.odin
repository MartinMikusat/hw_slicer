package benchmark

import "core:testing"

checked_test_kernel :: proc(input: Kernel_Input) -> Kernel_Result {
	hash := input.seed
	for index in u64(0)..<input.operation_count {
		hash = (hash~index)*1099511628211
	}
	return {hash, input.operation_count, 0}
}

wrong_test_kernel :: proc(input: Kernel_Input) -> Kernel_Result {
	return {0, input.operation_count, 0}
}

constant_test_kernel :: proc(input: Kernel_Input) -> Kernel_Result {
	return {0x1234, input.operation_count, 0}
}

nondeterministic_counter_test_calls: u64

nondeterministic_counter_test_kernel :: proc(
	input: Kernel_Input,
) -> Kernel_Result {
	result := checked_test_kernel(input)
	if nondeterministic_counter_test_calls >= 2 {
		result.slow_path_count = 1
	}
	nondeterministic_counter_test_calls += 1
	return result
}

@(test)
benchmark_harness_validates_before_timing_test :: proc(t: ^testing.T) {
	config := Benchmark_Config{
		name = "checked-test",
		fixture_version = 1,
		seed = 7,
		warmup_count = 1,
		iteration_count = 5,
		operation_count = 100,
		expected_hash = 0x3fcdc18c935f9feb,
	}
	report, error := benchmark_run(config, checked_test_kernel)
	defer benchmark_report_destroy(&report)
	testing.expect_value(t, error, Benchmark_Error.None)
	testing.expect(t, report.validated)
	testing.expect_value(t, len(report.samples_ns), 5)
	testing.expect(t, report.p50_ns > 0)
	testing.expect(t, report.p95_ns >= report.p50_ns)
}

@(test)
benchmark_harness_rejects_wrong_result_test :: proc(t: ^testing.T) {
	config := Benchmark_Config{
		name = "wrong-test",
		fixture_version = 1,
		seed = 7,
		iteration_count = 1,
		operation_count = 100,
		expected_hash = 0x1234,
	}
	_, error := benchmark_run(config, wrong_test_kernel)
	testing.expect_value(t, error, Benchmark_Error.Wrong_Result)
}

@(test)
benchmark_harness_rejects_constant_input_independent_kernel_test :: proc(
	t: ^testing.T,
) {
	config := Benchmark_Config{
		name = "constant-test",
		fixture_version = 1,
		seed = 7,
		iteration_count = 1,
		operation_count = 100,
		expected_hash = 0x1234,
	}
	_, error := benchmark_run(config, constant_test_kernel)
	testing.expect_value(t, error, Benchmark_Error.Input_Not_Consumed)
}

@(test)
benchmark_harness_rejects_nondeterministic_counters_test :: proc(
	t: ^testing.T,
) {
	nondeterministic_counter_test_calls = 0
	config := Benchmark_Config{
		name = "nondeterministic-counter-test",
		fixture_version = 1,
		seed = 7,
		iteration_count = 1,
		operation_count = 100,
		expected_hash = 0x3fcdc18c935f9feb,
	}
	_, error := benchmark_run(config, nondeterministic_counter_test_kernel)
	testing.expect_value(t, error, Benchmark_Error.Counter_Mismatch)
}

@(test)
orient_2d_fixture_has_canonical_output_hash_test :: proc(t: ^testing.T) {
	result := orient_2d_checked_kernel({
		seed = ORIENT_2D_BENCHMARK_SEED,
		operation_count = 1000,
	})
	testing.expect_value(t, result.operation_count, u64(1000))
	testing.expect_value(t, result.slow_path_count, u64(0))
	testing.expect_value(t, result.output_hash, u64(0x0d67ea512e86e9c3))
}
