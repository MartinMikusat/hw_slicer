package pipeline

import "core:encoding/hex"
import "core:fmt"
import "core:mem"
import "core:strings"

import contracts "../contracts"
import evidence "../evidence"
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
	files_list := make([dynamic]evidence.Evidence_Artifact, 0, 4, a)
	contents := make([dynamic]evidence.Evidence_Bundle_Content, 0, 16, a)

	Stage_Spec :: struct {
		kind:          contracts.Stage_Kind,
		provider_name: string,
		elapsed_ms:    f64,
		counters:      []evidence.Evidence_Counter,
		invariants:    []evidence.Evidence_Invariant,
		extra_path:    string,
		extra_format:  string,
		extra_bytes:   []u8,
		extra_items:   u64,
	}

	decode_counters := []evidence.Evidence_Counter{
		{name = "source_bytes", value = s.source.source.byte_count},
		{name = "source_format", value = u64(s.source.source.format)},
		{name = "triangle_count", value = u64(len(s.source.triangle_ids))},
		{name = "vertex_count", value = u64(len(s.source.vertex_x))},
	}
	resolve_counters := []evidence.Evidence_Counter{
		{name = "perimeter_count", value = u64(proc_src.perimeter_count)},
		{name = "layer_height_um", value = u64(max(i64(0), i64(proc_src.layer_height)))},
		{name = "first_layer_height_um", value = u64(max(i64(0), i64(proc_src.first_layer_height)))},
		{name = "nominal_line_width_um", value = u64(max(i64(0), i64(proc_src.nominal_line_width)))},
		{name = "modifier_zones", value = u64(len(s.options.modifiers))},
		{name = "vase_mode", value = evidence_bool_u64(s.options.vase_mode)},
		{name = "adaptive_layers", value = evidence_bool_u64(s.options.adaptive_layers)},
	}
	normalize_counters := []evidence.Evidence_Counter{
		{name = "triangle_count", value = u64(len(s.mesh.triangle_ids))},
		{name = "vertex_count", value = u64(len(s.mesh.vertex_x))},
		{name = "degenerate_removed", value = u64(s.mesh_repair_stats.degenerate_removed)},
		{name = "normals_flipped", value = u64(s.mesh_repair_stats.normals_flipped)},
		{name = "holes_filled", value = u64(s.mesh_repair_stats.holes_filled)},
	}
	schedule_counters := []evidence.Evidence_Counter{
		{name = "layer_count", value = u64(len(s.schedule.layer_ids))},
		{name = "adaptive_layers", value = evidence_bool_u64(s.options.adaptive_layers)},
		{name = "min_layer_height_um", value = u64(max(i64(0), i64(min_lh)))},
		{name = "max_layer_height_um", value = u64(max(i64(0), i64(max_lh)))},
	}
	accel_counters := []evidence.Evidence_Counter{
		{name = "layer_count", value = u64(len(s.span_index.layers))},
		{name = "span_entries", value = u64(len(s.span_index.triangle_indices))},
	}
	intersect_counters := []evidence.Evidence_Counter{
		{name = "raw_segments", value = u64(len(s.intersections.segments.segment_ids))},
		{name = "snapped_segments", value = u64(len(s.snapped.segments.segment_ids))},
		{name = "planar_owned_segments", value = u64(len(s.planar_ownership.segments.segment_ids))},
	}
	topo_counters := []evidence.Evidence_Counter{
		{name = "loops", value = u64(len(active_topo.paths))},
		{name = "vertices", value = u64(len(active_topo.vertices))},
		{name = "open_chains", value = active_topo.open_chain_count},
		{name = "degenerate_loops", value = active_topo.degenerate_loop_count},
		{name = "non_manifold_vertices", value = active_topo.non_manifold_vertex_count},
		{name = "simplified", value = evidence_bool_u64(s.has_simplified)},
	}
	region_counters := []evidence.Evidence_Counter{
		{name = "regions", value = u64(len(s.regions.regions))},
		{name = "holes", value = s.regions.hole_count},
		{name = "contour_repairs", value = u64(s.contour_repairs)},
	}
	feature_counters := []evidence.Evidence_Counter{
		{name = "surface_masks", value = u64(len(s.surfaces.masks))},
		{name = "skin_masks", value = u64(len(s.skins.masks))},
		{name = "skin_omit_top", value = evidence_bool_u64(s.options.vase_mode)},
		{name = "perimeter_groups", value = u64(len(s.perimeters.groups))},
		{name = "perimeter_paths", value = u64(len(s.perimeters.paths))},
		{name = "bridge_directions", value = u64(len(s.bridge_directions.selections))},
		{name = "bridge_evidence_masks", value = u64(len(s.bridge_evidence.masks))},
		{name = "bridge_paths", value = u64(len(s.bridges.paths))},
		{name = "overlap_masks", value = u64(len(s.overlap.masks))},
		{name = "solid_paths", value = u64(len(s.solids.paths))},
		{name = "monotonic_skin", value = evidence_bool_u64(s.options.monotonic_skin)},
		{name = "ironing_enabled", value = evidence_bool_u64(s.options.ironing_enabled)},
		{name = "ironing_paths", value = u64(len(s.ironing.paths))},
		{name = "infill_pattern", value = u64(s.options.infill_pattern)},
		{name = "infill_paths", value = infill_paths},
		{name = "gap_centerlines", value = u64(len(s.gaps.paths))},
		{name = "supports_enabled", value = evidence_bool_u64(s.options.enable_supports)},
		{name = "support_style_tree", value = evidence_bool_u64(s.options.support_style_tree)},
		{name = "support_paths", value = support_paths},
		{name = "adhesion_loops", value = u64(len(s.adhesion.loops))},
		{name = "modifier_zones", value = u64(len(s.options.modifiers))},
	}
	plan_counters := []evidence.Evidence_Counter{
		{name = "planned_paths", value = u64(len(s.unified_plan.paths))},
		{name = "planned_moves", value = u64(len(s.unified_plan.moves))},
		{name = "extrude_moves", value = extrude_moves},
		{name = "travel_moves", value = travel_moves},
		{name = "variable_walls_enabled", value = evidence_bool_u64(s.options.variable_walls_enabled)},
		{name = "variable_walls_vertices", value = s.variable_wall_stats.vertices_adapted},
		{name = "fuzzy_skin_enabled", value = evidence_bool_u64(s.options.fuzzy_skin_enabled)},
		{name = "fuzzy_skin_loops", value = s.fuzzy_skin_stats.loops_perturbed},
		{name = "extrusion_moves", value = u64(len(s.extrusion.moves))},
		{name = "total_filament_nm", value = u64(s.extrusion.total_filament_nm)},
		{name = "motion_operations", value = u64(len(s.motion.operations))},
		{name = "motion_extrusions", value = s.motion.extrusion_count},
		{name = "motion_retractions", value = s.motion.retraction_count},
		{name = "motion_travels", value = s.motion.travel_count},
		{name = "motion_dwells", value = s.motion.dwell_count},
		{name = "z_ramps_enabled", value = evidence_bool_u64(s.options.scarf_seam_enabled || s.options.vase_mode)},
		{name = "z_ramps_loops", value = s.z_ramp_stats.loops_ramped},
		{name = "z_ramps_ops", value = s.z_ramp_stats.ops_modified},
		{name = "arc_fitting_enabled", value = evidence_bool_u64(s.options.arc_fitting_enabled && !s.options.vase_mode)},
		{name = "arcs_fitted", value = s.arc_fit_stats.arcs_fitted},
		{name = "estimated_time_s", value = u64(s.estimated_seconds)},
	}
	gcode_counters := []evidence.Evidence_Counter{
		{name = "gcode_bytes", value = u64(len(s.klipper.bytes))},
		{name = "command_count", value = u64(len(s.klipper.commands))},
		{name = "validated", value = 1},
	}

	feature_ms := s.slots[.Surfaces_Skin].duration_ms + s.slots[.Perimeters].duration_ms +
		s.slots[.Bridges].duration_ms + s.slots[.Solid_Areas].duration_ms +
		s.slots[.Solid_Paths].duration_ms + s.slots[.Sparse_Infill].duration_ms +
		s.slots[.Gap_Fill].duration_ms + s.slots[.Supports].duration_ms
	plan_ms := s.slots[.Path_Plan].duration_ms + s.slots[.Motion].duration_ms

	gcode_extra_path := ""
	gcode_extra_bytes: []u8
	if level != .Summary && len(s.klipper.bytes) > 0 {
		gcode_extra_path = "stages/11-emit-gcode/output.gcode"
		gcode_extra_bytes = s.klipper.bytes
	}

	specs := [11]Stage_Spec{
		{kind = .Decode, provider_name = "hw-slicer.decode", elapsed_ms = 0, counters = decode_counters},
		{kind = .Resolve, provider_name = "hw-slicer.resolve", elapsed_ms = 0, counters = resolve_counters},
		{kind = .Normalize, provider_name = "hw-slicer.normalize", elapsed_ms = s.slots[.Model].duration_ms, counters = normalize_counters},
		{kind = .Schedule_Layers, provider_name = "hw-slicer.schedule-layers", elapsed_ms = s.slots[.Layer_Schedule].duration_ms, counters = schedule_counters},
		{kind = .Build_Acceleration, provider_name = "hw-slicer.build-acceleration", elapsed_ms = 0, counters = accel_counters},
		{kind = .Intersect, provider_name = "hw-slicer.intersect", elapsed_ms = s.slots[.Intersections].duration_ms, counters = intersect_counters},
		{kind = .Reconstruct_Topology, provider_name = "hw-slicer.reconstruct-topology", elapsed_ms = s.slots[.Topology].duration_ms, counters = topo_counters},
		{kind = .Calculate_Regions, provider_name = "hw-slicer.calculate-regions", elapsed_ms = s.slots[.Regions].duration_ms, counters = region_counters},
		{kind = .Generate_Features, provider_name = "hw-slicer.generate-features", elapsed_ms = feature_ms, counters = feature_counters},
		{kind = .Plan_Paths, provider_name = "hw-slicer.plan-paths", elapsed_ms = plan_ms, counters = plan_counters},
		{
			kind          = .Emit_GCode,
			provider_name = "hw-slicer.emit-gcode",
			elapsed_ms    = s.slots[.Gcode].duration_ms,
			counters      = gcode_counters,
			extra_path    = gcode_extra_path,
			extra_format  = "gcode",
			extra_bytes   = gcode_extra_bytes,
			extra_items   = u64(len(s.klipper.commands)),
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
			schema_version = evidence_stage_schema_version(spec.kind),
			revision       = 1,
		}

		primitives: []evidence.Evidence_Artifact
		if len(spec.extra_path) > 0 && len(spec.extra_bytes) > 0 {
			art, art_err := evidence.evidence_artifact_describe(
				spec.extra_path,
				spec.extra_format,
				contracts.SCHEMA_VERSION_STAGE_RESULT,
				max(u64(1), spec.extra_items),
				spec.extra_bytes,
				a,
			)
			if art_err != .None {
				return nil, {stage = "evidence", detail = fmt.tprintf("artifact describe failed for %s: %v", spec.extra_path, art_err)}
			}
			prims := make([]evidence.Evidence_Artifact, 1, a)
			prims[0] = art
			primitives = prims
			append(&files_list, art)
			append(&contents, evidence.Evidence_Bundle_Content{path = spec.extra_path, bytes = spec.extra_bytes})
		}

		sm := evidence.Evidence_Manifest{
			schema_version = contracts.SCHEMA_VERSION_DEBUG_EVIDENCE,
			request_hash   = request_hash_text,
			stage          = stage_info,
			provider       = prov,
			source_root_id = source_root_text,
			source_bounds  = src_bounds,
			planar_bounds  = planar_bounds,
			summary        = spec.counters,
			invariants     = spec.invariants,
			primitives     = primitives,
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
