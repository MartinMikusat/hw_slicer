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
	CGContextFillRect :: proc "c" (ctx: rawptr, rect: NS_Rect) ---
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
	Panel_Models,
	Panel_Section,
	Panel_Mesh,
	Evidence_Stages,
	Evidence_Details,
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
	raised  = {0.141255, 0.141255, 0.141255, 1},
	control = {0.141255, 0.141255, 0.141255, 1},
	overlay = {0.090196, 0.090196, 0.090196, 1},
	text    = {0.819608, 0.819608, 0.819608, 1},
	muted   = {0.819608, 0.819608, 0.819608, 1},
}

COLOR_COFFEE :: Vec4{0.698039, 0.490196, 0.341176, 1}
COLOR_SECTION :: Vec4{0.980392, 0.427451, 0.121569, 1}

UI_Panel :: enum {Models, Section, Mesh}
UI_Evidence_Pane :: enum {Stages, Details}

UI_State :: struct {
	controls: [dynamic]UI_Control,
	flash_state: flash.State,
	help_open: bool,
	evidence_open: bool,
	evidence_stage_index: int,
	evidence_scroll: int,
	evidence_detail_scroll: int,
	evidence_pane: UI_Evidence_Pane,
	width: f64,
	height: f64,
	scale: f64,
	dark: bool,
	selected_model: int,
	panel: UI_Panel,
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
	focused_id: u64,
	hovered_id: u64,
	pointer_x, pointer_y: f64,
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

ui_character_widths: [FONT_SIZE_MAX+1]f64

ui_character_width :: proc(ui: ^UI_State) -> f64 {
	size := settings_font_size_clamped(ui.font_size)
	if ui_character_widths[size] == 0 {
		font := ui_font("JetBrainsMono-Regular", f64(size))
		assert(font != nil)
		run := ui_text_run(font, "0", -0.8)
		assert(run.line != nil)
		ui_character_widths[size] = math.ceil(run.advance)/(f64(size)/BASE_FONT_SIZE)
		CFRelease(run.line)
		CFRelease(font)
	}
	return ui_character_widths[size]
}

ui_action_bar_rect :: proc(ui: ^UI_State) -> UI_Rect {
	return {12, ui.height-64, max(1.0, ui.width-24), 52}
}

ui_compact :: proc(ui: ^UI_State) -> bool {
	return ui.width < 800 || ui_action_bar_rect(ui).y < 484
}

ui_viewport_rect :: proc(ui: ^UI_State) -> UI_Rect {
	bar := ui_action_bar_rect(ui)
	if ui_compact(ui) {return {196, 52, max(1, ui.width-208), max(1, bar.y-64)}}
	return {
		x = 244,
		y = 52,
		w = max(240.0, ui.width-548),
		h = max(1.0, bar.y-64),
	}
}

ui_left_rect :: proc(ui: ^UI_State) -> UI_Rect {
	bar := ui_action_bar_rect(ui)
	return {12, 52, 172 if ui_compact(ui) else 220, max(1, bar.y-64)}
}

ui_right_rect :: proc(ui: ^UI_State) -> UI_Rect {
	bar := ui_action_bar_rect(ui)
	if ui_compact(ui) {return ui_left_rect(ui)}
	return {ui.width-292, 52, 280, max(1, bar.y-64)}
}

ui_section_slider_rect :: proc(ui: ^UI_State) -> UI_Rect {
	if ui_compact(ui) {return {20, 116, 156, 20}}
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

ui_evidence_compact :: proc(ui: ^UI_State) -> bool {
	modal := ui_evidence_modal_rect(ui)
	return modal.w < 700 || modal.h < 340
}

ui_evidence_visible_stages :: proc(ui: ^UI_State) -> int {
	modal := ui_evidence_modal_rect(ui)
	if ui_evidence_compact(ui) {return max(1, int((modal.h-136)/24))}
	return max(1, int((modal.h-126)/30))
}

ui_evidence_detail_rect :: proc(ui: ^UI_State) -> UI_Rect {
	modal := ui_evidence_modal_rect(ui)
	if ui_evidence_compact(ui) {return {modal.x+20, modal.y+80, modal.w-40, modal.h-136}}
	return {modal.x+316, modal.y+80, modal.w-336, modal.h-136}
}

ui_evidence_detail_rows :: proc(ui: ^UI_State) -> int {
	return max(1, int(ui_evidence_detail_rect(ui).h/20))
}

UI_Evidence_Line :: struct {
	label: string,
	value: string,
	value_offset: f64,
	value_mono: bool,
}

ui_evidence_detail_field :: proc(
	lines: ^[dynamic]UI_Evidence_Line,
	label, value: string,
	label_font, value_font: rawptr,
	width, tracking: f64,
	value_mono: bool,
) {
	label := label
	label_width := f64(90)
	label_advance := f64(0)
	if label != "" {
		label_run := ui_text_run(label_font, label)
		assert(label_run.line != nil)
		label_advance = label_run.advance
		CFRelease(label_run.line)
	} else {
		label_width = 0
	}
	if value == "" {
		wrapped := make([dynamic]string, context.temp_allocator)
		ui_wrap_text(&wrapped, label, label_font, width, 0)
		for part in wrapped {append(lines, UI_Evidence_Line{label = part})}
		return
	}
	if label_advance > label_width-7 {
		wrapped := make([dynamic]string, context.temp_allocator)
		ui_wrap_text(&wrapped, label, label_font, width, 0)
		for part in wrapped {append(lines, UI_Evidence_Line{label = part})}
		label = ""
		label_width = 0
	}
	wrapped := make([dynamic]string, context.temp_allocator)
	ui_wrap_text(&wrapped, value, value_font, width-label_width, tracking)
	for part, index in wrapped {
		append(lines, UI_Evidence_Line{
			label = label if index == 0 else "",
			value = part,
			value_offset = label_width,
			value_mono = value_mono,
		})
	}
}

ui_evidence_detail_lines :: proc(ui: ^UI_State, view: ^UI_Evidence_View) -> [dynamic]UI_Evidence_Line {
	lines := make([dynamic]UI_Evidence_Line, context.temp_allocator)
	if !ui_evidence_available(view) {return lines}
	replay := view.replay
	index := clamp(ui.evidence_stage_index, 0, len(replay.root.stages)-1)
	stage := replay.root.stages[index]
	manifest := replay.stage_manifests[index]
	items, bytes := ui_evidence_stage_totals(manifest)
	fields := [13]struct {label, value: string, mono: bool}{
		{"File", filepath.base(view.source), true},
		{"Container", view.container, false},
		{"Request", replay.root.request_hash, true},
		{"Stage", fmt.tprintf("%02d %s", stage.ordinal, stage.stage.name), true},
		{"Provider", fmt.tprintf("%s / %s", stage.provider.name, stage.provider.version), true},
		{"Schema", fmt.tprintf("%d", stage.stage.schema_version), true},
		{"Revision", fmt.tprintf("%d", stage.stage.revision), true},
		{"Primitives", fmt.tprintf("%d", len(manifest.primitives)), true},
		{"Renders", fmt.tprintf("%d", len(manifest.renders)), true},
		{"Items", fmt.tprintf("%d", items), true},
		{"Bytes", fmt.tprintf("%d", bytes), true},
		{"Graphs", ui_evidence_graph_state(stage.stage.name, replay), false},
		{"Stage summary", "", false},
	}
	label_font := ui_font("Inter-Regular", BASE_FONT_SIZE)
	mono := ui_font("JetBrainsMono-Regular", BASE_FONT_SIZE)
	assert(label_font != nil && mono != nil)
	defer CFRelease(label_font)
	defer CFRelease(mono)
	width := ui_evidence_detail_rect(ui).w
	tracking := -0.8*BASE_FONT_SIZE/f64(ui.font_size)
	for field in fields {
		ui_evidence_detail_field(&lines, field.label, field.value, label_font, mono if field.mono else label_font, width, tracking if field.mono else 0, field.mono)
	}
	for counter in manifest.summary {
		ui_evidence_detail_field(&lines, counter.name, fmt.tprintf("%d", counter.value), label_font, mono, width, tracking, true)
	}
	return lines
}

ui_wrap_text :: proc(
	lines: ^[dynamic]string,
	value: string,
	font: rawptr,
	width, tracking: f64,
) {
	if len(value) == 0 {append(lines, ""); return}
	offsets := make([dynamic]int, context.temp_allocator)
	for _, offset in value {append(&offsets, offset)}
	append(&offsets, len(value))
	start := 0
	for start < len(offsets)-1 {
		low, high := start+1, min(len(offsets)-1, start+max(1, int(width)))
		best := low
		for low <= high {
			middle := (low+high)/2
			run := ui_text_run(font, value[offsets[start]:offsets[middle]], tracking)
			assert(run.line != nil)
			advance := run.advance
			CFRelease(run.line)
			if advance <= width {
				best = middle
				low = middle+1
			} else {
				high = middle-1
			}
		}
		append(lines, value[offsets[start]:offsets[best]])
		start = best
	}
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
	ch := ui_character_width(ui)
	window_width := 3*ch
	ui_add_control(ui, "window close", "close window", {ui.width-12-window_width, 5, window_width, 30}, .Window_Close)
	ui_add_control(ui, "window minimize", "minimize window", {ui.width-12-3*window_width, 5, window_width, 30}, .Window_Minimize)
	ui_add_control(ui, "window zoom", "zoom window", {ui.width-12-2*window_width, 5, window_width, 30}, .Window_Zoom)
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
		compact := ui_evidence_compact(ui)
		if compact {
			ui_add_control(ui, "evidence stages", "evidence stages", {modal.x+20, modal.y+44, 90, 28}, .Evidence_Stages, true, 1, ui.evidence_pane == .Stages)
			ui_add_control(ui, "evidence details", "evidence details", {modal.x+116, modal.y+44, 90, 28}, .Evidence_Details, true, 1, ui.evidence_pane == .Details)
		}
		stage_count := len(evidence_view.replay.root.stages)
		if ui.evidence_stage_index < 0 ||
		   ui.evidence_stage_index >= stage_count {
			ui.evidence_stage_index = 0
		}
		visible := ui_evidence_visible_stages(ui)
		ui.evidence_scroll = clamp(ui.evidence_scroll, 0, max(0, stage_count-visible))
		for stage, stage_index in evidence_view.replay.root.stages {
			if compact && ui.evidence_pane != .Stages {continue}
			if stage_index < ui.evidence_scroll || stage_index >= ui.evidence_scroll+visible {continue}
			rect := UI_Rect{modal.x+20, modal.y+72+f64(stage_index-ui.evidence_scroll)*30, 270, 28}
			if compact {rect = {modal.x+20, modal.y+80+f64(stage_index-ui.evidence_scroll)*24, modal.w-40, 22}}
			ui_add_control(
				ui,
				stage.stage.name,
				stage.stage.name,
				rect,
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

	compact := ui_compact(ui)
	if compact {
		panels := [3]UI_Panel{.Models, .Section, .Mesh}
		panel_names := [3]string{"models panel", "section panel", "mesh panel"}
		panel_labels := [3]string{"Models", "Section", "Mesh"}
		panel_actions := [3]UI_Action{.Panel_Models, .Panel_Section, .Panel_Mesh}
		for panel, index in panels {
			ui_add_control(ui, panel_names[index], panel_labels[index], {12+f64(index)*57, 52, 57, 28}, panel_actions[index], true, 1, ui.panel == panel)
		}
	}
	if !compact || ui.panel == .Models {
		ui_add_control(ui, "action open", "01 open model or evidence", {20, 82, 152, 30}, .Open)
	}

	rows := [3]struct {
		name, label: string,
		action: UI_Action,
	}{
		{"model benchy", "load 3D Benchy", .Select_Benchy},
		{"model all in one", "load all in one printer test", .Select_All_In_One},
		{"model bunny", "load Stanford Bunny", .Select_Bunny},
	}
	for row, index in rows {
		if compact && ui.panel != .Models {continue}
		rect := UI_Rect{20, f64(142+index*30), 204, 28}
		if compact {rect = {16, f64(122+index*30), 164, 28}}
		ui_add_control(
			ui,
			row.name,
			row.label,
			rect,
			row.action,
			true,
			1,
			index == ui.selected_model,
		)
	}

	viewport := ui_viewport_rect(ui)
	lay_rect := UI_Rect{viewport.x+204, viewport.y+12, 126, 30}
	if viewport.w < 342 {lay_rect = {viewport.x+12, viewport.y+46, 126, 30}}
	ui_add_control(ui, "lay on face", "Lay on face", lay_rect, .Lay_On_Face, true, 1, ui.lay_on_face)
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
	if !compact || ui.panel == .Section {
		section_rect := UI_Rect{20, 268, 204, 30}
		if compact {section_rect = {20, 84, 156, 28}}
		ui_add_control(
			ui,
			"section enabled",
			"toggle layer section",
			section_rect,
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

ui_control_accessible :: proc(ui: ^UI_State, control: UI_Control) -> bool {
	#partial switch control.action {
	case .None, .Modal_Surface, .Dismiss_Help, .Dismiss_Evidence, .Dismiss_Settings:
		return false
	case .Window_Close, .Window_Minimize, .Window_Zoom:
		return !ui.settings_open && !ui.help_open && !ui.evidence_open
	case:
		return true
	}
}

ui_control_focusable :: proc(ui: ^UI_State, control: UI_Control) -> bool {
	return control.enabled && ui_control_accessible(ui, control)
}

ui_focus_next :: proc(ui: ^UI_State, reverse: bool) {
	count := len(ui.controls)
	if count == 0 {ui.focused_id = 0; return}
	current := -1
	for control, index in ui.controls {
		if control.id == ui.focused_id && ui_control_focusable(ui, control) {current = index; break}
	}
	step := -1 if reverse else 1
	if current < 0 {current = 0 if reverse else -1}
	for _ in 0..<count {
		current = (current+step+count)%count
		control := ui.controls[current]
		if ui_control_focusable(ui, control) {ui.focused_id = control.id; return}
	}
	ui.focused_id = 0
}

ui_begin_flash :: proc(ui: ^UI_State) {
	targets := make([dynamic]flash.Target, context.temp_allocator)
	for control in ui.controls {
		if !ui_control_focusable(ui, control) {continue}
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

ui_shadow_vertex :: proc(ui: ^UI_State, point: [2]f64, alpha: f32) -> Solid_Vertex {
	return {position = {f32(point[0]/ui.width*2-1), f32(1-point[1]/ui.height*2)}, color = {0, 0, 0, alpha}}
}

ui_shadow_layer :: proc(
	vertices: ^[dynamic]Solid_Vertex,
	ui: ^UI_State,
	rect: UI_Rect,
	radius, blur, offset_y: f64,
	opacity: f32,
) {
	assert(blur > 0 && opacity >= 0 && opacity <= 1)
	rect := rect
	rect.y += offset_y
	r := min(radius, min(rect.w, rect.h)/2)
	if r <= 0 {return}
	ui_add_round_rect(vertices, ui, rect, r, {0, 0, 0, opacity})
	centers := [4][2]f64{
		{rect.x+r, rect.y+r}, {rect.x+rect.w-r, rect.y+r},
		{rect.x+rect.w-r, rect.y+rect.h-r}, {rect.x+r, rect.y+rect.h-r},
	}
	inner, outer: [36][2]f64
	for center, corner in centers {
		for segment in 0..=8 {
			angle := math.PI*(1+f64(corner)/2)+f64(segment)*math.PI/16
			direction := [2]f64{math.cos(angle), math.sin(angle)}
			index := corner*9+segment
			inner[index] = {center[0]+r*direction[0], center[1]+r*direction[1]}
			outer[index] = {center[0]+(r+blur)*direction[0], center[1]+(r+blur)*direction[1]}
		}
	}
	for index in 0..<len(inner) {
		next := (index+1)%len(inner)
		a := ui_shadow_vertex(ui, inner[index], opacity)
		b := ui_shadow_vertex(ui, inner[next], opacity)
		c := ui_shadow_vertex(ui, outer[next], 0)
		d := ui_shadow_vertex(ui, outer[index], 0)
		append(vertices, a, b, c, a, c, d)
	}
}

ui_style_scale :: proc(ui: ^UI_State) -> f64 {
	return f64(ui.font_size)/BASE_FONT_SIZE
}

ui_style_row_height :: proc(ui: ^UI_State) -> f64 {
	return math.ceil(f64(ui.font_size)*1.2)
}

ui_pill_rect :: proc(ui: ^UI_State, hit: UI_Rect) -> UI_Rect {
	scale := ui_style_scale(ui)
	height := min(hit.h, (ui_style_row_height(ui)+6)/scale)
	inset := ui_character_width(ui)/4
	return {hit.x+inset, hit.y+(hit.h-height)/2, hit.w-2*inset, height}
}

ui_pill_highlight :: proc(vertices: ^[dynamic]Solid_Vertex, ui: ^UI_State, rect: UI_Rect, radius: f64, color: Vec4) {
	scale := ui_style_scale(ui)
	r := min(radius, min(rect.w, rect.h)/2)-1/scale
	thickness := 0.75/scale
	if r <= thickness {return}
	ui_add_rect(vertices, ui, {rect.x+radius, rect.y+1/scale, rect.w-2*radius, thickness}, color)
	centers := [2][2]f64{{rect.x+radius, rect.y+radius}, {rect.x+rect.w-radius, rect.y+radius}}
	for center, corner in centers {
		start := math.PI*(1+f64(corner)/2)
		for segment in 0..<8 {
			a0 := start+f64(segment)*math.PI/16
			a1 := start+f64(segment+1)*math.PI/16
			points := [4][2]f64{
				{center[0]+r*math.cos(a0), center[1]+r*math.sin(a0)},
				{center[0]+r*math.cos(a1), center[1]+r*math.sin(a1)},
				{center[0]+(r-thickness)*math.cos(a1), center[1]+(r-thickness)*math.sin(a1)},
				{center[0]+(r-thickness)*math.cos(a0), center[1]+(r-thickness)*math.sin(a0)},
			}
			indices := [6]int{0, 1, 2, 0, 2, 3}
			for index in indices {
				point := points[index]
				append(vertices, Solid_Vertex{position = {f32(point[0]/ui.width*2-1), f32(1-point[1]/ui.height*2)}, color = color})
			}
		}
	}
}

ui_pill_shadow :: proc(vertices: ^[dynamic]Solid_Vertex, ui: ^UI_State, rect: UI_Rect) {
	scale := ui_style_scale(ui)
	row := ui_style_row_height(ui)
	radius := 6/scale
	outer := 5*math.round(row*0.25)
	ui_shadow_layer(vertices, ui, rect, radius, outer/scale, math.round(outer/6)/scale, 0.05)
	ui_shadow_layer(vertices, ui, rect, radius, math.round(row*0.15)/scale, 1/scale, 55.0/255.0)
}

ui_menu_shadow :: proc(vertices: ^[dynamic]Solid_Vertex, ui: ^UI_State, rect: UI_Rect) {
	scale := ui_style_scale(ui)
	blur := math.round(ui_style_row_height(ui)*0.15)/scale
	ui_shadow_layer(vertices, ui, rect, 6/scale, blur, 1/scale, 60.0/255.0)
}

ui_modal_shadow :: proc(vertices: ^[dynamic]Solid_Vertex, ui: ^UI_State, rect: UI_Rect) {
	scale := ui_style_scale(ui)
	row := ui_style_row_height(ui)
	radius := 12/scale
	ui_shadow_layer(vertices, ui, rect, radius, math.round(row*5)/scale, math.round(row)/scale, 0.07)
	ui_shadow_layer(vertices, ui, rect, radius, math.round(row*1.5)/scale, 6/scale, 80.0/255.0)
}

ui_theme_blend :: proc(theme: Theme, amount: f32) -> Vec4 {
	return {
		theme.canvas.x+(theme.text.x-theme.canvas.x)*amount,
		theme.canvas.y+(theme.text.y-theme.canvas.y)*amount,
		theme.canvas.z+(theme.text.z-theme.canvas.z)*amount,
		1,
	}
}

ui_control_standing :: proc(ui: ^UI_State, control: UI_Control) -> bool {
	return control.enabled && (control.selected || control.id == ui.pressed_id || control.id == ui.focused_id)
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
		if action == .Window_Close || action == .Window_Minimize || action == .Window_Zoom {return {0.1, 0.1, 0.1, 1}}
		if ui_control_standing(ui, control) {return theme.canvas}
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
		underlay.focused_id = 0
		ui_build_controls(&underlay)
		base := ui_build_geometry(&underlay)
		append(&vertices, ..base[:])
		delete(underlay.controls)
		modal := ui_settings_modal_rect(ui)
		if ui.help_open {modal = ui_help_modal_rect(ui)}
		if ui.evidence_open && ui_evidence_available(evidence_view) {modal = ui_evidence_modal_rect(ui)}
		ui_add_rect(&vertices, ui, {0, 0, ui.width, ui.height}, {0, 0, 0, 0.8})
		ui_modal_shadow(&vertices, ui, modal)
		scale := ui_style_scale(ui)
		radius := 12/scale
		edge := 1/scale
		if ui.dark {
			ui_add_round_rect(&vertices, ui, modal, radius, {0.192, 0.192, 0.192, 1})
			ui_add_round_rect(&vertices, ui, {modal.x+edge, modal.y+edge, modal.w-2*edge, modal.h-2*edge}, radius-edge, theme.overlay)
		} else {
			ui_add_round_rect(&vertices, ui, modal, radius, theme.overlay)
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
		window_control := control.action == .Window_Close || control.action == .Window_Minimize || control.action == .Window_Zoom
		if window_control && modal_open {continue}
		if control.action == .Section_Height {
			if control.id == ui.focused_id {ui_add_border(&vertices, ui, control.rect, theme.text)}
			track := UI_Rect{control.rect.x+4, control.rect.y+control.rect.h/2-2, control.rect.w-8, 4}
			ui_add_round_rect(&vertices, ui, track, 2, ui_theme_blend(theme, 0.2))
			fraction := 0.0
			if ui.section_max > 0 {fraction = clamp(f64(ui.section_z/ui.section_max), 0, 1)}
			ink := theme.text if control.enabled else Vec4{0.501961, 0.501961, 0.501961, 1}
			ui_add_round_rect(&vertices, ui, {track.x, track.y, max(1, track.w*fraction), track.h}, 2, ink)
			ui_add_round_rect(&vertices, ui, {track.x+track.w*fraction-6, control.rect.y+(control.rect.h-12)/2, 12, 12}, 6, ink)
			continue
		}
		if control.action == .Toggle_Section {
			if control.id == ui.focused_id {ui_add_border(&vertices, ui, control.rect, theme.text)}
			scale := ui_style_scale(ui)
			height_px := math.round(ui_style_row_height(ui)*0.85)
			height := height_px/scale
			width := math.round(height_px*1.8)/scale
			inset := 2/scale
			track := UI_Rect{control.rect.x+8, control.rect.y+(control.rect.h-height)/2, width, height}
			track_color := ui_theme_blend(theme, 0.22 if hovered else 0.16)
			if !control.enabled {track_color = ui_theme_blend(theme, 0.04)}
			if ui.section_enabled && control.enabled {track_color = theme.text}
			ui_add_round_rect(&vertices, ui, track, height/2, track_color)
			thumb_size := height-2*inset
			thumb_x := track.x+inset
			if ui.section_enabled {thumb_x = track.x+track.w-inset-thumb_size}
			thumb := theme.raised
			if ui.section_enabled || !control.enabled {thumb = theme.canvas}
			ui_add_round_rect(&vertices, ui, {thumb_x, track.y+inset, thumb_size, thumb_size}, thumb_size/2, thumb)
			continue
		}
		menu := control.action == .Evidence_Stages || control.action == .Evidence_Details || control.action == .Panel_Models || control.action == .Panel_Section || control.action == .Panel_Mesh || control.action == .Select_Benchy || control.action == .Select_All_In_One || control.action == .Select_Bunny
		if _, stage := ui_evidence_stage_action_index(control.action, len(evidence_view.replay.root.stages) if ui_evidence_available(evidence_view) else 0); stage {menu = true}
		rect := ui_pill_rect(ui, control.rect)
		if window_control {
			size := min(rect.w, rect.h)
			rect = {rect.x+(rect.w-size)/2, rect.y+(rect.h-size)/2, size, size}
		}
		if rect.w <= 0 || rect.h <= 0 {continue}
		fill := theme.raised
		if hovered {
			amount := f32(0.12) if ui.dark else f32(0.55)
			fill = {fill.x+(1-fill.x)*amount, fill.y+(1-fill.y)*amount, fill.z+(1-fill.z)*amount, 1}
		}
		if standing {fill = theme.text}
		if window_control {
			#partial switch control.action {
			case .Window_Minimize: fill = {1.0, 0.741, 0.18, 1}
			case .Window_Zoom: fill = {0.157, 0.788, 0.251, 1}
			case .Window_Close: fill = {1.0, 0.373, 0.341, 1}
			}
			if standing {
				fill = {fill.x*0.85, fill.y*0.85, fill.z*0.85, 1}
			} else if hovered {
				#partial switch control.action {
				case .Window_Minimize: fill = {1.0, 0.81, 0.12, 1}
				case .Window_Zoom: fill = {0.12, 0.90, 0.22, 1}
				case .Window_Close: fill = {1.0, 0.45, 0.30, 1}
				}
			}
		}
		if menu && !hovered && !standing {continue}
		if !menu {ui_pill_shadow(&vertices, ui, rect)}
		if menu && standing {ui_menu_shadow(&vertices, ui, rect)}
		scale := ui_style_scale(ui)
		radius := 6/scale
		ui_add_round_rect(&vertices, ui, rect, radius, fill)
		if !menu && !standing {
			highlight_alpha := (f32(0.24) if hovered else f32(0.14)) if ui.dark else (f32(0.45) if hovered else f32(0.9))
			highlight := Vec4{1, 1, 1, highlight_alpha}
			if window_control {highlight = {fill.x+(1-fill.x)*0.35, fill.y+(1-fill.y)*0.35, fill.z+(1-fill.z)*0.35, 1}}
			ui_pill_highlight(&vertices, ui, rect, radius, highlight)
		}
	}
	for hint in flash.visible_hints(&ui.flash_state) {
		width := max(16.0, 8.0+8.0*f64(len(hint.label)))
		rect := UI_Rect{hint.target.rect.x+2, hint.target.rect.y+2, width, 18}
		rect.x = min(rect.x, ui.width-rect.w)
		rect.y = min(rect.y, ui.height-rect.h)
		ui_add_rect(&vertices, ui, rect, theme.text)
		if hint.selected {ui_add_border(&vertices, ui, {hint.target.rect.x, hint.target.rect.y, hint.target.rect.w, hint.target.rect.h}, theme.text)}
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

ui_draw_evidence_line :: proc(ctx, font, mono: rawptr, ui: ^UI_State, line: UI_Evidence_Line, rect: UI_Rect) {
	color := ui_theme(ui).text
	label_width := rect.w if line.value == "" else line.value_offset
	ui_draw_text(ctx, font, ui, line.label, {rect.x, rect.y, label_width, rect.h}, color, 0)
	if line.value != "" {
		ui_draw_text(ctx, mono if line.value_mono else font, ui, line.value,
			{rect.x+line.value_offset, rect.y, rect.w-line.value_offset, rect.h}, color, 0, tracked = line.value_mono)
	}
}

ui_draw_status :: proc(ctx, font: rawptr, ui: ^UI_State, status: string, failed: bool) {
	if status == "" {return}
	compact := ui_compact(ui)
	area := ui_right_rect(ui)
	if compact {area = ui_viewport_rect(ui)}
	width := area.w-16 if compact else 252.0
	x := area.x+8 if compact else area.x+12
	measure_font := ui_font("Inter-Regular", BASE_FONT_SIZE)
	assert(measure_font != nil)
	defer CFRelease(measure_font)
	lines := make([dynamic]string, context.temp_allocator)
	ui_wrap_text(&lines, status, measure_font, width, 0)
	row := ui_style_row_height(ui)/ui_style_scale(ui)
	height := f64(len(lines))*row
	y := area.y+area.h-8-height
	if compact {
		background := ui_theme(ui).canvas
		CGContextSetRGBFillColor(ctx, f64(background.x), f64(background.y), f64(background.z), 1)
		CGContextFillRect(ctx, ui_cg_rect(ui, {x-4, y-2, width+8, height+4}))
	}
	color := ui_theme(ui).text
	if failed {color = {0.956863, 0.203922, 0.203922, 1} if ui.dark else {0.768627, 0.145098, 0.145098, 1}}
	for line, index in lines {
		ui_draw_text(ctx, font, ui, line, {x, y+f64(index)*row, width, row}, color, 0)
	}
}

ui_draw_measurement :: proc(
	ctx, font, mono: rawptr,
	ui: ^UI_State,
	label, value: string,
	rect: UI_Rect,
	label_width: f64,
) {
	color := ui_theme(ui).text
	ui_draw_text(ctx, font, ui, label, {rect.x, rect.y, label_width, rect.h}, color, 0)
	ui_draw_text(ctx, mono, ui, value, {rect.x+label_width, rect.y, rect.w-label_width, rect.h}, color, 0, tracked = true)
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
			ui_theme(ui).canvas,
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
	theme := ui_theme(ui)

	ui_draw_text(
		ctx,
		font,
		ui,
		"Evidence inspector",
		{modal.x+20, modal.y+12, modal.w-40, 26},
		theme.text,
		0,
	)
	if ui_evidence_compact(ui) {
		panes := [2]UI_Action{.Evidence_Stages, .Evidence_Details}
		labels := [2]string{"Stages", "Details"}
		for label, index in labels {
			action := panes[index]
			ui_draw_text(ctx, font, ui, label, ui_control_rect(ui, action), ui_control_ink(ui, action), 0, .Center)
		}
		position := ui.evidence_scroll
		total := len(replay.root.stages)
		if ui.evidence_pane == .Stages {
			for stage, index in replay.root.stages {
				if index < ui.evidence_scroll || index >= ui.evidence_scroll+ui_evidence_visible_stages(ui) {continue}
				action := ui_evidence_stage_action(index)
				ui_draw_text(ctx, mono, ui, fmt.tprintf("%02d  %s", stage.ordinal, stage.stage.name), ui_control_rect(ui, action), ui_control_ink(ui, action), 8, tracked = true)
			}
		} else {
			lines := ui_evidence_detail_lines(ui, view)
			visible := ui_evidence_detail_rows(ui)
			ui.evidence_detail_scroll = clamp(ui.evidence_detail_scroll, 0, max(0, len(lines)-visible))
			position = ui.evidence_detail_scroll
			total = len(lines)
			for line, index in lines {
				if index < ui.evidence_detail_scroll || index >= ui.evidence_detail_scroll+visible {continue}
				ui_draw_evidence_line(ctx, font, mono, ui, line, {modal.x+20, modal.y+80+f64(index-ui.evidence_detail_scroll)*20, modal.w-40, 20})
			}
		}
		ui_draw_text(ctx, font, ui, fmt.tprintf("Scroll %d / %d", min(position+1, total), total), {modal.x+20, modal.y+modal.h-40, modal.w-160, 24}, theme.text, 0)
		ui_draw_text(ctx, font, ui, "1  Close", ui_control_rect(ui, .Close_Evidence), ui_control_ink(ui, .Close_Evidence), 0, .Center)
		ui_draw_flash_hint_text(ctx, font, ui)
		return
	}

	ui_draw_text(ctx, font, ui, "Select a stage", {modal.x+20, modal.y+42, 270, 22}, theme.text, 0)

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

	detail := ui_evidence_detail_rect(ui)
	lines := ui_evidence_detail_lines(ui, view)
	visible := ui_evidence_detail_rows(ui)
	ui.evidence_detail_scroll = clamp(ui.evidence_detail_scroll, 0, max(0, len(lines)-visible))
	for line, index in lines {
		if index < ui.evidence_detail_scroll || index >= ui.evidence_detail_scroll+visible {continue}
		ui_draw_evidence_line(ctx, font, mono, ui, line, {detail.x, detail.y+f64(index-ui.evidence_detail_scroll)*20, detail.w, 20})
	}
	ui_draw_text(ctx, font, ui, fmt.tprintf("Scroll %d / %d", min(ui.evidence_detail_scroll+1, len(lines)), len(lines)), {detail.x, modal.y+modal.h-40, max(1, detail.w-140), 24}, theme.text, 0)

	ui_draw_text(
		ctx,
		font,
		ui,
		"1  Close",
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
		"Settings",
		{modal.x+20, modal.y+14, modal.w-40, 32},
		theme.text,
		0,
	)
	ui_draw_text(
		ctx,
		font,
		ui,
		"Font size",
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
		"Close",
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
	status_failed := false,
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
		underlay.focused_id = 0
		ui_build_controls(&underlay)
		ui = &underlay
		CGContextSetAlpha(ctx, 0.2)
	}
	title_width := max(0.0, ui.width-383)
	title := "HW Slicer / Model and placement" if title_width >= 230 else "Slicer"
	ui_draw_text(ctx, font, ui, title, {12, 0, title_width, 40}, theme.text, 0)
	window_labels := [3]string{"−", "+", "×"}
	window_actions := [3]UI_Action{.Window_Minimize, .Window_Zoom, .Window_Close}
	for label, index in window_labels {
		action := window_actions[index]
		ui_draw_text(ctx, mono, ui, label, ui_control_rect(ui, action), ui_control_ink(ui, action), 0, .Center, tracked = true)
	}
	ui_draw_text(
		ctx,
		font,
		ui,
		"Dark" if !ui.dark else "Light",
		{ui.width-255, 5, 74, 30},
		ui_control_ink(ui, .Toggle_Theme),
		0,
		.Center,
	)
	ui_draw_text(
		ctx,
		font,
		ui,
		"Settings",
		{ui.width-359, 5, 97, 30},
		ui_control_ink(ui, .Open_Settings),
		0,
		.Center,
	)
	ui_draw_text(ctx, font, ui, "Help", ui_control_rect(ui, .Show_Help), ui_control_ink(ui, .Show_Help), 0, .Center)

	compact := ui_compact(ui)
	if compact {
		panels := [3]UI_Action{.Panel_Models, .Panel_Section, .Panel_Mesh}
		labels := [3]string{"Models", "Section", "Mesh"}
		for label, index in labels {
			action := panels[index]
			ui_draw_text(ctx, font, ui, label, ui_control_rect(ui, action), ui_control_ink(ui, action), 0, .Center)
		}
		if ui.panel == .Models {
			ui_draw_text(ctx, font, ui, "Open model", ui_control_rect(ui, .Open), ui_control_ink(ui, .Open), 0, .Center)
			labels := [3]string{"3DBenchy", "All in one test", "Stanford Bunny"}
			actions := [3]UI_Action{.Select_Benchy, .Select_All_In_One, .Select_Bunny}
			for label, index in labels {
				rect := ui_control_rect(ui, actions[index])
				ui_draw_text(ctx, font, ui, label, rect, ui_control_ink(ui, actions[index]), 10)
			}
		} else if ui.panel == .Section {
			ui_draw_text(ctx, font, ui, "Enabled" if ui.section_enabled else "Disabled", {64, 84, 112, 28}, ui_control_ink(ui, .Toggle_Section), 0)
			ui_draw_measurement(ctx, font, mono, ui, "Z", fmt.tprintf("%.2f mm", ui.section_z), {20, 138, 156, 18}, 70)
			ui_draw_measurement(ctx, font, mono, ui, "Segments", fmt.tprintf("%d", ui.section_segments), {20, 158, 156, 18}, 70)
		}
	} else {
		ui_draw_text(ctx, font, ui, "Load model", {20, 58, 190, 24}, theme.muted, 0)
		ui_draw_text(ctx, font, ui, "Open model", ui_control_rect(ui, .Open), ui_control_ink(ui, .Open), 0, .Center)
		ui_draw_text(ctx, font, ui, "Reference models", {20, 118, 190, 24}, theme.muted, 0)
		model_labels := [3]string{"3DBenchy", "All in one test", "Stanford Bunny"}
		model_actions := [3]UI_Action{.Select_Benchy, .Select_All_In_One, .Select_Bunny}
		for label, index in model_labels {
			color := ui_control_ink(ui, model_actions[index])
			ui_draw_text(
				ctx,
				font,
				ui,
				label,
				ui_control_rect(ui, model_actions[index]),
				color,
				8,
			)
		}
		ui_draw_text(ctx, font, ui, "Section", {20, 240, 190, 24}, theme.muted, 0)
		ui_draw_text(
			ctx,
			font,
			ui,
			"Enabled" if ui.section_enabled else "Disabled",
			{64, 268, 152, 30},
			ui_control_ink(ui, .Toggle_Section),
			0,
		)
		ui_draw_measurement(ctx, font, mono, ui, "Z", fmt.tprintf("%.2f mm", ui.section_z), {20, 334, 204, 22}, 90)
		ui_draw_measurement(ctx, font, mono, ui, "Segments", fmt.tprintf("%d", ui.section_segments), {20, 358, 204, 22}, 90)
	}

	viewport := ui_viewport_rect(ui)
	ui_draw_text(
		ctx,
		font,
		ui,
		"Frame",
		ui_control_rect(ui, .Frame_Mesh),
		ui_control_ink(ui, .Frame_Mesh),
		0,
		.Center,
	)
	ui_draw_text(
		ctx,
		font,
		ui,
		"Wireframe",
		ui_control_rect(ui, .Toggle_Wireframe),
		ui_control_ink(ui, .Toggle_Wireframe),
		0,
		.Center,
	)

	ui_draw_text(
		ctx,
		font,
		ui,
		"Lay on face",
		ui_control_rect(ui, .Lay_On_Face),
		ui_control_ink(ui, .Lay_On_Face),
		0,
		.Center,
	)
	if compact {
		if ui.panel == .Mesh {
			ui_draw_text(ctx, font, ui, model_name, {20, 82, 156, 20}, theme.text, 0)
			if mesh != nil && mesh.triangle_count > 0 {
				size := mesh_size(mesh.bounds)
				labels := [4]string{"Triangles", "Width", "Depth", "Height"}
				values := [4]string{
					fmt.tprintf("%d", mesh.triangle_count),
					fmt.tprintf("%.2f mm", size.x),
					fmt.tprintf("%.2f mm", size.y),
					fmt.tprintf("%.2f mm", size.z),
				}
				for label, index in labels {
					ui_draw_measurement(ctx, font, mono, ui, label, values[index], {20, f64(102+index*18), 156, 18}, 70)
				}
			}
		}
	} else {
		right := ui_right_rect(ui)
		ui_draw_text(ctx, font, ui, "Model details", {right.x+12, right.y+8, 240, 28}, theme.muted, 0)
		ui_draw_text(ctx, font, ui, model_name, {right.x+12, right.y+42, 252, 32}, theme.text, 0)
		if mesh != nil && mesh.triangle_count > 0 {
			size := mesh_size(mesh.bounds)
			labels := [4]string{"Triangles", "Width", "Depth", "Height"}
			values := [4]string{
				fmt.tprintf("%d", mesh.triangle_count),
				fmt.tprintf("%.2f mm", size.x),
				fmt.tprintf("%.2f mm", size.y),
				fmt.tprintf("%.2f mm", size.z),
			}
			for label, index in labels {
				ui_draw_measurement(ctx, font, mono, ui, label, values[index], {right.x+12, right.y+86+f64(index*26), 252, 24}, 90)
			}
			ui_draw_text(ctx, font, ui, "Binary STL / expanded vertices", {right.x+12, right.y+190, 252, 24}, theme.text, 0)
		}
		ui_draw_text(ctx, font, ui, "Camera", {right.x+12, right.y+242, 240, 24}, theme.muted, 0)
		camera_lines := [4]struct {input, action: string}{
			{"Left drag", "Orbit"},
			{"Right drag", "Pan"},
			{"Scroll", "Zoom"},
			{"/", "Flash"},
		}
		for line, index in camera_lines {
			rect := UI_Rect{right.x+12, right.y+270+f64(index*25), 252, 22}
			ui_draw_text(ctx, font, ui, line.input, {rect.x, rect.y, 100, rect.h}, theme.text, 0)
			ui_draw_text(ctx, font, ui, line.action, {rect.x+100, rect.y, rect.w-100, rect.h}, theme.text, 0)
		}

	}

	ui_draw_status(ctx, font, ui, status, status_failed)

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
				"Mesh viewer help",
				{modal.x+20, modal.y+14, 440, 32},
				theme.text,
				0,
			)
			help_lines := [7]string{
				"Left drag rotates the camera around the mesh target.",
				"Right or middle drag translates the camera target.",
				"Scroll changes camera distance.",
				"Frame recalculates the target and distance from the placed model bounds.",
				"Wireframe changes Metal triangle fill mode.",
				"Open accepts exact STL files and validated evidence bundles.",
				"Section drags a cutting plane; its contour draws over the mesh.",
			}
			line_y, line_step, line_height := f64(66), f64(30), f64(26)
			if modal.h < 320 || modal.w < 470 {
				help_lines = [7]string{
					"Left drag: orbit the model.",
					"Right or middle drag: pan.",
					"Scroll: zoom.",
					"Frame: fit the placed model.",
					"Wireframe: change triangle fill.",
					"Open: load STL or evidence.",
					"Section: move the cutting plane.",
				}
				line_y, line_step, line_height = 54, 20, 18
			}
			for line, index in help_lines {
				ui_draw_text(
					ctx,
					font,
					ui,
					line,
					{modal.x+20, modal.y+line_y+f64(index)*line_step, modal.w-40, line_height},
					theme.text,
					0,
				)
			}
			ui_draw_text(
				ctx,
				font,
				ui,
				"1  Close",
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
	} else if ui.settings_open {
		modal = "settings"
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
