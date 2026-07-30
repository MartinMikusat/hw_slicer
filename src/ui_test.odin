package main

import "core:testing"
import "core:strings"

import evidence "./evidence"

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
	testing.expect(t, ui.controls[5].selected)
	testing.expect(t, !ui.controls[6].selected)
	first_action := ui.controls[10]
	testing.expect_value(t, first_action.action, UI_Action.Open)
	testing.expect(t, first_action.enabled)
	for index in 11..<16 {
		testing.expect(t, !ui.controls[index].enabled)
	}
	testing.expect_value(t, ui.controls[15].action, UI_Action.Export)
}

@(test)
ui_evidence_transition_registers_stage_selection_test :: proc(t: ^testing.T) {
	ui: UI_State
	ui_initialize(&ui)
	defer ui_destroy(&ui)
	ui.width = 1280
	ui.height = 800
	ui.scale = 2
	stages := [3]evidence.Evidence_Bundle_Stage{
		{ordinal = 7, stage = {name = "reconstruct-topology"}},
		{ordinal = 8, stage = {name = "calculate-regions"}},
		{ordinal = 10, stage = {name = "plan-paths"}},
	}
	manifests: [3]evidence.Evidence_Manifest
	replay := evidence.Evidence_Bundle_Replay{
		root = {stages = stages[:]},
		stage_manifests = manifests[:],
	}
	view := UI_Evidence_View{
		replay = &replay,
		source = "fixture.hwsdebug",
		container = "PACKAGE",
	}
	ui.evidence_open = true
	ui.evidence_stage_index = 2
	ui_build_controls(&ui, &view)

	testing.expect_value(t, len(ui.controls), 7)
	testing.expect_value(
		t,
		ui.controls[3].action,
		ui_evidence_stage_action(0),
	)
	testing.expect(t, !ui.controls[3].selected)
	testing.expect(t, ui.controls[5].selected)
	testing.expect_value(
		t,
		ui.controls[6].action,
		UI_Action.Close_Evidence,
	)
	stage_index, stage_ok := ui_evidence_stage_action_index(
		ui.controls[5].action,
		len(stages),
	)
	testing.expect(t, stage_ok)
	testing.expect_value(t, stage_index, 2)
	testing.expect_value(
		t,
		ui_hit_test(
			&ui,
			ui.controls[5].rect.x+10,
			ui.controls[5].rect.y+10,
		),
		u64(ui_evidence_stage_action(2)),
	)
	snapshot := ui_snapshot_text(&ui)
	defer delete(snapshot)
	testing.expect(t, strings.contains(snapshot, "modal\tevidence"))
	testing.expect(t, strings.contains(snapshot, "selected_stage\t2"))
}

@(test)
ui_evidence_graph_state_reports_retained_motion_test :: proc(t: ^testing.T) {
	replay := evidence.Evidence_Bundle_Replay{
		path_plan_loaded = true,
		extrusion_loaded = true,
		motion_plan_loaded = true,
	}
	testing.expect_value(
		t,
		ui_evidence_graph_state("plan-paths", &replay),
		"PATH + EXTRUSION + MOTION GRAPHS RETAINED",
	)
	replay.extrusion_loaded = false
	testing.expect_value(
		t,
		ui_evidence_graph_state("plan-paths", &replay),
		"PATH + MOTION GRAPHS RETAINED",
	)
	replay.path_plan_loaded = false
	testing.expect_value(
		t,
		ui_evidence_graph_state("plan-paths", &replay),
		"MOTION GRAPH RETAINED",
	)
	replay.extrusion_loaded = true
	testing.expect_value(
		t,
		ui_evidence_graph_state("plan-paths", &replay),
		"EXTRUSION + MOTION GRAPHS RETAINED",
	)
	replay.motion_plan_loaded = false
	testing.expect_value(
		t,
		ui_evidence_graph_state("plan-paths", &replay),
		"EXTRUSION GRAPH RETAINED",
	)
	replay.extrusion_loaded = false
	testing.expect_value(
		t,
		ui_evidence_graph_state("plan-paths", &replay),
		"MANIFEST RETAINED",
	)
}

@(test)
ui_evidence_graph_state_reports_retained_feature_sources_test :: proc(
	t: ^testing.T,
) {
	replay := evidence.Evidence_Bundle_Replay{
		perimeters_loaded = true,
		infill_loaded = true,
		unified_sources_loaded = true,
	}
	testing.expect_value(
		t,
		ui_evidence_graph_state("generate-features", &replay),
		"PERIMETER + INFILL + FEATURE SOURCE GRAPHS RETAINED",
	)
	replay.unified_sources_loaded = false
	testing.expect_value(
		t,
		ui_evidence_graph_state("generate-features", &replay),
		"PERIMETER + INFILL GRAPHS RETAINED",
	)
	replay.infill_loaded = false
	replay.unified_sources_loaded = true
	testing.expect_value(
		t,
		ui_evidence_graph_state("generate-features", &replay),
		"PERIMETER + FEATURE SOURCE GRAPHS RETAINED",
	)
	replay.perimeters_loaded = false
	replay.infill_loaded = true
	testing.expect_value(
		t,
		ui_evidence_graph_state("generate-features", &replay),
		"INFILL + FEATURE SOURCE GRAPHS RETAINED",
	)
	replay.unified_sources_loaded = false
	testing.expect_value(
		t,
		ui_evidence_graph_state("generate-features", &replay),
		"INFILL GRAPH RETAINED",
	)
	replay.infill_loaded = false
	replay.perimeters_loaded = true
	testing.expect_value(
		t,
		ui_evidence_graph_state("generate-features", &replay),
		"PERIMETER GRAPH RETAINED",
	)
	replay.perimeters_loaded = false
	replay.unified_sources_loaded = true
	testing.expect_value(
		t,
		ui_evidence_graph_state("generate-features", &replay),
		"FEATURE SOURCE GRAPH RETAINED",
	)
	replay.unified_sources_loaded = false
	testing.expect_value(
		t,
		ui_evidence_graph_state("generate-features", &replay),
		"MANIFEST RETAINED",
	)
}

@(test)
ui_evidence_graph_state_reports_retained_unified_plan_test :: proc(
	t: ^testing.T,
) {
	replay := evidence.Evidence_Bundle_Replay{
		unified_plan_loaded = true,
		extrusion_loaded = true,
		motion_plan_loaded = true,
	}
	testing.expect_value(
		t,
		ui_evidence_graph_state("plan-paths", &replay),
		"UNIFIED PATH + EXTRUSION + MOTION GRAPHS RETAINED",
	)
	replay.extrusion_loaded = false
	testing.expect_value(
		t,
		ui_evidence_graph_state("plan-paths", &replay),
		"UNIFIED PATH + MOTION GRAPHS RETAINED",
	)
	replay.motion_plan_loaded = false
	testing.expect_value(
		t,
		ui_evidence_graph_state("plan-paths", &replay),
		"UNIFIED PATH-PLAN GRAPH RETAINED",
	)
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
