package pipeline

import "core:encoding/hex"
import "core:fmt"
import "core:mem"
import "core:strings"

import contracts "../contracts"
import evidence "../evidence"
import features "../features"
import gcode "../gcode"
import profiles "../profiles"
import slicing "../slicing"

@(private = "file")
evidence_stage_schema_version :: proc(kind: contracts.Stage_Kind) -> u32 {
	#partial switch kind {
	case .Schedule_Layers:
		return slicing.SCHEMA_VERSION_FIXED_LAYER_SCHEDULE_HASH
	case .Calculate_Regions:
		return slicing.SCHEMA_VERSION_REGION_HASH
	}
	return contracts.SCHEMA_VERSION_STAGE_RESULT
}

@(private = "file")
evidence_hex_hash :: proc(h: contracts.Content_Hash, allocator: mem.Allocator) -> string {
	copy_h := h
	b := hex.encode(copy_h[:], allocator)
	return string(b)
}

@(private = "file")
evidence_hex_id :: proc(id: contracts.Stable_ID, allocator: mem.Allocator) -> string {
	return fmt.aprintf("%016x", u64(id), allocator = allocator)
}

@(private = "file")
evidence_bool_u64 :: proc(v: bool) -> u64 {
	return 1 if v else 0
}

// One content file owned by a stage: a binary primitive or the exported G-code text.
@(private = "file")
Evidence_Export_File :: struct {
	path:           string,
	format:         string,
	schema_version: u32,
	item_count:     u64,
	bytes:          []u8,
}

// The two invariants every replay primitive manifest carries: the canonical result hash and the
// source-independent replay flag.
@(private = "file")
evidence_replay_invariants :: proc(
	hash_code, replay_code: string,
	hash: contracts.Content_Hash,
	allocator: mem.Allocator,
) -> []evidence.Evidence_Invariant {
	text := evidence_hex_hash(hash, allocator)
	invariants := make([]evidence.Evidence_Invariant, 2, allocator)
	invariants[0] = {code = hash_code, passed = true, observed = text, expected = text}
	invariants[1] = {
		code     = replay_code,
		passed   = true,
		observed = "passed",
		expected = "passed",
	}
	return invariants
}

@(private = "file")
evidence_topology_bounds :: proc(
	result: slicing.Topology_Result,
) -> evidence.Evidence_Bounds_2D {
	bounds := evidence.Evidence_Bounds_2D{units = "micrometre"}
	if len(result.vertices) == 0 {return bounds}
	bounds.valid = true
	bounds.minimum = [2]i64{i64(result.vertices[0].point.x), i64(result.vertices[0].point.y)}
	bounds.maximum = bounds.minimum
	for vertex in result.vertices[1:] {
		point := [2]i64{i64(vertex.point.x), i64(vertex.point.y)}
		bounds.minimum[0] = min(bounds.minimum[0], point[0])
		bounds.minimum[1] = min(bounds.minimum[1], point[1])
		bounds.maximum[0] = max(bounds.maximum[0], point[0])
		bounds.maximum[1] = max(bounds.maximum[1], point[1])
	}
	return bounds
}

@(private = "file")
evidence_region_bounds :: proc(
	result: slicing.Region_Result,
) -> evidence.Evidence_Bounds_2D {
	bounds := evidence.Evidence_Bounds_2D{units = "micrometre"}
	if len(result.regions) == 0 {return bounds}
	bounds.valid = true
	first := result.regions[0].bounds
	bounds.minimum = [2]i64{i64(first.minimum.x), i64(first.minimum.y)}
	bounds.maximum = [2]i64{i64(first.maximum.x), i64(first.maximum.y)}
	for region in result.regions[1:] {
		minimum := [2]i64{i64(region.bounds.minimum.x), i64(region.bounds.minimum.y)}
		maximum := [2]i64{i64(region.bounds.maximum.x), i64(region.bounds.maximum.y)}
		bounds.minimum[0] = min(bounds.minimum[0], minimum[0])
		bounds.minimum[1] = min(bounds.minimum[1], minimum[1])
		bounds.maximum[0] = max(bounds.maximum[0], maximum[0])
		bounds.maximum[1] = max(bounds.maximum[1], maximum[1])
	}
	return bounds
}

// Builds a complete, validated `.hwsdebug` evidence bundle covering every canonical stage
// (decode through emit-gcode, including bridges, gap fill, supports, adhesion, ironing,
// Z ramps, arc fitting, and modifiers) directly from a completed `Slice_Session`.
slice_session_export_evidence_bundle :: proc(
	s: ^Slice_Session,
	level: contracts.Evidence_Level,
	allocator := context.allocator,
) -> ([]u8, Slice_Run_Error) {
	if s == nil || level == .Disabled {
		return nil, {}
	}
	a := context.temp_allocator

	req_hash := s.slots[.Gcode].expected_hash
	req_nonzero := false
	for b in req_hash {
		if b != 0 {
			req_nonzero = true
			break
		}
	}
	if !req_nonzero {
		req_hash = s.source.source.content_hash
	}
	request_hash_text := evidence_hex_hash(req_hash, a)
	source_root_text := evidence_hex_id(s.source.source_root_id, a)

	src_bounds := evidence.Evidence_Bounds_3D{
		valid   = len(s.mesh.vertex_x) > 0,
		minimum = {f64(s.mesh.bounds.minimum.x), f64(s.mesh.bounds.minimum.y), f64(s.mesh.bounds.minimum.z)},
		maximum = {f64(s.mesh.bounds.maximum.x), f64(s.mesh.bounds.maximum.y), f64(s.mesh.bounds.maximum.z)},
		units   = "millimetre",
	}
	planar_bounds := evidence.Evidence_Bounds_2D{
		valid   = true,
		minimum = {i64(s.profile.printer.axis_minimum_x), i64(s.profile.printer.axis_minimum_y)},
		maximum = {i64(s.profile.printer.axis_maximum_x), i64(s.profile.printer.axis_maximum_y)},
		units   = "micrometre",
	}

	active_topo := session_active_topology(s)
	proc_src := s.profile.process.source

	min_lh := proc_src.layer_height
	max_lh := proc_src.layer_height
	for lh, idx in s.layer_heights {
		if idx == 0 {
			min_lh = lh
			max_lh = lh
		} else {
			if lh < min_lh {min_lh = lh}
			if lh > max_lh {max_lh = lh}
		}
	}

	infill_paths := u64(len(s.pattern_infill.paths))
	if infill_paths == 0 {infill_paths = u64(len(s.infill.segments))}
	support_paths := u64(len(s.tree_supports.paths)) if (s.options.enable_supports && s.options.support_style_tree) else u64(len(s.supports.paths))

	extrude_moves: u64
	travel_moves: u64
	for mv in s.unified_plan.moves {
		if mv.kind == .Extrude {extrude_moves += 1} else {travel_moves += 1}
	}

	stages_list := make([dynamic]evidence.Evidence_Bundle_Stage, 0, 11, a)
	files_list := make([dynamic]evidence.Evidence_Artifact, 0, 8, a)
	contents := make([dynamic]evidence.Evidence_Bundle_Content, 0, 24, a)

	Stage_Spec :: struct {
		kind:           contracts.Stage_Kind,
		provider_name:  string,
		elapsed_ms:     f64,
		schema_version: u32,
		revision:       u32,
		counters:       []evidence.Evidence_Counter,
		invariants:     []evidence.Evidence_Invariant,
		planar_bounds:  evidence.Evidence_Bounds_2D,
		files:          []Evidence_Export_File,
	}

	// Binary primitives for strict replay. Every artifact is optional: when its canonical result
	// hash or encoder rejects the retained session state, the stage keeps its summary counters and
	// the bundle stays exportable.
	primitives_level := level != .Summary

	sched_hash: contracts.Content_Hash
	sched_ok := false
	span_hash: contracts.Content_Hash
	span_ok := false
	inter_hash: contracts.Content_Hash
	inter_ok := false
	snapped_hash: contracts.Content_Hash
	snapped_ok := false
	topo_hash: contracts.Content_Hash
	topo_ok := false
	region_hash: contracts.Content_Hash
	region_ok := false
	surface_hash: contracts.Content_Hash
	surface_ok := false
	klipper_hash: contracts.Content_Hash
	klipper_ok := false

	schedule_bytes: []u8
	span_bytes: []u8
	intersect_bytes: []u8
	topology_bytes: []u8
	region_bytes: []u8
	surface_bytes: []u8
	klipper_bytes: []u8

	span_summary: evidence.Layer_Span_Artifact_Summary
	span_summary_ok := false
	intersection_summary: evidence.CPU_Intersection_Artifact_Summary

	if primitives_level {
		if !s.schedule.adaptive {
			sched_hash, sched_ok = slicing.fixed_layer_schedule_hash(s.schedule)
		}
		if sched_ok {
			if bytes, err := evidence.layer_schedule_artifact_encode(s.schedule, allocator = a); err == .None {
				schedule_bytes = bytes
			}
			span_hash, span_ok = slicing.layer_span_index_hash(sched_hash, s.span_index)
		}
		if span_ok {
			if bytes, err := evidence.layer_span_artifact_encode(sched_hash, s.span_index, allocator = a); err == .None {
				span_bytes = bytes
			}
			inter_hash, inter_ok = slicing.cpu_intersection_result_hash(span_hash, s.intersections)
		}
		if inter_ok {
			if bytes, err := evidence.cpu_intersection_artifact_encode(span_hash, s.intersections, allocator = a); err == .None {
				intersect_bytes = bytes
			}
			// The merged snapped result may contain planar-owned segments whose edge fields are
			// `.Invalid` (rejected by primary snapped-segment hashing). Fall back to the primary
			// snapped result hash so the downstream topology/region/surface chain remains anchored.
			snapped_hash, snapped_ok = slicing.snapped_segment_result_hash(inter_hash, s.snapped)
			if !snapped_ok {
				snapped_hash, snapped_ok = slicing.snapped_segment_result_hash(inter_hash, s.primary_snapped)
			}
		}
		if snapped_ok {
			export_topo := active_topo
			topo_source_segments := len(s.snapped.segments.segment_ids)
			// Contour simplification or repair drops segments/vertices while retaining original
			// snapped segment indices and pre-simplification vertex degrees. Build a normalized
			// temp view of the active topology (which regions were built from) so strict
			// topology/region/surface artifact encoding succeeds without loosening replay checks.
			if s.has_simplified || s.contour_repairs > 0 || len(active_topo.path_segment_indices) != topo_source_segments {
				dense := make([]u32, len(active_topo.path_segment_indices), a)
				for i in 0 ..< len(dense) {
					dense[i] = u32(i)
				}
				verts := make([]slicing.Topology_Vertex, len(active_topo.vertices), a)
				copy(verts, active_topo.vertices)
				for &v in verts {
					v.degree = 0
				}
				open_chains, deg_loops, non_manifold: u64
				for path in active_topo.paths {
					#partial switch path.kind {
					case .Open_Chain:      open_chains += 1
					case .Degenerate_Loop: deg_loops += 1
					}
					v_slice := active_topo.path_vertex_indices[path.vertex_offset:path.vertex_offset+u64(path.vertex_count)]
					for vi, li in v_slice {
						add := u32(1) if (path.kind == .Open_Chain && (li == 0 || li == len(v_slice)-1)) else u32(2)
						verts[vi].degree += add
					}
				}
				for v in verts {
					if v.degree > 2 {non_manifold += 1}
				}
				export_topo.vertices = verts
				export_topo.path_segment_indices = dense
				export_topo.open_chain_count = open_chains
				export_topo.degenerate_loop_count = deg_loops
				export_topo.non_manifold_vertex_count = non_manifold
				topo_source_segments = len(dense)
			}
			topo_hash, topo_ok = slicing.topology_result_hash(snapped_hash, topo_source_segments, export_topo)
			if topo_ok {
				if bytes, err := evidence.topology_artifact_encode(snapped_hash, topo_source_segments, export_topo, allocator = a); err == .None {
					topology_bytes = bytes
					active_topo = export_topo
				}
				// Replay decodes regions only after the topology primitive, so keep the pair together.
				if len(topology_bytes) > 0 {
					region_hash, region_ok = slicing.region_result_hash(topo_hash, export_topo, s.regions)
				}
			}
			if region_ok {
				if bytes, err := evidence.region_artifact_encode(topo_hash, export_topo, s.regions, allocator = a); err == .None {
					region_bytes = bytes
				}
				surface_hash, surface_ok = features.surface_result_hash(region_hash, s.surfaces)
			}
		}
		if surface_ok {
			if bytes, err := features.surface_artifact_encode(region_hash, s.surfaces, allocator = a); err == .None {
				surface_bytes = bytes
			}
		}
		// The Klipper artifact needs the motion result hash. The unified path plan and extrusion
		// artifacts are not retained by the session, so their dependency hashes are zero here and
		// no plan-path primitive accompanies the G-code one.
		motion_hash: contracts.Content_Hash
		motion_ok: bool
		if len(s.motion.layers) > 0 &&
		   len(s.schedule.layer_ids) == len(s.schedule.print_z) &&
		   len(s.schedule.layer_ids) == len(s.model_layer_sets) {
			motion_deps, deps_ok := features.motion_plan_hash_dependencies_make(
				contracts.Content_Hash{},
				contracts.Content_Hash{},
				s.schedule.layer_ids,
				s.schedule.print_z,
				s.model_layer_sets,
				s.profile,
				a,
			)
			if deps_ok {
				motion_hash, motion_ok =
					features.motion_plan_result_content_hash(motion_deps, s.motion)
				features.motion_plan_hash_dependencies_destroy(&motion_deps, a)
			}
		}
		if motion_ok {
			klipper_hash, klipper_ok = gcode.klipper_result_content_hash(
				motion_hash,
				profiles.profile_revisions(s.profile),
				s.klipper,
			)
		}
		if klipper_ok {
			if bytes, err := gcode.klipper_artifact_encode(motion_hash, s.motion, s.profile, s.klipper, allocator = a); err == .None {
				klipper_bytes = bytes
			}
		}
	}

	decode_counters := []evidence.Evidence_Counter{
		evidence.Evidence_Counter{name = "source_bytes", value = s.source.source.byte_count},
		evidence.Evidence_Counter{name = "source_format", value = u64(s.source.source.format)},
		evidence.Evidence_Counter{name = "triangle_count", value = u64(len(s.source.triangle_ids))},
		evidence.Evidence_Counter{name = "vertex_count", value = u64(len(s.source.vertex_x))},
	}
	resolve_counters := []evidence.Evidence_Counter{
		evidence.Evidence_Counter{name = "perimeter_count", value = u64(proc_src.perimeter_count)},
		evidence.Evidence_Counter{name = "layer_height_um", value = u64(max(i64(0), i64(proc_src.layer_height)))},
		evidence.Evidence_Counter{name = "first_layer_height_um", value = u64(max(i64(0), i64(proc_src.first_layer_height)))},
		evidence.Evidence_Counter{name = "nominal_line_width_um", value = u64(max(i64(0), i64(proc_src.nominal_line_width)))},
		evidence.Evidence_Counter{name = "modifier_zones", value = u64(len(s.options.modifiers))},
		evidence.Evidence_Counter{name = "vase_mode", value = evidence_bool_u64(s.options.vase_mode)},
		evidence.Evidence_Counter{name = "adaptive_layers", value = evidence_bool_u64(s.options.adaptive_layers)},
	}
	normalize_counters := []evidence.Evidence_Counter{
		evidence.Evidence_Counter{name = "triangle_count", value = u64(len(s.mesh.triangle_ids))},
		evidence.Evidence_Counter{name = "vertex_count", value = u64(len(s.mesh.vertex_x))},
		evidence.Evidence_Counter{name = "degenerate_removed", value = u64(s.mesh_repair_stats.degenerate_removed)},
		evidence.Evidence_Counter{name = "normals_flipped", value = u64(s.mesh_repair_stats.normals_flipped)},
		evidence.Evidence_Counter{name = "holes_filled", value = u64(s.mesh_repair_stats.holes_filled)},
	}

	schedule_counters := make([dynamic]evidence.Evidence_Counter, 0, 8, a)
	append(
		&schedule_counters,
		evidence.Evidence_Counter{name = "layer_count", value = u64(len(s.schedule.layer_ids))},
		evidence.Evidence_Counter{name = "adaptive_layers", value = evidence_bool_u64(s.options.adaptive_layers)},
		evidence.Evidence_Counter{name = "min_layer_height_um", value = u64(max(i64(0), i64(min_lh)))},
		evidence.Evidence_Counter{name = "max_layer_height_um", value = u64(max(i64(0), i64(max_lh)))},
	)
	schedule_invariants: []evidence.Evidence_Invariant
	if len(schedule_bytes) > 0 {
		append(
			&schedule_counters,
			evidence.Evidence_Counter{name = "scheduled_layers", value = u64(len(s.schedule.layer_z))},
		)
		schedule_invariants = evidence_replay_invariants(
			"canonical_layer_schedule_result_hash",
			"source_independent_layer_schedule_replay",
			sched_hash,
			a,
		)
	}

	accel_counters := make([dynamic]evidence.Evidence_Counter, 0, 9, a)
	append(
		&accel_counters,
		evidence.Evidence_Counter{name = "layer_count", value = u64(len(s.span_index.layers))},
		evidence.Evidence_Counter{name = "span_entries", value = u64(len(s.span_index.triangle_indices))},
	)
	if len(span_bytes) > 0 {
		if summary, summary_error := evidence.layer_span_artifact_preflight_summary(s.span_index); !summary_error {
			span_summary = summary
			span_summary_ok = true
		}
	}
	accel_invariants: []evidence.Evidence_Invariant
	if span_summary_ok {
		append(
			&accel_counters,
			evidence.Evidence_Counter{name = "span_triangles", value = span_summary.triangle_count},
			evidence.Evidence_Counter{name = "span_layers", value = span_summary.layer_count},
			evidence.Evidence_Counter{name = "triangle_layer_pairs", value = span_summary.pair_count},
			evidence.Evidence_Counter{name = "crossing_triangles", value = span_summary.crossing_triangle_count},
			evidence.Evidence_Counter{name = "planar_triangles", value = span_summary.planar_triangle_count},
			evidence.Evidence_Counter{name = "inactive_triangles", value = span_summary.inactive_triangle_count},
		)
		accel_invariants = evidence_replay_invariants(
			"canonical_layer_span_result_hash",
			"source_independent_layer_span_replay",
			span_hash,
			a,
		)
	}

	intersect_counters := make([dynamic]evidence.Evidence_Counter, 0, 9, a)
	append(
		&intersect_counters,
		evidence.Evidence_Counter{name = "raw_segments", value = u64(len(s.intersections.segments.segment_ids))},
		evidence.Evidence_Counter{name = "snapped_segments", value = u64(len(s.snapped.segments.segment_ids))},
		evidence.Evidence_Counter{name = "planar_owned_segments", value = u64(len(s.planar_ownership.segments.segment_ids))},
	)
	intersect_invariants: []evidence.Evidence_Invariant
	if len(intersect_bytes) > 0 {
		intersection_summary = evidence.cpu_intersection_artifact_summary(s.intersections)
		append(
			&intersect_counters,
			evidence.Evidence_Counter{name = "intersection_layers", value = intersection_summary.layer_count},
			evidence.Evidence_Counter{name = "planar_candidates", value = intersection_summary.planar_candidate_count},
			evidence.Evidence_Counter{name = "tangent_pairs", value = intersection_summary.tangent_count},
			evidence.Evidence_Counter{name = "degenerate_pairs", value = intersection_summary.degenerate_count},
			evidence.Evidence_Counter{name = "exact_predicates", value = intersection_summary.exact_predicate_count},
		)
		intersect_invariants = evidence_replay_invariants(
			"canonical_intersection_result_hash",
			"source_independent_intersection_replay",
			inter_hash,
			a,
		)
	}

	topo_counters := make([dynamic]evidence.Evidence_Counter, 0, 12, a)
	append(
		&topo_counters,
		evidence.Evidence_Counter{name = "loops", value = u64(len(active_topo.paths))},
		evidence.Evidence_Counter{name = "vertices", value = u64(len(active_topo.vertices))},
		evidence.Evidence_Counter{name = "open_chains", value = active_topo.open_chain_count},
		evidence.Evidence_Counter{name = "degenerate_loops", value = active_topo.degenerate_loop_count},
		evidence.Evidence_Counter{name = "non_manifold_vertices", value = active_topo.non_manifold_vertex_count},
		evidence.Evidence_Counter{name = "simplified", value = evidence_bool_u64(s.has_simplified)},
	)
	topo_invariants: []evidence.Evidence_Invariant
	if len(topology_bytes) > 0 {
		append(
			&topo_counters,
			evidence.Evidence_Counter{name = "layers", value = u64(len(active_topo.layers))},
			evidence.Evidence_Counter{name = "paths", value = u64(len(active_topo.paths))},
			evidence.Evidence_Counter{name = "path_vertex_indices", value = u64(len(active_topo.path_vertex_indices))},
			evidence.Evidence_Counter{name = "path_segment_indices", value = u64(len(active_topo.path_segment_indices))},
		)
		topo_invariants = evidence_replay_invariants(
			"canonical_result_hash",
			"source_independent_replay",
			topo_hash,
			a,
		)
	}

	region_counters := make([dynamic]evidence.Evidence_Counter, 0, 7, a)
	append(
		&region_counters,
		evidence.Evidence_Counter{name = "regions", value = u64(len(s.regions.regions))},
		evidence.Evidence_Counter{name = "holes", value = s.regions.hole_count},
		evidence.Evidence_Counter{name = "contour_repairs", value = u64(s.contour_repairs)},
	)
	region_invariants: []evidence.Evidence_Invariant
	if len(region_bytes) > 0 {
		append(
			&region_counters,
			evidence.Evidence_Counter{name = "layers", value = u64(len(s.regions.layers))},
			evidence.Evidence_Counter{name = "contours", value = u64(len(s.regions.contours))},
			evidence.Evidence_Counter{name = "region_contour_indices", value = u64(len(s.regions.region_contour_indices))},
		)
		region_invariants = evidence_replay_invariants(
			"canonical_result_hash",
			"source_independent_replay",
			region_hash,
			a,
		)
	}

	feature_counters := make([dynamic]evidence.Evidence_Counter, 0, 28, a)
	append(
		&feature_counters,
		evidence.Evidence_Counter{name = "surface_masks", value = u64(len(s.surfaces.masks))},
		evidence.Evidence_Counter{name = "skin_masks", value = u64(len(s.skins.masks))},
		evidence.Evidence_Counter{name = "skin_omit_top", value = evidence_bool_u64(s.options.vase_mode)},
		evidence.Evidence_Counter{name = "perimeter_groups", value = u64(len(s.perimeters.groups))},
		evidence.Evidence_Counter{name = "perimeter_paths", value = u64(len(s.perimeters.paths))},
		evidence.Evidence_Counter{name = "bridge_directions", value = u64(len(s.bridge_directions.selections))},
		evidence.Evidence_Counter{name = "bridge_evidence_masks", value = u64(len(s.bridge_evidence.masks))},
		evidence.Evidence_Counter{name = "bridge_paths", value = u64(len(s.bridges.paths))},
		evidence.Evidence_Counter{name = "overlap_masks", value = u64(len(s.overlap.masks))},
		evidence.Evidence_Counter{name = "solid_paths", value = u64(len(s.solids.paths))},
		evidence.Evidence_Counter{name = "monotonic_skin", value = evidence_bool_u64(s.options.monotonic_skin)},
		evidence.Evidence_Counter{name = "ironing_enabled", value = evidence_bool_u64(s.options.ironing_enabled)},
		evidence.Evidence_Counter{name = "ironing_paths", value = u64(len(s.ironing.paths))},
		evidence.Evidence_Counter{name = "infill_pattern", value = u64(s.options.infill_pattern)},
		evidence.Evidence_Counter{name = "infill_paths", value = infill_paths},
		evidence.Evidence_Counter{name = "gap_centerlines", value = u64(len(s.gaps.paths))},
		evidence.Evidence_Counter{name = "supports_enabled", value = evidence_bool_u64(s.options.enable_supports)},
		evidence.Evidence_Counter{name = "support_style_tree", value = evidence_bool_u64(s.options.support_style_tree)},
		evidence.Evidence_Counter{name = "support_paths", value = support_paths},
		evidence.Evidence_Counter{name = "adhesion_loops", value = u64(len(s.adhesion.loops))},
		evidence.Evidence_Counter{name = "modifier_zones", value = u64(len(s.options.modifiers))},
	)
	feature_invariants: []evidence.Evidence_Invariant
	if len(surface_bytes) > 0 {
		append(
			&feature_counters,
			evidence.Evidence_Counter{name = "surface_layers", value = u64(len(s.surfaces.layers))},
			evidence.Evidence_Counter{name = "surface_paths", value = u64(len(s.surfaces.paths))},
			evidence.Evidence_Counter{name = "surface_points", value = u64(len(s.surfaces.points))},
			evidence.Evidence_Counter{name = "surface_bottom_masks", value = s.surfaces.bottom_mask_count},
			evidence.Evidence_Counter{name = "surface_top_masks", value = s.surfaces.top_mask_count},
		)
		feature_invariants = evidence_replay_invariants(
			"canonical_surface_result_hash",
			"source_independent_surface_replay",
			surface_hash,
			a,
		)
	}

	plan_counters := []evidence.Evidence_Counter{
		evidence.Evidence_Counter{name = "planned_paths", value = u64(len(s.unified_plan.paths))},
		evidence.Evidence_Counter{name = "planned_moves", value = u64(len(s.unified_plan.moves))},
		evidence.Evidence_Counter{name = "extrude_moves", value = extrude_moves},
		evidence.Evidence_Counter{name = "travel_moves", value = travel_moves},
		evidence.Evidence_Counter{name = "variable_walls_enabled", value = evidence_bool_u64(s.options.variable_walls_enabled)},
		evidence.Evidence_Counter{name = "variable_walls_vertices", value = s.variable_wall_stats.vertices_adapted},
		evidence.Evidence_Counter{name = "fuzzy_skin_enabled", value = evidence_bool_u64(s.options.fuzzy_skin_enabled)},
		evidence.Evidence_Counter{name = "fuzzy_skin_loops", value = s.fuzzy_skin_stats.loops_perturbed},
		evidence.Evidence_Counter{name = "extrusion_moves", value = u64(len(s.extrusion.moves))},
		evidence.Evidence_Counter{name = "total_filament_nm", value = u64(s.extrusion.total_filament_nm)},
		evidence.Evidence_Counter{name = "motion_operations", value = u64(len(s.motion.operations))},
		evidence.Evidence_Counter{name = "motion_extrusions", value = s.motion.extrusion_count},
		evidence.Evidence_Counter{name = "motion_retractions", value = s.motion.retraction_count},
		evidence.Evidence_Counter{name = "motion_travels", value = s.motion.travel_count},
		evidence.Evidence_Counter{name = "motion_dwells", value = s.motion.dwell_count},
		evidence.Evidence_Counter{name = "z_ramps_enabled", value = evidence_bool_u64(s.options.scarf_seam_enabled || s.options.vase_mode)},
		evidence.Evidence_Counter{name = "z_ramps_loops", value = s.z_ramp_stats.loops_ramped},
		evidence.Evidence_Counter{name = "z_ramps_ops", value = s.z_ramp_stats.ops_modified},
		evidence.Evidence_Counter{name = "arc_fitting_enabled", value = evidence_bool_u64(s.options.arc_fitting_enabled && !s.options.vase_mode)},
		evidence.Evidence_Counter{name = "arcs_fitted", value = s.arc_fit_stats.arcs_fitted},
		evidence.Evidence_Counter{name = "estimated_time_s", value = u64(s.estimated_seconds)},
	}

	gcode_counters := make([dynamic]evidence.Evidence_Counter, 0, 8, a)
	append(
		&gcode_counters,
		evidence.Evidence_Counter{name = "gcode_bytes", value = u64(len(s.klipper.bytes))},
		evidence.Evidence_Counter{name = "command_count", value = u64(len(s.klipper.commands))},
		evidence.Evidence_Counter{name = "validated", value = 1},
	)
	gcode_invariants: []evidence.Evidence_Invariant
	if len(klipper_bytes) > 0 {
		append(
			&gcode_counters,
			evidence.Evidence_Counter{name = "commands", value = u64(len(s.klipper.commands))},
			evidence.Evidence_Counter{name = "layers", value = u64(s.klipper.layer_count)},
			evidence.Evidence_Counter{name = "motion_operations", value = s.klipper.motion_operation_count},
			evidence.Evidence_Counter{name = "dwell_ms", value = s.klipper.emitted_dwell_ms},
		)
		gcode_invariants = evidence_replay_invariants(
			"canonical_result_hash",
			"source_independent_replay",
			klipper_hash,
			a,
		)
	}

	feature_ms := s.slots[.Surfaces_Skin].duration_ms + s.slots[.Perimeters].duration_ms +
		s.slots[.Bridges].duration_ms + s.slots[.Solid_Areas].duration_ms +
		s.slots[.Solid_Paths].duration_ms + s.slots[.Sparse_Infill].duration_ms +
		s.slots[.Gap_Fill].duration_ms + s.slots[.Supports].duration_ms
	plan_ms := s.slots[.Path_Plan].duration_ms + s.slots[.Motion].duration_ms

	schedule_schema := evidence_stage_schema_version(.Schedule_Layers)
	schedule_revision := evidence.LAYER_SCHEDULE_MANIFEST_STAGE_REVISION
	span_schema := evidence_stage_schema_version(.Build_Acceleration)
	span_revision := u32(1)
	span_files: []Evidence_Export_File
	if span_summary_ok {
		span_schema = slicing.SCHEMA_VERSION_LAYER_SPAN_INDEX_HASH
		span_revision = evidence.LAYER_SPAN_MANIFEST_STAGE_REVISION
		span_files = []Evidence_Export_File{{
			path = "stages/05-build-acceleration/primitives/layer-spans.bin",
			format = evidence.LAYER_SPAN_ARTIFACT_FORMAT,
			schema_version = evidence.LAYER_SPAN_ARTIFACT_SCHEMA_VERSION,
			item_count = span_summary.triangle_count+span_summary.layer_count+span_summary.pair_count,
			bytes = span_bytes,
		}}
	}

	intersect_schema := evidence_stage_schema_version(.Intersect)
	intersect_revision := u32(1)
	intersect_files: []Evidence_Export_File
	if len(intersect_bytes) > 0 {
		intersect_schema = slicing.SCHEMA_VERSION_CPU_INTERSECTION_HASH
		intersect_revision = evidence.CPU_INTERSECTION_MANIFEST_STAGE_REVISION
		intersect_files = []Evidence_Export_File{{
			path = "stages/06-intersect/primitives/cpu-intersections.bin",
			format = evidence.CPU_INTERSECTION_ARTIFACT_FORMAT,
			schema_version = evidence.CPU_INTERSECTION_ARTIFACT_SCHEMA_VERSION,
			item_count = intersection_summary.layer_count+
				intersection_summary.segment_count+
				intersection_summary.planar_candidate_count,
			bytes = intersect_bytes,
		}}
	}

	topology_schema := evidence_stage_schema_version(.Reconstruct_Topology)
	topology_revision := u32(1)
	topology_files: []Evidence_Export_File
	topology_bounds := planar_bounds
	if len(topology_bytes) > 0 {
		topology_schema = slicing.SCHEMA_VERSION_TOPOLOGY_HASH
		topology_revision = evidence.TOPOLOGY_MANIFEST_STAGE_REVISION
		topology_bounds = evidence_topology_bounds(active_topo)
		topology_files = []Evidence_Export_File{{
			path = "stages/07-reconstruct-topology/primitives/topology.bin",
			format = evidence.TOPOLOGY_ARTIFACT_FORMAT,
			schema_version = evidence.TOPOLOGY_ARTIFACT_SCHEMA_VERSION,
			item_count = u64(len(active_topo.layers))+
				u64(len(active_topo.vertices))+
				u64(len(active_topo.paths))+
				u64(len(active_topo.path_vertex_indices))+
				u64(len(active_topo.path_segment_indices)),
			bytes = topology_bytes,
		}}
	}

	region_schema := evidence_stage_schema_version(.Calculate_Regions)
	region_revision := evidence.REGION_MANIFEST_STAGE_REVISION
	region_files: []Evidence_Export_File
	region_bounds := planar_bounds
	if len(region_bytes) > 0 {
		region_bounds = evidence_region_bounds(s.regions)
		region_files = []Evidence_Export_File{{
			path = "stages/08-calculate-regions/primitives/regions.bin",
			format = evidence.REGION_ARTIFACT_FORMAT,
			schema_version = evidence.REGION_ARTIFACT_SCHEMA_VERSION,
			item_count = u64(len(s.regions.layers))+
				u64(len(s.regions.contours))+
				u64(len(s.regions.regions))+
				u64(len(s.regions.region_contour_indices)),
			bytes = region_bytes,
		}}
	}

	feature_schema := evidence_stage_schema_version(.Generate_Features)
	feature_revision := u32(1)
	feature_files: []Evidence_Export_File
	if len(surface_bytes) > 0 {
		feature_schema = features.SCHEMA_VERSION_SURFACE_HASH
		feature_revision = evidence.SURFACE_MANIFEST_STAGE_REVISION
		feature_files = []Evidence_Export_File{{
			path = "stages/09-generate-features/primitives/surfaces.bin",
			format = features.SURFACE_ARTIFACT_FORMAT,
			schema_version = features.SURFACE_ARTIFACT_SCHEMA_VERSION,
			item_count = u64(len(s.surfaces.layers))+
				u64(len(s.surfaces.masks))+
				u64(len(s.surfaces.paths))+
				u64(len(s.surfaces.points)),
			bytes = surface_bytes,
		}}
	}

	gcode_schema := evidence_stage_schema_version(.Emit_GCode)
	gcode_revision := u32(1)
	gcode_files := make([dynamic]Evidence_Export_File, 0, 2, a)
	if primitives_level && len(s.klipper.bytes) > 0 {
		append(
			&gcode_files,
			Evidence_Export_File{
				path = "stages/11-emit-gcode/output.gcode",
				format = "gcode",
				schema_version = contracts.SCHEMA_VERSION_STAGE_RESULT,
				item_count = max(u64(1), u64(len(s.klipper.commands))),
				bytes = s.klipper.bytes,
			},
		)
	}
	if len(klipper_bytes) > 0 {
		gcode_schema = gcode.KLIPPER_EMITTER_SCHEMA_VERSION
		gcode_revision = evidence.KLIPPER_MANIFEST_STAGE_REVISION
		append(
			&gcode_files,
			Evidence_Export_File{
				path = "stages/11-emit-gcode/primitives/klipper-gcode.bin",
				format = gcode.KLIPPER_ARTIFACT_FORMAT,
				schema_version = gcode.KLIPPER_ARTIFACT_SCHEMA_VERSION,
				item_count = u64(len(s.klipper.commands)),
				bytes = klipper_bytes,
			},
		)
	}

	schedule_files: []Evidence_Export_File
	if len(schedule_bytes) > 0 {
		schedule_files = []Evidence_Export_File{{
			path = "stages/04-schedule-layers/primitives/layer-schedule.bin",
			format = evidence.LAYER_SCHEDULE_ARTIFACT_FORMAT,
			schema_version = evidence.LAYER_SCHEDULE_ARTIFACT_SCHEMA_VERSION,
			item_count = u64(len(s.schedule.layer_z)),
			bytes = schedule_bytes,
		}}
	}

	specs := [11]Stage_Spec{
		{
			kind = .Decode,
			provider_name = "hw-slicer.decode",
			elapsed_ms = 0,
			schema_version = evidence_stage_schema_version(.Decode),
			revision = 1,
			counters = decode_counters,
			planar_bounds = planar_bounds,
		},
		{
			kind = .Resolve,
			provider_name = "hw-slicer.resolve",
			elapsed_ms = 0,
			schema_version = evidence_stage_schema_version(.Resolve),
			revision = 1,
			counters = resolve_counters,
			planar_bounds = planar_bounds,
		},
		{
			kind = .Normalize,
			provider_name = "hw-slicer.normalize",
			elapsed_ms = s.slots[.Model].duration_ms,
			schema_version = evidence_stage_schema_version(.Normalize),
			revision = 1,
			counters = normalize_counters,
			planar_bounds = planar_bounds,
		},
		{
			kind = .Schedule_Layers,
			provider_name = "hw-slicer.schedule-layers",
			elapsed_ms = s.slots[.Layer_Schedule].duration_ms,
			schema_version = schedule_schema,
			revision = schedule_revision,
			counters = schedule_counters[:],
			invariants = schedule_invariants,
			planar_bounds = planar_bounds,
			files = schedule_files,
		},
		{
			kind = .Build_Acceleration,
			provider_name = "hw-slicer.build-acceleration",
			elapsed_ms = 0,
			schema_version = span_schema,
			revision = span_revision,
			counters = accel_counters[:],
			invariants = accel_invariants,
			planar_bounds = planar_bounds,
			files = span_files,
		},
		{
			kind = .Intersect,
			provider_name = "hw-slicer.intersect",
			elapsed_ms = s.slots[.Intersections].duration_ms,
			schema_version = intersect_schema,
			revision = intersect_revision,
			counters = intersect_counters[:],
			invariants = intersect_invariants,
			planar_bounds = planar_bounds,
			files = intersect_files,
		},
		{
			kind = .Reconstruct_Topology,
			provider_name = "hw-slicer.reconstruct-topology",
			elapsed_ms = s.slots[.Topology].duration_ms,
			schema_version = topology_schema,
			revision = topology_revision,
			counters = topo_counters[:],
			invariants = topo_invariants,
			planar_bounds = topology_bounds,
			files = topology_files,
		},
		{
			kind = .Calculate_Regions,
			provider_name = "hw-slicer.calculate-regions",
			elapsed_ms = s.slots[.Regions].duration_ms,
			schema_version = region_schema,
			revision = region_revision,
			counters = region_counters[:],
			invariants = region_invariants,
			planar_bounds = region_bounds,
			files = region_files,
		},
		{
			kind = .Generate_Features,
			provider_name = "hw-slicer.generate-features",
			elapsed_ms = feature_ms,
			schema_version = feature_schema,
			revision = feature_revision,
			counters = feature_counters[:],
			invariants = feature_invariants,
			planar_bounds = planar_bounds,
			files = feature_files,
		},
		{
			kind = .Plan_Paths,
			provider_name = "hw-slicer.plan-paths",
			elapsed_ms = plan_ms,
			schema_version = evidence_stage_schema_version(.Plan_Paths),
			revision = 1,
			counters = plan_counters,
			planar_bounds = planar_bounds,
		},
		{
			kind = .Emit_GCode,
			provider_name = "hw-slicer.emit-gcode",
			elapsed_ms = s.slots[.Gcode].duration_ms,
			schema_version = gcode_schema,
			revision = gcode_revision,
			counters = gcode_counters[:],
			invariants = gcode_invariants,
			planar_bounds = planar_bounds,
			files = gcode_files[:],
		},
	}

	for spec in specs {
		stage_name := contracts.stage_name(spec.kind)
		pdesc, pdesc_ok := contracts.provider_descriptor_make(spec.provider_name, {1, 0, 0}, spec.kind)
		if !pdesc_ok {
			return nil, {stage = "evidence", detail = fmt.tprintf("invalid provider descriptor for %s", stage_name)}
		}
		prov := evidence.Evidence_Provider{
			id      = evidence_hex_id(pdesc.id, a),
			name    = spec.provider_name,
			version = "1.0.0",
		}
		stage_info := evidence.Evidence_Stage{
			name           = stage_name,
			schema_version = spec.schema_version,
			revision       = spec.revision,
		}

		primitives := make([dynamic]evidence.Evidence_Artifact, 0, len(spec.files), a)
		for file in spec.files {
			if len(file.bytes) == 0 {continue}
			art, art_err := evidence.evidence_artifact_describe(
				file.path,
				file.format,
				file.schema_version,
				file.item_count,
				file.bytes,
				a,
			)
			if art_err != .None {
				return nil, {stage = "evidence", detail = fmt.tprintf("artifact describe failed for %s: %v", file.path, art_err)}
			}
			append(&primitives, art)
			append(&files_list, art)
			append(&contents, evidence.Evidence_Bundle_Content{path = file.path, bytes = file.bytes})
		}

		sm := evidence.Evidence_Manifest{
			schema_version = contracts.SCHEMA_VERSION_DEBUG_EVIDENCE,
			request_hash   = request_hash_text,
			stage          = stage_info,
			provider       = prov,
			source_root_id = source_root_text,
			source_bounds  = src_bounds,
			planar_bounds  = spec.planar_bounds,
			summary        = spec.counters,
			invariants     = spec.invariants,
			primitives     = primitives[:],
			elapsed_ns     = u64(max(0.0, spec.elapsed_ms * 1_000_000.0)),
		}
		sm_bytes, sm_err := evidence.evidence_manifest_encode(sm, a)
		if sm_err != .None {
			return nil, {stage = "evidence", detail = fmt.tprintf("stage manifest encode failed for %s: %v", stage_name, sm_err)}
		}
		sm_path := fmt.aprintf("stages/%02d-%s/manifest.json", u32(spec.kind), stage_name, allocator = a)
		sm_art, sm_art_err := evidence.evidence_artifact_describe(
			sm_path,
			"json",
			contracts.SCHEMA_VERSION_DEBUG_EVIDENCE,
			1,
			sm_bytes,
			a,
		)
		if sm_art_err != .None {
			return nil, {stage = "evidence", detail = fmt.tprintf("stage manifest describe failed for %s: %v", stage_name, sm_art_err)}
		}
		append(&stages_list, evidence.Evidence_Bundle_Stage{
			ordinal  = u32(spec.kind),
			stage    = stage_info,
			provider = prov,
			manifest = sm_art,
		})
		append(&contents, evidence.Evidence_Bundle_Content{path = sm_path, bytes = sm_bytes})
	}

	bundle_summary := evidence.Evidence_Bundle_Summary{
		schema_version = evidence.EVIDENCE_BUNDLE_SCHEMA_VERSION,
		request_hash   = request_hash_text,
		source_root_id = source_root_text,
		stage_count    = u64(len(stages_list)),
		file_count     = u64(len(files_list)),
	}
	summary_bytes, sum_err := evidence.evidence_bundle_summary_encode(bundle_summary, a)
	if sum_err != .None {
		return nil, {stage = "evidence", detail = fmt.tprintf("bundle summary encode failed: %v", sum_err)}
	}
	summary_art, sum_art_err := evidence.evidence_artifact_describe(
		"summary.json",
		"json",
		evidence.EVIDENCE_BUNDLE_SCHEMA_VERSION,
		1,
		summary_bytes,
		a,
	)
	if sum_art_err != .None {
		return nil, {stage = "evidence", detail = fmt.tprintf("bundle summary describe failed: %v", sum_art_err)}
	}
	append(&contents, evidence.Evidence_Bundle_Content{path = "summary.json", bytes = summary_bytes})

	bundle_manifest := evidence.Evidence_Bundle_Manifest{
		schema_version = evidence.EVIDENCE_BUNDLE_SCHEMA_VERSION,
		request_hash   = request_hash_text,
		source_root_id = source_root_text,
		summary        = summary_art,
		stages         = stages_list[:],
		files          = files_list[:],
	}
	pkg_bytes, pkg_err := evidence.evidence_bundle_package_encode(bundle_manifest, contents[:], allocator = allocator)
	if pkg_err != .None {
		return nil, {stage = "evidence", detail = fmt.tprintf("evidence bundle encode failed: %v", pkg_err)}
	}
	return pkg_bytes, {}
}