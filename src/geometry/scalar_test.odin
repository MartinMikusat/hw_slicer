package geometry

import "core:math"
import "core:testing"

import contracts "../contracts"

@(test)
millimetre_conversion_uses_explicit_nearest_rounding_test :: proc(t: ^testing.T) {
	tests := [?]struct {
		input:    f64,
		expected: i64,
	}{
		{0, 0},
		{0.0004, 0},
		{0.0005, 1},
		{-0.0005, -1},
		{12.3454, 12345},
		{12.3455, 12346},
	}
	for item in tests {
		actual, error := millimetres_to_micrometres(
			contracts.Millimetres(item.input),
		)
		testing.expect_value(t, error, Numeric_Error.None)
		testing.expect_value(t, i64(actual), item.expected)
	}
}

@(test)
millimetre_conversion_exposes_floor_and_ceil_for_candidate_bounds_test :: proc(
	t: ^testing.T,
) {
	floor_value, floor_error := millimetres_to_micrometres_quantized(
		contracts.Millimetres(1.0004),
		.Floor,
	)
	ceil_value, ceil_error := millimetres_to_micrometres_quantized(
		contracts.Millimetres(1.0004),
		.Ceil,
	)
	negative_floor, negative_floor_error :=
		millimetres_to_micrometres_quantized(
			contracts.Millimetres(-1.0004),
			.Floor,
		)
	testing.expect_value(t, floor_error, Numeric_Error.None)
	testing.expect_value(t, ceil_error, Numeric_Error.None)
	testing.expect_value(t, negative_floor_error, Numeric_Error.None)
	testing.expect_value(t, i64(floor_value), i64(1000))
	testing.expect_value(t, i64(ceil_value), i64(1001))
	testing.expect_value(t, i64(negative_floor), i64(-1001))
}

@(test)
millimetre_conversion_rejects_non_finite_and_out_of_range_test :: proc(
	t: ^testing.T,
) {
	_, nan_error := millimetres_to_micrometres(
		contracts.Millimetres(math.nan_f64()),
	)
	_, infinity_error := millimetres_to_micrometres(
		contracts.Millimetres(math.inf_f64(1)),
	)
	_, range_error := millimetres_to_micrometres(
		contracts.Millimetres(
			f64(MAX_PLANAR_COORDINATE_UM)/MICROMETRES_PER_MILLIMETRE+1,
		),
	)
	testing.expect_value(t, nan_error, Numeric_Error.Non_Finite)
	testing.expect_value(t, infinity_error, Numeric_Error.Non_Finite)
	testing.expect_value(t, range_error, Numeric_Error.Out_Of_Range)
}

@(test)
normalization_removes_negative_zero_test :: proc(t: ^testing.T) {
	normalized, error := normalize_f64(-0.0)
	testing.expect_value(t, error, Numeric_Error.None)
	testing.expect_value(t, transmute(u64)normalized, u64(0))
}

@(test)
checked_orientation_returns_exact_sign_test :: proc(t: ^testing.T) {
	a := Point_2{0, 0}
	b := Point_2{10, 0}
	c := Point_2{5, 5}
	determinant, sign, error := orient_2d_checked(a, b, c)
	testing.expect_value(t, determinant, i128(50))
	testing.expect_value(t, sign, Predicate_Sign.Positive)
	testing.expect_value(t, error, Numeric_Error.None)

	_, reverse_sign, reverse_error := orient_2d_checked(b, a, c)
	testing.expect_value(t, reverse_sign, Predicate_Sign.Negative)
	testing.expect_value(t, reverse_error, Numeric_Error.None)

	_, collinear_sign, collinear_error := orient_2d_checked(
		Point_2{0, 0},
		Point_2{5, 5},
		Point_2{10, 10},
	)
	testing.expect_value(t, collinear_sign, Predicate_Sign.Zero)
	testing.expect_value(t, collinear_error, Numeric_Error.None)
}

@(test)
orientation_rejects_coordinate_beyond_contract_limit_test :: proc(
	t: ^testing.T,
) {
	_, _, error := orient_2d_checked(
		Point_2{contracts.Micrometres(MAX_PLANAR_COORDINATE_UM+1), 0},
		Point_2{0, 0},
		Point_2{0, 1},
	)
	testing.expect_value(t, error, Numeric_Error.Out_Of_Range)
}
