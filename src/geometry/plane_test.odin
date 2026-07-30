package geometry

import "core:math"
import "core:testing"

import contracts "../contracts"

@(test)
plane_side_filter_resolves_clear_separations_test :: proc(t: ^testing.T) {
	below, below_error := plane_side_classify(1.25, 1500)
	above, above_error := plane_side_classify(2.25, 1500)
	testing.expect_value(t, below_error, Numeric_Error.None)
	testing.expect_value(t, above_error, Numeric_Error.None)
	testing.expect_value(t, below.side, Plane_Side.Below)
	testing.expect_value(t, above.side, Plane_Side.Above)
	testing.expect_value(t, below.path, Plane_Side_Path.Filtered)
	testing.expect_value(t, above.path, Plane_Side_Path.Filtered)
}

@(test)
plane_side_exact_path_resolves_equality_and_f64_representation_test :: proc(
	t: ^testing.T,
) {
	on, on_error := plane_side_classify(0.5, 500)
	represented, represented_error := plane_side_classify(
		contracts.Millimetres(f64(f32(0.2))),
		200,
	)
	negative_on, negative_error := plane_side_classify(-0.5, -500)
	testing.expect_value(t, on_error, Numeric_Error.None)
	testing.expect_value(t, represented_error, Numeric_Error.None)
	testing.expect_value(t, negative_error, Numeric_Error.None)
	testing.expect_value(t, on.side, Plane_Side.On)
	testing.expect_value(t, on.path, Plane_Side_Path.Exact)
	testing.expect_value(t, represented.side, Plane_Side.Above)
	testing.expect_value(t, negative_on.side, Plane_Side.On)
}

@(test)
plane_side_exact_path_handles_small_values_and_signed_planes_test :: proc(
	t: ^testing.T,
) {
	small_above, error := plane_side_classify(
		contracts.Millimetres(transmute(f64)u64(1)),
		0,
	)
	negative, negative_error := plane_side_classify(-0.0005, -1)
	testing.expect_value(t, error, Numeric_Error.None)
	testing.expect_value(t, negative_error, Numeric_Error.None)
	testing.expect_value(t, small_above.side, Plane_Side.Above)
	testing.expect_value(t, negative.side, Plane_Side.Above)
}

@(test)
plane_side_rejects_non_finite_and_out_of_range_values_test :: proc(
	t: ^testing.T,
) {
	_, non_finite_error := plane_side_classify(
		contracts.Millimetres(math.nan_f64()),
		0,
	)
	_, coordinate_error := plane_side_classify(
		contracts.Millimetres(1_000_000_001),
		0,
	)
	_, plane_error := plane_side_classify(
		0,
		contracts.Micrometres(MAX_PLANAR_COORDINATE_UM+1),
	)
	testing.expect_value(t, non_finite_error, Numeric_Error.Non_Finite)
	testing.expect_value(t, coordinate_error, Numeric_Error.Out_Of_Range)
	testing.expect_value(t, plane_error, Numeric_Error.Out_Of_Range)
}

@(test)
plane_side_exact_fallback_orders_adjacent_f64_values_test :: proc(
	t: ^testing.T,
) {
	planes := [7]contracts.Micrometres{
		contracts.Micrometres(-MAX_PLANAR_COORDINATE_UM+1000),
		-1_000_001,
		-1,
		0,
		1,
		1_000_001,
		contracts.Micrometres(MAX_PLANAR_COORDINATE_UM-1000),
	}
	for plane in planes {
		center := f64(i64(plane))/MICROMETRES_PER_MILLIMETRE
		lower := math.nextafter_f64(center, math.inf_f64(-1))
		upper := math.nextafter_f64(center, math.inf_f64(1))
		lower_result, lower_error := plane_side_classify(
			contracts.Millimetres(lower),
			plane,
		)
		upper_result, upper_error := plane_side_classify(
			contracts.Millimetres(upper),
			plane,
		)
		testing.expect_value(t, lower_error, Numeric_Error.None)
		testing.expect_value(t, upper_error, Numeric_Error.None)
		testing.expect_value(t, lower_result.side, Plane_Side.Below)
		testing.expect_value(t, upper_result.side, Plane_Side.Above)
	}
}
