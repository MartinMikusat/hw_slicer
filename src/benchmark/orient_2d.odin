package benchmark

import contracts "../contracts"
import geometry "../geometry"

ORIENT_2D_BENCHMARK_SEED :: u64(0x4857534c49434552)

orient_2d_checked_kernel :: proc(input: Kernel_Input) -> Kernel_Result {
	state := input.seed
	hash := u64(14695981039346656037)
	slow_path_count: u64
	for _ in u64(0)..<input.operation_count {
		a := benchmark_point(&state)
		b := benchmark_point(&state)
		c := benchmark_point(&state)
		determinant, _, error := geometry.orient_2d_checked(a, b, c)
		if error != .None {
			slow_path_count += 1
			continue
		}
		bits := transmute(u128)determinant
		for byte_index in 0..<16 {
			value := u8(bits>>u128(byte_index*8))
			hash = (hash~u64(value))*1099511628211
		}
	}
	return {
		output_hash = hash,
		operation_count = input.operation_count,
		slow_path_count = slow_path_count,
	}
}

benchmark_point :: proc(state: ^u64) -> geometry.Point_2 {
	return {
		x = contracts.Micrometres(benchmark_coordinate(state)),
		y = contracts.Micrometres(benchmark_coordinate(state)),
	}
}

benchmark_coordinate :: proc(state: ^u64) -> i64 {
	return i64(benchmark_random(state)%2_000_001)-1_000_000
}

benchmark_random :: proc(state: ^u64) -> u64 {
	value := state^
	value = value~(value<<13)
	value = value~(value>>7)
	value = value~(value<<17)
	state^ = value
	return value
}
