package pipeline

import "core:fmt"
import "core:math"
import "core:os"

import contracts "../contracts"
import profiles "../profiles"

// The most worker threads a stage starts; the parallel helpers clamp to this as well.
WORKER_THREADS_MAX :: 16

// Worker threads for a requested count: the count itself, or every logical core for 0. Measured on
// a 10-core M-series machine (4 performance, 6 efficiency), 10 threads slice Benchy 6 % faster than
// 8 (optimization ledger OPT-12).
resolved_worker_threads :: proc(requested: int) -> int {
	if requested > 0 {return min(requested, WORKER_THREADS_MAX)}
	return clamp(os.get_processor_core_count(), 1, WORKER_THREADS_MAX)
}

// Everything a slice reads besides the model: the unresolved profile documents and the run flags
// that no profile carries. The CLI and the application edit one of these and resolve it into the
// profiles and options that a Slice_Session takes.
Slice_Configuration :: struct {
	printer:             profiles.Printer_Profile,
	material:            profiles.Material_Profile,
	process:             profiles.Process_Profile,
	extras:              profiles.Process_JSON_Extras,
	dialect:             profiles.Dialect_Profile,
	enable_supports:     bool,
	adaptive_layers:     bool,
	use_native_polygon:  bool,
	use_gpu:             bool,
	// 0 uses every logical core (see `resolved_worker_threads`).
	worker_threads:      int,
	scarf_seam:          bool,
	vase_mode:           bool,
	fuzzy_skin:          bool,
	source_units:        contracts.Source_Units,
	object_name:         string,
	modifiers:           []Modifier_Zone,
	pause_layers:        []u32,
	color_change_layers: []u32,
}

// Loads the three profile files. On failure `detail` names the file and the reason.
slice_configuration_load :: proc(
	printer_path, material_path, process_path: string,
) -> (config: Slice_Configuration, detail: string, ok: bool) {
	printer, p_err := profiles.printer_profile_load_json(printer_path)
	if p_err != .None {
		return {}, fmt.tprintf("printer profile '%s': %s", printer_path, profiles.profile_json_error_text(p_err)), false
	}
	material, m_err := profiles.material_profile_load_json(material_path)
	if m_err != .None {
		return {}, fmt.tprintf("material profile '%s': %s", material_path, profiles.profile_json_error_text(m_err)), false
	}
	process, extras, pr_err := profiles.process_profile_load_json(process_path, printer)
	if pr_err != .None {
		return {}, fmt.tprintf("process profile '%s': %s", process_path, profiles.profile_json_error_text(pr_err)), false
	}
	profiles.profile_fit_printer(&process, printer)
	profiles.profile_fit_material(&process, material)
	config = {
		printer            = printer,
		material           = material,
		process            = process,
		extras             = extras,
		dialect            = profiles.profiles_default_klipper_dialect(),
		use_native_polygon = true,
		use_gpu            = true,
	}
	return config, "", true
}

// Applies one `key=value` profile setting.
slice_configuration_override :: proc(
	config: ^Slice_Configuration,
	key, value: string,
) -> (detail: string, ok: bool) {
	err := profiles.profile_apply_override(&config.process, &config.extras, key, value)
	if err != .None {
		return fmt.tprintf("override '%s=%s': %s", key, value, profiles.profile_json_error_text(err)), false
	}
	return "", true
}

slice_configuration_resolve :: proc(
	config: Slice_Configuration,
) -> (resolved: profiles.Resolved_Profiles, options: Slice_Run_Options, detail: string, ok: bool) {
	process := config.process
	extras := config.extras
	if config.vase_mode {
		process.perimeter_count = 1
		extras.infill_density_percent = 0.0
	}
	err: profiles.Profile_Resolve_Error
	resolved, err = profiles.profiles_resolve(config.printer, config.material, process, config.dialect)
	if err != .None {
		return {}, {}, fmt.tprintf("profile resolution failed: %v", err), false
	}

	run := DEFAULT_SLICE_RUN_OPTIONS
	if config.source_units != .Unspecified {run.source_units = config.source_units}
	run.infill_density_percent = extras.infill_density_percent
	run.enable_supports = config.enable_supports
	run.skirt_loops = extras.skirt_loops
	run.skirt_distance_um = contracts.Micrometres(i64(math.round(extras.skirt_distance_mm*1000.0)))
	run.skirt_height_layers = extras.skirt_height_layers
	run.brim_width_um = contracts.Micrometres(i64(math.round(extras.brim_width_mm*1000.0)))
	run.brim_gap_um = contracts.Micrometres(i64(math.round(extras.brim_gap_mm*1000.0)))
	run.brim_inner = extras.brim_inner
	run.elephant_foot_compensation_um = contracts.Micrometres(i64(math.round(extras.elephant_foot_compensation_mm*1000.0)))
	run.wipe_distance_um = contracts.Micrometres(i64(math.round(extras.wipe_distance_mm*1000.0)))
	run.overhang_slowdown_enabled = extras.overhang_slowdown_enabled
	run.overhang_speed_percent = extras.overhang_speed_percent
	switch extras.seam_position {
	case "rear":     run.seam_strategy = .Rear
	case "sharpest": run.seam_strategy = .Sharpest_Corner
	case "nearest":  run.seam_strategy = .Nearest
	case:            run.seam_strategy = .Aligned
	}
	switch extras.infill_pattern {
	case "rectilinear": run.infill_pattern = .Rectilinear
	case "grid":        run.infill_pattern = .Grid
	case "triangles":   run.infill_pattern = .Triangles
	case "cubic":       run.infill_pattern = .Cubic
	case "honeycomb":   run.infill_pattern = .Honeycomb
	case "lightning":   run.infill_pattern = .Lightning
	case:               run.infill_pattern = .Gyroid
	}
	run.monotonic_skin = extras.monotonic_skin
	run.ironing_enabled = extras.ironing_enabled
	run.ironing_spacing_um = contracts.Micrometres(i64(math.round(extras.ironing_spacing_mm*1000.0)))
	run.ironing_flow_percent = extras.ironing_flow_percent
	run.arc_fitting_enabled = extras.arc_fitting_enabled
	run.arc_tolerance_um = extras.arc_tolerance_mm * 1000.0
	run.variable_walls_enabled = extras.variable_walls_enabled
	run.support_style_tree = extras.support_style != "grid"
	run.adaptive_layers = config.adaptive_layers || extras.adaptive_layers
	run.use_native_polygon = config.use_native_polygon
	run.use_gpu = config.use_gpu
	run.worker_threads = config.worker_threads
	run.scarf_seam_enabled = config.scarf_seam
	run.vase_mode = config.vase_mode
	run.fuzzy_skin_enabled = config.fuzzy_skin
	run.modifiers = config.modifiers
	run.pause_layers = config.pause_layers
	run.color_change_layers = config.color_change_layers
	run.object_name = config.object_name
	return resolved, run, "", true
}
