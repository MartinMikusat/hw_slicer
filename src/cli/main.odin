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
	trace_json_path:      string,
	svg_dir:              string,
	evidence_bundle_path: string,
	evidence_level:       contracts.Evidence_Level,
	enable_supports: bool,
	adaptive_layers: bool,
	clone_count:     int,
	scale:           f64,
	rot_x:           f64,
	rot_y:              f64,
	rot_z:              f64,
	lay_flat:           bool,
	use_native_polygon:  bool,
	use_gpu:             bool,
	worker_threads:      int,
	scarf_seam:          bool,
	vase_mode:           bool,
	fuzzy_skin:          bool,
	sequential:          bool,
	modifiers:           [dynamic]pipeline.Modifier_Zone,
	pause_layers:        [dynamic]u32,
	color_change_layers: [dynamic]u32,
	overrides:           [dynamic]CLI_Override,
	then_changes:        [dynamic]CLI_Override,
	sweep_axes:          [dynamic]pipeline.Sweep_Axis,
	workspace_script:    string,
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
	fmt.sbprintf(&b, "  \"input\": ")
	write_json_string(&b, filepath.base(opts.input_path))
	strings.write_string(&b, ",\n")
	fmt.sbprintf(&b, "  \"printer\": ")
	write_json_string(&b, opts.printer)
	strings.write_string(&b, ",\n")
	fmt.sbprintf(&b, "  \"material\": ")
	write_json_string(&b, opts.material)
	strings.write_string(&b, ",\n")
	fmt.sbprintf(&b, "  \"process\": ")
	write_json_string(&b, opts.process)
	strings.write_string(&b, ",\n")
	fmt.sbprintf(&b, "  \"triangles\": %d,\n", len(res.spine.mesh.triangle_ids))
	fmt.sbprintf(&b, "  \"layers\": %d,\n", len(res.spine.schedule.layer_ids))
	fmt.sbprintf(&b, "  \"contour_repairs\": %d,\n", res.contour_repairs)
	fmt.sbprintf(&b, "  \"extrude_moves\": %d,\n", res.unified_plan.extrude_move_count)
	fmt.sbprintf(&b, "  \"travel_moves\": %d,\n", res.unified_plan.travel_move_count)
	fmt.sbprintf(&b, "  \"filament_mm\": %.3f,\n", f64(res.extrusion.total_filament_nm)/1_000_000.0)
	fmt.sbprintf(&b, "  \"gcode_bytes\": %d,\n", len(res.klipper.bytes))
	fmt.sbprintf(&b, "  \"gcode_commands\": %d,\n", res.klipper.validation.command_count)
	fmt.sbprintf(&b, "  \"total_duration_ms\": %.3f,\n", res.total_duration_ms)
	strings.write_string(&b, "  \"stages\": [\n")
	for st, idx in res.stages {
		comma := "," if idx+1 < len(res.stages) else ""
		strings.write_string(&b, "    {\"name\": ")
		write_json_string(&b, st.name)
		fmt.sbprintf(&b, ", \"duration_ms\": %.3f, \"count_a\": %d, \"count_b\": %d}%s\n",
			st.duration_ms, st.count_a, st.count_b, comma)
	}
	strings.write_string(&b, "  ]\n}\n")
	return os.write_entire_file(dest_path, b.buf[:]) == nil
}

// Writes `value` as a quoted JSON string with quote, backslash and control characters escaped.
write_json_string :: proc(b: ^strings.Builder, value: string) {
	strings.write_byte(b, '"')
	for i in 0..<len(value) {
		c := value[i]
		switch c {
		case '"':  strings.write_string(b, "\\\"")
		case '\\': strings.write_string(b, "\\\\")
		case '\n': strings.write_string(b, "\\n")
		case '\r': strings.write_string(b, "\\r")
		case '\t': strings.write_string(b, "\\t")
		case:
			if c < 0x20 {
				fmt.sbprintf(b, "\\u%04x", c)
			} else {
				strings.write_byte(b, c)
			}
		}
	}
	strings.write_byte(b, '"')
}

print_usage :: proc() {
	fmt.eprintln("usage: hw-slicer-cli --input=<file.stl|.obj|.3mf> [--out=<file.gcode>] [--printer=vcore3] [--material=pla] [--process=0.20-standard] [--supports] [--set key=val] [--trace-json=<path>] [--dump-svg-dir=<dir>]")
}

// Slices once, then applies each `--then key=value` change in turn and reruns only the stages that
// the change made stale. Each step prints the stale stages and writes its G-code to
// `<out>.then<N>.gcode`, so it can be compared with a fresh slice of the same settings.
run_stage_reruns :: proc(opts: CLI_Options, config_in: pipeline.Slice_Configuration, input_bytes: []u8) {
	config := config_in
	resolved, run_opts, detail, ok := pipeline.slice_configuration_resolve(config)
	if !ok {
		fmt.eprintf("error: %s\n", detail)
		os.exit(1)
	}
	decoded, units, dec_err := pipeline.decode_mesh_bytes(input_bytes, opts.input_path, run_opts.source_units)
	if len(dec_err.stage) > 0 {
		fmt.eprintf("SLICE FAILED at [%s]: %s\n", dec_err.stage, dec_err.detail)
		os.exit(1)
	}
	defer formats.decoded_mesh_destroy(&decoded)
	run_opts.source_units = units
	config.source_units = units
	session := pipeline.slice_session_create(decoded, resolved, run_opts)
	defer pipeline.slice_session_destroy(session)

	run_step :: proc(session: ^pipeline.Slice_Session, label, out_path: string) {
		pending := pipeline.slice_session_pending(session, .Gcode)
		fmt.printf("%s: %d of %d stages to run\n", label, card(pending), len(pipeline.Stage_Id))
		for id in pipeline.Stage_Id {
			if id not_in pending {continue}
			slot := session.slots[id]
			why := "not run" if slot.state == .Not_Run else fmt.tprintf("stale, %s changed", pipeline.stage_descriptors[slot.changed_by].name)
			fmt.printf("  run  %-24s %s\n", pipeline.stage_descriptors[id].name, why)
		}
		if err := pipeline.slice_session_run_all(session); len(err.stage) > 0 {
			fmt.eprintf("SLICE FAILED at [%s]: %s\n", err.stage, err.detail)
			os.exit(1)
		}
		total := 0.0
		for id in pending {total += session.slots[id].duration_ms}
		fmt.printf("  ran %.2f ms; gcode %d bytes\n", total, len(session.klipper.bytes))
		if len(out_path) > 0 {
			_ = os.write_entire_file(out_path, session.klipper.bytes)
		}
	}
	card :: proc(set: pipeline.Stage_Set) -> int {
		n := 0
		for id in pipeline.Stage_Id {if id in set {n += 1}}
		return n
	}

	run_step(session, "initial", fmt.tprintf("%s.then0.gcode", opts.output_path) if len(opts.output_path) > 0 else "")
	for change, index in opts.then_changes {
		if detail, ok := pipeline.slice_configuration_override(&config, change.key, change.val); !ok {
			fmt.eprintf("error: %s\n", detail)
			os.exit(1)
		}
		new_resolved, new_opts, new_detail, new_ok := pipeline.slice_configuration_resolve(config)
		if !new_ok {
			fmt.eprintf("error: %s\n", new_detail)
			os.exit(1)
		}
		new_opts.source_units = units
		pipeline.slice_session_update(session, new_resolved, new_opts)
		label := fmt.tprintf("then %s=%s", change.key, change.val)
		out := fmt.tprintf("%s.then%d.gcode", opts.output_path, index+1) if len(opts.output_path) > 0 else ""
		run_step(session, label, out)
	}
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
		clone_count         = 1,
		scale               = 1.0,
		use_native_polygon  = true,
		use_gpu             = true,
		worker_threads      = 0,
		input_paths         = make([dynamic]string),
		modifiers           = make([dynamic]pipeline.Modifier_Zone),
		pause_layers        = make([dynamic]u32),
		color_change_layers = make([dynamic]u32),
		overrides           = make([dynamic]CLI_Override),
		then_changes        = make([dynamic]CLI_Override),
	}
	defer delete(opts.input_paths)
	defer delete(opts.modifiers)
	defer delete(opts.pause_layers)
	defer delete(opts.color_change_layers)
	defer delete(opts.overrides)
	defer delete(opts.then_changes)

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
		} else if arg == "--polygon-provider=odin" {
			opts.use_native_polygon = true
		} else if arg == "--polygon-provider=clipper2" {
			opts.use_native_polygon = false
		} else if arg == "--gpu" {
			opts.use_gpu = true
		} else if arg == "--no-gpu" {
			opts.use_gpu = false
		} else if strings.has_prefix(arg, "--threads=") {
			if n, ok := strconv.parse_int(arg[len("--threads="):]); ok && n >= 1 {
				opts.worker_threads = n
			}
		} else if arg == "--scarf-seam" {
			opts.scarf_seam = true
		} else if arg == "--vase-mode" {
			opts.vase_mode = true
		} else if arg == "--fuzzy-skin" {
			opts.fuzzy_skin = true
		} else if arg == "--sequential" {
			opts.sequential = true
		} else if strings.has_prefix(arg, "--evidence-bundle=") {
			opts.evidence_bundle_path = arg[len("--evidence-bundle="):]
			if opts.evidence_level == .Disabled {opts.evidence_level = .Summary}
		} else if strings.has_prefix(arg, "--evidence-level=") {
			switch arg[len("--evidence-level="):] {
			case "disabled", "none": opts.evidence_level = .Disabled
			case "summary":          opts.evidence_level = .Summary
			case "primitives", "full": opts.evidence_level = .Primitives
			case "renders":          opts.evidence_level = .Renders
			case:
				fmt.eprintf("error: unknown --evidence-level '%s'\n", arg[len("--evidence-level="):])
				os.exit(2)
			}
		} else if strings.has_prefix(arg, "--sweep=") {
			spec := arg[len("--sweep="):]
			if ax, ok := pipeline.sweep_axis_parse(spec); ok {
				append(&opts.sweep_axes, ax)
			} else {
				fmt.eprintf("error: invalid --sweep '%s' (expected key=v1,v2,...)\n", spec)
				os.exit(2)
			}
		} else if strings.has_prefix(arg, "--modifier=") {
			spec := arg[len("--modifier="):]
			if mod, ok := pipeline.modifier_parse(spec); ok {
				append(&opts.modifiers, mod)
			} else {
				fmt.eprintf("error: invalid --modifier '%s'\n", spec)
				os.exit(2)
			}
		} else if strings.has_prefix(arg, "--pause-at-layer=") {
			if n, ok := strconv.parse_int(arg[len("--pause-at-layer="):]); ok && n >= 0 {
				append(&opts.pause_layers, u32(n))
			}
		} else if strings.has_prefix(arg, "--color-change=") {
			if n, ok := strconv.parse_int(arg[len("--color-change="):]); ok && n >= 0 {
				append(&opts.color_change_layers, u32(n))
			}
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
		} else if strings.has_prefix(arg, "--workspace-script=") {
			opts.workspace_script = arg[len("--workspace-script="):]
		} else if strings.has_prefix(arg, "--then=") {
			pair := arg[len("--then="):]
			eq := strings.index_byte(pair, '=')
			if eq <= 0 {
				fmt.eprintf("error: invalid --then '%s' (expected key=value)\n", pair)
				os.exit(2)
			}
			append(&opts.then_changes, CLI_Override{key = pair[:eq], val = pair[eq+1:]})
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

	config, load_detail, load_ok := pipeline.slice_configuration_load(printer_path, material_path, process_path)
	if !load_ok {
		fmt.eprintf("error: %s\n", load_detail)
		os.exit(1)
	}
	for ov in opts.overrides {
		if detail, ok := pipeline.slice_configuration_override(&config, ov.key, ov.val); !ok {
			fmt.eprintf("error: %s\n", detail)
			os.exit(1)
		}
	}
	config.enable_supports = opts.enable_supports
	config.adaptive_layers = opts.adaptive_layers
	config.use_native_polygon = opts.use_native_polygon
	config.use_gpu = opts.use_gpu
	config.worker_threads = opts.worker_threads
	config.scarf_seam = opts.scarf_seam
	config.vase_mode = opts.vase_mode
	config.fuzzy_skin = opts.fuzzy_skin
	config.modifiers = opts.modifiers[:]
	config.pause_layers = opts.pause_layers[:]
	config.color_change_layers = opts.color_change_layers[:]
	config.object_name = strings.clone(strings.trim_suffix(filepath.base(opts.input_path), filepath.ext(opts.input_path)), context.temp_allocator)
	resolved, run_opts, resolve_detail, resolve_ok := pipeline.slice_configuration_resolve(config)
	if !resolve_ok {
		fmt.eprintf("error: %s\n", resolve_detail)
		os.exit(1)
	}
	run_opts.evidence_level = opts.evidence_level

	input_bytes, read_err := os.read_entire_file(opts.input_path, context.allocator)
	if read_err != nil {
		fmt.eprintf("error: failed to read '%s'\n", opts.input_path)
		os.exit(1)
	}
	defer delete(input_bytes)


	has_plate_ops := len(opts.input_paths) > 1 || opts.clone_count > 1 ||
		opts.scale != 1.0 || opts.rot_x != 0 || opts.rot_y != 0 || opts.rot_z != 0 || opts.lay_flat

	if len(opts.sweep_axes) > 0 {
		mesh, units, dec_err := pipeline.decode_mesh_bytes(input_bytes, opts.input_path, run_opts.source_units)
		if len(dec_err.stage) > 0 {
			fmt.eprintf("SLICE FAILED at [%s]: %s\n", dec_err.stage, dec_err.detail)
			os.exit(1)
		}
		defer formats.decoded_mesh_destroy(&mesh)
		config.source_units = units
		stem := strings.trim_suffix(filepath.base(opts.input_path), filepath.ext(opts.input_path))
		sweep_res, sweep_err := pipeline.plate_slice_settings_sweep(mesh, stem, config, opts.sweep_axes[:])
		if len(sweep_err.stage) > 0 {
			fmt.eprintf("SWEEP FAILED at [%s]: %s\n", sweep_err.stage, sweep_err.detail)
			os.exit(1)
		}
		defer pipeline.sweep_result_destroy(&sweep_res)
		est_s := int(math.round(sweep_res.plate.total_seconds))
		fmt.printf("SLICE OK (sweep %d copies): %s  printer=%s material=%s process=%s\n",
			len(sweep_res.copies), filepath.base(opts.input_path), opts.printer, opts.material, opts.process)
		fmt.printf("  tris=%d  layers=%d  repairs=%d  extrude=%d  travel=%d  filament=%.2f mm  est_time=%02d:%02d:%02d  gcode=%d bytes  total=%.2f ms\n",
			sweep_res.plate.total_triangles, sweep_res.plate.total_layers, sweep_res.plate.total_repairs,
			sweep_res.plate.extrude_move_count, sweep_res.plate.travel_move_count,
			f64(sweep_res.plate.positive_filament_nm)/1_000_000.0,
			est_s/3600, (est_s%3600)/60, est_s%60,
			len(sweep_res.plate.gcode_bytes), sweep_res.plate.total_duration_ms)
		for c in sweep_res.copies {
			fmt.printf("  copy %2d: %-18s  at (%.1f, %.1f) mm  %s\n", c.index+1, c.name, c.center_x_mm, c.center_y_mm, c.settings)
		}
		if len(opts.output_path) > 0 {
			parent := filepath.dir(opts.output_path)
			if len(parent) > 0 && parent != "." {_ = os.make_directory_all(parent)}
			if os.write_entire_file(opts.output_path, sweep_res.plate.gcode_bytes) != nil {
				fmt.eprintf("error: failed to write G-code '%s'\n", opts.output_path)
				os.exit(1)
			}
			fmt.printf("  wrote G-code: %s\n", opts.output_path)
		}
		devlog.succeeded(devlog.global(), site, {scope = "cli", stage = "done"}, {rows = i64(sweep_res.plate.extrude_move_count)})
		return
	}

	if len(opts.workspace_script) > 0 {
		mesh, units, dec_err := pipeline.decode_mesh_bytes(input_bytes, opts.input_path, run_opts.source_units)
		if len(dec_err.stage) > 0 {
			fmt.eprintf("SLICE FAILED at [%s]: %s\n", dec_err.stage, dec_err.detail)
			os.exit(1)
		}
		defer formats.decoded_mesh_destroy(&mesh)
		config.source_units = units
		run_workspace_script(opts.workspace_script, config, mesh)
		return
	}
	if len(opts.then_changes) > 0 && !has_plate_ops {
		run_stage_reruns(opts, config, input_bytes)
		return
	}

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
		// Sequential printing needs the extruder clearance between neighbours, plus a margin
		// because the clearance check treats touching bounds as a collision.
		arrange_gap_mm := 8.0
		if opts.sequential {
			arrange_gap_mm = pipeline.DEFAULT_SEQUENTIAL_CLEARANCE.extruder_radius_mm + 1.0
		}
		if !pipeline.plate_auto_arrange(plate_objs[:], resolved.printer, arrange_gap_mm) {
			fmt.eprintln("error: plate objects do not fit on build plate")
			os.exit(1)
		}
		if opts.sequential {
			seq_ok, ca, cb := pipeline.plate_validate_sequential(plate_objs[:])
			if !seq_ok {
				fmt.eprintf("error: sequential printing collision between object %d and %d\n", ca, cb)
				os.exit(1)
			}
			if len(plate_objs) > 1 {
				seq_res, seq_err := pipeline.plate_slice_sequential(plate_objs[:], resolved, run_opts)
				if len(seq_err.stage) > 0 {
					devlog.failed(devlog.global(), site, {reason = seq_err.detail, detail = seq_err.stage, severity = .Error}, {scope = "cli", stage = seq_err.stage})
					fmt.eprintf("SLICE FAILED at [%s]: %s\n", seq_err.stage, seq_err.detail)
					os.exit(1)
				}
				defer pipeline.sequential_slice_result_destroy(&seq_res)
				fmt.printf("SLICE OK (sequential %d objects): %s  printer=%s material=%s process=%s\n",
					seq_res.object_count, filepath.base(opts.input_path), opts.printer, opts.material, opts.process)
				est_s := int(math.round(seq_res.total_seconds))
				fmt.printf("  tris=%d  layers=%d  repairs=%d  extrude=%d  travel=%d  filament=%.2f mm  est_time=%02d:%02d:%02d  gcode=%d bytes  total=%.2f ms\n",
					seq_res.total_triangles,
					seq_res.total_layers,
					seq_res.total_repairs,
					seq_res.extrude_move_count,
					seq_res.travel_move_count,
					f64(seq_res.positive_filament_nm)/1_000_000.0,
					est_s/3600, (est_s%3600)/60, est_s%60,
					len(seq_res.gcode_bytes),
					seq_res.total_duration_ms)
				if len(opts.output_path) > 0 {
					parent := filepath.dir(opts.output_path)
					if len(parent) > 0 && parent != "." {_ = os.make_directory_all(parent)}
					if os.write_entire_file(opts.output_path, seq_res.gcode_bytes) != nil {
						fmt.eprintf("error: failed to write G-code '%s'\n", opts.output_path)
						os.exit(1)
					}
					fmt.printf("  wrote G-code: %s\n", opts.output_path)
				}
				devlog.succeeded(devlog.global(), site, {scope = "cli", stage = "done"}, {rows = i64(seq_res.extrude_move_count)})
				return
			}
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
	est_s := int(math.round(res.estimated_seconds))
	reported_filament_nm := u128(res.extrusion.total_filament_nm)
	if res.klipper.positive_filament_nm > res.klipper.negative_filament_nm {
		reported_filament_nm = res.klipper.positive_filament_nm - res.klipper.negative_filament_nm
	}
	fmt.printf("  tris=%d  layers=%d  repairs=%d  extrude=%d  travel=%d  filament=%.2f mm  est_time=%02d:%02d:%02d  gcode=%d bytes  total=%.2f ms\n",
		len(res.spine.mesh.triangle_ids),
		len(res.spine.schedule.layer_ids),
		res.contour_repairs,
		res.unified_plan.extrude_move_count,
		res.unified_plan.travel_move_count,
		f64(reported_filament_nm)/1_000_000.0,
		est_s/3600, (est_s%3600)/60, est_s%60,
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

	if len(opts.evidence_bundle_path) > 0 && len(res.evidence_bundle_bytes) > 0 {
		parent := filepath.dir(opts.evidence_bundle_path)
		if len(parent) > 0 && parent != "." {_ = os.make_directory_all(parent)}
		if os.write_entire_file(opts.evidence_bundle_path, res.evidence_bundle_bytes) != nil {
			fmt.eprintf("error: failed to write evidence bundle '%s'\n", opts.evidence_bundle_path)
			os.exit(1)
		}
		fmt.printf("  wrote evidence bundle: %s (%d bytes)\n", opts.evidence_bundle_path, len(res.evidence_bundle_bytes))
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
