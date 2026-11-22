package main

import "core:fmt"
import "core:math"
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
	evaluated:      design.Design,
	toolpath:       design.Toolpath,
	beads:          [dynamic]Design_Bead,
	arc_count:      int,
	layers:            [dynamic]Design_Layer,
	selected_layer:    int,
	selected_junction: int, // index into evaluated.junctions, or -1
	clock:             f64, // simulated print time in seconds
	playing:        bool,
	rate_index:     int,
	play_tick:      time.Tick,
	partial:        [BEAD_VERTICES]Mesh_Vertex,
	export_path:    string,
	export_error:   Design_Export_Error,
}

design_state_init :: proc(s: ^Design_State) {
	s.nozzle_index = DESIGN_DEFAULT_NOZZLE
	s.rate_index = DESIGN_DEFAULT_RATE
	s.selected_junction = -1
}

design_state_clear :: proc(s: ^Design_State) {
	design.design_destroy(&s.evaluated)
	design.toolpath_destroy(&s.toolpath)
	delete(s.beads)
	delete(s.layers)
	delete(s.path)
	delete(s.export_path)
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

design_duration :: proc(s: ^Design_State) -> f64 {
	return s.toolpath.duration
}

// Reads, evaluates and generates `path`; on success replaces the shown model. A failed reload
// keeps the previous design.
app_load_design :: proc(path: string, keep_time := false) -> bool {
	site := devlog.Site{feature = "design", operation = "load"}
	devlog.started(devlog.global(), site, {scope = "design", stage = "read"})
	info, stat_error := os.stat(path, context.temp_allocator)
	source, read_error := os.read_entire_file(path, context.allocator)
	if stat_error != nil || read_error != nil {
		devlog.failed(devlog.global(), site, {reason = "design read failed", detail = filepath.base(path), severity = .Error}, {scope = "design", stage = "read"})
		app_set_status("DESIGN READ FAILED", true)
		return false
	}
	defer delete(source)
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
		if app.design.path != path {
			delete(app.design.path)
			app.design.path = strings.clone(path)
		}
		app.design.modified = info.modification_time
		return false
	}
	toolpath := design.generate(&evaluated)
	beads := make([dynamic]Design_Bead)
	layers := make([dynamic]Design_Layer)
	arc_count := design_beads(&toolpath, &beads, &layers)
	mesh := design_bead_mesh(beads[:], -1)
	if !renderer_set_mesh(&app.renderer, &mesh) {
		mesh_destroy(&mesh)
		delete(beads)
		delete(layers)
		design.toolpath_destroy(&toolpath)
		design.design_destroy(&evaluated)
		devlog.failed(devlog.global(), site, {reason = "renderer mesh upload failed", severity = .Critical}, {scope = "design", stage = "upload"})
		app_set_status("DESIGN FAILED: METAL BUFFER", true)
		return false
	}
	fraction := 1.0
	if keep_time && app.design.active && design_duration(&app.design) > 0 {
		fraction = app.design.clock/design_duration(&app.design)
	}
	playing := keep_time && app.design.playing
	path_copy := strings.clone(path)
	design_state_clear(&app.design)
	app.design.active = true
	app.design.path = path_copy
	app.design.modified = info.modification_time
	app.design.evaluated = evaluated
	app.design.toolpath = toolpath
	app.design.beads = beads
	app.design.arc_count = arc_count
	app.design.layers = layers
	app.design.clock = fraction*toolpath.duration
	design_sync_layer(&app.design)
	app.design.playing = playing
	app.design.play_tick = time.tick_now()

	mesh_destroy(&app.mesh)
	app.mesh = mesh
	app.placement = {transform = mat4_identity(), bounds = mesh.bounds}
	app.ui.lay_on_face = false
	app.face_hover = -1
	app.face_pressed = -1
	app.ui.selected_model = 3
	app.section_dirty = true
	delete(app.model_name)
	app.model_name = strings.clone(filepath.base(path))
	devlog.succeeded(devlog.global(), site, {scope = "design", stage = "loaded"}, {rows = i64(len(beads))})
	export_site := devlog.Site{feature = "design", operation = "export"}
	app.design.export_path, app.design.export_error = design_export(&app.design)
	if app.design.export_error == .None {
		devlog.succeeded(devlog.global(), export_site, {scope = "design", stage = "gcode"}, {rows = i64(len(toolpath.moves))})
		app_set_status(fmt.tprintf("DESIGN: %d LAYERS, G-CODE WRITTEN", toolpath.layers))
	} else {
		devlog.failed(devlog.global(), export_site, {reason = "design export failed", detail = design_export_error_text(app.design.export_error), code = i32(app.design.export_error), severity = .Error}, {scope = "design", stage = "gcode"})
		app_set_status(fmt.tprintf("G-CODE FAILED: %s", design_export_error_text(app.design.export_error)), true)
	}
	if !keep_time {app_frame_camera()}
	return true
}

// Re-slices the currently evaluated in-memory design (after interactive bevel/fillet edits),
// preserving camera, playback layer/time, and selected junction.
app_rebuild_design_mesh :: proc() -> bool {
	s := &app.design
	if !s.active {return false}
	layer_idx, _, _, in_layer := design_layer_state(s)
	toolpath := design.generate(&s.evaluated)
	beads := make([dynamic]Design_Bead)
	layers := make([dynamic]Design_Layer)
	arc_count := design_beads(&toolpath, &beads, &layers)
	mesh := design_bead_mesh(beads[:], s.selected_junction)
	if !renderer_set_mesh(&app.renderer, &mesh) {
		mesh_destroy(&mesh)
		delete(beads)
		delete(layers)
		design.toolpath_destroy(&toolpath)
		return false
	}
	design.toolpath_destroy(&s.toolpath)
	delete(s.beads)
	delete(s.layers)
	s.toolpath = toolpath
	s.beads = beads
	s.arc_count = arc_count
	s.layers = layers
	design_set_layer(s, layer_idx, in_layer)
	mesh_destroy(&app.mesh)
	app.mesh = mesh
	app.placement = {transform = mat4_identity(), bounds = mesh.bounds}
	app.section_dirty = true
	app.needs_redraw = true
	return true
}

// Updates bead highlight colors in the GPU mesh without regenerating toolpaths.
app_refresh_design_selection_mesh :: proc() {
	s := &app.design
	if !s.active || len(s.beads) == 0 {return}
	mesh := design_bead_mesh(s.beads[:], s.selected_junction)
	if renderer_set_mesh(&app.renderer, &mesh) {
		mesh_destroy(&app.mesh)
		app.mesh = mesh
	} else {
		mesh_destroy(&mesh)
	}
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

// Extruding moves become beads with their print-time interval and per-layer spans.
design_beads :: proc(
	t: ^design.Toolpath,
	beads: ^[dynamic]Design_Bead,
	layers: ^[dynamic]Design_Layer,
) -> (arc_count: int) {
	append_bead :: proc(
		beads: ^[dynamic]Design_Bead,
		layers: ^[dynamic]Design_Layer,
		a, b: [3]f64,
		w, h, t0, t1: f64,
		arc: design.Arc_Kind,
		arc_radius: f64,
		junction: i16,
	) {
		bead_idx := len(beads)
		append(beads, Design_Bead{
			a = {f32(a.x), f32(a.y), f32(a.z)},
			b = {f32(b.x), f32(b.y), f32(b.z)},
			width = f32(w),
			height = f32(h),
			t0 = t0,
			t1 = t1,
			arc = arc,
			arc_radius = f32(arc_radius),
			junction = junction,
		})
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
			start_angle := math.atan2(position.y-move.center.y, position.x-move.center.x)
			prev := position
			seg_dt := duration/f64(segs)
			for i in 1..=segs {
				next_pt := move.to
				if i < segs {
					ang := start_angle+sweep*f64(i)/f64(segs)
					next_pt = {move.center.x+radius*math.cos(ang), move.center.y+radius*math.sin(ang), move.to.z}
				}
				t0 := clock+f64(i-1)*seg_dt
				t1 := clock+f64(i)*seg_dt
				append_bead(beads, layers, prev, next_pt, move.width, move.height, t0, t1, move.arc, radius, move.junction)
				prev = next_pt
			}
			clock += duration
			position = move.to
			continue
		}
		delta := move.to-position
		duration := math.sqrt(delta.x*delta.x+delta.y*delta.y+delta.z*delta.z)/move.speed
		if move.extrude {
			append_bead(beads, layers, position, move.to, move.width, move.height, clock, clock+duration, .None, 0, move.junction)
		}
		clock += duration
		position = move.to
	}
	return
}

design_bead_mesh :: proc(beads: []Design_Bead, selected_junction := -1) -> Mesh {
	mesh: Mesh
	mesh.vertices = make([dynamic]Mesh_Vertex, 0, len(beads)*BEAD_VERTICES)
	mesh.bounds = {{max(f32), max(f32), max(f32)}, {-max(f32), -max(f32), -max(f32)}}
	vertices: [BEAD_VERTICES]Mesh_Vertex
	for bead in beads {
		selected := selected_junction >= 0 && int(bead.junction) == selected_junction
		design_bead_vertices(bead, 1, vertices[:], selected)
		append(&mesh.vertices, ..vertices[:])
		for v in vertices {
			mesh.bounds.minimum = {min(mesh.bounds.minimum.x, v.position.x), min(mesh.bounds.minimum.y, v.position.y), min(mesh.bounds.minimum.z, v.position.z)}
			mesh.bounds.maximum = {max(mesh.bounds.maximum.x, v.position.x), max(mesh.bounds.maximum.y, v.position.y), max(mesh.bounds.maximum.z, v.position.z)}
		}
	}
	if len(beads) == 0 {mesh.bounds = {}}
	mesh.triangle_count = u32(len(mesh.vertices)/3)
	return mesh
}

// Writes the bead from its start to `fraction` of its length. The ends extend by half a width
// so consecutive beads close their corners. Arc beads encode `is_arc` by scaling normals by 2.0,
// and selected-junction beads encode `is_selected` by scaling normals by 3.0.
design_bead_vertices :: proc(bead: Design_Bead, fraction: f32, out: []Mesh_Vertex, selected := false) {
	assert(len(out) == BEAD_VERTICES)
	end := vec3_add(bead.a, vec3_mul(vec3_sub(bead.b, bead.a), fraction))
	along := vec3_sub(bead.b, bead.a)
	along.z = 0
	direction := Vec3{1, 0, 0}
	if vec3_length(along) > 0.000001 {direction = vec3_normalize(along)}
	side := Vec3{-direction.y, direction.x, 0}
	extend := vec3_mul(direction, bead.width*0.5)
	start := vec3_sub(bead.a, extend)
	stop := vec3_add(end, extend)
	half := bead.width*0.5
	round := min(bead.height*0.42, half)
	// Hexagonal bead profile as (across, down) offsets from the top centre, CCW from above.
	profile := [BEAD_SIDES][2]f32{
		{-half+round, 0}, {half-round, 0},
		{half, bead.height*0.5},
		{half-round, bead.height}, {-half+round, bead.height},
		{-half, bead.height*0.5},
	}
	normal_scale := f32(3.0) if selected else (f32(2.0) if bead.arc != .None else f32(1.0))
	ring :: proc(origin, side: Vec3, p: [2]f32) -> Vec3 {
		return {origin.x+side.x*p[0], origin.y+side.y*p[0], origin.z-p[1]}
	}
	index := 0
	for k in 0..<BEAD_SIDES {
		p := profile[k]
		q := profile[(k+1)%BEAD_SIDES]
		mid := [2]f32{(p[0]+q[0])*0.5, (p[1]+q[1])*0.5-bead.height*0.5}
		normal := vec3_mul(vec3_normalize(Vec3{side.x*mid[0], side.y*mid[0], -mid[1]}), normal_scale)
		a0 := ring(start, side, p)
		a1 := ring(start, side, q)
		b0 := ring(stop, side, p)
		b1 := ring(stop, side, q)
		quad := [6]Vec3{a0, b0, b1, a0, b1, a1}
		for position in quad {
			out[index] = {position, normal}
			index += 1
		}
	}
	assert(index == BEAD_VERTICES)
}

Design_Visual :: struct {
	finished_vertices: int,
	partial:           []Mesh_Vertex,
	is_design:         bool,
	highlight_start:   int, // vertex index where current layer begins; -1 when using default color
	marker_active:     bool,
	marker_pos:        Vec3,
	marker_radius:     f32,
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
	if !s.active || len(s.beads) == 0 {return}
	v.is_design = true
	low, high := 0, len(s.beads)
	for low < high {
		middle := (low+high)/2
		if s.beads[middle].t1 <= s.clock {low = middle+1} else {high = middle}
	}
	v.finished_vertices = low*BEAD_VERTICES
	tip := s.beads[0].a
	if low > 0 {tip = s.beads[low-1].b}
	if low < len(s.beads) && s.beads[low].t0 < s.clock {
		bead := s.beads[low]
		fraction := f32((s.clock-bead.t0)/max(bead.t1-bead.t0, 0.000001))
		design_bead_vertices(bead, fraction, s.partial[:])
		v.partial = s.partial[:]
		tip = vec3_add(bead.a, vec3_mul(vec3_sub(bead.b, bead.a), fraction))
	}
	layer_idx, layer_count, _, in_layer := design_layer_state(s)
	if layer_count > 0 {
		layer := s.layers[layer_idx]
		if in_layer < 1.0-1e-6 {
			v.highlight_start = min(layer.first_bead*BEAD_VERTICES, v.finished_vertices)
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
