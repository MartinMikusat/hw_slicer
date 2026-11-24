package pipeline

import "core:fmt"
import "core:math"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

import contracts "../contracts"
import features "../features"
import formats "../formats"
import gcode "../gcode"
import geometry "../geometry"
import polygon "../polygon"
import profiles "../profiles"
import repair "../repair"
import slicing "../slicing"

Stage_Slot :: struct {
	state:           Stage_State,
	// Hash of the settings and upstream stages that the current result was built from, and of
	// those that apply now. They differ exactly when the result is stale.
	built_hash:      contracts.Content_Hash,
	expected_hash:   contracts.Content_Hash,
	settings_hash:   contracts.Content_Hash,
	// The earliest stage whose settings changed since the result was built.
	changed_by:      Stage_Id,
	duration_ms:     f64,
	// When the current run of this stage began, while the state is Running.
	started:         time.Tick,
	count_a:         u64,
	count_b:         u64,
	failure:         Slice_Run_Error,
}

// A slice of one model whose stage results stay available after the run. Changing the profiles or
// options marks only the affected stages stale; a later run recomputes only those stages.
Slice_Session :: struct {
	allocator:         mem.Allocator,
	profile:           profiles.Resolved_Profiles,
	// The modifier and layer-list slices of the options belong to the caller and must outlive the
	// session.
	options:           Slice_Run_Options,
	source:            formats.Decoded_Mesh,
	// Guards the slots. A run holds it only while a stage changes state, never while it computes.
	lock:              sync.Mutex,
	slots:             [Stage_Id]Stage_Slot,

	mesh_repair_stats: repair.Mesh_Repair_Stats,
	mesh:              geometry.Canonical_Mesh,
	schedule:          slicing.Fixed_Layer_Schedule,
	layer_heights:     []contracts.Micrometres,
	span_index:        slicing.Layer_Span_Index,
	intersections:     slicing.CPU_Intersection_Result,
	primary_snapped:   slicing.Snapped_Segment_Result,
	planar_ownership:  slicing.Planar_Ownership_Result,
	snapped:           slicing.Snapped_Segment_Result,
	topology:          slicing.Topology_Result,
	simplified:        slicing.Topology_Result,
	has_simplified:    bool,
	repaired:          slicing.Topology_Result,
	has_repaired:      bool,
	contour_repairs:   u32,
	regions:           slicing.Region_Result,
	surfaces:          features.Surface_Result,
	skins:             features.Skin_Result,
	perimeters:        features.Perimeter_Result,
	bridge_evidence:   features.Bridge_Evidence_Result,
	bridge_directions: features.Bridge_Direction_Result,
	bridges:           features.Bridge_Path_Result,
	overlap:           features.Role_Overlap_Result,
	solids:            features.Solid_Path_Result,
	ironing:           features.Ironing_Result,
	infill:            features.Infill_Result,
	pattern_infill:    features.Infill_Pattern_Result,
	gaps:              features.Gap_Centerline_Result,
	supports:          features.Support_Path_Result,
	tree_supports:     features.Tree_Support_Result,
	support_footprint: polygon.Polygon_Set,
	adhesion:          features.Adhesion_Result,
	unified_plan:      features.Unified_Path_Plan_Result,
	extrusion:         features.Extrusion_Result,
	motion:            features.Motion_Plan_Result,
	time_estimate:     features.Print_Time_Estimate,
	klipper:           gcode.Klipper_Result,
}

slice_session_create :: proc(
	source: formats.Decoded_Mesh,
	profile: profiles.Resolved_Profiles,
	options: Slice_Run_Options,
	allocator := context.allocator,
) -> ^Slice_Session {
	s := new(Slice_Session, allocator)
	s.allocator = allocator
	s.source = decoded_mesh_clone(source, allocator)
	s.profile = profile
	s.options = options
	session_refresh(s)
	return s
}

slice_session_destroy :: proc(s: ^Slice_Session) {
	if s == nil {return}
	for id in Stage_Id {session_clear_stage(s, id)}
	formats.decoded_mesh_destroy(&s.source, s.allocator)
	allocator := s.allocator
	free(s, allocator)
}

// Replaces the profiles and options. Every stage whose inputs changed becomes stale and keeps its
// previous result until it is run again.
slice_session_update :: proc(
	s: ^Slice_Session,
	profile: profiles.Resolved_Profiles,
	options: Slice_Run_Options,
) {
	s.profile = profile
	s.options = options
	session_refresh(s)
}

slice_session_state :: proc(s: ^Slice_Session, id: Stage_Id) -> Stage_State {
	return s.slots[id].state
}

// Stages that are not complete among the target and the stages it needs.
slice_session_pending :: proc(s: ^Slice_Session, target: Stage_Id) -> Stage_Set {
	set: Stage_Set
	needed := stage_upstream(target)
	for id in Stage_Id {
		if id not_in needed {continue}
		if s.slots[id].state != .Complete {set += {id}}
	}
	return set
}

slice_session_run_all :: proc(s: ^Slice_Session) -> Slice_Run_Error {
	return slice_session_run_to(s, max(Stage_Id))
}

SLICE_RUN_CANCELLED :: "cancelled"

// Runs every incomplete stage among the target and the stages it needs. A stage that fails stops
// the run.
// A set cancel flag stops the run before the next stage and returns a SLICE_RUN_CANCELLED error.
slice_session_run_to :: proc(s: ^Slice_Session, target: Stage_Id, cancel: ^bool = nil) -> Slice_Run_Error {
	features.set_worker_threads(s.options.worker_threads)
	slicing.slicing_set_worker_threads(s.options.worker_threads)
	needed := stage_upstream(target)
	for id in Stage_Id {
		if id not_in needed {continue}
		slot := &s.slots[id]
		if slot.state == .Complete {continue}
		if cancel != nil && sync.atomic_load(cancel) {return {stage = SLICE_RUN_CANCELLED}}
		sync.mutex_lock(&s.lock)
		session_clear_stage(s, id)
		slot.state = .Running
		slot.started = time.tick_now()
		sync.mutex_unlock(&s.lock)
		start := time.tick_now()
		err := session_run_stage(s, id)
		elapsed := time.duration_seconds(time.tick_since(start)) * 1000.0
		sync.mutex_lock(&s.lock)
		defer sync.mutex_unlock(&s.lock)
		slot.duration_ms = elapsed
		if len(err.stage) > 0 {
			session_clear_stage(s, id)
			slot.state = .Failed
			slot.failure = {stage = strings.clone(err.stage, s.allocator), detail = strings.clone(err.detail, s.allocator)}
			return err
		}
		slot.state = .Complete
		slot.built_hash = slot.expected_hash
	}
	return {}
}

// Drops the result of one stage so that the next run recomputes it. The stages after it keep their
// results: the pipeline is deterministic, so the same inputs rebuild the same result.
slice_session_forget :: proc(s: ^Slice_Session, id: Stage_Id) {
	sync.mutex_lock(&s.lock)
	defer sync.mutex_unlock(&s.lock)
	session_clear_stage(s, id)
}

// Moves the finished results out of a fully run session, leaving the rest in place.
slice_session_take_result :: proc(s: ^Slice_Session) -> Slice_Run_Result {
	r: Slice_Run_Result
	r.spine = {
		mesh             = s.mesh,
		schedule         = s.schedule,
		span_index       = s.span_index,
		intersections    = s.intersections,
		primary_snapped  = s.primary_snapped,
		planar_ownership = s.planar_ownership,
		snapped          = s.snapped,
		topology         = s.topology,
	}
	s.mesh = {}
	s.schedule = {}
	s.span_index = {}
	s.intersections = {}
	s.primary_snapped = {}
	s.planar_ownership = {}
	s.snapped = {}
	s.topology = {}
	// The raw topology and the contour repair replace each other: the last one built is the active
	// topology, and the earlier ones are not needed once the regions exist.
	if s.has_repaired {
		r.repaired_topology = s.repaired
		r.has_repaired = true
		s.repaired = {}
		s.has_repaired = false
		if s.has_simplified {
			slicing.topology_result_destroy(&s.simplified, s.allocator)
			s.simplified = {}
			s.has_simplified = false
		}
	} else if s.has_simplified {
		r.repaired_topology = s.simplified
		r.has_repaired = true
		s.simplified = {}
		s.has_simplified = false
	}
	r.contour_repairs = s.contour_repairs
	r.regions = s.regions
	s.regions = {}
	r.unified_plan = s.unified_plan
	s.unified_plan = {}
	r.extrusion = s.extrusion
	s.extrusion = {}
	r.motion = s.motion
	s.motion = {}
	r.klipper = s.klipper
	s.klipper = {}
	r.validation = r.klipper.validation
	r.time_estimate = s.time_estimate
	r.mesh_repair_stats = s.mesh_repair_stats
	r.stages = make([dynamic]Stage_Trace, 0, len(Stage_Id), s.allocator)
	for id in Stage_Id {
		slot := s.slots[id]
		append(&r.stages, Stage_Trace{
			name = stage_descriptors[id].name,
			duration_ms = slot.duration_ms,
			count_a = slot.count_a,
			count_b = slot.count_b,
		})
		r.total_duration_ms += slot.duration_ms
	}
	return r
}

@(private = "file")
session_refresh :: proc(s: ^Slice_Session) {
	changed: [Stage_Id]bool
	causes: [Stage_Id]Stage_Id
	for id in Stage_Id {
		slot := &s.slots[id]
		settings := stage_settings_hash(id, s.profile, s.options)
		own_changed := settings != slot.settings_hash
		slot.settings_hash = settings
		h: contracts.Canonical_Hash
		contracts.canonical_hash_init(&h, "hw-slicer/stage-input", 1)
		contracts.canonical_hash_append_content_hash(&h, settings)
		if id == .Model {
			contracts.canonical_hash_append_content_hash(&h, s.source.source.content_hash)
		}
		cause := id
		has_cause := false
		for dep in Stage_Id {
			if dep not_in stage_descriptors[id].inputs {continue}
			contracts.canonical_hash_append_content_hash(&h, s.slots[dep].expected_hash)
			if changed[dep] && !has_cause {
				cause = causes[dep]
				has_cause = true
			}
		}
		if own_changed {has_cause = true}
		slot.expected_hash = contracts.canonical_hash_final(&h)
		if slot.state == .Complete && slot.built_hash != slot.expected_hash {
			slot.state = .Stale
			slot.changed_by = cause
		}
		if slot.state == .Stale && slot.built_hash == slot.expected_hash {
			slot.state = .Complete
		}
		if slot.state == .Failed && slot.built_hash != slot.expected_hash {
			slot.state = .Not_Run
		}
		if has_cause && slot.state == .Stale {slot.changed_by = cause}
		changed[id] = has_cause || slot.state == .Stale
		causes[id] = slot.changed_by if (slot.state == .Stale && !has_cause) else cause
	}
}

@(private = "file")
decoded_mesh_clone :: proc(m: formats.Decoded_Mesh, allocator: mem.Allocator) -> formats.Decoded_Mesh {
	return {
		source                = m.source,
		source_root_id        = m.source_root_id,
		vertex_x              = slice.clone(m.vertex_x, allocator),
		vertex_y              = slice.clone(m.vertex_y, allocator),
		vertex_z              = slice.clone(m.vertex_z, allocator),
		vertex_ids            = slice.clone(m.vertex_ids, allocator),
		triangle_a            = slice.clone(m.triangle_a, allocator),
		triangle_b            = slice.clone(m.triangle_b, allocator),
		triangle_c            = slice.clone(m.triangle_c, allocator),
		triangle_ids          = slice.clone(m.triangle_ids, allocator),
		source_record_offsets = slice.clone(m.source_record_offsets, allocator),
	}
}

@(private = "file")
session_provider :: proc(s: ^Slice_Session) -> polygon.Polygon_Provider {
	return polygon.NATIVE_PROVIDER if s.options.use_native_polygon else polygon.CLIPPER2_PROVIDER
}

// The topology that the regions and every later stage use: the contour repair when it ran, else the
// simplified contours, else the reconstructed ones.
session_active_topology :: proc(s: ^Slice_Session) -> slicing.Topology_Result {
	if s.has_repaired {return s.repaired}
	if s.has_simplified {return s.simplified}
	return s.topology
}

@(private = "file")
session_clear_stage :: proc(s: ^Slice_Session, id: Stage_Id) {
	a := s.allocator
	switch id {
	case .Model:
		geometry.canonical_mesh_destroy(&s.mesh, a)
	case .Layer_Schedule:
		slicing.fixed_layer_schedule_destroy(&s.schedule, a)
		delete(s.layer_heights, a)
		s.layer_heights = nil
	case .Intersections:
		slicing.snapped_segments_destroy(&s.snapped, a)
		slicing.planar_ownership_destroy(&s.planar_ownership, a)
		slicing.snapped_segments_destroy(&s.primary_snapped, a)
		slicing.cpu_intersections_destroy(&s.intersections, a)
		slicing.layer_span_index_destroy(&s.span_index, a)
	case .Topology:
		slicing.topology_result_destroy(&s.topology, a)
		if s.has_simplified {slicing.topology_result_destroy(&s.simplified, a)}
		s.simplified = {}
		s.has_simplified = false
	case .Regions:
		slicing.region_result_destroy(&s.regions, a)
		if s.has_repaired {slicing.topology_result_destroy(&s.repaired, a)}
		s.repaired = {}
		s.has_repaired = false
		s.contour_repairs = 0
	case .Surfaces_Skin:
		features.skin_result_destroy(&s.skins, a)
		features.surface_result_destroy(&s.surfaces, a)
	case .Perimeters:
		features.perimeter_result_destroy(&s.perimeters, a)
	case .Bridges:
		features.bridge_path_result_destroy(&s.bridges, a)
		features.bridge_direction_result_destroy(&s.bridge_directions, a)
		features.bridge_evidence_result_destroy(&s.bridge_evidence, a)
	case .Solid_Skin:
		features.ironing_result_destroy(&s.ironing, a)
		features.solid_path_result_destroy(&s.solids, a)
		features.role_overlap_result_destroy(&s.overlap, a)
	case .Sparse_Infill:
		features.infill_pattern_result_destroy(&s.pattern_infill, a)
		features.infill_result_destroy(&s.infill, a)
	case .Gap_Fill:
		features.gap_centerline_result_destroy(&s.gaps, a)
	case .Supports:
		features.adhesion_result_destroy(&s.adhesion, a)
		polygon.polygon_set_destroy(&s.support_footprint, a)
		features.tree_support_result_destroy(&s.tree_supports, a)
		features.support_path_result_destroy(&s.supports, a)
	case .Path_Plan:
		features.unified_path_plan_result_destroy(&s.unified_plan, a)
	case .Motion:
		features.motion_plan_result_destroy(&s.motion, a)
		features.extrusion_result_destroy(&s.extrusion, a)
		s.time_estimate = {}
	case .Gcode:
		gcode.klipper_result_destroy(&s.klipper, a)
	}
	slot := &s.slots[id]
	delete(slot.failure.stage, a)
	delete(slot.failure.detail, a)
	slot.failure = {}
	slot.state = .Not_Run
	slot.count_a = 0
	slot.count_b = 0
}

@(private = "file")
session_run_stage :: proc(s: ^Slice_Session, id: Stage_Id) -> Slice_Run_Error {
	switch id {
	case .Model:         return stage_model(s)
	case .Layer_Schedule: return stage_layer_schedule(s)
	case .Intersections: return stage_intersections(s)
	case .Topology:      return stage_topology(s)
	case .Regions:       return stage_regions(s)
	case .Surfaces_Skin: return stage_surfaces_skin(s)
	case .Perimeters:    return stage_perimeters(s)
	case .Bridges:       return stage_bridges(s)
	case .Solid_Skin:    return stage_solid_skin(s)
	case .Sparse_Infill: return stage_sparse_infill(s)
	case .Gap_Fill:      return stage_gap_fill(s)
	case .Supports:      return stage_supports(s)
	case .Path_Plan:     return stage_path_plan(s)
	case .Motion:        return stage_motion(s)
	case .Gcode:         return stage_gcode(s)
	}
	return {}
}

@(private = "file")
spine_config :: proc(s: ^Slice_Session) -> Slice_Spine_Config {
	src := s.profile.process.source
	return {
		source_units        = s.options.source_units,
		first_layer_height  = src.first_layer_height,
		layer_height        = src.layer_height,
		max_layer_count     = s.options.max_layer_count,
		adaptive_layers     = s.options.adaptive_layers,
		min_adaptive_height = s.profile.printer.minimum_layer_height,
		max_adaptive_height = s.profile.printer.maximum_layer_height,
		fast_headless       = true,
	}
}

@(private = "file")
spine_error :: proc(err: Slice_Spine_Error) -> Slice_Run_Error {
	return {stage = "slice_spine", detail = fmt.tprintf("spine error: %v", err)}
}

@(private = "file")
stage_model :: proc(s: ^Slice_Session) -> Slice_Run_Error {
	a := s.allocator
	work := decoded_mesh_clone(s.source, a)
	defer formats.decoded_mesh_destroy(&work, a)
	s.mesh_repair_stats = {}
	if s.options.mesh_auto_repair {
		s.mesh_repair_stats = repair.mesh_auto_repair(&work, a)
	}
	if s.options.center_on_bed {center_decoded_on_bed(&work, s.profile.printer)}
	mesh, err := geometry.mesh_normalize_units(work, a)
	if err != .None {return spine_error(.Normalize)}
	s.mesh = mesh
	s.slots[.Model].count_a = u64(len(s.mesh.triangle_ids))
	return {}
}

@(private = "file")
stage_layer_schedule :: proc(s: ^Slice_Session) -> Slice_Run_Error {
	a := s.allocator
	config := spine_config(s)
	request_hash := slice_spine_request_hash(s.source.source, config)
	minimum_z, minimum_error := geometry.millimetres_to_micrometres_quantized(s.mesh.bounds.minimum.z, .Floor)
	maximum_z, maximum_error := geometry.millimetres_to_micrometres_quantized(s.mesh.bounds.maximum.z, .Ceil)
	if minimum_error != .None || maximum_error != .None {return spine_error(.Schedule)}
	schedule_error: slicing.Schedule_Error
	if config.adaptive_layers {
		min_ah := config.min_adaptive_height if i64(config.min_adaptive_height) > 0 else contracts.Micrometres(80)
		max_ah := config.max_adaptive_height if i64(config.max_adaptive_height) > 0 else contracts.Micrometres(280)
		s.schedule, schedule_error = slicing.adaptive_layer_schedule_build(
			s.mesh,
			{
				request_hash       = request_hash,
				first_layer_height = config.first_layer_height,
				min_layer_height   = min_ah,
				max_layer_height   = max_ah,
				nominal_height     = config.layer_height,
				max_layer_count    = config.max_layer_count,
				smooth_passes      = 3,
			},
			a,
		)
	} else {
		s.schedule, schedule_error = slicing.fixed_layer_schedule_build(
			{
				request_hash       = request_hash,
				minimum_z          = minimum_z,
				maximum_z          = maximum_z,
				first_layer_height = config.first_layer_height,
				layer_step         = config.layer_height,
				max_layer_count    = config.max_layer_count,
			},
			a,
		)
	}
	if schedule_error != .None {return spine_error(.Schedule)}

	proc_src := s.profile.process.source
	layer_count := len(s.schedule.layer_ids)
	s.layer_heights = make([]contracts.Micrometres, layer_count, a)
	for i in 0..<layer_count {
		if s.options.adaptive_layers {
			prev_z := i64(s.schedule.minimum_z) if i == 0 else i64(s.schedule.print_z[i-1])
			dz := i64(s.schedule.print_z[i]) - prev_z
			s.layer_heights[i] = contracts.Micrometres(max(i64(10), dz))
		} else {
			s.layer_heights[i] = proc_src.first_layer_height if i == 0 else proc_src.layer_height
		}
	}
	s.slots[.Layer_Schedule].count_a = u64(layer_count)
	return {}
}

@(private = "file")
stage_intersections :: proc(s: ^Slice_Session) -> Slice_Run_Error {
	a := s.allocator
	span_error: slicing.Layer_Span_Error
	s.span_index, span_error = slicing.layer_span_index_build(s.mesh, s.schedule, allocator = a)
	if span_error != .None {return spine_error(.Layer_Spans)}
	intersection_error: slicing.CPU_Intersection_Error
	s.intersections, intersection_error = slicing.cpu_intersections_build(s.mesh, s.schedule, s.span_index, allocator = a)
	if intersection_error != .None {return spine_error(.Intersections)}
	snap_error: slicing.Snapped_Segment_Error
	s.primary_snapped, snap_error = slicing.snapped_segments_build(s.intersections, a)
	if snap_error != .None {return spine_error(.Snap)}
	planar_error: slicing.Planar_Ownership_Error
	s.planar_ownership, planar_error = slicing.planar_ownership_resolve(s.mesh, s.schedule, s.intersections, allocator = a)
	if planar_error != .None {return spine_error(.Planar_Ownership)}
	owned_segments := slicing.Snapped_Segment_Result{
		layers   = s.planar_ownership.layers,
		segments = s.planar_ownership.segments,
	}
	s.snapped, snap_error = slicing.snapped_segments_merge(s.primary_snapped, owned_segments, a)
	if snap_error != .None {return spine_error(.Merge)}
	s.slots[.Intersections].count_a = u64(len(s.snapped.segments.segment_ids))
	return {}
}

@(private = "file")
stage_topology :: proc(s: ^Slice_Session) -> Slice_Run_Error {
	a := s.allocator
	topology_error: slicing.Topology_Error
	s.topology, topology_error = slicing.topology_reconstruct(s.schedule, s.snapped, allocator = a)
	if topology_error != .None {return spine_error(.Topology)}
	if s.options.contour_simplify_tolerance_um > 0.0 {
		if simplified, ok := slicing.topology_simplify_contours(s.topology, s.options.contour_simplify_tolerance_um, a); ok {
			s.simplified = simplified
			s.has_simplified = true
		}
	}
	s.slots[.Topology].count_a = u64(len(session_active_topology(s).paths))
	return {}
}

@(private = "file")
stage_regions :: proc(s: ^Slice_Session) -> Slice_Run_Error {
	a := s.allocator
	provider := session_provider(s)
	for {
		active := session_active_topology(s)
		failure: slicing.Region_Failure
		reg_err: slicing.Region_Error
		s.regions, reg_err = slicing.regions_build(active, allocator = a, failure = &failure)
		if reg_err == .None {break}
		if reg_err == .Contour_Intersection && s.contour_repairs < s.options.max_contour_repairs {
			rep, rep_err := repair.contour_path_repair(
				active,
				provider,
				{failure = failure, fill_rule = .Non_Zero, lineage_tolerance = 50},
				allocator = a,
			)
			if rep_err != .None {
				return {stage = "contour_repair", detail = fmt.tprintf("repair error: %v (layer %d)", rep_err, failure.layer_index)}
			}
			next_topo, apply_err := repair.contour_repair_apply_for_regions(active, rep, a)
			repair.contour_repair_result_destroy(&rep, a)
			if apply_err != .None {
				return {stage = "contour_repair_apply", detail = fmt.tprintf("apply error: %v", apply_err)}
			}
			if s.has_repaired {slicing.topology_result_destroy(&s.repaired, a)}
			s.repaired = next_topo
			s.has_repaired = true
			s.contour_repairs += 1
			continue
		}
		return {stage = "regions", detail = fmt.tprintf("regions error: %v (layer %d, repairs=%d)", reg_err, failure.layer_index, s.contour_repairs)}
	}
	s.slots[.Regions].count_a = u64(len(s.regions.regions))
	s.slots[.Regions].count_b = u64(s.contour_repairs)
	return {}
}

@(private = "file")
stage_surfaces_skin :: proc(s: ^Slice_Session) -> Slice_Run_Error {
	a := s.allocator
	proc_src := s.profile.process.source
	provider := session_provider(s)
	active := session_active_topology(s)
	err: features.Surface_Error
	s.surfaces, err = features.surfaces_classify(
		active,
		s.regions,
		provider,
		{fill_rule = .Non_Zero, topology_policy = .Diagnostic_Closed_Regions},
		allocator = a,
	)
	if err != .None {return {stage = "surfaces", detail = fmt.tprintf("surfaces error: %v", err)}}
	skin_err: features.Skin_Error
	s.skins, skin_err = features.skins_propagate(
		active,
		s.regions,
		s.surfaces,
		s.layer_heights,
		provider,
		{fill_rule = .Non_Zero, top = proc_src.top_skin, bottom = proc_src.bottom_skin, skip_source_filtering = true},
		allocator = a,
	)
	if skin_err != .None {return {stage = "skins", detail = fmt.tprintf("skins error: %v", skin_err)}}
	s.slots[.Surfaces_Skin].count_a = u64(len(s.surfaces.masks))
	s.slots[.Surfaces_Skin].count_b = u64(len(s.skins.masks))
	return {}
}

@(private = "file")
stage_perimeters :: proc(s: ^Slice_Session) -> Slice_Run_Error {
	proc_src := s.profile.process.source
	err: features.Perimeter_Error
	s.perimeters, err = features.perimeters_generate(
		session_active_topology(s),
		s.regions,
		session_provider(s),
		{
			count                = proc_src.perimeter_count,
			line_width           = proc_src.nominal_line_width,
			first_layer_inset_um = s.options.elephant_foot_compensation_um,
			topology_policy      = .Diagnostic_Closed_Regions,
			join_type            = .Miter,
			miter_limit          = 2.0,
			arc_tolerance        = 0.0,
		},
		allocator = s.allocator,
	)
	if err != .None {return {stage = "perimeters", detail = fmt.tprintf("perimeters error: %v", err)}}
	s.slots[.Perimeters].count_a = u64(len(s.perimeters.paths))
	return {}
}

@(private = "file")
stage_bridges :: proc(s: ^Slice_Session) -> Slice_Run_Error {
	a := s.allocator
	process := s.profile.process
	provider := session_provider(s)
	active := session_active_topology(s)
	ev_err: features.Bridge_Evidence_Error
	s.bridge_evidence, ev_err = features.bridge_evidence_build(
		active,
		s.regions,
		process,
		provider,
		{fill_rule = .Non_Zero, join_type = .Miter, miter_limit = 2.0, arc_tolerance = 0.0},
		allocator = a,
	)
	if ev_err != .None {return {stage = "bridge_evidence", detail = fmt.tprintf("bridge evidence error: %v", ev_err)}}
	dir_err: features.Bridge_Direction_Error
	s.bridge_directions, dir_err = features.bridge_directions_score(
		active,
		s.regions,
		s.bridge_evidence,
		process,
		provider,
		allocator = a,
	)
	if dir_err != .None {return {stage = "bridge_directions", detail = fmt.tprintf("bridge directions error: %v", dir_err)}}
	path_err: features.Bridge_Path_Error
	s.bridges, path_err = features.bridge_paths_generate(s.bridge_evidence, s.bridge_directions, process, allocator = a)
	if path_err != .None {return {stage = "bridge_paths", detail = fmt.tprintf("bridge paths error: %v", path_err)}}
	s.slots[.Bridges].count_a = u64(len(s.bridge_evidence.masks))
	s.slots[.Bridges].count_b = u64(len(s.bridges.paths))
	return {}
}

@(private = "file")
stage_solid_skin :: proc(s: ^Slice_Session) -> Slice_Run_Error {
	a := s.allocator
	process := s.profile.process
	proc_src := process.source
	provider := session_provider(s)
	active := session_active_topology(s)
	layer_count := len(s.schedule.layer_ids)

	overlap_sources, owned_overlap_sets := make_role_overlap_sources(s.schedule.layer_ids, s.bridge_evidence, s.skins, a)
	defer {
		for &oset in owned_overlap_sets {polygon.polygon_set_destroy(&oset, a)}
		delete(owned_overlap_sets)
		delete(overlap_sources, a)
	}
	// Vertical shell thickness: solid bands under sloped surfaces join the skin sources; overlap
	// resolution removes what the skins already cover.
	vertical_shells: features.Vertical_Shell_Result
	defer features.vertical_shell_result_destroy(&vertical_shells, a)
	if s.options.ensure_vertical_shells {
		shell_model_sets := build_model_polygon_sets(active, s.regions, a)
		defer destroy_model_polygon_sets(shell_model_sets, a)
		vertical_shells = features.vertical_shells_build(
			shell_model_sets,
			contracts.Micrometres(i64(proc_src.perimeter_count)*i64(proc_src.nominal_line_width)),
			proc_src.nominal_line_width,
			proc_src.top_skin.minimum_layers,
			proc_src.bottom_skin.minimum_layers,
			provider,
			a,
		)
		extended := make([dynamic]features.Role_Overlap_Source, 0, len(overlap_sources) + 2*layer_count, a)
		append(&extended, ..overlap_sources)
		for li in 0..<layer_count {
			layer_id := s.schedule.layer_ids[li]
			for band, side in ([2]polygon.Polygon_Set{vertical_shells.top[li], vertical_shells.bottom[li]}) {
				if len(band.paths) == 0 || polygon_set_total_area_2(band) <= 0 {continue}
				if _, ok := polygon.polygon_set_hash(band); !ok {continue}
				append(&extended, features.Role_Overlap_Source{
					stable_id   = contracts.stable_id_child(layer_id, .Feature, u64(1)<<58 | u64(side)),
					layer_id    = layer_id,
					layer_index = u32(li),
					role        = .Top_Skin if side == 0 else .Bottom_Skin,
					geometry    = band,
				})
			}
		}
		delete(overlap_sources, a)
		overlap_sources = extended[:]
	}
	ov_err: features.Role_Overlap_Error
	s.overlap, ov_err = features.role_overlap_resolve(
		s.schedule.layer_ids,
		overlap_sources,
		process,
		provider,
		.Non_Zero,
		allocator = a,
	)
	if ov_err != .None {return {stage = "role_overlap", detail = fmt.tprintf("role overlap error: %v", ov_err)}}
	sol_err: features.Solid_Path_Error
	s.solids, sol_err = features.solid_paths_generate(s.overlap, process, provider, allocator = a)
	if sol_err != .None {return {stage = "solid_paths", detail = fmt.tprintf("solid paths error: %v", sol_err)}}
	if s.options.monotonic_skin {
		features.solid_paths_sort_monotonic(&s.solids)
	}
	max_lh := max(proc_src.first_layer_height, proc_src.layer_height)
	s.ironing = features.ironing_paths_generate(
		s.overlap,
		{
			enabled      = s.options.ironing_enabled,
			spacing_um   = s.options.ironing_spacing_um,
			flow_percent = s.options.ironing_flow_percent,
			line_width   = proc_src.nominal_line_width,
			min_width_um = max_lh,
		},
		a,
	)
	s.slots[.Solid_Skin].count_a = u64(len(s.solids.paths))
	s.slots[.Solid_Skin].count_b = u64(len(s.ironing.paths))
	return {}
}

@(private = "file")
stage_sparse_infill :: proc(s: ^Slice_Session) -> Slice_Run_Error {
	a := s.allocator
	proc_src := s.profile.process.source
	layer_count := len(s.schedule.layer_ids)
	// Density is a volume fraction. A line deposits a rounded cross-section of
	// w*h - (1 - pi/4)*h^2, so rows of straight lines at spacing (w - (1 - pi/4)*h) / density fill
	// that fraction. Patterns with longer rows (gyroid) widen this spacing themselves.
	density := clamp(s.options.infill_density_percent, 1.0, 100.0)
	effective_width := f64(i64(proc_src.nominal_line_width)) - (1.0 - math.PI/4.0)*f64(i64(proc_src.layer_height))
	infill_spacing := contracts.Micrometres(max(i64(proc_src.nominal_line_width), i64(math.round(effective_width*100.0/density))))
	infill_inset := contracts.Micrometres(i64(proc_src.perimeter_count)*i64(proc_src.nominal_line_width))
	// Sparse infill fills the region minus the solid (skin and bridge) areas of its layer.
	solid_areas := role_overlap_layer_sets(s.overlap, layer_count, a)
	defer {
		for &set in solid_areas {polygon.polygon_set_destroy(&set, a)}
		delete(solid_areas, a)
	}
	s.infill.layers = make([]features.Infill_Layer, layer_count, a)
	// Zero density (spiral vase or an explicit 0%) prints no sparse infill.
	if s.options.infill_density_percent > 0 {
		s.pattern_infill = features.infill_pattern_generate(
			session_active_topology(s),
			s.regions,
			s.skins,
			s.schedule.print_z,
			session_provider(s),
			{
				pattern        = s.options.infill_pattern,
				spacing_um     = infill_spacing,
				line_width_um  = proc_src.nominal_line_width,
				boundary_inset = infill_inset,
				worker_threads = s.options.worker_threads,
			},
			a,
			solid_areas,
		)
		s.slots[.Sparse_Infill].count_a = u64(len(s.pattern_infill.paths))
		s.slots[.Sparse_Infill].count_b = u64(infill_spacing)
	}
	return {}
}

@(private = "file")
stage_gap_fill :: proc(s: ^Slice_Session) -> Slice_Run_Error {
	a := s.allocator
	process := s.profile.process
	proc_src := process.source
	provider := session_provider(s)
	gap_ev, gev_err := features.gap_evidence_build(
		session_active_topology(s),
		s.regions,
		s.perimeters,
		provider,
		{
			fill_rule          = .Non_Zero,
			minimum_line_width = process.thin_wall_minimum_width,
			maximum_line_width = process.thin_wall_maximum_width,
			join_type          = .Miter,
			miter_limit        = 2.0,
			arc_tolerance      = 0.0,
			uncovered_only     = true,
		},
		allocator = a,
	)
	if gev_err != .None {return {stage = "gap_evidence", detail = fmt.tprintf("gap evidence error: %v", gev_err)}}
	defer features.gap_evidence_result_destroy(&gap_ev, a)
	gap_samp, gs_err := features.gap_samples_build(
		gap_ev,
		process,
		{spacing = proc_src.nominal_line_width, phase = 0},
		allocator = a,
	)
	if gs_err != .None {return {stage = "gap_samples", detail = fmt.tprintf("gap samples error: %v", gs_err)}}
	defer features.gap_sample_result_destroy(&gap_samp, a)
	gc_err: features.Gap_Centerline_Error
	s.gaps, gc_err = features.gap_centerlines_build(gap_ev, gap_samp, 2, allocator = a)
	if gc_err != .None {return {stage = "gap_centerlines", detail = fmt.tprintf("gap centerlines error: %v", gc_err)}}
	s.slots[.Gap_Fill].count_a = u64(len(s.gaps.paths))
	s.slots[.Gap_Fill].count_b = u64(len(s.gaps.vertices))
	return {}
}

@(private = "file")
stage_supports :: proc(s: ^Slice_Session) -> Slice_Run_Error {
	a := s.allocator
	process := s.profile.process
	proc_src := process.source
	provider := session_provider(s)
	active := session_active_topology(s)
	layer_count := len(s.schedule.layer_ids)
	options := s.options
	tree := options.enable_supports && options.support_style_tree

	if tree {
		s.supports.pattern = proc_src.support_pattern
		s.supports.line_width = proc_src.nominal_line_width
		s.supports.layers = make([]features.Support_Path_Layer, layer_count, a)
		model_sets := build_model_polygon_sets(active, s.regions, a)
		defer destroy_model_polygon_sets(model_sets, a)
		s.tree_supports = features.tree_supports_generate(
			active,
			s.regions,
			model_sets,
			s.schedule.print_z,
			{
				overhang_angle_deg  = f64(i32(proc_src.support_overhang_angle)) / 1000.0,
				branch_angle_deg    = 45.0,
				tip_radius_um       = 800,
				trunk_max_radius_um = 6_000,
				tip_spacing_um      = 4_000,
				xy_clearance_um     = proc_src.support_clearance_xy,
				interface_layers    = proc_src.support_interface_layers,
				line_width_um       = proc_src.nominal_line_width,
				bed_min_x           = s.profile.printer.axis_minimum_x,
				bed_max_x           = s.profile.printer.axis_maximum_x,
				bed_min_y           = s.profile.printer.axis_minimum_y,
				bed_max_y           = s.profile.printer.axis_maximum_y,
			},
			a,
		)
	} else if options.enable_supports {
		sup_faces, sf_err := features.support_faces_classify(s.mesh, process, allocator = a)
		if sf_err != .None {return {stage = "support_faces", detail = fmt.tprintf("support faces error: %v", sf_err)}}
		defer features.support_face_result_destroy(&sup_faces, a)
		sup_demand, sd_err := features.support_demand_build(
			s.schedule,
			active,
			s.regions,
			sup_faces,
			process,
			provider,
			{fill_rule = .Non_Zero, join_type = .Miter, miter_limit = 2.0, arc_tolerance = 0.0},
			allocator = a,
		)
		if sd_err != .None {return {stage = "support_demand", detail = fmt.tprintf("support demand error: %v", sd_err)}}
		defer features.support_demand_result_destroy(&sup_demand, a)
		sup_geom, sg_err := features.support_geometry_build(
			s.schedule,
			active,
			s.regions,
			sup_demand,
			process,
			provider,
			allocator = a,
		)
		if sg_err != .None {return {stage = "support_geometry", detail = fmt.tprintf("support geometry error: %v", sg_err)}}
		defer features.support_geometry_result_destroy(&sup_geom, a)
		if len(sup_geom.layers) > 0 {
			layer0 := sup_geom.layers[0]
			footprint_points := make([dynamic]polygon.Polygon_Point, 0, 64, a)
			footprint_paths := make([dynamic]polygon.Polygon_Path, 0, 8, a)
			for mask in sup_geom.masks[layer0.mask_offset:layer0.mask_offset+u64(layer0.mask_count)] {
				for path in sup_geom.paths[mask.path_offset:mask.path_offset+u64(mask.path_count)] {
					append(&footprint_paths, polygon.Polygon_Path{offset = u64(len(footprint_points)), count = u64(path.point_count)})
					append(&footprint_points, ..sup_geom.points[path.point_offset:path.point_offset+u64(path.point_count)])
				}
			}
			s.support_footprint = {points = footprint_points[:], paths = footprint_paths[:]}
		}
		sp_err: features.Support_Path_Error
		s.supports, sp_err = features.support_paths_generate(sup_geom, process, provider, allocator = a)
		if sp_err != .None {return {stage = "support_paths", detail = fmt.tprintf("support paths error: %v", sp_err)}}
	} else {
		s.supports.pattern = proc_src.support_pattern
		s.supports.line_width = proc_src.nominal_line_width
		s.supports.layers = make([]features.Support_Path_Layer, layer_count, a)
	}
	sup_count := u64(len(s.tree_supports.paths)) if tree else u64(len(s.supports.paths))
	s.slots[.Supports].count_a = sup_count
	s.slots[.Supports].count_b = 2 if tree else (1 if options.enable_supports else 0)

	if tree {
		footprint_points := make([dynamic]polygon.Polygon_Point, 0, 64, a)
		footprint_paths := make([dynamic]polygon.Polygon_Path, 0, 8, a)
		for path in s.tree_supports.paths {
			if path.layer_index != 0 {continue}
			append(&footprint_paths, polygon.Polygon_Path{offset = u64(len(footprint_points)), count = u64(len(path.points))})
			append(&footprint_points, ..path.points)
		}
		s.support_footprint = {points = footprint_points[:], paths = footprint_paths[:]}
	}
	// Skirt and brim, built after supports so the skirt surrounds the first-layer supports.
	s.adhesion = features.adhesion_build(
		provider,
		active,
		s.regions,
		{
			skirt_loops                   = options.skirt_loops,
			skirt_distance_um             = options.skirt_distance_um,
			skirt_height_layers           = options.skirt_height_layers,
			brim_width_um                 = options.brim_width_um,
			brim_gap_um                   = options.brim_gap_um,
			brim_inner                    = options.brim_inner,
			elephant_foot_compensation_um = options.elephant_foot_compensation_um,
			line_width_um                 = proc_src.nominal_line_width,
			bed_min_x                     = s.profile.printer.axis_minimum_x,
			bed_max_x                     = s.profile.printer.axis_maximum_x,
			bed_min_y                     = s.profile.printer.axis_minimum_y,
			bed_max_y                     = s.profile.printer.axis_maximum_y,
		},
		allocator = a,
		support_footprint = s.support_footprint,
	)
	return {}
}

@(private = "file")
stage_path_plan :: proc(s: ^Slice_Session) -> Slice_Run_Error {
	a := s.allocator
	process := s.profile.process
	proc_src := process.source
	options := s.options
	layer_ids := s.schedule.layer_ids
	max_lh := max(proc_src.first_layer_height, proc_src.layer_height)

	u_sources, us_err := features.unified_path_sources_build(
		layer_ids,
		s.perimeters,
		s.bridges,
		s.gaps,
		s.solids,
		s.infill,
		s.supports,
		process,
		options.inner_perimeters_first,
		allocator = a,
	)
	if us_err != .None {return {stage = "unified_sources", detail = fmt.tprintf("unified sources error: %v", us_err)}}
	defer features.unified_path_source_result_destroy(&u_sources, a)
	// Inject adhesion loops (skirt & brim), custom pattern infill, and top-surface ironing passes.
	all_sources := make(
		[dynamic]features.Unified_Path_Source,
		0,
		len(u_sources.sources) + len(s.adhesion.loops) + len(s.pattern_infill.paths) + len(s.ironing.paths),
		a,
	)
	defer delete(all_sources)
	for loop, li in s.adhesion.loops {
		if int(loop.layer_index) >= len(layer_ids) {continue}
		layer_id := layer_ids[loop.layer_index]
		append(&all_sources, features.Unified_Path_Source{
			stable_id    = contracts.stable_id_child(layer_id, .Feature, u64(1)<<62 | u64(li)),
			layer_id     = layer_id,
			layer_index  = loop.layer_index,
			role         = .Perimeter,
			source_kind  = .Adhesion,
			source_index = u32(li),
			source_order = u64(li),
			closed       = true,
			points       = loop.points,
			line_widths  = loop.line_widths,
		})
	}
	for src in u_sources.sources {
		append(&all_sources, src)
	}
	for ip, pi in s.pattern_infill.paths {
		if int(ip.layer_index) >= len(layer_ids) {continue}
		layer_id := layer_ids[ip.layer_index]
		append(&all_sources, features.Unified_Path_Source{
			stable_id    = contracts.stable_id_child(layer_id, .Feature, u64(1)<<61 | u64(pi)),
			layer_id     = layer_id,
			layer_index  = ip.layer_index,
			role         = .Sparse_Infill,
			source_kind  = .Sparse_Infill,
			source_index = u32(pi),
			source_order = u64(pi),
			closed       = false,
			points       = ip.points,
			line_widths  = ip.line_widths,
		})
	}
	for ir, ii in s.ironing.paths {
		if int(ir.layer_index) >= len(layer_ids) {continue}
		layer_id := layer_ids[ir.layer_index]
		append(&all_sources, features.Unified_Path_Source{
			stable_id    = contracts.stable_id_child(layer_id, .Feature, u64(1)<<60 | u64(ii)),
			layer_id     = layer_id,
			layer_index  = ir.layer_index,
			role         = .Top_Skin,
			source_kind  = .Solid,
			source_index = u32(ii),
			source_order = (u64(1) << 40) + u64(ii),
			closed       = false,
			points       = ir.points,
			line_widths  = ir.line_widths,
		})
	}
	for tp, ti in s.tree_supports.paths {
		if int(tp.layer_index) >= len(layer_ids) {continue}
		layer_id := layer_ids[tp.layer_index]
		append(&all_sources, features.Unified_Path_Source{
			stable_id    = contracts.stable_id_child(layer_id, .Feature, u64(1)<<59 | u64(ti)),
			layer_id     = layer_id,
			layer_index  = tp.layer_index,
			role         = .Support_Interface if tp.is_interface else .Support,
			source_kind  = .Support,
			source_index = u32(ti),
			source_order = u64(ti),
			closed       = true,
			points       = tp.points,
			line_widths  = tp.line_widths,
		})
	}
	if options.variable_walls_enabled {
		_ = features.variable_walls_adapt(all_sources[:], {
			enabled          = true,
			nominal_width_um = proc_src.nominal_line_width,
			min_width_um     = max(max_lh, contracts.Micrometres((i64(proc_src.nominal_line_width)*65)/100)),
		})
	}
	fuzzy_owned_pts := make([dynamic][]polygon.Polygon_Point, 0, 16, a)
	fuzzy_owned_ws := make([dynamic][]contracts.Micrometres, 0, 16, a)
	defer {
		for p in fuzzy_owned_pts {delete(p, a)}
		for w in fuzzy_owned_ws {delete(w, a)}
		delete(fuzzy_owned_pts)
		delete(fuzzy_owned_ws)
	}
	if options.fuzzy_skin_enabled {
		_ = features.fuzzy_skin_apply(
			all_sources[:],
			s.perimeters,
			{
				enabled       = true,
				thickness_um  = options.fuzzy_thickness_um,
				point_dist_um = options.fuzzy_point_dist_um,
			},
			s.profile.printer,
			&fuzzy_owned_pts,
			&fuzzy_owned_ws,
			a,
		)
	}
	// Guarantee every extrusion vertex meets rounded-bead invariant (line_width >= layer_height).
	for &src in all_sources {
		if int(src.layer_index) >= len(s.layer_heights) {continue}
		lh := s.layer_heights[src.layer_index]
		for wi in 0..<len(src.line_widths) {
			if i64(src.line_widths[wi]) < i64(lh) {
				src.line_widths[wi] = lh
			}
		}
	}
	plan_err: features.Unified_Path_Plan_Error
	s.unified_plan, plan_err = features.unified_path_plan_build(
		layer_ids,
		all_sources[:],
		{
			start           = options.plan_start if options.has_plan_start else {x = s.profile.printer.axis_minimum_x, y = s.profile.printer.axis_minimum_y},
			seam            = proc_src.seam,
			seam_visibility = proc_src.seam_visibility,
			seam_strategy   = options.seam_strategy,
		},
		allocator = a,
	)
	if plan_err != .None {return {stage = "unified_path_plan", detail = fmt.tprintf("unified path plan error: %v", plan_err)}}
	s.slots[.Path_Plan].count_a = s.unified_plan.extrude_move_count
	s.slots[.Path_Plan].count_b = s.unified_plan.travel_move_count
	return {}
}

@(private = "file")
stage_motion :: proc(s: ^Slice_Session) -> Slice_Run_Error {
	a := s.allocator
	process := s.profile.process
	proc_src := process.source
	options := s.options
	ext_err: features.Extrusion_Error
	s.extrusion, ext_err = features.extrusion_calculate(s.unified_plan, s.layer_heights, s.profile.material, process, allocator = a)
	if ext_err != .None {return {stage = "extrusion", detail = fmt.tprintf("extrusion error: %v", ext_err)}}
	model_sets := build_model_polygon_sets(session_active_topology(s), s.regions, a)
	defer destroy_model_polygon_sets(model_sets, a)
	mot_err: features.Motion_Plan_Error
	s.motion, mot_err = features.motion_plan_build(
		s.schedule.layer_ids,
		s.schedule.print_z,
		model_sets,
		s.unified_plan,
		s.extrusion,
		s.profile,
		allocator = a,
		options = {
			wipe_distance_um          = options.wipe_distance_um,
			overhang_slowdown_enabled = options.overhang_slowdown_enabled,
			overhang_speed_percent    = options.overhang_speed_percent,
			use_gpu                   = options.use_gpu,
			worker_threads            = options.worker_threads,
		},
	)
	if mot_err != .None {return {stage = "motion_plan", detail = fmt.tprintf("motion plan error: %v", mot_err)}}
	// Scarf seam / spiral vase Z ramps run on linear segments before arc fitting, which leaves the
	// ramped moves linear and fits arcs to the rest.
	if options.scarf_seam_enabled || options.vase_mode {
		_ = features.motion_plan_apply_z_ramps(
			&s.motion,
			s.layer_heights,
			{enabled = options.scarf_seam_enabled, length_um = options.scarf_length_um, start_height_pct = 10},
			options.vase_mode,
			proc_src.bottom_skin.minimum_layers,
			proc_src,
			s.unified_plan,
			s.perimeters,
		)
	}
	// G2/G3 circular arc fitting of moves without a Z offset.
	if options.arc_fitting_enabled && !options.vase_mode {
		arc_cfg := features.DEFAULT_ARC_FIT_CONFIG
		if options.arc_tolerance_um > 0 {arc_cfg.max_chord_error_um = options.arc_tolerance_um}
		arc_stats := features.motion_plan_fit_arcs(&s.motion, s.profile.printer, arc_cfg, a)
		s.slots[.Motion].count_b = arc_stats.arcs_fitted
	}
	if len(options.modifiers) > 0 {
		_ = modifiers_apply_motion(&s.motion, options.modifiers, s.profile)
	}
	s.time_estimate = features.motion_plan_estimate_klipper_time(s.motion)
	s.slots[.Motion].count_a = u64(len(s.motion.operations))
	return {}
}

@(private = "file")
stage_gcode :: proc(s: ^Slice_Session) -> Slice_Run_Error {
	klip_err: gcode.Klipper_Error
	s.klipper, klip_err = gcode.klipper_emit(
		s.motion,
		s.profile,
		allocator = s.allocator,
		object_name = s.options.object_name,
		pause_layers = s.options.pause_layers,
		color_change_layers = s.options.color_change_layers,
	)
	if klip_err != .None {return {stage = "klipper_emit", detail = fmt.tprintf("klipper emit error: %v", klip_err)}}
	s.slots[.Gcode].count_a = u64(len(s.klipper.bytes))
	s.slots[.Gcode].count_b = u64(len(s.klipper.commands))
	return {}
}
