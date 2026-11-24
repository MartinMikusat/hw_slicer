package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"
import devlog "devlog:."

import contracts "./contracts"
import formats "./formats"
import pipeline "./pipeline"

// ponytail: dev-only absolute profile directory; use resource_root when packaging.
DEV_PROFILE_DIRECTORY :: "/Users/martin/projects/hw_slicer/resources/profiles"
WORKSPACE_PRINTER :: "vcore3"
WORKSPACE_MATERIAL :: "pla"
WORKSPACE_PROCESS :: "0.20-standard"

@(private = "file")
placement_rotation_is_identity :: proc(m: Mat4) -> bool {
	return m[0] == 1 && m[1] == 0 && m[2] == 0 &&
	       m[4] == 0 && m[5] == 1 && m[6] == 0 &&
	       m[8] == 0 && m[9] == 0 && m[10] == 1
}

// Opens the slicing workspace on the model file that was just loaded, applying the viewer's
// lay-on-face rotation when non-identity so the slice matches the placed orientation.
app_workspace_open :: proc(path: string) {
	site := devlog.Site{feature = "workspace", operation = "open"}
	app_workspace_close()
	bytes, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {
		devlog.failed(devlog.global(), site, {reason = "model file could not be read", severity = .Warning})
		return
	}
	defer delete(bytes)
	config, detail, config_ok := pipeline.slice_configuration_load(
		fmt.tprintf("%s/printers/%s.json", DEV_PROFILE_DIRECTORY, WORKSPACE_PRINTER),
		fmt.tprintf("%s/materials/%s.json", DEV_PROFILE_DIRECTORY, WORKSPACE_MATERIAL),
		fmt.tprintf("%s/processes/%s.json", DEV_PROFILE_DIRECTORY, WORKSPACE_PROCESS),
	)
	if !config_ok {
		devlog.failed(devlog.global(), site, {reason = "profiles could not be loaded", detail = detail, severity = .Warning})
		return
	}
	mesh, units, decode_error := pipeline.decode_mesh_bytes(bytes, path)
	if len(decode_error.stage) > 0 {
		devlog.failed(devlog.global(), site, {reason = "model could not be decoded", detail = decode_error.detail, severity = .Warning})
		return
	}
	defer formats.decoded_mesh_destroy(&mesh)
	m := app.placement.transform
	if !placement_rotation_is_identity(m) {
		for vi in 0..<len(mesh.vertex_x) {
			x := mesh.vertex_x[vi]
			y := mesh.vertex_y[vi]
			z := mesh.vertex_z[vi]
			mesh.vertex_x[vi] = f64(m[0])*x + f64(m[4])*y + f64(m[8])*z
			mesh.vertex_y[vi] = f64(m[1])*x + f64(m[5])*y + f64(m[9])*z
			mesh.vertex_z[vi] = f64(m[2])*x + f64(m[6])*y + f64(m[10])*z
		}
	}
	config.source_units = units
	config.object_name = strings.trim_suffix(filepath.base(path), filepath.ext(path))
	workspace, create_detail, create_ok := pipeline.workspace_create(config, mesh)
	if !create_ok {
		devlog.failed(devlog.global(), site, {reason = "workspace could not be created", detail = create_detail, severity = .Warning})
		return
	}
	app.workspace = workspace
	delete(app.workspace_path)
	app.workspace_path = strings.clone(path)
	app.workspace_exported_hash = {}
	app.ui.workspace.active = true
	app.ui.workspace.auto_run = true
	graph := &app.ui.workspace.graph
	graph^ = {show_mesh = true, show_result = true, zoom = 1, inspector_open = true}
	workspace_clock_origin = time.tick_now()
	app_workspace_refresh()
	devlog.succeeded(devlog.global(), site, {scope = "workspace", stage = "open"})
}

app_workspace_close :: proc() {
	if app.workspace == nil {return}
	pipeline.gcode_preview_destroy(&app.gcode_preview)
	clear(&app.gcode_colored_beads)
	app.gcode_colored_hash = {}
	pipeline.workspace_destroy(app.workspace)
	app.workspace = nil
	app.ui.workspace.active = false
	app_workspace_clear_rows()
	delete(app.ui.workspace.failure)
	app.ui.workspace.failure = ""
	app.ui.workspace.scroll = 0
}

@(private = "file")
workspace_clock_origin: time.Tick

@(private = "file")
app_workspace_clear_rows :: proc() {
	for row in app.ui.workspace.rows {
		delete(row.value)
		delete(row.default_value)
		delete(row.names[0])
		delete(row.names[1])
		delete(row.labels[0])
		delete(row.labels[1])
	}
	clear(&app.ui.workspace.rows)
}

// Copies the controller state into the interface state. Called after every action and on every
// frame while a run is active.
app_workspace_refresh :: proc() {
	w := app.workspace
	if w == nil {return}
	ui := &app.ui.workspace
	graph := &ui.graph
	ui.view = pipeline.workspace_view(w)
	ui.auto_run = !w.manual_only
	ui.logs = w.logs
	graph.clock = time.duration_seconds(time.tick_since(workspace_clock_origin))
	graph.changed = {}
	graph.can_run_only = {}
	for id in pipeline.Stage_Id {
		if pipeline.workspace_can_run_only(w, id) {graph.can_run_only += {id}}
	}
	for d in pipeline.setting_descriptors {
		if pipeline.slice_configuration_value(w.config, d.key) != pipeline.slice_configuration_value(w.defaults, d.key) {
			graph.changed += {d.owner}
		}
	}
	graph.evidence = {}
	for stage in app.evidence_replay.root.stages {graph.evidence += evidence_stage_nodes(stage.stage.name)}
	delete(ui.failure)
	ui.failure = ""
	for id in pipeline.Stage_Id {
		failure := ui.view.stages[id].failure
		if len(failure.stage) > 0 && len(ui.failure) == 0 {
			ui.failure = strings.clone(fmt.tprintf("Failed in %s: %s", failure.stage, failure.detail))
		}
		ui.view.stages[id].failure = {}
	}
	app_workspace_clear_rows()
	graph.hidden_advanced = 0
	for setting in pipeline.workspace_settings(w, ui.view.selected) {
		if setting.descriptor.advanced && !graph.advanced {
			graph.hidden_advanced += 1
			continue
		}
		index := len(ui.rows)
		row := UI_Setting_Row{
			key = setting.descriptor.key,
			label = setting.descriptor.label,
			unit = setting.descriptor.unit,
			value = strings.clone(setting.value),
			default_value = strings.clone(setting.default_value),
			changed = setting.value != setting.default_value,
			kind = setting.descriptor.kind,
			editable = setting.editable,
			owner = setting.owner_name,
		}
		if setting.editable {
			if setting.descriptor.kind == .Toggle {
				row.names[1] = strings.clone(fmt.tprintf("setting %d toggle", index))
				row.labels[1] = strings.clone(fmt.tprintf("toggle %s", setting.descriptor.label))
			} else {
				row.names[0] = strings.clone(fmt.tprintf("setting %d decrease", index))
				row.names[1] = strings.clone(fmt.tprintf("setting %d increase", index))
				row.labels[0] = strings.clone(fmt.tprintf("decrease %s", setting.descriptor.label))
				row.labels[1] = strings.clone(fmt.tprintf("increase %s", setting.descriptor.label))
			}
		}
		append(&ui.rows, row)
	}
	app_sync_gcode_preview()
	app.section_dirty = true
	app.needs_redraw = true
}

@(private = "file")
app_sync_gcode_preview :: proc() {
	w := app.workspace
	graph := &app.ui.workspace.graph
	sel := app.ui.workspace.view.selected
	if w == nil || (sel != .Motion && sel != .Gcode) || !pipeline.workspace_stage_readable(w, .Motion) {
		graph.gcode_preview_ready = false
		return
	}
	motion_hash := w.session.slots[.Motion].built_hash
	if motion_hash != app.gcode_preview.built_hash {
		pipeline.gcode_preview_destroy(&app.gcode_preview)
		if built, ok := pipeline.workspace_build_gcode_preview(w, context.allocator); ok {
			app.gcode_preview = built
		}
	}
	if len(app.gcode_preview.beads) == 0 {
		graph.gcode_preview_ready = false
		return
	}
	graph.gcode_preview_ready = true
	mode := graph.gcode_mode
	min_v := app.gcode_preview.mode_min[mode]
	max_v := app.gcode_preview.mode_max[mode]
	graph.gcode_min = min_v
	graph.gcode_max = max_v
	if app.gcode_colored_hash != app.gcode_preview.built_hash ||
	   app.gcode_colored_mode != mode ||
	   len(app.gcode_colored_beads) != len(app.gcode_preview.beads) {
		clear(&app.gcode_colored_beads)
		reserve(&app.gcode_colored_beads, len(app.gcode_preview.beads))
		for bd in app.gcode_preview.beads {
			col := pipeline.gcode_preview_bead_color(bd, mode, min_v, max_v)
			append(&app.gcode_colored_beads, Gpu_Colored_Bead{
				a = Vec4{bd.a[0], bd.a[1], bd.a[2], bd.width_mm},
				b = Vec4{bd.b[0], bd.b[1], bd.b[2], bd.height_mm},
				color = Vec4{col[0], col[1], col[2], col[3]},
			})
		}
		_ = renderer_set_colored_beads(&app.renderer, app.gcode_colored_beads[:])
		app.gcode_colored_hash = app.gcode_preview.built_hash
		app.gcode_colored_mode = mode
	}
}

// Once per frame: joins a finished run, exports completed G-code to build/gcode/, and refreshes.
app_workspace_poll :: proc() {
	w := app.workspace
	if w == nil {return}
	changed := pipeline.workspace_poll(w)
	if changed || pipeline.workspace_running(w) {
		app_workspace_refresh()
		ui_build_controls(&app.ui)
	}
	if !pipeline.workspace_running(w) && app.ui.workspace.view.stages[.Gcode].state == .Complete {
		app_workspace_maybe_export_gcode()
	}
}

@(private = "file")
app_workspace_maybe_export_gcode :: proc() {
	w := app.workspace
	if w == nil || len(app.workspace_path) == 0 {return}
	built_hash := w.session.slots[.Gcode].built_hash
	if built_hash == app.workspace_exported_hash {return}
	gcode_bytes, ok := pipeline.workspace_gcode_bytes(w, context.allocator)
	if !ok {return}
	defer delete(gcode_bytes)
	stem := strings.trim_suffix(filepath.base(app.workspace_path), filepath.ext(app.workspace_path))
	out_dir := "build/gcode"
	_ = os.make_directory_all(out_dir)
	out_path := fmt.tprintf("%s/%s.gcode", out_dir, stem)
	if os.write_entire_file(out_path, gcode_bytes) == nil {
		app.workspace_exported_hash = built_hash
		app_set_status(fmt.tprintf("EXPORTED %s (%d bytes)", out_path, len(gcode_bytes)))
	}
}

// Handles the workspace actions. Returns false for an action that is not one of them.
app_workspace_activate :: proc(action: UI_Action) -> bool {
	w := app.workspace
	if w == nil {return false}
	ui := &app.ui.workspace
	graph := &ui.graph
	if row_index, side, is_setting := ui_setting_action_index(action, len(ui.rows)); is_setting {
		app_workspace_edit_row(ui.rows[row_index], side)
		app_workspace_refresh()
		ui_build_controls(&app.ui)
		return true
	}
	if id, is_node := ui_graph_node_action_index(action); is_node {
		pipeline.workspace_select(w, id)
		ui.scroll = 0
		app_workspace_refresh()
		ui_build_controls(&app.ui)
		return true
	}
	menu_stage := graph.menu_stage
	#partial switch action {
	case .Workspace_Run:
		if pipeline.workspace_running(w) {
			pipeline.workspace_cancel(w)
		} else {
			_ = pipeline.workspace_run_selected(w)
		}
	case .Workspace_Auto:
		pipeline.workspace_set_auto_run(w, w.manual_only)
	case .Graph_Fit:
		ui_graph_fit(&app.ui)
	case .Graph_Inspector_Toggle:
		graph.inspector_open = !graph.inspector_open
	case .Graph_Divider, .Graph_Minimap, .Graph_Inspector_Surface, .Graph_Menu_Surface:
	case .Graph_Menu_Run_To:
		graph.menu_open = false
		_ = pipeline.workspace_run_to(w, menu_stage)
	case .Graph_Menu_Run_Only:
		graph.menu_open = false
		if !pipeline.workspace_run_only(w, menu_stage) {app_set_status("Run only needs current results of every input.", true)}
	case .Graph_Menu_Reset:
		graph.menu_open = false
		if detail, ok := pipeline.workspace_reset_stage(w, menu_stage); !ok {
			app_set_status(detail, true)
		} else {
			app_set_status(fmt.tprintf("%s: settings reset", pipeline.stage_descriptors[menu_stage].name))
		}
	case .Graph_Menu_Evidence:
		graph.menu_open = false
		app_workspace_open_evidence(menu_stage)
	case .Graph_Menu_Copy:
		graph.menu_open = false
		settings := pipeline.workspace_settings_text(w, menu_stage)
		if app_copy_text(settings) {
			app_set_status(fmt.tprintf("%s settings copied", pipeline.stage_descriptors[menu_stage].name))
		} else {
			app_set_status("The clipboard is not available.", true)
		}
	case .Attribute_Settings, .Attribute_Log, .Attribute_Docs:
		graph.tab = .Settings if action == .Attribute_Settings else (.Log if action == .Attribute_Log else .Docs)
		ui.scroll = 0
	case .Attribute_Advanced:
		graph.advanced = !graph.advanced
		ui.scroll = 0
	case .View_Mesh:
		graph.show_mesh = !graph.show_mesh
	case .View_Result:
		graph.show_result = !graph.show_result
	case .View_GCode_Prev:
		count := len(pipeline.GCode_View_Mode)
		graph.gcode_mode = pipeline.GCode_View_Mode((int(graph.gcode_mode) + count - 1) % count)
	case .View_GCode_Next:
		count := len(pipeline.GCode_View_Mode)
		graph.gcode_mode = pipeline.GCode_View_Mode((int(graph.gcode_mode) + 1) % count)
	case .View_GCode_Single_Layer:
		graph.gcode_single_layer = !graph.gcode_single_layer
	case:
		return false
	}
	app_workspace_refresh()
	ui_build_controls(&app.ui)
	return true
}

@(private = "file")
app_workspace_edit_row :: proc(row: UI_Setting_Row, side: int) {
	w := app.workspace
	next: string
	switch row.kind {
	case .Toggle:
		next = "false" if row.value == "true" else "true"
	case .Choice:
		for descriptor in pipeline.setting_descriptors {
			if descriptor.key != row.key {continue}
			current := 0
			for choice, index in descriptor.choices {
				if choice == row.value {current = index}
			}
			count := len(descriptor.choices)
			next = descriptor.choices[(current+(1 if side == 1 else count-1))%count]
		}
	case .Number:
		value, ok := strconv.parse_f64(row.value)
		if !ok {return}
		step := 1.0
		for descriptor in pipeline.setting_descriptors {
			if descriptor.key == row.key {step = descriptor.step}
		}
		value += step if side == 1 else -step
		value = math.round(value*10_000)/10_000
		next = fmt.tprintf("%v", value)
	}
	if detail, ok := pipeline.workspace_edit(w, row.key, next); !ok {
		app_set_status(detail, true)
	} else {
		app_set_status(fmt.tprintf("%s: %s", row.label, next))
	}
}

// Opens the evidence view on the first record of the loaded bundle that belongs to the stage.
@(private = "file")
app_workspace_open_evidence :: proc(id: pipeline.Stage_Id) {
	for stage, index in app.evidence_replay.root.stages {
		if id not_in evidence_stage_nodes(stage.stage.name) {continue}
		app.ui.evidence_open = true
		app.ui.evidence_stage_index = index
		app.ui.evidence_detail_scroll = 0
		app.ui.evidence_scroll = max(0, index-ui_evidence_visible_stages(&app.ui)+1)
		if ui_evidence_compact(&app.ui) {app.ui.evidence_pane = .Details}
		app.needs_redraw = true
		return
	}
	app_set_status("The loaded evidence has no record for this stage.", true)
}

// The workspace stages that an evidence-bundle stage records. Bundle stages group the work
// differently from the workspace, so one record can belong to several stages, and some records
// (profile resolution) belong to none.
evidence_stage_nodes :: proc(name: string) -> pipeline.Stage_Set {
	switch name {
	case "decode", "normalize":                return {.Model}
	case "schedule-layers":                     return {.Layer_Schedule}
	case "build-acceleration", "intersect":     return {.Intersections}
	case "reconstruct-topology":                return {.Topology}
	case "calculate-regions":                   return {.Regions}
	case "generate-features":
		return {.Surfaces_Skin, .Perimeters, .Bridges, .Solid_Areas, .Solid_Paths, .Sparse_Infill, .Gap_Fill, .Supports}
	case "plan-paths":                          return {.Path_Plan, .Motion}
	case "emit-gcode":                          return {.Gcode}
	}
	return {}
}

// A short note naming the workspace stage of an evidence-bundle stage, for the evidence list.
evidence_stage_node_names :: proc(name: string) -> string {
	nodes := evidence_stage_nodes(name)
	count := card(nodes)
	if count == 0 {return "(no stage)"}
	for id in pipeline.Stage_Id {
		if id not_in nodes {continue}
		if count == 1 {return fmt.tprintf("→ %s", pipeline.stage_descriptors[id].name)}
		return fmt.tprintf("→ %s +%d", pipeline.stage_descriptors[id].name, count-1)
	}
	return ""
}

// Puts plain text on the general pasteboard.
app_copy_text :: proc(value: string) -> bool {
	pasteboard_class := objc_getClass("NSPasteboard")
	if pasteboard_class == nil {return false}
	pasteboard := msg_id(pasteboard_class, sel_registerName("generalPasteboard"))
	if pasteboard == nil {return false}
	ns_text := ui_cf_string(value)
	if ns_text == nil {return false}
	defer CFRelease(ns_text)
	ns_type := ui_cf_string("public.utf8-plain-text")
	defer CFRelease(ns_type)
	_ = msg_id(pasteboard, sel_registerName("clearContents"))
	set_string := transmute(proc "c" (Id, Sel, Id, Id) -> bool)objc_send_address
	return set_string(pasteboard, sel_registerName("setString:forType:"), ns_text, ns_type)
}

// Scrolls the settings of the attribute editor when the pointer is over it.
app_workspace_scroll :: proc(delta_y: f64) -> bool {
	ui := &app.ui.workspace
	if !ui_graph_mode(&app.ui) || !ui.graph.inspector_open || delta_y == 0 {return false}
	if !ui_contains(ui_attribute_rect(&app.ui), app.ui.pointer_x, app.ui.pointer_y) {return false}
	_, visible := ui_attribute_rows_area(&app.ui)
	ui.scroll = clamp(ui.scroll+(-1 if delta_y > 0 else 1), 0, max(0, len(ui.rows)-visible))
	ui_build_controls(&app.ui)
	app.needs_redraw = true
	return true
}

// Graph pointer handling that the generic control path does not cover: panning the canvas, the
// divider and the overview, the context menu, and resetting a setting with a right-click.
// Returns true when the event was used here.
app_graph_mouse :: proc(phase, button: i32, x, y, delta_x, delta_y: f64) -> bool {
	ui := &app.ui
	if !ui_graph_mode(ui) || ui.settings_open || ui.help_open || ui.evidence_open {return false}
	graph := &ui.workspace.graph
	switch phase {
	case 0:
		id := ui_hit_test(ui, x, y)
		if graph.menu_open {
			if id == u64(UI_Action.Graph_Menu_Surface) {return true}
			for item in GRAPH_MENU_ITEMS {
				if id == u64(item.action) {return false}
			}
			graph.menu_open = false
			ui_build_controls(ui)
			app.needs_redraw = true
			return true
		}
		if button == 1 {
			if stage, is_node := ui_graph_node_action_index(UI_Action(id)); is_node {
				graph.menu_open = true
				graph.menu_stage = stage
				graph.menu_at = {x, y}
				ui_build_controls(ui)
				app.needs_redraw = true
				return true
			}
			if row, is_row := ui_attribute_row_at(ui, x, y); is_row && ui.workspace.rows[row].editable {
				key := ui.workspace.rows[row].key
				label := ui.workspace.rows[row].label
				if detail, ok := pipeline.workspace_reset_setting(app.workspace, key); !ok {
					app_set_status(detail, true)
				} else {
					app_set_status(fmt.tprintf("%s reset", label))
				}
				app_workspace_refresh()
				ui_build_controls(ui)
				return true
			}
			return false
		}
		if id == u64(UI_Action.Graph_Divider) {
			graph.split_dragging = true
			app.needs_redraw = true
			return true
		}
		if id == u64(UI_Action.Graph_Minimap) {
			graph.minimap_dragging = true
			ui_graph_minimap_move(ui, x, y)
			ui_build_controls(ui)
			app.needs_redraw = true
			return true
		}
		_, on_node := ui_graph_node_action_index(UI_Action(id))
		if ui_contains(ui_graph_rect(ui), x, y) && (id == 0 || (on_node && button == 2)) {
			graph.panning = true
			return true
		}
	case 1:
		switch {
		case graph.panning:
			scale := ui.ui_scale if ui.ui_scale > 0 else 1
			ui_graph_pan_by(ui, delta_x/scale, delta_y/scale)
		case graph.split_dragging:
			ui_graph_set_split(ui, x)
		case graph.minimap_dragging:
			ui_graph_minimap_move(ui, x, y)
		case:
			return false
		}
		ui_build_controls(ui)
		app.needs_redraw = true
		return true
	case 2:
		if graph.panning || graph.split_dragging || graph.minimap_dragging {
			graph.panning = false
			graph.split_dragging = false
			graph.minimap_dragging = false
			ui.pressed_id = 0
			ui_build_controls(ui)
			app.needs_redraw = true
			return true
		}
	case 3:
		from, to, found := ui_graph_edge_at(ui, x, y)
		if ui_hit_test(ui, x, y) != 0 {found = false}
		if found != graph.hover_edge || (found && (from != graph.hover_from || to != graph.hover_to)) {
			graph.hover_edge = found
			graph.hover_from = from
			graph.hover_to = to
			app.needs_redraw = true
		}
		if found || graph.hover_edge {app.needs_redraw = true}
	}
	return false
}

// Zooms the graph with the scroll wheel while the pointer is over it.
app_graph_scroll :: proc(delta_y: f64) -> bool {
	ui := &app.ui
	if !ui_graph_mode(ui) || delta_y == 0 {return false}
	if !ui_contains(ui_graph_rect(ui), ui.pointer_x, ui.pointer_y) {return false}
	ui_graph_zoom_at(ui, ui.pointer_x, ui.pointer_y, math.exp(delta_y*0.01))
	ui.workspace.graph.menu_open = false
	ui_build_controls(ui)
	app.needs_redraw = true
	return true
}

// Graph keys: f fits the graph, the arrow keys move the selection along edges, Escape closes the
// stage menu.
app_graph_key :: proc(key_code: u16, characters: string) -> bool {
	ui := &app.ui
	if !ui_graph_mode(ui) || ui.settings_open || ui.help_open || ui.evidence_open || ui.lay_on_face {return false}
	graph := &ui.workspace.graph
	if key_code == 53 && graph.menu_open {
		graph.menu_open = false
		ui_build_controls(ui)
		app.needs_redraw = true
		return true
	}
	if characters == "f" {
		ui_graph_fit(ui)
		ui_build_controls(ui)
		app.needs_redraw = true
		return true
	}
	if key_code >= 123 && key_code <= 126 {
		selected := ui.workspace.view.selected
		next := ui_graph_neighbour(selected, key_code)
		if next != selected {
			pipeline.workspace_select(app.workspace, next)
			ui.workspace.scroll = 0
			app_workspace_refresh()
			ui_build_controls(ui)
		}
		return true
	}
	return false
}

// Development launch: `--stage=N` opens the workspace on stage N instead of the newest design.
// `--stage-run` runs every stage before the first frame, and each `--stage-set=key=value` edits a
// setting afterwards (with the runs finished), so a capture shows the resulting stale state.
app_workspace_startup :: proc() {
	w := app.workspace
	pipeline.workspace_select(w, pipeline.Stage_Id(clamp(startup_stage, 0, len(pipeline.Stage_Id)-1)))
	if startup_stage_run {
		pipeline.workspace_set_auto_run(w, false)
		_ = pipeline.workspace_run_to(w, .Gcode)
		pipeline.workspace_wait(w)
	}
	for edit in startup_stage_edits {
		if detail, ok := pipeline.workspace_edit(w, edit[0], edit[1]); !ok {
			app_set_status(detail, true)
		}
	}
	pipeline.workspace_wait(w)
	if startup_gcode_view >= 0 {
		app.ui.workspace.graph.gcode_mode = pipeline.GCode_View_Mode(clamp(startup_gcode_view, 0, len(pipeline.GCode_View_Mode)-1))
	}
	app_workspace_refresh()
	ui_build_controls(&app.ui)
}

// Switches between the top-level workspace tabs. The loaded design stays in memory while another
// tab is shown, so switching back is immediate.
app_set_demo_tab :: proc(tab: App_Tab) {
	app.ui.active_tab = tab
	app.ui.focused_id = 0
	printer_blur_field(&app.printer)
	switch tab {
	case .Slicer:
		app.design.active = false
		// A loaded design replaces the model mesh; bring back the model the workspace slices.
		if len(app.mesh.vertices) == 0 && app.workspace != nil {
			_ = app_load_model(app.workspace_model, true, false)
		}
		app_workspace_refresh()
	case .Printer:
		app.design.active = false
		app.ui.lay_on_face = false
		app.section_dirty = true
		app.needs_redraw = true
	case .Design:
		// The viewer holds the model mesh after the slicer tab, so the design is loaded again: the
		// pinned or last design when there is one, otherwise the newest.
		if len(app.design.layers) == 0 || len(app.mesh.vertices) > 0 {
			path := strings.clone(app.design.path, context.temp_allocator)
			if len(path) == 0 || !app.design.pinned {
				if newest, found := design_newest(); found {path = newest}
			}
			if len(path) > 0 {_ = app_load_design(path, true)}
		}
		app.design.active = len(app.design.layers) > 0
	}
	app.section_dirty = true
	ui_build_controls(&app.ui)
	app.needs_redraw = true
}
