package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import devlog "devlog:."

import contracts "../contracts"
import features "../features"
import formats "../formats"
import pipeline "../pipeline"
import profiles "../profiles"

CLI_Override :: struct {
	key: string,
	val: string,
}

CLI_Options :: struct {
	input_path:      string,
	input_paths:     [dynamic]string,
	output_path:     string,
	printer:         string,
	material:        string,
	process:         string,
	profiles_dir:    string,
	trace_json_path: string,
	svg_dir:         string,
	enable_supports: bool,
	adaptive_layers: bool,
	clone_count:     int,
	scale:           f64,
	rot_x:           f64,
	rot_y:           f64,
	rot_z:           f64,
	lay_flat:        bool,
	overrides:       [dynamic]CLI_Override,
}

resolve_profile_path :: proc(dir, kind, name: string) -> string {
	if strings.has_suffix(name, ".json") || strings.contains(name, "/") {
		return name
	}
	return fmt.tprintf("%s/%s/%s.json", dir, kind, name)
}

role_svg_color :: proc(role: profiles.Printable_Role) -> string {
	switch role {
	case .Perimeter:         return "#1B2632"
	case .Bridge:            return "#2B7A78"
	case .Gap, .Thin_Wall:   return "#8A5A2B"
	case .Top_Skin:          return "#A35139"
	case .Bottom_Skin:       return "#C97B3A"
	case .Top_Bottom_Skin:   return "#B5623A"
	case .Sparse_Infill:     return "#5C6E4E"
	case .Support:           return "#7A8290"
	case .Support_Interface: return "#4C6A92"
	case .Invalid:           return "#999999"
	}
	return "#999999"
}

write_layer_svg :: proc(
	plan: features.Unified_Path_Plan_Result,
	layer_idx: int,
	dest_path: string,
) -> bool {
	if layer_idx < 0 || layer_idx >= len(plan.layers) {return false}
	layer := plan.layers[layer_idx]
	if layer.move_count == 0 {return false}
	min_x, max_x := max(i64), min(i64)
	min_y, max_y := max(i64), min(i64)
	for i in 0..<u64(layer.move_count) {
		mv := plan.moves[layer.move_offset+i]
		if mv.kind != .Extrude {continue}
		min_x = min(min_x, min(i64(mv.point_a.x), i64(mv.point_b.x)))
		max_x = max(max_x, max(i64(mv.point_a.x), i64(mv.point_b.x)))
		min_y = min(min_y, min(i64(mv.point_a.y), i64(mv.point_b.y)))
		max_y = max(max_y, max(i64(mv.point_a.y), i64(mv.point_b.y)))
	}
	if min_x > max_x {return false}
	pad := i64(2000)
	vx := f64(min_x-pad)/1000.0
	vy := f64(min_y-pad)/1000.0
	vw := max(1.0, f64((max_x-min_x)+2*pad)/1000.0)
	vh := max(1.0, f64((max_y-min_y)+2*pad)/1000.0)
	b := strings.builder_make(0, int(layer.move_count)*96, context.temp_allocator)
	fmt.sbprintf(&b, "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"%.3f %.3f %.3f %.3f\" width=\"800\" height=\"800\" style=\"background:#EEE9DF\">\n", vx, vy, vw, vh)
	fmt.sbprintf(&b, "<g transform=\"translate(0, %.3f) scale(1, -1)\" stroke-linecap=\"round\">\n", 2*vy+vh)
	for i in 0..<u64(layer.move_count) {
		mv := plan.moves[layer.move_offset+i]
		if mv.kind != .Extrude {continue}
		ax, ay := f64(mv.point_a.x)/1000.0, f64(mv.point_a.y)/1000.0
		bx, by := f64(mv.point_b.x)/1000.0, f64(mv.point_b.y)/1000.0
		w := max(0.15, f64(mv.line_width_a)/1000.0)
		fmt.sbprintf(&b, "<line x1=\"%.3f\" y1=\"%.3f\" x2=\"%.3f\" y2=\"%.3f\" stroke=\"%s\" stroke-width=\"%.3f\"/>\n",
			ax, ay, bx, by, role_svg_color(mv.role), w)
	}
	strings.write_string(&b, "</g>\n</svg>\n")
	return os.write_entire_file(dest_path, b.buf[:]) == nil
}

write_trace_json :: proc(
	dest_path: string,
	opts: CLI_Options,
	res: ^pipeline.Slice_Run_Result,
) -> bool {
	b := strings.builder_make(0, 4096, context.temp_allocator)
	strings.write_string(&b, "{\n")
	fmt.sbprintf(&b, "  \"input\": \"%s\",\n", filepath.base(opts.input_path))
	fmt.sbprintf(&b, "  \"printer\": \"%s\",\n", opts.printer)
	fmt.sbprintf(&b, "  \"material\": \"%s\",\n", opts.material)
	fmt.sbprintf(&b, "  \"process\": \"%s\",\n", opts.process)
	fmt.sbprintf(&b, "  \"triangles\": %d,\n", len(res.spine.mesh.triangle_ids))
	fmt.sbprintf(&b, "  \"layers\": %d,\n", len(res.spine.schedule.layer_ids))
	fmt.sbprintf(&b, "  \"contour_repairs\": %d,\n", res.contour_repairs)
	fmt.sbprintf(&b, "  \"extrude_moves\": %d,\n", res.unified_plan.extrude_move_count)
	fmt.sbprintf(&b, "  \"travel_moves\": %d,\n", res.unified_plan.travel_move_count)
	fmt.sbprintf(&b, "  \"filament_mm\": %.3f,\n", f64(res.extrusion.total_filament_nm)/1_000_000.0)
	fmt.sbprintf(&b, "  \"gcode_bytes\": %d,\n", len(res.klipper.bytes))
	fmt.sbprintf(&b, "  \"gcode_commands\": %d,\n", len(res.klipper.commands))
	fmt.sbprintf(&b, "  \"total_duration_ms\": %.3f,\n", res.total_duration_ms)
	strings.write_string(&b, "  \"stages\": [\n")
	for st, idx in res.stages {
		comma := "," if idx+1 < len(res.stages) else ""
		fmt.sbprintf(&b, "    {\"name\": \"%s\", \"duration_ms\": %.3f, \"count_a\": %d, \"count_b\": %d}%s\n",
			st.name, st.duration_ms, st.count_a, st.count_b, comma)
	}
	strings.write_string(&b, "  ]\n}\n")
	return os.write_entire_file(dest_path, b.buf[:]) == nil
}

print_usage :: proc() {
	fmt.eprintln("usage: hw-slicer-cli --input=<file.stl|.obj|.3mf> [--out=<file.gcode>] [--printer=vcore3] [--material=pla] [--process=0.20-standard] [--supports] [--set key=val] [--trace-json=<path>] [--dump-svg-dir=<dir>]")
}

main :: proc() {
	started := devlog.global_start(devlog.default_directory("hw-slicer", "cli"))
	if started {context.assertion_failure_proc = devlog.fatal_hook()}
	defer if started {devlog.global_destroy()}

	opts := CLI_Options{
		printer      = "vcore3",
		material     = "pla",
		process      = "0.20-standard",
		profiles_dir = "resources/profiles",
		clone_count  = 1,
		scale        = 1.0,
		input_paths  = make([dynamic]string),
		overrides    = make([dynamic]CLI_Override),
	}
	defer delete(opts.input_paths)
	defer delete(opts.overrides)

	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		if strings.has_prefix(arg, "--input=") {
			p := arg[len("--input="):]
			if len(opts.input_path) == 0 {opts.input_path = p}
			append(&opts.input_paths, p)
		} else if strings.has_prefix(arg, "--out=") {
			opts.output_path = arg[len("--out="):]
		} else if strings.has_prefix(arg, "--printer=") {
			opts.printer = arg[len("--printer="):]
		} else if strings.has_prefix(arg, "--material=") {
			opts.material = arg[len("--material="):]
		} else if strings.has_prefix(arg, "--process=") {
			opts.process = arg[len("--process="):]
		} else if strings.has_prefix(arg, "--profiles-dir=") {
			opts.profiles_dir = arg[len("--profiles-dir="):]
		} else if strings.has_prefix(arg, "--trace-json=") {
			opts.trace_json_path = arg[len("--trace-json="):]
		} else if strings.has_prefix(arg, "--dump-svg-dir=") {
			opts.svg_dir = arg[len("--dump-svg-dir="):]
		} else if arg == "--supports" {
			opts.enable_supports = true
		} else if arg == "--no-supports" {
			opts.enable_supports = false
		} else if arg == "--adaptive-layers" {
			opts.adaptive_layers = true
		} else if arg == "--lay-flat" {
			opts.lay_flat = true
		} else if strings.has_prefix(arg, "--clone=") {
			if n, ok := strconv.parse_int(arg[len("--clone="):]); ok && n >= 1 {
				opts.clone_count = n
			}
		} else if strings.has_prefix(arg, "--scale=") {
			if s, ok := strconv.parse_f64(arg[len("--scale="):]); ok && s > 0 {
				opts.scale = s
			}
		} else if strings.has_prefix(arg, "--rotate=") {
			parts := strings.split(arg[len("--rotate="):], ",", context.temp_allocator)
			if len(parts) == 3 {
				if v, ok := strconv.parse_f64(parts[0]); ok {opts.rot_x = v}
				if v, ok := strconv.parse_f64(parts[1]); ok {opts.rot_y = v}
				if v, ok := strconv.parse_f64(parts[2]); ok {opts.rot_z = v}
			}
		} else if arg == "--set" && i+1 < len(args) {
			i += 1
			pair := args[i]
			eq := strings.index_byte(pair, '=')
			if eq <= 0 {
				fmt.eprintf("error: invalid --set '%s' (expected key=value)\n", pair)
				os.exit(2)
			}
			append(&opts.overrides, CLI_Override{key = pair[:eq], val = pair[eq+1:]})
		} else if strings.has_prefix(arg, "--set=") {
			pair := arg[len("--set="):]
			eq := strings.index_byte(pair, '=')
			if eq <= 0 {
				fmt.eprintf("error: invalid --set '%s' (expected key=value)\n", pair)
				os.exit(2)
			}
			append(&opts.overrides, CLI_Override{key = pair[:eq], val = pair[eq+1:]})
		} else if arg == "-h" || arg == "--help" {
			print_usage()
			os.exit(0)
		} else {
			fmt.eprintf("error: unknown argument '%s'\n", arg)
			print_usage()
			os.exit(2)
		}
	}

	if len(opts.input_path) == 0 {
		print_usage()
		os.exit(2)
	}

	site := devlog.Site{feature = "cli", operation = "slice"}
	devlog.started(devlog.global(), site, {scope = "cli", stage = "profiles"})

	printer_path := resolve_profile_path(opts.profiles_dir, "printers", opts.printer)
	material_path := resolve_profile_path(opts.profiles_dir, "materials", opts.material)
	process_path := resolve_profile_path(opts.profiles_dir, "processes", opts.process)

	printer_prof, p_err := profiles.printer_profile_load_json(printer_path)
	if p_err != .None {
		fmt.eprintf("error: printer profile '%s': %s\n", printer_path, profiles.profile_json_error_text(p_err))
		os.exit(1)
	}
	material_prof, m_err := profiles.material_profile_load_json(material_path)
	if m_err != .None {
		fmt.eprintf("error: material profile '%s': %s\n", material_path, profiles.profile_json_error_text(m_err))
		os.exit(1)
	}
	process_prof, extras, pr_err := profiles.process_profile_load_json(process_path, printer_prof)
	if pr_err != .None {
		fmt.eprintf("error: process profile '%s': %s\n", process_path, profiles.profile_json_error_text(pr_err))
		os.exit(1)
	}
	profiles.profile_fit_printer(&process_prof, printer_prof)
	profiles.profile_fit_material(&process_prof, material_prof)
	for ov in opts.overrides {
		ov_err := profiles.profile_apply_override(&process_prof, &extras, ov.key, ov.val)
		if ov_err != .None {
			fmt.eprintf("error: override '%s=%s': %s\n", ov.key, ov.val, profiles.profile_json_error_text(ov_err))
			os.exit(1)
		}
	}
	dialect_prof := profiles.profiles_default_klipper_dialect()
	resolved, res_err := profiles.profiles_resolve(printer_prof, material_prof, process_prof, dialect_prof)
	if res_err != .None {
		fmt.eprintf("error: profile resolution failed: %v\n", res_err)
		os.exit(1)
	}

	input_bytes, read_err := os.read_entire_file(opts.input_path, context.allocator)
	if read_err != nil {
		fmt.eprintf("error: failed to read '%s'\n", opts.input_path)
		os.exit(1)
	}
	defer delete(input_bytes)

	run_opts := pipeline.DEFAULT_SLICE_RUN_OPTIONS
	run_opts.infill_density_percent = extras.infill_density_percent
	run_opts.enable_supports = opts.enable_supports
	run_opts.skirt_loops = extras.skirt_loops
	run_opts.skirt_distance_um = contracts.Micrometres(i64(math.round(extras.skirt_distance_mm*1000.0)))
	run_opts.skirt_height_layers = extras.skirt_height_layers
	run_opts.brim_width_um = contracts.Micrometres(i64(math.round(extras.brim_width_mm*1000.0)))
	run_opts.brim_gap_um = contracts.Micrometres(i64(math.round(extras.brim_gap_mm*1000.0)))
	run_opts.brim_inner = extras.brim_inner
	run_opts.elephant_foot_compensation_um = contracts.Micrometres(i64(math.round(extras.elephant_foot_compensation_mm*1000.0)))
	run_opts.wipe_distance_um = contracts.Micrometres(i64(math.round(extras.wipe_distance_mm*1000.0)))
	run_opts.overhang_slowdown_enabled = extras.overhang_slowdown_enabled
	run_opts.overhang_speed_percent = extras.overhang_speed_percent
	switch extras.seam_position {
	case "rear":     run_opts.seam_strategy = .Rear
	case "sharpest": run_opts.seam_strategy = .Sharpest_Corner
	case "nearest":  run_opts.seam_strategy = .Nearest
	case:            run_opts.seam_strategy = .Aligned
	}
	switch extras.infill_pattern {
	case "rectilinear": run_opts.infill_pattern = .Rectilinear
	case "grid":        run_opts.infill_pattern = .Grid
	case "triangles":   run_opts.infill_pattern = .Triangles
	case "cubic":       run_opts.infill_pattern = .Cubic
	case "honeycomb":   run_opts.infill_pattern = .Honeycomb
	case "lightning":   run_opts.infill_pattern = .Lightning
	case:               run_opts.infill_pattern = .Gyroid
	}
	run_opts.monotonic_skin = extras.monotonic_skin
	run_opts.ironing_enabled = extras.ironing_enabled
	run_opts.ironing_spacing_um = contracts.Micrometres(i64(math.round(extras.ironing_spacing_mm*1000.0)))
	run_opts.ironing_flow_percent = extras.ironing_flow_percent
	run_opts.arc_fitting_enabled = extras.arc_fitting_enabled
	run_opts.arc_tolerance_um = extras.arc_tolerance_mm * 1000.0
	run_opts.variable_walls_enabled = extras.variable_walls_enabled
	run_opts.support_style_tree = extras.support_style != "grid"
	run_opts.adaptive_layers = opts.adaptive_layers || extras.adaptive_layers
	raw_stem := strings.trim_suffix(filepath.base(opts.input_path), filepath.ext(opts.input_path))
	run_opts.object_name = strings.clone(raw_stem, context.temp_allocator)

	has_plate_ops := len(opts.input_paths) > 1 || opts.clone_count > 1 ||
		opts.scale != 1.0 || opts.rot_x != 0 || opts.rot_y != 0 || opts.rot_z != 0 || opts.lay_flat

	res: pipeline.Slice_Run_Result
	slice_err: pipeline.Slice_Run_Error
	if has_plate_ops {
		plate_objs := make([dynamic]pipeline.Plate_Object, 0, len(opts.input_paths) * opts.clone_count)
		defer {
			for &po in plate_objs {formats.decoded_mesh_destroy(&po.mesh)}
			delete(plate_objs)
		}
		for in_p in opts.input_paths {
			b, r_err := os.read_entire_file(in_p, context.allocator)
			if r_err != nil {
				fmt.eprintf("error: failed to read '%s'\n", in_p)
				os.exit(1)
			}
			mesh, units, dec_err := pipeline.decode_mesh_bytes(b, in_p, run_opts.source_units)
			delete(b)
			if len(dec_err.stage) > 0 {
				fmt.eprintf("SLICE FAILED at [%s]: %s\n", dec_err.stage, dec_err.detail)
				os.exit(1)
			}
			run_opts.source_units = units
			stem := strings.trim_suffix(filepath.base(in_p), filepath.ext(in_p))
			base_obj := pipeline.Plate_Object{
				name = stem,
				mesh = mesh,
				transform = {
					scale_x   = opts.scale,
					scale_y   = opts.scale,
					scale_z   = opts.scale,
					rot_x_deg = opts.rot_x,
					rot_y_deg = opts.rot_y,
					rot_z_deg = opts.rot_z,
					lay_flat  = opts.lay_flat,
				},
			}
			pipeline.plate_object_apply_transform(&base_obj)
			append(&plate_objs, base_obj)
			for ci in 1..<opts.clone_count {
				cloned := pipeline.plate_object_clone(base_obj, fmt.tprintf("%s_%d", stem, ci))
				append(&plate_objs, cloned)
			}
		}
		if !pipeline.plate_auto_arrange(plate_objs[:], resolved.printer) {
			fmt.eprintln("error: plate objects do not fit on build plate")
			os.exit(1)
		}
		merged := pipeline.plate_merge_to_mesh(plate_objs[:])
		defer formats.decoded_mesh_destroy(&merged)
		run_opts.center_on_bed = false
		res, slice_err = pipeline.slice_run_decoded_mesh(&merged, resolved, run_opts)
	} else {
		res, slice_err = pipeline.slice_run_bytes(input_bytes, opts.input_path, resolved, run_opts)
	}
	if len(slice_err.stage) > 0 {
		devlog.failed(devlog.global(), site, {reason = slice_err.detail, detail = slice_err.stage, severity = .Error}, {scope = "cli", stage = slice_err.stage})
		fmt.eprintf("SLICE FAILED at [%s]: %s\n", slice_err.stage, slice_err.detail)
		os.exit(1)
	}
	defer pipeline.slice_run_result_destroy(&res)

	fmt.printf("SLICE OK: %s  printer=%s material=%s process=%s\n",
		filepath.base(opts.input_path), opts.printer, opts.material, opts.process)
	fmt.printf("  tris=%d  layers=%d  repairs=%d  extrude=%d  travel=%d  filament=%.2f mm  gcode=%d bytes  total=%.2f ms\n",
		len(res.spine.mesh.triangle_ids),
		len(res.spine.schedule.layer_ids),
		res.contour_repairs,
		res.unified_plan.extrude_move_count,
		res.unified_plan.travel_move_count,
		f64(res.extrusion.total_filament_nm)/1_000_000.0,
		len(res.klipper.bytes),
		res.total_duration_ms)
	for st in res.stages {
		fmt.printf("  stage %-22s %8.2f ms  (a=%d, b=%d)\n", st.name, st.duration_ms, st.count_a, st.count_b)
	}

	if len(opts.output_path) > 0 {
		parent := filepath.dir(opts.output_path)
		if len(parent) > 0 && parent != "." {_ = os.make_directory_all(parent)}
		if os.write_entire_file(opts.output_path, res.klipper.bytes) != nil {
			fmt.eprintf("error: failed to write G-code '%s'\n", opts.output_path)
			os.exit(1)
		}
		fmt.printf("  wrote G-code: %s\n", opts.output_path)
	}

	if len(opts.trace_json_path) > 0 {
		parent := filepath.dir(opts.trace_json_path)
		if len(parent) > 0 && parent != "." {_ = os.make_directory_all(parent)}
		if !write_trace_json(opts.trace_json_path, opts, &res) {
			fmt.eprintf("error: failed to write trace JSON '%s'\n", opts.trace_json_path)
			os.exit(1)
		}
	}

	if len(opts.svg_dir) > 0 && len(res.unified_plan.layers) > 0 {
		_ = os.make_directory_all(opts.svg_dir)
		n := len(res.unified_plan.layers)
		picks := [5]int{0, n/4, n/2, (n*3)/4, n-1}
		stem := strings.trim_suffix(filepath.base(opts.input_path), filepath.ext(opts.input_path))
		for idx in picks {
			svg_path := fmt.tprintf("%s/%s-layer-%04d.svg", opts.svg_dir, stem, idx)
			_ = write_layer_svg(res.unified_plan, idx, svg_path)
		}
		fmt.printf("  wrote SVGs: %s/%s-layer-*.svg\n", opts.svg_dir, stem)
	}

	devlog.succeeded(devlog.global(), site, {scope = "cli", stage = "done"}, {rows = i64(res.unified_plan.extrude_move_count)})
	_ = math.PI
}
