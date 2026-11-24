package main

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import devlog "devlog:."
import text_input "components:text_input"

import cfg "./configuration"
import mr "./moonraker"

CONFIG_MAIN_FILE :: "printer.cfg"
CONFIG_PARAM_MAX :: 26
CONFIG_LAYERED_ROWS_MAX :: 48

Printer_Config_Mode :: enum u8 {
	Guided,
	Layered,
}

Printer_Config_Subsystem :: enum u8 {
	Build_Plate,
	Bed_Mesh,
	Toolhead,
	Board_Wiring,
	Heaters,
}

PRINTER_SUBSYSTEM_NAMES := [Printer_Config_Subsystem]string{
	.Build_Plate  = "Build Plate",
	.Bed_Mesh     = "Bed Mesh",
	.Toolhead     = "Toolhead",
	.Board_Wiring = "Board",
	.Heaters      = "Heaters",
}

Config_Param_Def :: struct {
	subsystem: Printer_Config_Subsystem,
	section:   string,
	key:       string,
	label:     string,
	unit:      string,
	fallback:  string,
}

PRINTER_CONFIG_PARAMS := [CONFIG_PARAM_MAX]Config_Param_Def{
	// Build Plate & Motion
	{.Build_Plate, "stepper_x", "position_max", "Build plate X", "mm", "300"},
	{.Build_Plate, "stepper_y", "position_max", "Build plate Y", "mm", "300"},
	{.Build_Plate, "stepper_z", "position_max", "Travel Z max", "mm", "300"},
	{.Build_Plate, "printer", "max_velocity", "Max velocity", "mm/s", "500"},
	{.Build_Plate, "printer", "max_accel", "Max acceleration", "mm/s²", "5000"},
	{.Build_Plate, "printer", "max_z_velocity", "Max Z velocity", "mm/s", "30"},
	{.Build_Plate, "printer", "max_z_accel", "Max Z accel", "mm/s²", "300"},
	// Bed Mesh
	{.Bed_Mesh, "bed_mesh", "mesh_min", "Mesh min (X, Y)", "mm", "20, 20"},
	{.Bed_Mesh, "bed_mesh", "mesh_max", "Mesh max (X, Y)", "mm", "280, 280"},
	{.Bed_Mesh, "bed_mesh", "probe_count", "Probe count (X, Y)", "pts", "5, 5"},
	{.Bed_Mesh, "bed_mesh", "speed", "Probe travel speed", "mm/s", "200"},
	{.Bed_Mesh, "bed_mesh", "horizontal_move_z", "Hop Z height", "mm", "5"},
	// Toolhead & Probe
	{.Toolhead, "extruder", "nozzle_diameter", "Nozzle diameter", "mm", "0.400"},
	{.Toolhead, "extruder", "filament_diameter", "Filament diameter", "mm", "1.750"},
	{.Toolhead, "extruder", "rotation_distance", "Extruder rotation dist", "mm", "22.678"},
	{.Toolhead, "extruder", "pressure_advance", "Pressure advance", "s", "0.04"},
	{.Toolhead, "probe", "x_offset", "Probe X offset", "mm", "0"},
	{.Toolhead, "probe", "y_offset", "Probe Y offset", "mm", "0"},
	{.Toolhead, "probe", "z_offset", "Probe Z offset", "mm", "0"},
	// Board & Wiring
	{.Board_Wiring, "mcu", "serial", "Mainboard MCU", "", "/dev/serial/..."},
	{.Board_Wiring, "stepper_x", "step_pin", "X step pin", "", ""},
	{.Board_Wiring, "stepper_y", "step_pin", "Y step pin", "", ""},
	{.Board_Wiring, "stepper_z", "step_pin", "Z step pin", "", ""},
	// Heaters & Limits
	{.Heaters, "extruder", "max_temp", "Hotend max temp", "°C", "290"},
	{.Heaters, "heater_bed", "max_temp", "Bed max temp", "°C", "120"},
	{.Heaters, "extruder", "min_extrude_temp", "Min extrude temp", "°C", "170"},
}

Config_Flat_Row :: struct {
	section_idx: int,
	key_idx:     int,
	drifted:     bool,
	overridden:  bool,
}

Printer_Config_State :: struct {
	mode:            Printer_Config_Mode,
	subsystem:       Printer_Config_Subsystem,
	loading:         bool,
	waiting_list:    bool,
	waiting_file:    string,
	uploading:       bool,
	resolved:        bool,
	sources:         [dynamic]cfg.Source,
	resolution:      cfg.Resolution,
	differences:     [dynamic]cfg.Difference,
	drafts:          [CONFIG_PARAM_MAX]string,
	dirty:           [CONFIG_PARAM_MAX]bool,
	search:          string,
	overridden_only: bool,
	drift_only:      bool,
	layered_rows:    [dynamic]Config_Flat_Row,
	layered_scroll:  int,
	selected_row:    int,
	status:          string,
	status_failed:   bool,
}

printer_config_destroy :: proc(c: ^Printer_Config_State) {
	if c.resolved {cfg.resolution_destroy(&c.resolution)}
	for s in c.sources {
		delete(s.path)
		delete(s.data)
	}
	delete(c.sources)
	delete(c.differences)
	delete(c.layered_rows)
	delete(c.waiting_file)
	delete(c.search)
	delete(c.status)
	for &d in c.drafts {delete(d)}
	c^ = {}
}

@(private = "file")
printer_config_set_status :: proc(c: ^Printer_Config_State, text: string, failed := false) {
	delete(c.status)
	c.status = strings.clone(text)
	c.status_failed = failed
	app.needs_redraw = true
}

@(private = "file")
printer_config_clear_sources :: proc(c: ^Printer_Config_State) {
	if c.resolved {
		cfg.resolution_destroy(&c.resolution)
		c.resolved = false
	}
	for s in c.sources {
		delete(s.path)
		delete(s.data)
	}
	clear(&c.sources)
	clear(&c.differences)
	clear(&c.layered_rows)
	delete(c.waiting_file)
	c.waiting_file = ""
}

printer_config_refresh :: proc(p: ^Printer_State) {
	c := &p.config
	if p.demo || p.client.state.connection != .Connected {
		printer_config_set_status(c, "Connect to Moonraker to load live Klipper configuration", true)
		return
	}
	printer_config_clear_sources(c)
	c.loading = true
	c.waiting_list = true
	if !mr.refresh_config_files(&p.client) {
		c.loading = false
		c.waiting_list = false
		printer_config_set_status(c, p.client.state.error if len(p.client.state.error) > 0 else "Could not list config files", true)
		return
	}
	printer_config_set_status(c, "Listing configuration files…")
}

@(private = "file")
printer_config_rebuild_layered :: proc(c: ^Printer_Config_State) {
	clear(&c.layered_rows)
	if !c.resolved {return}
	needle := strings.to_lower(strings.trim_space(c.search), context.temp_allocator)
	for &sec, si in c.resolution.sections {
		for &key, ki in sec.keys {
			final, has_final := cfg.final_entry(&key)
			if !has_final {continue}
			overridden := len(key.entries) > 1
			drifted := false
			for d in c.differences {
				if d.section == sec.name && d.key == key.name {
					drifted = true
					break
				}
			}
			if c.overridden_only && !overridden {continue}
			if c.drift_only && !drifted {continue}
			if len(needle) > 0 {
				s_lo := strings.to_lower(sec.name, context.temp_allocator)
				k_lo := strings.to_lower(key.name, context.temp_allocator)
				v_lo := strings.to_lower(final.value, context.temp_allocator)
				if !strings.contains(s_lo, needle) && !strings.contains(k_lo, needle) && !strings.contains(v_lo, needle) {
					continue
				}
			}
			append(&c.layered_rows, Config_Flat_Row{si, ki, drifted, overridden})
		}
	}
	if c.selected_row >= len(c.layered_rows) {
		c.selected_row = max(0, len(c.layered_rows) - 1)
	}
}

printer_config_sync_drafts :: proc(c: ^Printer_Config_State) {
	for def, i in PRINTER_CONFIG_PARAMS {
		if c.dirty[i] {continue}
		val := def.fallback
		if c.resolved {
			if key, found := cfg.find_key(&c.resolution, def.section, def.key); found {
				if entry, ok := cfg.final_entry(key); ok {
					val = entry.value
				}
			}
		}
		delete(c.drafts[i])
		c.drafts[i] = strings.clone(val)
	}
}

@(private = "file")
printer_config_try_resolve :: proc(p: ^Printer_State) {
	c := &p.config
	listing := make([dynamic]string, context.temp_allocator)
	for f in p.client.state.config_files {append(&listing, f.path)}
	if len(listing) == 0 {
		c.loading = false
		printer_config_set_status(c, "No configuration files found on Moonraker", true)
		return
	}
	if c.resolved {
		cfg.resolution_destroy(&c.resolution)
		c.resolved = false
	}
	if !cfg.resolve(&c.resolution, CONFIG_MAIN_FILE, listing[:], c.sources[:]) {
		c.loading = false
		printer_config_set_status(c, "Configuration resolution failed", true)
		return
	}
	if cfg.complete(&c.resolution) {
		c.resolved = true
		c.loading = false
		clear(&c.differences)
		if running, ok := mr.running_configuration(&p.client); ok {
			diffs := cfg.compare_running(&c.resolution, running, context.allocator)
			delete(c.differences)
			c.differences = diffs
		}
		printer_config_sync_drafts(c)
		printer_config_rebuild_layered(c)
		app.section_dirty = true
		printer_config_set_status(c, fmt.tprintf("Loaded %d layers · %d sections · %d drifted",
			len(c.resolution.layers), len(c.resolution.sections), len(c.differences)))
		return
	}
	if len(c.sources) >= cfg.LAYERS_MAX {
		c.loading = false
		cfg.resolution_destroy(&c.resolution)
		printer_config_set_status(c, "Include depth limit reached", true)
		return
	}
	next_path := strings.clone(c.resolution.missing[0])
	cfg.resolution_destroy(&c.resolution)
	delete(c.waiting_file)
	c.waiting_file = next_path
	if !mr.read_config(&p.client, next_path) {
		c.loading = false
		delete(c.waiting_file)
		c.waiting_file = ""
		printer_config_set_status(c, p.client.state.error if len(p.client.state.error) > 0 else "Failed to download config file", true)
		return
	}
	printer_config_set_status(c, fmt.tprintf("Reading %s…", next_path))
}

printer_config_poll :: proc(p: ^Printer_State) -> bool {
	c := &p.config
	if c.uploading && p.client.state.transfer.kind == .Config_Upload {
		switch p.client.state.transfer.status {
		case .Complete:
			c.uploading = false
			for &d in c.dirty {d = false}
			devlog.succeeded(devlog.global(), {feature = "config", operation = "save_printer_cfg"})
			printer_config_set_status(c, "Saved printer.cfg — restart Klipper to apply")
			printer_config_refresh(p)
			return true
		case .Failed, .Cancelled:
			c.uploading = false
			devlog.failed(devlog.global(), {feature = "config", operation = "save_printer_cfg"}, {reason = "upload failed", detail = p.client.state.error})
			printer_config_set_status(c, p.client.state.error if len(p.client.state.error) > 0 else "Failed to upload printer.cfg", true)
			return true
		case .Idle, .Running:
		}
	}
	if !c.loading {return false}
	if c.waiting_list {
		if mr.has_pending(&p.client, .Config_Files) {return false}
		c.waiting_list = false
		printer_config_try_resolve(p)
		return true
	}
	if len(c.waiting_file) > 0 && p.client.state.transfer.kind == .Config_Download {
		switch p.client.state.transfer.status {
		case .Complete:
			path := c.waiting_file
			c.waiting_file = ""
			append(&c.sources, cfg.Source{path, strings.clone(string(p.client.state.transfer.data))})
			printer_config_try_resolve(p)
			return true
		case .Failed, .Cancelled:
			c.loading = false
			delete(c.waiting_file)
			c.waiting_file = ""
			printer_config_set_status(c, p.client.state.error if len(p.client.state.error) > 0 else "Config file download failed", true)
			return true
		case .Idle, .Running:
		}
	}
	return false
}

printer_config_dirty_count :: proc(c: ^Printer_Config_State) -> int {
	n := 0
	for d in c.dirty {if d {n += 1}}
	return n
}

printer_config_save :: proc(p: ^Printer_State) {
	c := &p.config
	if !c.resolved || p.demo || p.client.state.connection != .Connected {
		printer_config_set_status(c, "Load live configuration before saving printer.cfg", true)
		return
	}
	updates := make([dynamic]cfg.Update, context.temp_allocator)
	for def, i in PRINTER_CONFIG_PARAMS {
		if !c.dirty[i] {continue}
		val := strings.trim_space(c.drafts[i])
		if len(val) == 0 {continue}
		append(&updates, cfg.Update{section = def.section, key = def.key, value = val})
	}
	if len(updates) == 0 {
		printer_config_set_status(c, "No modified parameters to save")
		return
	}
	main_text := ""
	for s in c.sources {
		if s.path == CONFIG_MAIN_FILE {
			main_text = s.data
			break
		}
	}
	if len(main_text) == 0 {
		printer_config_set_status(c, "printer.cfg source is unavailable", true)
		return
	}
	updated, ok := cfg.apply_overrides(main_text, updates[:], context.temp_allocator)
	if !ok {
		printer_config_set_status(c, "Could not apply overrides to printer.cfg", true)
		return
	}
	devlog.started(devlog.global(), {feature = "config", operation = "save_printer_cfg"})
	if mr.upload_config(&p.client, CONFIG_MAIN_FILE, transmute([]u8)updated) {
		c.uploading = true
		printer_config_set_status(c, fmt.tprintf("Uploading printer.cfg (%d updates)…", len(updates)))
	} else {
		printer_config_set_status(c, p.client.state.error if len(p.client.state.error) > 0 else "Upload rejected", true)
	}
}

printer_config_revert :: proc(p: ^Printer_State) {
	c := &p.config
	for &d in c.dirty {d = false}
	printer_config_sync_drafts(c)
	app.section_dirty = true
	printer_config_set_status(c, "Reverted unsaved edits")
}

// 3D build-volume & bed-mesh overlay in hw_slicer's Metal viewport --------------------------------

printer_config_shows_3d :: proc(p: ^Printer_State) -> bool {
	return p.subtab == .Config && p.config.mode == .Guided &&
		(p.config.subsystem == .Build_Plate || p.config.subsystem == .Bed_Mesh)
}

@(private = "file")
printer_config_parse_f32 :: proc(s: string, fallback: f32) -> f32 {
	if v, ok := strconv.parse_f64(strings.trim_space(s)); ok && !math.is_nan(v) && !math.is_inf(v, 0) {
		return f32(v)
	}
	return fallback
}

@(private = "file")
printer_config_parse_pair :: proc(s: string, fa, fb: f32) -> (f32, f32) {
	parts := strings.split(s, ",", context.temp_allocator)
	if len(parts) < 2 {return fa, fb}
	return printer_config_parse_f32(parts[0], fa), printer_config_parse_f32(parts[1], fb)
}

printer_config_build_3d_lines :: proc(p: ^Printer_State, out: ^[dynamic]Mesh_Vertex) {
	clear(out)
	c := &p.config
	bx := clamp(printer_config_parse_f32(c.drafts[0], 300), 50, 1000)
	by := clamp(printer_config_parse_f32(c.drafts[1], 300), 50, 1000)
	bz := clamp(printer_config_parse_f32(c.drafts[2], 300), 50, 1000)
	hx, hy := bx*0.5, by*0.5
	up := Vec3{0, 0, 1}
	add_seg :: proc(out: ^[dynamic]Mesh_Vertex, a, b, up: Vec3) {
		append(out, Mesh_Vertex{a, up}, Mesh_Vertex{b, up})
	}
	// Build volume wireframe box.
	c000 := Vec3{-hx, -hy, 0}; c100 := Vec3{hx, -hy, 0}
	c110 := Vec3{hx, hy, 0};   c010 := Vec3{-hx, hy, 0}
	c001 := Vec3{-hx, -hy, bz}; c101 := Vec3{hx, -hy, bz}
	c111 := Vec3{hx, hy, bz};   c011 := Vec3{-hx, hy, bz}
	add_seg(out, c000, c100, up); add_seg(out, c100, c110, up)
	add_seg(out, c110, c010, up); add_seg(out, c010, c000, up)
	add_seg(out, c001, c101, up); add_seg(out, c101, c111, up)
	add_seg(out, c111, c011, up); add_seg(out, c011, c001, up)
	add_seg(out, c000, c001, up); add_seg(out, c100, c101, up)
	add_seg(out, c110, c111, up); add_seg(out, c010, c011, up)

	// Bed mesh probe grid when Bed Mesh subsystem is selected.
	if c.subsystem == .Bed_Mesh {
		mx0, my0 := printer_config_parse_pair(c.drafts[7], 20, 20)
		mx1, my1 := printer_config_parse_pair(c.drafts[8], bx-20, by-20)
		px_f, py_f := printer_config_parse_pair(c.drafts[9], 5, 5)
		nx := clamp(int(math.round(f64(px_f))), 2, 15)
		ny := clamp(int(math.round(f64(py_f))), 2, 15)
		for ix in 0..<nx {
			tx := f32(ix) / f32(max(1, nx-1))
			x := mx0 + (mx1 - mx0)*tx - hx
			add_seg(out, {x, my0-hy, 0.5}, {x, my1-hy, 0.5}, up)
		}
		for iy in 0..<ny {
			ty := f32(iy) / f32(max(1, ny-1))
			y := my0 + (my1 - my0)*ty - hy
			add_seg(out, {mx0-hx, y, 0.5}, {mx1-hx, y, 0.5}, up)
		}
	}
}

// Action ID helpers -------------------------------------------------------------------------------

printer_cfg_param_action :: proc(index: int) -> UI_Action {
	return UI_Action(u64(UI_Action.Printer_Cfg_Param_Base) + u64(index))
}
printer_cfg_param_index :: proc(action: UI_Action) -> (int, bool) {
	id := u64(action)
	base := u64(UI_Action.Printer_Cfg_Param_Base)
	if id < base || id-base >= CONFIG_PARAM_MAX {return 0, false}
	return int(id-base), true
}

printer_cfg_row_action :: proc(index: int) -> UI_Action {
	return UI_Action(u64(UI_Action.Printer_Cfg_Row_Base) + u64(index))
}
printer_cfg_row_index :: proc(action: UI_Action) -> (int, bool) {
	id := u64(action)
	base := u64(UI_Action.Printer_Cfg_Row_Base)
	if id < base || id-base >= CONFIG_LAYERED_ROWS_MAX {return 0, false}
	return int(id-base), true
}

printer_config_field_ptr :: proc(p: ^Printer_State, action: UI_Action) -> ^string {
	if action == .Printer_Cfg_Search {return &p.config.search}
	if idx, ok := printer_cfg_param_index(action); ok {return &p.config.drafts[idx]}
	return nil
}

printer_config_on_field_edited :: proc(p: ^Printer_State, action: UI_Action) {
	if action == .Printer_Cfg_Search {
		p.config.layered_scroll = 0
		printer_config_rebuild_layered(&p.config)
		return
	}
	if idx, ok := printer_cfg_param_index(action); ok {
		p.config.dirty[idx] = true
		if printer_config_shows_3d(p) {app.section_dirty = true}
	}
}

printer_config_activate :: proc(p: ^Printer_State, action: UI_Action) -> bool {
	c := &p.config
	if idx, ok := printer_cfg_param_index(action); ok {
		_ = idx
		printer_focus_field(p, action)
		return true
	}
	if row, ok := printer_cfg_row_index(action); ok {
		idx := c.layered_scroll + row
		if idx >= 0 && idx < len(c.layered_rows) {
			c.selected_row = idx
			app.needs_redraw = true
		}
		return true
	}
	#partial switch action {
	case .Printer_Cfg_Mode_Guided:
		printer_blur_field(p)
		c.mode = .Guided
		app.section_dirty = true
	case .Printer_Cfg_Mode_Layered:
		printer_blur_field(p)
		c.mode = .Layered
		printer_config_rebuild_layered(c)
		app.section_dirty = true
	case .Printer_Cfg_Sub_Build:  c.subsystem = .Build_Plate; app.section_dirty = true
	case .Printer_Cfg_Sub_Mesh:   c.subsystem = .Bed_Mesh; app.section_dirty = true
	case .Printer_Cfg_Sub_Tool:   c.subsystem = .Toolhead; app.section_dirty = true
	case .Printer_Cfg_Sub_Board:  c.subsystem = .Board_Wiring; app.section_dirty = true
	case .Printer_Cfg_Sub_Heat:   c.subsystem = .Heaters; app.section_dirty = true
	case .Printer_Cfg_Refresh:
		printer_blur_field(p)
		printer_config_refresh(p)
	case .Printer_Cfg_Save:
		printer_blur_field(p)
		printer_config_save(p)
	case .Printer_Cfg_Revert:
		printer_blur_field(p)
		printer_config_revert(p)
	case .Printer_Cfg_Search:
		printer_focus_field(p, action)
	case .Printer_Cfg_Overridden:
		c.overridden_only = !c.overridden_only
		c.layered_scroll = 0
		printer_config_rebuild_layered(c)
	case .Printer_Cfg_Drift:
		c.drift_only = !c.drift_only
		c.layered_scroll = 0
		printer_config_rebuild_layered(c)
	case:
		return false
	}
	app.needs_redraw = true
	return true
}

printer_config_layered_visible :: proc(ui: ^UI_State) -> int {
	vp := ui_printer_viewport_rect(ui)
	return clamp(int((vp.h - 110) / 28), 1, CONFIG_LAYERED_ROWS_MAX)
}

printer_config_scroll :: proc(p: ^Printer_State, delta_y: f64) -> bool {
	c := &p.config
	if c.mode == .Layered {
		visible := printer_config_layered_visible(&app.ui)
		step := -1 if delta_y > 0 else 1
		c.layered_scroll = clamp(c.layered_scroll + step, 0, max(0, len(c.layered_rows) - visible))
		app.needs_redraw = true
		return true
	}
	if printer_config_shows_3d(p) {
		panel := ui_printer_config_left_rect(&app.ui)
		if !ui_contains(panel, app.ui.pointer_x, app.ui.pointer_y) {
			return false // allow 3D camera zoom on the right half
		}
	}
	return true
}

ui_printer_config_left_rect :: proc(ui: ^UI_State) -> UI_Rect {
	vp := ui_printer_viewport_rect(ui)
	if printer_config_shows_3d(&app.printer) {
		return {vp.x, vp.y, max(320.0, vp.w*0.48), vp.h}
	}
	return vp
}

// Controls & Drawing ------------------------------------------------------------------------------

ui_printer_config_controls :: proc(ui: ^UI_State) {
	p := &app.printer
	c := &p.config
	panel := ui_printer_config_left_rect(ui)
	y := panel.y + 12

	ui_add_control(ui, "config guided", "Guided configuration", {panel.x+12, y, 76, 28}, .Printer_Cfg_Mode_Guided, true, 1, c.mode == .Guided)
	ui_add_control(ui, "config layered", "Layered include view", {panel.x+94, y, 78, 28}, .Printer_Cfg_Mode_Layered, true, 1, c.mode == .Layered)
	ui_add_control(ui, "config refresh", "Refresh configuration from Moonraker", {panel.x+180, y, 76, 28}, .Printer_Cfg_Refresh, p.client.state.connection == .Connected && !p.demo && !c.loading)

	if c.mode == .Guided {
		dirty := printer_config_dirty_count(c)
		can_save := c.resolved && dirty > 0 && !c.uploading && !p.demo && p.client.state.connection == .Connected
		ui_add_control(ui, "config save", "Save modified values to printer.cfg", {panel.x+panel.w-142, y, 130, 28}, .Printer_Cfg_Save, can_save)
		ui_add_control(ui, "config revert", "Revert unsaved changes", {panel.x+panel.w-214, y, 66, 28}, .Printer_Cfg_Revert, dirty > 0)

		sub_y := y + 36
		sub_actions := [Printer_Config_Subsystem]UI_Action{
			.Build_Plate  = .Printer_Cfg_Sub_Build,
			.Bed_Mesh     = .Printer_Cfg_Sub_Mesh,
			.Toolhead     = .Printer_Cfg_Sub_Tool,
			.Board_Wiring = .Printer_Cfg_Sub_Board,
			.Heaters      = .Printer_Cfg_Sub_Heat,
		}
		sx := panel.x + 12
		for sub in Printer_Config_Subsystem {
			w := 86.0 if sub == .Build_Plate else 76.0
			ui_add_control(ui, PRINTER_SUBSYSTEM_NAMES[sub], PRINTER_SUBSYSTEM_NAMES[sub], {sx, sub_y, w, 26}, sub_actions[sub], true, 1, c.subsystem == sub)
			sx += w + 6
		}

		py := sub_y + 40
		field_w := min(220.0, max(120.0, panel.w*0.42))
		for def, i in PRINTER_CONFIG_PARAMS {
			if def.subsystem != c.subsystem {continue}
			if py + 34 > panel.y + panel.h - 36 {break}
			ui_add_control(ui, fmt.tprintf("cfg param %d", i), def.label, {panel.x+panel.w-field_w-16, py, field_w, 26}, printer_cfg_param_action(i))
			py += 38
		}
	} else {
		fy := y + 36
		search_w := min(280.0, max(120.0, panel.w - 280))
		ui_add_control(ui, "config search", "Filter sections, keys, or values", {panel.x+12, fy, search_w, 26}, .Printer_Cfg_Search)
		ui_add_control(ui, "config overridden", "Show overridden keys only", {panel.x+20+search_w, fy, 118, 26}, .Printer_Cfg_Overridden, true, 1, c.overridden_only)
		ui_add_control(ui, "config drift", "Show drifted keys only", {panel.x+144+search_w, fy, 88, 26}, .Printer_Cfg_Drift, true, 1, c.drift_only)

		list_w := max(260.0, panel.w*0.56 - 18)
		visible := printer_config_layered_visible(ui)
		c.layered_scroll = clamp(c.layered_scroll, 0, max(0, len(c.layered_rows) - visible))
		for row in 0..<visible {
			idx := c.layered_scroll + row
			if idx >= len(c.layered_rows) {break}
			ui_add_control(ui, fmt.tprintf("cfg row %d", row), "Select configuration key", {panel.x+12, fy+36+f64(row)*28, list_w, 24}, printer_cfg_row_action(row), true, 1, idx == c.selected_row)
		}
	}
}

ui_draw_printer_config :: proc(painter: ^UI_Painter, ui: ^UI_State, p: ^Printer_State) {
	theme := ui_theme(ui)
	c := &p.config
	panel := ui_printer_config_left_rect(ui)

	ui_draw_text(painter, painter.font, ui, "Guided", ui_control_rect(ui, .Printer_Cfg_Mode_Guided), ui_control_ink(ui, .Printer_Cfg_Mode_Guided), 0, .Center)
	ui_draw_text(painter, painter.font, ui, "Layered", ui_control_rect(ui, .Printer_Cfg_Mode_Layered), ui_control_ink(ui, .Printer_Cfg_Mode_Layered), 0, .Center)
	ui_draw_text(painter, painter.font, ui, "Refresh", ui_control_rect(ui, .Printer_Cfg_Refresh), ui_control_ink(ui, .Printer_Cfg_Refresh), 0, .Center)

	if c.mode == .Guided {
		dirty := printer_config_dirty_count(c)
		save_label := fmt.tprintf("Save printer.cfg (%d)", dirty) if dirty > 0 else "Save printer.cfg"
		ui_draw_text(painter, painter.font, ui, save_label, ui_control_rect(ui, .Printer_Cfg_Save), ui_control_ink(ui, .Printer_Cfg_Save), 0, .Center)
		ui_draw_text(painter, painter.font, ui, "Revert", ui_control_rect(ui, .Printer_Cfg_Revert), ui_control_ink(ui, .Printer_Cfg_Revert), 0, .Center)

		sub_actions := [Printer_Config_Subsystem]UI_Action{
			.Build_Plate  = .Printer_Cfg_Sub_Build,
			.Bed_Mesh     = .Printer_Cfg_Sub_Mesh,
			.Toolhead     = .Printer_Cfg_Sub_Tool,
			.Board_Wiring = .Printer_Cfg_Sub_Board,
			.Heaters      = .Printer_Cfg_Sub_Heat,
		}
		for sub in Printer_Config_Subsystem {
			ui_draw_text(painter, painter.font, ui, PRINTER_SUBSYSTEM_NAMES[sub], ui_control_rect(ui, sub_actions[sub]), ui_control_ink(ui, sub_actions[sub]), 0, .Center)
		}

		py := panel.y + 88
		field_w := min(220.0, max(120.0, panel.w*0.42))
		label_w := max(100.0, panel.w - field_w - 40)
		for def, i in PRINTER_CONFIG_PARAMS {
			if def.subsystem != c.subsystem {continue}
			if py + 34 > panel.y + panel.h - 36 {break}
			label := fmt.tprintf("%s (%s)", def.label, def.unit) if len(def.unit) > 0 else def.label
			if c.dirty[i] {label = fmt.tprintf("• %s", label)}
			ui_draw_text(painter, painter.font, ui, label, {panel.x+16, py, label_w, 26}, theme.accent if c.dirty[i] else theme.text, 0)
			printer_draw_text_field(painter, ui, printer_cfg_param_action(i), c.drafts[i], def.fallback)
			py += 38
		}
	} else {
		printer_draw_text_field(painter, ui, .Printer_Cfg_Search, c.search, "Search section, key, or value…")
		ui_draw_text(painter, painter.font, ui, "Overridden only", ui_control_rect(ui, .Printer_Cfg_Overridden), ui_control_ink(ui, .Printer_Cfg_Overridden), 0, .Center)
		ui_draw_text(painter, painter.font, ui, "Drift only", ui_control_rect(ui, .Printer_Cfg_Drift), ui_control_ink(ui, .Printer_Cfg_Drift), 0, .Center)

		list_w := max(260.0, panel.w*0.56 - 18)
		visible := printer_config_layered_visible(ui)
		for row in 0..<visible {
			idx := c.layered_scroll + row
			if idx >= len(c.layered_rows) {break}
			fr := c.layered_rows[idx]
			sec := c.resolution.sections[fr.section_idx]
			key := &c.resolution.sections[fr.section_idx].keys[fr.key_idx]
			final, _ := cfg.final_entry(key)
			r := ui_control_rect(ui, printer_cfg_row_action(row))
			selected := idx == c.selected_row
			if selected {
				ui_add_round_rect(painter, r, 5, theme.accent)
			} else if ui.hovered_id == u64(printer_cfg_row_action(row)) {
				ui_add_round_rect(painter, r, 5, theme.raised)
			}
			ink := theme.accent_ink if selected else theme.text
			muted := theme.accent_ink if selected else theme.muted
			prefix := "! " if fr.drifted else ""
			left_text := fmt.tprintf("%s[%s] %s", prefix, sec.name, key.name)
			ui_draw_text(painter, painter.mono, ui, left_text, {r.x+6, r.y, r.w*0.56, r.h}, ink, 0, tracked = true)
			val_flat, _ := strings.replace_all(final.value, "\n", " ", context.temp_allocator)
			ui_draw_text(painter, painter.mono, ui, val_flat, {r.x+r.w*0.58, r.y, r.w*0.40, r.h}, muted, 0, .End, tracked = true)
		}

		// Right provenance column.
		dx := panel.x + list_w + 24
		dw := max(180.0, panel.x + panel.w - dx - 12)
		ui_add_rect(painter, {dx-6, panel.y+84, 1, panel.h-116}, theme.border)
		if c.selected_row >= 0 && c.selected_row < len(c.layered_rows) {
			fr := c.layered_rows[c.selected_row]
			sec := c.resolution.sections[fr.section_idx]
			key := &c.resolution.sections[fr.section_idx].keys[fr.key_idx]
			final, _ := cfg.final_entry(key)
			dy := panel.y + 88
			ui_draw_text(painter, painter.mono, ui, fmt.tprintf("[%s] %s", sec.name, key.name), {dx+8, dy, dw-16, 22}, theme.text, 0, tracked = true)
			dy += 28
			ui_draw_text(painter, painter.font, ui, "Include provenance", {dx+8, dy, dw-16, 20}, theme.muted, 0)
			dy += 24
			for entry in key.entries {
				if dy + 42 > panel.y + panel.h - 36 {break}
				layer := c.resolution.layers[entry.layer]
				lname := fmt.tprintf("%s (SAVE_CONFIG)", layer.path) if layer.kind == .Save_Config else layer.path
				is_win := entry.layer == final.layer && entry.line == final.line
				tag := "ACTIVE" if is_win else ("ignored" if entry.ignored else "shadowed")
				ui_draw_text(painter, painter.mono, ui, fmt.tprintf("%s:%d  [%s]", lname, entry.line, tag), {dx+8, dy, dw-16, 18}, theme.accent if is_win else theme.muted, 0, tracked = true)
				val_flat, _ := strings.replace_all(entry.value, "\n", " | ", context.temp_allocator)
				ui_draw_text(painter, painter.mono, ui, val_flat, {dx+16, dy+18, dw-24, 18}, theme.text if is_win else theme.muted, 0, tracked = true)
				dy += 42
			}
		} else if !c.resolved {
			ui_draw_text(painter, painter.font, ui, "Click Refresh while connected to load Klipper configuration layers.", {dx+8, panel.y+88, dw-16, 24}, theme.muted, 0)
		}
	}

	if len(c.status) > 0 {
		ui_draw_text(painter, painter.font, ui, c.status, {panel.x+14, panel.y+panel.h-28, panel.w-28, 22}, ui_error_color(ui) if c.status_failed else theme.muted, 0)
	}
}
