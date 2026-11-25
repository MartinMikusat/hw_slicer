package pipeline

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import formats "../formats"

// A run that last took longer than this no longer starts on its own after a setting change; the
// operator starts it with Run. Stages that have not run yet count as fast.
WORKSPACE_AUTO_RUN_LIMIT_MS :: 5_000.0

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
	// Amount that one step of a number moves.
	step:      f64,
	kind:      Setting_Kind,
	choices:   []string,
	owner:     Stage_Id,
	also_read: Stage_Set,
	// Rarely changed or diagnostic settings, hidden until the operator shows advanced settings.
	advanced:  bool,
}

setting_descriptors := [?]Setting_Descriptor {
	{key = "layer_height", step = 0.04, label = "Layer height", unit = "mm", owner = .Layer_Schedule,
		also_read = {.Solid_Paths, .Sparse_Infill, .Path_Plan, .Motion}},
	{key = "first_layer_height", step = 0.04, label = "First layer height", unit = "mm", owner = .Layer_Schedule,
		also_read = {.Solid_Paths, .Path_Plan, .Motion}, advanced = true},
	{key = "adaptive_layers", label = "Adaptive layers", kind = .Toggle, owner = .Layer_Schedule},
	{key = "resolution", step = 0.004, label = "Contour resolution", unit = "mm", owner = .Topology, advanced = true},
	{key = "top_skin_layers", step = 1, label = "Top shell layers", owner = .Surfaces_Skin, also_read = {.Solid_Areas}},
	{key = "top_skin_thickness", step = 0.2, label = "Top shell thickness", unit = "mm", owner = .Surfaces_Skin, advanced = true},
	{key = "bottom_skin_layers", step = 1, label = "Bottom shell layers", owner = .Surfaces_Skin, also_read = {.Solid_Areas}},
	{key = "bottom_skin_thickness", step = 0.2, label = "Bottom shell thickness", unit = "mm", owner = .Surfaces_Skin, advanced = true},
	{key = "vase_mode", label = "Spiral vase mode", kind = .Toggle, owner = .Surfaces_Skin, also_read = {.Perimeters, .Motion}, advanced = true},
	{key = "line_width", step = 0.02, label = "Line width", unit = "mm", owner = .Perimeters,
		also_read = {.Solid_Areas, .Solid_Paths, .Sparse_Infill, .Gap_Fill, .Supports, .Path_Plan, .Motion}},
	{key = "initial_layer_line_width", step = 0.02, label = "First layer line width", unit = "mm", owner = .Perimeters, advanced = true},
	{key = "outer_wall_line_width", step = 0.02, label = "Outer wall line width", unit = "mm", owner = .Perimeters, advanced = true},
	{key = "inner_wall_line_width", step = 0.02, label = "Inner wall line width", unit = "mm", owner = .Perimeters, advanced = true},
	{key = "perimeters", step = 1, label = "Perimeters", owner = .Perimeters, also_read = {.Solid_Areas, .Sparse_Infill}},
	{key = "only_one_wall_first_layer", label = "One wall on first layer", kind = .Toggle, owner = .Perimeters, advanced = true},
	{key = "elephant_foot", step = 0.05, label = "Elephant foot compensation", unit = "mm", owner = .Perimeters, also_read = {.Supports}, advanced = true},
	{key = "xy_contour_compensation", step = 0.05, label = "XY contour compensation", unit = "mm", owner = .Perimeters, advanced = true},
	{key = "xy_hole_compensation", step = 0.05, label = "XY hole compensation", unit = "mm", owner = .Perimeters, advanced = true},
	{key = "precise_outer_wall", label = "Precise outer wall", kind = .Toggle, owner = .Perimeters, advanced = true},
	{key = "bridge_angle", step = 15, label = "Bridge angle", unit = "°", owner = .Bridges, advanced = true},
	{key = "bridge_flow", step = 0.05, label = "Bridge flow ratio", owner = .Bridges, also_read = {.Motion}, advanced = true},
	{key = "thick_bridges", label = "Thick bridges", kind = .Toggle, owner = .Bridges, also_read = {.Path_Plan}, advanced = true},
	{key = "ensure_vertical_shells", label = "Ensure vertical shells", kind = .Toggle, owner = .Solid_Areas, advanced = true},
	{key = "top_surface_pattern", label = "Top surface pattern", kind = .Choice, owner = .Solid_Paths,
		choices = {"monotonic", "rectilinear", "concentric"}},
	{key = "bottom_surface_pattern", label = "Bottom surface pattern", kind = .Choice, owner = .Solid_Paths,
		choices = {"monotonic", "rectilinear", "concentric"}, advanced = true},
	{key = "top_surface_line_width", step = 0.02, label = "Top surface line width", unit = "mm", owner = .Solid_Paths, advanced = true},
	{key = "monotonic_skin", label = "Monotonic skin", kind = .Toggle, owner = .Solid_Paths, advanced = true},
	{key = "ironing_type", label = "Ironing type", kind = .Choice, owner = .Solid_Paths,
		choices = {"none", "top", "topmost", "all_solid"}},
	{key = "ironing", label = "Ironing", kind = .Toggle, owner = .Solid_Paths, advanced = true},
	{key = "ironing_spacing", step = 0.05, label = "Ironing spacing", unit = "mm", owner = .Solid_Paths, advanced = true},
	{key = "ironing_flow", step = 5, label = "Ironing flow", unit = "%", owner = .Solid_Paths, advanced = true},
	{key = "ironing_inset", step = 0.05, label = "Ironing inset", unit = "mm", owner = .Solid_Paths, advanced = true},
	{key = "infill_density", step = 5, label = "Infill density", unit = "%", owner = .Sparse_Infill},
	{key = "infill_pattern", label = "Infill pattern", kind = .Choice, owner = .Sparse_Infill,
		choices = {"rectilinear", "grid", "triangles", "gyroid", "cubic", "honeycomb", "lightning", "concentric", "aligned_rectilinear"}},
	{key = "sparse_infill_line_width", step = 0.02, label = "Sparse infill line width", unit = "mm", owner = .Sparse_Infill, advanced = true},
	{key = "infill_direction", step = 15, label = "Infill direction", unit = "°", owner = .Sparse_Infill, also_read = {.Solid_Paths}, advanced = true},
	{key = "infill_wall_overlap", step = 5, label = "Infill/wall overlap", unit = "%", owner = .Sparse_Infill, advanced = true},
	{key = "infill_combination", step = 1, label = "Infill combination", unit = "layers", owner = .Sparse_Infill, also_read = {.Motion}, advanced = true},
	{key = "minimum_sparse_infill_area", step = 5, label = "Min sparse infill area", unit = "mm²", owner = .Sparse_Infill, advanced = true},
	{key = "detect_thin_wall", label = "Detect thin walls", kind = .Toggle, owner = .Gap_Fill, advanced = true},
	{key = "gap_fill_target", label = "Gap fill target", kind = .Choice, owner = .Gap_Fill,
		choices = {"everywhere", "nowhere", "top_bottom"}, advanced = true},
	{key = "enable_supports", label = "Enable supports", kind = .Toggle, owner = .Supports},
	{key = "support_mode", label = "Support mode", kind = .Choice, owner = .Supports, choices = {"everywhere", "build_plate_only"}},
	{key = "support_style", label = "Support style", kind = .Choice, owner = .Supports, choices = {"tree", "grid"}},
	{key = "support_overhang_angle", step = 5, label = "Support overhang angle", unit = "°", owner = .Supports, advanced = true},
	{key = "support_density", step = 5, label = "Support density", unit = "%", owner = .Supports},
	{key = "support_expansion", step = 0.2, label = "Support expansion", unit = "mm", owner = .Supports, advanced = true},
	{key = "tree_branch_angle", step = 5, label = "Tree branch angle", unit = "°", owner = .Supports, advanced = true},
	{key = "skirt_loops", step = 1, label = "Skirt loops", owner = .Supports},
	{key = "skirt_distance", step = 1, label = "Skirt distance", unit = "mm", owner = .Supports, advanced = true},
	{key = "skirt_height", step = 1, label = "Skirt height", unit = "layers", owner = .Supports, advanced = true},
	{key = "min_skirt_length", step = 10, label = "Min skirt length", unit = "mm", owner = .Supports, advanced = true},
	{key = "draft_shield", label = "Draft shield", kind = .Toggle, owner = .Supports, advanced = true},
	{key = "brim_type", label = "Brim type", kind = .Choice, owner = .Supports,
		choices = {"none", "outer_only", "inner_only", "outer_and_inner"}, advanced = true},
	{key = "brim_width", step = 1, label = "Brim width", unit = "mm", owner = .Supports},
	{key = "brim_gap", step = 0.05, label = "Brim gap", unit = "mm", owner = .Supports, advanced = true},
	{key = "brim_inner", label = "Inner brim", kind = .Toggle, owner = .Supports, advanced = true},
	{key = "raft_layers", step = 1, label = "Raft layers", owner = .Model, also_read = {.Supports}, advanced = true},
	{key = "wall_sequence", label = "Wall order", kind = .Choice, owner = .Path_Plan,
		choices = {"inner_outer", "outer_inner", "inner_outer_inner"}, advanced = true},
	{key = "infill_first", label = "Infill before walls", kind = .Toggle, owner = .Path_Plan, advanced = true},
	{key = "only_one_wall_top", label = "One wall on top", kind = .Toggle, owner = .Path_Plan, advanced = true},
	{key = "seam_position", label = "Seam position", kind = .Choice, owner = .Path_Plan,
		choices = {"aligned", "rear", "sharpest", "nearest", "random"}},
	{key = "seam_gap", step = 5, label = "Seam gap", unit = "%", owner = .Path_Plan, advanced = true},
	{key = "staggered_inner_seams", label = "Staggered inner seams", kind = .Toggle, owner = .Path_Plan, advanced = true},
	{key = "variable_walls", label = "Variable walls", kind = .Toggle, owner = .Path_Plan},
	{key = "fuzzy_skin_mode", label = "Fuzzy skin", kind = .Choice, owner = .Path_Plan,
		choices = {"none", "contour", "all", "all_walls"}, advanced = true},
	{key = "initial_layer_speed", step = 5, label = "First layer speed", unit = "mm/s", owner = .Motion, advanced = true},
	{key = "outer_wall_speed", step = 5, label = "Outer wall speed", unit = "mm/s", owner = .Motion, advanced = true},
	{key = "inner_wall_speed", step = 5, label = "Inner wall speed", unit = "mm/s", owner = .Motion, advanced = true},
	{key = "perimeter_speed", step = 5, label = "Perimeter speed", unit = "mm/s", owner = .Motion},
	{key = "top_surface_speed", step = 5, label = "Top surface speed", unit = "mm/s", owner = .Motion, advanced = true},
	{key = "infill_speed", step = 5, label = "Infill speed", unit = "mm/s", owner = .Motion},
	{key = "small_perimeter_speed", step = 5, label = "Small perimeter speed", unit = "mm/s", owner = .Motion, advanced = true},
	{key = "ironing_speed", step = 5, label = "Ironing speed", unit = "mm/s", owner = .Motion, advanced = true},
	{key = "travel_speed", step = 10, label = "Travel speed", unit = "mm/s", owner = .Motion},
	{key = "top_surface_flow_ratio", step = 0.02, label = "Top surface flow", owner = .Motion, advanced = true},
	{key = "fan", step = 10, label = "Fan", unit = "%", owner = .Motion},
	{key = "min_layer_time", step = 1, label = "Minimum layer time", unit = "s", owner = .Motion, advanced = true},
	{key = "nozzle_temp", step = 5, label = "Nozzle temperature", unit = "°C", owner = .Motion},
	{key = "bed_temp", step = 5, label = "Bed temperature", unit = "°C", owner = .Motion},
	{key = "z_hop", step = 0.1, label = "Z hop", unit = "mm", owner = .Motion},
	{key = "wipe_distance", step = 0.5, label = "Wipe distance", unit = "mm", owner = .Motion, advanced = true},
	{key = "reduce_crossing_wall", label = "Avoid crossing walls", kind = .Toggle, owner = .Motion, advanced = true},
	{key = "reduce_infill_retraction", label = "Reduce infill retraction", kind = .Toggle, owner = .Motion, advanced = true},
	{key = "scarf_seam", label = "Scarf seam", kind = .Toggle, owner = .Motion, advanced = true},
	{key = "overhang_slowdown", label = "Overhang slowdown", kind = .Toggle, owner = .Motion},
	{key = "overhang_speed", step = 5, label = "Overhang speed", unit = "%", owner = .Motion, advanced = true},
	{key = "arc_fitting", label = "Arc fitting", kind = .Toggle, owner = .Motion},
	{key = "arc_tolerance", step = 0.01, label = "Arc tolerance", unit = "mm", owner = .Motion, advanced = true},
	{key = "accel_to_decel_enable", label = "Accel to decel", kind = .Toggle, owner = .Gcode, advanced = true},
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
	case "resolution":              return fmt.tprintf("%v", e.resolution_mm)
	case "top_skin_layers":         return fmt.tprintf("%d", p.top_skin.minimum_layers)
	case "top_skin_thickness":      return mm(i64(p.top_skin.thickness))
	case "bottom_skin_layers":      return fmt.tprintf("%d", p.bottom_skin.minimum_layers)
	case "bottom_skin_thickness":   return mm(i64(p.bottom_skin.thickness))
	case "vase_mode":               return b(config.vase_mode || e.vase_mode)
	case "initial_layer_line_width": return fmt.tprintf("%v", e.initial_layer_line_width_mm)
	case "outer_wall_line_width":   return fmt.tprintf("%v", e.outer_wall_line_width_mm)
	case "inner_wall_line_width":   return fmt.tprintf("%v", e.inner_wall_line_width_mm)
	case "only_one_wall_first_layer": return b(e.only_one_wall_first_layer)
	case "xy_contour_compensation": return fmt.tprintf("%v", e.xy_contour_compensation_mm)
	case "xy_hole_compensation":    return fmt.tprintf("%v", e.xy_hole_compensation_mm)
	case "precise_outer_wall":      return b(e.precise_outer_wall)
	case "bridge_angle":            return fmt.tprintf("%v", e.bridge_angle_deg)
	case "bridge_flow":             return fmt.tprintf("%v", e.bridge_flow_ratio)
	case "thick_bridges":           return b(e.thick_bridges)
	case "ensure_vertical_shells":  return b(e.ensure_vertical_shells)
	case "top_surface_pattern":     return e.top_surface_pattern if len(e.top_surface_pattern) > 0 else "monotonic"
	case "bottom_surface_pattern":  return e.bottom_surface_pattern if len(e.bottom_surface_pattern) > 0 else "monotonic"
	case "top_surface_line_width":  return fmt.tprintf("%v", e.top_surface_line_width_mm)
	case "ironing_type":            return e.ironing_type if len(e.ironing_type) > 0 else "none"
	case "ironing_inset":           return fmt.tprintf("%v", e.ironing_inset_mm)
	case "sparse_infill_line_width": return fmt.tprintf("%v", e.sparse_infill_line_width_mm)
	case "infill_direction":        return fmt.tprintf("%v", e.infill_direction_deg)
	case "infill_wall_overlap":     return fmt.tprintf("%v", e.infill_wall_overlap_percent)
	case "infill_combination":      return fmt.tprintf("%d", e.infill_combination_layers)
	case "minimum_sparse_infill_area": return fmt.tprintf("%v", e.minimum_sparse_infill_area_mm2)
	case "detect_thin_wall":        return b(e.detect_thin_wall)
	case "gap_fill_target":         return e.gap_fill_target if len(e.gap_fill_target) > 0 else "everywhere"
	case "enable_supports":         return b(config.enable_supports || e.enable_supports)
	case "support_expansion":       return fmt.tprintf("%v", e.support_expansion_mm)
	case "tree_branch_angle":       return fmt.tprintf("%v", e.tree_branch_angle_deg)
	case "min_skirt_length":        return fmt.tprintf("%v", e.min_skirt_length_mm)
	case "draft_shield":            return b(e.draft_shield)
	case "brim_type":               return e.brim_type if len(e.brim_type) > 0 else "outer_only"
	case "raft_layers":             return fmt.tprintf("%d", e.raft_layers)
	case "wall_sequence":           return e.wall_sequence if len(e.wall_sequence) > 0 else "inner_outer"
	case "infill_first":            return b(e.infill_first)
	case "only_one_wall_top":       return b(e.only_one_wall_top)
	case "seam_gap":                return fmt.tprintf("%v", e.seam_gap_percent)
	case "staggered_inner_seams":   return b(e.staggered_inner_seams)
	case "fuzzy_skin_mode":         return e.fuzzy_skin_mode if len(e.fuzzy_skin_mode) > 0 else "none"
	case "initial_layer_speed":     return fmt.tprintf("%v", e.initial_layer_speed_mm_s)
	case "outer_wall_speed":        return fmt.tprintf("%v", e.outer_wall_speed_mm_s)
	case "inner_wall_speed":        return fmt.tprintf("%v", e.inner_wall_speed_mm_s)
	case "top_surface_speed":       return fmt.tprintf("%v", e.top_surface_speed_mm_s)
	case "small_perimeter_speed":   return fmt.tprintf("%v", e.small_perimeter_speed_mm_s)
	case "ironing_speed":           return fmt.tprintf("%v", e.ironing_speed_mm_s)
	case "top_surface_flow_ratio":  return fmt.tprintf("%v", e.top_surface_flow_ratio)
	case "reduce_crossing_wall":    return b(e.reduce_crossing_wall)
	case "reduce_infill_retraction": return b(e.reduce_infill_retraction)
	case "scarf_seam":              return b(config.scarf_seam || e.scarf_seam_enabled)
	case "accel_to_decel_enable":   return b(e.accel_to_decel_enable)
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
	// Time since the stage started, while it is running.
	elapsed_ms:  f64,
	count_a:     u64,
	count_b:     u64,
	// True when a setting change starts this stage by itself.
	auto_run:    bool,
	// Waiting in the active run for the stages before it.
	queued:      bool,
	// Left without any result by the last run, which was cancelled.
	cancelled:   bool,
	failure:     Slice_Run_Error,
}

Workspace_View :: struct {
	stages:       [Stage_Id]Stage_View,
	selected:     Stage_Id,
	running:      bool,
	// The target of the active run while `running`.
	active:       Stage_Id,
	queued_edits: int,
}

Setting_View :: struct {
	descriptor:    Setting_Descriptor,
	value:         string,
	// The value the workspace opened with, from the profiles. Reset returns to it.
	default_value: string,
	// False for a setting owned by an earlier stage, shown as context only.
	editable:      bool,
	owner_name:    string,
}

Stage_Log_Kind :: enum u8 {
	Ran,
	Failed,
	Cancelled,
	Stale,
}

Stage_Log_Entry :: struct {
	kind:        Stage_Log_Kind,
	at:          time.Time,
	duration_ms: f64,
	// For Stale: the earliest stage whose settings changed.
	cause:       Stage_Id,
}

STAGE_LOG_CAPACITY :: 16

// The most recent events of one stage. Older entries are overwritten.
Stage_Log :: struct {
	entries: [STAGE_LOG_CAPACITY]Stage_Log_Entry,
	// Number of entries ever appended.
	count:   int,
}

stage_log_append :: proc(log: ^Stage_Log, entry: Stage_Log_Entry) {
	log.entries[log.count%STAGE_LOG_CAPACITY] = entry
	log.count += 1
}

stage_log_len :: proc(log: Stage_Log) -> int {
	return min(log.count, STAGE_LOG_CAPACITY)
}

// Entry `index` counted from the newest, which is 0.
stage_log_recent :: proc(log: Stage_Log, index: int) -> Stage_Log_Entry {
	assert(index >= 0 && index < stage_log_len(log))
	return log.entries[(log.count-1-index)%STAGE_LOG_CAPACITY]
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
	// The configuration the workspace opened with.
	defaults:       Slice_Configuration,
	session:        ^Slice_Session,
	selected:       Stage_Id,
	selected_layer: int,
	// When false, a setting change only marks stages stale and the operator starts every run.
	manual_only:    bool,
	last_error:     Slice_Run_Error,
	logs:           [Stage_Id]Stage_Log,

	thread:         ^thread.Thread,
	running:        bool,
	cancel:         bool,
	active_stage:   Stage_Id,
	// The stages the active run computes.
	run_set:        Stage_Set,
	// The stages that the last run, when cancelled, left without a result.
	cancelled:      Stage_Set,
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
	w.defaults = config
	if len(config.object_name) > 0 {
		w.config.object_name = strings.clone(config.object_name)
		w.defaults.object_name = strings.clone(config.object_name)
	}
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
	delete(w.config.object_name)
	delete(w.defaults.object_name)
	slice_session_destroy(w.session)
	free(w)
}

workspace_select :: proc(w: ^Workspace, id: Stage_Id) {
	w.selected = id
}

workspace_running :: proc(w: ^Workspace) -> bool {
	return sync.atomic_load(&w.running)
}

// Changes one setting. While a run is active the change waits in a queue and applies when the run
// ends. A change that the profile validation rejects is refused at once and leaves no trace.
// Stages that become stale and are quick to run start automatically.
workspace_edit :: proc(w: ^Workspace, key, value: string) -> (detail: string, ok: bool) {
	pair := [1][2]string{{key, value}}
	return workspace_edit_many(w, pair[:])
}

// Changes several settings as one edit, so that they mark stages stale and start runs once.
workspace_edit_many :: proc(w: ^Workspace, edits: [][2]string) -> (detail: string, ok: bool) {
	if len(edits) == 0 {return "", true}
	trial := w.config
	for edit in edits {
		if detail, ok = slice_configuration_override(&trial, edit[0], edit[1]); !ok {return}
	}
	if _, _, resolve_detail, resolve_ok := slice_configuration_resolve(trial); !resolve_ok {
		return resolve_detail, false
	}
	if workspace_running(w) {
		for edit in edits {
			append(&w.queued, Queued_Edit{key = strings.clone(edit[0]), value = strings.clone(edit[1])})
		}
		return "", true
	}
	workspace_apply(w, trial)
	workspace_autorun(w)
	return "", true
}

// Returns one setting to the value the workspace opened with.
workspace_reset_setting :: proc(w: ^Workspace, key: string) -> (detail: string, ok: bool) {
	return workspace_edit(w, key, slice_configuration_value(w.defaults, key))
}

// Returns every setting that the stage owns to the value the workspace opened with.
workspace_reset_stage :: proc(w: ^Workspace, id: Stage_Id) -> (detail: string, ok: bool) {
	edits := make([dynamic][2]string, 0, 8, context.temp_allocator)
	for d in setting_descriptors {
		if d.owner != id {continue}
		default_value := slice_configuration_value(w.defaults, d.key)
		if slice_configuration_value(w.config, d.key) != default_value {
			append(&edits, [2]string{d.key, default_value})
		}
	}
	return workspace_edit_many(w, edits[:])
}

// The settings that the stage owns as `key=value` lines, in the form `--stage-set` and the
// workspace script accept.
workspace_settings_text :: proc(w: ^Workspace, id: Stage_Id, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for d in setting_descriptors {
		if d.owner != id {continue}
		fmt.sbprintf(&b, "%s=%s\n", d.key, slice_configuration_value(w.config, d.key))
	}
	return strings.to_string(b)
}

// Starts the stages that are stale or missing up to and including the target.
workspace_run_to :: proc(w: ^Workspace, target: Stage_Id) -> bool {
	if workspace_running(w) {return false}
	workspace_start(w, target)
	return true
}

// Starts everything that is stale or missing up to and including the selected stage.
workspace_run_selected :: proc(w: ^Workspace) -> bool {
	return workspace_run_to(w, w.selected)
}

// True when the stage can be recomputed by itself: every stage it needs has a current result.
workspace_can_run_only :: proc(w: ^Workspace, id: Stage_Id) -> bool {
	if workspace_running(w) {return false}
	for dep in Stage_Id {
		if dep == id || dep not_in stage_upstream(id) {continue}
		if w.session.slots[dep].state != .Complete {return false}
	}
	return true
}

// Recomputes only this stage from the current results of the stages it needs.
workspace_run_only :: proc(w: ^Workspace, id: Stage_Id) -> bool {
	if !workspace_can_run_only(w, id) {return false}
	slice_session_forget(w.session, id)
	workspace_start(w, id)
	return true
}

workspace_set_auto_run :: proc(w: ^Workspace, enabled: bool) {
	w.manual_only = !enabled
}

workspace_cancel :: proc(w: ^Workspace) {
	sync.atomic_store(&w.cancel, true)
}

// Joins a finished run, logs its outcome per stage, applies queued edits and starts follow-up
// automatic runs. Returns true when the visible state may have changed. The application calls this
// once per frame.
workspace_poll :: proc(w: ^Workspace) -> (changed: bool) {
	if w.thread == nil {return false}
	if !thread.is_done(w.thread) {return false}
	thread.join(w.thread)
	thread.destroy(w.thread)
	w.thread = nil
	cancelled := sync.atomic_load(&w.cancel)
	now := time.now()
	for id in Stage_Id {
		if id not_in w.run_set {continue}
		slot := w.session.slots[id]
		switch slot.state {
		case .Complete:
			stage_log_append(&w.logs[id], {kind = .Ran, at = now, duration_ms = slot.duration_ms})
		case .Failed:
			stage_log_append(&w.logs[id], {kind = .Failed, at = now, duration_ms = slot.duration_ms})
		case .Not_Run, .Stale, .Running:
			if cancelled {
				stage_log_append(&w.logs[id], {kind = .Cancelled, at = now})
				w.cancelled += {id}
			}
		}
	}
	w.run_set = {}
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
	running := workspace_running(w)
	sync.mutex_lock(&s.lock)
	for id in Stage_Id {
		slot := s.slots[id]
		d := stage_descriptors[id]
		v.stages[id] = {
			id = id, name = d.name, purpose = d.purpose, state = slot.state, changed_by = slot.changed_by,
			duration_ms = slot.duration_ms, count_a = slot.count_a, count_b = slot.count_b,
			auto_run = slot.duration_ms < WORKSPACE_AUTO_RUN_LIMIT_MS, failure = slot.failure,
		}
		if slot.state == .Running {
			v.stages[id].elapsed_ms = time.duration_milliseconds(time.tick_since(slot.started))
		}
		v.stages[id].queued = running && id in w.run_set && slot.state != .Running && slot.state != .Complete
		v.stages[id].cancelled = !running && id in w.cancelled && slot.state == .Not_Run
	}
	sync.mutex_unlock(&s.lock)
	v.selected = w.selected
	v.running = running
	v.active = w.active_stage
	v.queued_edits = len(w.queued)
	return v
}

// Settings the stage owns, followed by the earlier-owned settings it reads.
workspace_settings :: proc(w: ^Workspace, id: Stage_Id, allocator := context.temp_allocator) -> []Setting_View {
	out := make([dynamic]Setting_View, 0, 16, allocator)
	for d in setting_descriptors {
		if d.owner != id {continue}
		append(&out, Setting_View{
			descriptor = d,
			value = slice_configuration_value(w.config, d.key),
			default_value = slice_configuration_value(w.defaults, d.key),
			editable = true,
		})
	}
	for d in setting_descriptors {
		if d.owner == id || id not_in d.also_read {continue}
		append(&out, Setting_View{
			descriptor = d,
			value = slice_configuration_value(w.config, d.key),
			default_value = slice_configuration_value(w.defaults, d.key),
			owner_name = stage_descriptors[d.owner].name,
		})
	}
	return out[:]
}

@(private = "file")
workspace_apply :: proc(w: ^Workspace, config: Slice_Configuration) {
	resolved, options, _, ok := slice_configuration_resolve(config)
	if !ok {return}
	before: [Stage_Id]Stage_State
	for id in Stage_Id {before[id] = w.session.slots[id].state}
	w.config = config
	slice_session_update(w.session, resolved, options)
	now := time.now()
	for id in Stage_Id {
		slot := w.session.slots[id]
		if slot.state == .Stale && before[id] != .Stale {
			stage_log_append(&w.logs[id], {kind = .Stale, at = now, cause = slot.changed_by})
		}
	}
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

// Copies the completed Klipper G-code bytes into `allocator` when the G-code stage is readable.
workspace_gcode_bytes :: proc(w: ^Workspace, allocator := context.allocator) -> ([]u8, bool) {
	if w == nil || w.session == nil {return nil, false}
	s := w.session
	sync.mutex_lock(&s.lock)
	defer sync.mutex_unlock(&s.lock)
	st := s.slots[.Gcode].state
	if (st != .Complete && st != .Stale) || len(s.klipper.bytes) == 0 {return nil, false}
	out := make([]u8, len(s.klipper.bytes), allocator)
	copy(out, s.klipper.bytes)
	return out, true
}

@(private = "file")
workspace_start :: proc(w: ^Workspace, target: Stage_Id) {
	pending := slice_session_pending(w.session, target)
	if pending == {} {return}
	sync.atomic_store(&w.running, true)
	sync.atomic_store(&w.cancel, false)
	w.active_stage = target
	w.run_set = pending
	w.cancelled = {}
	Run_Job :: struct {
		w:      ^Workspace,
		target: Stage_Id,
	}
	job := new(Run_Job)
	job^ = {w = w, target = target}
	t := thread.create(proc(t: ^thread.Thread) {
		// A thread started with a context gets its own temporary arena but must free it itself.
		defer if context.temp_allocator.procedure == runtime.default_temp_allocator_proc {
			runtime.default_temp_allocator_destroy(auto_cast context.temp_allocator.data)
		}
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
