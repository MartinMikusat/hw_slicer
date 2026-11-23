package main

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import devlog "devlog:."

import design "./design"

DESIGN_NOZZLES :: [?]f64{0.25, 0.4, 0.6, 0.8}
DESIGN_DEFAULT_NOZZLE :: 1
DESIGN_FILAMENT_DIAMETER :: 1.75
DESIGN_RATES :: [?]f64{1, 10, 50, 200}
DESIGN_DEFAULT_RATE :: 1
DESIGN_POLL_SECONDS :: 0.5
DESIGN_SOURCE_LIMIT :: 1 << 20
DESIGN_EXTENSION :: ".hwsdesign"

// ponytail: dev-only absolute directory; the focused interface shows its newest design.
DEV_DESIGN_DIRECTORY :: "/Users/martin/projects/hw_slicer/resources/designs"

// Vertices of one bead: six side quads of a hexagonal cross-section (36 vertices, 12 triangles).
BEAD_SIDES :: 6
BEAD_VERTICES :: BEAD_SIDES*6
VISUAL_CHORD_TOLERANCE :: 0.05 // mm between a preview arc and its visual chord

Design_Bead :: struct {
	a, b:          Vec3, // top centre line
	width, height: f32,
	t0, t1:        f64, // print time in seconds
	arc:           design.Arc_Kind,
	arc_radius:    f32,
	junction:      i16, // index into evaluated.junctions, or -1
}

Design_Layer :: struct {
	z:          f64,
	t0, t1:     f64,
	first_bead: int,
	end_bead:   int,
}

Design_State :: struct {
	active:         bool,
	pinned:         bool, // opened explicitly; do not follow the newest design
	path:           string,
	modified:       time.Time,
	poll_tick:      time.Tick,
	nozzle_index:   int,
	editor:             Profile_Editor,
	profile_dirty:      bool,
	profile_valid:      bool,
	profile_conflict:   bool,
	profile_error:      string,
	profile_issue_xy:   Maybe([2]f64),
	profile_disk:       string,
	profile_text:       string,
	evaluated:         design.Design,
	toolpath:          design.Toolpath,
	beads:             [dynamic]Design_Bead,
	gpu_beads:         [dynamic]Gpu_Bead,
	arc_count:         int,
	layers:            [dynamic]Design_Layer,
	selected_layer:    int,
	selected_junction: int, // index into evaluated.junctions, or -1
	dirty:             bool, // pending in-memory rebuild coalesced once per frame
	scratch_toolpath:  design.Toolpath,
	scratch_beads:     [dynamic]Design_Bead,
	scratch_gpu_beads: [dynamic]Gpu_Bead,
	scratch_layers:    [dynamic]Design_Layer,
	clock:             f64, // simulated print time in seconds
	playing:        bool,
	rate_index:     int,
	play_tick:         time.Tick,
	export_path:       string,
	export_error:      Design_Export_Error,
}

design_state_init :: proc(s: ^Design_State) {
	s.nozzle_index = DESIGN_DEFAULT_NOZZLE
	s.rate_index = DESIGN_DEFAULT_RATE
	s.selected_junction = -1
}

design_state_clear :: proc(s: ^Design_State) {
	profile_editor_finish_drag(&s.editor)
	design.design_destroy(&s.evaluated)
	design.toolpath_destroy(&s.toolpath)
	design.toolpath_destroy(&s.scratch_toolpath)
	delete(s.beads)
	delete(s.gpu_beads)
	delete(s.layers)
	delete(s.scratch_beads)
	delete(s.scratch_gpu_beads)
	delete(s.scratch_layers)
	delete(s.path)
	delete(s.export_path)
	delete(s.profile_disk)
	delete(s.profile_text)
	delete(s.profile_error)
	nozzle, rate, pinned := s.nozzle_index, s.rate_index, s.pinned
	s^ = {}
	s.nozzle_index, s.rate_index, s.pinned = nozzle, rate, pinned
	s.selected_junction = -1
}

design_nozzle :: proc(s: ^Design_State) -> f64 {
	nozzles := DESIGN_NOZZLES
	return nozzles[s.nozzle_index]
}

design_rate :: proc(s: ^Design_State) -> f64 {
	rates := DESIGN_RATES
	return rates[s.rate_index]
}

design_corner_label :: proc(junction: design.Junction) -> string {
	if end, split := junction.corner_end.?; split {
		switch end {
		case .South: return "South"
		case .North: return "North"
		}
	}
	return "Corner"
}

design_duration :: proc(s: ^Design_State) -> f64 {
	return s.toolpath.duration
}

// Reads, evaluates and generates `path`; on success replaces the shown model. A failed reload
// keeps the previous design.
app_load_design :: proc(path: string, keep_time := false) -> bool {
	site := devlog.Site{feature = "design", operation = "load"}
	devlog.started(devlog.global(), site, {scope = "design", stage = "read"})
	info, stat_error := os.stat(path, context.temp_allocator)
	if stat_error == nil && info.size > DESIGN_SOURCE_LIMIT {
		app_set_status("DESIGN TOO LARGE", true)
		return false
	}
	source, read_error := os.read_entire_file(path, context.allocator)
	defer delete(source)
	if stat_error != nil || read_error != nil {
		devlog.failed(devlog.global(), site, {reason = "design read failed", detail = filepath.base(path), severity = .Error}, {scope = "design", stage = "read"})
		app_set_status("DESIGN READ FAILED", true)
		return false
	}
	if len(source) > DESIGN_SOURCE_LIMIT {
		devlog.failed(devlog.global(), site, {reason = "design source too large", severity = .Error}, {scope = "design", stage = "read"})
		app_set_status("DESIGN TOO LARGE", true)
		return false
	}
	printer := design_printer(design_nozzle(&app.design))
	evaluated, evaluate_error, ok := design.evaluate(string(source), printer)
	if !ok {
		defer design.error_destroy(&evaluate_error)
		devlog.failed(devlog.global(), site, {reason = "design evaluation failed", code = i32(evaluate_error.line), severity = .Warning}, {scope = "design", stage = "evaluate"})
		app_set_status(fmt.tprintf("DESIGN LINE %d: %s", evaluate_error.line, evaluate_error.message), true)
		// Track the file anyway, so the next edit is picked up.
		if !app.design.active && app.design.path != path {
			delete(app.design.path)
			app.design.path = strings.clone(path)
		}
		if app.design.path == path {app.design.modified = info.modification_time}
		return false
	}
	defer design.design_destroy(&evaluated)
	if !app_install_design_preview(&evaluated, keep_time) {return false}
	s := &app.design
	path_copy := strings.clone(path)
	delete(s.path)
	s.path = path_copy
	s.modified = info.modification_time
	profile_editor_finish_drag(&s.editor)
	s.editor = {}
	delete(s.profile_disk)
	delete(s.profile_text)
	delete(s.profile_error)
	s.profile_disk, s.profile_text, s.profile_error = "", "", ""
	for object in s.evaluated.objects {
		if object.profile != nil {
			s.profile_disk = strings.clone(string(source))
			s.profile_text = strings.clone(string(source))
			break
		}
	}
	s.profile_dirty, s.profile_valid, s.profile_conflict = false, true, false
	s.profile_issue_xy = nil
	delete(app.model_name)
	app.model_name = strings.clone(filepath.base(s.path))
	devlog.succeeded(devlog.global(), site, {scope = "design", stage = "loaded"}, {rows = i64(len(s.beads))})
	_ = app_export_current_design()
	if !keep_time {app_frame_camera()}
	return true
}

app_install_design_preview :: proc(candidate: ^design.Design, keep_time: bool, previous: ^design.Design = nil) -> bool {
	t_gen0 := time.tick_now()
	toolpath := design.generate(candidate)
	t_gen1 := time.tick_now()
	beads := make([dynamic]Design_Bead, 0, len(toolpath.moves))
	gpu_beads := make([dynamic]Gpu_Bead, 0, len(toolpath.moves))
	layers := make([dynamic]Design_Layer, 0, toolpath.layers)
	arc_count, bounds := design_beads(&toolpath, &beads, &gpu_beads, &layers)
	t_beads1 := time.tick_now()
	if !renderer_set_beads(&app.renderer, gpu_beads[:]) {
		delete(beads)
		delete(gpu_beads)
		delete(layers)
		design.toolpath_destroy(&toolpath)
		devlog.failed(devlog.global(), devlog.Site{feature = "design", operation = "preview"}, {reason = "renderer bead upload failed", severity = .Critical}, {scope = "design", stage = "upload"})
		app_set_status("DESIGN FAILED: METAL BUFFER", true)
		return false
	}
	t_up1 := time.tick_now()
	if bench_frames_target > 0 {
		fmt.printf("TRACE: generate=%.2f ms  beads=%.2f ms  upload=%.2f ms  total=%.2f ms\n",
			time.duration_seconds(time.tick_diff(t_gen0, t_gen1))*1000.0,
			time.duration_seconds(time.tick_diff(t_gen1, t_beads1))*1000.0,
			time.duration_seconds(time.tick_diff(t_beads1, t_up1))*1000.0,
			time.duration_seconds(time.tick_diff(t_gen0, t_up1))*1000.0)
	}
	fraction := 1.0
	if keep_time && app.design.active && design_duration(&app.design) > 0 {
		fraction = app.design.clock/design_duration(&app.design)
	}
	playing := keep_time && app.design.playing
	if previous != nil {
		previous^ = app.design.evaluated
	} else {
		design.design_destroy(&app.design.evaluated)
	}
	design.toolpath_destroy(&app.design.toolpath)
	delete(app.design.beads)
	delete(app.design.gpu_beads)
	delete(app.design.layers)
	app.design.selected_junction = -1
	app.design.dirty = false
	app.design.active = true
	app.design.evaluated = candidate^
	candidate^ = {}
	app.design.toolpath = toolpath
	app.design.beads = beads
	app.design.gpu_beads = gpu_beads
	app.design.arc_count = arc_count
	app.design.layers = layers
	app.design.clock = fraction*toolpath.duration
	design_sync_layer(&app.design)
	app.design.playing = playing
	app.design.play_tick = time.tick_now()

	mesh_destroy(&app.mesh)
	app.mesh = Mesh{bounds = bounds, triangle_count = u32(len(beads)*BEAD_VERTICES/3)}
	app.placement = {transform = mat4_identity(), bounds = bounds}
	app.ui.lay_on_face = false
	app.face_hover = -1
	app.face_pressed = -1
	app.ui.selected_model = 3
	app.section_dirty = true
	app.needs_redraw = true
	return true
}

app_export_current_design :: proc() -> bool {
	export_site := devlog.Site{feature = "design", operation = "export"}
	delete(app.design.export_path)
	app.design.export_path, app.design.export_error = design_export(&app.design)
	if app.design.export_error == .None {
		devlog.succeeded(devlog.global(), export_site, {scope = "design", stage = "gcode"}, {rows = i64(len(app.design.toolpath.moves))})
		app_set_status(fmt.tprintf("DESIGN: %d LAYERS, G-CODE WRITTEN", app.design.toolpath.layers))
	} else {
		devlog.failed(devlog.global(), export_site, {reason = "design export failed", detail = design_export_error_text(app.design.export_error), code = i32(app.design.export_error), severity = .Error}, {scope = "design", stage = "gcode"})
		app_set_status(fmt.tprintf("G-CODE FAILED: %s", design_export_error_text(app.design.export_error)), true)
	}
	return app.design.export_error == .None
}

// Re-slices the affected layer span of the currently evaluated in-memory design
// (after interactive bevel/fillet/corner edits), splicing into the existing bead buffers
// and uploading to the next ping-pong Metal buffer.
app_rebuild_design_mesh :: proc() -> bool {
	s := &app.design
	if !s.active {return false}
	layer_idx, _, _, in_layer := design_layer_state(s)
	n_layers := len(s.layers)

	// Fast path: splice only the layers touched by the edited junction.
	if s.selected_junction >= 0 && s.selected_junction < len(s.evaluated.junctions) && n_layers > 0 {
		j := s.evaluated.junctions[s.selected_junction]
		lo_l, hi_l := design.object_layer_span(&s.evaluated, s.evaluated.objects[j.lower_index])
		lo_u, hi_u := design.object_layer_span(&s.evaluated, s.evaluated.objects[j.upper_index])
		lo := clamp(min(lo_l, lo_u), 0, n_layers)
		hi := clamp(max(hi_l, hi_u), lo, n_layers)
		if lo < hi {
			design.generate_layers(&s.evaluated, lo, hi, &s.scratch_toolpath)
			clear(&s.scratch_beads)
			clear(&s.scratch_gpu_beads)
			clear(&s.scratch_layers)
			_, _ = design_beads(&s.scratch_toolpath, &s.scratch_beads, &s.scratch_gpu_beads, &s.scratch_layers)
			if len(s.scratch_layers) == hi-lo {
				old_start := s.layers[lo].first_bead
				old_end := s.layers[hi-1].end_bead
				old_t0 := s.layers[lo].t0
				old_t1 := s.layers[hi-1].t1
				old_count := old_end-old_start
				new_count := len(s.scratch_beads)
				delta := new_count-old_count
				suffix_count := len(s.beads)-old_end
				new_total := len(s.beads)+delta

				// Shift new beads' timestamps to start at `old_t0`.
				for &b in s.scratch_beads {
					b.t0 += old_t0
					b.t1 += old_t0
				}
				new_t1 := s.scratch_layers[len(s.scratch_layers)-1].t1+old_t0
				dt_delta := new_t1-old_t1

				if delta > 0 {
					resize(&s.beads, new_total)
					resize(&s.gpu_beads, new_total)
				}
				if delta != 0 && suffix_count > 0 {
					mem.copy(&s.beads[old_start+new_count], &s.beads[old_end], suffix_count*size_of(Design_Bead))
					mem.copy(&s.gpu_beads[old_start+new_count], &s.gpu_beads[old_end], suffix_count*size_of(Gpu_Bead))
				}
				if new_count > 0 {
					mem.copy(&s.beads[old_start], &s.scratch_beads[0], new_count*size_of(Design_Bead))
					mem.copy(&s.gpu_beads[old_start], &s.scratch_gpu_beads[0], new_count*size_of(Gpu_Bead))
				}
				if delta < 0 {
					resize(&s.beads, new_total)
					resize(&s.gpu_beads, new_total)
				}
				for k in 0..<len(s.scratch_layers) {
					ml := s.scratch_layers[k]
					s.layers[lo+k] = {
						z          = ml.z,
						t0         = ml.t0+old_t0,
						t1         = ml.t1+old_t0,
						first_bead = ml.first_bead+old_start,
						end_bead   = ml.end_bead+old_start,
					}
				}
				if delta != 0 || abs(dt_delta) > 1e-9 {
					for L in hi..<n_layers {
						s.layers[L].first_bead += delta
						s.layers[L].end_bead += delta
						s.layers[L].t0 += dt_delta
						s.layers[L].t1 += dt_delta
					}
					if abs(dt_delta) > 1e-9 && suffix_count > 0 {
						for i in old_start+new_count..<new_total {
							s.beads[i].t0 += dt_delta
							s.beads[i].t1 += dt_delta
						}
					}
					s.toolpath.duration += dt_delta
				}
				if !renderer_set_beads(&app.renderer, s.gpu_beads[:]) {return false}
				design_set_layer(s, layer_idx, in_layer)
				app.mesh.triangle_count = u32(len(s.beads)*BEAD_VERTICES/3)
				app.needs_redraw = true
				return true
			}
		}
	}

	toolpath := design.generate(&s.evaluated)
	clear(&s.beads)
	clear(&s.gpu_beads)
	clear(&s.layers)
	arc_count, bounds := design_beads(&toolpath, &s.beads, &s.gpu_beads, &s.layers)
	if !renderer_set_beads(&app.renderer, s.gpu_beads[:]) {
		design.toolpath_destroy(&toolpath)
		return false
	}
	design.toolpath_destroy(&s.toolpath)
	s.toolpath = toolpath
	s.arc_count = arc_count
	design_set_layer(s, layer_idx, in_layer)
	app.mesh.bounds = bounds
	app.mesh.triangle_count = u32(len(s.beads)*BEAD_VERTICES/3)
	app.placement = {transform = mat4_identity(), bounds = bounds}
	app.section_dirty = true
	app.needs_redraw = true
	return true
}

// Selection highlight is evaluated in `bead_vertex` via uniform; no CPU rebuild needed.
app_refresh_design_selection_mesh :: proc() {
	app.needs_redraw = true
}

// Raycasts the camera ray through `(px, py)` against visible beads; returns the hit bead's
// junction index (>= 0) or -1 if no junction bead was hit.
design_pick_junction :: proc(s: ^Design_State, camera: Camera, viewport: UI_Rect, px, py: f64) -> int {
	if !s.active || len(s.beads) == 0 || viewport.w <= 0 || viewport.h <= 0 {return -1}
	eye := app_camera_eye(camera)
	forward := vec3_normalize(vec3_sub(camera.target, eye))
	right := vec3_normalize(vec3_cross(forward, {0, 0, 1}))
	up := vec3_cross(right, forward)
	h := f32(math.tan(0.78/2.0))
	x := f32(2*(px-viewport.x)/viewport.w-1)*h*f32(viewport.w/viewport.h)
	y := f32(1-2*(py-viewport.y)/viewport.h)*h
	dir := vec3_normalize(vec3_add(forward, vec3_add(vec3_mul(right, x), vec3_mul(up, y))))
	inv_x := f32(1.0)/dir.x if abs(dir.x) > 1e-8 else f32(1e30)
	inv_y := f32(1.0)/dir.y if abs(dir.y) > 1e-8 else f32(1e30)
	inv_z := f32(1.0)/dir.z if abs(dir.z) > 1e-8 else f32(1e30)

	vis := design_visible(s)
	count := min(len(s.beads), vis.finished_vertices/BEAD_VERTICES)
	best_t := max(f32)
	best_junction := -1
	for i in 0..<count {
		b := s.beads[i]
		r := max(b.width, b.height)*0.65
		min_x := min(b.a.x, b.b.x)-r
		max_x := max(b.a.x, b.b.x)+r
		min_y := min(b.a.y, b.b.y)-r
		max_y := max(b.a.y, b.b.y)+r
		min_z := min(b.a.z, b.b.z)-b.height
		max_z := max(b.a.z, b.b.z)+r*0.35

		tx1 := (min_x-eye.x)*inv_x
		tx2 := (max_x-eye.x)*inv_x
		tmin := min(tx1, tx2)
		tmax := max(tx1, tx2)

		ty1 := (min_y-eye.y)*inv_y
		ty2 := (max_y-eye.y)*inv_y
		tmin = max(tmin, min(ty1, ty2))
		tmax = min(tmax, max(ty1, ty2))

		tz1 := (min_z-eye.z)*inv_z
		tz2 := (max_z-eye.z)*inv_z
		tmin = max(tmin, min(tz1, tz2))
		tmax = min(tmax, max(tz1, tz2))

		if tmax >= max(tmin, f32(0)) && tmin < best_t {
			best_t = tmin
			best_junction = int(b.junction)
		}
	}
	return best_junction
}

// The most recently modified design in DEV_DESIGN_DIRECTORY, allocated with the temp allocator.
design_newest :: proc() -> (path: string, ok: bool) {
	entries, error := os.read_all_directory_by_path(DEV_DESIGN_DIRECTORY, context.temp_allocator)
	if error != nil {return "", false}
	newest: time.Time
	for entry in entries {
		if entry.type != .Regular || !strings.equal_fold(filepath.ext(entry.name), DESIGN_EXTENSION) {continue}
		if !ok || time.diff(newest, entry.modification_time) > 0 {
			path, newest, ok = entry.fullpath, entry.modification_time, true
		}
	}
	return
}

// Follows the newest design unless one was opened explicitly, and reloads the shown design when
// its file changed. Runs at most every DESIGN_POLL_SECONDS.
app_poll_design :: proc() {
	if app.design.poll_tick != {} && time.duration_seconds(time.tick_since(app.design.poll_tick)) < DESIGN_POLL_SECONDS {return}
	app.design.poll_tick = time.tick_now()
	s := &app.design
	if s.editor.dragging {return}
	if s.profile_dirty {
		info, err := os.stat(s.path, context.temp_allocator)
		if err == nil && info.modification_time == s.modified {return}
		if err == nil {s.modified = info.modification_time}
		matches := false
		if err == nil && info.size == i64(len(s.profile_disk)) {
			disk, read_error := os.read_entire_file(s.path, context.allocator)
			matches = read_error == nil && string(disk) == s.profile_disk
			delete(disk)
		}
		if !matches && !s.profile_conflict {
			s.profile_conflict = true
			app_set_status("The design changed on disk. Discard to load the external edit.", true)
		} else if matches && s.profile_conflict {
			s.profile_conflict = false
			app_set_status("The file on disk matches the original design")
		}
		return
	}
	if !app.design.pinned {
		if newest, found := design_newest(); found && newest != app.design.path {
			_ = app_load_design(newest)
			return
		}
	}
	if app.design.path == "" {return}
	info, error := os.stat(app.design.path, context.temp_allocator)
	if error != nil || info.modification_time == app.design.modified {return}
	path := strings.clone(app.design.path, context.temp_allocator)
	_ = app_load_design(path, true)
}

// Advances a playing simulation; true when the frame changed.
app_animate_design :: proc() -> bool {
	s := &app.design
	if !s.active || !s.playing {return false}
	now := time.tick_now()
	dt := time.duration_seconds(time.tick_diff(s.play_tick, now))
	s.play_tick = now
	s.clock += dt*design_rate(s)
	if s.clock >= design_duration(s) {
		s.clock = design_duration(s)
		s.playing = false
	}
	design_sync_layer(s)
	return true
}

design_toggle_play :: proc(s: ^Design_State) {
	if !s.active {return}
	s.playing = !s.playing
	if s.playing && s.clock >= design_duration(s) {
		s.clock = 0
		design_sync_layer(s)
	}
	s.play_tick = time.tick_now()
}

design_set_time_fraction :: proc(s: ^Design_State, fraction: f64) {
	s.clock = clamp(fraction, 0, 1)*design_duration(s)
	design_sync_layer(s)
}

design_sync_layer :: proc(s: ^Design_State) {
	n := len(s.layers)
	if n == 0 {
		s.selected_layer = 0
		return
	}
	if s.clock <= s.layers[0].t0 {
		s.selected_layer = 0
		return
	}
	if s.clock >= s.layers[n-1].t1 {
		s.selected_layer = n-1
		return
	}
	low, high := 0, n-1
	for low < high {
		mid := (low+high)/2
		if s.layers[mid].t1 < s.clock {low = mid+1} else {high = mid}
	}
	s.selected_layer = low
}

design_layer_state :: proc(s: ^Design_State) -> (layer_idx, layer_count: int, z, in_layer: f64) {
	layer_count = len(s.layers)
	if layer_count == 0 {return 0, 0, 0, 0}
	layer_idx = clamp(s.selected_layer, 0, layer_count-1)
	layer := s.layers[layer_idx]
	z = layer.z
	span := layer.t1-layer.t0
	if span <= 1e-9 {
		in_layer = 1.0 if s.clock >= layer.t0 else 0.0
	} else {
		in_layer = clamp((s.clock-layer.t0)/span, 0, 1)
	}
	return
}

design_set_layer :: proc(s: ^Design_State, layer_idx: int, in_layer := 1.0) {
	if len(s.layers) == 0 {return}
	idx := clamp(layer_idx, 0, len(s.layers)-1)
	s.selected_layer = idx
	layer := s.layers[idx]
	s.clock = layer.t0+(layer.t1-layer.t0)*clamp(in_layer, 0, 1)
}

design_set_in_layer :: proc(s: ^Design_State, fraction: f64) {
	if len(s.layers) == 0 {return}
	idx := clamp(s.selected_layer, 0, len(s.layers)-1)
	s.selected_layer = idx
	layer := s.layers[idx]
	s.clock = layer.t0+(layer.t1-layer.t0)*clamp(fraction, 0, 1)
}

// Steps the in-layer progress by `delta` extruded moves (single step = 1 move/bead).
design_step_in_layer :: proc(s: ^Design_State, delta: int) {
	if len(s.layers) == 0 || delta == 0 {return}
	idx := clamp(s.selected_layer, 0, len(s.layers)-1)
	s.selected_layer = idx
	layer := s.layers[idx]
	count := layer.end_bead-layer.first_bead
	if count <= 0 {return}
	// Find how many beads in this layer have finished at `s.clock`.
	completed := 0
	if s.clock >= layer.t1-1e-9 {
		completed = count
	} else if s.clock > layer.t0+1e-9 {
		low, high := layer.first_bead, layer.end_bead
		for low < high {
			mid := (low+high)/2
			if s.beads[mid].t1 <= s.clock+1e-9 {low = mid+1} else {high = mid}
		}
		completed = low-layer.first_bead
	}
	next_completed := clamp(completed+delta, 0, count)
	if next_completed == 0 {
		s.clock = layer.t0
	} else {
		s.clock = s.beads[layer.first_bead+next_completed-1].t1
	}
}

// Extruding moves become beads, compact Gpu_Beads, per-layer spans, and model bounds.
design_beads :: proc(
	t: ^design.Toolpath,
	beads: ^[dynamic]Design_Bead,
	gpu_beads: ^[dynamic]Gpu_Bead,
	layers: ^[dynamic]Design_Layer,
) -> (arc_count: int, bounds: Mesh_Bounds) {
	bounds = {{max(f32), max(f32), max(f32)}, {-max(f32), -max(f32), -max(f32)}}
	append_bead :: proc(
		beads: ^[dynamic]Design_Bead,
		gpu_beads: ^[dynamic]Gpu_Bead,
		layers: ^[dynamic]Design_Layer,
		bounds: ^Mesh_Bounds,
		a, b: [3]f64,
		w, h, t0, t1: f64,
		arc: design.Arc_Kind,
		arc_radius: f64,
		junction: i16,
	) {
		bead_idx := len(beads)
		af := Vec3{f32(a.x), f32(a.y), f32(a.z)}
		bf := Vec3{f32(b.x), f32(b.y), f32(b.z)}
		wf := f32(w)
		hf := f32(h)
		append(beads, Design_Bead{
			a = af,
			b = bf,
			width = wf,
			height = hf,
			t0 = t0,
			t1 = t1,
			arc = arc,
			arc_radius = f32(arc_radius),
			junction = junction,
		})
		append(gpu_beads, Gpu_Bead{
			a    = {af.x, af.y, af.z, wf},
			b    = {bf.x, bf.y, bf.z, hf},
			meta = {1.0, 1.0 if arc != .None else 0.0, f32(junction), 0.0},
		})
		half := wf*0.5
		bounds.minimum = {
			min(bounds.minimum.x, min(af.x, bf.x)-half),
			min(bounds.minimum.y, min(af.y, bf.y)-half),
			min(bounds.minimum.z, min(af.z, bf.z)-hf),
		}
		bounds.maximum = {
			max(bounds.maximum.x, max(af.x, bf.x)+half),
			max(bounds.maximum.y, max(af.y, bf.y)+half),
			max(bounds.maximum.z, max(af.z, bf.z)),
		}
		if len(layers) == 0 || abs(b.z-layers[len(layers)-1].z) > 1e-6 {
			append(layers, Design_Layer{
				z          = b.z,
				t0         = t0,
				t1         = t1,
				first_bead = bead_idx,
				end_bead   = bead_idx+1,
			})
		} else {
			last := &layers[len(layers)-1]
			last.t1 = t1
			last.end_bead = bead_idx+1
		}
	}
	position := t.start
	clock := 0.0
	for move in t.moves {
		if move.extrude && move.arc != .None {
			arc_count += 1
			radius, sweep := design.arc_geometry({position.x, position.y}, {move.to.x, move.to.y}, move.center, move.arc)
			distance := radius*abs(sweep)
			duration := distance/move.speed
			full_segs := design.MAX_CIRCLE_SEGMENTS
			if radius > VISUAL_CHORD_TOLERANCE {
				full_segs = int(math.ceil(math.PI/math.acos(1-VISUAL_CHORD_TOLERANCE/radius)))
			}
			full_segs = clamp(full_segs, design.MIN_CIRCLE_SEGMENTS, design.MAX_CIRCLE_SEGMENTS)
			segs := max(2, int(math.ceil(f64(full_segs)*abs(sweep)/(2*math.PI))))
			rx := position.x-move.center.x
			ry := position.y-move.center.y
			d_ang := sweep/f64(segs)
			dc := math.cos(d_ang)
			ds := math.sin(d_ang)
			prev := position
			seg_dt := duration/f64(segs)
			for i in 1..=segs {
				next_pt := move.to
				if i < segs {
					next_rx := rx*dc-ry*ds
					ry = rx*ds+ry*dc
					rx = next_rx
					next_pt = {move.center.x+rx, move.center.y+ry, move.to.z}
				}
				t0 := clock+f64(i-1)*seg_dt
				t1 := clock+f64(i)*seg_dt
				append_bead(beads, gpu_beads, layers, &bounds, prev, next_pt, move.width, move.height, t0, t1, move.arc, radius, move.junction)
				prev = next_pt
			}
			clock += duration
			position = move.to
			continue
		}
		delta := move.to-position
		duration := math.sqrt(delta.x*delta.x+delta.y*delta.y+delta.z*delta.z)/move.speed
		if move.extrude {
			append_bead(beads, gpu_beads, layers, &bounds, position, move.to, move.width, move.height, clock, clock+duration, .None, 0, move.junction)
		}
		clock += duration
		position = move.to
	}
	if len(beads) == 0 {bounds = {}}
	return
}

Design_Visual :: struct {
	finished_vertices:    int,
	partial:              []Mesh_Vertex,
	is_design:            bool,
	finished_beads:       int,
	has_partial:          bool,
	partial_bead:         Gpu_Bead,
	highlight_start:      int, // vertex index where current layer begins; -1 when using default color
	highlight_start_bead: int, // bead index where current layer begins; -1 when using default color
	selected_junction:    int, // selected bevel/fillet/corner junction index, or -1
	marker_active:        bool,
	marker_pos:           Vec3,
	marker_radius:        f32,
}

design_current_move_info :: proc(s: ^Design_State) -> (arc: design.Arc_Kind, radius: f32) {
	if !s.active || len(s.beads) == 0 {return .None, 0}
	low, high := 0, len(s.beads)
	for low < high {
		middle := (low+high)/2
		if s.beads[middle].t1 <= s.clock {low = middle+1} else {high = middle}
	}
	idx := low
	if idx >= len(s.beads) {idx = len(s.beads)-1}
	if low < len(s.beads) && s.beads[low].t0 < s.clock {
		idx = low
	} else if low > 0 {
		idx = low-1
	}
	return s.beads[idx].arc, s.beads[idx].arc_radius
}

// The vertices to draw at the current time: a prefix of finished beads, the growing bead,
// contiguous G1/arc vertex runs, optional current-layer highlight range, and nozzle-tip marker sphere.
design_visible :: proc(s: ^Design_State) -> (v: Design_Visual) {
	v.highlight_start = -1
	v.highlight_start_bead = -1
	v.selected_junction = s.selected_junction
	if !s.active || len(s.beads) == 0 {return}
	v.is_design = true
	low, high := 0, len(s.beads)
	for low < high {
		middle := (low+high)/2
		if s.beads[middle].t1 <= s.clock {low = middle+1} else {high = middle}
	}
	v.finished_beads = low
	v.finished_vertices = low*BEAD_VERTICES
	tip := s.beads[0].a
	if low > 0 {tip = s.beads[low-1].b}
	if low < len(s.beads) && s.beads[low].t0 < s.clock {
		bead := s.beads[low]
		fraction := f32((s.clock-bead.t0)/max(bead.t1-bead.t0, 0.000001))
		v.has_partial = true
		v.partial_bead = {
			a    = {bead.a.x, bead.a.y, bead.a.z, bead.width},
			b    = {bead.b.x, bead.b.y, bead.b.z, bead.height},
			meta = {fraction, 1.0 if bead.arc != .None else 0.0, f32(bead.junction), 0.0},
		}
		tip = vec3_add(bead.a, vec3_mul(vec3_sub(bead.b, bead.a), fraction))
	}
	layer_idx, layer_count, _, in_layer := design_layer_state(s)
	if layer_count > 0 {
		layer := s.layers[layer_idx]
		if in_layer < 1.0-1e-6 {
			v.highlight_start_bead = min(layer.first_bead, low)
			v.highlight_start = v.highlight_start_bead*BEAD_VERTICES
			if in_layer <= 1e-6 && layer.first_bead < len(s.beads) {
				tip = s.beads[layer.first_bead].a
			}
		}
		if in_layer < 1.0-1e-6 || layer_idx < layer_count-1 {
			v.marker_active = true
			v.marker_pos = tip
			v.marker_radius = max(f32(1.1), f32(s.evaluated.line_width*2.5))
		}
	}
	return
}

design_time_text :: proc(seconds: f64) -> string {
	total := int(math.round(seconds))
	if total >= 3600 {return fmt.tprintf("%d:%02d:%02d", total/3600, total/60%60, total%60)}
	return fmt.tprintf("%d:%02d", total/60, total%60)
}
