package main

import "core:fmt"
import "core:os"
import "core:testing"

@(test)
settings_font_size_round_trip_and_clamp_test :: proc(t: ^testing.T) {
	path := fmt.aprintf(
		"%s/hw-slicer-settings-test.json",
		os.get_env("TMPDIR", context.temp_allocator),
	)
	defer delete(path)
	os.remove(path)
	testing.expect(t, settings_save(path, {font_size = 99}))
	loaded := settings_defaults()
	testing.expect(t, settings_load(path, &loaded))
	testing.expect_value(t, loaded.font_size, FONT_SIZE_MAX)
	os.remove(path)
}

@(test)
ui_settings_modal_registers_font_controls_test :: proc(t: ^testing.T) {
	ui: UI_State
	ui_initialize(&ui)
	defer ui_destroy(&ui)
	ui.width = 1280
	ui.height = 800
	ui.scale = 2
	ui.settings_open = true
	ui_build_controls(&ui)
	testing.expect_value(t, len(ui.controls), 8)
	testing.expect_value(t, ui.controls[5].action, UI_Action.Font_Decrease)
	testing.expect_value(t, ui.controls[6].action, UI_Action.Font_Increase)
	testing.expect_value(t, ui.controls[7].action, UI_Action.Close_Settings)
	testing.expect_value(
		t,
		ui_hit_test(
			&ui,
			ui.controls[6].rect.x+10,
			ui.controls[6].rect.y+10,
		),
		u64(UI_Action.Font_Increase),
	)
	testing.expect_value(
		t,
		ui_hit_test(&ui, 5, 795),
		u64(UI_Action.Dismiss_Settings),
	)
}

@(test)
ui_content_scale_applies_to_text_rects_test :: proc(t: ^testing.T) {
	ui: UI_State
	ui_initialize(&ui)
	defer ui_destroy(&ui)
	ui.ui_scale = 2
	ui.scale = 1
	ui.height = 800
	rect := ui_cg_rect(&ui, {10, 10, 100, 20})
	testing.expect_value(t, rect.origin.x, f64(20))
	testing.expect_value(t, rect.size.width, f64(200))
	testing.expect_value(t, rect.size.height, f64(40))
}
