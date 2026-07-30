package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import CF "core:sys/darwin/CoreFoundation"
import flash "flash:."

import evidence "./evidence"

foreign import core_graphics "system:CoreGraphics.framework"
foreign core_graphics {
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
	CTFontCreateWithName :: proc "c" (
		name: rawptr,
		size: f64,
		transform: rawptr,
	) -> rawptr ---
	CTLineCreateWithAttributedString :: proc "c" (string: rawptr) -> rawptr ---
	CTLineGetTypographicBounds :: proc "c" (
		line: rawptr,
		ascent, descent, leading: ^f64,
	) -> f64 ---
	CTLineDraw :: proc "c" (line, ctx: rawptr) ---
	CTFontManagerRegisterFontsForURL :: proc "c" (
		url: rawptr,
		scope: u32,
		error: ^rawptr,
	) -> bool ---
	kCTFontAttributeName: rawptr
	kCTForegroundColorFromContextAttributeName: rawptr
}

foreign import slicer_core_foundation "system:CoreFoundation.framework"
foreign slicer_core_foundation {
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
	CFURLCreateFromFileSystemRepresentation :: proc "c" (
		allocator: rawptr,
		bytes: [^]u8,
		length: int,
		is_directory: bool,
	) -> rawptr ---
	CFRelease :: proc "c" (value: rawptr) ---
	kCFBooleanTrue: rawptr
}

UI_Rect :: struct {x, y, w, h: f64}

UI_Action :: enum u64 {
	None,
	Window_Close,
	Window_Minimize,
	Window_Zoom,
	Toggle_Theme,
	Show_Help,
	Close_Help,
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
	canvas  = {0.800000, 0.780392, 0.721569, 1},
	header  = {0.909804, 0.890196, 0.819608, 1},
	surface = {0.878431, 0.858824, 0.788235, 1},
	raised  = {0.850980, 0.831373, 0.760784, 1},
	control = {0.831373, 0.811765, 0.741176, 1},
	overlay = {0.909804, 0.890196, 0.819608, 1},
	text    = {0.149020, 0.145098, 0.156863, 1},
	muted   = {0.478431, 0.458824, 0.419608, 1},
}

DARK_THEME :: Theme{
	canvas  = {0.039216, 0.043137, 0.039216, 1},
	header  = {0.031373, 0.035294, 0.031373, 1},
	surface = {0.054902, 0.058824, 0.054902, 1},
	raised  = {0.066667, 0.070588, 0.066667, 1},
	control = {0.066667, 0.070588, 0.066667, 1},
	overlay = {0.019608, 0.023529, 0.019608, 0.96},
	text    = {0.968627, 0.949020, 0.878431, 1},
	muted   = {0.470588, 0.490196, 0.458824, 1},
}

COLOR_COFFEE :: Vec4{0.698039, 0.490196, 0.341176, 1}
COLOR_GUM    :: Vec4{0.490196, 0.529412, 0.411765, 1}
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
	width: f64,
	height: f64,
	scale: f64,
	dark: bool,
	selected_model: int,
	wireframe: bool,
	pressed_id: u64,
	hovered_id: u64,
}

ui_initialize :: proc(ui: ^UI_State) {
	ui.controls = make([dynamic]UI_Control)
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
		ui.height/2-height/2,
		width,
		height,
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
	ui_add_control(ui, "window close", "close window", {8, 5, 30, 30}, .Window_Close)
	ui_add_control(ui, "window minimize", "minimize window", {40, 5, 30, 30}, .Window_Minimize)
	ui_add_control(ui, "window zoom", "zoom window", {72, 5, 30, 30}, .Window_Zoom)
	if ui.help_open {
		modal := UI_Rect{
			ui.width/2-270,
			ui.height/2-170,
			540,
			340,
		}
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
		stage_count := len(evidence_view.replay.root.stages)
		if ui.evidence_stage_index < 0 ||
		   ui.evidence_stage_index >= stage_count {
			ui.evidence_stage_index = 0
		}
		for stage, stage_index in evidence_view.replay.root.stages {
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
					modal.y+72+f64(stage_index)*30,
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
	ui_add_control(
		ui,
		"theme",
		"switch to light theme" if ui.dark else "switch to dark theme",
		{ui.width-156, 5, 82, 30},
		.Toggle_Theme,
	)
	ui_add_control(ui, "help", "viewer help", {ui.width-66, 5, 54, 30}, .Show_Help)

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
	slot_width := bar.w/6
	for index in 0..<6 {
		ui_add_control(
			ui,
			names[index],
			accessibility_labels[index],
			{bar.x+f64(index)*slot_width, bar.y, slot_width, bar.h},
			actions[index],
			index == 0,
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

ui_begin_flash :: proc(ui: ^UI_State) {
	targets := make([dynamic]flash.Target, context.temp_allocator)
	for control in ui.controls {
		if !control.enabled {continue}
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

ui_build_geometry :: proc(
	ui: ^UI_State,
	evidence_view: ^UI_Evidence_View = nil,
) -> [dynamic]Solid_Vertex {
	vertices := make([dynamic]Solid_Vertex, context.temp_allocator)
	theme := ui_theme(ui)
	evidence_stage_count := 0
	if ui_evidence_available(evidence_view) {
		evidence_stage_count = len(evidence_view.replay.root.stages)
	}
	ui_add_rect(&vertices, ui, {0, 0, ui.width, 40}, theme.header)
	ui_add_rect(&vertices, ui, ui_left_rect(ui), theme.surface)
	ui_add_rect(&vertices, ui, ui_viewport_rect(ui), theme.raised)
	ui_add_rect(&vertices, ui, ui_right_rect(ui), theme.surface)
	bar := ui_action_bar_rect(ui)
	ui_add_rect(&vertices, ui, bar, theme.header)
	if ui.help_open {
		modal := UI_Rect{
			ui.width/2-270,
			ui.height/2-170,
			540,
			340,
		}
		ui_add_rect(&vertices, ui, {0, 40, ui.width, ui.height-40}, {0, 0, 0, 0.58})
		ui_add_rect(&vertices, ui, modal, theme.overlay)
		ui_add_border(&vertices, ui, modal, COLOR_GUM)
	} else if ui.evidence_open && ui_evidence_available(evidence_view) {
		modal := ui_evidence_modal_rect(ui)
		ui_add_rect(&vertices, ui, {0, 40, ui.width, ui.height-40}, {0, 0, 0, 0.58})
		ui_add_rect(&vertices, ui, modal, theme.overlay)
	}

	for control in ui.controls {
		hovered := control.id == ui.hovered_id
		fill := theme.surface if hovered else theme.control
		if _, is_stage := ui_evidence_stage_action_index(
			control.action,
			evidence_stage_count,
		); is_stage {
			ui_add_rect(
				&vertices,
				ui,
				control.rect,
				theme.surface if hovered else theme.raised,
			)
			if control.selected {
				ui_add_rect(
					&vertices,
					ui,
					{control.rect.x, control.rect.y, 4, control.rect.h},
					COLOR_GUM,
				)
				ui_add_border(
					&vertices,
					ui,
					control.rect,
					COLOR_GUM,
				)
			}
			continue
		}
		switch control.action {
		case .Window_Close, .Window_Minimize, .Window_Zoom:
			ui_add_rect(&vertices, ui, control.rect, fill)
		case .Toggle_Theme:
			ui_add_rect(&vertices, ui, control.rect, fill)
			ui_add_border(&vertices, ui, control.rect, COLOR_COFFEE)
			ui_add_rect(
				&vertices,
				ui,
				{control.rect.x, control.rect.y, 4, control.rect.h},
				COLOR_COFFEE,
			)
		case .Toggle_Wireframe:
			ui_add_rect(&vertices, ui, control.rect, fill)
			ui_add_border(&vertices, ui, control.rect, COLOR_COFFEE)
			ui_add_rect(
				&vertices,
				ui,
				{control.rect.x, control.rect.y, 4, control.rect.h},
				COLOR_COFFEE,
			)
		case .Show_Help, .Frame_Mesh:
			ui_add_rect(&vertices, ui, control.rect, fill)
		case .Select_Benchy, .Select_All_In_One, .Select_Bunny:
			ui_add_rect(
				&vertices,
				ui,
				control.rect,
				theme.surface if hovered else theme.raised,
			)
			if control.selected {
				ui_add_rect(
					&vertices,
					ui,
					{control.rect.x, control.rect.y, 4, control.rect.h},
					COLOR_COFFEE,
				)
			}
		case .Open, .Slice, .Cancel, .Capture, .Compare, .Export:
			ui_add_rect(
				&vertices,
				ui,
				{
					control.rect.x+6,
					control.rect.y+6,
					control.rect.w-12,
					control.rect.h-12,
				},
				fill,
			)
			if control.enabled {
				ui_add_border(
					&vertices,
					ui,
					{
						control.rect.x+6,
						control.rect.y+6,
						control.rect.w-12,
						control.rect.h-12,
					},
					COLOR_COFFEE,
				)
			}
		case .Close_Help, .Close_Evidence:
			ui_add_rect(&vertices, ui, control.rect, fill)
			ui_add_border(&vertices, ui, control.rect, COLOR_GUM)
		case .None, .Evidence_Stage_Base:
		}
	}
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
		background := FLASH_SELECTED_BG if hint.selected else FLASH_BG
		border := FLASH_SELECTED_BORDER if hint.selected else FLASH_BORDER
		ui_add_rect(&vertices, ui, rect, background)
		ui_add_border(&vertices, ui, rect, border)
		if hint.selected {
			target := UI_Rect{
				hint.target.rect.x,
				hint.target.rect.y,
				hint.target.rect.w,
				hint.target.rect.h,
			}
			ui_add_border(&vertices, ui, target, FLASH_SELECTED_BORDER)
		}
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

ui_text_run :: proc(font: rawptr, text: string) -> Text_Run {
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
	return {
		{rect.x*ui.scale, (ui.height-rect.y-rect.h)*ui.scale},
		{rect.w*ui.scale, rect.h*ui.scale},
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
) {
	run := ui_text_run(font, text)
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
	x := (rect.x+inset)*ui.scale
	switch alignment {
	case .Center:
		x = rect.x*ui.scale+(rect.w*ui.scale-run.advance)/2
	case .End:
		x = (rect.x+rect.w-inset)*ui.scale-run.advance
	case .Start:
	}
	y := cg_rect.origin.y+
		(cg_rect.size.height-(run.ascent+run.descent))/2+
		run.descent
	CGContextSetTextPosition(ctx, x, y)
	CTLineDraw(run.line, ctx)
	CGContextRestoreGState(ctx)
}

ui_icon_point :: proc(ui: ^UI_State, rect: UI_Rect, x, y: f64) -> NS_Point {
	return {
		(rect.x+x/24*rect.w)*ui.scale,
		(ui.height-(rect.y+y/24*rect.h))*ui.scale,
	}
}

ui_icon_begin :: proc(
	ctx: rawptr,
	ui: ^UI_State,
	color: Vec4,
) {
	CGContextSetRGBStrokeColor(
		ctx,
		f64(color.x),
		f64(color.y),
		f64(color.z),
		f64(color.w),
	)
	CGContextSetLineWidth(ctx, 1.5*ui.scale)
	CGContextSetLineCap(ctx, 1)
	CGContextSetLineJoin(ctx, 1)
}

ui_draw_icon_segment :: proc(
	ctx: rawptr,
	ui: ^UI_State,
	rect: UI_Rect,
	points: []NS_Point,
) {
	if len(points) == 0 {return}
	CGContextBeginPath(ctx)
	first := ui_icon_point(ui, rect, points[0].x, points[0].y)
	CGContextMoveToPoint(ctx, first.x, first.y)
	for point in points[1:] {
		mapped := ui_icon_point(ui, rect, point.x, point.y)
		CGContextAddLineToPoint(ctx, mapped.x, mapped.y)
	}
	CGContextStrokePath(ctx)
}

ui_draw_window_icons :: proc(
	ctx: rawptr,
	ui: ^UI_State,
	color: Vec4,
) {
	ui_icon_begin(ctx, ui, color)
	icon := UI_Rect{11, 8, 24, 24}
	ui_draw_icon_segment(
		ctx,
		ui,
		icon,
		[]NS_Point{{6.75827, 17.2426}, {12.0009, 12}, {17.2435, 6.75736}},
	)
	ui_draw_icon_segment(
		ctx,
		ui,
		icon,
		[]NS_Point{{6.75827, 6.75736}, {12.0009, 12}, {17.2435, 17.2426}},
	)
	icon.x = 43
	ui_draw_icon_segment(ctx, ui, icon, []NS_Point{{6, 12}, {18, 12}})
	icon.x = 75
	corners := [4][3]NS_Point{
		[3]NS_Point{{7, 4}, {4, 4}, {4, 7}},
		[3]NS_Point{{17, 4}, {20, 4}, {20, 7}},
		[3]NS_Point{{7, 20}, {4, 20}, {4, 17}},
		[3]NS_Point{{17, 20}, {20, 20}, {20, 17}},
	}
	for &points in corners {
		ui_draw_icon_segment(ctx, ui, icon, points[:])
	}
}

ui_draw_help_icon :: proc(
	ctx: rawptr,
	ui: ^UI_State,
	rect: UI_Rect,
	color: Vec4,
) {
	ui_icon_begin(ctx, ui, color)
	circle := ui_cg_rect(
		ui,
		{
			rect.x+2,
			rect.y+2,
			rect.w-4,
			rect.h-4,
		},
	)
	CGContextStrokeEllipseInRect(ctx, circle)
	ui_draw_icon_segment(
		ctx,
		ui,
		rect,
		[]NS_Point{{9, 9}, {9.2, 7}, {11, 6.3}, {13, 6.4}, {14.5, 8}, {14.5, 9}, {14, 10.5}, {12, 11}, {12, 14}},
	)
	ui_draw_icon_segment(
		ctx,
		ui,
		rect,
		[]NS_Point{{12, 18.01}, {12.01, 17.9989}},
	)
}

ui_register_font :: proc(resource_root: string) -> bool {
	path := filepath.join({resource_root, "Fonts", "Iosevka-Regular.ttf"})
	defer delete(path)
	bytes := transmute([]u8)path
	url := CFURLCreateFromFileSystemRepresentation(
		nil,
		raw_data(bytes),
		len(bytes),
		false,
	)
	if url == nil {return false}
	defer CFRelease(url)
	error: rawptr
	registered := CTFontManagerRegisterFontsForURL(url, 1, &error)
	if error != nil {CFRelease(error)}
	return registered || error == nil
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
	case "reconstruct-topology":
		if replay.topology_loaded {return "TOPOLOGY GRAPH RETAINED"}
	case "calculate-regions":
		if replay.regions_loaded {return "REGION GRAPH RETAINED"}
	case "plan-paths":
		if replay.path_plan_loaded && replay.motion_plan_loaded {
			return "PATH + MOTION GRAPHS RETAINED"
		}
		if replay.path_plan_loaded {return "PATH-PLAN GRAPH RETAINED"}
		if replay.motion_plan_loaded {return "MOTION GRAPH RETAINED"}
	case "emit-gcode":
		if replay.marlin_loaded {return "G-CODE GRAPH RETAINED"}
	case:
	}
	return "MANIFEST RETAINED"
}

ui_draw_evidence_overlay :: proc(
	ctx, font: rawptr,
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
		font,
		ui,
		fmt.tprintf(
			"%s / %s / %d STAGES",
			filepath.base(view.source),
			view.container,
			len(replay.root.stages),
		),
		{modal.x+20, modal.y+36, modal.w-40, 22},
		theme.muted,
		0,
	)
	ui_draw_text(
		ctx,
		font,
		ui,
		fmt.tprintf("REQUEST %s", replay.root.request_hash),
		{modal.x+20, modal.y+54, modal.w-40, 20},
		theme.muted,
		0,
	)

	for stage, stage_index in replay.root.stages {
		color := COLOR_GUM if stage_index == selected_index else theme.text
		ui_draw_text(
			ctx,
			font,
			ui,
			fmt.tprintf("%02d  %s", stage.ordinal, stage.stage.name),
			{
				modal.x+28,
				modal.y+72+f64(stage_index)*30,
				250,
				28,
			},
			color,
			0,
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
			font,
			ui,
			line,
			{
				detail_x,
				modal.y+82+f64(line_index)*24,
				detail_width,
				22,
			},
			theme.text if line_index < 6 else COLOR_GUM,
			0,
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
			font,
			ui,
			fmt.tprintf("%-28s %d", counter.name, counter.value),
			{
				detail_x,
				summary_y+24+f64(counter_index)*22,
				detail_width,
				20,
			},
			theme.text,
			0,
		)
	}
	ui_draw_text(
		ctx,
		font,
		ui,
		"1  CLOSE",
		{modal.x+modal.w-132, modal.y+modal.h-48, 112, 32},
		COLOR_GUM,
		0,
		.Center,
	)
	ui_draw_flash_hint_text(ctx, font, ui)
}

ui_build_text_overlay :: proc(
	ui: ^UI_State,
	mesh: ^Mesh,
	model_name, status: string,
	evidence_view: ^UI_Evidence_View = nil,
) -> []u8 {
	width := uint(max(1, ui.width*ui.scale))
	height := uint(max(1, ui.height*ui.scale))
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
	font_name := ui_cf_string("Iosevka")
	if font_name == nil {return pixels}
	defer CFRelease(font_name)
	font := CTFontCreateWithName(font_name, 12*ui.scale, nil)
	if font == nil {return pixels}
	defer CFRelease(font)
	theme := ui_theme(ui)

	ui_draw_window_icons(ctx, ui, theme.text)
	ui_draw_text(
		ctx,
		font,
		ui,
		"HW SLICER / MESH VIEWER",
		{116, 0, 360, 40},
		theme.text,
		0,
	)
	if ui.help_open {
		modal := UI_Rect{
			ui.width/2-270,
			ui.height/2-170,
			540,
			340,
		}
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
			"FRAME recalculates the target and distance from STL bounds.",
			"WIREFRAME changes Metal triangle fill mode.",
			"OPEN accepts exact STL files and validated evidence bundles.",
			"The 220 x 220 mm grid uses direct Metal line primitives.",
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
			COLOR_GUM,
			0,
			.Center,
		)
		ui_draw_flash_hint_text(ctx, font, ui)
		return pixels
	}
	if ui.evidence_open && ui_evidence_available(evidence_view) {
		ui_draw_evidence_overlay(ctx, font, ui, evidence_view)
		return pixels
	}
	ui_draw_text(
		ctx,
		font,
		ui,
		"DARK" if !ui.dark else "LIGHT",
		{ui.width-156, 5, 82, 30},
		COLOR_COFFEE,
		0,
		.Center,
	)
	ui_draw_help_icon(
		ctx,
		ui,
		{ui.width-56, 8, 24, 24},
		theme.text,
	)

	ui_draw_text(ctx, font, ui, "REFERENCE MODELS", {20, 58, 190, 24}, theme.muted, 0)
	model_labels := [3]string{"3DBENCHY", "ALL IN ONE TEST", "STANFORD BUNNY"}
	for label, index in model_labels {
		color := COLOR_COFFEE if index == ui.selected_model else theme.text
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
	viewport := ui_viewport_rect(ui)
	ui_draw_text(
		ctx,
		font,
		ui,
		"FRAME",
		{viewport.x+12, viewport.y+12, 78, 30},
		theme.text,
		0,
		.Center,
	)
	ui_draw_text(
		ctx,
		font,
		ui,
		"WIREFRAME",
		{viewport.x+98, viewport.y+12, 98, 30},
		COLOR_COFFEE if ui.wireframe else theme.text,
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
				font,
				ui,
				line,
				{right.x+12, right.y+86+f64(index*26), 252, 24},
				theme.text if index < 4 else theme.muted,
				0,
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
			COLOR_COFFEE,
			0,
		)
	}

	bar := ui_action_bar_rect(ui)
	slot_width := bar.w/6
	labels := [6]string{"OPEN", "SLICE", "CANCEL", "CAPTURE", "COMPARE", "EXPORT"}
	for label, index in labels {
		color := COLOR_COFFEE if index == 0 else theme.muted
		ui_draw_text(
			ctx,
			font,
			ui,
			fmt.tprintf("%02d", index+1),
			{bar.x+f64(index)*slot_width+12, bar.y, 28, bar.h},
			color,
			0,
		)
		ui_draw_text(
			ctx,
			font,
			ui,
			label,
			{bar.x+f64(index)*slot_width+42, bar.y, slot_width-48, bar.h},
			color,
			0,
		)
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
	return os.write_entire_file(path, transmute([]u8)text)
}
