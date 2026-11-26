package pipeline

import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"

import contracts "../contracts"
import formats "../formats"
import gcode "../gcode"
import polygon "../polygon"

Sweep_Axis :: struct {
	key:    string,
	values: []string,
}

Sweep_Copy_Summary :: struct {
	index:       int,
	name:        string,
	center_x_mm: f64,
	center_y_mm: f64,
	settings:    string,
}

Sweep_Result :: struct {
	plate:  Sequential_Slice_Result,
	copies: []Sweep_Copy_Summary,
}

sweep_result_destroy :: proc(r: ^Sweep_Result, allocator := context.allocator) {
	if r == nil {return}
	sequential_slice_result_destroy(&r.plate, allocator)
	for c in r.copies {
		delete(c.name, allocator)
		delete(c.settings, allocator)
	}
	delete(r.copies, allocator)
	r^ = {}
}

// Parses a CLI sweep specification of the form `key=v1,v2,v3`.
sweep_axis_parse :: proc(spec: string, allocator := context.allocator) -> (Sweep_Axis, bool) {
	eq := strings.index_byte(spec, '=')
	if eq <= 0 || eq+1 >= len(spec) {return {}, false}
	key := strings.trim_space(spec[:eq])
	rest := spec[eq+1:]
	if len(key) == 0 || len(rest) == 0 {return {}, false}
	parts := strings.split(rest, ",", context.temp_allocator)
	vals := make([dynamic]string, 0, len(parts), allocator)
	for p in parts {
		v := strings.trim_space(p)
		if len(v) > 0 {
			append(&vals, strings.clone(v, allocator))
		}
	}
	if len(vals) == 0 {
		delete(vals)
		return {}, false
	}
	return Sweep_Axis{key = strings.clone(key, allocator), values = vals[:]}, true
}

sweep_axis_destroy :: proc(a: ^Sweep_Axis, allocator := context.allocator) {
	delete(a.key, allocator)
	for v in a.values {delete(v, allocator)}
	delete(a.values, allocator)
	a^ = {}
}

// Generates a multi-copy tuning plate where each copy receives a distinct combination of
// the sampled `axes` settings, auto-arranged with sequential clearance and assembled into
// one validated Klipper G-code stream.
plate_slice_settings_sweep :: proc(
	base_mesh: formats.Decoded_Mesh,
	base_name: string,
	base_config: Slice_Configuration,
	axes: []Sweep_Axis,
	allocator := context.allocator,
) -> (Sweep_Result, Slice_Run_Error) {
	if len(axes) == 0 {
		return {}, {stage = "sweep", detail = "no sweep axes provided"}
	}
	combo_count := 1
	for ax in axes {
		if len(ax.values) == 0 {
			return {}, {stage = "sweep", detail = fmt.tprintf("sweep axis '%s' has no values", ax.key)}
		}
		if combo_count > 64 / len(ax.values) {
			return {}, {stage = "sweep", detail = "settings sweep exceeds 64-copy plate limit"}
		}
		combo_count *= len(ax.values)
	}

	resolved_base, _, base_detail, base_ok := slice_configuration_resolve(base_config)
	if !base_ok {
		return {}, {stage = "sweep", detail = base_detail}
	}

	objects := make([]Plate_Object, combo_count, context.temp_allocator)
	configs := make([]Slice_Configuration, combo_count, context.temp_allocator)
	summaries := make([]Sweep_Copy_Summary, combo_count, allocator)

	base_obj := Plate_Object{name = base_name, mesh = base_mesh, transform = DEFAULT_PLATE_TRANSFORM}
	plate_object_compute_bounds(&base_obj)

	for ci in 0..<combo_count {
		cfg := base_config
		// Decode mixed-radix combination index.
		rem := ci
		var_buf := strings.builder_make(context.temp_allocator)
		for ax, ai in axes {
			v_idx := rem % len(ax.values)
			rem /= len(ax.values)
			val := ax.values[v_idx]
			if detail, ok := slice_configuration_override(&cfg, ax.key, val); !ok {
				return {}, {stage = "sweep", detail = detail}
			}
			if ai > 0 {strings.write_string(&var_buf, ", ")}
			fmt.sbprintf(&var_buf, "%s=%s", ax.key, val)
		}
		copy_name := fmt.aprintf("%s_s%d", base_name, ci+1, allocator = allocator)
		cfg.object_name = copy_name
		configs[ci] = cfg
		objects[ci] = plate_object_clone(base_obj, copy_name, allocator)
		summaries[ci] = Sweep_Copy_Summary{
			index    = ci,
			name     = copy_name,
			settings = strings.clone(strings.to_string(var_buf), allocator),
		}
	}
	defer {
		for &obj in objects {formats.decoded_mesh_destroy(&obj.mesh, allocator)}
	}

	arrange_gap_mm := DEFAULT_SEQUENTIAL_CLEARANCE.extruder_radius_mm + 1.0
	if !plate_auto_arrange(objects, resolved_base.printer, arrange_gap_mm) {
		return {}, {stage = "sweep", detail = fmt.tprintf("sweep (%d copies) does not fit on build plate with sequential clearance", combo_count)}
	}
	if ok, ca, cb := plate_validate_sequential(objects); !ok {
		return {}, {stage = "sweep", detail = fmt.tprintf("sequential clearance collision between sweep copies %d and %d", ca, cb)}
	}

	for ci in 0..<combo_count {
		summaries[ci].center_x_mm = (objects[ci].min_x + objects[ci].max_x) * 0.5
		summaries[ci].center_y_mm = (objects[ci].min_y + objects[ci].max_y) * 0.5
	}

	// Slice each copy with its own resolved configuration and assemble sequentially.
	results := make([]Slice_Run_Result, combo_count, allocator)
	defer {
		for &r in results {slice_run_result_destroy(&r, allocator)}
		delete(results, allocator)
	}
	object_areas := make([][2]polygon.Polygon_Point, combo_count, context.temp_allocator)
	plate_area: [2]polygon.Polygon_Point
	has_plate_area := false
	total_layers := 0

	out := Sweep_Result{copies = summaries}
	for ci in 0..<combo_count {
		prof, run_opts, detail, ok := slice_configuration_resolve(configs[ci])
		if !ok {
			sweep_result_destroy(&out, allocator)
			return {}, {stage = "sweep", detail = detail}
		}
		run_opts.center_on_bed = false
		run_opts.object_name = objects[ci].name
		run_opts.has_plan_start = true
		run_opts.plan_start = {
			x = contracts.Micrometres(i64(math.round((objects[ci].min_x + objects[ci].max_x) * 500.0))),
			y = contracts.Micrometres(i64(math.round((objects[ci].min_y + objects[ci].max_y) * 500.0))),
		}
		obj_mesh := objects[ci].mesh
		res, err := slice_run_decoded_mesh(&obj_mesh, prof, run_opts, allocator)
		if len(err.stage) > 0 {
			sweep_result_destroy(&out, allocator)
			return {}, err
		}
		results[ci] = res
		area := gcode.klipper_extrusion_area(res.motion)
		object_areas[ci] = area
		if !has_plate_area {
			plate_area = area
			has_plate_area = true
		} else {
			plate_area[0] = {min(plate_area[0].x, area[0].x), min(plate_area[0].y, area[0].y)}
			plate_area[1] = {max(plate_area[1].x, area[1].x), max(plate_area[1].y, area[1].y)}
		}
		total_layers += len(res.spine.schedule.layer_ids)
		out.plate.object_count += 1
		out.plate.total_triangles += len(res.spine.mesh.triangle_ids)
		out.plate.total_layers += len(res.spine.schedule.layer_ids)
		out.plate.total_repairs += int(res.contour_repairs)
		out.plate.extrude_move_count += res.unified_plan.extrude_move_count
		out.plate.travel_move_count += res.unified_plan.travel_move_count
		if res.klipper.positive_filament_nm > res.klipper.negative_filament_nm {
			out.plate.positive_filament_nm += res.klipper.positive_filament_nm - res.klipper.negative_filament_nm
		} else {
			out.plate.positive_filament_nm += u128(res.extrusion.total_filament_nm)
		}
		out.plate.total_seconds += res.estimated_seconds
		out.plate.total_duration_ms += res.total_duration_ms
	}

	b := strings.builder_make(allocator)
	defer strings.builder_destroy(&b)

	first := string(results[0].klipper.bytes)
	header_end := sequential_body_start(first)
	if header_end < 0 {
		sweep_result_destroy(&out, allocator)
		return {}, {stage = "sweep", detail = "sweep copy G-code has no layers"}
	}
	header := first[:header_end]
	for line in strings.split_lines_iterator(&header) {
		switch {
		case strings.has_prefix(line, "EXCLUDE_OBJECT_DEFINE"):
			continue
		case strings.has_prefix(line, "SET_PRINT_STATS_INFO TOTAL_LAYER="):
			fmt.sbprintf(&b, "SET_PRINT_STATS_INFO TOTAL_LAYER=%d\n", total_layers)
		case strings.has_prefix(line, "START_PRINT "):
			strings.write_string(&b, "START_PRINT ")
			rest := line[len("START_PRINT "):]
			for field in strings.split_iterator(&rest, " ") {
				if strings.has_prefix(field, "X0=") || strings.has_prefix(field, "Y0=") ||
				   strings.has_prefix(field, "X1=") || strings.has_prefix(field, "Y1=") {
					continue
				}
				strings.write_string(&b, field)
				strings.write_byte(&b, ' ')
			}
			strings.write_string(&b, "X0=")
			sequential_append_um(&b, plate_area[0].x)
			strings.write_string(&b, " Y0=")
			sequential_append_um(&b, plate_area[0].y)
			strings.write_string(&b, " X1=")
			sequential_append_um(&b, plate_area[1].x)
			strings.write_string(&b, " Y1=")
			sequential_append_um(&b, plate_area[1].y)
			strings.write_byte(&b, '\n')
		case:
			strings.write_string(&b, line)
			strings.write_byte(&b, '\n')
		}
	}
	for ci in 0..<combo_count {
		fmt.sbprintf(&b, ";SWEEP_COPY %d: %s (%s) at X=%.2f Y=%.2f\n",
			ci+1, summaries[ci].name, summaries[ci].settings, summaries[ci].center_x_mm, summaries[ci].center_y_mm)
		obj_g := string(results[ci].klipper.bytes)
		for line in strings.split_lines_iterator(&obj_g) {
			if strings.has_prefix(line, "EXCLUDE_OBJECT_DEFINE") {
				strings.write_string(&b, line)
				strings.write_byte(&b, '\n')
				break
			}
		}
	}

	travel_feed := i64(math.round(f64(resolved_base.process.source.travel.speed)*60.0/1000.0))
	layer_counter := 0
	max_z_mm := 0.0
	for ci in 0..<combo_count {
		g := string(results[ci].klipper.bytes)
		body_start := sequential_body_start(g)
		body_end := strings.last_index(g, "END_PRINT")
		if body_start < 0 || body_end < body_start {
			sweep_result_destroy(&out, allocator)
			return {}, {stage = "sweep", detail = "sweep copy G-code has no layers"}
		}
		if ci > 0 {
			first_point, has_point := sequential_first_point(results[ci].motion)
			if !has_point {
				sweep_result_destroy(&out, allocator)
				return {}, {stage = "sweep", detail = "sweep copy has no motion"}
			}
			clear_z := max_z_mm + 2.0
			fmt.sbprintf(&b, ";SEQUENTIAL_OBJECT_TRANSITION %d\n", ci)
			fmt.sbprintf(&b, "G0 Z%.3f F%d\n", clear_z, travel_feed)
			strings.write_string(&b, "G0 X")
			sequential_append_um(&b, first_point.x)
			strings.write_string(&b, " Y")
			sequential_append_um(&b, first_point.y)
			fmt.sbprintf(&b, " F%d\n", travel_feed)
		}
		body := g[body_start:body_end]
		for line in strings.split_lines_iterator(&body) {
			if strings.has_prefix(line, "SET_PRINT_STATS_INFO CURRENT_LAYER=") {
				layer_counter += 1
				fmt.sbprintf(&b, "SET_PRINT_STATS_INFO CURRENT_LAYER=%d\n", layer_counter)
			} else {
				strings.write_string(&b, line)
				strings.write_byte(&b, '\n')
			}
		}
		if objects[ci].max_z > max_z_mm {max_z_mm = objects[ci].max_z}
	}
	strings.write_string(&b, "END_PRINT\n")

	text := strings.to_string(b)
	if detail, ok := sequential_validate(text, object_areas, total_layers); !ok {
		sweep_result_destroy(&out, allocator)
		return {}, {stage = "sweep", detail = detail}
	}
	out.plate.gcode_bytes = make([]u8, len(text), allocator)
	copy(out.plate.gcode_bytes, transmute([]u8)text)
	return out, {}
}
