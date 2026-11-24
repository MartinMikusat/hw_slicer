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
//   select <group>          group by index or name prefix
//   next | prev             stage navigation
//   set <key> <value>       edit a setting
//   run <stage>             start the stage and what it needs (index or name prefix)
//   runsel                  run the selected group
//   auto on|off             let setting changes start quick stale stages by themselves
//   cancel | wait           cancel the active run | wait for it to end
//   view | settings         print the stage list | the selected group's settings
//   check <group> <state>   print a mismatch and exit 1 when the group has another state
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
			if len(words) < 2 {fmt.println("  usage: select <group>"); continue}
			name := strings.join(words[1:], " ", context.temp_allocator)
			if group, found := find_group(name); found {
				pipeline.workspace_select(w, group)
			} else {fmt.printf("  no group '%s'\n", name)}
		case "next":
			fmt.printf("  %s\n", "moved" if pipeline.workspace_next(w) else "Next is disabled")
		case "prev":
			fmt.printf("  %s\n", "moved" if pipeline.workspace_previous(w) else "Previous is disabled")
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
			if len(words) < 3 {fmt.println("  usage: check <group> <state>"); continue}
			expected := words[len(words)-1]
			group, found := find_group(strings.join(words[1:len(words)-1], " ", context.temp_allocator))
			view := pipeline.workspace_view(w)
			if !found {fmt.printf("  no group in '%s'\n", line); failed = true; continue}
			state := fmt.tprintf("%v", view.groups[group].state)
			if strings.equal_fold(state, expected) {
				fmt.printf("  ok: %s is %s\n", view.groups[group].name, state)
			} else {
				fmt.printf("  MISMATCH: %s is %s, expected %s\n", view.groups[group].name, state, expected)
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

find_group :: proc(text: string) -> (pipeline.Stage_Group, bool) {
	if n, ok := strconv.parse_int(text); ok && n >= 0 && n < len(pipeline.Stage_Group) {
		return pipeline.Stage_Group(n), true
	}
	for group in pipeline.Stage_Group {
		if strings.has_prefix(strings.to_lower(pipeline.stage_group_names[group], context.temp_allocator), strings.to_lower(text, context.temp_allocator)) {
			return group, true
		}
	}
	return {}, false
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
	fmt.printf("  %s  Previous:%s Next:%s%s\n",
		"RUNNING" if view.running else "idle",
		"on" if view.can_previous else "off",
		"on" if view.can_next else "off",
		fmt.tprintf("  queued edits: %d", view.queued_edits) if view.queued_edits > 0 else "")
	for group in pipeline.Stage_Group {
		g := view.groups[group]
		mark := ">" if group == view.selected else " "
		note := ""
		if g.state == .Stale {
			note = fmt.tprintf("  stale: %s changed", pipeline.stage_descriptors[view.stages[g.stale_stage].changed_by].name)
		}
		fmt.printf("  %s %2d %-24s %v%s\n", mark, int(group), g.name, g.state, note)
		for id in pipeline.Stage_Id {
			if id not_in g.stages {continue}
			st := view.stages[id]
			fmt.printf("        - %-22s %-8v %8.1f ms  a=%d b=%d%s\n", st.name, st.state, st.duration_ms, st.count_a, st.count_b,
				"" if st.auto_run else "  (manual Run)")
		}
	}
}

print_workspace_settings :: proc(w: ^pipeline.Workspace) {
	view := pipeline.workspace_view(w)
	fmt.printf("  settings for %s\n", pipeline.stage_group_names[view.selected])
	settings := pipeline.workspace_settings(w, view.selected)
	if len(settings) == 0 {
		fmt.printf("    (none) this group configures: %s\n", stage_group_purpose(view.selected))
		return
	}
	for sv in settings {
		unit := sv.descriptor.unit
		if sv.editable {
			fmt.printf("    %-28s %s %s\n", sv.descriptor.label, sv.value, unit)
		} else {
			fmt.printf("    %-28s %s %s   (from %s, read-only)\n", sv.descriptor.label, sv.value, unit, sv.owner_name)
		}
	}
}

stage_group_purpose :: proc(group: pipeline.Stage_Group) -> string {
	b := strings.builder_make(context.temp_allocator)
	for id in pipeline.Stage_Id {
		if pipeline.stage_descriptors[id].group == group {
			strings.write_string(&b, pipeline.stage_descriptors[id].purpose)
			strings.write_string(&b, " ")
		}
	}
	return strings.to_string(b)
}
