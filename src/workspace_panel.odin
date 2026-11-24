package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import devlog "devlog:."

import formats "./formats"
import pipeline "./pipeline"

// ponytail: dev-only absolute profile directory; use resource_root when packaging.
DEV_PROFILE_DIRECTORY :: "/Users/martin/projects/hw_slicer/resources/profiles"
WORKSPACE_PRINTER :: "vcore3"
WORKSPACE_MATERIAL :: "pla"
WORKSPACE_PROCESS :: "0.20-standard"

// Opens the slicing workspace on the model file that was just loaded. The model is sliced as it
// is on disk; the lay-on-face placement of the viewer does not reach the slice yet.
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
	config.source_units = units
	workspace, create_detail, create_ok := pipeline.workspace_create(config, mesh)
	if !create_ok {
		devlog.failed(devlog.global(), site, {reason = "workspace could not be created", detail = create_detail, severity = .Warning})
		return
	}
	app.workspace = workspace
	app.ui.workspace.active = true
	app.ui.workspace.auto_run = true
	app_workspace_refresh()
	devlog.succeeded(devlog.global(), site, {scope = "workspace", stage = "open"})
}

app_workspace_close :: proc() {
	if app.workspace == nil {return}
	pipeline.workspace_destroy(app.workspace)
	app.workspace = nil
	app.ui.workspace.active = false
	app_workspace_clear_rows()
	delete(app.ui.workspace.failure)
	app.ui.workspace.failure = ""
	app.ui.workspace.scroll = 0
	app.ui.stage_index = 0
}

@(private = "file")
app_workspace_clear_rows :: proc() {
	for row in app.ui.workspace.rows {
		delete(row.value)
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
	ui.view = pipeline.workspace_view(w)
	ui.auto_run = !w.manual_only
	app.ui.stage_index = int(ui.view.selected)
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
	for setting, index in pipeline.workspace_settings(w, ui.view.selected) {
		row := UI_Setting_Row{
			key = setting.descriptor.key,
			label = setting.descriptor.label,
			unit = setting.descriptor.unit,
			value = strings.clone(setting.value),
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
	app.needs_redraw = true
}

// Once per frame: joins a finished run, then refreshes the interface while anything is running.
app_workspace_poll :: proc() {
	w := app.workspace
	if w == nil {return}
	changed := pipeline.workspace_poll(w)
	if changed || pipeline.workspace_running(w) {
		app_workspace_refresh()
		ui_build_controls(&app.ui)
	}
}

// Handles the workspace actions. Returns false for an action that is not one of them.
app_workspace_activate :: proc(action: UI_Action) -> bool {
	w := app.workspace
	if w == nil {return false}
	ui := &app.ui.workspace
	if row_index, side, is_setting := ui_setting_action_index(action, len(ui.rows)); is_setting {
		app_workspace_edit_row(ui.rows[row_index], side)
		app_workspace_refresh()
		ui_build_controls(&app.ui)
		return true
	}
	#partial switch action {
	case .Previous_Stage:
		_ = pipeline.workspace_previous(w)
	case .Next_Stage:
		_ = pipeline.workspace_next(w)
	case .Workspace_Run:
		if pipeline.workspace_running(w) {
			pipeline.workspace_cancel(w)
		} else {
			_ = pipeline.workspace_run_selected(w)
		}
	case .Workspace_Auto:
		pipeline.workspace_set_auto_run(w, w.manual_only)
	case:
		return false
	}
	ui.scroll = 0
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

app_workspace_scroll :: proc(delta_y: f64) -> bool {
	ui := &app.ui.workspace
	if !ui.active || app.ui.stage_index == 0 || delta_y == 0 {return false}
	left := ui_left_rect(&app.ui)
	if !ui_contains(left, app.ui.pointer_x, app.ui.pointer_y) {return false}
	_, visible := ui_workspace_settings_area(&app.ui)
	ui.scroll = clamp(ui.scroll+(-1 if delta_y > 0 else 1), 0, max(0, len(ui.rows)-visible))
	ui_build_controls(&app.ui)
	app.needs_redraw = true
	return true
}

// Development launch: `--stage=N` opens the workspace on group N instead of the newest design.
// `--stage-run` runs that group before the first frame, and each `--stage-set=key=value` edits a
// setting afterwards (with the runs finished), so a capture shows the resulting stale state.
app_workspace_startup :: proc() {
	w := app.workspace
	pipeline.workspace_select(w, pipeline.Stage_Group(clamp(startup_stage, 0, len(pipeline.Stage_Group)-1)))
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
	app_workspace_refresh()
	ui_build_controls(&app.ui)
}
