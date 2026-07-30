package geometry

import "core:math"

import contracts "../contracts"

F64_UNIT_ROUNDOFF :: f64(1.0/9_007_199_254_740_992.0)
PLANE_FILTER_ERROR_FACTOR :: f64(4)

Plane_Side :: enum i8 {
	Below = -1,
	On    = 0,
	Above = 1,
}

Plane_Side_Path :: enum u8 {
	Filtered,
	Exact,
}

Plane_Side_Result :: struct {
	side:              Plane_Side,
	path:              Plane_Side_Path,
	scaled_difference: f64,
	error_bound:       f64,
}

plane_side_classify :: proc(
	z: contracts.Millimetres,
	plane_z: contracts.Micrometres,
) -> (Plane_Side_Result, Numeric_Error) {
	z_value := f64(z)
	if math.is_nan(z_value) || math.is_inf(z_value) {
		return {}, .Non_Finite
	}
	maximum_mm := f64(MAX_PLANAR_COORDINATE_UM)/
		MICROMETRES_PER_MILLIMETRE
	if z_value < -maximum_mm || z_value > maximum_mm ||
	   i64(plane_z) < -MAX_PLANAR_COORDINATE_UM ||
	   i64(plane_z) > MAX_PLANAR_COORDINATE_UM {
		return {}, .Out_Of_Range
	}

	scaled_z := z_value*MICROMETRES_PER_MILLIMETRE
	plane_value := f64(plane_z)
	difference := scaled_z-plane_value
	error_bound := PLANE_FILTER_ERROR_FACTOR*F64_UNIT_ROUNDOFF*
		(math.abs(scaled_z)+math.abs(plane_value))
	if math.abs(difference) > error_bound {
		side := Plane_Side.Above
		if difference < 0 {side = .Below}
		return {
			side = side,
			path = .Filtered,
			scaled_difference = difference,
			error_bound = error_bound,
		}, .None
	}
	return {
		side = plane_side_exact(z_value, i64(plane_z)),
		path = .Exact,
		scaled_difference = difference,
		error_bound = error_bound,
	}, .None
}

plane_side_exact :: proc(z: f64, plane_um: i64) -> Plane_Side {
	if z == 0 {
		switch {
		case plane_um < 0: return .Above
		case plane_um > 0: return .Below
		case:              return .On
		}
	}
	if plane_um == 0 {
		if z < 0 {return .Below}
		return .Above
	}
	if z < 0 && plane_um > 0 {return .Below}
	if z > 0 && plane_um < 0 {return .Above}

	z_magnitude := z
	if z_magnitude < 0 {z_magnitude = -z_magnitude}
	plane_magnitude := plane_um
	if plane_magnitude < 0 {plane_magnitude = -plane_magnitude}
	magnitude_order := plane_side_magnitude_order(
		z_magnitude,
		u64(plane_magnitude),
	)
	if z < 0 {magnitude_order = -magnitude_order}
	switch {
	case magnitude_order < 0: return .Below
	case magnitude_order > 0: return .Above
	case:                     return .On
	}
}

plane_side_magnitude_order :: proc(
	z_magnitude: f64,
	plane_magnitude_um: u64,
) -> i8 {
	bits := transmute(u64)z_magnitude
	exponent_bits := u16((bits>>52)&0x7ff)
	fraction := bits&0x000f_ffff_ffff_ffff
	significand := fraction
	exponent: i32
	if exponent_bits == 0 {
		exponent = -1074
	} else {
		significand |= u64(1)<<52
		exponent = i32(exponent_bits)-1023-52
	}
	left := i128(significand)*i128(1000)
	right := i128(plane_magnitude_um)
	if exponent >= 0 {
		left <<= u32(exponent)
	} else {
		shift := -exponent
		if shift > 63 {return -1}
		right <<= u32(shift)
	}
	switch {
	case left < right: return -1
	case left > right: return 1
	case:              return 0
	}
}
