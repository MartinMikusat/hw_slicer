package pipeline

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"

import formats "../formats"

// A run that last took longer than this no longer starts on its own after a setting change; the
// operator starts it with Run. Stages that have not run yet count as fast.
WORKSPACE_AUTO_RUN_LIMIT_MS :: 750.0

Setting_Kind :: enum u8 {
	Number,
	Toggle,
	Choice,
}

// One editable setting. `key` is the `profile_apply_override` key. The owner stage is the first
// stage the setting affects; later stages in `also_read` show it read-only.
Setting_Descriptor :: struct {
	key:       string,
	label:     string,
	unit:      string,
	kind:      Setting_Kind,
	choices:   []string,
	owner:     Stage_Id,
	also_read: Stage_Set,
}

setting_descriptors := [?]Setting_Descriptor {
	{key = "layer_height", label = "Layer height", unit = "mm", owner = .Layer_Schedule,
		also_read = {.Solid_Skin, .Sparse_Infill, .Path_Plan, .Motion}},
	{key = "first_layer_height", label = "First layer height", unit = "mm", owner = .Layer_Schedule,
		also_read = {.Solid_Skin, .Path_Plan, .Motion}},
	{key = "adaptive_layers", label = "Adaptive layers", kind = .Toggle, owner = .Layer_Schedule},
	{key = "line_width", label = "Line width", unit = "mm", owner = .Perimeters,
		also_read = {.Solid_Skin, .Sparse_Infill, .Gap_Fill, .Supports, .Path_Plan, .Motion}},
	{key = "perimeters", label = "Perimeters", owner = .Perimeters, also_read = {.Solid_Skin, .Sparse_Infill}},
	{key = "elephant_foot", label = "Elephant foot compensation", unit = "mm", owner = .Perimeters, also_read = {.Supports}},
	{key = "monotonic_skin", label = "Monotonic skin", kind = .Toggle, owner = .Solid_Skin},
	{key = "ironing", label = "Ironing", kind = .Toggle, owner = .Solid_Skin},
	{key = "ironing_spacing", label = "Ironing spacing", unit = "mm", owner = .Solid_Skin},
	{key = "ironing_flow", label = "Ironing flow", unit = "%", owner = .Solid_Skin},
	{key = "infill_density", label = "Infill density", unit = "%", owner = .Sparse_Infill},
	{key = "infill_pattern", label = "Infill pattern", kind = .Choice, owner = .Sparse_Infill,
		choices = {"rectilinear", "grid", "triangles", "gyroid", "cubic", "honeycomb", "lightning"}},
	{key = "support_mode", label = "Support mode", kind = .Choice, owner = .Supports, choices = {"everywhere", "build_plate_only"}},
	{key = "support_style", label = "Support style", kind = .Choice, owner = .Supports, choices = {"tree", "grid"}},
	{key = "support_overhang_angle", label = "Support overhang angle", unit = "°", owner = .Supports},
	{key = "support_density", label = "Support density", unit = "%", owner = .Supports},
	{key = "skirt_loops", label = "Skirt loops", owner = .Supports},
	{key = "skirt_distance", label = "Skirt distance", unit = "mm", owner = .Supports},
	{key = "skirt_height", label = "Skirt height", unit = "layers", owner = .Supports},
	{key = "brim_width", label = "Brim width", unit = "mm", owner = .Supports},
	{key = "brim_gap", label = "Brim gap", unit = "mm", owner = .Supports},
	{key = "brim_inner", label = "Inner brim", kind = .Toggle, owner = .Supports},
	{key = "seam_position", label = "Seam position", kind = .Choice, owner = .Path_Plan,
		choices = {"aligned", "rear", "sharpest", "nearest"}},
	{key = "variable_walls", label = "Variable walls", kind = .Toggle, owner = .Path_Plan},
	{key = "perimeter_speed", label = "Perimeter speed", unit = "mm/s", owner = .Motion},
	{key = "infill_speed", label = "Infill speed", unit = "mm/s", owner = .Motion},
	{key = "travel_speed", label = "Travel speed", unit = "mm/s", owner = .Motion},
	{key = "fan", label = "Fan", unit = "%", owner = .Motion},
	{key = "min_layer_time", label = "Minimum layer time", unit = "s", owner = .Motion},
	{key = "nozzle_temp", label = "Nozzle temperature", unit = "°C", owner = .Motion},
	{key = "bed_temp", label = "Bed temperature", unit = "°C", owner = .Motion},
	{key = "z_hop", label = "Z hop", unit = "mm", owner = .Motion},
	{key = "wipe_distance", label = "Wipe distance", unit = "mm", owner = .Motion},
	{key = "overhang_slowdown", label = "Overhang slowdown", kind = .Toggle, owner = .Motion},
	{key = "overhang_speed", label = "Overhang speed", unit = "%", owner = .Motion},
	{key = "arc_fitting", label = "Arc fitting", kind = .Toggle, owner = .Motion},
	{key = "arc_tolerance", label = "Arc tolerance", unit = "mm", owner = .Motion},
}

// The current value of a setting in the units of its descriptor, as text.
slice_configuration_value :: proc(config: Slice_Configuration, key: string) -> string {
	p := config.process
	e := config.extras
	b :: proc(v: bool) -> string {return "true" if v else "false"}
	mm :: proc(um: i64) -> string {return fmt.tprintf("%v", f64(um) / 1000.0)}
	switch key {
	case "layer_height":            return mm(i64(p.layer_height))
	case "first_layer_height":      return mm(i64(p.first_layer_height))
	case "adaptive_layers":         return b(config.adaptive_layers || e.adaptive_layers)
	case "line_width":              return mm(i64(p.nominal_line_width))
	case "perimeters":              return fmt.tprintf("%d", p.perimeter_count)
	case "elephant_foot":           return fmt.tprintf("%v", e.elephant_foot_compensation_mm)
	case "monotonic_skin":          return b(e.monotonic_skin)
	case "ironing":                 return b(e.ironing_enabled)
	case "ironing_spacing":         return fmt.tprintf("%v", e.ironing_spacing_mm)
	case "ironing_flow":            return fmt.tprintf("%d", e.ironing_flow_percent)
	case "infill_density":          return fmt.tprintf("%v", e.infill_density_percent)
	case "infill_pattern":          return e.infill_pattern if len(e.infill_pattern) > 0 else "gyroid"
	case "support_mode":            return "everywhere" if p.support_mode == .Everywhere else "build_plate_only"
	case "support_style":           return "grid" if e.support_style == "grid" else "tree"
	case "support_overhang_angle":  return fmt.tprintf("%v", f64(i32(p.support_overhang_angle)) / 1000.0)
	case "support_density":         return fmt.tprintf("%v", f64(u32(p.support_density)) / 10_000.0)
	case "skirt_loops":             return fmt.tprintf("%d", e.skirt_loops)
	case "skirt_distance":          return fmt.tprintf("%v", e.skirt_distance_mm)
	case "skirt_height":            return fmt.tprintf("%d", e.skirt_height_layers)
	case "brim_width":              return fmt.tprintf("%v", e.brim_width_mm)
	case "brim_gap":                return fmt.tprintf("%v", e.brim_gap_mm)
	case "brim_inner":              return b(e.brim_inner)
	case "seam_position":           return e.seam_position if len(e.seam_position) > 0 else "aligned"
	case "variable_walls":          return b(e.variable_walls_enabled)
	case "perimeter_speed":         return mm(i64(p.perimeter.speed))
	case "infill_speed":            return mm(i64(p.sparse_infill.speed))
	case "travel_speed":            return mm(i64(p.travel.speed))
	case "fan":                     return fmt.tprintf("%v", f64(u32(p.perimeter.fan_ratio)) / 10_000.0)
	case "min_layer_time":          return fmt.tprintf("%v", f64(u32(p.minimum_layer_time)) / 1000.0)
	case "nozzle_temp":             return fmt.tprintf("%d", i32(p.nozzle_temperature))
	case "bed_temp":                return fmt.tprintf("%d", i32(p.bed_temperature))
	case "z_hop":                   return mm(i64(p.z_hop_height)) if p.z_hop_enabled else "0"
	case "wipe_distance":           return fmt.tprintf("%v", e.wipe_distance_mm)
	case "overhang_slowdown":       return b(e.overhang_slowdown_enabled)
	case "overhang_speed":          return fmt.tprintf("%d", e.overhang_speed_percent)
	case "arc_fitting":             return b(e.arc_fitting_enabled)
	case "arc_tolerance":           return fmt.tprintf("%v", e.arc_tolerance_mm)
	}
	return ""
}

Stage_View :: struct {
	id:          Stage_Id,
	name:        string,
	purpose:     string,
	state:       Stage_State,
	// Set while the state is Stale: the earliest stage whose settings changed.
	changed_by:  Stage_Id,
	duration_ms: f64,
	count_a:     u64,
	count_b:     u64,
	// True when a setting change starts this stage by itself.
	auto_run:    bool,
	failure:     Slice_Run_Error,
}

Group_View :: struct {
	group:      Stage_Group,
	name:       string,
	state:      Stage_State,
	stages:     Stage_Set,
	// The first stale or failed stage of the group, for the status line.
	stale_stage: Stage_Id,
}

Workspace_View :: struct {
	stages:     [Stage_Id]Stage_View,
	groups:     [Stage_Group]Group_View,
	selected:   Stage_Group,
	running:    bool,
	// The stage being computed while `running`.
	active:     Stage_Id,
	can_previous: bool,
	can_next:     bool,
	queued_edits: int,
}

Setting_View :: struct {
	descriptor: Setting_Descriptor,
	value:      string,
	// False for a setting owned by an earlier stage, shown as context only.
	editable:   bool,
	owner_name: string,
}

@(private = "file")
Queued_Edit :: struct {
	key:   string,
	value: string,
}

// The operator-facing controller: owns the configuration and the session, runs stages on a
// background thread, and exposes status and settings as plain data. The application draws from
// this and sends actions back; nothing here depends on the interface.
Workspace :: struct {
	config:         Slice_Configuration,
	session:        ^Slice_Session,
	selected:       Stage_Group,
	selected_layer: int,
	// When false, a setting change only marks stages stale and the operator starts every run.
	manual_only:    bool,
	last_error:     Slice_Run_Error,

	thread:         ^thread.Thread,
	running:        bool,
	cancel:         bool,
	active_stage:   Stage_Id,
	queued:         [dynamic]Queued_Edit,
}

// Takes ownership of nothing: the mesh is copied and the configuration slices must outlive the
// workspace.
workspace_create :: proc(
	config: Slice_Configuration,
	mesh: formats.Decoded_Mesh,
) -> (w: ^Workspace, detail: string, ok: bool) {
	resolved, options, resolve_detail, resolve_ok := slice_configuration_resolve(config)
	if !resolve_ok {return nil, resolve_detail, false}
	w = new(Workspace)
	w.config = config
	w.session = slice_session_create(mesh, resolved, options)
	w.queued = make([dynamic]Queued_Edit)
	return w, "", true
}

workspace_destroy :: proc(w: ^Workspace) {
	if w == nil {return}
	workspace_cancel(w)
	workspace_wait(w)
	for edit in w.queued {
		delete(edit.key)
		delete(edit.value)
	}
	delete(w.queued)
	delete(w.last_error.stage)
	delete(w.last_error.detail)
	slice_session_destroy(w.session)
	free(w)
}

workspace_select :: proc(w: ^Workspace, group: Stage_Group) {
	w.selected = group
}

workspace_next :: proc(w: ^Workspace) -> bool {
	if !workspace_view(w).can_next {return false}
	w.selected = Stage_Group(int(w.selected) + 1)
	return true
}

workspace_previous :: proc(w: ^Workspace) -> bool {
	if w.selected == min(Stage_Group) {return false}
	w.selected = Stage_Group(int(w.selected) - 1)
	return true
}

workspace_running :: proc(w: ^Workspace) -> bool {
	return sync.atomic_load(&w.running)
}

// Changes one setting. While a run is active the change waits in a queue and applies when the run
// ends. A change that the profile validation rejects is refused at once and leaves no trace.
// Stages that become stale and are quick to run start automatically.
workspace_edit :: proc(w: ^Workspace, key, value: string) -> (detail: string, ok: bool) {
	trial := w.config
	if detail, ok = slice_configuration_override(&trial, key, value); !ok {return}
	if _, _, resolve_detail, resolve_ok := slice_configuration_resolve(trial); !resolve_ok {
		return resolve_detail, false
	}
	if workspace_running(w) {
		append(&w.queued, Queued_Edit{key = strings.clone(key), value = strings.clone(value)})
		return "", true
	}
	workspace_apply(w, trial)
	workspace_autorun(w)
	return "", true
}

// Starts the stages that are stale or missing up to and including the target.
workspace_run_to :: proc(w: ^Workspace, target: Stage_Id) -> bool {
	if workspace_running(w) {return false}
	workspace_start(w, target)
	return true
}

// Starts everything that is stale or missing in the selected group and the stages it needs.
workspace_run_selected :: proc(w: ^Workspace) -> bool {
	members := stage_group_members(w.selected)
	target: Stage_Id
	for id in Stage_Id {if id in members {target = id}}
	return workspace_run_to(w, target)
}

workspace_set_auto_run :: proc(w: ^Workspace, enabled: bool) {
	w.manual_only = !enabled
}

workspace_cancel :: proc(w: ^Workspace) {
	sync.atomic_store(&w.cancel, true)
}

// Joins a finished run, applies queued edits and starts follow-up automatic runs. Returns true when
// the visible state may have changed. The application calls this once per frame.
workspace_poll :: proc(w: ^Workspace) -> (changed: bool) {
	if w.thread == nil {return false}
	if !thread.is_done(w.thread) {return false}
	thread.join(w.thread)
	thread.destroy(w.thread)
	w.thread = nil
	sync.atomic_store(&w.running, false)
	sync.atomic_store(&w.cancel, false)
	if len(w.queued) > 0 {
		trial := w.config
		applied := false
		for edit in w.queued {
			if _, ok := slice_configuration_override(&trial, edit.key, edit.value); ok {applied = true}
			delete(edit.key)
			delete(edit.value)
		}
		clear(&w.queued)
		if applied {workspace_apply(w, trial)}
	}
	workspace_autorun(w)
	return true
}

// Blocks until no run is active, for the headless driver and for shutdown.
workspace_wait :: proc(w: ^Workspace) {
	for w.thread != nil {
		thread.join(w.thread)
		workspace_poll(w)
	}
}

workspace_view :: proc(w: ^Workspace) -> Workspace_View {
	v: Workspace_View
	s := w.session
	sync.mutex_lock(&s.lock)
	for id in Stage_Id {
		slot := s.slots[id]
		d := stage_descriptors[id]
		v.stages[id] = {
			id = id, name = d.name, purpose = d.purpose, state = slot.state, changed_by = slot.changed_by,
			duration_ms = slot.duration_ms, count_a = slot.count_a, count_b = slot.count_b,
			auto_run = slot.duration_ms < WORKSPACE_AUTO_RUN_LIMIT_MS, failure = slot.failure,
		}
	}
	sync.mutex_unlock(&s.lock)
	for group in Stage_Group {
		members := stage_group_members(group)
		g := Group_View{group = group, name = stage_group_names[group], stages = members, state = .Complete}
		first_pending := true
		for id in Stage_Id {
			if id not_in members {continue}
			state := v.stages[id].state
			switch {
			case state == .Failed:
				g.state = .Failed
			case state == .Running && g.state != .Failed:
				g.state = .Running
			case state == .Stale && g.state != .Failed && g.state != .Running:
				g.state = .Stale
			case state == .Not_Run && g.state == .Complete:
				g.state = .Not_Run
			}
			if state != .Complete && first_pending {
				g.stale_stage = id
				first_pending = false
			}
		}
		v.groups[group] = g
	}
	v.selected = w.selected
	v.running = workspace_running(w)
	v.active = w.active_stage
	selected_state := v.groups[w.selected].state
	v.can_next = (selected_state == .Complete || selected_state == .Stale) && w.selected != max(Stage_Group)
	v.can_previous = w.selected != min(Stage_Group)
	v.queued_edits = len(w.queued)
	return v
}

// Settings the selected group owns, followed by the earlier-owned settings its stages read.
workspace_settings :: proc(w: ^Workspace, group: Stage_Group, allocator := context.temp_allocator) -> []Setting_View {
	members := stage_group_members(group)
	out := make([dynamic]Setting_View, 0, 16, allocator)
	for d in setting_descriptors {
		if d.owner in members {
			append(&out, Setting_View{descriptor = d, value = slice_configuration_value(w.config, d.key), editable = true})
		}
	}
	for d in setting_descriptors {
		if d.owner in members {continue}
		if d.also_read & members != {} {
			append(&out, Setting_View{
				descriptor = d,
				value = slice_configuration_value(w.config, d.key),
				owner_name = stage_descriptors[d.owner].name,
			})
		}
	}
	return out[:]
}

@(private = "file")
workspace_apply :: proc(w: ^Workspace, config: Slice_Configuration) {
	resolved, options, _, ok := slice_configuration_resolve(config)
	if !ok {return}
	w.config = config
	slice_session_update(w.session, resolved, options)
}

// Runs the stale stages that are quick, in order, up to the first one that is slow or has no result.
@(private = "file")
workspace_autorun :: proc(w: ^Workspace) {
	if workspace_running(w) || w.manual_only {return}
	target: Stage_Id
	found := false
	for id in Stage_Id {
		slot := w.session.slots[id]
		if slot.state == .Complete {continue}
		// Only results that a change made stale refresh by themselves. A stage that has not run
		// waits for the operator, and the stages after it keep their stale results.
		if slot.state != .Stale {break}
		if slot.duration_ms >= WORKSPACE_AUTO_RUN_LIMIT_MS {break}
		target = id
		found = true
	}
	if found {workspace_start(w, target)}
}

@(private = "file")
workspace_start :: proc(w: ^Workspace, target: Stage_Id) {
	if slice_session_pending(w.session, target) == {} {return}
	sync.atomic_store(&w.running, true)
	sync.atomic_store(&w.cancel, false)
	w.active_stage = target
	Run_Job :: struct {
		w:      ^Workspace,
		target: Stage_Id,
	}
	job := new(Run_Job)
	job^ = {w = w, target = target}
	t := thread.create(proc(t: ^thread.Thread) {
		job := (^Run_Job)(t.data)
		w := job.w
		err := slice_session_run_to(w.session, job.target, &w.cancel)
		if len(err.stage) > 0 && err.stage != SLICE_RUN_CANCELLED {
			sync.mutex_lock(&w.session.lock)
			delete(w.last_error.stage)
			delete(w.last_error.detail)
			w.last_error = {stage = strings.clone(err.stage), detail = strings.clone(err.detail)}
			sync.mutex_unlock(&w.session.lock)
		}
		free(job)
	})
	t.data = job
	t.init_context = context
	w.thread = t
	thread.start(t)
}
