package polygon

import "core:math"
import "core:mem"
import "core:slice"

import contracts "../contracts"
import geometry "../geometry"

HW_CLIPPER2_LIBRARY :: #config(HW_CLIPPER2_LIBRARY, "")

when HW_CLIPPER2_LIBRARY == "" {
	#panic(
		"Define HW_CLIPPER2_LIBRARY with the pinned Clipper2 archive path",
	)
}

foreign import hw_clipper2_library {
	HW_CLIPPER2_LIBRARY,
}

HW_Clipper2_Point :: struct {
	x, y: i64,
}

HW_Clipper2_Path :: struct {
	offset, count: u64,
}

HW_Clipper2_Paths_View :: struct {
	points:      [^]HW_Clipper2_Point,
	point_count: u64,
	paths:       [^]HW_Clipper2_Path,
	path_count:  u64,
}

HW_Clipper2_Paths_Result :: struct {
	points:      [^]HW_Clipper2_Point,
	point_count: u64,
	paths:       [^]HW_Clipper2_Path,
	path_count:  u64,
}

HW_Clipper2_Error :: enum i32 {
	None,
	Invalid_Input,
	Input_Limit,
	Output_Limit,
	Allocation_Failed,
	Execution_Failed,
}

foreign hw_clipper2_library {
	@(link_name = "hw_clipper2_version")
	hw_clipper2_version :: proc() -> cstring ---

	@(link_name = "hw_clipper2_boolean")
	hw_clipper2_boolean :: proc(
		operation, fill_rule: u8,
		subjects, clips: HW_Clipper2_Paths_View,
		maximum_output_points, maximum_output_paths: u64,
		result: ^HW_Clipper2_Paths_Result,
	) -> HW_Clipper2_Error ---

	@(link_name = "hw_clipper2_offset")
	hw_clipper2_offset :: proc(
		input: HW_Clipper2_Paths_View,
		delta: f64,
		join_type: u8,
		miter_limit, arc_tolerance: f64,
		maximum_output_points, maximum_output_paths: u64,
		result: ^HW_Clipper2_Paths_Result,
	) -> HW_Clipper2_Error ---

	@(link_name = "hw_clipper2_paths_dispose")
	hw_clipper2_paths_dispose :: proc(
		result: ^HW_Clipper2_Paths_Result,
	) ---
}

#assert(size_of(Polygon_Point) == size_of(HW_Clipper2_Point))
#assert(align_of(Polygon_Point) == align_of(HW_Clipper2_Point))
#assert(size_of(Polygon_Path) == size_of(HW_Clipper2_Path))
#assert(align_of(Polygon_Path) == align_of(HW_Clipper2_Path))
#assert(size_of(HW_Clipper2_Point) == 16)
#assert(size_of(HW_Clipper2_Path) == 16)
#assert(size_of(HW_Clipper2_Paths_View) == 32)
#assert(size_of(HW_Clipper2_Paths_Result) == 32)

CLIPPER2_PINNED_VERSION :: "2.0.1"

Polygon_Canonical_Path :: struct {
	points:        []Polygon_Point,
	signed_area_2: i128,
}

clipper2_boolean :: proc(
	subjects, clips: Polygon_Set,
	operation: Polygon_Operation,
	fill_rule: Polygon_Fill_Rule,
	limits := DEFAULT_POLYGON_LIMITS,
	allocator := context.allocator,
) -> (Polygon_Set, Polygon_Error) {
	if operation == .Invalid ||
	   !clipper2_version_valid() {
		if operation == .Invalid {return {}, .Invalid_Input}
		return {}, .Provider_Version
	}
	subject_error := polygon_set_validate(subjects, limits)
	if subject_error != .None {return {}, subject_error}
	clip_error := polygon_set_validate(clips, limits)
	if clip_error != .None {return {}, clip_error}
	raw_result: HW_Clipper2_Paths_Result
	ffi_error := hw_clipper2_boolean(
		u8(operation),
		u8(fill_rule),
		polygon_set_ffi_view(subjects),
		polygon_set_ffi_view(clips),
		limits.max_output_points,
		limits.max_output_paths,
		&raw_result,
	)
	defer hw_clipper2_paths_dispose(&raw_result)
	if ffi_error != .None {return {}, polygon_ffi_error(ffi_error)}
	return polygon_set_canonicalize(raw_result, limits, allocator)
}

clipper2_offset :: proc(
	input: Polygon_Set,
	delta: contracts.Micrometres,
	join_type: Polygon_Join_Type,
	miter_limit, arc_tolerance: f64,
	limits := DEFAULT_POLYGON_LIMITS,
	allocator := context.allocator,
) -> (Polygon_Set, Polygon_Error) {
	if !clipper2_version_valid() {return {}, .Provider_Version}
	input_error := polygon_set_validate(input, limits)
	if input_error != .None {return {}, input_error}
	if i64(delta) < -geometry.MAX_PLANAR_COORDINATE_UM ||
	   i64(delta) > geometry.MAX_PLANAR_COORDINATE_UM {
		return {}, .Coordinate_Range
	}
	if math.is_nan(miter_limit) || math.is_inf(miter_limit) ||
	   math.is_nan(arc_tolerance) || math.is_inf(arc_tolerance) ||
	   miter_limit < 1 || arc_tolerance < 0 {
		return {}, .Invalid_Input
	}
	raw_result: HW_Clipper2_Paths_Result
	ffi_error := hw_clipper2_offset(
		polygon_set_ffi_view(input),
		f64(i64(delta)),
		u8(join_type),
		miter_limit,
		arc_tolerance,
		limits.max_output_points,
		limits.max_output_paths,
		&raw_result,
	)
	defer hw_clipper2_paths_dispose(&raw_result)
	if ffi_error != .None {return {}, polygon_ffi_error(ffi_error)}
	return polygon_set_canonicalize(raw_result, limits, allocator)
}

clipper2_version_valid :: proc() -> bool {
	version := hw_clipper2_version()
	return version != nil && string(version) == CLIPPER2_PINNED_VERSION
}

polygon_set_validate :: proc(
	set: Polygon_Set,
	limits: Polygon_Limits,
) -> Polygon_Error {
	if u64(len(set.points)) > limits.max_input_points ||
	   u64(len(set.paths)) > limits.max_input_paths {
		return .Input_Limit
	}
	expected_offset: u64
	for path in set.paths {
		if path.offset != expected_offset || path.count < 3 ||
		   expected_offset > u64(len(set.points)) ||
		   path.count > u64(len(set.points))-expected_offset {
			return .Invalid_Input
		}
		end := int(path.offset+path.count)
		start := int(path.offset)
		previous := set.points[end-1]
		for point in set.points[start:end] {
			if geometry.point_2_validate({x = point.x, y = point.y}) !=
			   .None {
				return .Coordinate_Range
			}
			if point == previous {return .Invalid_Input}
			previous = point
		}
		expected_offset += path.count
	}
	if expected_offset != u64(len(set.points)) {
		return .Invalid_Input
	}
	if len(set.paths) == 0 && len(set.points) != 0 {
		return .Invalid_Input
	}
	return .None
}

polygon_set_ffi_view :: proc(set: Polygon_Set) -> HW_Clipper2_Paths_View {
	return {
		points = transmute([^]HW_Clipper2_Point)(raw_data(set.points)),
		point_count = u64(len(set.points)),
		paths = transmute([^]HW_Clipper2_Path)(raw_data(set.paths)),
		path_count = u64(len(set.paths)),
	}
}

polygon_set_canonicalize :: proc(
	raw: HW_Clipper2_Paths_Result,
	limits: Polygon_Limits,
	allocator: mem.Allocator,
) -> (Polygon_Set, Polygon_Error) {
	if raw.point_count > limits.max_output_points ||
	   raw.path_count > limits.max_output_paths {
		return {}, .Output_Limit
	}
	if raw.point_count > u64(max(int)) ||
	   raw.path_count > u64(max(int)) ||
	   raw.point_count > 0 && raw.points == nil ||
	   raw.path_count > 0 && raw.paths == nil {
		return {}, .Provider_Failed
	}
	if raw.path_count == 0 {
		if raw.point_count != 0 {return {}, .Provider_Failed}
		return {}, .None
	}
	raw_points := raw.points[:int(raw.point_count)]
	raw_paths := raw.paths[:int(raw.path_count)]
	temporary_points := make(
		[]Polygon_Point,
		int(raw.point_count),
		allocator,
	)
	records := make(
		[]Polygon_Canonical_Path,
		int(raw.path_count),
		allocator,
	)
	if temporary_points == nil || records == nil {
		delete(temporary_points, allocator)
		delete(records, allocator)
		return {}, .Allocation_Failed
	}
	defer delete(temporary_points, allocator)
	defer delete(records, allocator)

	expected_offset: u64
	point_write := 0
	for raw_path, path_index in raw_paths {
		if raw_path.offset != expected_offset || raw_path.count < 3 ||
		   expected_offset > raw.point_count ||
		   raw_path.count > raw.point_count-expected_offset {
			return {}, .Provider_Failed
		}
		raw_path_points :=
			raw_points[int(raw_path.offset):int(raw_path.offset+raw_path.count)]
		start_index := polygon_ffi_minimum_rotation(raw_path_points)
		record_points :=
			temporary_points[point_write:point_write+len(raw_path_points)]
		previous := Polygon_Point{}
		for local_index in 0..<len(raw_path_points) {
			source := raw_path_points[
				(start_index+local_index)%len(raw_path_points)
			]
			point := Polygon_Point{
				x = contracts.Micrometres(source.x),
				y = contracts.Micrometres(source.y),
			}
			if geometry.point_2_validate({x = point.x, y = point.y}) !=
			   .None {
				return {}, .Coordinate_Range
			}
			if local_index > 0 && point == previous {
				return {}, .Provider_Failed
			}
			record_points[local_index] = point
			previous = point
		}
		if record_points[0] == record_points[len(record_points)-1] {
			return {}, .Provider_Failed
		}
		area := polygon_path_area_2(record_points)
		if area == 0 {return {}, .Provider_Failed}
		records[path_index] = {
			points = record_points,
			signed_area_2 = area,
		}
		point_write += len(raw_path_points)
		expected_offset += raw_path.count
	}
	if expected_offset != raw.point_count || point_write != len(temporary_points) {
		return {}, .Provider_Failed
	}
	slice.sort_by(records, polygon_canonical_path_less)

	result: Polygon_Set
	result.points = make([]Polygon_Point, len(temporary_points), allocator)
	result.paths = make([]Polygon_Path, len(records), allocator)
	if result.points == nil || result.paths == nil {
		polygon_set_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	point_write = 0
	for record, path_index in records {
		result.paths[path_index] = {
			offset = u64(point_write),
			count = u64(len(record.points)),
		}
		copy(
			result.points[point_write:point_write+len(record.points)],
			record.points,
		)
		point_write += len(record.points)
	}
	return result, .None
}

polygon_ffi_point_less :: proc(a, b: HW_Clipper2_Point) -> bool {
	if a.x != b.x {return a.x < b.x}
	return a.y < b.y
}

polygon_ffi_minimum_rotation :: proc(
	points: []HW_Clipper2_Point,
) -> int {
	first, second, offset := 0, 1, 0
	count := len(points)
	for first < count && second < count && offset < count {
		a := points[(first+offset)%count]
		b := points[(second+offset)%count]
		if a == b {
			offset += 1
			continue
		}
		if polygon_ffi_point_less(a, b) {
			second += offset+1
			if second == first {second += 1}
		} else {
			first += offset+1
			if first == second {first += 1}
		}
		offset = 0
	}
	return min(first, second)%count
}

polygon_canonical_path_less :: proc(
	a, b: Polygon_Canonical_Path,
) -> bool {
	count := min(len(a.points), len(b.points))
	for index in 0..<count {
		if a.points[index].x != b.points[index].x {
			return a.points[index].x < b.points[index].x
		}
		if a.points[index].y != b.points[index].y {
			return a.points[index].y < b.points[index].y
		}
	}
	if len(a.points) != len(b.points) {
		return len(a.points) < len(b.points)
	}
	return a.signed_area_2 < b.signed_area_2
}

polygon_path_area_2 :: proc(points: []Polygon_Point) -> i128 {
	area: i128
	for point, index in points {
		next := points[(index+1)%len(points)]
		area += i128(i64(point.x))*i128(i64(next.y))-
			i128(i64(point.y))*i128(i64(next.x))
	}
	return area
}

polygon_ffi_error :: proc(error: HW_Clipper2_Error) -> Polygon_Error {
	switch error {
	case .None:              return .None
	case .Invalid_Input:     return .Invalid_Input
	case .Input_Limit:       return .Input_Limit
	case .Output_Limit:      return .Output_Limit
	case .Allocation_Failed: return .Allocation_Failed
	case .Execution_Failed:  return .Provider_Failed
	}
	return .Provider_Failed
}
