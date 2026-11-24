package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"
import devlog "devlog:."
import text_input "components:text_input"
import "rune:gpu"

import mr "./moonraker"

PRINTER_DEFAULT_ENDPOINT :: "http://ratos.local/"
PRINTER_LOCAL_ENDPOINT :: "http://127.0.0.1:7125/"
PRINTER_MAX_HEATERS :: 8
PRINTER_MAX_VISIBLE_FILES :: 48
PRINTER_JOG_STEPS := [4]f64{0.1, 1.0, 10.0, 50.0}
PRINTER_JOG_FEED_XY :: 80.0
PRINTER_JOG_FEED_Z :: 15.0

Printer_Subtab :: enum u8 {
	Control,
	Files,
	Console,
	Config,
	Connection,
}

Printer_State :: struct {
	client:         mr.Client,
	tracking:       Print_Tracking,
	initialized:    bool,
	demo:           bool,
	subtab:         Printer_Subtab,
	edit:           text_input.State,
	endpoint:       string,
	api_key:        string,
	heater_drafts:  [PRINTER_MAX_HEATERS]string,
	move_drafts:    [3]string,
	jog_step_index: int,
	history_range:  int, // 0 = 1m, 1 = 5m, 2 = 20m
	selected_file:  string,
	files_scroll:   int,
	console_scroll: int,
	download_dest:  string,
	last_revision:  u64,
	notice:         string,
	notice_failed:  bool,
}

ui_printer_mode :: proc(ui: ^UI_State) -> bool {
	return ui.active_tab == .Printer && !ui.design_active
}

printer_set_notice :: proc(p: ^Printer_State, text: string, failed := false) {
	delete(p.notice)
	p.notice = strings.clone(text)
	p.notice_failed = failed
	app.needs_redraw = true
}

printer_state_init :: proc(p: ^Printer_State) {
	p^ = {
		jog_step_index = 2, // 10 mm
		history_range  = 1, // 5 min
	}
	mr.initialize(&p.client, limited = true)
	p.endpoint = strings.clone(PRINTER_DEFAULT_ENDPOINT)
	p.initialized = true
	// Auto-connect in the background on launch (non-blocking).
	if !mr.connect(&p.client, p.endpoint, p.api_key) {
		printer_set_notice(p, p.client.state.error if len(p.client.state.error) > 0 else "Unable to start Moonraker connection", true)
	}
}

printer_state_destroy :: proc(p: ^Printer_State) {
	if !p.initialized {return}
	printer_tracking_destroy(p)
	mr.destroy(&p.client)
	text_input.destroy(&p.edit)
	delete(p.endpoint)
	delete(p.api_key)
	delete(p.selected_file)
	delete(p.download_dest)
	delete(p.notice)
	for &d in p.heater_drafts {delete(d)}
	for &d in p.move_drafts {delete(d)}
	p^ = {}
}

// Polls Moonraker every frame (even while on other tabs so live telemetry stays warm).
app_printer_poll :: proc() {
	p := &app.printer
	if !p.initialized {return}
	changed := mr.poll(&p.client)
	if printer_tracking_step(p) {changed = true}
	// Handle completed file downloads to disk.
	if len(p.download_dest) > 0 && p.client.state.transfer.kind == .Download {
		switch p.client.state.transfer.status {
		case .Complete:
			if os.write_entire_file(p.download_dest, p.client.state.transfer.data) == nil {
				printer_set_notice(p, fmt.tprintf("Saved %s", filepath.base(p.download_dest)))
			} else {
				printer_set_notice(p, "Failed to write downloaded file", true)
			}
			delete(p.download_dest)
			p.download_dest = ""
			changed = true
		case .Failed, .Cancelled:
			printer_set_notice(p, p.client.state.error if len(p.client.state.error) > 0 else "File download failed", true)
			delete(p.download_dest)
			p.download_dest = ""
			changed = true
		case .Idle, .Running:
		}
	}
	if ui_printer_mode(&app.ui) && p.subtab == .Files {
		visible := printer_files_visible_rows(&app.ui)
		if mr.file_info_step(&p.client, p.selected_file, p.files_scroll, visible) {
			changed = true
		}
	}
	if changed || p.client.state.revision != p.last_revision {
		p.last_revision = p.client.state.revision
		if ui_printer_mode(&app.ui) {
			app.needs_redraw = true
		}
	}
}

// Text field helpers (components:text_input) ------------------------------------------------------

@(private = "file")
printer_field_ptr :: proc(p: ^Printer_State, field: text_input.Field_ID) -> ^string {
	action := UI_Action(u64(field))
	#partial switch action {
	case .Printer_Conn_Endpoint: return &p.endpoint
	case .Printer_Conn_Api_Key:  return &p.api_key
	case .Printer_Move_X_Field:  return &p.move_drafts[0]
	case .Printer_Move_Y_Field:  return &p.move_drafts[1]
	case .Printer_Move_Z_Field:  return &p.move_drafts[2]
	}
	if idx, ok := printer_heater_field_index(action); ok && idx < PRINTER_MAX_HEATERS {
		return &p.heater_drafts[idx]
	}
	return nil
}

@(private = "file")
printer_paste_text :: proc() -> (string, bool) {
	pasteboard_class := objc_getClass("NSPasteboard")
	if pasteboard_class == nil {return "", false}
	pasteboard := msg_id(pasteboard_class, sel_registerName("generalPasteboard"))
	if pasteboard == nil {return "", false}
	ns_type := ui_cf_string("public.utf8-plain-text")
	if ns_type == nil {return "", false}
	defer CFRelease(ns_type)
	ns_str := msg_id_id(pasteboard, sel_registerName("stringForType:"), ns_type)
	if ns_str == nil {return "", false}
	utf8_fn := transmute(proc "c" (Id, Sel) -> cstring)objc_send_address
	cstr := utf8_fn(ns_str, sel_registerName("UTF8String"))
	if cstr == nil {return "", false}
	return strings.clone(string(cstr), context.temp_allocator), true
}

printer_focus_field :: proc(p: ^Printer_State, action: UI_Action) {
	fid := text_input.Field_ID(u64(action))
	ptr := printer_field_ptr(p, fid)
	if ptr == nil {return}
	_ = text_input.focus(&p.edit, fid, ptr^)
	app.needs_redraw = true
}

printer_blur_field :: proc(p: ^Printer_State) {
	if p.edit.active_field == text_input.NO_FIELD {return}
	ptr := printer_field_ptr(p, p.edit.active_field)
	_ = text_input.blur(&p.edit, ptr)
	app.needs_redraw = true
}

// Returns true when the key event was handled by the active Printer text field or view.
app_printer_key :: proc(key_code: u16, characters: string, modifiers: u64) -> bool {
	if !ui_printer_mode(&app.ui) || app.ui.settings_open || app.ui.help_open || app.ui.evidence_open {
		return false
	}
	p := &app.printer
	if p.edit.active_field == text_input.NO_FIELD {return false}
	ptr := printer_field_ptr(p, p.edit.active_field)
	if ptr == nil {
		printer_blur_field(p)
		return false
	}

	shift := (modifiers & (1 << 17)) != 0
	alt := (modifiers & (1 << 19)) != 0
	cmd := (modifiers & (1 << 20)) != 0

	// Escape: blur active field without submitting.
	if key_code == 53 {
		printer_blur_field(p)
		return true
	}
	// Return / Enter: submit field.
	if key_code == 36 || key_code == 76 {
		active := UI_Action(u64(p.edit.active_field))
		printer_blur_field(p)
		printer_submit_field(p, active)
		return true
	}
	// Clipboard and select-all shortcuts.
	if cmd {
		lower := strings.to_lower(characters, context.temp_allocator)
		switch lower {
		case "a":
			text_input.set_selection(&p.edit, ptr^, 0, len(ptr^))
			app.needs_redraw = true
			return true
		case "c":
			if start, end := text_input.selection_bounds(&p.edit, ptr^); end > start {
				_ = app_copy_text(ptr^[start:end])
			}
			return true
		case "x":
			if start, end := text_input.selection_bounds(&p.edit, ptr^); end > start {
				_ = app_copy_text(ptr^[start:end])
				_ = text_input.remove_selection(&p.edit, ptr)
				app.needs_redraw = true
			}
			return true
		case "v":
			if pasted, ok := printer_paste_text(); ok && len(pasted) > 0 {
				clean, _ := strings.replace_all(pasted, "\n", "", context.temp_allocator)
				clean2, _ := strings.replace_all(clean, "\r", "", context.temp_allocator)
				_ = text_input.insert_text(&p.edit, ptr, clean2)
				app.needs_redraw = true
			}
			return true
		}
		return false
	}
	// Navigation & deletion keys.
	switch key_code {
	case 51: // Backspace
		if alt {
			_ = text_input.delete_word_backward(&p.edit, ptr)
		} else {
			_ = text_input.delete_backward(&p.edit, ptr)
		}
		app.needs_redraw = true
		return true
	case 117: // Forward delete
		_ = text_input.delete_forward(&p.edit, ptr)
		app.needs_redraw = true
		return true
	case 123: // Left
		if alt {
			text_input.move_word_left(&p.edit, ptr^, shift)
		} else {
			text_input.move_left(&p.edit, ptr^, shift)
		}
		app.needs_redraw = true
		return true
	case 124: // Right
		if alt {
			text_input.move_word_right(&p.edit, ptr^, shift)
		} else {
			text_input.move_right(&p.edit, ptr^, shift)
		}
		app.needs_redraw = true
		return true
	case 115: // Home
		text_input.move_line_start(&p.edit, ptr^, shift)
		app.needs_redraw = true
		return true
	case 119: // End
		text_input.move_line_end(&p.edit, ptr^, shift)
		app.needs_redraw = true
		return true
	}
	// Printable UTF-8 characters.
	if len(characters) > 0 && characters[0] >= 0x20 && characters[0] != 0x7f {
		_ = text_input.insert_text(&p.edit, ptr, characters)
		app.needs_redraw = true
		return true
	}
	return true
}

@(private = "file")
printer_submit_field :: proc(p: ^Printer_State, action: UI_Action) {
	#partial switch action {
	case .Printer_Conn_Endpoint, .Printer_Conn_Api_Key:
		printer_connect_current(p)
	case .Printer_Move_X_Field:
		printer_submit_move(p, 0)
	case .Printer_Move_Y_Field:
		printer_submit_move(p, 1)
	case .Printer_Move_Z_Field:
		printer_submit_move(p, 2)
	case:
		if idx, ok := printer_heater_field_index(action); ok {
			printer_submit_heater(p, idx, false)
		}
	}
}

// Action ID helpers -------------------------------------------------------------------------------

printer_heater_field_action :: proc(index: int) -> UI_Action {
	return UI_Action(u64(UI_Action.Printer_Heater_Field_Base) + u64(index))
}
printer_heater_field_index :: proc(action: UI_Action) -> (int, bool) {
	id := u64(action)
	base := u64(UI_Action.Printer_Heater_Field_Base)
	if id < base || id-base >= PRINTER_MAX_HEATERS {return 0, false}
	return int(id-base), true
}

printer_heater_set_action :: proc(index: int) -> UI_Action {
	return UI_Action(u64(UI_Action.Printer_Heater_Set_Base) + u64(index))
}
printer_heater_set_index :: proc(action: UI_Action) -> (int, bool) {
	id := u64(action)
	base := u64(UI_Action.Printer_Heater_Set_Base)
	if id < base || id-base >= PRINTER_MAX_HEATERS {return 0, false}
	return int(id-base), true
}

printer_heater_off_action :: proc(index: int) -> UI_Action {
	return UI_Action(u64(UI_Action.Printer_Heater_Off_Base) + u64(index))
}
printer_heater_off_index :: proc(action: UI_Action) -> (int, bool) {
	id := u64(action)
	base := u64(UI_Action.Printer_Heater_Off_Base)
	if id < base || id-base >= PRINTER_MAX_HEATERS {return 0, false}
	return int(id-base), true
}

printer_file_row_action :: proc(index: int) -> UI_Action {
	return UI_Action(u64(UI_Action.Printer_File_Row_Base) + u64(index))
}
printer_file_row_index :: proc(action: UI_Action) -> (int, bool) {
	id := u64(action)
	base := u64(UI_Action.Printer_File_Row_Base)
	if id < base || id-base >= PRINTER_MAX_VISIBLE_FILES {return 0, false}
	return int(id-base), true
}

// Commands ----------------------------------------------------------------------------------------

@(private = "file")
printer_connect_current :: proc(p: ^Printer_State) {
	p.demo = false
	if mr.connect(&p.client, p.endpoint, p.api_key) {
		printer_set_notice(p, fmt.tprintf("Connecting to %s", p.endpoint))
	} else {
		printer_set_notice(p, p.client.state.error if len(p.client.state.error) > 0 else "Connection failed", true)
	}
}

@(private = "file")
printer_submit_heater :: proc(p: ^Printer_State, index: int, turn_off: bool) {
	if index < 0 || index >= len(p.client.state.heaters) || index >= PRINTER_MAX_HEATERS {return}
	h := p.client.state.heaters[index]
	target := 0.0
	if !turn_off {
		val, ok := strconv.parse_f64(strings.trim_space(p.heater_drafts[index]))
		if !ok || math.is_nan(val) || math.is_inf(val, 0) {
			printer_set_notice(p, "Enter a finite temperature target", true)
			return
		}
		target = val
	}
	site := devlog.Site{feature = "printer", operation = "heater_set"}
	devlog.started(devlog.global(), site, {scope = "printer", stage = h.name})
	if mr.command(&p.client, mr.Command{kind = .Heater, text = h.name, value = target}) {
		devlog.succeeded(devlog.global(), site, {scope = "printer", stage = h.name})
		printer_set_notice(p, fmt.tprintf("%s target → %.0f °C", h.name, target))
	} else {
		devlog.failed(devlog.global(), site, {reason = "heater command rejected", detail = p.client.state.error, severity = .Warning})
		printer_set_notice(p, p.client.state.error if len(p.client.state.error) > 0 else "Heater command rejected", true)
	}
}

@(private = "file")
printer_submit_jog :: proc(p: ^Printer_State, axis: mr.Axis, sign: f64) {
	step := PRINTER_JOG_STEPS[clamp(p.jog_step_index, 0, len(PRINTER_JOG_STEPS)-1)] * sign
	feed := PRINTER_JOG_FEED_Z if axis == .Z else PRINTER_JOG_FEED_XY
	site := devlog.Site{feature = "printer", operation = "jog"}
	devlog.started(devlog.global(), site, {scope = "printer"})
	if mr.command(&p.client, mr.Command{kind = .Jog, axis = axis, value = step, feed_mm_per_second = feed}) {
		devlog.succeeded(devlog.global(), site, {scope = "printer"})
		printer_set_notice(p, fmt.tprintf("Jog %v %+.1f mm", axis, step))
	} else {
		devlog.failed(devlog.global(), site, {reason = "jog rejected", detail = p.client.state.error, severity = .Warning})
		printer_set_notice(p, p.client.state.error if len(p.client.state.error) > 0 else "Jog rejected", true)
	}
}

@(private = "file")
printer_submit_move :: proc(p: ^Printer_State, axis_idx: int) {
	if axis_idx < 0 || axis_idx > 2 {return}
	val, ok := strconv.parse_f64(strings.trim_space(p.move_drafts[axis_idx]))
	if !ok || math.is_nan(val) || math.is_inf(val, 0) {
		printer_set_notice(p, "Enter a finite coordinate in mm", true)
		return
	}
	axis := mr.Axis(axis_idx)
	feed := PRINTER_JOG_FEED_Z if axis == .Z else PRINTER_JOG_FEED_XY
	if mr.command(&p.client, mr.Command{kind = .Move, axis = axis, value = val, feed_mm_per_second = feed}) {
		printer_set_notice(p, fmt.tprintf("Move %v → %.2f mm", axis, val))
	} else {
		printer_set_notice(p, p.client.state.error if len(p.client.state.error) > 0 else "Move rejected", true)
	}
}

@(private = "file")
printer_download_selected :: proc(p: ^Printer_State) {
	if len(p.selected_file) == 0 {return}
	if app.host.save_document == nil {return}
	suggested := strings.clone_to_cstring(filepath.base(p.selected_file), context.temp_allocator)
	out_buf: [4096]u8
	if !app.host.save_document(suggested, raw_data(out_buf[:]), len(out_buf)) {return}
	dest := string(cstring(&out_buf[0]))
	if mr.download(&p.client, p.selected_file) {
		delete(p.download_dest)
		p.download_dest = strings.clone(dest)
		printer_set_notice(p, fmt.tprintf("Downloading %s…", filepath.base(p.selected_file)))
	} else {
		printer_set_notice(p, p.client.state.error if len(p.client.state.error) > 0 else "Download rejected", true)
	}
}

app_printer_activate :: proc(action: UI_Action) -> bool {
	p := &app.printer
	if idx, ok := printer_heater_field_index(action); ok {
		_ = idx
		printer_focus_field(p, action)
		return true
	}
	if idx, ok := printer_heater_set_index(action); ok {
		printer_blur_field(p)
		printer_submit_heater(p, idx, false)
		return true
	}
	if idx, ok := printer_heater_off_index(action); ok {
		printer_blur_field(p)
		printer_submit_heater(p, idx, true)
		return true
	}
	if row_idx, ok := printer_file_row_index(action); ok {
		file_idx := p.files_scroll + row_idx
		if file_idx >= 0 && file_idx < len(p.client.state.files) {
			delete(p.selected_file)
			p.selected_file = strings.clone(p.client.state.files[file_idx].path)
			app.needs_redraw = true
		}
		return true
	}
	#partial switch action {
	case .Printer_Control_Surface, .Printer_Chart_Surface:
		printer_blur_field(p)
		return true
	case .Printer_Sub_Control:
		printer_blur_field(p)
		p.subtab = .Control
	case .Printer_Sub_Files:
		printer_blur_field(p)
		p.subtab = .Files
		if p.client.state.connection == .Connected && len(p.client.state.files) == 0 {
			_ = mr.refresh_files(&p.client)
		}
	case .Printer_Sub_Console:
		printer_blur_field(p)
		p.subtab = .Console
	case .Printer_Sub_Config:
		printer_blur_field(p)
		p.subtab = .Config
	case .Printer_Sub_Connection:
		printer_blur_field(p)
		p.subtab = .Connection
	case .Printer_Emergency_Stop:
		printer_blur_field(p)
		if mr.command(&p.client, mr.Command{kind = .Emergency}) {
			printer_set_notice(p, "EMERGENCY STOP sent", true)
		} else {
			printer_set_notice(p, p.client.state.error if len(p.client.state.error) > 0 else "Emergency stop failed", true)
		}
	case .Printer_Restart:
		printer_blur_field(p)
		if mr.command(&p.client, mr.Command{kind = .Restart}) {
			printer_set_notice(p, "Restart submitted")
		} else {
			printer_set_notice(p, p.client.state.error if len(p.client.state.error) > 0 else "Restart rejected", true)
		}
	case .Printer_Firmware_Restart:
		printer_blur_field(p)
		if mr.command(&p.client, mr.Command{kind = .Firmware_Restart}) {
			printer_set_notice(p, "Firmware restart submitted")
		} else {
			printer_set_notice(p, p.client.state.error if len(p.client.state.error) > 0 else "Firmware restart rejected", true)
		}
	case .Printer_Home_All, .Printer_Home_X, .Printer_Home_Y, .Printer_Home_Z:
		printer_blur_field(p)
		axis := ""
		if action == .Printer_Home_X {axis = "X"}
		if action == .Printer_Home_Y {axis = "Y"}
		if action == .Printer_Home_Z {axis = "Z"}
		if mr.command(&p.client, mr.Command{kind = .Home, text = axis}) {
			printer_set_notice(p, "Homing all axes" if axis == "" else fmt.tprintf("Homing %s", axis))
		} else {
			printer_set_notice(p, p.client.state.error if len(p.client.state.error) > 0 else "Homing rejected", true)
		}
	case .Printer_Disable_Motors:
		printer_blur_field(p)
		if mr.command(&p.client, mr.Command{kind = .Disable_Motors}) {
			printer_set_notice(p, "Motors disabled (M84)")
		} else {
			printer_set_notice(p, p.client.state.error if len(p.client.state.error) > 0 else "Disable motors rejected", true)
		}
	case .Printer_Step_01: p.jog_step_index = 0
	case .Printer_Step_1:  p.jog_step_index = 1
	case .Printer_Step_10: p.jog_step_index = 2
	case .Printer_Step_50: p.jog_step_index = 3
	case .Printer_Jog_X_Neg: printer_submit_jog(p, .X, -1)
	case .Printer_Jog_X_Pos: printer_submit_jog(p, .X, 1)
	case .Printer_Jog_Y_Neg: printer_submit_jog(p, .Y, -1)
	case .Printer_Jog_Y_Pos: printer_submit_jog(p, .Y, 1)
	case .Printer_Jog_Z_Neg: printer_submit_jog(p, .Z, -1)
	case .Printer_Jog_Z_Pos: printer_submit_jog(p, .Z, 1)
	case .Printer_Move_X_Field, .Printer_Move_Y_Field, .Printer_Move_Z_Field:
		printer_focus_field(p, action)
	case .Printer_Move_X_Go:
		printer_blur_field(p)
		printer_submit_move(p, 0)
	case .Printer_Move_Y_Go:
		printer_blur_field(p)
		printer_submit_move(p, 1)
	case .Printer_Move_Z_Go:
		printer_blur_field(p)
		printer_submit_move(p, 2)
	case .Printer_History_1m:  p.history_range = 0
	case .Printer_History_5m:  p.history_range = 1
	case .Printer_History_20m: p.history_range = 2
	case .Printer_History_Refresh:
		if !mr.refresh_temperature_history(&p.client) {
			printer_set_notice(p, p.client.state.history_error if len(p.client.state.history_error) > 0 else "History refresh unavailable", true)
		}
	case .Printer_Files_Refresh:
		if !mr.refresh_files(&p.client) {
			printer_set_notice(p, p.client.state.error if len(p.client.state.error) > 0 else "Refresh failed", true)
		}
	case .Printer_Files_Download:
		printer_download_selected(p)
	case .Printer_Conn_Endpoint, .Printer_Conn_Api_Key:
		printer_focus_field(p, action)
	case .Printer_Conn_Connect:
		printer_blur_field(p)
		printer_connect_current(p)
	case .Printer_Conn_Disconnect:
		printer_blur_field(p)
		p.demo = false
		mr.disconnect(&p.client)
		printer_set_notice(p, "Disconnected")
	case .Printer_Conn_Local:
		printer_blur_field(p)
		delete(p.endpoint)
		p.endpoint = strings.clone(PRINTER_LOCAL_ENDPOINT)
		printer_connect_current(p)
	case .Printer_Conn_Preview:
		printer_blur_field(p)
		if p.demo {
			p.demo = false
			mr.disconnect(&p.client)
			printer_set_notice(p, "Offline preview closed")
		} else {
			mr.load_demo(&p.client)
			p.demo = true
			printer_set_notice(p, "Offline sample preview active (no printer connected)")
		}
	case:
		return false
	}
	app.needs_redraw = true
	return true
}

app_printer_scroll :: proc(delta_y: f64) -> bool {
	if !ui_printer_mode(&app.ui) || delta_y == 0 {return false}
	p := &app.printer
	step := -1 if delta_y > 0 else 1
	switch p.subtab {
	case .Files:
		visible := printer_files_visible_rows(&app.ui)
		p.files_scroll = clamp(p.files_scroll + step, 0, max(0, len(p.client.state.files) - visible))
		app.needs_redraw = true
		return true
	case .Console:
		visible := printer_console_visible_rows(&app.ui)
		p.console_scroll = clamp(p.console_scroll + step, 0, max(0, len(p.client.state.console) - visible))
		app.needs_redraw = true
		return true
	case .Control:
		if ui_contains(ui_printer_control_card_rect(&app.ui), app.ui.pointer_x, app.ui.pointer_y) ||
		   ui_contains(ui_printer_chart_card_rect(&app.ui), app.ui.pointer_x, app.ui.pointer_y) {
			return true
		}
		return false
	case .Config, .Connection:
		return true
	}
	return false
}

// Layout ------------------------------------------------------------------------------------------

ui_printer_subbar_rect :: proc(ui: ^UI_State) -> UI_Rect {
	return {12, 46, max(1, ui.width-24), 36}
}

ui_printer_viewport_rect :: proc(ui: ^UI_State) -> UI_Rect {
	sub := ui_printer_subbar_rect(ui)
	top := sub.y + sub.h + 6
	return {12, top, max(1, ui.width-24), max(1, ui.height-top-12)}
}

ui_printer_control_card_rect :: proc(ui: ^UI_State) -> UI_Rect {
	vp := ui_printer_viewport_rect(ui)
	w := min(348.0, max(260.0, vp.w*0.32))
	h := max(200.0, vp.h-24)
	return {vp.x+12, vp.y+12, w, h}
}

ui_printer_chart_card_rect :: proc(ui: ^UI_State) -> UI_Rect {
	vp := ui_printer_viewport_rect(ui)
	ctrl := ui_printer_control_card_rect(ui)
	avail_w := max(0.0, vp.x+vp.w-12-(ctrl.x+ctrl.w+12))
	w := min(420.0, avail_w)
	h := min(210.0, max(130.0, vp.h*0.32))
	return {vp.x+vp.w-w-12, vp.y+vp.h-h-12, w, h}
}

printer_files_visible_rows :: proc(ui: ^UI_State) -> int {
	vp := ui_printer_viewport_rect(ui)
	return clamp(int((vp.h - 68) / 34), 1, PRINTER_MAX_VISIBLE_FILES)
}

printer_console_visible_rows :: proc(ui: ^UI_State) -> int {
	vp := ui_printer_viewport_rect(ui)
	return max(1, int((vp.h - 52) / 20))
}

// Controls ----------------------------------------------------------------------------------------

ui_printer_custom_control :: proc(action: UI_Action) -> bool {
	if _, ok := printer_heater_field_index(action); ok {return true}
	if _, ok := printer_file_row_index(action); ok {return true}
	#partial switch action {
	case .Printer_Control_Surface, .Printer_Chart_Surface,
	     .Printer_Conn_Endpoint, .Printer_Conn_Api_Key,
	     .Printer_Move_X_Field, .Printer_Move_Y_Field, .Printer_Move_Z_Field:
		return true
	}
	return false
}

ui_printer_controls :: proc(ui: ^UI_State) {
	p := &app.printer
	s := &p.client.state
	sub := ui_printer_subbar_rect(ui)
	sub_items := [5]struct {
		tab:    Printer_Subtab,
		action: UI_Action,
		name:   string,
		label:  string,
		w:      f64,
	}{
		{.Control, .Printer_Sub_Control, "printer control tab", "Control", 78},
		{.Files, .Printer_Sub_Files, "printer files tab", "Files", 66},
		{.Console, .Printer_Sub_Console, "printer console tab", "Console", 80},
		{.Config, .Printer_Sub_Config, "printer config tab", "Config", 74},
		{.Connection, .Printer_Sub_Connection, "printer connection tab", "Connection", 96},
	}
	sx := sub.x
	for item in sub_items {
		ui_add_control(ui, item.name, item.label, {sx, sub.y+3, item.w, 30}, item.action, true, 1, p.subtab == item.tab)
		sx += item.w + 6
	}
	// Persistent Emergency STOP button at top-right of the Printer sub-bar.
	can_stop := s.connection == .Connected && !p.demo
	ui_add_control(ui, "emergency stop", "Emergency stop printer", {sub.x+sub.w-86, sub.y+3, 86, 30}, .Printer_Emergency_Stop, can_stop)

	vp := ui_printer_viewport_rect(ui)
	switch p.subtab {
	case .Control:
		ctrl := ui_printer_control_card_rect(ui)
		ui_add_control(ui, "printer control card", "printer controls", ctrl, .Printer_Control_Surface)

		// Frame viewport button floating top-right of 3D viewport.
		ui_add_control(ui, "frame mesh", "frame the build plate", {vp.x+vp.w-88, vp.y+12, 76, 30}, .Frame_Mesh)

		y := ctrl.y + 116
		ready := s.connection == .Connected && !s.stale && s.printer_state == "ready" && !p.demo
		heaters_shown := min(len(s.heaters), PRINTER_MAX_HEATERS)
		for i in 0..<heaters_shown {
			h := s.heaters[i]
			if y + 54 > ctrl.y + ctrl.h - 200 {break}
			if h.controllable {
				can_set := ready && h.limits_available
				ui_add_control(ui, fmt.tprintf("heater %d target", i), h.name, {ctrl.x+12, y+22, ctrl.w-132, 26}, printer_heater_field_action(i), can_set)
				ui_add_control(ui, fmt.tprintf("heater %d set", i), "Set heater target", {ctrl.x+ctrl.w-114, y+22, 48, 26}, printer_heater_set_action(i), can_set)
				ui_add_control(ui, fmt.tprintf("heater %d off", i), "Turn heater off", {ctrl.x+ctrl.w-60, y+22, 48, 26}, printer_heater_off_action(i), can_set)
				y += 56
			} else {
				y += 28
			}
		}

		// Motion & Machine controls anchored cleanly below heaters.
		motion_y := max(y + 12, ctrl.y + ctrl.h - 210)
		idle := ready && s.job_state != "printing" && s.job_state != "paused"
		ui_add_control(ui, "home all", "Home all axes (G28)", {ctrl.x+12, motion_y+22, 74, 28}, .Printer_Home_All, idle)
		ui_add_control(ui, "home x", "Home X", {ctrl.x+92, motion_y+22, 34, 28}, .Printer_Home_X, idle)
		ui_add_control(ui, "home y", "Home Y", {ctrl.x+132, motion_y+22, 34, 28}, .Printer_Home_Y, idle)
		ui_add_control(ui, "home z", "Home Z", {ctrl.x+172, motion_y+22, 34, 28}, .Printer_Home_Z, idle)
		ui_add_control(ui, "disable motors", "Disable motors (M84)", {ctrl.x+ctrl.w-108, motion_y+22, 96, 28}, .Printer_Disable_Motors, idle)

		step_y := motion_y + 58
		step_actions := [4]UI_Action{.Printer_Step_01, .Printer_Step_1, .Printer_Step_10, .Printer_Step_50}
		step_names := [4]string{"step 0.1", "step 1", "step 10", "step 50"}
		step_w := (ctrl.w - 24 - 18) / 4
		for i in 0..<4 {
			ui_add_control(ui, step_names[i], step_names[i], {ctrl.x+12+f64(i)*(step_w+6), step_y, step_w, 24}, step_actions[i], true, 1, p.jog_step_index == i)
		}

		jog_y := step_y + 32
		jog_w := (ctrl.w - 24 - 30) / 6
		jog_specs := [6]struct {action: UI_Action, name: string, axis: u8}{
			{.Printer_Jog_X_Neg, "jog x-", 'x'}, {.Printer_Jog_X_Pos, "jog x+", 'x'},
			{.Printer_Jog_Y_Neg, "jog y-", 'y'}, {.Printer_Jog_Y_Pos, "jog y+", 'y'},
			{.Printer_Jog_Z_Neg, "jog z-", 'z'}, {.Printer_Jog_Z_Pos, "jog z+", 'z'},
		}
		homed_lo := strings.to_lower(s.homed_axes, context.temp_allocator)
		for js, i in jog_specs {
			axis_ok := idle && s.limits_available && strings.contains_rune(homed_lo, rune(js.axis))
			ui_add_control(ui, js.name, js.name, {ctrl.x+12+f64(i)*(jog_w+6), jog_y, jog_w, 28}, js.action, axis_ok)
		}

		// Absolute move row.
		move_y := jog_y + 36
		col_w := (ctrl.w - 24 - 12) / 3
		move_fields := [3]UI_Action{.Printer_Move_X_Field, .Printer_Move_Y_Field, .Printer_Move_Z_Field}
		move_gos := [3]UI_Action{.Printer_Move_X_Go, .Printer_Move_Y_Go, .Printer_Move_Z_Go}
		move_axes := [3]rune{'x', 'y', 'z'}
		for i in 0..<3 {
			mx := ctrl.x + 12 + f64(i)*(col_w+6)
			axis_ok := idle && s.limits_available && strings.contains_rune(homed_lo, move_axes[i])
			ui_add_control(ui, fmt.tprintf("move %c field", move_axes[i]), "Absolute position", {mx, move_y, col_w-32, 26}, move_fields[i], axis_ok)
			ui_add_control(ui, fmt.tprintf("move %c go", move_axes[i]), "Move axis", {mx+col_w-30, move_y, 30, 26}, move_gos[i], axis_ok)
		}

		// Restart buttons at bottom of control card.
		rst_y := ctrl.y + ctrl.h - 38
		can_restart := s.connection == .Connected && !p.demo && (s.printer_state != "ready" || idle)
		half_w := (ctrl.w - 30) / 2
		ui_add_control(ui, "restart klipper", "Restart Klipper", {ctrl.x+12, rst_y, half_w, 28}, .Printer_Restart, can_restart)
		ui_add_control(ui, "firmware restart", "Firmware restart", {ctrl.x+18+half_w, rst_y, half_w, 28}, .Printer_Firmware_Restart, can_restart)

		// Floating temperature history chart card (bottom-right of 3D viewport).
		chart := ui_printer_chart_card_rect(ui)
		if chart.w >= 260 {
			ui_add_control(ui, "temperature chart card", "temperature history", chart, .Printer_Chart_Surface)
			ui_add_control(ui, "history 1m", "1 minute range", {chart.x+chart.w-188, chart.y+8, 36, 22}, .Printer_History_1m, true, 1, p.history_range == 0)
			ui_add_control(ui, "history 5m", "5 minute range", {chart.x+chart.w-148, chart.y+8, 36, 22}, .Printer_History_5m, true, 1, p.history_range == 1)
			ui_add_control(ui, "history 20m", "20 minute range", {chart.x+chart.w-108, chart.y+8, 40, 22}, .Printer_History_20m, true, 1, p.history_range == 2)
			ui_add_control(ui, "history refresh", "Refresh history", {chart.x+chart.w-64, chart.y+8, 54, 22}, .Printer_History_Refresh, ready)
		}

	case .Files:
		ui_add_control(ui, "refresh files", "Refresh G-code files", {vp.x+12, vp.y+12, 86, 28}, .Printer_Files_Refresh, s.connection == .Connected && !p.demo)
		visible := printer_files_visible_rows(ui)
		list_w := max(260.0, vp.w*0.58 - 18)
		p.files_scroll = clamp(p.files_scroll, 0, max(0, len(s.files) - visible))
		for row in 0..<visible {
			idx := p.files_scroll + row
			if idx >= len(s.files) {break}
			file := s.files[idx]
			ui_add_control(ui, fmt.tprintf("file row %d", row), file.path, {vp.x+12, vp.y+52+f64(row)*34, list_w, 30}, printer_file_row_action(row), true, 1, file.path == p.selected_file)
		}
		if len(p.selected_file) > 0 && s.connection == .Connected && !p.demo {
			detail_x := vp.x + list_w + 24
			ui_add_control(ui, "download file", "Download selected G-code file", {detail_x+12, vp.y+vp.h-44, 120, 30}, .Printer_Files_Download, s.transfer.status != .Running)
		}

	case .Console, .Config:
		// Read-only scrollable views (Config editor lands in Milestone 3).

	case .Connection:
		cx := vp.x + 24
		cy := vp.y + 84
		field_w := min(440.0, vp.w - 48)
		ui_add_control(ui, "moonraker url", "Moonraker URL", {cx, cy+24, field_w, 30}, .Printer_Conn_Endpoint)
		ui_add_control(ui, "moonraker api key", "API key (optional)", {cx, cy+90, field_w, 30}, .Printer_Conn_Api_Key)
		btn_y := cy + 140
		ui_add_control(ui, "connect printer", "Connect to Moonraker", {cx, btn_y, 96, 30}, .Printer_Conn_Connect)
		ui_add_control(ui, "disconnect printer", "Disconnect", {cx+104, btn_y, 96, 30}, .Printer_Conn_Disconnect, s.connection != .Offline || p.demo)
		ui_add_control(ui, "local printer", "Use 127.0.0.1:7125", {cx+208, btn_y, 134, 30}, .Printer_Conn_Local)
		ui_add_control(ui, "offline preview", "Toggle offline sample data", {cx+350, btn_y, 132, 30}, .Printer_Conn_Preview, true, 1, p.demo)
	}
}

// Drawing -----------------------------------------------------------------------------------------

@(private = "file")
printer_connection_label :: proc(p: ^Printer_State) -> (text: string, color: Vec4) {
	theme := ui_theme(&app.ui)
	if p.demo {return "Offline preview (sample data)", GRAPH_ORANGE}
	switch p.client.state.connection {
	case .Connected:
		if p.client.state.stale {return "Connected (stale)", GRAPH_ORANGE}
		host := p.client.state.hostname if len(p.client.state.hostname) > 0 else "ratos"
		return fmt.tprintf("Connected · %s", host), GRAPH_GREEN
	case .Connecting, .Initializing:
		return "Connecting…", GRAPH_BLUE
	case .Reconnecting:
		return "Reconnecting…", GRAPH_ORANGE
	case .Failed:
		return "Connection failed", ui_error_color(&app.ui)
	case .Offline:
		return "Offline", theme.muted
	}
	return "Offline", theme.muted
}

@(private = "file")
printer_draw_text_field :: proc(painter: ^UI_Painter, ui: ^UI_State, action: UI_Action, value: string, placeholder: string, masked := false) {
	rect := ui_control_rect(ui, action)
	if rect.w <= 0 || rect.h <= 0 {return}
	theme := ui_theme(ui)
	p := &app.printer
	active := p.edit.active_field == text_input.Field_ID(u64(action))
	ui_add_round_rect(painter, rect, 5, theme.canvas)
	ui_add_border(painter, rect, theme.accent if active else theme.border, 1.5 if active else 1.0)

	display := value
	if masked && len(value) > 0 {
		dots := make([]u8, len(value), context.temp_allocator)
		for i in 0..<len(value) {dots[i] = '*'}
		display = string(dots)
	}
	if len(display) == 0 && !active {
		ui_draw_text(painter, painter.mono, ui, placeholder, rect, theme.muted, 8, tracked = true)
		return
	}
	if active {
		// Show selection highlight and caret.
		ch := ui_character_width(ui)
		start, end := text_input.selection_bounds(&p.edit, value)
		if end > start {
			sx := rect.x + 8 + f64(start)*ch
			sw := min(f64(end-start)*ch, rect.x+rect.w-6-sx)
			if sw > 0 {
				sel_col := theme.accent
				sel_col.w = 0.28
				ui_add_rect(painter, {sx, rect.y+4, sw, rect.h-8}, sel_col)
			}
		}
		caret_x := min(rect.x + 8 + f64(p.edit.caret_byte_offset)*ch, rect.x + rect.w - 6)
		ui_add_rect(painter, {caret_x, rect.y+5, 1.5, rect.h-10}, theme.accent)
	}
	ui_draw_text(painter, painter.mono, ui, display, rect, theme.text, 8, tracked = true)
}

ui_draw_printer_panels :: proc(painter: ^UI_Painter, ui: ^UI_State) {
	theme := ui_theme(ui)
	p := &app.printer
	ui_add_rect(painter, {0, 0, ui.width, 40}, theme.header)
	ui_add_rect(painter, {0, 39, ui.width, 1}, theme.border)

	vp := ui_printer_viewport_rect(ui)
	switch p.subtab {
	case .Control:
		ctrl := ui_printer_control_card_rect(ui)
		ui_menu_shadow(painter, ui, ctrl)
		bg := theme.overlay
		bg.w = 0.92
		ui_add_round_rect(painter, ctrl, 8, bg)
		ui_add_border(painter, ctrl, theme.border)

		chart := ui_printer_chart_card_rect(ui)
		if chart.w >= 260 {
			ui_menu_shadow(painter, ui, chart)
			ui_add_round_rect(painter, chart, 8, bg)
			ui_add_border(painter, chart, theme.border)
		}
	case .Files, .Console, .Config, .Connection:
		ui_add_round_rect(painter, vp, 8, theme.surface)
		ui_add_border(painter, vp, theme.border)
	}
}

ui_draw_printer_labels :: proc(painter: ^UI_Painter, ui: ^UI_State) {
	theme := ui_theme(ui)
	p := &app.printer
	s := &p.client.state
	sub := ui_printer_subbar_rect(ui)

	sub_labels := [5]struct {action: UI_Action, text: string}{
		{.Printer_Sub_Control, "Control"},
		{.Printer_Sub_Files, "Files"},
		{.Printer_Sub_Console, "Console"},
		{.Printer_Sub_Config, "Config"},
		{.Printer_Sub_Connection, "Connection"},
	}
	for item in sub_labels {
		ui_draw_text(painter, painter.font, ui, item.text, ui_control_rect(ui, item.action), ui_control_ink(ui, item.action), 0, .Center)
	}
	// Live connection badge in the sub-bar.
	conn_text, conn_col := printer_connection_label(p)
	conn_x := sub.x + 436
	stop_rect := ui_control_rect(ui, .Printer_Emergency_Stop)
	if stop_rect.x - conn_x > 120 {
		ui_add_round_rect(painter, {conn_x, sub.y+13, 8, 8}, 4, conn_col)
		ui_draw_text(painter, painter.font, ui, conn_text, {conn_x+14, sub.y+3, stop_rect.x-conn_x-24, 30}, theme.text, 0)
	}
	// Prominent red Emergency STOP button fill & label.
	if stop_rect.w > 0 {
		stop_fill := ui_error_color(ui)
		if !(s.connection == .Connected && !p.demo) {stop_fill.w = 0.35}
		ui_add_round_rect(painter, ui_pill_rect(ui, stop_rect), 6, stop_fill)
		ui_draw_text(painter, painter.font, ui, "STOP", stop_rect, {1, 1, 1, 1}, 0, .Center)
	}

	vp := ui_printer_viewport_rect(ui)
	switch p.subtab {
	case .Control:
		printer_draw_control_overlay(painter, ui, p)
	case .Files:
		printer_draw_files_panel(painter, ui, p, vp)
	case .Console:
		printer_draw_console_panel(painter, ui, p, vp)
	case .Config:
		ui_draw_text(painter, painter.font, ui, "Printer Configuration", {vp.x+20, vp.y+16, vp.w-40, 26}, theme.text, 0)
		msg := fmt.tprintf("Connected: %d configuration files discovered on Moonraker. Guided & Layered configuration editor lands in Milestone 3 (read-only printer_config MCP tool is active now).", len(s.config_files))
		if s.connection != .Connected {
			msg = "Connect to Moonraker to inspect live Klipper configuration. Guided & Layered configuration editor lands in Milestone 3 (read-only printer_config MCP tool is active now)."
		}
		ui_draw_text(painter, painter.font, ui, msg, {vp.x+20, vp.y+52, vp.w-40, 24}, theme.muted, 0)
	case .Connection:
		printer_draw_connection_panel(painter, ui, p, vp)
	}

	// Subtle notice toast at bottom-left of viewport (above chart / inside panel).
	if len(p.notice) > 0 && p.subtab != .Control {
		col := ui_error_color(ui) if p.notice_failed else theme.muted
		ui_draw_text(painter, painter.font, ui, p.notice, {vp.x+16, vp.y+vp.h-28, vp.w-32, 22}, col, 0)
	}
}

@(private = "file")
printer_draw_control_overlay :: proc(painter: ^UI_Painter, ui: ^UI_State, p: ^Printer_State) {
	theme := ui_theme(ui)
	s := &p.client.state
	ctrl := ui_printer_control_card_rect(ui)

	ui_draw_text(painter, painter.font, ui, "Frame", ui_control_rect(ui, .Frame_Mesh), ui_control_ink(ui, .Frame_Mesh), 0, .Center)

	// Status header inside left floating card.
	state_str := s.printer_state if len(s.printer_state) > 0 else "disconnected"
	job_str := s.job_state if len(s.job_state) > 0 else "idle"
	ui_draw_text(painter, painter.font, ui, fmt.tprintf("State: %s · Job: %s", state_str, job_str), {ctrl.x+12, ctrl.y+10, ctrl.w-24, 22}, theme.text, 0)
	if len(s.filename) > 0 {
		prog := fmt.tprintf("%.0f%% · %s", s.progress*100, filepath.base(s.filename)) if s.progress_available else filepath.base(s.filename)
		ui_draw_text(painter, painter.mono, ui, prog, {ctrl.x+12, ctrl.y+32, ctrl.w-24, 20}, theme.accent, 0, tracked = true)
	} else if len(p.notice) > 0 {
		ui_draw_text(painter, painter.font, ui, p.notice, {ctrl.x+12, ctrl.y+32, ctrl.w-24, 20}, ui_error_color(ui) if p.notice_failed else theme.muted, 0)
	}
	pos := s.live_position if s.live_position_available else s.position
	pos_text := fmt.tprintf("X %.1f  Y %.1f  Z %.2f", pos[0], pos[1], pos[2]) if (s.live_position_available || s.position_available) else "Position unavailable"
	ui_draw_text(painter, painter.mono, ui, pos_text, {ctrl.x+12, ctrl.y+56, ctrl.w-24, 20}, theme.text, 0, tracked = true)
	homed := strings.to_upper(s.homed_axes, context.temp_allocator) if len(s.homed_axes) > 0 else "none"
	motors := "engaged" if (s.motors_available && s.motors_engaged) else ("off" if s.motors_available else "–")
	status_line := fmt.tprintf("Homed: %s · Motors: %s", homed, motors)
	if p.tracking.status != .Off {
		status_line = fmt.tprintf("%s · %s", status_line, TRACKING_STATUS_NAMES[p.tracking.status])
	}
	ui_draw_text(painter, painter.font, ui, status_line, {ctrl.x+12, ctrl.y+78, ctrl.w-24, 20}, theme.muted, 0)
	ui_add_rect(painter, {ctrl.x+12, ctrl.y+104, ctrl.w-24, 1}, theme.border)

	// Heaters list.
	y := ctrl.y + 116
	heaters_shown := min(len(s.heaters), PRINTER_MAX_HEATERS)
	if heaters_shown == 0 {
		ui_draw_text(painter, painter.font, ui, "No heaters reported", {ctrl.x+12, y, ctrl.w-24, 22}, theme.muted, 0)
	}
	for i in 0..<heaters_shown {
		h := s.heaters[i]
		if y + 54 > ctrl.y + ctrl.h - 200 {break}
		temp_str := fmt.tprintf("%.1f° / %.0f°", h.temperature, h.target) if h.available else "–"
		if h.power_available && h.power > 0.005 {
			temp_str = fmt.tprintf("%s (%.0f%%)", temp_str, h.power*100)
		}
		ui_draw_text(painter, painter.font, ui, h.name, {ctrl.x+12, y, ctrl.w*0.5-12, 20}, theme.text, 0)
		ui_draw_text(painter, painter.mono, ui, temp_str, {ctrl.x+ctrl.w*0.5, y, ctrl.w*0.5-12, 20}, theme.accent if h.target > 0 else theme.muted, 0, .End, tracked = true)
		if h.controllable {
			placeholder := fmt.tprintf("%.0f", h.target) if h.target_available else "0"
			printer_draw_text_field(painter, ui, printer_heater_field_action(i), p.heater_drafts[i], placeholder)
			ui_draw_text(painter, painter.font, ui, "Set", ui_control_rect(ui, printer_heater_set_action(i)), ui_control_ink(ui, printer_heater_set_action(i)), 0, .Center)
			ui_draw_text(painter, painter.font, ui, "Off", ui_control_rect(ui, printer_heater_off_action(i)), ui_control_ink(ui, printer_heater_off_action(i)), 0, .Center)
			y += 56
		} else {
			y += 28
		}
	}

	// Motion section labels.
	motion_y := max(y + 12, ctrl.y + ctrl.h - 210)
	ui_add_rect(painter, {ctrl.x+12, motion_y-6, ctrl.w-24, 1}, theme.border)
	ui_draw_text(painter, painter.font, ui, "Motion & Machine", {ctrl.x+12, motion_y, ctrl.w-24, 20}, theme.muted, 0)
	btn_labels := [17]struct {action: UI_Action, text: string}{
		{.Printer_Home_All, "Home All"}, {.Printer_Home_X, "X"}, {.Printer_Home_Y, "Y"}, {.Printer_Home_Z, "Z"},
		{.Printer_Disable_Motors, "Motors Off"},
		{.Printer_Step_01, "0.1"}, {.Printer_Step_1, "1"}, {.Printer_Step_10, "10"}, {.Printer_Step_50, "50"},
		{.Printer_Jog_X_Neg, "X−"}, {.Printer_Jog_X_Pos, "X+"},
		{.Printer_Jog_Y_Neg, "Y−"}, {.Printer_Jog_Y_Pos, "Y+"},
		{.Printer_Jog_Z_Neg, "Z−"}, {.Printer_Jog_Z_Pos, "Z+"},
		{.Printer_Restart, "Restart"}, {.Printer_Firmware_Restart, "FW Restart"},
	}
	for b in btn_labels {
		ui_draw_text(painter, painter.font, ui, b.text, ui_control_rect(ui, b.action), ui_control_ink(ui, b.action), 0, .Center)
	}
	move_fields := [3]UI_Action{.Printer_Move_X_Field, .Printer_Move_Y_Field, .Printer_Move_Z_Field}
	move_gos := [3]UI_Action{.Printer_Move_X_Go, .Printer_Move_Y_Go, .Printer_Move_Z_Go}
	move_hints := [3]string{"X mm", "Y mm", "Z mm"}
	for i in 0..<3 {
		printer_draw_text_field(painter, ui, move_fields[i], p.move_drafts[i], move_hints[i])
		ui_draw_text(painter, painter.font, ui, "Go", ui_control_rect(ui, move_gos[i]), ui_control_ink(ui, move_gos[i]), 0, .Center)
	}

	// Floating temperature history chart.
	chart := ui_printer_chart_card_rect(ui)
	if chart.w >= 260 {
		ui_draw_text(painter, painter.font, ui, "Temperatures", {chart.x+12, chart.y+8, 120, 22}, theme.text, 0)
		ui_draw_text(painter, painter.font, ui, "1m", ui_control_rect(ui, .Printer_History_1m), ui_control_ink(ui, .Printer_History_1m), 0, .Center)
		ui_draw_text(painter, painter.font, ui, "5m", ui_control_rect(ui, .Printer_History_5m), ui_control_ink(ui, .Printer_History_5m), 0, .Center)
		ui_draw_text(painter, painter.font, ui, "20m", ui_control_rect(ui, .Printer_History_20m), ui_control_ink(ui, .Printer_History_20m), 0, .Center)
		ui_draw_text(painter, painter.font, ui, "Sync", ui_control_rect(ui, .Printer_History_Refresh), ui_control_ink(ui, .Printer_History_Refresh), 0, .Center)
		printer_draw_temperature_chart(painter, ui, p, {chart.x+12, chart.y+38, chart.w-24, chart.h-50})
	}
}

@(private = "file")
printer_draw_temperature_chart :: proc(painter: ^UI_Painter, ui: ^UI_State, p: ^Printer_State, plot: UI_Rect) {
	theme := ui_theme(ui)
	ui_add_rect(painter, plot, theme.canvas)
	ui_add_border(painter, plot, theme.border)
	histories := p.client.state.temperature_history
	if len(histories) == 0 {
		msg := p.client.state.history_error if len(p.client.state.history_error) > 0 else "Waiting for temperature history…"
		ui_draw_text(painter, painter.font, ui, msg, plot, theme.muted, 0, .Center)
		return
	}
	window_samples := 60 if p.history_range == 0 else (300 if p.history_range == 1 else 1200)
	max_t := 60.0
	for h in histories {
		start := max(0, len(h.samples) - window_samples)
		for sample in h.samples[start:] {
			if sample.temperature_available {max_t = max(max_t, sample.temperature + 15)}
			if sample.target_available {max_t = max(max_t, sample.target + 15)}
		}
	}
	max_t = math.ceil(max_t / 50.0) * 50.0
	palette := [4]Vec4{GRAPH_ORANGE, GRAPH_BLUE, GRAPH_GREEN, theme.accent}
	gpu.push_clip(painter.list, ui_gpu_rect(plot))
	for h, hi in histories {
		col := palette[hi % len(palette)]
		start := max(0, len(h.samples) - window_samples)
		slice := h.samples[start:]
		n := len(slice)
		if n < 2 {continue}
		denom := f64(max(1, window_samples - 1))
		offset := window_samples - n
		for i in 1..<n {
			a, b := slice[i-1], slice[i]
			x0 := plot.x + (f64(offset + i - 1) / denom) * plot.w
			x1 := plot.x + (f64(offset + i) / denom) * plot.w
			if a.target_available && b.target_available {
				y0 := plot.y + plot.h - clamp(a.target / max_t, 0, 1) * plot.h
				y1 := plot.y + plot.h - clamp(b.target / max_t, 0, 1) * plot.h
				tcol := col; tcol.w = 0.40
				if i % 2 == 0 {
					gpu.draw_line(painter.list, {f32(x0), f32(y0)}, {f32(x1), f32(y1)}, 1.2, ui_color(tcol), false)
				}
			}
			if a.temperature_available && b.temperature_available {
				y0 := plot.y + plot.h - clamp(a.temperature / max_t, 0, 1) * plot.h
				y1 := plot.y + plot.h - clamp(b.temperature / max_t, 0, 1) * plot.h
				gpu.draw_line(painter.list, {f32(x0), f32(y0)}, {f32(x1), f32(y1)}, 1.8, ui_color(col), false)
			}
		}
	}
	gpu.pop_clip(painter.list)
	ui_draw_text(painter, painter.mono, ui, fmt.tprintf("%.0f°C", max_t), {plot.x+4, plot.y+2, 64, 16}, theme.muted, 0, tracked = true)
	ui_draw_text(painter, painter.mono, ui, "0°C", {plot.x+4, plot.y+plot.h-18, 48, 16}, theme.muted, 0, tracked = true)
}

@(private = "file")
printer_draw_files_panel :: proc(painter: ^UI_Painter, ui: ^UI_State, p: ^Printer_State, vp: UI_Rect) {
	theme := ui_theme(ui)
	s := &p.client.state
	ui_draw_text(painter, painter.font, ui, "Refresh", ui_control_rect(ui, .Printer_Files_Refresh), ui_control_ink(ui, .Printer_Files_Refresh), 0, .Center)
	ui_draw_text(painter, painter.font, ui, fmt.tprintf("%d G-code files", len(s.files)), {vp.x+108, vp.y+12, 240, 28}, theme.muted, 0)

	list_w := max(260.0, vp.w*0.58 - 18)
	visible := printer_files_visible_rows(ui)
	for row in 0..<visible {
		idx := p.files_scroll + row
		if idx >= len(s.files) {break}
		file := s.files[idx]
		r := ui_control_rect(ui, printer_file_row_action(row))
		selected := file.path == p.selected_file
		hovered := ui.hovered_id == u64(printer_file_row_action(row))
		if selected {
			ui_add_round_rect(painter, r, 6, theme.accent)
		} else if hovered {
			ui_add_round_rect(painter, r, 6, theme.raised)
		}
		ink := theme.accent_ink if selected else theme.text
		muted := theme.accent_ink if selected else theme.muted
		ui_draw_text(painter, painter.font, ui, file.path, {r.x+8, r.y, r.w-100, r.h}, ink, 0)
		size_mb := f64(file.size) / (1024.0 * 1024.0)
		ui_draw_text(painter, painter.mono, ui, fmt.tprintf("%.1f MB", size_mb), {r.x+r.w-92, r.y, 84, r.h}, muted, 0, .End, tracked = true)
	}

	// Selected file metadata details on the right.
	detail_x := vp.x + list_w + 24
	detail_w := max(180.0, vp.x + vp.w - detail_x - 12)
	ui_add_rect(painter, {detail_x-6, vp.y+52, 1, vp.h-64}, theme.border)
	sel_idx := mr.file_index(&p.client, p.selected_file)
	if sel_idx < 0 {
		ui_draw_text(painter, painter.font, ui, "Select a file to inspect metadata.", {detail_x+12, vp.y+56, detail_w-24, 24}, theme.muted, 0)
		return
	}
	f := s.files[sel_idx]
	ui_draw_text(painter, painter.font, ui, filepath.base(f.path), {detail_x+12, vp.y+56, detail_w-24, 24}, theme.text, 0)
	y := vp.y + 88
	ui_draw_measurement(painter, ui, "Size", fmt.tprintf("%.2f MB", f64(f.size)/(1024*1024)), {detail_x+12, y, detail_w-24, 22}, 110); y += 24
	if f.metadata_status == .Ready {
		m := f.metadata
		if len(m.slicer) > 0 {ui_draw_measurement(painter, ui, "Slicer", m.slicer, {detail_x+12, y, detail_w-24, 22}, 110); y += 24}
		if len(m.filament_type) > 0 {ui_draw_measurement(painter, ui, "Filament", m.filament_type, {detail_x+12, y, detail_w-24, 22}, 110); y += 24}
		if .Estimated_Time in m.available {
			mins := int(m.numbers[.Estimated_Time] / 60)
			ui_draw_measurement(painter, ui, "Print time", fmt.tprintf("%dh %02dm", mins/60, mins%60), {detail_x+12, y, detail_w-24, 22}, 110); y += 24
		}
		if .Layer_Height in m.available {ui_draw_measurement(painter, ui, "Layer height", fmt.tprintf("%.2f mm", m.numbers[.Layer_Height]), {detail_x+12, y, detail_w-24, 22}, 110); y += 24}
		if .Object_Height in m.available {ui_draw_measurement(painter, ui, "Object height", fmt.tprintf("%.2f mm", m.numbers[.Object_Height]), {detail_x+12, y, detail_w-24, 22}, 110); y += 24}
		if .Nozzle_Diameter in m.available {ui_draw_measurement(painter, ui, "Nozzle", fmt.tprintf("%.2f mm", m.numbers[.Nozzle_Diameter]), {detail_x+12, y, detail_w-24, 22}, 110); y += 24}
		if .Filament_Weight in m.available {ui_draw_measurement(painter, ui, "Weight", fmt.tprintf("%.1f g", m.numbers[.Filament_Weight]), {detail_x+12, y, detail_w-24, 22}, 110); y += 24}
	} else if f.metadata_status == .Pending {
		ui_draw_text(painter, painter.font, ui, "Loading slicer metadata…", {detail_x+12, y, detail_w-24, 22}, theme.muted, 0)
	}
	if s.connection == .Connected && !p.demo {
		ui_draw_text(painter, painter.font, ui, "Download", ui_control_rect(ui, .Printer_Files_Download), ui_control_ink(ui, .Printer_Files_Download), 0, .Center)
	}
}

@(private = "file")
printer_draw_console_panel :: proc(painter: ^UI_Painter, ui: ^UI_State, p: ^Printer_State, vp: UI_Rect) {
	theme := ui_theme(ui)
	logs := p.client.state.console
	ui_draw_text(painter, painter.font, ui, fmt.tprintf("Console (%d lines)", len(logs)), {vp.x+16, vp.y+12, vp.w-32, 24}, theme.muted, 0)
	visible := printer_console_visible_rows(ui)
	p.console_scroll = clamp(p.console_scroll, 0, max(0, len(logs) - visible))
	for row in 0..<visible {
		idx := len(logs) - 1 - (p.console_scroll + row)
		if idx < 0 || idx >= len(logs) {break}
		entry := logs[idx]
		col := theme.text
		switch entry.kind {
		case .Error:    col = ui_error_color(ui)
		case .Sent:     col = theme.accent
		case .Info:     col = theme.muted
		case .Response: col = theme.text
		}
		ui_draw_text(painter, painter.mono, ui, entry.text, {vp.x+16, vp.y+42+f64(row)*20, vp.w-32, 20}, col, 0, tracked = true)
	}
}

@(private = "file")
printer_draw_connection_panel :: proc(painter: ^UI_Painter, ui: ^UI_State, p: ^Printer_State, vp: UI_Rect) {
	theme := ui_theme(ui)
	s := &p.client.state
	cx := vp.x + 24
	cy := vp.y + 20
	conn_text, conn_col := printer_connection_label(p)
	ui_draw_text(painter, painter.font, ui, "Moonraker Connection", {cx, cy, vp.w-48, 26}, theme.text, 0)
	ui_draw_text(painter, painter.font, ui, conn_text, {cx, cy+28, vp.w-48, 22}, conn_col, 0)
	if len(s.error) > 0 {
		ui_draw_text(painter, painter.font, ui, s.error, {cx, cy+50, vp.w-48, 20}, ui_error_color(ui), 0)
	}

	fy := vp.y + 84
	ui_draw_text(painter, painter.font, ui, "Moonraker base URL", {cx, fy, 240, 20}, theme.muted, 0)
	printer_draw_text_field(painter, ui, .Printer_Conn_Endpoint, p.endpoint, PRINTER_DEFAULT_ENDPOINT)
	ui_draw_text(painter, painter.font, ui, "API key (optional, kept in memory only)", {cx, fy+66, 360, 20}, theme.muted, 0)
	printer_draw_text_field(painter, ui, .Printer_Conn_Api_Key, p.api_key, "Optional API key", masked = true)

	ui_draw_text(painter, painter.font, ui, "Connect", ui_control_rect(ui, .Printer_Conn_Connect), ui_control_ink(ui, .Printer_Conn_Connect), 0, .Center)
	ui_draw_text(painter, painter.font, ui, "Disconnect", ui_control_rect(ui, .Printer_Conn_Disconnect), ui_control_ink(ui, .Printer_Conn_Disconnect), 0, .Center)
	ui_draw_text(painter, painter.font, ui, "127.0.0.1:7125", ui_control_rect(ui, .Printer_Conn_Local), ui_control_ink(ui, .Printer_Conn_Local), 0, .Center)
	ui_draw_text(painter, painter.font, ui, "Offline preview", ui_control_rect(ui, .Printer_Conn_Preview), ui_control_ink(ui, .Printer_Conn_Preview), 0, .Center)
}
