package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import devlog "devlog:."

import design "./design"

app_profile_failure :: proc(message: string) -> bool {
	s := &app.design
	delete(s.profile_error)
	s.profile_error = strings.clone(message)
	app_set_status(message, true)
	return false
}

app_profile_apply_draft :: proc() -> bool {
	s := &app.design
	s.profile_dirty = true
	s.profile_valid = false
	s.profile_issue_xy = nil
	source := design.profile_source(&s.evaluated, s.profile_text, context.allocator)
	installed := false
	defer {if !installed {delete(source)}}
	if len(source) > DESIGN_SOURCE_LIMIT {return app_profile_failure("Design exceeds the file size limit")}
	evaluated, problem, valid := design.evaluate(source, design_printer(design_nozzle(s)))
	if !valid {
		defer design.error_destroy(&problem)
		s.profile_issue_xy = problem.position
		devlog.failed(devlog.global(), {feature = "design", operation = "edit_profile"},
			{reason = "invalid draft", code = i32(problem.line), severity = .Warning})
		return app_profile_failure(fmt.tprintf("Line %d · %s", problem.line, problem.message))
	}
	if !app_install_design_preview(evaluated, true) {
		return app_profile_failure("Could not display the edited toolpath")
	}
	delete(s.profile_text)
	s.profile_text = source
	installed = true
	delete(s.profile_error)
	s.profile_error = ""
	s.profile_valid = true
	s.profile_dirty = source != s.profile_disk || s.export_error != .None
	app_set_status("Profile preview updated")
	return true
}

app_profile_discard :: proc() -> bool {
	return app_load_design(app.design.path, true)
}

app_profile_save :: proc() -> (saved: bool) {
	s := &app.design
	if !s.profile_dirty || !s.profile_valid || s.profile_conflict || s.editor.dragging {return false}
	site := devlog.Site{feature = "design", operation = "save_profile"}
	devlog.started(devlog.global(), site)
	defer {
		if !saved {
			devlog.failed(devlog.global(), site, {reason = "profile save failed", detail = s.profile_error})
		}
	}
	if os.make_directory_all(DEV_GCODE_DIRECTORY) != nil && !os.is_dir(DEV_GCODE_DIRECTORY) {
		return app_profile_failure("Could not create the G-code directory")
	}
	stage_dir, dir_err := os.make_directory_temp(DEV_GCODE_DIRECTORY, ".profile-", context.temp_allocator)
	if dir_err != nil {return app_profile_failure("Could not stage the G-code")}
	defer os.remove(stage_dir)
	staged, export_err := design_export(s, directory = stage_dir)
	if export_err != .None {
		return app_profile_failure(fmt.tprintf("G-code · %s", design_export_error_text(export_err)))
	}
	defer delete(staged)
	defer os.remove(staged)
	destination, path_err := filepath.join({DEV_GCODE_DIRECTORY, filepath.base(staged)}, context.allocator)
	if path_err != nil {return app_profile_failure("Invalid G-code destination")}
	published := false
	defer {if !published {delete(destination)}}
	result := hw_slicer_replace_design(strings.clone_to_cstring(s.path, context.temp_allocator),
		raw_data(s.profile_disk), len(s.profile_disk), raw_data(s.profile_text), len(s.profile_text),
		strings.clone_to_cstring(staged, context.temp_allocator),
		strings.clone_to_cstring(destination, context.temp_allocator))
	switch result {
	case .Conflict:
		s.profile_conflict = true
		return app_profile_failure("The design changed on disk. Discard to load the external edit.")
	case .Failed:
		return app_profile_failure("Could not replace the design file")
	case .Saved, .Gcode_Failed:
	}
	delete(s.profile_disk)
	s.profile_disk = strings.clone(s.profile_text)
	s.profile_conflict = false
	if info, err := os.stat(s.path, context.temp_allocator); err == nil {s.modified = info.modification_time}
	if result == .Gcode_Failed {
		s.export_error = .Publish
		return app_profile_failure("Design saved. G-code publication failed. Retry Save.")
	}
	delete(s.export_path)
	s.export_path = destination
	published = true
	s.export_error = .None
	s.profile_dirty = false
	delete(s.profile_error)
	s.profile_error = ""
	devlog.succeeded(devlog.global(), site)
	app_set_status("Design and G-code saved")
	return true
}
