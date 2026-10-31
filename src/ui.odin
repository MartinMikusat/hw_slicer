package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import CF "core:sys/darwin/CoreFoundation"
import flash "flash:."

import evidence "./evidence"

foreign import core_graphics "system:CoreGraphics.framework"
foreign core_graphics {
	CGDataProviderCreateWithCFData :: proc "c" (data: rawptr) -> rawptr ---
	CGDataProviderRelease :: proc "c" (provider: rawptr) ---
	CGFontCreateWithDataProvider :: proc "c" (provider: rawptr) -> rawptr ---
	CGFontRelease :: proc "c" (font: rawptr) ---
	CGColorSpaceCreateDeviceRGB :: proc "c" () -> rawptr ---
	CGColorSpaceRelease :: proc "c" (space: rawptr) ---
	CGBitmapContextCreate :: proc "c" (
		data: rawptr,
		width, height, bits_per_component, bytes_per_row: uint,
		space: rawptr,
		bitmap_info: u32,
	) -> rawptr ---
	CGContextRelease :: proc "c" (ctx: rawptr) ---
	CGContextClearRect :: proc "c" (ctx: rawptr, rect: NS_Rect) ---
	CGContextSetAlpha :: proc "c" (ctx: rawptr, alpha: f64) ---
	CGContextSetRGBFillColor :: proc "c" (
		ctx: rawptr,
		red, green, blue, alpha: f64,
	) ---
	CGContextSetRGBStrokeColor :: proc "c" (
		ctx: rawptr,
		red, green, blue, alpha: f64,
	) ---
	CGContextSetLineWidth :: proc "c" (ctx: rawptr, width: f64) ---
	CGContextSetLineCap :: proc "c" (ctx: rawptr, cap: i32) ---
	CGContextSetLineJoin :: proc "c" (ctx: rawptr, join: i32) ---
	CGContextBeginPath :: proc "c" (ctx: rawptr) ---
	CGContextMoveToPoint :: proc "c" (ctx: rawptr, x, y: f64) ---
	CGContextAddLineToPoint :: proc "c" (ctx: rawptr, x, y: f64) ---
	CGContextStrokePath :: proc "c" (ctx: rawptr) ---
	CGContextStrokeEllipseInRect :: proc "c" (ctx: rawptr, rect: NS_Rect) ---
	CGContextSetTextPosition :: proc "c" (ctx: rawptr, x, y: f64) ---
	CGContextSaveGState :: proc "c" (ctx: rawptr) ---
	CGContextRestoreGState :: proc "c" (ctx: rawptr) ---
	CGContextClipToRect :: proc "c" (ctx: rawptr, rect: NS_Rect) ---
}

foreign import core_text "system:CoreText.framework"
foreign core_text {
	CTLineCreateWithAttributedString :: proc "c" (string: rawptr) -> rawptr ---
	CTLineGetTypographicBounds :: proc "c" (
		line: rawptr,
		ascent, descent, leading: ^f64,
	) -> f64 ---
	CTLineDraw :: proc "c" (line, ctx: rawptr) ---
	CTFontManagerRegisterGraphicsFont :: proc "c" (font: rawptr, error: ^rawptr) -> bool ---
	CTFontCreateWithName :: proc "c" (name: rawptr, size: f64, transform: rawptr) -> rawptr ---
	kCTKernAttributeName: rawptr
	kCTFontAttributeName: rawptr
	kCTForegroundColorFromContextAttributeName: rawptr
}

foreign import slicer_core_foundation "system:CoreFoundation.framework"
foreign slicer_core_foundation {
	CFNumberCreate :: proc "c" (allocator: rawptr, kind: i32, value: rawptr) -> rawptr ---
	CFDataCreate :: proc "c" (allocator: rawptr, bytes: rawptr, length: int) -> rawptr ---
	CFStringCreateWithBytes :: proc "c" (
		allocator: rawptr,
		bytes: [^]u8,
		count: int,
		encoding: u32,
		external: bool,
	) -> rawptr ---
	CFStringGetLength :: proc "c" (string: rawptr) -> int ---
	CFAttributedStringCreateMutable :: proc "c" (
		allocator: rawptr,
		max_length: int,
	) -> rawptr ---
	CFAttributedStringReplaceString :: proc "c" (
		string: rawptr,
		range: CF.Range,
		replacement: rawptr,
	) ---
	CFAttributedStringSetAttribute :: proc "c" (
		string: rawptr,
		range: CF.Range,
		name, value: rawptr,
	) ---
	CFRelease :: proc "c" (value: rawptr) ---
	kCFBooleanTrue: rawptr
}

UI_Rect :: struct {x, y, w, h: f64}

UI_Action :: enum u64 {
	None,
	Modal_Surface,
	Window_Close,
	Window_Minimize,
	Window_Zoom,
	Toggle_Theme,
	Show_Help,
	Close_Help,
	Dismiss_Help,
	Select_Benchy,
	Select_All_In_One,
	Select_Bunny,
	Frame_Mesh,
	Toggle_Wireframe,
	Open,
	Slice,
	Cancel,
	Capture,
	Compare,
	Export,
	Close_Evidence,
	Dismiss_Evidence,
	Open_Settings,
	Close_Settings,
	Dismiss_Settings,
	Font_Decrease,
	Font_Increase,
	Toggle_Section,
	Section_Height,
	Lay_On_Face,
	Evidence_Stage_Base = 1000,
}

UI_Control :: struct {
	id:      u64,
	name:    string,
	label:   string,
	rect:    UI_Rect,
	action:  UI_Action,
	enabled: bool,
	role:    i32,
	selected: bool,
}

UI_Evidence_View :: struct {
	replay:    ^evidence.Evidence_Bundle_Replay,
	source:    string,
	container: string,
}

Theme :: struct {
	canvas:  Vec4,
	header:  Vec4,
	surface: Vec4,
	raised:  Vec4,
	control: Vec4,
	overlay: Vec4,
	text:    Vec4,
	muted:   Vec4,
}

LIGHT_THEME :: Theme{
	canvas  = {0.976471, 0.972549, 0.964706, 1},
	header  = {0.976471, 0.972549, 0.964706, 1},
	surface = {0.976471, 0.972549, 0.964706, 1},
	raised  = {0.976471, 0.972549, 0.964706, 1},
	control = {0.976471, 0.972549, 0.964706, 1},
	overlay = {0.976471, 0.972549, 0.964706, 1},
	text    = {0.180392, 0.180392, 0.180392, 1},
	muted   = {0.180392, 0.180392, 0.180392, 1},
}

DARK_THEME :: Theme{
	canvas  = {0.090196, 0.090196, 0.090196, 1},
	header  = {0.090196, 0.090196, 0.090196, 1},
	surface = {0.090196, 0.090196, 0.090196, 1},
	raised  = {0.156078, 0.156078, 0.156078, 1},
	control = {0.156078, 0.156078, 0.156078, 1},
	overlay = {0.090196, 0.090196, 0.090196, 1},
	text    = {0.819608, 0.819608, 0.819608, 1},
	muted   = {0.819608, 0.819608, 0.819608, 1},
}

COLOR_COFFEE :: Vec4{0.698039, 0.490196, 0.341176, 1}
COLOR_SECTION :: Vec4{0.980392, 0.427451, 0.121569, 1}
FLASH_BG     :: Vec4{0.96, 0.94, 0.85, 1}
FLASH_FG     :: Vec4{0.025, 0.027, 0.026, 1}
FLASH_BORDER :: Vec4{0.02, 0.02, 0.02, 1}
FLASH_SELECTED_BG :: Vec4{0.98, 0.35, 0.09, 1}
FLASH_SELECTED_BORDER :: Vec4{1.0, 0.55, 0.18, 1}

UI_State :: struct {
	controls: [dynamic]UI_Control,
	flash_state: flash.State,
	help_open: bool,
	evidence_open: bool,
	evidence_stage_index: int,
	evidence_scroll: int,
	width: f64,
	height: f64,
	scale: f64,
	dark: bool,
	selected_model: int,
	wireframe: bool,
	lay_on_face: bool,
	font_size:   int,
	ui_scale:    f64,
	physical_width:  f64,
	physical_height: f64,
	settings_open: bool,
	section_enabled:  bool,
	section_z:        f32,
	section_max:      f32,
	section_segments: int,
	section_dragging: bool,
	pressed_id: u64,
	hovered_id: u64,
}

ui_initialize :: proc(ui: ^UI_State) {
	ui.controls = make([dynamic]UI_Control)
	ui.font_size = DEFAULT_FONT_SIZE
	ui.ui_scale = f64(ui.font_size)/BASE_FONT_SIZE
	ui.section_enabled = true
	flash.state_init(&ui.flash_state)
}

ui_destroy :: proc(ui: ^UI_State) {
	delete(ui.controls)
	flash.state_destroy(&ui.flash_state)
	ui^ = {}
}

ui_theme :: proc(ui: ^UI_State) -> Theme {
	return DARK_THEME if ui.dark else LIGHT_THEME
}

ui_contains :: proc(rect: UI_Rect, x, y: f64) -> bool {
	return x >= rect.x && y >= rect.y &&
		x < rect.x+rect.w && y < rect.y+rect.h
}

ui_viewport_rect :: proc(ui: ^UI_State) -> UI_Rect {
	return {
		x = 244,
		y = 52,
		w = max(240.0, ui.width-548),
		h = max(240.0, ui.height-128),
	}
}

ui_left_rect :: proc(ui: ^UI_State) -> UI_Rect {
	return {12, 52, 220, max(240, ui.height-128)}
}

ui_right_rect :: proc(ui: ^UI_State) -> UI_Rect {
	return {ui.width-292, 52, 280, max(240, ui.height-128)}
}

ui_action_bar_rect :: proc(ui: ^UI_State) -> UI_Rect {
	return {12, ui.height-64, ui.width-24, 52}
}

ui_section_slider_rect :: proc(ui: ^UI_State) -> UI_Rect {
	return {20, 306, 204, 24}
}

ui_help_modal_rect :: proc(ui: ^UI_State) -> UI_Rect {
	width := min(540.0, ui.width-48)
	return {ui.width/2-width/2, 24, width, min(340.0, ui.height-48)}
}

ui_settings_modal_rect :: proc(ui: ^UI_State) -> UI_Rect {
	width := min(420.0, ui.width-48)
	height := 260.0
	return {
		ui.width/2-width/2,
		24,
		width,
		min(height, ui.height-48),
	}
}

ui_evidence_available :: proc(view: ^UI_Evidence_View) -> bool {
	return view != nil &&
		view.replay != nil &&
		len(view.replay.root.stages) > 0 &&
		len(view.replay.root.stages) == len(view.replay.stage_manifests)
}

ui_evidence_modal_rect :: proc(ui: ^UI_State) -> UI_Rect {
	width := min(900.0, ui.width-48)
	height := min(600.0, ui.height-96)
	return {
		ui.width/2-width/2,
		24,
		width,
		min(height, ui.height-48),
	}
}

ui_evidence_visible_stages :: proc(ui: ^UI_State) -> int {
	modal := ui_evidence_modal_rect(ui)
	return max(1, int((modal.h-126)/30))
}

ui_evidence_stage_action :: proc(index: int) -> UI_Action {
	return UI_Action(u64(UI_Action.Evidence_Stage_Base)+u64(index))
}

ui_evidence_stage_action_index :: proc(
	action: UI_Action,
	stage_count: int,
) -> (int, bool) {
	id := u64(action)
	base := u64(UI_Action.Evidence_Stage_Base)
	if id < base || id-base >= u64(stage_count) {return 0, false}
	return int(id-base), true
}

ui_add_control :: proc(
	ui: ^UI_State,
	name, label: string,
	rect: UI_Rect,
	action: UI_Action,
	enabled := true,
	role: i32 = 0,
	selected := false,
) {
	when ODIN_DEBUG {
		assert(rect.w > 0 && rect.h > 0, "UI controls must have visible rectangles")
		for control in ui.controls {
			assert(control.id != u64(action), "UI control identifiers must be unique")
			assert(control.name != name, "UI control names must be unique")
		}
	}
	append(
		&ui.controls,
		UI_Control{
			id = u64(action),
			name = name,
			label = label,
			rect = rect,
			action = action,
			enabled = enabled,
			role = role,
			selected = selected,
		},
	)
}

ui_build_controls :: proc(
	ui: ^UI_State,
	evidence_view: ^UI_Evidence_View = nil,
) {
	clear(&ui.controls)
	ui_add_control(ui, "window close", "close window", {ui.width-33, 12, 21, 16}, .Window_Close)
	ui_add_control(ui, "window minimize", "minimize window", {ui.width-75, 12, 21, 16}, .Window_Minimize)
	ui_add_control(ui, "window zoom", "zoom window", {ui.width-54, 12, 21, 16}, .Window_Zoom)
	if ui.help_open {
		modal := ui_help_modal_rect(ui)
		ui_add_control(ui, "help scrim", "close viewer help", {0, 0, ui.width, ui.height}, .Dismiss_Help)
		ui_add_control(ui, "help surface", "viewer help", modal, .Modal_Surface)
		ui_add_control(
			ui,
			"help close",
			"01 close viewer help",
			{modal.x+modal.w-132, modal.y+modal.h-54, 112, 36},
			.Close_Help,
		)
		return
	}
	if ui.evidence_open && ui_evidence_available(evidence_view) {
		modal := ui_evidence_modal_rect(ui)
		ui_add_control(
			ui,
			"evidence scrim",
			"close evidence inspector",
			{0, 0, ui.width, ui.height},
			.Dismiss_Evidence,
		)
		ui_add_control(
			ui,
			"evidence surface",
			"evidence inspector",
			modal,
			.Modal_Surface,
		)
		stage_count := len(evidence_view.replay.root.stages)
		if ui.evidence_stage_index < 0 ||
		   ui.evidence_stage_index >= stage_count {
			ui.evidence_stage_index = 0
		}
		visible := ui_evidence_visible_stages(ui)
		ui.evidence_scroll = clamp(ui.evidence_scroll, 0, max(0, stage_count-visible))
		for stage, stage_index in evidence_view.replay.root.stages {
			if stage_index < ui.evidence_scroll || stage_index >= ui.evidence_scroll+visible {continue}
			ui_add_control(
				ui,
				stage.stage.name,
				fmt.tprintf(
					"stage %02d %s",
					stage.ordinal,
					stage.stage.name,
				),
				{
					modal.x+20,
					modal.y+72+f64(stage_index-ui.evidence_scroll)*30,
					270,
					28,
				},
				ui_evidence_stage_action(stage_index),
				true,
				1,
				stage_index == ui.evidence_stage_index,
			)
		}
		ui_add_control(
			ui,
			"evidence close",
			"1 close evidence inspector",
			{modal.x+modal.w-132, modal.y+modal.h-48, 112, 32},
			.Close_Evidence,
		)
		return
	}
	if ui.settings_open {
		modal := ui_settings_modal_rect(ui)
		ui_add_control(
			ui,
			"settings scrim",
			"close settings",
			{0, 0, ui.width, ui.height},
			.Dismiss_Settings,
		)
		ui_add_control(
			ui,
			"settings surface",
			"settings",
			modal,
			.Modal_Surface,
		)
		ui_add_control(
			ui,
			"font smaller",
			"decrease font size",
			{modal.x+24, modal.y+96, 48, 40},
			.Font_Decrease,
			ui.font_size > FONT_SIZE_MIN,
		)
		ui_add_control(
			ui,
			"font larger",
			"increase font size",
			{modal.x+82, modal.y+96, 48, 40},
			.Font_Increase,
			ui.font_size < FONT_SIZE_MAX,
		)
		ui_add_control(
			ui,
			"settings close",
			"close settings",
			{modal.x+modal.w-120, modal.y+modal.h-52, 96, 36},
			.Close_Settings,
		)
		return
	}
	ui_add_control(
		ui,
		"theme",
		"switch to light theme" if ui.dark else "switch to dark theme",
		{ui.width-255, 5, 74, 30},
		.Toggle_Theme,
	)
	ui_add_control(ui, "help", "viewer help", {ui.width-174, 5, 87, 30}, .Show_Help)
	ui_add_control(
		ui,
		"settings",
		"open settings",
		{ui.width-359, 5, 97, 30},
		.Open_Settings,
	)

	rows := [3]struct {
		name, label: string,
		action: UI_Action,
	}{
		{"model benchy", "load 3D Benchy", .Select_Benchy},
		{"model all in one", "load all in one printer test", .Select_All_In_One},
		{"model bunny", "load Stanford Bunny", .Select_Bunny},
	}
	for row, index in rows {
		ui_add_control(
			ui,
			row.name,
			row.label,
			{20, f64(86+index*48), 204, 40},
			row.action,
			true,
			1,
			index == ui.selected_model,
		)
	}

	viewport := ui_viewport_rect(ui)
	ui_add_control(ui, "lay on face", "Lay on face", {viewport.x+204, viewport.y+12, 126, 30}, .Lay_On_Face, true, 1, ui.lay_on_face)
	ui_add_control(
		ui,
		"frame mesh",
		"frame the complete mesh",
		{viewport.x+12, viewport.y+12, 78, 30},
		.Frame_Mesh,
	)
	ui_add_control(
		ui,
		"wireframe",
		"toggle mesh wireframe",
		{viewport.x+98, viewport.y+12, 98, 30},
		.Toggle_Wireframe,
		true, 1, ui.wireframe,
	)
	ui_add_control(
		ui,
		"section enabled",
		"toggle layer section",
		{20, 258, 204, 36},
		.Toggle_Section,
		ui.section_max > 0,
	)
	ui_add_control(
		ui,
		"section height",
		"layer section height",
		ui_section_slider_rect(ui),
		.Section_Height,
		ui.section_max > 0,
	)

	names := [6]string{
		"action open",
		"action slice",
		"action cancel",
		"action capture",
		"action compare",
		"action export",
	}
	accessibility_labels := [6]string{
		"01 open",
		"02 slice",
		"03 cancel",
		"04 capture",
		"05 compare",
		"06 export",
	}
	actions := [6]UI_Action{.Open, .Slice, .Cancel, .Capture, .Compare, .Export}
	bar := ui_action_bar_rect(ui)
	button_labels := [6]string{"1  Open", "2  Slice", "3  Cancel", "4  Capture", "5  Compare", "6  Export"}
	font := ui_font("Inter-Regular", BASE_FONT_SIZE)
	assert(font != nil)
	defer CFRelease(font)
	x := bar.x
	for index in 0..<6 {
		run := ui_text_run(font, button_labels[index])
		assert(run.line != nil)
		width := math.ceil(run.advance)+28
		CFRelease(run.line)
		ui_add_control(
			ui, names[index], accessibility_labels[index],
			{x, bar.y+8, width, 32}, actions[index], index == 0,
		)
		x += width+10.5
	}
}

ui_hit_test :: proc(ui: ^UI_State, x, y: f64) -> u64 {
	for index := len(ui.controls)-1; index >= 0; index -= 1 {
		control := ui.controls[index]
		if control.enabled && ui_contains(control.rect, x, y) {
			return control.id
		}
	}
	return 0
}

ui_begin_flash :: proc(ui: ^UI_State) {
	targets := make([dynamic]flash.Target, context.temp_allocator)
	for control in ui.controls {
		if !control.enabled || control.action == .Modal_Surface ||
		   control.action == .Dismiss_Help || control.action == .Dismiss_Evidence ||
		   control.action == .Dismiss_Settings {continue}
		append(
			&targets,
			flash.Target{
				id = flash.Target_ID(control.id),
				label = control.name,
				rect = {
					control.rect.x,
					control.rect.y,
					control.rect.w,
					control.rect.h,
				},
				anchor = .Top_Left,
			},
		)
	}
	_ = flash.begin(
		&ui.flash_state,
		targets[:],
		{
			y_axis = .Down,
			minimum_shortcut_length = 2,
			maximum_shortcut_length = 3,
		},
	)
}

ui_add_rect :: proc(
	vertices: ^[dynamic]Solid_Vertex,
	ui: ^UI_State,
	rect: UI_Rect,
	color: Vec4,
) {
	x0 := f32(rect.x/ui.width*2-1)
	x1 := f32((rect.x+rect.w)/ui.width*2-1)
	y0 := f32(1-rect.y/ui.height*2)
	y1 := f32(1-(rect.y+rect.h)/ui.height*2)
	a := Solid_Vertex{position = {x0, y0}, color = color}
	b := Solid_Vertex{position = {x1, y0}, color = color}
	c := Solid_Vertex{position = {x1, y1}, color = color}
	d := Solid_Vertex{position = {x0, y1}, color = color}
	append(vertices, a, b, c, a, c, d)
}

ui_add_border :: proc(
	vertices: ^[dynamic]Solid_Vertex,
	ui: ^UI_State,
	rect: UI_Rect,
	color: Vec4,
	width := 1.0,
) {
	ui_add_rect(vertices, ui, {rect.x, rect.y, rect.w, width}, color)
	ui_add_rect(
		vertices,
		ui,
		{rect.x, rect.y+rect.h-width, rect.w, width},
		color,
	)
	ui_add_rect(vertices, ui, {rect.x, rect.y, width, rect.h}, color)
	ui_add_rect(
		vertices,
		ui,
		{rect.x+rect.w-width, rect.y, width, rect.h},
		color,
	)
}

ui_add_round_rect :: proc(
	vertices: ^[dynamic]Solid_Vertex,
	ui: ^UI_State,
	rect: UI_Rect,
	radius: f64,
	color: Vec4,
) {
	r := min(radius, min(rect.w, rect.h)/2)
	if r <= 0 {return}
	ui_add_rect(vertices, ui, {rect.x+r, rect.y, rect.w-2*r, rect.h}, color)
	ui_add_rect(vertices, ui, {rect.x, rect.y+r, r, rect.h-2*r}, color)
	ui_add_rect(vertices, ui, {rect.x+rect.w-r, rect.y+r, r, rect.h-2*r}, color)
	centers := [4][2]f64{
		{rect.x+r, rect.y+r}, {rect.x+rect.w-r, rect.y+r},
		{rect.x+rect.w-r, rect.y+rect.h-r}, {rect.x+r, rect.y+rect.h-r},
	}
	for center, corner in centers {
		start := math.PI * (1 + f64(corner)/2)
		for segment in 0..<8 {
			a0 := start+f64(segment)*math.PI/16
			a1 := start+f64(segment+1)*math.PI/16
			points := [3][2]f64{center, {center[0]+r*math.cos(a0), center[1]+r*math.sin(a0)}, {center[0]+r*math.cos(a1), center[1]+r*math.sin(a1)}}
			for point in points {
				append(vertices, Solid_Vertex{position = {f32(point[0]/ui.width*2-1), f32(1-point[1]/ui.height*2)}, color = color})
			}
		}
	}
}

ui_add_shadow :: proc(
	vertices: ^[dynamic]Solid_Vertex,
	ui: ^UI_State,
	rect: UI_Rect,
	radius, spread, offset_y: f64,
) {
	for layer := 4; layer > 0; layer -= 1 {
		extent := spread*f64(layer)/4
		shadow := UI_Rect{rect.x-extent, rect.y-extent+offset_y, rect.w+2*extent, rect.h+2*extent}
		ui_add_round_rect(vertices, ui, shadow, radius+extent, {0, 0, 0, 0.035})
	}
}

ui_control_standing :: proc(ui: ^UI_State, control: UI_Control) -> bool {
	return control.enabled && (control.selected || control.id == ui.pressed_id)
}

ui_control_rect :: proc(ui: ^UI_State, action: UI_Action) -> UI_Rect {
	for control in ui.controls {
		if control.action == action {return control.rect}
	}
	return {}
}

ui_control_ink :: proc(ui: ^UI_State, action: UI_Action) -> Vec4 {
	theme := ui_theme(ui)
	for control in ui.controls {
		if control.action != action {continue}
		if !control.enabled {return {0.501961, 0.501961, 0.501961, 1}}
		if action == .Toggle_Section {return theme.text}
		window_control := action == .Window_Close || action == .Window_Minimize || action == .Window_Zoom
		if ui_control_standing(ui, control) || (window_control && control.id == ui.hovered_id) {return theme.canvas}
		break
	}
	return theme.text
}

ui_build_geometry :: proc(
	ui: ^UI_State,
	evidence_view: ^UI_Evidence_View = nil,
) -> [dynamic]Solid_Vertex {
	vertices := make([dynamic]Solid_Vertex, context.temp_allocator)
	theme := ui_theme(ui)
	modal_open := ui.help_open || (ui.evidence_open && ui_evidence_available(evidence_view)) || ui.settings_open
	if modal_open {
		underlay := ui^
		underlay.controls = make([dynamic]UI_Control)
		underlay.help_open = false
		underlay.evidence_open = false
		underlay.settings_open = false
		underlay.hovered_id = 0
		underlay.pressed_id = 0
		ui_build_controls(&underlay)
		base := ui_build_geometry(&underlay)
		append(&vertices, ..base[:])
		delete(underlay.controls)
		modal := ui_settings_modal_rect(ui)
		if ui.help_open {modal = ui_help_modal_rect(ui)}
		if ui.evidence_open && ui_evidence_available(evidence_view) {modal = ui_evidence_modal_rect(ui)}
		ui_add_rect(&vertices, ui, {0, 0, ui.width, ui.height}, {0, 0, 0, 0.8})
		ui_add_shadow(&vertices, ui, modal, 12, 18, 4)
		if ui.dark {
			ui_add_round_rect(&vertices, ui, modal, 12, {0.192, 0.192, 0.192, 1})
			ui_add_round_rect(&vertices, ui, {modal.x+1, modal.y+1, modal.w-2, modal.h-2}, 11, theme.overlay)
		} else {
			ui_add_round_rect(&vertices, ui, modal, 12, theme.overlay)
		}
	} else {
		ui_add_rect(&vertices, ui, {0, 0, ui.width, 40}, theme.header)
		ui_add_rect(&vertices, ui, ui_left_rect(ui), theme.surface)
		ui_add_rect(&vertices, ui, ui_right_rect(ui), theme.surface)
		ui_add_rect(&vertices, ui, ui_action_bar_rect(ui), theme.header)
	}

	for control in ui.controls {
		hovered := control.enabled && control.id == ui.hovered_id
		standing := ui_control_standing(ui, control)
		if control.action == .None || control.action == .Modal_Surface || control.action == .Dismiss_Settings || control.action == .Dismiss_Evidence || control.action == .Dismiss_Help {continue}
		if control.action == .Window_Close || control.action == .Window_Minimize || control.action == .Window_Zoom {
			if hovered || standing {ui_add_rect(&vertices, ui, control.rect, theme.text)}
			continue
		}
		if control.action == .Section_Height {
			track := UI_Rect{control.rect.x+4, control.rect.y+control.rect.h/2-2, control.rect.w-8, 4}
			ui_add_round_rect(&vertices, ui, track, 2, {0.5, 0.5, 0.5, 1})
			fraction := 0.0
			if ui.section_max > 0 {fraction = clamp(f64(ui.section_z/ui.section_max), 0, 1)}
			ui_add_round_rect(&vertices, ui, {track.x, track.y, max(1, track.w*fraction), track.h}, 2, theme.text)
			ui_add_round_rect(&vertices, ui, {track.x+track.w*fraction-6, control.rect.y+6, 12, 12}, 6, theme.text)
			continue
		}
		if control.action == .Toggle_Section {
			track := UI_Rect{control.rect.x+8, control.rect.y+11, 25, 14}
			track_color := Vec4{0.5, 0.5, 0.5, 1}
			if ui.section_enabled && control.enabled {track_color = theme.text}
			ui_add_round_rect(&vertices, ui, track, 7, track_color)
			thumb_x := track.x+2
			if ui.section_enabled {thumb_x = track.x+track.w-12}
			ui_add_round_rect(&vertices, ui, {thumb_x, track.y+2, 10, 10}, 5, theme.canvas)
			continue
		}
		menu := control.action == .Select_Benchy || control.action == .Select_All_In_One || control.action == .Select_Bunny
		if _, stage := ui_evidence_stage_action_index(control.action, len(evidence_view.replay.root.stages) if ui_evidence_available(evidence_view) else 0); stage {menu = true}
		rect := UI_Rect{control.rect.x+3, control.rect.y+4, control.rect.w-6, control.rect.h-8}
		if rect.w <= 0 || rect.h <= 0 {continue}
		fill := theme.raised
		if hovered {fill = {0.87, 0.87, 0.87, 1} if !ui.dark else {0.24, 0.24, 0.24, 1}}
		if standing {fill = theme.text}
		if menu && !hovered && !standing {continue}
		if !menu {ui_add_shadow(&vertices, ui, rect, 6, 4, 1)}
		ui_add_round_rect(&vertices, ui, rect, 6, fill)
		if !menu && !standing {
			highlight_alpha := f32(0.14) if ui.dark else f32(0.9)
			ui_add_rect(&vertices, ui, {rect.x+6, rect.y+1, max(0, rect.w-12), 0.5}, {1, 1, 1, highlight_alpha})
		}
	}
	for hint in flash.visible_hints(&ui.flash_state) {
		width := max(16.0, 8.0+8.0*f64(len(hint.label)))
		rect := UI_Rect{hint.target.rect.x+2, hint.target.rect.y+2, width, 18}
		rect.x = min(rect.x, ui.width-rect.w)
		rect.y = min(rect.y, ui.height-rect.h)
		background := FLASH_SELECTED_BG if hint.selected else FLASH_BG
		border := FLASH_SELECTED_BORDER if hint.selected else FLASH_BORDER
		ui_add_rect(&vertices, ui, rect, background)
		ui_add_border(&vertices, ui, rect, border)
		if hint.selected {ui_add_border(&vertices, ui, {hint.target.rect.x, hint.target.rect.y, hint.target.rect.w, hint.target.rect.h}, FLASH_SELECTED_BORDER)}
	}
	return vertices
}

Text_Run :: struct {
	line: rawptr,
	advance, ascent, descent, leading: f64,
}

ui_cf_string :: proc(text: string) -> rawptr {
	if len(text) == 0 {return nil}
	bytes := transmute([]u8)text
	return CFStringCreateWithBytes(
		nil,
		raw_data(bytes),
		len(bytes),
		0x08000100,
		false,
	)
}

ui_text_run :: proc(font: rawptr, text: string, tracking := f64(0)) -> Text_Run {
	string_ref := ui_cf_string(text)
	if string_ref == nil {return {}}
	defer CFRelease(string_ref)
	attributed := CFAttributedStringCreateMutable(nil, 0)
	if attributed == nil {return {}}
	defer CFRelease(attributed)
	CFAttributedStringReplaceString(attributed, {0, 0}, string_ref)
	range := CF.Range{0, CF.Index(CFStringGetLength(string_ref))}
	CFAttributedStringSetAttribute(
		attributed,
		range,
		kCTFontAttributeName,
		font,
	)
	CFAttributedStringSetAttribute(
		attributed,
		range,
		kCTForegroundColorFromContextAttributeName,
		kCFBooleanTrue,
	)
	if tracking != 0 {
		value := tracking
		number := CFNumberCreate(nil, 6, &value)
		assert(number != nil)
		CFAttributedStringSetAttribute(attributed, range, kCTKernAttributeName, number)
		CFRelease(number)
	}
	result: Text_Run
	result.line = CTLineCreateWithAttributedString(attributed)
	if result.line != nil {
		result.advance = CTLineGetTypographicBounds(
			result.line,
			&result.ascent,
			&result.descent,
			&result.leading,
		)
	}
	return result
}

Text_Alignment :: enum {Start, Center, End}

ui_cg_rect :: proc(ui: ^UI_State, rect: UI_Rect) -> NS_Rect {
	scale := ui.ui_scale*ui.scale
	return {
		{rect.x*scale, (ui.height*ui.ui_scale-(rect.y+rect.h)*ui.ui_scale)*ui.scale},
		{rect.w*scale, rect.h*scale},
	}
}

ui_draw_text :: proc(
	ctx, font: rawptr,
	ui: ^UI_State,
	text: string,
	rect: UI_Rect,
	color: Vec4,
	inset := 8.0,
	alignment := Text_Alignment.Start,
	tracked := false,
) {
	run := ui_text_run(font, text, -0.8*ui.scale if tracked else 0)
	if run.line == nil {return}
	defer CFRelease(run.line)
	cg_rect := ui_cg_rect(ui, rect)
	CGContextSaveGState(ctx)
	CGContextClipToRect(ctx, cg_rect)
	CGContextSetRGBFillColor(
		ctx,
		f64(color.x),
		f64(color.y),
		f64(color.z),
		f64(color.w),
	)
	inset_scaled := inset*ui.ui_scale*ui.scale
	x := cg_rect.origin.x+inset_scaled
	switch alignment {
	case .Center:
		x = cg_rect.origin.x+(cg_rect.size.width-run.advance)/2
	case .End:
		x = cg_rect.origin.x+cg_rect.size.width-inset_scaled-run.advance
	case .Start:
	}
	y := cg_rect.origin.y+
		(cg_rect.size.height-(run.ascent+run.descent))/2+
		run.descent
	CGContextSetTextPosition(ctx, x, y)
	CTLineDraw(run.line, ctx)
	CGContextRestoreGState(ctx)
}

UI_INTER_FONT :: #load("../resources/fonts/Inter-Regular.woff2")
UI_MONO_FONT :: #load("../resources/fonts/JetBrainsMono-Regular.woff2")
ui_fonts_registered: bool

ui_register_fonts :: proc() {
	if ui_fonts_registered {return}
	for data in ([2][]byte{UI_INTER_FONT, UI_MONO_FONT}) {
		cf_data := CFDataCreate(nil, raw_data(data), len(data))
		assert(cf_data != nil)
		provider := CGDataProviderCreateWithCFData(cf_data)
		assert(provider != nil)
		font := CGFontCreateWithDataProvider(provider)
		assert(font != nil)
		error: rawptr
		registered := CTFontManagerRegisterGraphicsFont(font, &error)
		if error != nil {CFRelease(error)}
		CGFontRelease(font)
		CGDataProviderRelease(provider)
		CFRelease(cf_data)
		assert(registered, "embedded font must register")
	}
	ui_fonts_registered = true
}

ui_font :: proc(name: string, size: f64) -> rawptr {
	ui_register_fonts()
	font_name := ui_cf_string(name)
	assert(font_name != nil)
	defer CFRelease(font_name)
	return CTFontCreateWithName(font_name, size, nil)
}

ui_draw_flash_hint_text :: proc(
	ctx, font: rawptr,
	ui: ^UI_State,
) {
	for hint in flash.visible_hints(&ui.flash_state) {
		width := max(16.0, 8.0+8.0*f64(len(hint.label)))
		rect := UI_Rect{
			hint.target.rect.x+2,
			hint.target.rect.y+2,
			width,
			18,
		}
		rect.x = min(rect.x, ui.width-rect.w)
		rect.y = min(rect.y, ui.height-rect.h)
		ui_draw_text(
			ctx,
			font,
			ui,
			hint.label,
			rect,
			FLASH_FG,
			0,
			.Center,
		)
	}
}

ui_evidence_stage_totals :: proc(
	manifest: evidence.Evidence_Manifest,
) -> (item_count, byte_count: u64) {
	for primitive in manifest.primitives {
		item_count += primitive.item_count
		byte_count += primitive.byte_count
	}
	for render in manifest.renders {
		item_count += render.item_count
		byte_count += render.byte_count
	}
	return
}

ui_evidence_graph_state :: proc(
	stage_name: string,
	replay: ^evidence.Evidence_Bundle_Replay,
) -> string {
	if replay == nil {return "MANIFEST RETAINED"}
	switch stage_name {
	case "schedule-layers":
		if replay.layer_schedule_loaded {
			return "LAYER-SCHEDULE GRAPH RETAINED"
		}
	case "build-acceleration":
		if replay.layer_spans_loaded {
			return "LAYER-SPAN GRAPH RETAINED"
		}
	case "intersect":
		if replay.intersections_loaded &&
		   replay.planar_ownership_loaded &&
		   replay.snapped_loaded {
			return "INTERSECTION + OWNERSHIP + SNAPPED GRAPHS RETAINED"
		}
		if replay.intersections_loaded &&
		   replay.planar_ownership_loaded {
			return "INTERSECTION + OWNERSHIP GRAPHS RETAINED"
		}
		if replay.planar_ownership_loaded &&
		   replay.snapped_loaded {
			return "OWNERSHIP + SNAPPED GRAPHS RETAINED"
		}
		if replay.intersections_loaded && replay.snapped_loaded {
			return "INTERSECTION + SNAPPED GRAPHS RETAINED"
		}
		if replay.planar_ownership_loaded {
			return "PLANAR-OWNERSHIP GRAPH RETAINED"
		}
		if replay.snapped_loaded {
			return "SNAPPED-SEGMENT GRAPH RETAINED"
		}
		if replay.intersections_loaded {
			return "INTERSECTION GRAPH RETAINED"
		}
	case "reconstruct-topology":
		if replay.topology_loaded {return "TOPOLOGY GRAPH RETAINED"}
	case "calculate-regions":
		if replay.regions_loaded {return "REGION GRAPH RETAINED"}
	case "generate-features":
		if replay.skins_loaded &&
		   replay.perimeters_loaded &&
		   replay.infill_loaded &&
		   replay.unified_sources_loaded {
			return "SURFACE + SKIN + PERIMETER + INFILL + FEATURE SOURCE GRAPHS RETAINED"
		}
		if replay.skins_loaded &&
		   replay.perimeters_loaded &&
		   replay.infill_loaded {
			return "SURFACE + SKIN + PERIMETER + INFILL GRAPHS RETAINED"
		}
		if replay.skins_loaded &&
		   replay.perimeters_loaded &&
		   replay.unified_sources_loaded {
			return "SURFACE + SKIN + PERIMETER + FEATURE SOURCE GRAPHS RETAINED"
		}
		if replay.skins_loaded &&
		   replay.infill_loaded &&
		   replay.unified_sources_loaded {
			return "SURFACE + SKIN + INFILL + FEATURE SOURCE GRAPHS RETAINED"
		}
		if replay.skins_loaded && replay.perimeters_loaded {
			return "SURFACE + SKIN + PERIMETER GRAPHS RETAINED"
		}
		if replay.skins_loaded && replay.infill_loaded {
			return "SURFACE + SKIN + INFILL GRAPHS RETAINED"
		}
		if replay.skins_loaded && replay.unified_sources_loaded {
			return "SURFACE + SKIN + FEATURE SOURCE GRAPHS RETAINED"
		}
		if replay.skins_loaded {
			return "SURFACE + SKIN GRAPHS RETAINED"
		}
		if replay.surfaces_loaded &&
		   replay.perimeters_loaded &&
		   replay.infill_loaded &&
		   replay.unified_sources_loaded {
			return "SURFACE + PERIMETER + INFILL + FEATURE SOURCE GRAPHS RETAINED"
		}
		if replay.surfaces_loaded &&
		   replay.perimeters_loaded &&
		   replay.infill_loaded {
			return "SURFACE + PERIMETER + INFILL GRAPHS RETAINED"
		}
		if replay.surfaces_loaded &&
		   replay.perimeters_loaded &&
		   replay.unified_sources_loaded {
			return "SURFACE + PERIMETER + FEATURE SOURCE GRAPHS RETAINED"
		}
		if replay.surfaces_loaded &&
		   replay.infill_loaded &&
		   replay.unified_sources_loaded {
			return "SURFACE + INFILL + FEATURE SOURCE GRAPHS RETAINED"
		}
		if replay.surfaces_loaded && replay.perimeters_loaded {
			return "SURFACE + PERIMETER GRAPHS RETAINED"
		}
		if replay.surfaces_loaded && replay.infill_loaded {
			return "SURFACE + INFILL GRAPHS RETAINED"
		}
		if replay.surfaces_loaded && replay.unified_sources_loaded {
			return "SURFACE + FEATURE SOURCE GRAPHS RETAINED"
		}
		if replay.surfaces_loaded {return "SURFACE GRAPH RETAINED"}
		if replay.perimeters_loaded &&
		   replay.infill_loaded &&
		   replay.unified_sources_loaded {
			return "PERIMETER + INFILL + FEATURE SOURCE GRAPHS RETAINED"
		}
		if replay.perimeters_loaded && replay.infill_loaded {
			return "PERIMETER + INFILL GRAPHS RETAINED"
		}
		if replay.perimeters_loaded && replay.unified_sources_loaded {
			return "PERIMETER + FEATURE SOURCE GRAPHS RETAINED"
		}
		if replay.infill_loaded && replay.unified_sources_loaded {
			return "INFILL + FEATURE SOURCE GRAPHS RETAINED"
		}
		if replay.perimeters_loaded {
			return "PERIMETER GRAPH RETAINED"
		}
		if replay.infill_loaded {return "INFILL GRAPH RETAINED"}
		if replay.unified_sources_loaded {
			return "FEATURE SOURCE GRAPH RETAINED"
		}
	case "plan-paths":
		if replay.unified_plan_loaded &&
		   replay.extrusion_loaded &&
		   replay.motion_plan_loaded {
			return "UNIFIED PATH + EXTRUSION + MOTION GRAPHS RETAINED"
		}
		if replay.unified_plan_loaded && replay.extrusion_loaded {
			return "UNIFIED PATH + EXTRUSION GRAPHS RETAINED"
		}
		if replay.unified_plan_loaded && replay.motion_plan_loaded {
			return "UNIFIED PATH + MOTION GRAPHS RETAINED"
		}
		if replay.unified_plan_loaded {
			return "UNIFIED PATH-PLAN GRAPH RETAINED"
		}
		if replay.path_plan_loaded &&
		   replay.extrusion_loaded &&
		   replay.motion_plan_loaded {
			return "PATH + EXTRUSION + MOTION GRAPHS RETAINED"
		}
		if replay.path_plan_loaded && replay.extrusion_loaded {
			return "PATH + EXTRUSION GRAPHS RETAINED"
		}
		if replay.path_plan_loaded && replay.motion_plan_loaded {
			return "PATH + MOTION GRAPHS RETAINED"
		}
		if replay.extrusion_loaded && replay.motion_plan_loaded {
			return "EXTRUSION + MOTION GRAPHS RETAINED"
		}
		if replay.path_plan_loaded {return "PATH-PLAN GRAPH RETAINED"}
		if replay.extrusion_loaded {return "EXTRUSION GRAPH RETAINED"}
		if replay.motion_plan_loaded {return "MOTION GRAPH RETAINED"}
	case "emit-gcode":
		if replay.marlin_loaded {return "G-CODE GRAPH RETAINED"}
	case:
	}
	return "MANIFEST RETAINED"
}

ui_draw_evidence_overlay :: proc(
	ctx, font, mono: rawptr,
	ui: ^UI_State,
	view: ^UI_Evidence_View,
) {
	if !ui_evidence_available(view) {return}
	modal := ui_evidence_modal_rect(ui)
	replay := view.replay
	selected_index := ui.evidence_stage_index
	if selected_index < 0 || selected_index >= len(replay.root.stages) {
		selected_index = 0
	}
	selected := replay.root.stages[selected_index]
	manifest := replay.stage_manifests[selected_index]
	item_count, byte_count := ui_evidence_stage_totals(manifest)
	theme := ui_theme(ui)

	ui_draw_text(
		ctx,
		font,
		ui,
		"EVIDENCE INSPECTOR",
		{modal.x+20, modal.y+12, modal.w-40, 26},
		theme.text,
		0,
	)
	ui_draw_text(
		ctx,
		mono,
		ui,
		fmt.tprintf(
			"%s / %s / %d STAGES",
			filepath.base(view.source),
			view.container,
			len(replay.root.stages),
		),
		{modal.x+20, modal.y+36, modal.w-40, 22},
		theme.muted,
		0, tracked = true,
	)
	ui_draw_text(
		ctx,
		mono,
		ui,
		fmt.tprintf("REQUEST %s", replay.root.request_hash),
		{modal.x+20, modal.y+54, modal.w-40, 20},
		theme.muted,
		0, tracked = true,
	)

	for stage, stage_index in replay.root.stages {
		if stage_index < ui.evidence_scroll || stage_index >= ui.evidence_scroll+ui_evidence_visible_stages(ui) {continue}
		color := ui_control_ink(ui, ui_evidence_stage_action(stage_index))
		ui_draw_text(
			ctx,
			mono,
			ui,
			fmt.tprintf("%02d  %s", stage.ordinal, stage.stage.name),
			{
				modal.x+28,
				modal.y+72+f64(stage_index-ui.evidence_scroll)*30,
				250,
				28,
			},
			color,
			0, tracked = true,
		)
	}

	detail_x := modal.x+316
	detail_width := modal.w-336
	graph_state := ui_evidence_graph_state(selected.stage.name, replay)
	detail_lines := [7]string{
		fmt.tprintf("STAGE      %02d %s", selected.ordinal, selected.stage.name),
		fmt.tprintf(
			"PROVIDER   %s / %s",
			selected.provider.name,
			selected.provider.version,
		),
		fmt.tprintf(
			"SCHEMA     %d / REVISION %d",
			selected.stage.schema_version,
			selected.stage.revision,
		),
		fmt.tprintf(
			"RECORDS    %d PRIMITIVES / %d RENDERS",
			len(manifest.primitives),
			len(manifest.renders),
		),
		fmt.tprintf("ITEMS      %d", item_count),
		fmt.tprintf("BYTES      %d", byte_count),
		graph_state,
	}
	for line, line_index in detail_lines {
		ui_draw_text(
			ctx,
			mono,
			ui,
			line,
			{
				detail_x,
				modal.y+82+f64(line_index)*24,
				detail_width,
				22,
			},
			theme.text,
			0, tracked = true,
		)
	}
	summary_y := modal.y+264
	ui_draw_text(
		ctx,
		font,
		ui,
		"STAGE SUMMARY",
		{detail_x, summary_y, detail_width, 22},
		theme.muted,
		0,
	)
	counter_limit := int((modal.y+modal.h-70-summary_y)/22)
	for counter, counter_index in manifest.summary {
		if counter_index >= counter_limit {break}
		ui_draw_text(
			ctx,
			mono,
			ui,
			fmt.tprintf("%-28s %d", counter.name, counter.value),
			{
				detail_x,
				summary_y+24+f64(counter_index)*22,
				detail_width,
				20,
			},
			theme.text,
			0, tracked = true,
		)
	}
	ui_draw_text(
		ctx,
		font,
		ui,
		"1  CLOSE",
		{modal.x+modal.w-132, modal.y+modal.h-48, 112, 32},
		ui_control_ink(ui, .Close_Evidence),
		0,
		.Center,
	)
	ui_draw_flash_hint_text(ctx, font, ui)
}

ui_draw_settings_overlay :: proc(
	ctx, font, mono: rawptr,
	ui: ^UI_State,
) {
	theme := ui_theme(ui)
	modal := ui_settings_modal_rect(ui)
	ui_draw_text(
		ctx,
		font,
		ui,
		"SETTINGS",
		{modal.x+20, modal.y+14, modal.w-40, 32},
		theme.text,
		0,
	)
	ui_draw_text(
		ctx,
		font,
		ui,
		"FONT SIZE",
		{modal.x+24, modal.y+54, modal.w-48, 24},
		theme.muted,
		0,
	)
	ui_draw_text(
		ctx,
		font,
		ui,
		"−",
		{modal.x+24, modal.y+96, 48, 40},
		ui_control_ink(ui, .Font_Decrease),
		0,
		.Center,
	)
	ui_draw_text(
		ctx,
		font,
		ui,
		"+",
		{modal.x+82, modal.y+96, 48, 40},
		ui_control_ink(ui, .Font_Increase),
		0,
		.Center,
	)
	ui_draw_text(
		ctx,
		mono,
		ui,
		fmt.tprintf("%d PT", ui.font_size),
		{modal.x+142, modal.y+96, modal.w-166, 40},
		theme.text,
		0, tracked = true,
	)
	ui_draw_text(
		ctx,
		font,
		ui,
		"CLOSE",
		{modal.x+modal.w-120, modal.y+modal.h-52, 96, 36},
		ui_control_ink(ui, .Close_Settings),
		0,
		.Center,
	)
}

ui_build_text_overlay :: proc(
	ui: ^UI_State,
	mesh: ^Mesh,
	model_name, status: string,
	evidence_view: ^UI_Evidence_View = nil,
) -> []u8 {
	width := uint(max(1, ui.physical_width*ui.scale))
	height := uint(max(1, ui.physical_height*ui.scale))
	pixels := make([]u8, int(width*height*4))
	space := CGColorSpaceCreateDeviceRGB()
	ctx := CGBitmapContextCreate(
		raw_data(pixels),
		width,
		height,
		8,
		width*4,
		space,
		0x2002,
	)
	CGColorSpaceRelease(space)
	if ctx == nil {return pixels}
	defer CGContextRelease(ctx)
	CGContextClearRect(ctx, {{0, 0}, {f64(width), f64(height)}})
	font := ui_font("Inter-Regular", f64(ui.font_size)*ui.scale)
	if font == nil {return pixels}
	defer CFRelease(font)
	mono := ui_font("JetBrainsMono-Regular", f64(ui.font_size)*ui.scale)
	assert(mono != nil)
	defer CFRelease(mono)
	theme := ui_theme(ui)

	ui := ui
	modal_ui := ui
	modal_open := ui.help_open || ui.settings_open || (ui.evidence_open && ui_evidence_available(evidence_view))
	underlay: UI_State
	defer delete(underlay.controls)
	if modal_open {
		underlay = ui^
		underlay.controls = make([dynamic]UI_Control)
		underlay.help_open = false
		underlay.evidence_open = false
		underlay.settings_open = false
		underlay.hovered_id = 0
		underlay.pressed_id = 0
		ui_build_controls(&underlay)
		ui = &underlay
		CGContextSetAlpha(ctx, 0.2)
	}
	ui_draw_text(ctx, font, ui, "HW SLICER / MESH VIEWER", {12, 0, 360, 40}, theme.text, 0)
	window_labels := [3]string{"[_]", "[+]", "[x]"}
	window_actions := [3]UI_Action{.Window_Minimize, .Window_Zoom, .Window_Close}
	for label, index in window_labels {
		action := window_actions[index]
		ui_draw_text(ctx, mono, ui, label, ui_control_rect(ui, action), ui_control_ink(ui, action), 0, .Center, tracked = true)
	}
	ui_draw_text(
		ctx,
		font,
		ui,
		"DARK" if !ui.dark else "LIGHT",
		{ui.width-255, 5, 74, 30},
		ui_control_ink(ui, .Toggle_Theme),
		0,
		.Center,
	)
	ui_draw_text(
		ctx,
		font,
		ui,
		"SETTINGS",
		{ui.width-359, 5, 97, 30},
		ui_control_ink(ui, .Open_Settings),
		0,
		.Center,
	)
	ui_draw_text(ctx, font, ui, "HELP", ui_control_rect(ui, .Show_Help), ui_control_ink(ui, .Show_Help), 0, .Center)

	ui_draw_text(ctx, font, ui, "REFERENCE MODELS", {20, 58, 190, 24}, theme.muted, 0)
	model_labels := [3]string{"3DBENCHY", "ALL IN ONE TEST", "STANFORD BUNNY"}
	model_actions := [3]UI_Action{.Select_Benchy, .Select_All_In_One, .Select_Bunny}
	for label, index in model_labels {
		color := ui_control_ink(ui, model_actions[index])
		ui_draw_text(
			ctx,
			font,
			ui,
			label,
			{28, f64(86+index*48), 188, 40},
			color,
			0,
		)
	}
	ui_draw_text(ctx, font, ui, "SECTION", {20, 230, 190, 24}, theme.muted, 0)
	ui_draw_text(
		ctx,
		font,
		ui,
		"ENABLED" if ui.section_enabled else "DISABLED",
		{64, 258, 152, 36},
		ui_control_ink(ui, .Toggle_Section),
		0,
	)
	ui_draw_text(
		ctx,
		mono,
		ui,
		fmt.tprintf("Z %.2f MM", ui.section_z),
		{20, 334, 204, 22},
		theme.text,
		0, tracked = true,
	)
	ui_draw_text(
		ctx,
		mono,
		ui,
		fmt.tprintf("%d SEGMENTS", ui.section_segments),
		{20, 358, 204, 22},
		theme.muted,
		0, tracked = true,
	)
	viewport := ui_viewport_rect(ui)
	ui_draw_text(
		ctx,
		font,
		ui,
		"FRAME",
		{viewport.x+12, viewport.y+12, 78, 30},
		ui_control_ink(ui, .Frame_Mesh),
		0,
		.Center,
	)
	ui_draw_text(
		ctx,
		font,
		ui,
		"WIREFRAME",
		{viewport.x+98, viewport.y+12, 98, 30},
		ui_control_ink(ui, .Toggle_Wireframe),
		0,
		.Center,
	)

	ui_draw_text(
		ctx,
		font,
		ui,
		"LAY ON FACE",
		{viewport.x+204, viewport.y+12, 126, 30},
		ui_control_ink(ui, .Lay_On_Face),
		0,
		.Center,
	)
	right := ui_right_rect(ui)
	ui_draw_text(ctx, font, ui, "MESH EVIDENCE", {right.x+12, right.y+8, 240, 28}, theme.muted, 0)
	ui_draw_text(ctx, font, ui, model_name, {right.x+12, right.y+42, 252, 32}, theme.text, 0)
	if mesh != nil && mesh.triangle_count > 0 {
		size := mesh_size(mesh.bounds)
		lines := [5]string{
			fmt.tprintf("TRIANGLES  %d", mesh.triangle_count),
			fmt.tprintf("WIDTH      %.2f mm", size.x),
			fmt.tprintf("DEPTH      %.2f mm", size.y),
			fmt.tprintf("HEIGHT     %.2f mm", size.z),
			"BINARY STL / EXPANDED VERTICES",
		}
		for line, index in lines {
			ui_draw_text(
				ctx,
				mono,
				ui,
				line,
				{right.x+12, right.y+86+f64(index*26), 252, 24},
				theme.text if index < 4 else theme.muted,
				0, tracked = true,
			)
		}
	}
	ui_draw_text(ctx, font, ui, "CAMERA", {right.x+12, right.y+242, 240, 24}, theme.muted, 0)
	camera_lines := [4]string{
		"LEFT DRAG   ORBIT",
		"RIGHT DRAG  PAN",
		"SCROLL      ZOOM",
		"/           FLASH",
	}
	for line, index in camera_lines {
		ui_draw_text(
			ctx,
			font,
			ui,
			line,
			{right.x+12, right.y+270+f64(index*25), 252, 22},
			theme.text,
			0,
		)
	}
	if status != "" {
		ui_draw_text(
			ctx,
			font,
			ui,
			status,
			{right.x+12, right.y+right.h-42, 252, 30},
			theme.text,
			0,
		)
	}

	labels := [6]string{"1  Open", "2  Slice", "3  Cancel", "4  Capture", "5  Compare", "6  Export"}
	actions := [6]UI_Action{.Open, .Slice, .Cancel, .Capture, .Compare, .Export}
	for label, index in labels {
		action := actions[index]
		ui_draw_text(ctx, font, ui, label, ui_control_rect(ui, action), ui_control_ink(ui, action), 0, .Center)
	}

	if modal_open {
		ui = modal_ui
		modal := ui_settings_modal_rect(ui)
		if ui.help_open {modal = ui_help_modal_rect(ui)}
		if ui.evidence_open && ui_evidence_available(evidence_view) {modal = ui_evidence_modal_rect(ui)}
		CGContextClearRect(ctx, ui_cg_rect(ui, modal))
		CGContextSetAlpha(ctx, 1)
		if ui.help_open {
			modal := ui_help_modal_rect(ui)
			ui_draw_text(
				ctx,
				font,
				ui,
				"MESH VIEWER HELP",
				{modal.x+20, modal.y+14, 440, 32},
				theme.text,
				0,
			)
			help_lines := [7]string{
				"LEFT DRAG rotates the camera around the mesh target.",
				"RIGHT OR MIDDLE DRAG translates the camera target.",
				"SCROLL changes camera distance.",
				"FRAME recalculates the target and distance from the placed model bounds.",
				"WIREFRAME changes Metal triangle fill mode.",
				"OPEN accepts exact STL files and validated evidence bundles.",
				"SECTION drags a cutting plane; its contour draws over the mesh.",
			}
			for line, index in help_lines {
				ui_draw_text(
					ctx,
					font,
					ui,
					line,
					{modal.x+20, modal.y+66+f64(index*30), modal.w-40, 26},
					theme.text,
					0,
				)
			}
			ui_draw_text(
				ctx,
				font,
				ui,
				"01  CLOSE",
				{modal.x+modal.w-132, modal.y+modal.h-54, 112, 36},
				ui_control_ink(ui, .Close_Help),
				0,
				.Center,
			)
			ui_draw_flash_hint_text(ctx, font, ui)
			return pixels
		}
		if ui.evidence_open && ui_evidence_available(evidence_view) {
			ui_draw_evidence_overlay(ctx, font, mono, ui, evidence_view)
			return pixels
		}
		if ui.settings_open {
			ui_draw_settings_overlay(ctx, font, mono, ui)
			return pixels
		}
	}

	ui_draw_flash_hint_text(ctx, font, ui)

	return pixels
}

ui_snapshot_text :: proc(ui: ^UI_State) -> string {
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)
	modal := "none"
	if ui.help_open {
		modal = "help"
	} else if ui.evidence_open {
		modal = "evidence"
	}
	fmt.sbprintf(
		&builder,
		"controls\t%d\ttheme\t%s\tmodal\t%s\tselected_stage\t%d\n",
		len(ui.controls),
		"dark" if ui.dark else "light",
		modal,
		ui.evidence_stage_index,
	)
	for control in ui.controls {
		fmt.sbprintf(
			&builder,
			"%d\t%s\t%s\t%.0f\t%.0f\t%.0f\t%.0f\t%s\t%s\n",
			control.id,
			control.name,
			control.label,
			control.rect.x,
			control.rect.y,
			control.rect.w,
			control.rect.h,
			"enabled" if control.enabled else "disabled",
			"selected" if control.selected else "clear",
		)
	}
	return strings.clone(strings.to_string(builder))
}

ui_write_snapshot :: proc(ui: ^UI_State, path: string) -> bool {
	text := ui_snapshot_text(ui)
	defer delete(text)
	return os.write_entire_file(path, transmute([]u8)text) == nil
}
