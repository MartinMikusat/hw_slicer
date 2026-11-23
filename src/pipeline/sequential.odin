package pipeline

import "core:slice"

Sequential_Clearance :: struct {
	extruder_radius_mm: f64, // default 35.0 mm around nozzle
	gantry_height_mm:   f64, // default 45.0 mm
}

DEFAULT_SEQUENTIAL_CLEARANCE :: Sequential_Clearance{
	extruder_radius_mm = 35.0,
	gantry_height_mm   = 45.0,
}

// Validates that plate objects can be printed sequentially (object-by-object) without
// extruder or gantry collisions, and sorts objects front-to-back (ascending min_y).
plate_validate_sequential :: proc(
	objects: []Plate_Object,
	clearance := DEFAULT_SEQUENTIAL_CLEARANCE,
) -> (ok: bool, conflict_a, conflict_b: int) {
	if len(objects) <= 1 {return true, -1, -1}
	for &obj in objects {plate_object_compute_bounds(&obj)}
	slice.sort_by(objects, proc(a, b: Plate_Object) -> bool {
		if a.min_y != b.min_y {return a.min_y < b.min_y}
		return a.min_x < b.min_x
	})
	r := clearance.extruder_radius_mm
	for i in 0..<len(objects) {
		a := objects[i]
		if a.max_z - a.min_z > clearance.gantry_height_mm && i + 1 < len(objects) {
			return false, i, i + 1
		}
		for j := i + 1; j < len(objects); j += 1 {
			b := objects[j]
			overlap_x := (a.min_x - r) < b.max_x && (a.max_x + r) > b.min_x
			overlap_y := (a.min_y - r) < b.max_y && (a.max_y + r) > b.min_y
			if overlap_x && overlap_y {
				return false, i, j
			}
		}
	}
	return true, -1, -1
}
