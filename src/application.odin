package main

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"
import flash "flash:."
import devlog "devlog:."

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
	placement: Model_Placement,
	face_hover: int,
	face_pressed: int,
	section_vertices: [dynamic]Mesh_Vertex,
	section_dirty: bool,
	first_frame_logged: bool,
	evidence_replay: evidence.Evidence_Bundle_Replay,
	evidence_kind: evidence.Evidence_Bundle_Source_Kind,
	camera:        Camera,
	camera_goal: Camera,
	camera_velocity: Camera,
	camera_tick: time.Tick,
	camera_initialized: bool,
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
startup_font_size: int
startup_settings_open: bool

app_context :: proc() -> runtime.Context {
	result := runtime.default_context()
	result.assertion_failure_proc = devlog.fatal_hook()
	return result
}

app_set_status :: proc(text: string) {
	delete(app.status)
	app.status = strings.clone(text)
	app.needs_redraw = true
}

app_frame_camera :: proc() {
	if app.mesh.triangle_count == 0 {return}
	size := mesh_size(app.placement.bounds)
	app.camera_goal.target = {0, 0, size.z*0.5}
	app.camera_goal.yaw = 0.82
	app.camera_goal.pitch = 0.62
	app.camera_goal.distance = max(max(size.x, size.y), size.z)*2.25
	app.camera_goal.distance = max(app.camera_goal.distance, 4)
	if !app.camera_initialized {
		app.camera = app.camera_goal
		app.camera_initialized = true
	}
	app.needs_redraw = true
}

// ponytail: dev-only absolute model directory; use resource_root when packaging.
DEV_MODEL_DIRECTORY :: "/Users/martin/projects/hw_slicer/resources/models"

app_model_path :: proc(index: int) -> (string, string) {
	switch index {
	case 0:
		path, _ := filepath.join(
			{DEV_MODEL_DIRECTORY, "benchy.stl"},
		)
		return path, "3DBenchy"
	case 1:
		path, _ := filepath.join(
			{DEV_MODEL_DIRECTORY, "all-in-one-test.stl"},
		)
		return path, "All In One 3D Printer Test"
	case 2:
		path, _ := filepath.join(
			{DEV_MODEL_DIRECTORY, "stanford-bunny.stl"},
		)
		return path, "Stanford Bunny"
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
	site := devlog.Site{feature = "model", operation = "load"}
	devlog.started(devlog.global(), site, {scope = "model", stage = "read"})
	next, error := mesh_load_stl(path)
	if error != .None {
		devlog.failed(
			devlog.global(),
			site,
			{
				reason = "model load failed",
				detail = mesh_error_text(error),
				code = i32(error),
				severity = .Error,
			},
			{scope = "model", stage = "read"},
		)
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
		devlog.failed(
			devlog.global(),
			site,
			{
				reason = "renderer mesh upload failed",
				severity = .Critical,
			},
			{scope = "model", stage = "upload"},
		)
		app_set_status("LOAD FAILED: METAL BUFFER")
		return false
	}
	mesh_destroy(&app.mesh)
	app.mesh = next
	rotation := mat4_identity()
	if index == 1 {rotation = {1,0,0,0, 0,0,1,0, 0,-1,0,0, 0,0,0,1}}
	app.placement = placement_on_bed(&app.mesh, rotation)
	app.ui.lay_on_face = false
	app.face_hover = -1
	app.face_pressed = -1
	app.ui.selected_model = index
	app.ui.section_max = mesh_size(app.placement.bounds).z
	app.ui.section_z = app.ui.section_max/2
	app.section_dirty = true
	delete(app.model_name)
	app.model_name = strings.clone(name)
	app_set_status(fmt.tprintf("LOADED %d TRIANGLES", app.mesh.triangle_count))
	devlog.succeeded(
		devlog.global(),
		site,
		{scope = "model", stage = "loaded"},
		{rows = i64(app.mesh.triangle_count)},
	)
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
	site := devlog.Site{feature = "evidence", operation = "load"}
	devlog.started(devlog.global(), site, {scope = "evidence", stage = "read"})
	next, kind, load_error := evidence.evidence_bundle_path_replay(path)
	if load_error != .None {
		devlog.failed(
			devlog.global(),
			site,
			{
				reason = "evidence load failed",
				code = i32(load_error),
				severity = .Error,
			},
			{scope = "evidence", stage = "read"},
		)
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
	app.ui.focused_id = 0
	app.ui.evidence_stage_index = 0
	app.ui.evidence_scroll = 0
	app.ui.evidence_detail_scroll = 0
	app.ui.evidence_pane = .Stages
	app_set_status(
		fmt.tprintf(
			"EVIDENCE: %d STAGES",
			len(app.evidence_replay.root.stages),
		),
	)
	devlog.succeeded(
		devlog.global(),
		site,
		{scope = "evidence", stage = "loaded"},
		{rows = i64(len(app.evidence_replay.root.stages))},
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
		app.ui.evidence_detail_scroll = 0
		if ui_evidence_compact(&app.ui) {app.ui.evidence_pane = .Details}
		app.needs_redraw = true
		return true
	}
	switch action {
	case .Modal_Surface:
		return false
	case .Evidence_Stages, .Evidence_Details:
		app.ui.evidence_pane = .Stages if action == .Evidence_Stages else .Details
		app.needs_redraw = true
	case .Panel_Models, .Panel_Section, .Panel_Mesh:
		if action == .Panel_Models {app.ui.panel = .Models}
		if action == .Panel_Section {app.ui.panel = .Section}
		if action == .Panel_Mesh {app.ui.panel = .Mesh}
		app.needs_redraw = true
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
		app.ui.focused_id = 0
		app.ui.evidence_open = false
		app.ui.help_open = true
		app.needs_redraw = true
	case .Close_Help, .Dismiss_Help:
		app.ui.focused_id = 0
		app.ui.help_open = false
		app.needs_redraw = true
	case .Close_Evidence:
		app.ui.focused_id = 0
		app.ui.evidence_open = false
		app.needs_redraw = true
	case .Dismiss_Evidence:
		app.ui.focused_id = 0
		app.ui.evidence_open = false
		app.needs_redraw = true
	case .Select_Benchy:
		_ = app_load_model(0)
	case .Select_All_In_One:
		_ = app_load_model(1)
	case .Select_Bunny:
		_ = app_load_model(2)
	case .Lay_On_Face:
		app.ui.lay_on_face = !app.ui.lay_on_face
		app.face_hover = -1
		app.face_pressed = -1
		app_set_status("SELECT A FACE TO PLACE ON THE BED; ESC CANCELS" if app.ui.lay_on_face else "FACE SELECTION CANCELLED")
	case .Frame_Mesh:
		app_frame_camera()
	case .Toggle_Wireframe:
		app.ui.wireframe = !app.ui.wireframe
		app.needs_redraw = true
	case .Toggle_Section:
		app.ui.section_enabled = !app.ui.section_enabled
		app.section_dirty = true
		app.needs_redraw = true
	case .Open_Settings:
		app.ui.focused_id = 0
		app.ui.settings_open = true
		app.needs_redraw = true
	case .Close_Settings, .Dismiss_Settings:
		app.ui.focused_id = 0
		app.ui.settings_open = false
		app.needs_redraw = true
	case .Font_Decrease:
		app_apply_font_size(-1)
		return true
	case .Font_Increase:
		app_apply_font_size(1)
		return true
	case .Section_Height:
		return true
	case .Open:
		app_open_document()
		app.needs_redraw = true
	case .Slice, .Cancel, .Capture, .Compare, .Export:
		return false
	case .None, .Evidence_Stage_Base:
		return false
	}
	return true
}

app_initialize :: proc(host: ^Host_Services) -> bool {
	site := devlog.Site{feature = "app", operation = "initialize"}
	devlog.started(devlog.global(), site, {scope = "app", stage = "window"})
	if host == nil || !objc_initialize() {
		devlog.failed(
			devlog.global(),
			site,
			{
				reason = "initialization failed",
				detail = "objective-c unavailable",
				severity = .Critical,
			},
			{scope = "app", stage = "window"},
		)
		fmt.eprintln("HW Slicer failed before Objective-C initialization")
		return false
	}
	app = {}
	app.host = host^
	app.resource_root = strings.clone(string(host.resource_root))
	app.ui.dark = host.preference_get_int("theme-dark", 1) != 0
	app.ui.selected_model = 0
	ui_initialize(&app.ui)
	settings := settings_defaults()
	_ = settings_load(settings_path(context.temp_allocator), &settings)
	if startup_font_size != 0 {
		settings.font_size = settings_font_size_clamped(startup_font_size)
	}
	app.ui.font_size = settings.font_size
	app.ui.ui_scale = f64(app.ui.font_size)/BASE_FONT_SIZE
	app.ui.settings_open = startup_settings_open
	if !renderer_initialize(&app.renderer, Id(host.layer)) {
		devlog.failed(
			devlog.global(),
			site,
			{
				reason = "metal initialization failed",
				severity = .Critical,
			},
			{scope = "app", stage = "renderer"},
		)
		fmt.eprintln("HW Slicer failed during Metal initialization")
		renderer_shutdown(&app.renderer)
		ui_destroy(&app.ui)
		return false
	}
	if capture := os.get_env("HW_SLICER_CAPTURE", context.allocator); len(capture) > 0 {
		app.renderer.capture_path = capture
	}
	if !app_load_model(app.ui.selected_model, true) {		if app.ui.selected_model != 0 && app_load_model(0, true) {
			app_set_status("FALLBACK: LOADED 3DBENCHY")
		} else {
			fmt.eprintln("HW Slicer failed while loading its mesh")
			renderer_shutdown(&app.renderer)
			ui_destroy(&app.ui)
			return false
		}
	}
	app.needs_redraw = true
	devlog.succeeded(
		devlog.global(),
		site,
		{scope = "app", stage = "ready"},
	)
	return true
}

app_destroy :: proc() {
	mesh_destroy(&app.mesh)
	delete(app.section_vertices)
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

app_apply_font_size :: proc(delta: int) {
	next := settings_font_size_clamped(app.ui.font_size+delta)
	if next == app.ui.font_size {return}
	app.ui.font_size = next
	app.ui.ui_scale = f64(next)/BASE_FONT_SIZE
	if app.ui.physical_width > 0 && app.ui.physical_height > 0 {
		app.ui.width = app.ui.physical_width/app.ui.ui_scale
		app.ui.height = app.ui.physical_height/app.ui.ui_scale
	}
	_ = settings_save(
		settings_path(context.temp_allocator),
		{font_size = next},
	)
	app.needs_redraw = true
}

app_set_section_z :: proc(x: f64) {
	if app.ui.section_max <= 0 {return}
	rect := ui_section_slider_rect(&app.ui)
	next := section_height_from_pointer(
		x,
		rect,
		app.ui.section_max,
	)
	if next == app.ui.section_z {return}
	app.ui.section_z = next
	app.section_dirty = true
}

app_rebuild_section :: proc() {
	if !app.ui.section_enabled || app.mesh.triangle_count == 0 {
		clear(&app.section_vertices)
		app.ui.section_segments = 0
		return
	}
	stats := section_mesh_at_z(&app.mesh, app.ui.section_z, &app.section_vertices, app.placement.transform)
	app.ui.section_segments = stats.segments
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
	eye := app_camera_eye(app.camera_goal)
	forward := vec3_normalize(vec3_sub(app.camera_goal.target, eye))
	right := vec3_normalize(vec3_cross(forward, {0, 0, 1}))
	up := vec3_normalize(vec3_cross(right, forward))
	scale := app.camera_goal.distance*0.0015
	app.camera_goal.target = vec3_add(
		app.camera_goal.target,
		vec3_add(
			vec3_mul(right, f32(-delta_x)*scale),
			vec3_mul(up, f32(delta_y)*scale),
		),
	)
}

renderer_draw_application :: proc() -> Render_Result {
	if app.section_dirty {
		app_rebuild_section()
		_ = renderer_set_section(&app.renderer, app.section_vertices[:])
		app.section_dirty = false
	}
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
	viewport := ui_viewport_rect(&app.ui)
	viewport.x *= app.ui.ui_scale
	viewport.y *= app.ui.ui_scale
	viewport.w *= app.ui.ui_scale
	viewport.h *= app.ui.ui_scale
	result := renderer_draw(
		&app.renderer,
		&app.mesh,
		app.placement,
		app.face_hover,
		app.camera,
		viewport,
		ui_theme(&app.ui),
		app.ui.wireframe,
		solids[:],
		pixels,
		app.ui.physical_width,
		app.ui.physical_height,
		app.ui.scale,
	)
	app.needs_redraw = false
	return result
}

application_initialize :: proc "c" (host: ^Host_Services) -> bool {
	context = app_context()
	return app_initialize(host)
}

application_shutdown :: proc "c" () {
	context = app_context()
	devlog.stopped(
		devlog.global(),
		{feature = "app", operation = "shutdown"},
		{scope = "app"},
	)
	devlog.global_destroy()
	app_destroy()
}

application_frame :: proc "c" (width, height, scale: f64) {
	context = app_context()
	if width <= 0 || height <= 0 {return}
	if width != app.last_width || height != app.last_height ||
	   scale != app.last_scale {
		app.last_width = width
		app.last_height = height
		app.last_scale = scale
		app.ui.physical_width = width
		app.ui.physical_height = height
		app.ui.scale = scale
		app.ui.ui_scale = f64(app.ui.font_size)/BASE_FONT_SIZE
		app.ui.width = width/app.ui.ui_scale
		app.ui.height = height/app.ui.ui_scale
		app.needs_redraw = true
	}
	app_animate_camera()
	if app.needs_redraw {
		result := renderer_draw_application()
		switch result {
		case .Presented, .Captured:
			if !app.first_frame_logged {
				devlog.succeeded(
					devlog.global(),
					{feature = "renderer", operation = "first_frame"},
					{scope = "renderer", stage = "draw"},
					{rows = 1},
				)
				app.first_frame_logged = true
			}
		case .Capture_Failed:
			devlog.failed(
				devlog.global(),
				{feature = "renderer", operation = "capture"},
				{
					reason = "render capture failed",
					severity = .Warning,
				},
				{scope = "renderer", stage = "capture"},
			)
		case .No_Layer, .Empty_Viewport, .No_Depth_Texture,
		     .No_Drawable, .No_Command_Buffer, .No_Encoder,
		     .No_Capture_Texture:
			if !app.first_frame_logged {
				devlog.failed(
					devlog.global(),
					{feature = "renderer", operation = "draw"},
					{
						reason = "renderer draw failed",
						detail = render_result_text(result),
						severity = .Warning,
					},
					{scope = "renderer", stage = "draw"},
				)
			}
		}
	}
}

application_mouse :: proc "c" (
	phase, button: i32,
	x, y, delta_x, delta_y: f64,
) {
	context = app_context()
	ui_scale := app.ui.ui_scale
	if ui_scale <= 0 {ui_scale = 1}
	point_x := x/ui_scale
	point_y := y/ui_scale
	app.ui.pointer_x = point_x
	app.ui.pointer_y = point_y
	if phase == 4 {return}
	if app.ui.lay_on_face && !app.ui.settings_open && !app.ui.help_open && !app.ui.evidence_open &&
	   ui_hit_test(&app.ui, point_x, point_y) == 0 && ui_contains(ui_viewport_rect(&app.ui), point_x, point_y) {
		if phase == 3 || (phase == 0 && button == 0) || (phase == 2 && button == 0) {
			face := placement_pick(&app.mesh, app.placement, app.camera, ui_viewport_rect(&app.ui), point_x, point_y)
			rotation, valid := placement_face(&app.mesh, face)
			app.face_hover = face if valid else -1
			app.needs_redraw = true
			if phase == 0 {
				app.face_pressed = app.face_hover
				if !valid {app_set_status("SELECT AN OUTER FLAT FACE")}
			}
			if phase == 2 && valid && app.face_pressed == face {
				app.placement = placement_on_bed(&app.mesh, rotation)
				app.ui.section_max = mesh_size(app.placement.bounds).z
				app.ui.section_z = min(app.ui.section_z, app.ui.section_max)
				app.section_dirty = true
				app.ui.lay_on_face = false
				app.face_hover = -1
				app_frame_camera()
				app_set_status("FACE PLACED ON BED")
			}
			if phase == 2 {app.face_pressed = -1}
			return
		}
	} else if app.face_hover >= 0 {
		app.face_hover = -1
		app.needs_redraw = true
	}
	switch phase {
	case 0:
		if app.ui.focused_id != 0 {app.ui.focused_id = 0; app.needs_redraw = true}
		app.face_pressed = -1
		id := ui_hit_test(&app.ui, point_x, point_y)
		app.ui.pressed_id = id
		if id != 0 {app.needs_redraw = true}
		if id == u64(UI_Action.Section_Height) {
			app.ui.section_dragging = true
			app_set_section_z(point_x)
			app.needs_redraw = true
		} else {
			app.ui.section_dragging = false
			if id == 0 && ui_contains(ui_viewport_rect(&app.ui), point_x, point_y) {
				app.dragging = true
				app.drag_button = button
			}
		}
	case 1:
		if app.ui.section_dragging {
			app_set_section_z(point_x)
			app.needs_redraw = true
		} else if app.dragging {
			if app.drag_button == 0 {
				app.camera_goal.yaw -= f32(delta_x)*0.008
				app.camera_goal.pitch = clamp_f32(
					app.camera_goal.pitch+f32(delta_y)*0.008,
					-1.45,
					1.45,
				)
			} else {
				app_pan_camera(delta_x, delta_y)
			}
			app.needs_redraw = true
		}
	case 2:
		if app.ui.pressed_id != 0 {app.needs_redraw = true}
		if app.ui.section_dragging {
			app.ui.section_dragging = false
			app.ui.pressed_id = 0
		} else {
			id := ui_hit_test(&app.ui, point_x, point_y)
			if !app.dragging && id != 0 && id == app.ui.pressed_id {
				_ = app_activate(UI_Action(id))
			}
			app.dragging = false
			app.ui.pressed_id = 0
		}
	case 3:
		hovered := ui_hit_test(&app.ui, point_x, point_y)
		if hovered != app.ui.hovered_id {
			app.ui.hovered_id = hovered
			app.needs_redraw = true
		}
	case:
	}
}

application_scroll :: proc "c" (delta_x, delta_y: f64) {
	context = app_context()
	_ = delta_x
	if app.ui.evidence_open {
		step := -1 if delta_y > 0 else 1
		if delta_y != 0 {
			detail_scroll := ui_evidence_compact(&app.ui) && app.ui.evidence_pane == .Details
			if !ui_evidence_compact(&app.ui) {
				detail_scroll = ui_contains(ui_evidence_detail_rect(&app.ui), app.ui.pointer_x, app.ui.pointer_y)
			}
			if detail_scroll {
				view := app_evidence_view()
				lines := ui_evidence_detail_lines(&app.ui, &view)
				maximum := max(0, len(lines)-ui_evidence_detail_rows(&app.ui))
				app.ui.evidence_detail_scroll = clamp(app.ui.evidence_detail_scroll+step, 0, maximum)
			} else {
				stage_count := len(app.evidence_replay.root.stages)
				maximum := max(0, stage_count-ui_evidence_visible_stages(&app.ui))
				app.ui.evidence_scroll = clamp(app.ui.evidence_scroll+step, 0, maximum)
			}
			app.needs_redraw = true
		}
		return
	}
	if app.ui.settings_open || app.ui.help_open {return}
	app.camera_goal.distance *= math.exp(-f32(delta_y)*0.008)
	app.camera_goal.distance = clamp_f32(app.camera_goal.distance, 0.1, camera_distance_max(app.camera_goal, ui_viewport_rect(&app.ui)))
	app.needs_redraw = true
}

app_adjust_section_height :: proc(direction: i32) -> bool {
	if direction != -1 && direction != 1 {return false}
	view := app_evidence_view()
	ui_build_controls(&app.ui, &view)
	for control in app.ui.controls {
		if control.action == .Section_Height && ui_control_focusable(&app.ui, control) {
			step := app.ui.section_max/100
			app.ui.section_z = clamp(app.ui.section_z+step*f32(direction), 0, app.ui.section_max)
			app.section_dirty = true
			app.needs_redraw = true
			return true
		}
	}
	return false
}

application_key :: proc "c" (
	key_code: u16,
	characters: cstring,
	modifiers: u64,
) {
	context = app_context()
	if key_code == 53 {
		if app.ui.lay_on_face && !app.ui.settings_open && !app.ui.help_open &&
		   !app.ui.evidence_open && !flash.is_active(&app.ui.flash_state) {
			app.ui.lay_on_face = false
			app.face_hover = -1
			app_set_status("FACE SELECTION CANCELLED")
			return
		}
		if flash.is_active(&app.ui.flash_state) {
			flash.cancel(&app.ui.flash_state)
			app.needs_redraw = true
		} else if app.ui.settings_open {
			app.ui.focused_id = 0
			app.ui.settings_open = false
			app.needs_redraw = true
		} else if app.ui.help_open {
			app.ui.focused_id = 0
			app.ui.help_open = false
			app.needs_redraw = true
		} else if app.ui.evidence_open {
			app.ui.focused_id = 0
			app.ui.evidence_open = false
			app.needs_redraw = true
		}
		return
	}
	text := string(characters)
	command := (modifiers & (1 << 20)) != 0
	if command && text == "," {
		if app.ui.settings_open || (!app.ui.help_open && !app.ui.evidence_open) {
			if flash.is_active(&app.ui.flash_state) {flash.cancel(&app.ui.flash_state)}
			app.ui.settings_open = !app.ui.settings_open
			app.ui.focused_id = 0
			app.needs_redraw = true
		}
		return
	}
	if !flash.is_active(&app.ui.flash_state) {
		if key_code == 48 {
			view := app_evidence_view()
			ui_build_controls(&app.ui, &view)
			ui_focus_next(&app.ui, (modifiers & (1 << 17)) != 0)
			app.needs_redraw = true
			return
		}
		if key_code == 36 || key_code == 76 || key_code == 49 {
			view := app_evidence_view()
			ui_build_controls(&app.ui, &view)
			for control in app.ui.controls {
				if control.id == app.ui.focused_id && ui_control_focusable(&app.ui, control) {
					_ = app_activate(control.action)
					app.needs_redraw = true
					return
				}
			}
		}
		if app.ui.focused_id == u64(UI_Action.Section_Height) && (key_code == 123 || key_code == 124) {
			if app_adjust_section_height(1 if key_code == 124 else -1) {return}
		}
	}
	if app.ui.settings_open {
		if text == "-" {
			app_apply_font_size(-1)
			return
		}
		if text == "=" || text == "+" {
			app_apply_font_size(1)
			return
		}
		if text == "1" {
			app.ui.focused_id = 0
			app.ui.settings_open = false
			app.needs_redraw = true
		}
		return
	}
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
	if app.ui.help_open {
		if text == "1" {_ = app_activate(.Close_Help)}
		return
	}
	if app.ui.evidence_open {
		if key_code == 126 || key_code == 125 {
			application_scroll(0, 1 if key_code == 126 else -1)
			return
		}
		if text == "1" {_ = app_activate(.Close_Evidence)}
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
	context = app_context()
	if output == nil || index >= uint(len(app.ui.controls)) {return false}
	control := app.ui.controls[index]
	if !ui_control_accessible(&app.ui, control) {return false}
	ui_scale := app.ui.ui_scale
	role := control.role
	if control.action == .Toggle_Section {role = 2}
	if control.action == .Section_Height {role = 3}
	output^ = {
		id = control.id,
		name = raw_data(transmute([]u8)control.name),
		name_length = uint(len(control.name)),
		label = raw_data(transmute([]u8)control.label),
		label_length = uint(len(control.label)),
		rect = {
			control.rect.x*ui_scale,
			control.rect.y*ui_scale,
			control.rect.w*ui_scale,
			control.rect.h*ui_scale,
		},
		role = role,
		enabled = control.enabled,
		selected = app.ui.section_enabled if role == 2 else control.selected,
		value = f64(app.ui.section_z) if role == 3 else 0,
		minimum = 0,
		maximum = f64(app.ui.section_max) if role == 3 else 0,
	}
	return true
}

application_hit_test :: proc "c" (x, y: f64) -> u64 {
	context = app_context()
	ui_scale := app.ui.ui_scale
	if ui_scale <= 0 {ui_scale = 1}
	return ui_hit_test(&app.ui, x/ui_scale, y/ui_scale)
}

application_activate_control :: proc "c" (control_id: u64) -> bool {
	context = app_context()
	view := app_evidence_view()
	ui_build_controls(&app.ui, &view)
	for control in app.ui.controls {
		if control.id == control_id && ui_control_focusable(&app.ui, control) {
			return app_activate(control.action)
		}
	}
	return false
}

application_adjust_control :: proc "c" (control_id: u64, direction: i32) -> bool {
	context = app_context()
	if control_id != u64(UI_Action.Section_Height) {return false}
	return app_adjust_section_height(direction)
}

application_window_state :: proc "c" (visible, active: bool) {
	context = app_context()
	site := devlog.Site{feature = "window", operation = "show"}
	switch {
	case visible && active:
		devlog.succeeded(devlog.global(), site, {scope = "window", stage = "active"})
	case visible:
		devlog.failed(
			devlog.global(),
			site,
			{reason = "window not active", severity = .Warning},
			{scope = "window"},
		)
	case:
		devlog.failed(
			devlog.global(),
			site,
			{reason = "window not visible", severity = .Critical},
			{scope = "window"},
		)
	}
}

application_write_ui_snapshot :: proc "c" (path: cstring) -> bool {
	context = app_context()
	if path == nil {return false}
	text := string(path)
	if !ui_write_snapshot(&app.ui, text) {
		devlog.failed(
			devlog.global(),
			{feature = "ui", operation = "write_snapshot"},
			{
				reason = "ui snapshot write failed",
				detail = filepath.base(text),
				severity = .Warning,
			},
			{scope = "ui"},
		)
		return false
	}
	return true
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
	adjust_control = application_adjust_control,
	write_ui_snapshot = application_write_ui_snapshot,
	window_state = application_window_state,
}

main :: proc() {
	for argument in os.args[1:] {
		if strings.has_prefix(argument, "--font-size=") {
			value := argument[len("--font-size="):]
			if parsed, ok := strconv.parse_int(value, 10); ok {
				startup_font_size = parsed
			}
		} else if argument == "--settings" {
			startup_settings_open = true
		}
	}
	config := devlog.DEFAULT_CONFIG
	config.profile = devlog.profile_from_env()
	started := devlog.global_start(
		devlog.default_directory("hw-slicer", "app"),
		config,
	)
	if started {
		context.assertion_failure_proc = devlog.fatal_hook()
	}
	defer {
		if started {devlog.global_destroy()}
	}
	devlog.started(
		devlog.global(),
		{feature = "app", operation = "startup"},
		{scope = "app", stage = "launch"},
	)
	status := hw_slicer_host_run(&application_api)
	if status != 0 {
		devlog.failed(
			devlog.global(),
			{feature = "app", operation = "window_host"},
			{
				reason = "window host failed",
				code = i32(status),
				severity = .Critical,
			},
			{scope = "app"},
		)
	}
	devlog.stopped(
		devlog.global(),
		{feature = "app", operation = "shutdown"},
		{scope = "app"},
	)
	if status != 0 {
		os.exit(int(status))
	}
}
