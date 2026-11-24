package main

import "core:fmt"
import "core:math"
import "core:time"
import "rune:gpu"
import "rune:text"

import pipeline "./pipeline"

// Graph units are points at zoom 1. Node positions come from the stage dependency table only.
GRAPH_NODE_W :: 140.0
GRAPH_NODE_H :: 60.0
GRAPH_PITCH_X :: 172.0
GRAPH_PITCH_Y :: 74.0
GRAPH_MARGIN :: 24.0
GRAPH_ZOOM_MIN :: 0.25
GRAPH_ZOOM_MAX :: 2.5
GRAPH_SPLIT_DEFAULT :: 0.5
GRAPH_DIVIDER_W :: 10.0
GRAPH_MENU_ROW :: 28.0
ATTRIBUTE_ROW :: 44.0

UI_Attribute_Tab :: enum u8 {
	Settings,
	Log,
	Docs,
}

// View state of the stage graph and the attribute editor beside it.
UI_Graph :: struct {
	// Graph point at the top-left corner of the canvas, and screen points per graph unit.
	pan:              [2]f64,
	zoom:             f64,
	fitted:           bool,
	panning:          bool,
	minimap_dragging: bool,
	// Fraction of the content width that the graph takes beside the 3D view.
	split:            f64,
	split_dragging:   bool,
	inspector_open:   bool,
	menu_open:        bool,
	menu_stage:       pipeline.Stage_Id,
	menu_at:          [2]f64,
	tab:              UI_Attribute_Tab,
	advanced:         bool,
	// Settings of the selected stage that the Advanced toggle hides.
	hidden_advanced:  int,
	show_mesh:           bool,
	show_result:         bool,
	gcode_mode:          pipeline.GCode_View_Mode,
	gcode_single_layer:  bool,
	gcode_preview_ready: bool,
	gcode_min:           f32,
	gcode_max:           f32,
	hover_edge:          bool,
	hover_from:       pipeline.Stage_Id,
	hover_to:         pipeline.Stage_Id,
	// Stages that have records in the loaded evidence bundle.
	evidence:         pipeline.Stage_Set,
	// Stages whose own settings differ from the values the workspace opened with.
	changed:          pipeline.Stage_Set,
	can_run_only:     pipeline.Stage_Set,
	// Seconds on a monotonic clock, for the running indicator.
	clock:            f64,
}

GRAPH_MENU_ITEMS := [5]struct {
	action: UI_Action,
	name:   string,
	label:  string,
}{
	{.Graph_Menu_Run_To, "menu run to here", "Run to here"},
	{.Graph_Menu_Run_Only, "menu run only", "Run only"},
	{.Graph_Menu_Reset, "menu reset", "Reset to default"},
	{.Graph_Menu_Evidence, "menu open evidence", "Open evidence"},
	{.Graph_Menu_Copy, "menu copy settings", "Copy settings"},
}

ui_graph_mode :: proc(ui: ^UI_State) -> bool {
	return ui.slicer_tab && ui.workspace.active && !ui.design_active
}

ui_graph_node_action :: proc(id: pipeline.Stage_Id) -> UI_Action {
	return UI_Action(u64(UI_Action.Graph_Node_Base)+u64(id))
}

ui_graph_node_action_index :: proc(action: UI_Action) -> (pipeline.Stage_Id, bool) {
	id := u64(action)
	base := u64(UI_Action.Graph_Node_Base)
	if id < base || id-base >= u64(len(pipeline.Stage_Id)) {return {}, false}
	return pipeline.Stage_Id(id-base), true
}

// Layout ------------------------------------------------------------------------------------------

ui_graph_content_rect :: proc(ui: ^UI_State) -> UI_Rect {
	return {12, 52, max(1, ui.width-24), max(1, ui.height-64)}
}

ui_graph_rect :: proc(ui: ^UI_State) -> UI_Rect {
	c := ui_graph_content_rect(ui)
	split := ui.workspace.graph.split if ui.workspace.graph.split > 0 else GRAPH_SPLIT_DEFAULT
	avail := max(1.0, c.w-GRAPH_DIVIDER_W)
	lo := min(220.0, avail*0.3)
	hi := max(lo, avail-min(280.0, avail*0.3))
	return {c.x, c.y, clamp(avail*split, lo, hi), c.h}
}

ui_graph_divider_rect :: proc(ui: ^UI_State) -> UI_Rect {
	g := ui_graph_rect(ui)
	return {g.x+g.w, g.y, GRAPH_DIVIDER_W, g.h}
}

ui_graph_viewport_rect :: proc(ui: ^UI_State) -> UI_Rect {
	c := ui_graph_content_rect(ui)
	d := ui_graph_divider_rect(ui)
	left := d.x+d.w
	return {left, c.y, max(1, c.x+c.w-left), c.h}
}

ui_attribute_rect :: proc(ui: ^UI_State) -> UI_Rect {
	vp := ui_viewport_rect(ui)
	w := min(clamp(vp.w*0.44, 248, 320), max(180.0, vp.w-24))
	top := vp.y+50
	bottom := vp.y+vp.h-90
	h := max(160.0, bottom-top)
	return {vp.x+vp.w-w-12, top, w, h}
}

ui_graph_set_split :: proc(ui: ^UI_State, x: f64) {
	c := ui_graph_content_rect(ui)
	avail := max(1.0, c.w-GRAPH_DIVIDER_W)
	ui.workspace.graph.split = clamp((x-c.x-GRAPH_DIVIDER_W*0.5)/avail, 0.15, 0.85)
}

ui_rect_intersection :: proc(a, b: UI_Rect) -> UI_Rect {
	x0 := max(a.x, b.x)
	y0 := max(a.y, b.y)
	x1 := min(a.x+a.w, b.x+b.w)
	y1 := min(a.y+a.h, b.y+b.h)
	return {x0, y0, max(0, x1-x0), max(0, y1-y0)}
}

// Top-left corner of a node in graph units. Stages of one column stack around y = 0.
ui_graph_node_origin :: proc(id: pipeline.Stage_Id) -> [2]f64 {
	columns := pipeline.stage_columns()
	members, index := 0, 0
	for other in pipeline.Stage_Id {
		if columns[other] != columns[id] {continue}
		if other == id {index = members}
		members += 1
	}
	return {f64(columns[id])*GRAPH_PITCH_X, (f64(index)-f64(members-1)/2)*GRAPH_PITCH_Y-GRAPH_NODE_H/2}
}

@(private = "file")
ui_graph_bounds :: proc() -> (lo, hi: [2]f64) {
	lo = {max(f64), max(f64)}
	hi = {-max(f64), -max(f64)}
	for id in pipeline.Stage_Id {
		o := ui_graph_node_origin(id)
		lo = {min(lo.x, o.x), min(lo.y, o.y)}
		hi = {max(hi.x, o.x+GRAPH_NODE_W), max(hi.y, o.y+GRAPH_NODE_H)}
	}
	return
}

ui_graph_to_screen :: proc(ui: ^UI_State, p: [2]f64) -> [2]f64 {
	g := ui_graph_rect(ui)
	v := ui.workspace.graph
	return {g.x+(p.x-v.pan.x)*v.zoom, g.y+(p.y-v.pan.y)*v.zoom}
}

ui_graph_node_rect :: proc(ui: ^UI_State, id: pipeline.Stage_Id) -> UI_Rect {
	p := ui_graph_to_screen(ui, ui_graph_node_origin(id))
	z := ui.workspace.graph.zoom
	return {p.x, p.y, GRAPH_NODE_W*z, GRAPH_NODE_H*z}
}

ui_graph_fit :: proc(ui: ^UI_State) {
	g := ui_graph_rect(ui)
	lo, hi := ui_graph_bounds()
	w := hi.x-lo.x+2*GRAPH_MARGIN
	h := hi.y-lo.y+2*GRAPH_MARGIN
	v := &ui.workspace.graph
	v.zoom = clamp(min(g.w/w, g.h/h), GRAPH_ZOOM_MIN, 1.4)
	center := (lo+hi)*0.5
	v.pan = center-[2]f64{g.w, g.h}/(2*v.zoom)
	v.fitted = true
}

// Zooms by `factor` and keeps the graph point under (x, y) in place.
ui_graph_zoom_at :: proc(ui: ^UI_State, x, y, factor: f64) {
	g := ui_graph_rect(ui)
	v := &ui.workspace.graph
	anchor := v.pan+[2]f64{x-g.x, y-g.y}/v.zoom
	v.zoom = clamp(v.zoom*factor, GRAPH_ZOOM_MIN, GRAPH_ZOOM_MAX)
	v.pan = anchor-[2]f64{x-g.x, y-g.y}/v.zoom
}

ui_graph_pan_by :: proc(ui: ^UI_State, dx, dy: f64) {
	v := &ui.workspace.graph
	v.pan -= [2]f64{dx, dy}/v.zoom
}

// True when part of the graph lies outside the canvas at the current view.
ui_graph_minimap_visible :: proc(ui: ^UI_State) -> bool {
	g := ui_graph_rect(ui)
	lo, hi := ui_graph_bounds()
	a := ui_graph_to_screen(ui, lo)
	b := ui_graph_to_screen(ui, hi)
	return a.x < g.x || a.y < g.y || b.x > g.x+g.w || b.y > g.y+g.h
}

ui_graph_minimap_rect :: proc(ui: ^UI_State) -> UI_Rect {
	g := ui_graph_rect(ui)
	w := min(168.0, g.w*0.3)
	h := min(64.0, g.h*0.4)
	return {g.x+g.w-w-8, g.y+g.h-h-8, w, h}
}

@(private = "file")
ui_minimap_scale :: proc(ui: ^UI_State) -> (origin: [2]f64, scale: f64, lo: [2]f64) {
	m := ui_graph_minimap_rect(ui)
	lo_g, hi_g := ui_graph_bounds()
	lo = lo_g-GRAPH_MARGIN
	hi := hi_g+GRAPH_MARGIN
	scale = min((m.w-8)/(hi.x-lo.x), (m.h-8)/(hi.y-lo.y))
	origin = {m.x+4, m.y+4}
	return
}

// Centres the graph view on the graph point under (x, y) in the minimap.
ui_graph_minimap_move :: proc(ui: ^UI_State, x, y: f64) {
	origin, scale, lo := ui_minimap_scale(ui)
	target := lo+([2]f64{x, y}-origin)/scale
	g := ui_graph_rect(ui)
	v := &ui.workspace.graph
	v.pan = target-[2]f64{g.w, g.h}/(2*v.zoom)
}

@(private = "file")
ui_bezier_point :: proc(a, b: [2]f64, t: f64) -> [2]f64 {
	dx := max(24.0, (b.x-a.x)*0.5)
	c1 := a+[2]f64{dx, 0}
	c2 := b-[2]f64{dx, 0}
	u := 1-t
	return u*u*u*a+3*u*u*t*c1+3*u*t*t*c2+t*t*t*b
}

@(private = "file")
ui_graph_edge_ends :: proc(ui: ^UI_State, from, to: pipeline.Stage_Id) -> (a, b: [2]f64) {
	rf := ui_graph_node_rect(ui, from)
	rt := ui_graph_node_rect(ui, to)
	return {rf.x+rf.w, rf.y+rf.h/2}, {rt.x, rt.y+rt.h/2}
}

GRAPH_EDGE_SAMPLES :: 24

// The edge nearest to (x, y) within a few points, as its two stages.
ui_graph_edge_at :: proc(ui: ^UI_State, x, y: f64) -> (from, to: pipeline.Stage_Id, found: bool) {
	if !ui_contains(ui_graph_rect(ui), x, y) {return}
	best := 6.0
	for id in pipeline.Stage_Id {
		for dep in pipeline.Stage_Id {
			if dep not_in pipeline.stage_descriptors[id].inputs {continue}
			a, b := ui_graph_edge_ends(ui, dep, id)
			previous := a
			for i in 1..=GRAPH_EDGE_SAMPLES {
				p := ui_bezier_point(a, b, f64(i)/GRAPH_EDGE_SAMPLES)
				d := ui_segment_distance({x, y}, previous, p)
				if d < best {
					best = d
					from, to, found = dep, id, true
				}
				previous = p
			}
		}
	}
	return
}

@(private = "file")
ui_segment_distance :: proc(p, a, b: [2]f64) -> f64 {
	ab := b-a
	length := ab.x*ab.x+ab.y*ab.y
	t := clamp(((p.x-a.x)*ab.x+(p.y-a.y)*ab.y)/length, 0, 1) if length > 0 else 0
	q := a+ab*t
	return math.hypot(p.x-q.x, p.y-q.y)
}

// Moves the selection along the graph: left to the deepest input, right to the first stage that
// reads the result, up and down within the column.
ui_graph_neighbour :: proc(id: pipeline.Stage_Id, key_code: u16) -> pipeline.Stage_Id {
	columns := pipeline.stage_columns()
	switch key_code {
	case 123:
		best := id
		for dep in pipeline.Stage_Id {
			if dep not_in pipeline.stage_descriptors[id].inputs {continue}
			if best == id || columns[dep] > columns[best] {best = dep}
		}
		return best
	case 124:
		for later in pipeline.Stage_Id {
			if later in pipeline.stage_dependents(id) {return later}
		}
	case 125, 126:
		down := key_code == 125
		previous, next := id, id
		found_next := false
		for other in pipeline.Stage_Id {
			if columns[other] != columns[id] || other == id {continue}
			if other < id {previous = other}
			if other > id && !found_next {next = other; found_next = true}
		}
		return next if down else previous
	}
	return id
}

ui_graph_menu_rect :: proc(ui: ^UI_State) -> UI_Rect {
	v := ui.workspace.graph
	w := 184.0
	h := 12+f64(len(GRAPH_MENU_ITEMS))*GRAPH_MENU_ROW
	x := clamp(v.menu_at.x, 4, max(4, ui.width-w-4))
	y := clamp(v.menu_at.y, 44, max(44, ui.height-h-4))
	return {x, y, w, h}
}

ui_graph_menu_item_rect :: proc(ui: ^UI_State, index: int) -> UI_Rect {
	m := ui_graph_menu_rect(ui)
	return {m.x+6, m.y+6+f64(index)*GRAPH_MENU_ROW, m.w-12, GRAPH_MENU_ROW-2}
}

ui_graph_menu_enabled :: proc(ui: ^UI_State, action: UI_Action) -> bool {
	v := ui.workspace.graph
	id := v.menu_stage
	#partial switch action {
	case .Graph_Menu_Run_To:
		return !ui.workspace.view.running
	case .Graph_Menu_Run_Only:
		return id in v.can_run_only
	case .Graph_Menu_Reset:
		return id in v.changed
	case .Graph_Menu_Evidence:
		return id in v.evidence
	case .Graph_Menu_Copy:
		for d in pipeline.setting_descriptors {
			if d.owner == id {return true}
		}
	}
	return false
}

ui_attribute_content_top :: proc(ui: ^UI_State) -> f64 {
	return ui_attribute_rect(ui).y+96
}

ui_attribute_advanced_rect :: proc(ui: ^UI_State) -> UI_Rect {
	a := ui_attribute_rect(ui)
	top := ui_attribute_content_top(ui)
	return {a.x+a.w-116, top, 108, 26}
}

// First row y and visible row count of the settings in the attribute editor.
ui_attribute_rows_area :: proc(ui: ^UI_State) -> (top: f64, rows: int) {
	a := ui_attribute_rect(ui)
	adv := ui_attribute_advanced_rect(ui)
	top = adv.y+adv.h+10
	rows = max(1, int((a.y+a.h-24-top)/ATTRIBUTE_ROW))
	return
}

// The setting row under (x, y) in the attribute editor.
ui_attribute_row_at :: proc(ui: ^UI_State, x, y: f64) -> (int, bool) {
	if !ui.workspace.graph.inspector_open || ui.workspace.graph.tab != .Settings {return 0, false}
	a := ui_attribute_rect(ui)
	top, visible := ui_attribute_rows_area(ui)
	if x < a.x || x > a.x+a.w || y < top {return 0, false}
	index := ui.workspace.scroll+int((y-top)/ATTRIBUTE_ROW)
	if index >= ui.workspace.scroll+visible || index >= len(ui.workspace.rows) {return 0, false}
	return index, true
}

ui_section_bar_rect :: proc(ui: ^UI_State) -> UI_Rect {
	vp := ui_viewport_rect(ui)
	return {vp.x+12, vp.y+vp.h-78, 106, 28}
}

// Controls ----------------------------------------------------------------------------------------

ui_graph_controls :: proc(ui: ^UI_State) {
	view := ui.workspace.view
	v := ui.workspace.graph

	g := ui_graph_rect(ui)
	for id in pipeline.Stage_Id {
		clipped := ui_rect_intersection(ui_graph_node_rect(ui, id), g)
		if clipped.w < 1 || clipped.h < 1 {continue}
		d := pipeline.stage_descriptors[id]
		ui_add_control(ui, d.name, d.purpose, clipped, ui_graph_node_action(id), true, 1, id == view.selected)
	}
	if ui_graph_minimap_visible(ui) {
		ui_add_control(ui, "graph overview", "move the graph view", ui_graph_minimap_rect(ui), .Graph_Minimap)
	}
	ui_add_control(ui, "fit graph", "fit the stage graph in view", {g.x+g.w-60, g.y+8, 52, 26}, .Graph_Fit)
	ui_add_control(ui, "graph divider", "resize the graph and the 3D view", ui_graph_divider_rect(ui), .Graph_Divider)

	vp := ui_viewport_rect(ui)
	insp_btn := UI_Rect{vp.x+vp.w-104, vp.y+12, 92, 30}
	ui_add_control(ui, "stage inspector", "toggle stage settings, log, and docs", insp_btn, .Graph_Inspector_Toggle, true, 1, v.inspector_open)

	// Floating viewport toolbar (wraps cleanly inside the 3D viewport when narrow).
	Toolbar_Item :: struct {
		name, label: string,
		width:       f64,
		action:      UI_Action,
		role:        i32,
		selected:    bool,
	}
	toolbar := [5]Toolbar_Item{
		{"frame mesh", "frame the complete mesh", 68, .Frame_Mesh, 0, false},
		{"wireframe", "toggle mesh wireframe", 90, .Toggle_Wireframe, 1, ui.wireframe},
		{"show mesh", "toggle the model mesh", 60, .View_Mesh, 1, v.show_mesh},
		{"show result", "toggle the stage result", 66, .View_Result, 1, v.show_result},
		{"lay on face", "Lay on face", 98, .Lay_On_Face, 1, ui.lay_on_face},
	}
	tx := vp.x+12
	ty := vp.y+12
	max_x := max(vp.x+120, insp_btn.x-8)
	for item in toolbar {
		if tx > vp.x+12 && tx+item.width > max_x {
			tx = vp.x+12
			ty += 36
		}
		ui_add_control(ui, item.name, item.label, {tx, ty, item.width, 30}, item.action, true, item.role, item.selected)
		tx += item.width+6
	}
	if ui_gcode_preview_visible(ui) {
		gx, gy := vp.x+12, ty+36
		ui_add_control(ui, "previous gcode view", "previous G-code color scheme", {gx, gy, 28, 30}, .View_GCode_Prev)
		ui_add_control(ui, "next gcode view", "cycle G-code color scheme", {gx+32, gy, 152, 30}, .View_GCode_Next)
		ui_add_control(ui, "single layer toggle", "toggle single layer vs stacked layers", {gx+190, gy, 76, 30}, .View_GCode_Single_Layer, true, 1, v.gcode_single_layer)
	}

	ui_add_control(ui, "section enabled", "toggle the layer view", ui_section_bar_rect(ui), .Toggle_Section, ui.section_max > 0)
	ui_add_control(ui, "section height", "layer height", ui_section_slider_rect(ui), .Section_Height, ui.section_max > 0)

	run_y := vp.y+vp.h-42
	ui_add_control(ui, "run stage", "cancel the run" if view.running else "run the selected stage and the stages it needs", {vp.x+12, run_y, 76, 30}, .Workspace_Run)
	ui_add_control(ui, "auto run", "toggle automatic refresh of stale stages", {vp.x+94, run_y, 86, 30}, .Workspace_Auto, true, 1, ui.workspace.auto_run)

	if v.inspector_open {
		a := ui_attribute_rect(ui)
		ui_add_control(ui, "inspector surface", "stage inspector", a, .Graph_Inspector_Surface)
		tab_w := (a.w-16)/3
		tab_names := [UI_Attribute_Tab]string{.Settings = "settings tab", .Log = "log tab", .Docs = "documentation tab"}
		tab_labels := [UI_Attribute_Tab]string{.Settings = "stage settings", .Log = "stage log and timing", .Docs = "stage documentation"}
		tab_actions := [UI_Attribute_Tab]UI_Action{.Settings = .Attribute_Settings, .Log = .Attribute_Log, .Docs = .Attribute_Docs}
		for tab in UI_Attribute_Tab {
			ui_add_control(ui, tab_names[tab], tab_labels[tab], {a.x+8+f64(tab)*tab_w, a.y+58, tab_w-4, 28}, tab_actions[tab], true, 1, v.tab == tab)
		}
		if v.tab == .Settings {
			ui_add_control(ui, "advanced settings", "show advanced settings", ui_attribute_advanced_rect(ui), .Attribute_Advanced, true, 1, v.advanced)
			top, visible := ui_attribute_rows_area(ui)
			ui.workspace.scroll = clamp(ui.workspace.scroll, 0, max(0, len(ui.workspace.rows)-visible))
			for row, index in ui.workspace.rows {
				if !row.editable {continue}
				if index < ui.workspace.scroll || index >= ui.workspace.scroll+visible {continue}
				y := top+f64(index-ui.workspace.scroll)*ATTRIBUTE_ROW+18
				right := a.x+a.w-8
				if row.kind == .Toggle {
					ui_add_control(ui, row.names[1], row.labels[1], {right-80, y, 80, 24}, ui_setting_action(index, 1))
				} else {
					ui_add_control(ui, row.names[0], row.labels[0], {right-80, y, 36, 24}, ui_setting_action(index, 0))
					ui_add_control(ui, row.names[1], row.labels[1], {right-40, y, 36, 24}, ui_setting_action(index, 1))
				}
			}
		}
	}

	if v.menu_open {
		ui_add_control(ui, "stage menu", "stage actions", ui_graph_menu_rect(ui), .Graph_Menu_Surface)
		for item, index in GRAPH_MENU_ITEMS {
			ui_add_control(ui, item.name, item.label, ui_graph_menu_item_rect(ui, index), item.action, ui_graph_menu_enabled(ui, item.action))
		}
	}
}

// Controls that the graph drawing paints itself instead of as buttons.
ui_graph_custom_control :: proc(action: UI_Action) -> bool {
	if _, is_node := ui_graph_node_action_index(action); is_node {return true}
	#partial switch action {
	case .Graph_Divider, .Graph_Minimap, .Graph_Inspector_Surface, .Graph_Menu_Surface,
	     .Graph_Menu_Run_To, .Graph_Menu_Run_Only, .Graph_Menu_Reset, .Graph_Menu_Evidence,
	     .Graph_Menu_Copy:
		return true
	}
	return false
}

// Drawing -----------------------------------------------------------------------------------------

GRAPH_GREEN :: Vec4{0.329, 0.565, 0.369, 1}
GRAPH_ORANGE :: Vec4{0.929, 0.561, 0.200, 1}
GRAPH_BLUE :: Vec4{0.329, 0.518, 0.796, 1}
GRAPH_GREY :: Vec4{0.553, 0.553, 0.537, 1}

ui_stage_color :: proc(ui: ^UI_State, stage: pipeline.Stage_View) -> Vec4 {
	if stage.queued {return GRAPH_BLUE}
	if stage.cancelled {return GRAPH_GREY}
	switch stage.state {
	case .Failed:            return ui_error_color(ui)
	case .Running:           return GRAPH_ORANGE
	case .Complete, .Stale:  return GRAPH_GREEN
	case .Not_Run:           return GRAPH_GREY
	}
	return GRAPH_GREY
}

ui_stage_state_text :: proc(stage: pipeline.Stage_View) -> string {
	if stage.queued {return "Queued"}
	if stage.cancelled {return "Cancelled"}
	return ui_workspace_state_text(stage.state)
}

// The status line of a stage: its state, and the cause for a stale or failed one.
ui_stage_status :: proc(ui: ^UI_State, stage: pipeline.Stage_View) -> string {
	if stage.queued || stage.cancelled {return ui_stage_state_text(stage)}
	switch stage.state {
	case .Stale:
		return fmt.tprintf("Stale: %s changed", pipeline.stage_descriptors[stage.changed_by].name)
	case .Failed:
		return ui.workspace.failure if len(ui.workspace.failure) > 0 else "Failed"
	case .Running:
		return fmt.tprintf("Running %.1f s", stage.elapsed_ms/1000)
	case .Not_Run, .Complete:
	}
	return ui_workspace_state_text(stage.state)
}

ui_draw_graph_panels :: proc(painter: ^UI_Painter, ui: ^UI_State) {
	theme := ui_theme(ui)
	ui_add_rect(painter, {0, 0, ui.width, 40}, theme.header)
	ui_add_rect(painter, {0, 39, ui.width, 1}, theme.border)
	g := ui_graph_rect(ui)
	ui_add_rect(painter, g, theme.surface)
	ui_add_border(painter, g, theme.border)
	d := ui_graph_divider_rect(ui)
	grip := theme.accent if ui.workspace.graph.split_dragging || ui.hovered_id == u64(UI_Action.Graph_Divider) else theme.border
	ui_add_round_rect(painter, {d.x+d.w/2-2, d.y+d.h/2-24, 4, 48}, 2, grip)
	if ui.workspace.graph.inspector_open {
		a := ui_attribute_rect(ui)
		ui_menu_shadow(painter, ui, a)
		bg := theme.overlay
		bg.w = 0.94
		ui_add_round_rect(painter, a, 8, bg)
		ui_add_border(painter, a, theme.border)
	}
}

@(private = "file")
ui_graph_font :: proc(painter: ^UI_Painter, ui: ^UI_State, scale: f64) -> (text.Font, bool) {
	size := math.round(BASE_FONT_SIZE*ui.workspace.graph.zoom*scale*2)/2
	if size < 5 {return {}, false}
	return text.font(painter.glyphs, {family = .Named, name = "Inter-Regular", size = f32(size)}), true
}

ui_draw_stage_graph :: proc(painter: ^UI_Painter, ui: ^UI_State) {
	theme := ui_theme(ui)
	view := ui.workspace.view
	v := ui.workspace.graph
	g := ui_graph_rect(ui)
	z := v.zoom
	gpu.push_clip(painter.list, ui_gpu_rect(g))

	// Edges first, so nodes cover their ends.
	for id in pipeline.Stage_Id {
		for dep in pipeline.Stage_Id {
			if dep not_in pipeline.stage_descriptors[id].inputs {continue}
			a, b := ui_graph_edge_ends(ui, dep, id)
			selected := dep == view.selected || id == view.selected
			hovered := v.hover_edge && v.hover_from == dep && v.hover_to == id
			color := theme.border
			if selected {color = theme.accent}
			if hovered {color = theme.text}
			width := f32(clamp((2.2 if selected || hovered else 1.4)*z, 0.8, 3))
			dashed := view.stages[dep].state == .Stale
			previous := a
			for i in 1..=GRAPH_EDGE_SAMPLES {
				p := ui_bezier_point(a, b, f64(i)/GRAPH_EDGE_SAMPLES)
				if !dashed || i%2 == 0 {
					gpu.draw_line(painter.list, {f32(previous.x), f32(previous.y)}, {f32(p.x), f32(p.y)}, width, ui_color(color), false)
				}
				previous = p
			}
		}
	}

	title_font, title_ok := ui_graph_font(painter, ui, 0.9)
	body_font, body_ok := ui_graph_font(painter, ui, 0.8)
	for id in pipeline.Stage_Id {
		r := ui_graph_node_rect(ui, id)
		if ui_rect_intersection(r, g).w <= 0 || ui_rect_intersection(r, g).h <= 0 {continue}
		stage := view.stages[id]
		d := pipeline.stage_descriptors[id]
		radius := f32(6*z)
		title_h := 22*z
		state_color := ui_stage_color(ui, stage)
		hovered := ui.hovered_id == u64(ui_graph_node_action(id))
		body := theme.raised
		if hovered {body = ui_theme_blend(theme, 0.12)}
		gpu.draw_box(painter.list, {rect = ui_gpu_rect(r), radii = {radius, radius, radius, radius}, fill = ui_color(body)})
		gpu.draw_rect(painter.list, ui_gpu_rect({r.x, r.y, r.w, title_h}), ui_color(state_color), {radius, radius, 0, 0})
		outline := theme.border
		outline_width := f32(1)
		if stage.state == .Stale {outline = GRAPH_ORANGE; outline_width = 2}
		if id == view.selected {outline = theme.accent; outline_width = 2.5}
		gpu.draw_box(painter.list, {rect = ui_gpu_rect(r), radii = {radius, radius, radius, radius}, border_color = ui_color(outline), border_width = outline_width})

		// Running indicator: a block that sweeps across the bottom of the title bar.
		if stage.state == .Running {
			track := UI_Rect{r.x+4*z, r.y+title_h-4*z, r.w-8*z, 3*z}
			phase := v.clock*0.8-math.floor(v.clock*0.8)
			block := UI_Rect{track.x+(track.w*0.7)*phase, track.y, track.w*0.3, track.h}
			ui_add_rect(painter, block, {1, 1, 1, 0.85})
		}
		if title_ok {
			ink := Vec4{0.98, 0.97, 0.94, 1} if stage.state != .Not_Run && !stage.cancelled else theme.text
			label := d.name
			if stage.cancelled {label = fmt.tprintf("× %s", d.name)}
			ui_draw_text(painter, title_font, ui, label, {r.x, r.y, r.w-(30*z if stage.state == .Stale else 0), title_h}, ink, 6*z)
			if stage.state == .Stale {
				badge := UI_Rect{r.x+r.w-30*z, r.y+4*z, 26*z, title_h-8*z}
				gpu.draw_rect(painter.list, ui_gpu_rect(badge), ui_color(GRAPH_ORANGE), {f32(3*z), f32(3*z), f32(3*z), f32(3*z)})
				if body_ok {ui_draw_text(painter, body_font, ui, "stale", badge, {0.1, 0.1, 0.1, 1}, 0, .Center)}
			}
		}
		if body_ok {
			line_h := (r.h-title_h)/2
			counts := ""
			if stage.state == .Complete || stage.state == .Stale {
				if len(d.counts[0]) > 0 {counts = fmt.tprintf("%s %d", d.counts[0], stage.count_a)}
			}
			timing := ui_stage_state_text(stage)
			switch {
			case stage.state == .Running:
				timing = fmt.tprintf("Running %.1f s", stage.elapsed_ms/1000)
			case stage.queued || stage.cancelled || stage.state == .Failed || stage.state == .Not_Run:
			case:
				timing = fmt.tprintf("%.1f ms", stage.duration_ms)
			}
			ui_draw_text(painter, body_font, ui, counts if len(counts) > 0 else d.purpose, {r.x, r.y+title_h, r.w, line_h}, theme.text if len(counts) > 0 else theme.muted, 6*z)
			ui_draw_text(painter, body_font, ui, timing, {r.x, r.y+title_h+line_h, r.w-16*z, line_h}, ui_error_color(ui) if stage.state == .Failed else theme.muted, 6*z)
			if id in v.evidence {
				ui_draw_text(painter, body_font, ui, "E", {r.x+r.w-18*z, r.y+title_h+line_h, 14*z, line_h}, theme.accent, 0, .Center)
			}
		}
	}
	gpu.pop_clip(painter.list)

	ui_draw_text(painter, painter.font, ui, "Fit", ui_control_rect(ui, .Graph_Fit), ui_control_ink(ui, .Graph_Fit), 0, .Center)
	if ui_graph_minimap_visible(ui) {ui_draw_graph_minimap(painter, ui)}

	// Hover details: the input an edge carries, and the cause of a stale result.
	if v.hover_edge {
		label := fmt.tprintf("%s → %s", pipeline.stage_descriptors[v.hover_from].name, pipeline.stage_descriptors[v.hover_to].name)
		ui_draw_tooltip(painter, ui, label)
	} else if id, is_node := ui_graph_node_action_index(UI_Action(ui.hovered_id)); is_node {
		stage := view.stages[id]
		if stage.state == .Stale || stage.state == .Failed {ui_draw_tooltip(painter, ui, ui_stage_status(ui, stage))}
	}
}

@(private = "file")
ui_draw_tooltip :: proc(painter: ^UI_Painter, ui: ^UI_State, label: string) {
	theme := ui_theme(ui)
	layout := text.layout(painter.glyphs, label, painter.font)
	w := 16.0
	if len(layout.lines) > 0 {w += f64(layout.lines[0].advance)}
	rect := UI_Rect{clamp(ui.pointer_x+14, 4, max(4, ui.width-w-4)), ui.pointer_y+18, w, 24}
	ui_add_round_rect(painter, rect, 5, theme.overlay)
	ui_add_border(painter, rect, theme.border)
	ui_draw_text(painter, painter.font, ui, label, rect, theme.text, 8)
}

@(private = "file")
ui_draw_graph_minimap :: proc(painter: ^UI_Painter, ui: ^UI_State) {
	theme := ui_theme(ui)
	m := ui_graph_minimap_rect(ui)
	fill := theme.overlay
	fill.w = 0.94
	ui_add_round_rect(painter, m, 5, fill)
	ui_add_border(painter, m, theme.border)
	origin, scale, lo := ui_minimap_scale(ui)
	for id in pipeline.Stage_Id {
		o := ui_graph_node_origin(id)
		p := origin+(o-lo)*scale
		ui_add_rect(painter, {p.x, p.y, GRAPH_NODE_W*scale, GRAPH_NODE_H*scale}, ui_stage_color(ui, ui.workspace.view.stages[id]))
	}
	g := ui_graph_rect(ui)
	v := ui.workspace.graph
	a := origin+(v.pan-lo)*scale
	view := UI_Rect{a.x, a.y, g.w/v.zoom*scale, g.h/v.zoom*scale}
	gpu.push_clip(painter.list, ui_gpu_rect(m))
	ui_add_border(painter, view, theme.accent, 1.5)
	gpu.pop_clip(painter.list)
}

ui_draw_graph_menu :: proc(painter: ^UI_Painter, ui: ^UI_State) {
	if !ui.workspace.graph.menu_open {return}
	theme := ui_theme(ui)
	m := ui_graph_menu_rect(ui)
	ui_menu_shadow(painter, ui, m)
	ui_add_round_rect(painter, m, 8, theme.overlay)
	ui_add_border(painter, m, theme.border)
	for item, index in GRAPH_MENU_ITEMS {
		r := ui_graph_menu_item_rect(ui, index)
		enabled := ui_graph_menu_enabled(ui, item.action)
		if enabled && ui.hovered_id == u64(item.action) {ui_add_round_rect(painter, r, 5, theme.accent)}
		ink := theme.text
		if !enabled {ink = theme.muted}
		if enabled && ui.hovered_id == u64(item.action) {ink = theme.accent_ink}
		ui_draw_text(painter, painter.font, ui, item.label, r, ink, 10)
	}
}

// Draws text in lines that fit the rectangle width and returns the height used.
@(private = "file")
ui_draw_wrapped :: proc(painter: ^UI_Painter, ui: ^UI_State, value: string, rect: UI_Rect, color: Vec4) -> f64 {
	if len(value) == 0 {return 0}
	measure_font := ui_font("Inter-Regular", BASE_FONT_SIZE)
	assert(measure_font != nil)
	defer CFRelease(measure_font)
	lines := make([dynamic]string, context.temp_allocator)
	ui_wrap_text(&lines, value, measure_font, rect.w, 0)
	row := 20.0
	for line, index in lines {
		y := rect.y+f64(index)*row
		if y+row > rect.y+rect.h {break}
		ui_draw_text(painter, painter.font, ui, line, {rect.x, y, rect.w, row}, color, 0)
	}
	return f64(len(lines))*row
}

ui_draw_attribute_editor :: proc(painter: ^UI_Painter, ui: ^UI_State) {
	if !ui.workspace.graph.inspector_open {return}
	theme := ui_theme(ui)
	view := ui.workspace.view
	v := ui.workspace.graph
	a := ui_attribute_rect(ui)
	id := view.selected
	stage := view.stages[id]
	d := pipeline.stage_descriptors[id]
	ui_draw_text(painter, painter.font, ui, d.name, {a.x+8, a.y+6, a.w-16, 24}, theme.text, 0)
	status_color := theme.muted
	if stage.state == .Stale || stage.state == .Failed {status_color = theme.accent}
	ui_draw_text(painter, painter.font, ui, ui_stage_status(ui, stage), {a.x+8, a.y+30, a.w-16, 22}, status_color, 0)
	tab_labels := [UI_Attribute_Tab]string{.Settings = "Settings", .Log = "Log", .Docs = "Docs"}
	tab_actions := [UI_Attribute_Tab]UI_Action{.Settings = .Attribute_Settings, .Log = .Attribute_Log, .Docs = .Attribute_Docs}
	for tab in UI_Attribute_Tab {
		ui_draw_text(painter, painter.font, ui, tab_labels[tab], ui_control_rect(ui, tab_actions[tab]), ui_control_ink(ui, tab_actions[tab]), 0, .Center)
	}
	top := ui_attribute_content_top(ui)
	width := a.w-24
	switch v.tab {
	case .Settings:
		adv := ui_attribute_advanced_rect(ui)
		ui_draw_text(painter, painter.font, ui, "Advanced", adv, ui_control_ink(ui, .Attribute_Advanced), 0, .Center)
		hidden := "" if v.hidden_advanced == 0 else fmt.tprintf("%d hidden", v.hidden_advanced)
		ui_draw_text(painter, painter.font, ui, hidden, {a.x+8, adv.y, adv.x-a.x-12, adv.h}, theme.muted, 0)
		ui_draw_setting_rows(painter, ui)
	case .Log:
		y := top
		auto := "Runs by itself after a change." if stage.auto_run else fmt.tprintf("Starts only with Run: the last run took over %.0f ms.", pipeline.WORKSPACE_AUTO_RUN_LIMIT_MS)
		if stage.state == .Complete || stage.state == .Stale || stage.state == .Failed {
			ui_draw_measurement(painter, ui, "Last run", fmt.tprintf("%.1f ms", stage.duration_ms), {a.x+12, y, width, 20}, 110)
			y += 22
		}
		y += ui_draw_wrapped(painter, ui, auto, {a.x+12, y, width, 60}, theme.muted)+8
		if stage.state == .Failed && len(ui.workspace.failure) > 0 {
			y += ui_draw_wrapped(painter, ui, ui.workspace.failure, {a.x+12, y, width, 100}, ui_error_color(ui))+8
		}
		log := ui.workspace.logs[id]
		count := pipeline.stage_log_len(log)
		if count == 0 {
			ui_draw_text(painter, painter.font, ui, "No events yet.", {a.x+12, y, width, 20}, theme.muted, 0)
			break
		}
		ui_draw_text(painter, painter.font, ui, "Recent events", {a.x+12, y, width, 20}, theme.text, 0)
		y += 24
		for index in 0..<count {
			if y+20 > a.y+a.h-8 {break}
			entry := pipeline.stage_log_recent(log, index)
			age := time.duration_seconds(time.since(entry.at))
			stamp := fmt.tprintf("%.0f s ago", age) if age < 120 else fmt.tprintf("%.0f min ago", age/60)
			what := ""
			switch entry.kind {
			case .Ran:       what = fmt.tprintf("Ran in %.1f ms", entry.duration_ms)
			case .Failed:    what = fmt.tprintf("Failed after %.1f ms", entry.duration_ms)
			case .Cancelled: what = "Cancelled"
			case .Stale:     what = fmt.tprintf("Stale: %s changed", pipeline.stage_descriptors[entry.cause].name)
			}
			ui_draw_text(painter, painter.mono, ui, stamp, {a.x+12, y, 92, 20}, theme.muted, 0, tracked = true)
			ui_draw_text(painter, painter.font, ui, what, {a.x+106, y, width-94, 20}, theme.text, 0)
			y += 20
		}
	case .Docs:
		y := top
		y += ui_draw_wrapped(painter, ui, d.purpose, {a.x+12, y, width, 80}, theme.text)+10
		inputs := ""
		for dep in pipeline.Stage_Id {
			if dep not_in d.inputs {continue}
			inputs = fmt.tprintf("%s%s%s", inputs, ", " if len(inputs) > 0 else "", pipeline.stage_descriptors[dep].name)
		}
		readers := ""
		for later in pipeline.Stage_Id {
			if later not_in pipeline.stage_dependents(id) {continue}
			readers = fmt.tprintf("%s%s%s", readers, ", " if len(readers) > 0 else "", pipeline.stage_descriptors[later].name)
		}
		ui_draw_text(painter, painter.font, ui, "Inputs", {a.x+12, y, width, 20}, theme.muted, 0)
		y += 20
		y += ui_draw_wrapped(painter, ui, inputs if len(inputs) > 0 else "The model file.", {a.x+12, y, width, 60}, theme.text)+8
		ui_draw_text(painter, painter.font, ui, "Read by", {a.x+12, y, width, 20}, theme.muted, 0)
		y += 20
		y += ui_draw_wrapped(painter, ui, readers if len(readers) > 0 else "None. This is the final output.", {a.x+12, y, width, 60}, theme.text)+8
		counts := [2]u64{stage.count_a, stage.count_b}
		for label, index in d.counts {
			if len(label) == 0 {continue}
			value := fmt.tprintf("%d", counts[index]) if stage.state == .Complete || stage.state == .Stale else "–"
			ui_draw_measurement(painter, ui, label, value, {a.x+12, y, width, 20}, 120)
			y += 22
		}
		owned := 0
		for setting in pipeline.setting_descriptors {
			if setting.owner == id {owned += 1}
		}
		y += 6
		ui_draw_text(painter, painter.font, ui, fmt.tprintf("Owns %d setting%s", owned, "" if owned == 1 else "s"), {a.x+12, y, width, 20}, theme.muted, 0)
		y += 22
		evidence := "Evidence: records in the loaded bundle." if id in v.evidence else "Evidence: none loaded for this stage."
		ui_draw_wrapped(painter, ui, evidence, {a.x+12, y, width, 40}, theme.muted)
	}
}

@(private = "file")
ui_draw_setting_rows :: proc(painter: ^UI_Painter, ui: ^UI_State) {
	theme := ui_theme(ui)
	a := ui_attribute_rect(ui)
	top, visible := ui_attribute_rows_area(ui)
	if len(ui.workspace.rows) == 0 {
		purpose := pipeline.stage_descriptors[ui.workspace.view.selected].purpose
		ui_draw_wrapped(painter, ui, fmt.tprintf("No settings. %s", purpose), {a.x+12, top, a.w-24, 100}, theme.muted)
		return
	}
	bold := text.font(painter.glyphs, {family = .Mono, weight = .Bold, size = BASE_FONT_SIZE})
	for row, index in ui.workspace.rows {
		if index < ui.workspace.scroll || index >= ui.workspace.scroll+visible {continue}
		row_y := top+f64(index-ui.workspace.scroll)*ATTRIBUTE_ROW
		label := row.label if len(row.unit) == 0 else fmt.tprintf("%s (%s)", row.label, row.unit)
		ui_draw_text(painter, painter.font, ui, label, {a.x+8, row_y, a.w-16, 18}, theme.muted if !row.editable else theme.text, 0)
		value_rect := UI_Rect{a.x+8, row_y+20, max(1.0, a.w-100), 22}
		if row.editable {
			if row.changed {
				ui_draw_text(painter, bold, ui, row.value, value_rect, theme.text, 0)
				ui_draw_text(painter, painter.font, ui, fmt.tprintf("default %s", row.default_value), {value_rect.x+70, value_rect.y, value_rect.w-70, 22}, theme.muted, 0)
			} else {
				ui_draw_text(painter, painter.mono, ui, row.value, value_rect, theme.text, 0, tracked = true)
			}
			if row.kind == .Toggle {
				action := ui_setting_action(index, 1)
				ui_draw_text(painter, painter.font, ui, "On" if row.value == "true" else "Off", ui_control_rect(ui, action), ui_control_ink(ui, action), 0, .Center)
			} else {
				minus := ui_setting_action(index, 0)
				plus := ui_setting_action(index, 1)
				ui_draw_text(painter, painter.font, ui, "−", ui_control_rect(ui, minus), ui_control_ink(ui, minus), 0, .Center)
				ui_draw_text(painter, painter.font, ui, "+", ui_control_rect(ui, plus), ui_control_ink(ui, plus), 0, .Center)
			}
		} else {
			ui_draw_text(painter, painter.mono, ui, row.value, {a.x+8, row_y+20, 80, 22}, theme.muted, 0, tracked = true)
			ui_draw_text(painter, painter.font, ui, fmt.tprintf("from %s", row.owner), {a.x+92, row_y+20, a.w-100, 22}, theme.muted, 0)
		}
	}
	if len(ui.workspace.rows) > visible {
		ui_draw_text(painter, painter.font, ui, fmt.tprintf("%d–%d of %d, scroll for more", ui.workspace.scroll+1, min(len(ui.workspace.rows), ui.workspace.scroll+visible), len(ui.workspace.rows)), {a.x+8, a.y+a.h-22, a.w-16, 20}, theme.muted, 0)
	} else {
		ui_draw_text(painter, painter.font, ui, "Right-click a setting to reset it.", {a.x+8, a.y+a.h-22, a.w-16, 20}, theme.muted, 0)
	}
}

ui_gcode_preview_visible :: proc(ui: ^UI_State) -> bool {
	v := ui.workspace.graph
	sel := ui.workspace.view.selected
	return (sel == .Motion || sel == .Gcode) && v.show_result && v.gcode_preview_ready
}

@(private = "file")
ui_gcode_legend_value :: proc(value: f32, mode: pipeline.GCode_View_Mode) -> string {
	switch mode {
	case .Line_Type:
		return ""
	case .Speed, .Actual_Speed, .Acceleration, .Temperature, .Fan_Speed, .Flow_Ratio, .Filament:
		return fmt.tprintf("%.0f", value)
	case .Volumetric_Flow, .Layer_Time, .Layer_Time_Log:
		return fmt.tprintf("%.1f", value)
	case .Layer_Height, .Line_Width, .Pressure_Advance:
		return fmt.tprintf("%.2f", value)
	}
	return fmt.tprintf("%.2f", value)
}

@(private = "file")
ui_draw_gcode_legend :: proc(painter: ^UI_Painter, ui: ^UI_State) {
	if !ui_gcode_preview_visible(ui) {return}
	theme := ui_theme(ui)
	vp := ui_viewport_rect(ui)
	v := ui.workspace.graph
	mode := v.gcode_mode
	info := pipeline.GCODE_VIEW_INFOS[mode]

	bg := theme.overlay
	bg.w = 0.92
	legend_right := vp.x + vp.w - 12
	if v.inspector_open {
		legend_right = ui_attribute_rect(ui).x - 12
	}
	if mode == .Line_Type {
		swatches := pipeline.GCODE_LINE_SWATCHES
		row_h := 18.0
		card_w := 152.0
		card_h := 32.0 + f64(len(swatches))*row_h + 8.0
		if vp.h < card_h + 150 || legend_right - card_w < vp.x + 12 {return}
		card := UI_Rect{legend_right - card_w, vp.y + 50, card_w, card_h}
		ui_add_rect(painter, card, bg)
		ui_add_border(painter, card, theme.border)
		ui_draw_text(painter, painter.font, ui, "Line type", {card.x+10, card.y+6, card.w-20, 20}, theme.muted, 0)
		for sw, idx in swatches {
			ry := card.y + 28 + f64(idx)*row_h
			col := Vec4{sw.color[0], sw.color[1], sw.color[2], 1}
			ui_add_round_rect(painter, {card.x+10, ry+3, 12, 12}, 2, col)
			ui_draw_text(painter, painter.font, ui, sw.label, {card.x+28, ry, card.w-36, row_h}, theme.text, 0)
		}
		return
	}

	card_w := 184.0
	bar_h := 140.0
	card_h := 38.0 + bar_h + 14.0
	if vp.h < card_h + 150 || legend_right - card_w < vp.x + 12 {return}
	card := UI_Rect{legend_right - card_w, vp.y + 50, card_w, card_h}
	ui_add_rect(painter, card, bg)
	ui_add_border(painter, card, theme.border)

	header := info.label
	if len(info.unit) > 0 {
		header = fmt.tprintf("%s (%s)", info.label, info.unit)
	}
	ui_draw_text(painter, painter.font, ui, header, {card.x+10, card.y+6, card.w-20, 22}, theme.muted, 0)

	bar := UI_Rect{card.x+12, card.y+34, 16, bar_h}
	steps :: 35
	strip_h := bar.h / f64(steps)
	for i in 0..<steps {
		t := 1.0 - f32(i)/f32(steps-1)
		c := pipeline.gcode_preview_heat_color(t)
		col := Vec4{c[0], c[1], c[2], 1}
		ui_add_rect(painter, {bar.x, bar.y + f64(i)*strip_h, bar.w, strip_h + 0.5}, col)
	}
	ui_add_border(painter, bar, theme.border)

	min_v := v.gcode_min
	max_v := v.gcode_max
	for ti in 0..<5 {
		frac := f32(4 - ti) / 4.0
		val: f32
		if mode == .Layer_Time_Log {
			lo := math.log10_f32(max(min_v, f32(0.1)))
			hi := math.log10_f32(max(max_v, max(min_v, f32(0.1)) + 0.001))
			val = math.pow_f32(10.0, lo + (hi - lo)*frac)
		} else {
			val = min_v + (max_v - min_v)*frac
		}
		ty := bar.y + f64(ti)*(bar.h/4.0) - 9.0
		label := ui_gcode_legend_value(val, mode)
		ui_draw_text(painter, painter.mono, ui, label, {bar.x + bar.w + 10, ty, card.w - (bar.w + 26), 18}, theme.text, 0, tracked = true)
	}
}

// The floating labels inside the 3D viewport of the graph workspace.
ui_draw_graph_view_labels :: proc(painter: ^UI_Painter, ui: ^UI_State) {
	theme := ui_theme(ui)
	labels := [6]struct {action: UI_Action, text: string}{
		{.Frame_Mesh, "Frame"},
		{.Toggle_Wireframe, "Wireframe"},
		{.View_Mesh, "Mesh"},
		{.View_Result, "Result"},
		{.Lay_On_Face, "Lay on face"},
		{.Graph_Inspector_Toggle, "Inspector"},
	}
	for label in labels {
		ui_draw_text(painter, painter.font, ui, label.text, ui_control_rect(ui, label.action), ui_control_ink(ui, label.action), 0, .Center)
	}
	if ui_gcode_preview_visible(ui) {
		v := ui.workspace.graph
		mode_label := fmt.tprintf("%s  ›", pipeline.GCODE_VIEW_INFOS[v.gcode_mode].label)
		ui_draw_text(painter, painter.font, ui, "‹", ui_control_rect(ui, .View_GCode_Prev), ui_control_ink(ui, .View_GCode_Prev), 0, .Center)
		ui_draw_text(painter, painter.font, ui, mode_label, ui_control_rect(ui, .View_GCode_Next), ui_control_ink(ui, .View_GCode_Next), 0, .Center)
		ui_draw_text(painter, painter.font, ui, "1 layer" if v.gcode_single_layer else "Stack", ui_control_rect(ui, .View_GCode_Single_Layer), ui_control_ink(ui, .View_GCode_Single_Layer), 0, .Center)
		ui_draw_gcode_legend(painter, ui)
	}
	vp := ui_viewport_rect(ui)
	section := ui_section_bar_rect(ui)
	ui_draw_text(painter, painter.font, ui, "Layer", {section.x+50, section.y, section.w-50, section.h}, theme.text, 0)
	slider := ui_section_slider_rect(ui)
	readout := fmt.tprintf("%.2f mm", ui.section_z)
	if ui.workspace.layer_count > 0 {
		readout = fmt.tprintf("Layer %d / %d · %.2f mm", ui.workspace.layer+1, ui.workspace.layer_count, ui.workspace.layer_z)
	}
	if !ui.section_enabled {readout = "Layer view off"}
	ui_draw_text(painter, painter.mono, ui, readout, {slider.x+slider.w+8, slider.y, max(0, vp.x+vp.w-12-(slider.x+slider.w+8)), slider.h}, theme.text, 0, tracked = true)
	if ui.section_enabled && ui.workspace.graph.show_result && !ui.workspace.result_shown && ui.workspace.view.selected != .Model {
		ui_draw_text(painter, painter.font, ui, "No result on this layer; showing the mesh section.", {vp.x+12, slider.y-24, vp.w-24, 20}, theme.muted, 0)
	}

	view := ui.workspace.view
	run_rect := ui_control_rect(ui, .Workspace_Run)
	auto_rect := ui_control_rect(ui, .Workspace_Auto)
	ui_draw_text(painter, painter.font, ui, "Cancel" if view.running else "Run", run_rect, ui_control_ink(ui, .Workspace_Run), 0, .Center)
	ui_draw_text(painter, painter.font, ui, "Auto on" if ui.workspace.auto_run else "Auto off", auto_rect, ui_control_ink(ui, .Workspace_Auto), 0, .Center)
	complete, stale, failed := 0, 0, 0
	for stage in view.stages {
		switch stage.state {
		case .Complete:          complete += 1
		case .Stale:             stale += 1
		case .Failed:            failed += 1
		case .Not_Run, .Running:
		}
	}
	summary := fmt.tprintf("%s · %d complete, %d stale, %d failed", pipeline.stage_descriptors[view.selected].name, complete, stale, failed)
	if view.running {
		summary = fmt.tprintf("%s · running to %s", summary, pipeline.stage_descriptors[view.active].name)
	}
	if view.queued_edits > 0 {summary = fmt.tprintf("%s · %d queued edit%s", summary, view.queued_edits, "" if view.queued_edits == 1 else "s")}
	summary_x := auto_rect.x+auto_rect.w+10
	ui_draw_text(painter, painter.font, ui, summary, {summary_x, auto_rect.y, max(0, vp.x+vp.w-12-summary_x), auto_rect.h}, theme.muted, 0)
}

// The status line at the bottom of the stage graph pane.
ui_draw_graph_status :: proc(painter: ^UI_Painter, ui: ^UI_State, status: string, failed: bool) {
	if status == "" {return}
	g := ui_graph_rect(ui)
	color := ui_theme(ui).muted
	if failed {color = ui_error_color(ui)}
	right_pad := ui_graph_minimap_rect(ui).w+16 if ui_graph_minimap_visible(ui) else 12.0
	ui_draw_text(painter, painter.font, ui, status, {g.x+10, g.y+g.h-28, max(0, g.w-10-right_pad), 22}, color, 0)
}
