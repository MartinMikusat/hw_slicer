package main

import "core:testing"

@(test)
ui_registry_preserves_numbered_action_slots_test :: proc(t: ^testing.T) {
	ui: UI_State
	ui_initialize(&ui)
	defer ui_destroy(&ui)
	ui.width = 1280
	ui.height = 800
	ui.scale = 2
	ui.dark = true
	ui_build_controls(&ui)

	testing.expect_value(t, len(ui.controls), 16)
	first_action := ui.controls[10]
	testing.expect_value(t, first_action.action, UI_Action.Open)
	testing.expect(t, first_action.enabled)
	for index in 11..<16 {
		testing.expect(t, !ui.controls[index].enabled)
	}
	testing.expect_value(t, ui.controls[15].action, UI_Action.Export)
}

@(test)
ui_help_transition_exposes_only_window_and_modal_actions_test :: proc(t: ^testing.T) {
	ui: UI_State
	ui_initialize(&ui)
	defer ui_destroy(&ui)
	ui.width = 1280
	ui.height = 800
	ui.scale = 2
	ui_build_controls(&ui)
	ui.help_open = true
	ui_build_controls(&ui)
	testing.expect_value(t, len(ui.controls), 4)
	testing.expect_value(
		t,
		ui.controls[len(ui.controls)-1].action,
		UI_Action.Close_Help,
	)
}

@(test)
ui_hit_test_ignores_disabled_numbered_actions_test :: proc(t: ^testing.T) {
	ui: UI_State
	ui_initialize(&ui)
	defer ui_destroy(&ui)
	ui.width = 1280
	ui.height = 800
	ui.scale = 2
	ui_build_controls(&ui)

	open := ui.controls[10]
	slice := ui.controls[11]
	testing.expect_value(
		t,
		ui_hit_test(&ui, open.rect.x+10, open.rect.y+10),
		u64(UI_Action.Open),
	)
	testing.expect_value(
		t,
		ui_hit_test(&ui, slice.rect.x+10, slice.rect.y+10),
		u64(0),
	)
}
