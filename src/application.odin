package main

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import flash "flash:."

import evidence "./evidence"

Camera :: struct {
	target:   Vec3,
	yaw:      f32,
	pitch:    f32,
	distance: f32,
}

App_State :: struct {
	host:          Host_Services,
	renderer:      Renderer,
	ui:            UI_State,
	mesh:          Mesh,
	evidence_replay: evidence.Evidence_Bundle_Replay,
	evidence_kind: evidence.Evidence_Bundle_Source_Kind,
	camera:        Camera,
	resource_root: string,
	external_path: string,
	evidence_path: string,
	model_name:    string,
	status:        string,
	needs_redraw:  bool,
	dragging:      bool,
	drag_button:   i32,
	last_width:    f64,
	last_height:   f64,
	last_scale:    f64,
}

app: App_State

app_set_status :: proc(text: string) {
	delete(app.status)
	app.status = strings.clone(text)
	app.needs_redraw = true
}

app_frame_camera :: proc() {
	if app.mesh.triangle_count == 0 {return}
	size := mesh_size(app.mesh.bounds)
	app.camera.target = {0, 0, size.z*0.5}
	app.camera.yaw = 0.82
	app.camera.pitch = 0.62
	app.camera.distance = max(max(size.x, size.y), size.z)*2.25
	app.camera.distance = max(app.camera.distance, 4)
	app.needs_redraw = true
}

app_model_path :: proc(index: int) -> (string, string) {
	switch index {
	case 0:
		return filepath.join(
			{app.resource_root, "Models", "benchy.stl"},
		), "3DBenchy"
	case 1:
		return filepath.join(
			{app.resource_root, "Models", "all-in-one-test.stl"},
		), "All In One 3D Printer Test"
	case 2:
		return filepath.join(
			{app.resource_root, "Models", "stanford-bunny.stl"},
		), "Stanford Bunny"
	case:
		return app.external_path, filepath.base(app.external_path)
	}
}

app_load_model :: proc(index: int, frame_camera := true) -> bool {
	path, name := app_model_path(index)
	path_is_owned := index >= 0 && index < 3
	defer {
		if path_is_owned {delete(path)}
	}
	next, error := mesh_load_stl(path)
	if error != .None {
		fmt.eprintf(
			"HW Slicer could not load %s: %s\n",
			path,
			mesh_error_text(error),
		)
		app_set_status(fmt.tprintf("LOAD FAILED: %s", mesh_error_text(error)))
		return false
	}
	if !renderer_set_mesh(&app.renderer, &next) {
		mesh_destroy(&next)
		app_set_status("LOAD FAILED: METAL BUFFER")
		return false
	}
	mesh_destroy(&app.mesh)
	app.mesh = next
	app.ui.selected_model = index
	delete(app.model_name)
	app.model_name = strings.clone(name)
	app_set_status(fmt.tprintf("LOADED %d TRIANGLES", app.mesh.triangle_count))
	if frame_camera {app_frame_camera()}
	return true
}

app_evidence_view :: proc() -> UI_Evidence_View {
	container := "PACKAGE"
	if app.evidence_kind == .Directory {
		container = "DIRECTORY"
	}
	return {
		replay = &app.evidence_replay,
		source = app.evidence_path,
		container = container,
	}
}

app_load_evidence :: proc(path: string) -> bool {
	next, kind, load_error := evidence.evidence_bundle_path_replay(path)
	if load_error != .None {
		fmt.eprintf(
			"HW Slicer could not load evidence %s: %v\n",
			path,
			load_error,
		)
		app_set_status(fmt.tprintf("EVIDENCE FAILED: %v", load_error))
		return false
	}
	evidence.evidence_bundle_replay_destroy(&app.evidence_replay)
	app.evidence_replay = next
	app.evidence_kind = kind
	delete(app.evidence_path)
	app.evidence_path = strings.clone(path)
	app.ui.help_open = false
	app.ui.evidence_open = true
	app.ui.evidence_stage_index = 0
	app_set_status(
		fmt.tprintf(
			"EVIDENCE: %d STAGES",
			len(app.evidence_replay.root.stages),
		),
	)
	return true
}

app_open_document :: proc() {
	path: [4096]u8
	if app.host.open_document == nil ||
	   !app.host.open_document(raw_data(path[:]), len(path)) {
		return
	}
	selected := string(cstring(&path[0]))
	if !strings.equal_fold(filepath.ext(selected), ".stl") {
		_ = app_load_evidence(selected)
		return
	}
	delete(app.external_path)
	app.external_path = strings.clone(selected)
	_ = app_load_model(3)
}

app_activate :: proc(action: UI_Action) -> bool {
	if stage_index, is_stage := ui_evidence_stage_action_index(
		action,
		len(app.evidence_replay.root.stages),
	); is_stage {
		if !app.ui.evidence_open {return false}
		app.ui.evidence_stage_index = stage_index
		app.needs_redraw = true
		return true
	}
	switch action {
	case .Window_Close:
		app.host.window_close()
	case .Window_Minimize:
		app.host.window_minimize()
	case .Window_Zoom:
		app.host.window_zoom()
	case .Toggle_Theme:
		app.ui.dark = !app.ui.dark
		app.host.preference_set_int(
			"theme-dark",
			1 if app.ui.dark else 0,
		)
		app.needs_redraw = true
	case .Show_Help:
		app.ui.evidence_open = false
		app.ui.help_open = true
		app.needs_redraw = true
	case .Close_Help:
		app.ui.help_open = false
		app.needs_redraw = true
	case .Close_Evidence:
		app.ui.evidence_open = false
		app.needs_redraw = true
	case .Select_Benchy:
		_ = app_load_model(0)
	case .Select_All_In_One:
		_ = app_load_model(1)
	case .Select_Bunny:
		_ = app_load_model(2)
	case .Frame_Mesh:
		app_frame_camera()
	case .Toggle_Wireframe:
		app.ui.wireframe = !app.ui.wireframe
		app.needs_redraw = true
	case .Open:
		app_open_document()
	case .Slice, .Cancel, .Capture, .Compare, .Export:
		return false
	case .None, .Evidence_Stage_Base:
		return false
	}
	return true
}

app_initialize :: proc(host: ^Host_Services) -> bool {
	if host == nil || !objc_initialize() {
		fmt.eprintln("HW Slicer failed before Objective-C initialization")
		return false
	}
	app = {}
	app.host = host^
	app.resource_root = strings.clone(string(host.resource_root))
	app.ui.dark = host.preference_get_int("theme-dark", 1) != 0
	app.ui.selected_model = 0
	ui_initialize(&app.ui)
	if !renderer_initialize(&app.renderer, Id(host.layer)) {
		fmt.eprintln("HW Slicer failed during Metal initialization")
		renderer_shutdown(&app.renderer)
		ui_destroy(&app.ui)
		return false
	}
	if !app_load_model(app.ui.selected_model, true) {
		if app.ui.selected_model != 0 && app_load_model(0, true) {
			app_set_status("FALLBACK: LOADED 3DBENCHY")
		} else {
			fmt.eprintln("HW Slicer failed while loading its mesh")
			renderer_shutdown(&app.renderer)
			ui_destroy(&app.ui)
			return false
		}
	}
	app.needs_redraw = true
	return true
}

app_destroy :: proc() {
	mesh_destroy(&app.mesh)
	evidence.evidence_bundle_replay_destroy(&app.evidence_replay)
	renderer_shutdown(&app.renderer)
	ui_destroy(&app.ui)
	delete(app.resource_root)
	delete(app.external_path)
	delete(app.evidence_path)
	delete(app.model_name)
	delete(app.status)
	app = {}
}

app_camera_eye :: proc(camera: Camera) -> Vec3 {
	cos_pitch := math.cos(camera.pitch)
	direction := Vec3{
		cos_pitch*math.cos(camera.yaw),
		cos_pitch*math.sin(camera.yaw),
		math.sin(camera.pitch),
	}
	return vec3_add(camera.target, vec3_mul(direction, camera.distance))
}

app_pan_camera :: proc(delta_x, delta_y: f64) {
	eye := app_camera_eye(app.camera)
	forward := vec3_normalize(vec3_sub(app.camera.target, eye))
	right := vec3_normalize(vec3_cross(forward, {0, 0, 1}))
	up := vec3_normalize(vec3_cross(right, forward))
	scale := app.camera.distance*0.0015
	app.camera.target = vec3_add(
		app.camera.target,
		vec3_add(
			vec3_mul(right, f32(-delta_x)*scale),
			vec3_mul(up, f32(delta_y)*scale),
		),
	)
}

renderer_draw_application :: proc() {
	evidence_view := app_evidence_view()
	ui_build_controls(&app.ui, &evidence_view)
	solids := ui_build_geometry(&app.ui, &evidence_view)
	pixels := ui_build_text_overlay(
		&app.ui,
		&app.mesh,
		app.model_name,
		app.status,
		&evidence_view,
	)
	defer delete(pixels)
	renderer_draw(
		&app.renderer,
		&app.mesh,
		app.camera,
		ui_viewport_rect(&app.ui),
		ui_theme(&app.ui),
		app.ui.wireframe,
		solids[:],
		pixels,
		app.ui.width,
		app.ui.height,
		app.ui.scale,
	)
	app.needs_redraw = false
}

application_initialize :: proc "c" (host: ^Host_Services) -> bool {
	context = runtime.default_context()
	return app_initialize(host)
}

application_shutdown :: proc "c" () {
	context = runtime.default_context()
	app_destroy()
}

application_frame :: proc "c" (width, height, scale: f64) {
	context = runtime.default_context()
	if width <= 0 || height <= 0 {return}
	if width != app.last_width || height != app.last_height ||
	   scale != app.last_scale {
		app.last_width = width
		app.last_height = height
		app.last_scale = scale
		app.ui.width = width
		app.ui.height = height
		app.ui.scale = scale
		app.needs_redraw = true
	}
	if app.needs_redraw {
		renderer_draw_application()
	}
}

application_mouse :: proc "c" (
	phase, button: i32,
	x, y, delta_x, delta_y: f64,
) {
	context = runtime.default_context()
	switch phase {
	case 0:
		id := ui_hit_test(&app.ui, x, y)
		app.ui.pressed_id = id
		if id == 0 && ui_contains(ui_viewport_rect(&app.ui), x, y) {
			app.dragging = true
			app.drag_button = button
		}
	case 1:
		if app.dragging {
			if app.drag_button == 0 {
				app.camera.yaw -= f32(delta_x)*0.008
				app.camera.pitch = clamp_f32(
					app.camera.pitch+f32(delta_y)*0.008,
					-1.45,
					1.45,
				)
			} else {
				app_pan_camera(delta_x, delta_y)
			}
			app.needs_redraw = true
		}
	case 2:
		id := ui_hit_test(&app.ui, x, y)
		if !app.dragging && id != 0 && id == app.ui.pressed_id {
			_ = app_activate(UI_Action(id))
		}
		app.dragging = false
		app.ui.pressed_id = 0
	case 3:
		hovered := ui_hit_test(&app.ui, x, y)
		if hovered != app.ui.hovered_id {
			app.ui.hovered_id = hovered
			app.needs_redraw = true
		}
	case:
	}
}

application_scroll :: proc "c" (delta_x, delta_y: f64) {
	context = runtime.default_context()
	_ = delta_x
	app.camera.distance *= math.exp(f32(delta_y)*0.035)
	app.camera.distance = clamp_f32(app.camera.distance, 0.1, 100000)
	app.needs_redraw = true
}

application_key :: proc "c" (
	key_code: u16,
	characters: cstring,
	modifiers: u64,
) {
	context = runtime.default_context()
	_ = modifiers
	if key_code == 53 {
		if flash.is_active(&app.ui.flash_state) {
			flash.cancel(&app.ui.flash_state)
			app.needs_redraw = true
		} else if app.ui.help_open {
			app.ui.help_open = false
			app.needs_redraw = true
		} else if app.ui.evidence_open {
			app.ui.evidence_open = false
			app.needs_redraw = true
		}
		return
	}
	text := string(characters)
	if flash.is_active(&app.ui.flash_state) {
		if key_code == 48 && flash.has_group_selection(&app.ui.flash_state) {
			_ = flash.cycle_selection(&app.ui.flash_state, .Next)
			app.needs_redraw = true
			return
		}
		if key_code == 36 && flash.has_group_selection(&app.ui.flash_state) {
			result := flash.activate_selection(&app.ui.flash_state)
			if result.kind == .Activated {
				_ = app_activate(UI_Action(result.target_id))
			}
			app.needs_redraw = true
			return
		}
		if len(text) > 0 {
			result := flash.consume(&app.ui.flash_state, text[0])
			if result.kind == .Activated {
				_ = app_activate(UI_Action(result.target_id))
			}
			app.needs_redraw = true
		}
		return
	}
	if text == "/" {
		ui_begin_flash(&app.ui)
		app.needs_redraw = true
		return
	}
	if app.ui.help_open && text == "1" {
		_ = app_activate(.Close_Help)
		return
	}
	if app.ui.evidence_open && text == "1" {
		_ = app_activate(.Close_Evidence)
		return
	}
	if len(text) == 1 && text[0] >= '1' && text[0] <= '6' {
		slot := int(text[0]-'1')
		actions := [6]UI_Action{.Open, .Slice, .Cancel, .Capture, .Compare, .Export}
		_ = app_activate(actions[slot])
	}
}

application_control_count :: proc "c" () -> uint {
	return uint(len(app.ui.controls))
}

application_control_at :: proc "c" (
	index: uint,
	output: ^Host_Control,
) -> bool {
	if output == nil || index >= uint(len(app.ui.controls)) {return false}
	control := app.ui.controls[index]
	output^ = {
		id = control.id,
		name = cstring(raw_data(transmute([]u8)control.name)),
		label = cstring(raw_data(transmute([]u8)control.label)),
		rect = {
			control.rect.x,
			control.rect.y,
			control.rect.w,
			control.rect.h,
		},
		role = control.role,
		enabled = control.enabled,
		selected = control.selected,
	}
	return true
}

application_hit_test :: proc "c" (x, y: f64) -> u64 {
	context = runtime.default_context()
	return ui_hit_test(&app.ui, x, y)
}

application_activate_control :: proc "c" (control_id: u64) -> bool {
	context = runtime.default_context()
	return app_activate(UI_Action(control_id))
}

application_write_ui_snapshot :: proc "c" (path: cstring) -> bool {
	context = runtime.default_context()
	if path == nil {return false}
	return ui_write_snapshot(&app.ui, string(path))
}

application_api := Application_API{
	initialize = application_initialize,
	shutdown = application_shutdown,
	frame = application_frame,
	mouse = application_mouse,
	scroll = application_scroll,
	key = application_key,
	control_count = application_control_count,
	control_at = application_control_at,
	hit_test = application_hit_test,
	activate_control = application_activate_control,
	write_ui_snapshot = application_write_ui_snapshot,
}

main :: proc() {
	status := hw_slicer_host_run(&application_api)
	if status != 0 {
		os.exit(int(status))
	}
}
