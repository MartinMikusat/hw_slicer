package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import formats "../formats"
import pipeline "../pipeline"

// Drives the workspace controller from a text script and prints what the interface would show
// after each action. This is the headless stand-in for the application window.
//
//   select <stage>          stage by index or name prefix
//   set <key> <value>       edit a setting
//   reset <key> | resetsel  return a setting | the selected stage's settings to the defaults
//   run <stage>             start the stage and what it needs (index or name prefix)
//   runsel                  run the selected stage and what it needs
//   runonly <stage>         recompute only the stage from the current results it needs
//   auto on|off             let setting changes start quick stale stages by themselves
//   cancel | wait           cancel the active run | wait for it to end
//   view | settings         print the stage graph | the selected stage's settings
//   check <stage> <state>   print a mismatch and exit 1 when the stage has another state
run_workspace_script :: proc(script_path: string, config: pipeline.Slice_Configuration, mesh: formats.Decoded_Mesh) {
	data, read_err := os.read_entire_file(script_path, context.allocator)
	if read_err != nil {
		fmt.eprintf("error: failed to read script '%s'\n", script_path)
		os.exit(1)
	}
	defer delete(data)
	w, detail, ok := pipeline.workspace_create(config, mesh)
	if !ok {
		fmt.eprintf("error: %s\n", detail)
		os.exit(1)
	}
	defer pipeline.workspace_destroy(w)

	failed := false
	for raw_line in strings.split_lines(string(data), context.temp_allocator) {
		line := strings.trim_space(raw_line)
		if len(line) == 0 || line[0] == '#' {continue}
		words := strings.fields(line, context.temp_allocator)
		fmt.printf("> %s\n", line)
		switch words[0] {
		case "select":
			if len(words) < 2 {fmt.println("  usage: select <stage>"); continue}
			name := strings.join(words[1:], " ", context.temp_allocator)
			if id, found := find_stage(name); found {
				pipeline.workspace_select(w, id)
			} else {fmt.printf("  no stage '%s'\n", name)}
		case "set":
			if len(words) < 3 {fmt.println("  usage: set <key> <value>"); continue}
			if detail, ok := pipeline.workspace_edit(w, words[1], words[2]); !ok {
				fmt.printf("  rejected: %s\n", detail)
			} else if pipeline.workspace_running(w) {
				fmt.println("  accepted, run started" if pipeline.workspace_view(w).queued_edits == 0 else "  accepted, queued until the run ends")
			} else {
				fmt.println("  accepted")
			}
		case "run":
			if len(words) < 2 {fmt.println("  usage: run <stage>"); continue}
			name := strings.join(words[1:], " ", context.temp_allocator)
			if id, found := find_stage(name); found {
				if !pipeline.workspace_run_to(w, id) {fmt.println("  busy")}
			} else {fmt.printf("  no stage '%s'\n", name)}
		case "runsel":
			if !pipeline.workspace_run_selected(w) {fmt.println("  busy")}
		case "runonly":
			if len(words) < 2 {fmt.println("  usage: runonly <stage>"); continue}
			name := strings.join(words[1:], " ", context.temp_allocator)
			if id, found := find_stage(name); found {
				if !pipeline.workspace_run_only(w, id) {fmt.println("  refused: busy, or an input has no current result")}
			} else {fmt.printf("  no stage '%s'\n", name)}
		case "reset":
			if len(words) < 2 {fmt.println("  usage: reset <key>"); continue}
			if detail, ok := pipeline.workspace_reset_setting(w, words[1]); !ok {fmt.printf("  rejected: %s\n", detail)}
		case "resetsel":
			if detail, ok := pipeline.workspace_reset_stage(w, w.selected); !ok {fmt.printf("  rejected: %s\n", detail)}
		case "auto":
			pipeline.workspace_set_auto_run(w, len(words) > 1 && words[1] == "on")
		case "cancel":
			pipeline.workspace_cancel(w)
		case "wait":
			pipeline.workspace_wait(w)
		case "sleep":
			if len(words) > 1 {
				if ms, ok := strconv.parse_int(words[1]); ok {time.sleep(time.Duration(ms) * time.Millisecond)}
			}
			pipeline.workspace_poll(w)
		case "view":
			print_workspace_view(w)
		case "settings":
			print_workspace_settings(w)
		case "check":
			if len(words) < 3 {fmt.println("  usage: check <stage> <state>"); continue}
			expected := words[len(words)-1]
			id, found := find_stage(strings.join(words[1:len(words)-1], " ", context.temp_allocator))
			if !found {fmt.printf("  no stage in '%s'\n", line); failed = true; continue}
			stage := pipeline.workspace_view(w).stages[id]
			state := fmt.tprintf("%v", stage.state)
			if strings.equal_fold(state, expected) {
				fmt.printf("  ok: %s is %s\n", stage.name, state)
			} else {
				fmt.printf("  MISMATCH: %s is %s, expected %s\n", stage.name, state, expected)
				failed = true
			}
		case:
			fmt.printf("  unknown action '%s'\n", words[0])
		}
	}
	pipeline.workspace_wait(w)
	if len(w.last_error.stage) > 0 {
		fmt.printf("last run error [%s]: %s\n", w.last_error.stage, w.last_error.detail)
		failed = true
	}
	if failed {os.exit(1)}
}

find_stage :: proc(text: string) -> (pipeline.Stage_Id, bool) {
	if n, ok := strconv.parse_int(text); ok && n >= 0 && n < len(pipeline.Stage_Id) {
		return pipeline.Stage_Id(n), true
	}
	for id in pipeline.Stage_Id {
		if strings.has_prefix(strings.to_lower(pipeline.stage_descriptors[id].name, context.temp_allocator), strings.to_lower(text, context.temp_allocator)) {
			return id, true
		}
	}
	return {}, false
}

print_workspace_view :: proc(w: ^pipeline.Workspace) {
	view := pipeline.workspace_view(w)
	fmt.printf("  %s%s\n",
		"RUNNING" if view.running else "idle",
		fmt.tprintf("  queued edits: %d", view.queued_edits) if view.queued_edits > 0 else "")
	columns := pipeline.stage_columns()
	for id in pipeline.Stage_Id {
		st := view.stages[id]
		mark := ">" if id == view.selected else " "
		state := fmt.tprintf("%v", st.state)
		if st.queued {state = "Queued"}
		if st.cancelled {state = "Cancelled"}
		note := ""
		if st.state == .Stale {
			note = fmt.tprintf("  stale: %s changed", pipeline.stage_descriptors[st.changed_by].name)
		}
		fmt.printf("  %s %2d col %2d %-24s %-9s %8.1f ms  a=%d b=%d%s%s\n", mark, int(id), columns[id], st.name, state,
			st.duration_ms, st.count_a, st.count_b, "" if st.auto_run else "  (manual Run)", note)
	}
}

print_workspace_settings :: proc(w: ^pipeline.Workspace) {
	view := pipeline.workspace_view(w)
	fmt.printf("  settings for %s\n", pipeline.stage_descriptors[view.selected].name)
	settings := pipeline.workspace_settings(w, view.selected)
	if len(settings) == 0 {
		fmt.printf("    (none) this stage: %s\n", pipeline.stage_descriptors[view.selected].purpose)
		return
	}
	for sv in settings {
		unit := sv.descriptor.unit
		changed := fmt.tprintf("  (changed, default %s)", sv.default_value) if sv.value != sv.default_value else ""
		if sv.editable {
			fmt.printf("    %-28s %s %s%s\n", sv.descriptor.label, sv.value, unit, changed)
		} else {
			fmt.printf("    %-28s %s %s   (from %s, read-only)\n", sv.descriptor.label, sv.value, unit, sv.owner_name)
		}
	}
}
