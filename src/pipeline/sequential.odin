package pipeline

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

import contracts "../contracts"
import features "../features"
import gcode "../gcode"
import polygon "../polygon"
import profiles "../profiles"

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

Sequential_Slice_Result :: struct {
	gcode_bytes:          []u8,
	object_count:         int,
	total_triangles:      int,
	total_layers:         int,
	total_repairs:        int,
	extrude_move_count:   u64,
	travel_move_count:    u64,
	positive_filament_nm: u128,
	total_seconds:        f64,
	total_duration_ms:    f64,
}

sequential_slice_result_destroy :: proc(res: ^Sequential_Slice_Result, allocator := context.allocator) {
	if res == nil {return}
	delete(res.gcode_bytes, allocator)
	res^ = {}
}

// Slices each validated, front-to-back-sorted plate object independently and assembles one
// G-code stream: the first object's header with the plate-wide print area and layer count, every
// object's exclusion definition, then each object's body. Between objects the nozzle lifts above
// the tallest printed object, travels to the next object's first point, and only then descends.
plate_slice_sequential :: proc(
	objects: []Plate_Object,
	profile: profiles.Resolved_Profiles,
	options: Slice_Run_Options,
	allocator := context.allocator,
) -> (Sequential_Slice_Result, Slice_Run_Error) {
	out := Sequential_Slice_Result{object_count = len(objects)}
	if len(objects) == 0 {
		return {}, {stage = "sequential", detail = "no objects on plate"}
	}
	results := make([]Slice_Run_Result, len(objects), allocator)
	sliced := 0
	defer {
		for i in 0..<sliced {slice_run_result_destroy(&results[i], allocator)}
		delete(results, allocator)
	}
	for &obj, oi in objects {
		plate_object_compute_bounds(&obj)
		obj_opts := options
		obj_opts.center_on_bed = false
		obj_opts.object_name = obj.name
		obj_res, err := slice_run_decoded_mesh(&obj.mesh, profile, obj_opts, allocator)
		if len(err.stage) > 0 {
			return {}, err
		}
		results[oi] = obj_res
		sliced += 1
	}

	area := [2]polygon.Polygon_Point{
		{max(contracts.Micrometres), max(contracts.Micrometres)},
		{min(contracts.Micrometres), min(contracts.Micrometres)},
	}
	total_layers := 0
	for &obj_res in results {
		a := gcode.klipper_extrusion_area(obj_res.motion)
		area[0] = {min(area[0].x, a[0].x), min(area[0].y, a[0].y)}
		area[1] = {max(area[1].x, a[1].x), max(area[1].y, a[1].y)}
		total_layers += len(obj_res.motion.layers)

		out.total_triangles += len(obj_res.spine.mesh.triangle_ids)
		out.total_layers += len(obj_res.spine.schedule.layer_ids)
		out.total_repairs += int(obj_res.contour_repairs)
		out.extrude_move_count += obj_res.unified_plan.extrude_move_count
		out.travel_move_count += obj_res.unified_plan.travel_move_count
		if obj_res.klipper.positive_filament_nm > obj_res.klipper.negative_filament_nm {
			out.positive_filament_nm += obj_res.klipper.positive_filament_nm - obj_res.klipper.negative_filament_nm
		} else {
			out.positive_filament_nm += u128(obj_res.extrusion.total_filament_nm)
		}
		out.total_seconds += obj_res.time_estimate.total_seconds
		out.total_duration_ms += obj_res.total_duration_ms
	}

	b := strings.builder_make(0, 64*1024, allocator)
	defer strings.builder_destroy(&b)
	travel_feed := (i64(profile.process.source.travel.speed) * 60) / 1_000
	bed_max_z_mm := f64(i64(profile.printer.axis_maximum_z)) / 1_000.0

	// Header of the first object, with plate-wide START_PRINT area and layer count.
	first := string(results[0].klipper.bytes)
	header_end := sequential_body_start(first)
	if header_end < 0 {
		return {}, {stage = "sequential", detail = "object G-code has no layers"}
	}
	if define := strings.index(first[:header_end], "EXCLUDE_OBJECT_DEFINE"); define >= 0 {
		header_end = define
	}
	header := first[:header_end]
	for line in strings.split_lines_iterator(&header) {
		switch {
		case strings.has_prefix(line, "SET_PRINT_STATS_INFO TOTAL_LAYER="):
			fmt.sbprintf(&b, "SET_PRINT_STATS_INFO TOTAL_LAYER=%d\n", total_layers)
		case strings.has_prefix(line, "START_PRINT "):
			prefix := line
			if x0 := strings.index(line, " X0="); x0 >= 0 {prefix = line[:x0]}
			strings.write_string(&b, prefix)
			strings.write_string(&b, " X0=")
			sequential_append_um(&b, area[0].x)
			strings.write_string(&b, " Y0=")
			sequential_append_um(&b, area[0].y)
			strings.write_string(&b, " X1=")
			sequential_append_um(&b, area[1].x)
			strings.write_string(&b, " Y1=")
			sequential_append_um(&b, area[1].y)
			strings.write_string(&b, "\n")
		case:
			strings.write_string(&b, line)
			strings.write_string(&b, "\n")
		}
	}
	for &obj_res in results {
		g := string(obj_res.klipper.bytes)
		if define := strings.index(g, "EXCLUDE_OBJECT_DEFINE"); define >= 0 {
			line_end := strings.index_byte(g[define:], '\n')
			if line_end >= 0 {strings.write_string(&b, g[define:define+line_end+1])}
		}
	}

	layer_offset := 0
	max_z_mm := 0.0
	for &obj_res, oi in results {
		g := string(obj_res.klipper.bytes)
		body_start := sequential_body_start(g)
		body_end := len(g)
		if end_idx := strings.last_index(g, "END_PRINT"); end_idx >= 0 {
			body_end = end_idx
		}
		if body_start < 0 || body_start >= body_end {
			return {}, {stage = "sequential", detail = "object G-code has no layers"}
		}
		if oi > 0 {
			first_point, has_point := sequential_first_point(obj_res.motion)
			if !has_point {
				return {}, {stage = "sequential", detail = "object has no motion"}
			}
			clear_z := min(bed_max_z_mm, max_z_mm + 2.0)
			fmt.sbprintf(&b, ";SEQUENTIAL_OBJECT_TRANSITION index=%d name=%s\n", oi, gcode.klipper_object_name(objects[oi].name, context.temp_allocator))
			fmt.sbprintf(&b, "G0 Z%.3f F%d\n", clear_z, travel_feed)
			strings.write_string(&b, "G0 X")
			sequential_append_um(&b, first_point.x)
			strings.write_string(&b, " Y")
			sequential_append_um(&b, first_point.y)
			fmt.sbprintf(&b, " F%d\n", travel_feed)
			// Each object's emitter assumes the fan is off after its own header.
			strings.write_string(&b, "M107\n")
		}
		body := g[body_start:body_end]
		for line in strings.split_lines_iterator(&body) {
			if strings.has_prefix(line, "SET_PRINT_STATS_INFO CURRENT_LAYER=") {
				n, _ := strconv.parse_int(line[len("SET_PRINT_STATS_INFO CURRENT_LAYER="):])
				fmt.sbprintf(&b, "SET_PRINT_STATS_INFO CURRENT_LAYER=%d\n", n+layer_offset)
			} else {
				strings.write_string(&b, line)
				strings.write_string(&b, "\n")
			}
		}
		layer_offset += len(obj_res.motion.layers)
		if objects[oi].max_z > max_z_mm {
			max_z_mm = objects[oi].max_z
		}
	}
	strings.write_string(&b, "END_PRINT\n")

	text := strings.to_string(b)
	out.gcode_bytes = make([]u8, len(text), allocator)
	copy(out.gcode_bytes, transmute([]u8)text)
	return out, {}
}

// The byte offset where an object's per-layer body begins: its EXCLUDE_OBJECT_START, or its
// first layer comment when the object has no name.
@(private = "file")
sequential_body_start :: proc(g: string) -> int {
	if idx := strings.index(g, "EXCLUDE_OBJECT_START"); idx >= 0 {return idx}
	return strings.index(g, ";LAYER:")
}

// The XY point that the object's first move starts from.
@(private = "file")
sequential_first_point :: proc(motion: features.Motion_Plan_Result) -> (polygon.Polygon_Point, bool) {
	for op in motion.operations {
		if op.kind != .Dwell {return op.point_a, true}
	}
	return {}, false
}

@(private = "file")
sequential_append_um :: proc(b: ^strings.Builder, value: contracts.Micrometres) {
	v := i64(value)
	if v < 0 {
		strings.write_byte(b, '-')
		v = -v
	}
	fmt.sbprintf(b, "%d.%03d", v/1_000, v%1_000)
}
