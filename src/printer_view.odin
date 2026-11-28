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
PRINTER_FEATURE_MAX :: 16
PRINTER_DESIGN_PARAM_MAX :: 24
PRINTER_MACRO_MAX :: 128
PRINTER_MACRO_ROW_MAX :: 40
PRINTER_FAN_ROWS_MAX :: 6

Printer_Subtab :: enum u8 {
	Control,
	Tuning,
	Files,
	Console,
	Macros,
	Config,
	Connection,
}

Printer_State :: struct {
	client:         mr.Client,
	tracking:       Print_Tracking,
	config:         Printer_Config_State,
	initialized:    bool,
	demo:           bool,
	subtab:         Printer_Subtab,
	edit:           text_input.State,
	endpoint:       string,
	api_key:        string,
	heater_drafts:  [PRINTER_MAX_HEATERS]string,
	move_drafts:    [3]string,
	feature_speed_drafts: [PRINTER_FEATURE_MAX]string,
	feature_accel_drafts: [PRINTER_FEATURE_MAX]string,
	feature_fan_drafts:   [PRINTER_FEATURE_MAX]string,
	design_param_drafts:  [PRINTER_DESIGN_PARAM_MAX]string,
	jog_step_index: int,
	history_range:  int, // 0 = 1m, 1 = 5m, 2 = 20m
	selected_file:  string,
	files_scroll:   int,
	console_scroll: int,
	macros_scroll:  int,
	expanded_macro: string,
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
	printer_config_sync_drafts(&p.config)
	p.initialized = true
	// Auto-connect in the background on launch (non-blocking).
	if !mr.connect(&p.client, p.endpoint, p.api_key) {
		printer_set_notice(p, p.client.state.error if len(p.client.state.error) > 0 else "Unable to start Moonraker connection", true)
	}
}

printer_state_destroy :: proc(p: ^Printer_State) {
	if !p.initialized {return}
	printer_config_destroy(&p.config)
	printer_tracking_destroy(p)
	printer_thumbnail_destroy(&printer_thumbnail)
	mr.destroy(&p.client)
	text_input.destroy(&p.edit)
	delete(p.endpoint)
	delete(p.api_key)
	delete(p.selected_file)
	delete(p.download_dest)
	delete(p.expanded_macro)
	delete(p.notice)
	for &d in p.heater_drafts {delete(d)}
	for &d in p.move_drafts {delete(d)}
	for &d in p.feature_speed_drafts {delete(d)}
	for &d in p.feature_accel_drafts {delete(d)}
	for &d in p.feature_fan_drafts {delete(d)}
	for &d in p.design_param_drafts {delete(d)}
	p^ = {}
}

// Polls Moonraker every frame (even while on other tabs so live telemetry stays warm).
app_printer_poll :: proc() {
	p := &app.printer
	if !p.initialized {return}
	changed := mr.poll(&p.client)
	if printer_tracking_step(p) {changed = true}
	if printer_config_poll(p) {changed = true}
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
		if printer_thumbnail_poll(p, mr.file_index(&p.client, p.selected_file)) {
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
	if idx, ok := printer_feature_index(action, .Printer_Feature_Speed_Base); ok {
		return &p.feature_speed_drafts[idx]
	}
	if idx, ok := printer_feature_index(action, .Printer_Feature_Accel_Base); ok {
		return &p.feature_accel_drafts[idx]
	}
	if idx, ok := printer_feature_index(action, .Printer_Feature_Fan_Base); ok {
		return &p.feature_fan_drafts[idx]
	}
	if idx, ok := printer_design_param_index(action, .Printer_Design_Param_Field_Base); ok {
		return &p.design_param_drafts[idx]
	}
	return printer_config_field_ptr(p, action)
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
				printer_config_on_field_edited(p, UI_Action(u64(p.edit.active_field)))
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
		printer_config_on_field_edited(p, UI_Action(u64(p.edit.active_field)))
		app.needs_redraw = true
		return true
	case 117: // Forward delete
		_ = text_input.delete_forward(&p.edit, ptr)
		printer_config_on_field_edited(p, UI_Action(u64(p.edit.active_field)))
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
		printer_config_on_field_edited(p, UI_Action(u64(p.edit.active_field)))
		app.needs_redraw = true
		return true
	}
	return true
}

@(private = "file")
printer_submit_field :: proc(p: ^Printer_State, action: UI_Action) {
	if idx, ok := printer_feature_field_index(action); ok {
		printer_submit_feature(p, idx)
		return
	}
	if idx, ok := printer_design_param_index(action, .Printer_Design_Param_Field_Base); ok {
		printer_submit_design_param(p, idx, false)
		return
	}
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

printer_feature_index :: proc(action: UI_Action, base: UI_Action) -> (int, bool) {
	id := u64(action)
	first := u64(base)
	if id < first || id-first >= PRINTER_FEATURE_MAX {return 0, false}
	return int(id-first), true
}
printer_feature_field_index :: proc(action: UI_Action) -> (int, bool) {
	if i, ok := printer_feature_index(action, .Printer_Feature_Speed_Base); ok {return i, true}
	if i, ok := printer_feature_index(action, .Printer_Feature_Accel_Base); ok {return i, true}
	return printer_feature_index(action, .Printer_Feature_Fan_Base)
}
printer_feature_speed_action :: proc(index: int) -> UI_Action {
	return UI_Action(u64(UI_Action.Printer_Feature_Speed_Base) + u64(index))
}
printer_feature_accel_action :: proc(index: int) -> UI_Action {
	return UI_Action(u64(UI_Action.Printer_Feature_Accel_Base) + u64(index))
}
printer_feature_fan_action :: proc(index: int) -> UI_Action {
	return UI_Action(u64(UI_Action.Printer_Feature_Fan_Base) + u64(index))
}
printer_feature_apply_action :: proc(index: int) -> UI_Action {
	return UI_Action(u64(UI_Action.Printer_Feature_Apply_Base) + u64(index))
}

printer_design_param_index :: proc(action: UI_Action, base: UI_Action) -> (int, bool) {
	id := u64(action)
	first := u64(base)
	if id < first || id-first >= PRINTER_DESIGN_PARAM_MAX {return 0, false}
	return int(id-first), true
}
printer_design_param_field_action :: proc(index: int) -> UI_Action {
	return UI_Action(u64(UI_Action.Printer_Design_Param_Field_Base) + u64(index))
}
printer_design_param_apply_action :: proc(index: int) -> UI_Action {
	return UI_Action(u64(UI_Action.Printer_Design_Param_Apply_Base) + u64(index))
}
printer_design_param_reset_action :: proc(index: int) -> UI_Action {
	return UI_Action(u64(UI_Action.Printer_Design_Param_Reset_Base) + u64(index))
}

printer_macro_row_action :: proc(index: int) -> UI_Action {
	return UI_Action(u64(UI_Action.Printer_Macro_Row_Base) + u64(index))
}
printer_macro_row_index :: proc(action: UI_Action) -> (int, bool) {
	id := u64(action)
	base := u64(UI_Action.Printer_Macro_Row_Base)
	if id < base || id-base >= PRINTER_MACRO_ROW_MAX {return 0, false}
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
printer_submit_feature :: proc(p: ^Printer_State, index: int) {
	if index < 0 || index >= len(p.client.state.features) || index >= PRINTER_FEATURE_MAX {return}
	f := p.client.state.features[index]
	speed, speed_ok := strconv.parse_f64(strings.trim_space(p.feature_speed_drafts[index]))
	accel, accel_ok := strconv.parse_f64(strings.trim_space(p.feature_accel_drafts[index]))
	fan, fan_ok := strconv.parse_f64(strings.trim_space(p.feature_fan_drafts[index]))
	if !speed_ok || !accel_ok || !fan_ok {
		printer_set_notice(p, "Enter numeric speed, acceleration, and fan values", true)
		return
	}
	site := devlog.Site{feature = "printer", operation = "feature_set"}
	devlog.started(devlog.global(), site, {scope = "printer", stage = f.label})
	if mr.set_feature(&p.client, index, speed, accel, fan) {
		devlog.succeeded(devlog.global(), site, {scope = "printer", stage = f.label})
		printer_set_notice(p, fmt.tprintf("%s → %.0f mm/s · %.0f mm/s² · %.0f%%", f.label, speed, accel, fan))
	} else {
		devlog.failed(devlog.global(), site, {reason = "feature change rejected", detail = p.client.state.error, severity = .Warning})
		printer_set_notice(p, p.client.state.error if len(p.client.state.error) > 0 else "Feature change rejected", true)
	}
}

@(private = "file")
printer_submit_design_param :: proc(p: ^Printer_State, index: int, reset: bool) {
	if index < 0 || index >= len(p.client.state.design_params) || index >= PRINTER_DESIGN_PARAM_MAX {return}
	dp := p.client.state.design_params[index]
	value := dp.value
	if !reset {
		parsed, ok := strconv.parse_f64(strings.trim_space(p.design_param_drafts[index]))
		if !ok || math.is_nan(parsed) || math.is_inf(parsed, 0) {
			printer_set_notice(p, "Enter a finite design parameter value", true)
			return
		}
		value = parsed
	}
	if mr.set_design_param(&p.client, dp.name, value, reset) {
		value_text := fmt.tprintf("→ %.4g", value)
		if len(dp.unit) > 0 {value_text = fmt.tprintf("%s %s", value_text, dp.unit)}
		printer_set_notice(p, fmt.tprintf("%s %s", dp.name, "reset to base value" if reset else value_text))
	} else {
		printer_set_notice(p, p.client.state.error if len(p.client.state.error) > 0 else "Design parameter change rejected", true)
	}
}

// Keeps the live tuning drafts aligned with reported values, skipping the field being typed in.
@(private = "file")
printer_sync_tuning_drafts :: proc(p: ^Printer_State) {
	s := &p.client.state
	for f, i in s.features {
		if i >= PRINTER_FEATURE_MAX {break}
		if p.edit.active_field != text_input.Field_ID(u64(printer_feature_speed_action(i))) {
			printer_set_draft(&p.feature_speed_drafts[i], fmt.tprintf("%.0f", f.speed))
		}
		if p.edit.active_field != text_input.Field_ID(u64(printer_feature_accel_action(i))) {
			printer_set_draft(&p.feature_accel_drafts[i], fmt.tprintf("%.0f", f.acceleration))
		}
		if p.edit.active_field != text_input.Field_ID(u64(printer_feature_fan_action(i))) {
			printer_set_draft(&p.feature_fan_drafts[i], fmt.tprintf("%.0f", f.fan))
		}
	}
	for dp, i in s.design_params {
		if i >= PRINTER_DESIGN_PARAM_MAX {break}
		if p.edit.active_field == text_input.Field_ID(u64(printer_design_param_field_action(i))) {continue}
		printer_set_draft(&p.design_param_drafts[i], fmt.tprintf("%.4g", dp.value))
	}
}

@(private = "file")
printer_set_draft :: proc(draft: ^string, value: string) {
	if draft^ == value {return}
	delete(draft^)
	draft^ = strings.clone(value)
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
	if printer_config_activate(p, action) {return true}
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
	if idx, ok := printer_feature_field_index(action); ok {
		_ = idx
		printer_focus_field(p, action)
		return true
	}
	if idx, ok := printer_feature_index(action, .Printer_Feature_Apply_Base); ok {
		printer_blur_field(p)
		printer_submit_feature(p, idx)
		return true
	}
	if idx, ok := printer_design_param_index(action, .Printer_Design_Param_Field_Base); ok {
		_ = idx
		printer_focus_field(p, action)
		return true
	}
	if idx, ok := printer_design_param_index(action, .Printer_Design_Param_Apply_Base); ok {
		printer_blur_field(p)
		printer_submit_design_param(p, idx, false)
		return true
	}
	if idx, ok := printer_design_param_index(action, .Printer_Design_Param_Reset_Base); ok {
		printer_blur_field(p)
		printer_submit_design_param(p, idx, true)
		return true
	}
	if row, ok := printer_macro_row_index(action); ok {
		idx := p.macros_scroll + row
		if idx >= 0 && idx < len(p.client.state.macros) {
			name := p.client.state.macros[idx].name
			expanded := p.expanded_macro == name
			delete(p.expanded_macro)
			p.expanded_macro = "" if expanded else strings.clone(name)
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
	case .Printer_Sub_Tuning:
		printer_blur_field(p)
		p.subtab = .Tuning
	case .Printer_Sub_Macros:
		printer_blur_field(p)
		p.subtab = .Macros
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
		app.section_dirty = true
		if !p.config.resolved && !p.config.loading && p.client.state.connection == .Connected && !p.demo {
			printer_config_refresh(p)
		}
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
	case .Macros:
		visible := printer_macro_visible_rows(&app.ui)
		total := min(len(p.client.state.macros), PRINTER_MACRO_MAX)
		p.macros_scroll = clamp(p.macros_scroll + step, 0, max(0, total - visible))
		app.needs_redraw = true
		return true
	case .Tuning:
		return true
	case .Control:
		if ui_contains(ui_printer_control_card_rect(&app.ui), app.ui.pointer_x, app.ui.pointer_y) ||
		   ui_contains(ui_printer_chart_card_rect(&app.ui), app.ui.pointer_x, app.ui.pointer_y) {
			return true
		}
		return false
	case .Config:
		return printer_config_scroll(p, delta_y)
	case .Connection:
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

printer_macro_visible_rows :: proc(ui: ^UI_State) -> int {
	vp := ui_printer_viewport_rect(ui)
	return clamp(int((vp.h - 88) / 30), 1, PRINTER_MACRO_ROW_MAX)
}

printer_macro_row_height :: proc(m: mr.Macro, expanded: bool) -> f64 {
	h := 30.0
	if !expanded {return h}
	if len(m.description) > 0 {h += 20}
	if len(m.parameters) > 0 {h += 20}
	return h
}

printer_tuning_columns :: proc(ui: ^UI_State) -> (left, right: UI_Rect) {
	vp := ui_printer_viewport_rect(ui)
	gap := 24.0
	w := max(240.0, (vp.w - 32 - gap) * 0.5)
	return {vp.x+16, vp.y+12, w, vp.h-24}, {vp.x+16+w+gap, vp.y+12, vp.w-32-gap-w, vp.h-24}
}

Printer_Tuning_Row :: struct {
	label, v0, v1, v2, apply, reset: UI_Rect,
}

printer_tuning_feature_row :: proc(col: UI_Rect, y: f64) -> (row: Printer_Tuning_Row) {
	h := 26.0
	apply_w, fan_w, accel_w, speed_w := 58.0, 58.0, 70.0, 70.0
	row.apply = {col.x+col.w-apply_w, y, apply_w, h}
	row.v2 = {row.apply.x-6-fan_w, y, fan_w, h}
	row.v1 = {row.v2.x-6-accel_w, y, accel_w, h}
	row.v0 = {row.v1.x-6-speed_w, y, speed_w, h}
	row.label = {col.x, y, max(70.0, row.v0.x-6-col.x), h}
	return
}

printer_tuning_param_row :: proc(col: UI_Rect, y: f64) -> (row: Printer_Tuning_Row) {
	h := 26.0
	reset_w, apply_w, unit_w, value_w := 54.0, 58.0, 44.0, 92.0
	row.reset = {col.x+col.w-reset_w, y, reset_w, h}
	row.apply = {row.reset.x-6-apply_w, y, apply_w, h}
	row.v1 = {row.apply.x-6-unit_w, y, unit_w, h}
	row.v0 = {row.v1.x-6-value_w, y, value_w, h}
	row.label = {col.x, y, max(70.0, row.v0.x-6-col.x), h}
	return
}

printer_fans_card_rect :: proc(ui: ^UI_State) -> UI_Rect {
	rows := min(len(app.printer.client.state.fans), PRINTER_FAN_ROWS_MAX)
	if rows == 0 {return {}}
	vp := ui_printer_viewport_rect(ui)
	chart := ui_printer_chart_card_rect(ui)
	w := min(230.0, max(150.0, vp.w*0.26))
	h := 34 + f64(rows)*20
	top := vp.y + 52
	if top + h > chart.y - 12 {h = chart.y - 12 - top}
	if h < 56 || w > vp.w - 24 {return {}}
	return {vp.x+vp.w-w-12, top, w, h}
}

printer_object_name :: proc(name: string) -> string {
	for prefix in ([?]string{"fan_generic ", "heater_fan ", "controller_fan ", "temperature_fan "}) {
		if strings.has_prefix(name, prefix) {return name[len(prefix):]}
	}
	return name
}

// Controls ----------------------------------------------------------------------------------------

ui_printer_custom_control :: proc(action: UI_Action) -> bool {
	if _, ok := printer_heater_field_index(action); ok {return true}
	if _, ok := printer_file_row_index(action); ok {return true}
	if _, ok := printer_cfg_param_index(action); ok {return true}
	if _, ok := printer_cfg_row_index(action); ok {return true}
	if _, ok := printer_feature_field_index(action); ok {return true}
	if _, ok := printer_design_param_index(action, .Printer_Design_Param_Field_Base); ok {return true}
	#partial switch action {
	case .Printer_Control_Surface, .Printer_Chart_Surface,
	     .Printer_Conn_Endpoint, .Printer_Conn_Api_Key,
	     .Printer_Move_X_Field, .Printer_Move_Y_Field, .Printer_Move_Z_Field,
	     .Printer_Cfg_Search:
		return true
	}
	return false
}

ui_printer_controls :: proc(ui: ^UI_State) {
	p := &app.printer
	s := &p.client.state
	sub := ui_printer_subbar_rect(ui)
	sub_items := [7]struct {
		tab:    Printer_Subtab,
		action: UI_Action,
		name:   string,
		label:  string,
		w:      f64,
	}{
		{.Control, .Printer_Sub_Control, "printer control tab", "Control", 78},
		{.Tuning, .Printer_Sub_Tuning, "printer tuning tab", "Tuning", 74},
		{.Files, .Printer_Sub_Files, "printer files tab", "Files", 66},
		{.Console, .Printer_Sub_Console, "printer console tab", "Console", 80},
		{.Macros, .Printer_Sub_Macros, "printer macros tab", "Macros", 74},
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

	case .Console:
		// Read-only scrollable log.
	case .Tuning:
		printer_sync_tuning_drafts(p)
		left, right := printer_tuning_columns(ui)
		editable := s.connection == .Connected && !p.demo && !s.stale && s.printer_state == "ready"
		y := left.y + 54
		features := min(len(s.features), PRINTER_FEATURE_MAX)
		for i in 0..<features {
			row := printer_tuning_feature_row(left, y)
			if row.v0.y + row.v0.h > left.y + left.h {break}
			f := s.features[i]
			ui_add_control(ui, fmt.tprintf("feature %d speed", i), fmt.tprintf("%s speed in mm/s", f.label), row.v0, printer_feature_speed_action(i), editable)
			ui_add_control(ui, fmt.tprintf("feature %d accel", i), fmt.tprintf("%s acceleration in mm/s²", f.label), row.v1, printer_feature_accel_action(i), editable)
			ui_add_control(ui, fmt.tprintf("feature %d fan", i), fmt.tprintf("%s fan in percent", f.label), row.v2, printer_feature_fan_action(i), editable)
			ui_add_control(ui, fmt.tprintf("feature %d apply", i), fmt.tprintf("Apply %s", f.label), row.apply, printer_feature_apply_action(i), editable)
			y += 32
		}

		y = right.y + 54
		params := min(len(s.design_params), PRINTER_DESIGN_PARAM_MAX)
		for i in 0..<params {
			row := printer_tuning_param_row(right, y)
			if row.v0.y + row.v0.h > right.y + right.h {break}
			dp := s.design_params[i]
			can_edit := editable && dp.editable
			ui_add_control(ui, fmt.tprintf("design param %d value", i), fmt.tprintf("%s value", dp.name), row.v0, printer_design_param_field_action(i), can_edit)
			if dp.editable {
				ui_add_control(ui, fmt.tprintf("design param %d apply", i), fmt.tprintf("Apply %s", dp.name), row.apply, printer_design_param_apply_action(i), can_edit)
			}
			if dp.editable && dp.overridden {
				ui_add_control(ui, fmt.tprintf("design param %d reset", i), fmt.tprintf("Reset %s", dp.name), row.reset, printer_design_param_reset_action(i), can_edit)
			}
			y += 32
		}

	case .Macros:
		visible := printer_macro_visible_rows(ui)
		macros := s.macros
		total := min(len(macros), PRINTER_MACRO_MAX)
		p.macros_scroll = clamp(p.macros_scroll, 0, max(0, total - visible))
		list_w := max(200.0, vp.w - 32)
		y := vp.y + 54
		bottom := vp.y + vp.h - 12
		row := 0
		for idx := p.macros_scroll; idx < total && row < visible; idx += 1 {
			if y + 30 > bottom {break}
			m := macros[idx]
			expanded := p.expanded_macro == m.name
			ui_add_control(ui, fmt.tprintf("macro row %d", row), m.name, {vp.x+16, y, list_w, 30}, printer_macro_row_action(row), true, 1, expanded)
			y += printer_macro_row_height(m, expanded)
			row += 1
		}

	case .Config:
		ui_printer_config_controls(ui)

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
	if p.demo {return "Offline preview (sample data)", theme.warning}
	switch p.client.state.connection {
	case .Connected:
		if p.client.state.stale {return "Connected (stale)", theme.warning}
		host := p.client.state.hostname if len(p.client.state.hostname) > 0 else "ratos"
		return fmt.tprintf("Connected · %s", host), theme.mint
	case .Connecting, .Initializing:
		return "Connecting…", theme.blue
	case .Reconnecting:
		return "Reconnecting…", theme.warning
	case .Failed:
		return "Connection failed", theme.danger
	case .Offline:
		return "Offline", theme.muted
	}
	return "Offline", theme.muted
}

printer_draw_text_field :: proc(painter: ^UI_Painter, ui: ^UI_State, action: UI_Action, value: string, placeholder: string, masked := false) {
	rect := ui_control_rect(ui, action)
	if rect.w <= 0 || rect.h <= 0 {return}
	theme := ui_theme(ui)
	p := &app.printer
	active := p.edit.active_field == text_input.Field_ID(u64(action))
	enabled := true
	for c in ui.controls {
		if c.action == action {enabled = c.enabled; break}
	}
	fill := theme.surface if enabled else theme.disabled_fill
	border := theme.border if enabled else theme.disabled_ink
	ui_neo_box(painter, rect, 8, fill, border, theme.border_width)
	if active && enabled {
		ui_neo_focus_ring(painter, theme, rect, 8)
	}

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
				sel_col := theme.lavender
				sel_col.w = 0.55
				ui_add_rect(painter, {sx, rect.y+4, sw, rect.h-8}, sel_col)
			}
		}
		caret_x := min(rect.x + 8 + f64(p.edit.caret_byte_offset)*ch, rect.x + rect.w - 6)
		ui_add_rect(painter, {caret_x, rect.y+5, 1.8, rect.h-10}, theme.focus)
	}
	ui_draw_text(painter, painter.mono, ui, display, rect, theme.text, 8, tracked = true)
}

ui_draw_printer_panels :: proc(painter: ^UI_Painter, ui: ^UI_State) {
	theme := ui_theme(ui)
	p := &app.printer
	ui_add_rect(painter, {0, 0, ui.width, 40}, theme.header)
	ui_add_rect(painter, {0, 40-theme.border_width, ui.width, theme.border_width}, theme.border)

	vp := ui_printer_viewport_rect(ui)
	switch p.subtab {
	case .Control:
		ctrl := ui_printer_control_card_rect(ui)
		ui_neo_panel(painter, ui, ctrl, theme.surface, theme.radius, true)

		chart := ui_printer_chart_card_rect(ui)
		if chart.w >= 260 {
			ui_neo_panel(painter, ui, chart, theme.surface, theme.radius, true)
		}
		fans := printer_fans_card_rect(ui)
		if fans.w > 0 {
			ui_neo_panel(painter, ui, fans, theme.surface, theme.radius, true)
		}
	case .Config:
		panel := ui_printer_config_left_rect(ui)
		ui_neo_panel(painter, ui, panel, theme.surface, theme.radius, true)
	case .Files, .Console, .Connection, .Tuning, .Macros:
		ui_neo_panel(painter, ui, vp, theme.surface, theme.radius, true)
	}
}

ui_draw_printer_labels :: proc(painter: ^UI_Painter, ui: ^UI_State) {
	theme := ui_theme(ui)
	p := &app.printer
	s := &p.client.state
	sub := ui_printer_subbar_rect(ui)

	sub_labels := [7]struct {action: UI_Action, text: string}{
		{.Printer_Sub_Control, "Control"},
		{.Printer_Sub_Tuning, "Tuning"},
		{.Printer_Sub_Files, "Files"},
		{.Printer_Sub_Console, "Console"},
		{.Printer_Sub_Macros, "Macros"},
		{.Printer_Sub_Config, "Config"},
		{.Printer_Sub_Connection, "Connection"},
	}
	for item in sub_labels {
		ui_draw_text(painter, painter.semibold, ui, item.text, ui_control_rect(ui, item.action), ui_control_ink(ui, item.action), 0, .Center)
	}
	// Live connection badge in the sub-bar.
	conn_text, conn_col := printer_connection_label(p)
	conn_x := sub.x + 584
	stop_rect := ui_control_rect(ui, .Printer_Emergency_Stop)
	if stop_rect.x - conn_x > 130 {
		badge_w := min(220.0, stop_rect.x - conn_x - 16)
		badge_r := UI_Rect{conn_x, sub.y+4, badge_w, 28}
		ui_neo_badge(painter, ui, badge_r, theme.surface, true)
		ui_neo_box(painter, {badge_r.x+10, badge_r.y+9, 10, 10}, 5, conn_col, theme.border, 1.3)
		ui_draw_text(painter, painter.semibold, ui, conn_text, {badge_r.x+26, badge_r.y, badge_r.w-34, badge_r.h}, theme.text, 0)
	}
	// Prominent neobrutalist Emergency STOP button.
	if stop_rect.w > 0 {
		can_stop := s.connection == .Connected && !p.demo
		stop_r := stop_rect
		if can_stop {
			ui_neo_shadow(painter, stop_r, 8, theme.depth*0.75, theme.shadow)
			if ui.pressed_id == u64(UI_Action.Printer_Emergency_Stop) {
				stop_r = {stop_r.x+theme.depth*0.75, stop_r.y+theme.depth*0.75, stop_r.w, stop_r.h}
			}
		}
		stop_fill := theme.danger if can_stop else theme.disabled_fill
		stop_border := theme.border if can_stop else theme.disabled_ink
		ui_neo_box(painter, stop_r, 8, stop_fill, stop_border, theme.border_width)
		ui_draw_text(painter, painter.bold, ui, "STOP", stop_r, NEO_DARK_INK if can_stop else theme.disabled_ink, 0, .Center)
	}

	vp := ui_printer_viewport_rect(ui)
	switch p.subtab {
	case .Control:
		printer_draw_control_overlay(painter, ui, p)
	case .Tuning:
		printer_draw_tuning_panel(painter, ui, p, vp)
	case .Macros:
		printer_draw_macros_panel(painter, ui, p, vp)
	case .Files:
		printer_draw_files_panel(painter, ui, p, vp)
	case .Console:
		printer_draw_console_panel(painter, ui, p, vp)
	case .Config:
		ui_draw_printer_config(painter, ui, p)
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

	ui_draw_text(painter, painter.semibold, ui, "Frame", ui_control_rect(ui, .Frame_Mesh), ui_control_ink(ui, .Frame_Mesh), 0, .Center)

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
	ui_neo_dashed_divider(painter, ui, ctrl.x+12, ctrl.y+104, ctrl.w-24)

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
	ui_neo_dashed_divider(painter, ui, ctrl.x+12, motion_y-6, ctrl.w-24)
	ui_draw_text(painter, painter.bold, ui, "Motion & Machine", {ctrl.x+12, motion_y, ctrl.w-24, 20}, theme.text, 0)
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
		ui_draw_text(painter, painter.semibold, ui, b.text, ui_control_rect(ui, b.action), ui_control_ink(ui, b.action), 0, .Center)
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
		ui_draw_text(painter, painter.bold, ui, "Temperatures", {chart.x+12, chart.y+8, 120, 22}, theme.text, 0)
		ui_draw_text(painter, painter.semibold, ui, "1m", ui_control_rect(ui, .Printer_History_1m), ui_control_ink(ui, .Printer_History_1m), 0, .Center)
		ui_draw_text(painter, painter.semibold, ui, "5m", ui_control_rect(ui, .Printer_History_5m), ui_control_ink(ui, .Printer_History_5m), 0, .Center)
		ui_draw_text(painter, painter.semibold, ui, "20m", ui_control_rect(ui, .Printer_History_20m), ui_control_ink(ui, .Printer_History_20m), 0, .Center)
		ui_draw_text(painter, painter.semibold, ui, "Sync", ui_control_rect(ui, .Printer_History_Refresh), ui_control_ink(ui, .Printer_History_Refresh), 0, .Center)
		printer_draw_temperature_chart(painter, ui, p, {chart.x+12, chart.y+38, chart.w-24, chart.h-50})
	}
	printer_draw_fans_card(painter, ui)
}

@(private = "file")
printer_draw_fans_card :: proc(painter: ^UI_Painter, ui: ^UI_State) {
	card := printer_fans_card_rect(ui)
	if card.w <= 0 {return}
	theme := ui_theme(ui)
	ui_draw_text(painter, painter.bold, ui, "Fans", {card.x+12, card.y+6, card.w-24, 20}, theme.text, 0)
	y := card.y + 28
	for fan, i in app.printer.client.state.fans {
		if i >= PRINTER_FAN_ROWS_MAX || y + 20 > card.y + card.h - 4 {break}
		speed := fmt.tprintf("%.0f%%", fan.speed*100) if fan.available else "Unknown"
		ui_draw_text(painter, painter.font, ui, printer_object_name(fan.name), {card.x+12, y, card.w*0.55, 20}, theme.text, 0)
		ui_draw_text(painter, painter.mono, ui, speed, {card.x+card.w-88, y, 76, 20}, theme.accent if fan.available && fan.speed > 0 else theme.muted, 0, .End, tracked = true)
		y += 20
	}
}

@(private = "file")
printer_draw_tuning_panel :: proc(painter: ^UI_Painter, ui: ^UI_State, p: ^Printer_State, vp: UI_Rect) {
	theme := ui_theme(ui)
	s := &p.client.state
	left, right := printer_tuning_columns(ui)

	// Print features column.
	ui_draw_text(painter, painter.bold, ui, "Print features (live)", {left.x, left.y, left.w, 22}, theme.text, 0)
	header := printer_tuning_feature_row(left, left.y + 26)
	ui_draw_text(painter, painter.font, ui, "Feature", header.label, theme.muted, 0)
	ui_draw_text(painter, painter.font, ui, "mm/s", header.v0, theme.muted, 0, .Center)
	ui_draw_text(painter, painter.font, ui, "mm/s²", header.v1, theme.muted, 0, .Center)
	ui_draw_text(painter, painter.font, ui, "Fan%", header.v2, theme.muted, 0, .Center)
	y := left.y + 54
	features := min(len(s.features), PRINTER_FEATURE_MAX)
	if features == 0 {
		ui_draw_text(painter, painter.font, ui, "No live print features reported", {left.x, y, left.w, 22}, theme.muted, 0)
	}
	for i in 0..<features {
		row := printer_tuning_feature_row(left, y)
		if row.v0.y + row.v0.h > left.y + left.h {break}
		f := s.features[i]
		active := s.job_current_feature == f.index
		label := fmt.tprintf("%s%s", "* " if active else "  ", f.label)
		ui_draw_text(painter, painter.font, ui, label, row.label, theme.accent if active else theme.text, 0)
		printer_draw_text_field(painter, ui, printer_feature_speed_action(i), p.feature_speed_drafts[i], "")
		printer_draw_text_field(painter, ui, printer_feature_accel_action(i), p.feature_accel_drafts[i], "")
		printer_draw_text_field(painter, ui, printer_feature_fan_action(i), p.feature_fan_drafts[i], "")
		apply_action := printer_feature_apply_action(i)
		ui_draw_text(painter, painter.font, ui, "Apply", ui_control_rect(ui, apply_action), ui_control_ink(ui, apply_action), 0, .Center)
		y += 32
	}

	// Design parameters column.
	heading := fmt.tprintf("Design parameters (live · rev %d)", s.job_design_revision) if s.job_design_revision > 0 else "Design parameters (live)"
	ui_draw_text(painter, painter.bold, ui, heading, {right.x, right.y, right.w, 22}, theme.text, 0)
	header = printer_tuning_param_row(right, right.y + 26)
	ui_draw_text(painter, painter.font, ui, "Parameter", header.label, theme.muted, 0)
	ui_draw_text(painter, painter.font, ui, "Value", header.v0, theme.muted, 0, .Center)
	ui_draw_text(painter, painter.font, ui, "Unit", header.v1, theme.muted, 0, .Center)
	y = right.y + 54
	params := min(len(s.design_params), PRINTER_DESIGN_PARAM_MAX)
	if params == 0 {
		ui_draw_text(painter, painter.font, ui, "No live design parameters reported", {right.x, y, right.w, 22}, theme.muted, 0)
	}
	for i in 0..<params {
		row := printer_tuning_param_row(right, y)
		if row.v0.y + row.v0.h > right.y + right.h {break}
		dp := s.design_params[i]
		label := fmt.tprintf("%s%s", "* " if dp.overridden else "  ", dp.name)
		ui_draw_text(painter, painter.font, ui, label, row.label, theme.accent if dp.overridden else theme.text, 0)
		printer_draw_text_field(painter, ui, printer_design_param_field_action(i), p.design_param_drafts[i], "")
		ui_draw_text(painter, painter.mono, ui, dp.unit, row.v1, theme.muted, 0, .Center, tracked = true)
		if dp.editable {
			apply_action := printer_design_param_apply_action(i)
			ui_draw_text(painter, painter.font, ui, "Apply", ui_control_rect(ui, apply_action), ui_control_ink(ui, apply_action), 0, .Center)
			if dp.overridden {
				reset_action := printer_design_param_reset_action(i)
				ui_draw_text(painter, painter.font, ui, "Reset", ui_control_rect(ui, reset_action), ui_control_ink(ui, reset_action), 0, .Center)
			}
		} else {
			ui_draw_text(painter, painter.font, ui, dp.reason if len(dp.reason) > 0 else "locked", row.apply, theme.muted, 0)
		}
		y += 32
	}
}

@(private = "file")
printer_draw_macros_panel :: proc(painter: ^UI_Painter, ui: ^UI_State, p: ^Printer_State, vp: UI_Rect) {
	theme := ui_theme(ui)
	macros := p.client.state.macros
	ui_draw_text(painter, painter.font, ui, fmt.tprintf("Macros (%d discovered)", len(macros)), {vp.x+16, vp.y+10, vp.w-32, 22}, theme.text, 0)
	ui_draw_text(painter, painter.font, ui, "Select a macro to show its description and parameters. Execution is not available.", {vp.x+16, vp.y+32, vp.w-32, 16}, theme.muted, 0)
	if len(macros) == 0 {
		ui_draw_text(painter, painter.font, ui, "No macros discovered. Connect to a printer that reports its macro list.", {vp.x+16, vp.y+54, vp.w-32, 22}, theme.muted, 0)
		return
	}
	visible := printer_macro_visible_rows(ui)
	total := min(len(macros), PRINTER_MACRO_MAX)
	row := 0
	for idx := p.macros_scroll; idx < total && row < visible; idx += 1 {
		action := printer_macro_row_action(row)
		r := ui_control_rect(ui, action)
		if r.w <= 0 {break}
		m := macros[idx]
		expanded := p.expanded_macro == m.name
		ui_draw_text(painter, painter.font, ui, fmt.tprintf("%s %s", "−" if expanded else "+", m.name), r, ui_control_ink(ui, action), 0)
		if expanded {
			dy := r.y + 32
			if len(m.description) > 0 {
				ui_draw_text(painter, painter.font, ui, m.description, {vp.x+28, dy, vp.w-56, 18}, theme.muted, 0)
				dy += 20
			}
			if len(m.parameters) > 0 {
				ui_draw_text(painter, painter.mono, ui, m.parameters, {vp.x+28, dy, vp.w-56, 18}, theme.text, 0, tracked = true)
			}
		}
		row += 1
	}
	if len(macros) > PRINTER_MACRO_MAX {
		ui_draw_text(painter, painter.mono, ui, fmt.tprintf("Showing the first %d macros", PRINTER_MACRO_MAX), {vp.x+16, vp.y+vp.h-24, vp.w-32, 18}, theme.muted, 0, tracked = true)
	}
}

@(private = "file")
printer_draw_temperature_chart :: proc(painter: ^UI_Painter, ui: ^UI_State, p: ^Printer_State, plot: UI_Rect) {
	theme := ui_theme(ui)
	ui_neo_box(painter, plot, 7, theme.track, theme.border, theme.border_width)
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
			ui_neo_box(painter, r, 7, theme.lavender, theme.border, theme.border_width)
		} else if hovered {
			ui_neo_box(painter, r, 7, theme.track, theme.border, 1.2)
		}
		ink := NEO_DARK_INK if selected else theme.text
		muted := NEO_DARK_INK if selected else theme.muted
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
		ui_draw_text(painter, painter.font, ui, "Loading slicer metadata…", {detail_x+12, y, detail_w-24, 22}, theme.muted, 0); y += 24
	}
	if thumb := printer_thumbnail_label(&printer_thumbnail); len(thumb) > 0 {
		ui_draw_measurement(painter, ui, "Thumbnail", thumb, {detail_x+12, y, detail_w-24, 22}, 110); y += 24
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
