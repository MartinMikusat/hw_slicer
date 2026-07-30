package polygon

import contracts "../contracts"
import geometry "../geometry"

SCHEMA_VERSION_POLYGON_SET_HASH :: u32(1)

polygon_set_hash :: proc(
	set: Polygon_Set,
) -> (contracts.Content_Hash, bool) {
	expected_offset: u64
	previous_path: []Polygon_Point
	for path, path_index in set.paths {
		if path.offset != expected_offset || path.count < 3 ||
		   expected_offset > u64(len(set.points)) ||
		   path.count > u64(len(set.points))-expected_offset {
			return {}, false
		}
		start := int(path.offset)
		end := start+int(path.count)
		points := set.points[start:end]
		if polygon_minimum_rotation(points) != 0 {
			return {}, false
		}
		previous_point := points[len(points)-1]
		for point in points {
			if geometry.point_2_validate({x = point.x, y = point.y}) !=
			   .None ||
			   point == previous_point {
				return {}, false
			}
			previous_point = point
		}
		if polygon_path_area_2(points) == 0 {
			return {}, false
		}
		if path_index > 0 &&
		   polygon_path_slice_less(points, previous_path) {
			return {}, false
		}
		previous_path = points
		expected_offset += path.count
	}
	if expected_offset != u64(len(set.points)) ||
	   len(set.paths) == 0 && len(set.points) != 0 {
		return {}, false
	}

	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/polygon-set",
		SCHEMA_VERSION_POLYGON_SET_HASH,
	)
	contracts.canonical_hash_append_u64(&hash, u64(len(set.paths)))
	for path in set.paths {
		contracts.canonical_hash_append_u64(&hash, path.offset)
		contracts.canonical_hash_append_u64(&hash, path.count)
	}
	contracts.canonical_hash_append_u64(&hash, u64(len(set.points)))
	for point in set.points {
		contracts.canonical_hash_append_i64(&hash, i64(point.x))
		contracts.canonical_hash_append_i64(&hash, i64(point.y))
	}
	return contracts.canonical_hash_final(&hash), true
}

polygon_point_less :: proc(a, b: Polygon_Point) -> bool {
	if a.x != b.x {return a.x < b.x}
	return a.y < b.y
}

polygon_minimum_rotation :: proc(points: []Polygon_Point) -> int {
	first, second, offset := 0, 1, 0
	count := len(points)
	for first < count && second < count && offset < count {
		a := points[(first+offset)%count]
		b := points[(second+offset)%count]
		if a == b {
			offset += 1
			continue
		}
		if polygon_point_less(a, b) {
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

polygon_path_slice_less :: proc(
	a, b: []Polygon_Point,
) -> bool {
	count := min(len(a), len(b))
	for index in 0..<count {
		if a[index].x != b[index].x {
			return a[index].x < b[index].x
		}
		if a[index].y != b[index].y {
			return a[index].y < b[index].y
		}
	}
	return len(a) < len(b)
}
