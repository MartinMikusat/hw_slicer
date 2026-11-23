package main

import "core:fmt"
import "core:math"
import gpu "rune:gpu"
import flash "flash:."
import design "./design"

Profile_Selection :: struct {
	object, loop, anchor, control: int,
}

Profile_Editor :: struct {
	active, dragging, panning: bool,
	button: i32,
	selected: Profile_Selection,
	center: [2]f64,
	scale: f64,
	press: [2]f64,
	before: design.Bezier_Anchor,
}

profile_first_object :: proc(s: ^Design_State) -> int {
	for obj, i in s.evaluated.objects {
		if obj.profile != nil {return i}
	}
	return -1
}

profile_anchor :: proc(s: ^Design_State, selection: Profile_Selection) -> ^design.Bezier_Anchor {
	if selection.object < 0 || selection.object >= len(s.evaluated.objects) {return nil}
	profile := s.evaluated.objects[selection.object].profile
	if profile == nil || selection.loop < 0 || selection.loop >= len(profile.loops) {return nil}
	anchors := profile.loops[selection.loop].anchors
	if selection.anchor < 0 || selection.anchor >= len(anchors) {return nil}
	return &anchors[selection.anchor]
}

profile_control_positions :: proc(anchor: design.Bezier_Anchor, origin: [2]f64) -> [3][2]f64 {
	points := design.anchor_controls(anchor)
	points[0] += origin
	points[1] += points[0]
	points[2] += points[0]
	return points
}

profile_canvas :: proc(view: UI_Rect) -> UI_Rect {
	return {view.x+8, view.y+86, max(1, view.w-16), max(1, view.h-108)}
}

profile_screen :: proc(e: ^Profile_Editor, canvas: UI_Rect, point: [2]f64) -> [2]f64 {
	mid := [2]f64{canvas.x+canvas.w/2, canvas.y+canvas.h/2}
	return mid+(point-e.center)*[2]f64{e.scale, -e.scale}
}

profile_editor_fit :: proc(s: ^Design_State, view: UI_Rect) {
	low := [2]f64{max(f64), max(f64)}
	high := -low
	for obj in s.evaluated.objects {
		if obj.profile == nil {continue}
		for loop in obj.profile.loops {
			for anchor in loop.anchors {
				for point in profile_control_positions(anchor, obj.center) {
					low = {min(low.x, point.x), min(low.y, point.y)}
					high = {max(high.x, point.x), max(high.y, point.y)}
				}
			}
		}
	}
	if high.x < low.x {return}
	canvas := profile_canvas(view)
	s.editor.center = (low+high)/2
	s.editor.scale = clamp(min(canvas.w/max(1, high.x-low.x), canvas.h/max(1, high.y-low.y))*0.86, 0.001, 4096)
}

profile_editor_toggle :: proc() {
	s := &app.design
	e := &s.editor
	first := profile_first_object(s)
	if first < 0 || e.dragging {return}
	if e.active && s.profile_dirty && !s.profile_valid {
		app_set_status(s.profile_error, true)
		return
	}
	e.active = !e.active
	e.panning = false
	if e.active {
		s.playing = false
		s.selected_junction = -1
		if e.scale <= 0 || profile_anchor(s, e.selected) == nil {
			e.selected = {object = first}
			profile_editor_fit(s, ui_viewport_rect(&app.ui))
		}
	}
	app.needs_redraw = true
}

profile_editor_next_control :: proc() {
	s := &app.design
	e := &s.editor
	if !e.active || e.dragging {return}
	sel := &e.selected
	sel.control = (sel.control+1)%3
	if sel.control == 0 {
		loops := s.evaluated.objects[sel.object].profile.loops
		sel.anchor = (sel.anchor+1)%len(loops[sel.loop].anchors)
		if sel.anchor == 0 {
			sel.loop = (sel.loop+1)%len(loops)
			if sel.loop == 0 {
				for {
					sel.object = (sel.object+1)%len(s.evaluated.objects)
					if s.evaluated.objects[sel.object].profile != nil {break}
				}
			}
		}
	}
	app.needs_redraw = true
}

profile_pick_control :: proc(s: ^Design_State, canvas: UI_Rect, mouse: [2]f64) -> (Profile_Selection, bool) {
	e := &s.editor
	best := 10.0
	selection: Profile_Selection
	found := false
	for obj, oi in s.evaluated.objects {
		if obj.profile == nil {continue}
		for loop, li in obj.profile.loops {
			for anchor, ai in loop.anchors {
				selected := e.selected.object == oi && e.selected.loop == li && e.selected.anchor == ai
				for point, ci in profile_control_positions(anchor, obj.center) {
					if ci != 0 && !selected {continue}
					delta := mouse-profile_screen(e, canvas, point)
					d := math.hypot(delta.x, delta.y)
					if d < best || (found && d == best && selected && ci == e.selected.control) {
						best = d
						selection = {oi, li, ai, ci}
						found = true
					}
				}
			}
		}
	}
	return selection, found
}

profile_editor_cancel_drag :: proc() {
	s := &app.design
	e := &s.editor
	if e.dragging {
		if anchor := profile_anchor(s, e.selected); anchor != nil {anchor^ = e.before}
		e.before = {}
		e.dragging = false
	}
	e.panning = false
	app.needs_redraw = true
}

profile_editor_mouse :: proc(phase, button: i32, mouse: [2]f64) -> bool {
	s := &app.design
	e := &s.editor
	if !e.active || app.ui.settings_open || app.ui.evidence_open || app.ui.help_open || flash.is_active(&app.ui.flash_state) {return false}
	canvas := profile_canvas(ui_viewport_rect(&app.ui))
	if (e.dragging || e.panning) && phase < 3 && (phase == 0 || button != e.button) {return true}
	if e.dragging && (phase == 1 || phase == 2) {
		anchor := profile_anchor(s, e.selected)
		if anchor == nil {profile_editor_cancel_drag(); return true}
		delta := (mouse-e.press)/[2]f64{e.scale, -e.scale}
		anchor^ = e.before
		if delta != {} {design.move_anchor_control(anchor, e.selected.control, delta)}
		if phase == 2 {
			e.before = {}
			e.dragging = false
			if delta != {} {_ = app_profile_apply_draft()}
		}
		app.needs_redraw = true
		return true
	}
	if e.panning && (phase == 1 || phase == 2) {
		e.center -= (mouse-e.press)/[2]f64{e.scale, -e.scale}
		e.press = mouse
		e.panning = phase != 2
		app.needs_redraw = true
		return true
	}
	if phase != 0 || !ui_contains(canvas, mouse.x, mouse.y) {return false}
	if ui_hit_test(&app.ui, mouse.x, mouse.y) != 0 {return false}
	e.press = mouse
	e.button = button
	app.ui.focused_id = 0
	if selected, found := profile_pick_control(s, canvas, mouse); button == 0 && found {
		e.selected = selected
		e.before = profile_anchor(s, selected)^
		e.dragging = true
	} else {
		e.panning = true
	}
	app.needs_redraw = true
	return true
}

profile_editor_zoom :: proc(delta_y: f64) {
	e := &app.design.editor
	canvas := profile_canvas(ui_viewport_rect(&app.ui))
	mouse := [2]f64{app.ui.pointer_x, app.ui.pointer_y}
	if !ui_contains(canvas, mouse.x, mouse.y) || e.dragging || e.panning || e.scale <= 0 {return}
	mid := [2]f64{canvas.x+canvas.w/2, canvas.y+canvas.h/2}
	relative := (mouse-mid)*[2]f64{1, -1}
	scale := clamp(e.scale*math.exp(clamp(delta_y*0.03, -1, 1)), 0.001, 4096)
	e.center += relative*(1/e.scale-1/scale)
	e.scale = scale
	app.needs_redraw = true
}

profile_editor_key :: proc(code: u16, modifiers: u64) -> bool {
	s := &app.design
	e := &s.editor
	if !s.active || app.ui.settings_open || app.ui.evidence_open || app.ui.help_open || flash.is_active(&app.ui.flash_state) {return false}
	if code == 1 && modifiers & (1<<20) != 0 && (e.active || s.profile_dirty) {
		if !e.dragging {_ = app_profile_save()}
		return true
	}
	if !e.active {return false}
	if code == 53 && (e.dragging || e.panning) {profile_editor_cancel_drag(); return true}
	if e.dragging || e.panning {return true}
	if code < 123 || code > 126 || (app.ui.focused_id != 0 && app.ui.focused_id != u64(UI_Action.Profile_Point)) {return false}
	anchor := profile_anchor(s, e.selected)
	if anchor == nil {return false}
	directions := [4][2]f64{{-1, 0}, {1, 0}, {0, -1}, {0, 1}}
	step := 1.0 if modifiers & (1<<17) != 0 else 0.1
	design.move_anchor_control(anchor, e.selected.control, directions[code-123]*step)
	_ = app_profile_apply_draft()
	app.needs_redraw = true
	return true
}

ui_profile_controls :: proc(ui: ^UI_State, view: UI_Rect) {
	width := max(1.0, min(90.0, (view.w-34)/4))
	actions := [4]UI_Action{.Profile_Edit, .Profile_Fit, .Profile_Save, .Profile_Discard}
	names := [4]string{"profile preview", "fit profile", "save profile", "discard profile"}
	labels := [4]string{"Show 3D bead preview", "Fit all profile points", "Save design and G-code", "Discard edits and reload the design"}
	enabled := [4]bool{ui.profile_preview_enabled, true, ui.profile_save_enabled, ui.profile_discard_enabled}
	for action, i in actions {
		ui_add_control(ui, names[i], labels[i], {view.x+8+f64(i)*(width+6), view.y+8, width, 30}, action, enabled[i])
	}
	ui_add_control(ui, "next profile point", "Select next anchor or handle. Arrow keys move the selected point.",
	               {view.x+8, view.y+46, 92, 28}, .Profile_Point)
}

ui_profile_button_labels :: proc(painter: ^UI_Painter, ui: ^UI_State) {
	actions := [5]UI_Action{.Profile_Edit, .Profile_Fit, .Profile_Save, .Profile_Discard, .Profile_Point}
	labels := [5]string{"Preview" if ui.profile_editing else "Edit profile", "Fit", "Save", "Discard", "Next point"}
	for action, i in actions {
		ui_draw_text(painter, painter.font, ui, labels[i], ui_control_rect(ui, action), ui_control_ink(ui, action), 0, .Center)
	}
}

ui_draw_profile :: proc(p: ^UI_Painter, ui: ^UI_State, s: ^Design_State) {
	if s == nil {return}
	e := &s.editor
	view := ui_viewport_rect(ui)
	canvas := profile_canvas(view)
	theme := ui_theme(ui)
	ui_add_rect(p, view, theme.surface)
	ui_add_rect(p, canvas, theme.canvas)
	ui_add_border(p, canvas, theme.border)
	{
		gpu.push_clip(p.list, ui_gpu_rect(canvas))
		defer gpu.pop_clip(p.list)
		if !e.dragging && (!s.profile_dirty || s.profile_valid) && ui.design_layer >= 0 && ui.design_layer < len(s.layers) {
			layer := s.layers[ui.design_layer]
			for bead in s.beads[layer.first_bead:layer.end_bead] {
				if bead.width <= 0 {continue}
				a := profile_screen(e, canvas, {f64(bead.a.x), f64(bead.a.y)})
				b := profile_screen(e, canvas, {f64(bead.b.x), f64(bead.b.y)})
				gpu.draw_line(p.list, {f32(a.x), f32(a.y)}, {f32(b.x), f32(b.y)}, f32(max(0.4, f64(bead.width)*e.scale)), ui_color(theme.bead))
			}
		}
		points := make([dynamic][2]f64, context.temp_allocator)
		defer delete(points)
		for obj, oi in s.evaluated.objects {
			if obj.profile == nil {continue}
			for loop, li in obj.profile.loops {
				for anchor, ai in loop.anchors {
					clear(&points)
					if !design.flatten_profile_segment(anchor, loop.anchors[(ai+1)%len(loop.anchors)], &points) {continue}
					pt := design.anchor_controls(anchor)[0]
					last := profile_screen(e, canvas, obj.center+pt)
					for endpoint in points {
						next := profile_screen(e, canvas, obj.center+endpoint)
						gpu.draw_line(p.list, {f32(last.x), f32(last.y)}, {f32(next.x), f32(next.y)}, 1.5, ui_color(theme.text))
						last = next
					}
				}
				for anchor, ai in loop.anchors {
					selected := e.selected.object == oi && e.selected.loop == li && e.selected.anchor == ai
					controls := profile_control_positions(anchor, obj.center)
					at := profile_screen(e, canvas, controls[0])
					if selected {
						for i in 1..=2 {
							handle := profile_screen(e, canvas, controls[i])
							gpu.draw_line(p.list, {f32(at.x), f32(at.y)}, {f32(handle.x), f32(handle.y)}, 1.5, ui_color(theme.accent))
							ui_add_round_rect(p, {handle.x-4, handle.y-4, 8, 8}, 4, theme.accent if e.selected.control == i else theme.text)
						}
					}
					ui_add_rect(p, {at.x-4, at.y-4, 8, 8}, theme.accent if selected else theme.text)
				}
			}
		}
		if issue, located := s.profile_issue_xy.?; located && s.profile_dirty && !s.profile_valid && !e.dragging {
			xy := profile_screen(e, canvas, issue)
			point := [2]f32{f32(xy.x), f32(xy.y)}
			for diagonal in ([2][2]f32{{7, 7}, {7, -7}}) {
				gpu.draw_line(p.list, point-diagonal, point+diagonal, 5, ui_color(theme.canvas))
				gpu.draw_line(p.list, point-diagonal, point+diagonal, 2.5, ui_color(ui_error_color(ui)))
			}
		}
	}
	ui_draw_text(p, p.font, ui, profile_selection_label(s),
	             {view.x+106, view.y+46, view.w-114, 28}, theme.text, 0)
}

profile_selection_label :: proc(s: ^Design_State) -> string {
	selection := s.editor.selected
	anchor := profile_anchor(s, selection)
	if anchor == nil {return ""}
	obj := &s.evaluated.objects[selection.object]
	controls := [3]string{"anchor", "incoming handle", "outgoing handle"}
	point := profile_control_positions(anchor^, obj.center)[selection.control]
	return fmt.tprintf("%s / %s / %s · %s · %.2f, %.2f mm",
		obj.name, obj.profile.loops[selection.loop].name, anchor.name,
		controls[selection.control], point.x, point.y)
}
