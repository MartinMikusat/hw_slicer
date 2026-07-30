package geometry

import "core:math"

import contracts "../contracts"

MICROMETRES_PER_MILLIMETRE :: f64(1000)
MAX_PLANAR_COORDINATE_UM :: i64(1_000_000_000_000)

Numeric_Error :: enum u8 {
	None,
	Non_Finite,
	Out_Of_Range,
}

Quantization_Mode :: enum u8 {
	Nearest,
	Floor,
	Ceil,
}

Predicate_Sign :: enum i8 {
	Negative = -1,
	Zero     = 0,
	Positive = 1,
}

Point_2 :: struct {
	x: contracts.Micrometres,
	y: contracts.Micrometres,
}

Point_3 :: struct {
	x: contracts.Millimetres,
	y: contracts.Millimetres,
	z: contracts.Millimetres,
}

normalize_f64 :: proc(value: f64) -> (f64, Numeric_Error) {
	if math.is_nan(value) || math.is_inf(value) {
		return 0, .Non_Finite
	}
	if value == 0 {return 0, .None}
	return value, .None
}

millimetres_to_micrometres :: proc(
	value: contracts.Millimetres,
) -> (contracts.Micrometres, Numeric_Error) {
	return millimetres_to_micrometres_quantized(value, .Nearest)
}

millimetres_to_micrometres_quantized :: proc(
	value: contracts.Millimetres,
	mode: Quantization_Mode,
) -> (contracts.Micrometres, Numeric_Error) {
	normalized, error := normalize_f64(f64(value))
	if error != .None {return 0, error}
	scaled := normalized*MICROMETRES_PER_MILLIMETRE
	limit := f64(MAX_PLANAR_COORDINATE_UM)
	if scaled < -limit || scaled > limit {
		return 0, .Out_Of_Range
	}
	quantized: f64
	switch mode {
	case .Nearest: quantized = math.round(scaled)
	case .Floor:   quantized = math.floor(scaled)
	case .Ceil:    quantized = math.ceil(scaled)
	}
	return contracts.Micrometres(i64(quantized)), .None
}

micrometres_to_millimetres :: proc(
	value: contracts.Micrometres,
) -> contracts.Millimetres {
	return contracts.Millimetres(f64(value)/MICROMETRES_PER_MILLIMETRE)
}

point_2_validate :: proc(point: Point_2) -> Numeric_Error {
	x := i64(point.x)
	y := i64(point.y)
	if x < -MAX_PLANAR_COORDINATE_UM || x > MAX_PLANAR_COORDINATE_UM ||
	   y < -MAX_PLANAR_COORDINATE_UM || y > MAX_PLANAR_COORDINATE_UM {
		return .Out_Of_Range
	}
	return .None
}

point_3_validate :: proc(point: Point_3) -> Numeric_Error {
	values := [3]f64{f64(point.x), f64(point.y), f64(point.z)}
	for value in values {
		if math.is_nan(value) || math.is_inf(value) {
			return .Non_Finite
		}
	}
	return .None
}

orient_2d_checked :: proc(
	a, b, c: Point_2,
) -> (determinant: i128, sign: Predicate_Sign, error: Numeric_Error) {
	if point_2_validate(a) != .None ||
	   point_2_validate(b) != .None ||
	   point_2_validate(c) != .None {
		error = .Out_Of_Range
		return
	}
	ac_x := i128(i64(a.x))-i128(i64(c.x))
	ac_y := i128(i64(a.y))-i128(i64(c.y))
	bc_x := i128(i64(b.x))-i128(i64(c.x))
	bc_y := i128(i64(b.y))-i128(i64(c.y))
	determinant = ac_x*bc_y-ac_y*bc_x
	switch {
	case determinant < 0: sign = .Negative
	case determinant > 0: sign = .Positive
	case:                 sign = .Zero
	}
	return
}
