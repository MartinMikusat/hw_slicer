package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"

import evidence "../../src/evidence"

Evidence_Inspect_Stage_Wire :: struct {
	ordinal:          u32,
	name:             string,
	schema_version:   u32,
	revision:         u32,
	provider:         string,
	provider_version: string,
	primitive_count:  u64,
	render_count:     u64,
	item_count:       u64,
	byte_count:       u64,
	summary:          []evidence.Evidence_Counter,
}

Evidence_Inspect_Decoded_Wire :: struct {
	layer_schedule_loaded: ^bool `json:"layer_schedule_loaded,omitempty"`,
	layer_schedule_layers: ^u64  `json:"layer_schedule_layers,omitempty"`,
	layer_schedule_minimum_z_um: ^i64 `json:"layer_schedule_minimum_z_um,omitempty"`,
	layer_schedule_maximum_z_um: ^i64 `json:"layer_schedule_maximum_z_um,omitempty"`,
	layer_schedule_first_plane_z_um: ^i64 `json:"layer_schedule_first_plane_z_um,omitempty"`,
	layer_schedule_step_um: ^i64 `json:"layer_schedule_step_um,omitempty"`,
	layer_spans_loaded:     ^bool `json:"layer_spans_loaded,omitempty"`,
	span_triangles:         ^u64  `json:"span_triangles,omitempty"`,
	span_layers:            ^u64  `json:"span_layers,omitempty"`,
	triangle_layer_pairs:   ^u64  `json:"triangle_layer_pairs,omitempty"`,
	crossing_triangles:     ^u64  `json:"crossing_triangles,omitempty"`,
	planar_triangles:       ^u64  `json:"planar_triangles,omitempty"`,
	inactive_triangles:     ^u64  `json:"inactive_triangles,omitempty"`,
	intersections_loaded:   ^bool `json:"intersections_loaded,omitempty"`,
	intersection_layers:    ^u64  `json:"intersection_layers,omitempty"`,
	raw_segments:           ^u64  `json:"raw_segments,omitempty"`,
	planar_candidates:      ^u64  `json:"planar_candidates,omitempty"`,
	tangent_pairs:          ^u64  `json:"tangent_pairs,omitempty"`,
	degenerate_pairs:       ^u64  `json:"degenerate_pairs,omitempty"`,
	exact_predicates:       ^u64  `json:"exact_predicates,omitempty"`,
	topology_loaded:       bool,
	topology_layers:       u64,
	topology_vertices:     u64,
	topology_paths:        u64,
	regions_loaded:        bool,
	region_layers:         u64,
	region_contours:       u64,
	regions:               u64,
	region_holes:          u64,
	path_plan_loaded:      bool,
	path_plan_layers:      u64,
	path_plan_paths:       u64,
	path_plan_moves:       u64,
	path_plan_travel_moves: u64,
	path_plan_extrude_moves: u64,
	infill_loaded:         ^bool `json:"infill_loaded,omitempty"`,
	infill_layers:         ^u64  `json:"infill_layers,omitempty"`,
	infill_segments:       ^u64  `json:"infill_segments,omitempty"`,
	infill_boundary_hits:  ^u64  `json:"infill_boundary_hits,omitempty"`,
	infill_scanlines:      ^u64  `json:"infill_scanlines,omitempty"`,
	perimeters_loaded:     ^bool `json:"perimeters_loaded,omitempty"`,
	perimeter_layers:      ^u64  `json:"perimeter_layers,omitempty"`,
	perimeter_groups:      ^u64  `json:"perimeter_groups,omitempty"`,
	perimeter_paths:       ^u64  `json:"perimeter_paths,omitempty"`,
	perimeter_points:      ^u64  `json:"perimeter_points,omitempty"`,
	surfaces_loaded:       ^bool `json:"surfaces_loaded,omitempty"`,
	surface_layers:        ^u64  `json:"surface_layers,omitempty"`,
	surface_masks:         ^u64  `json:"surface_masks,omitempty"`,
	surface_paths:         ^u64  `json:"surface_paths,omitempty"`,
	surface_points:        ^u64  `json:"surface_points,omitempty"`,
	surface_bottom_masks:  ^u64  `json:"surface_bottom_masks,omitempty"`,
	surface_top_masks:     ^u64  `json:"surface_top_masks,omitempty"`,
	unified_sources_loaded: ^bool `json:"unified_sources_loaded,omitempty"`,
	unified_source_layers: ^u64 `json:"unified_source_layers,omitempty"`,
	unified_sources:       ^u64 `json:"unified_sources,omitempty"`,
	unified_source_points: ^u64 `json:"unified_source_points,omitempty"`,
	unified_path_plan_loaded: ^bool `json:"unified_path_plan_loaded,omitempty"`,
	unified_path_plan_layers: ^u64 `json:"unified_path_plan_layers,omitempty"`,
	unified_path_plan_paths: ^u64 `json:"unified_path_plan_paths,omitempty"`,
	unified_path_plan_moves: ^u64 `json:"unified_path_plan_moves,omitempty"`,
	unified_path_plan_travel_moves: ^u64 `json:"unified_path_plan_travel_moves,omitempty"`,
	unified_path_plan_extrude_moves: ^u64 `json:"unified_path_plan_extrude_moves,omitempty"`,
	extrusion_loaded:      ^bool `json:"extrusion_loaded,omitempty"`,
	extrusion_layers:      ^u64  `json:"extrusion_layers,omitempty"`,
	extrusion_moves:       ^u64  `json:"extrusion_moves,omitempty"`,
	extrusion_volume_cubic_um: ^u64 `json:"extrusion_volume_cubic_um,omitempty"`,
	extrusion_filament_nm: string `json:"extrusion_filament_nm,omitempty"`,
	motion_plan_loaded:    ^bool `json:"motion_plan_loaded,omitempty"`,
	motion_plan_layers:    ^u64  `json:"motion_plan_layers,omitempty"`,
	motion_plan_operations: ^u64 `json:"motion_plan_operations,omitempty"`,
	motion_plan_retractions: ^u64 `json:"motion_plan_retractions,omitempty"`,
	motion_plan_travels:   ^u64  `json:"motion_plan_travels,omitempty"`,
	motion_plan_extrusions: ^u64 `json:"motion_plan_extrusions,omitempty"`,
	motion_plan_dwells:    ^u64  `json:"motion_plan_dwells,omitempty"`,
	motion_plan_motion_duration_us: ^u64 `json:"motion_plan_motion_duration_us,omitempty"`,
	motion_plan_dwell_duration_us: ^u64 `json:"motion_plan_dwell_duration_us,omitempty"`,
	motion_plan_total_duration_us: ^u64 `json:"motion_plan_total_duration_us,omitempty"`,
	marlin_loaded:         ^bool `json:"marlin_loaded,omitempty"`,
	marlin_commands:       ^u64  `json:"marlin_commands,omitempty"`,
	marlin_gcode_bytes:    ^u64  `json:"marlin_gcode_bytes,omitempty"`,
	marlin_layers:         ^u64  `json:"marlin_layers,omitempty"`,
	marlin_motion_operations: ^u64 `json:"marlin_motion_operations,omitempty"`,
}

Evidence_Inspect_Wire :: struct {
	schema_version: u32,
	source:         string,
	container:      string,
	request_hash:   string,
	source_root_id: string,
	stage_count:    u64,
	file_count:     u64,
	stages:         []Evidence_Inspect_Stage_Wire,
	decoded:        Evidence_Inspect_Decoded_Wire,
	validated:      bool,
}

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln(
			"usage: hw-slicer-evidence-inspect <evidence-bundle-or-directory>",
		)
		os.exit(2)
	}
	replay, kind, load_error :=
		evidence.evidence_bundle_path_replay(os.args[1])
	defer evidence.evidence_bundle_replay_destroy(&replay)
	if load_error != .None {
		fmt.eprintf(
			"[hw_slicer] evidence inspection failed: %v\n",
			load_error,
		)
		os.exit(1)
	}
	stages := make(
		[]Evidence_Inspect_Stage_Wire,
		len(replay.root.stages),
	)
	defer delete(stages)
	for stage, stage_index in replay.root.stages {
		manifest := replay.stage_manifests[stage_index]
		item_count: u64
		byte_count: u64
		for primitive in manifest.primitives {
			item_count += primitive.item_count
			byte_count += primitive.byte_count
		}
		for render in manifest.renders {
			item_count += render.item_count
			byte_count += render.byte_count
		}
		stages[stage_index] = {
			ordinal = stage.ordinal,
			name = stage.stage.name,
			schema_version = stage.stage.schema_version,
			revision = stage.stage.revision,
			provider = stage.provider.name,
			provider_version = stage.provider.version,
			primitive_count = u64(len(manifest.primitives)),
			render_count = u64(len(manifest.renders)),
			item_count = item_count,
			byte_count = byte_count,
			summary = manifest.summary,
		}
	}
	infill_layers: u64
	infill_segments: u64
	infill_boundary_hits: u64
	perimeter_layers: u64
	perimeter_groups: u64
	perimeter_paths: u64
	perimeter_points: u64
	surface_layers: u64
	surface_masks: u64
	surface_paths: u64
	surface_points: u64
	unified_source_layers: u64
	unified_sources: u64
	unified_source_points: u64
	unified_path_plan_layers: u64
	unified_path_plan_paths: u64
	unified_path_plan_moves: u64
	extrusion_layers: u64
	extrusion_moves: u64
	motion_plan_layers: u64
	motion_plan_operations: u64
	marlin_commands: u64
	marlin_gcode_bytes: u64
	marlin_layers: u64
	layer_schedule_layers: u64
	layer_schedule_minimum_z_um: i64
	layer_schedule_maximum_z_um: i64
	layer_schedule_first_plane_z_um: i64
	layer_schedule_step_um: i64
	span_triangles: u64
	span_layers: u64
	triangle_layer_pairs: u64
	crossing_triangles: u64
	planar_triangles: u64
	inactive_triangles: u64
	intersection_layers: u64
	raw_segments: u64
	planar_candidates: u64
	tangent_pairs: u64
	degenerate_pairs: u64
	exact_predicates: u64
	decoded := Evidence_Inspect_Decoded_Wire{
		topology_loaded = replay.topology_loaded,
		regions_loaded = replay.regions_loaded,
		path_plan_loaded = replay.path_plan_loaded,
	}
	if replay.layer_schedule_loaded {
		layer_schedule_layers =
			u64(len(replay.layer_schedule.result.layer_z))
		layer_schedule_minimum_z_um =
			i64(replay.layer_schedule.result.minimum_z)
		layer_schedule_maximum_z_um =
			i64(replay.layer_schedule.result.maximum_z)
		layer_schedule_first_plane_z_um =
			i64(replay.layer_schedule.result.first_plane_z)
		layer_schedule_step_um =
			i64(replay.layer_schedule.result.layer_step)
		decoded.layer_schedule_loaded =
			&replay.layer_schedule_loaded
		decoded.layer_schedule_layers = &layer_schedule_layers
		decoded.layer_schedule_minimum_z_um =
			&layer_schedule_minimum_z_um
		decoded.layer_schedule_maximum_z_um =
			&layer_schedule_maximum_z_um
		decoded.layer_schedule_first_plane_z_um =
			&layer_schedule_first_plane_z_um
		decoded.layer_schedule_step_um = &layer_schedule_step_um
	}
	if replay.layer_spans_loaded {
		span_triangles =
			u64(len(replay.layer_spans.result.triangle_ranges))
		span_layers = u64(len(replay.layer_spans.result.layers))
		triangle_layer_pairs =
			u64(len(replay.layer_spans.result.triangle_ids))
		for range_value in replay.layer_spans.result.triangle_ranges {
			switch range_value.kind {
			case .None:
				inactive_triangles += 1
			case .Crossing_Candidates:
				crossing_triangles += 1
			case .Quantized_Planar:
				planar_triangles += 1
			case:
			}
		}
		decoded.layer_spans_loaded = &replay.layer_spans_loaded
		decoded.span_triangles = &span_triangles
		decoded.span_layers = &span_layers
		decoded.triangle_layer_pairs = &triangle_layer_pairs
		decoded.crossing_triangles = &crossing_triangles
		decoded.planar_triangles = &planar_triangles
		decoded.inactive_triangles = &inactive_triangles
	}
	if replay.intersections_loaded {
		intersection_layers =
			u64(len(replay.intersections.result.layers))
		raw_segments =
			u64(len(replay.intersections.result.segments.segment_ids))
		planar_candidates =
			u64(len(replay.intersections.result.planar_candidates))
		tangent_pairs = replay.intersections.result.tangent_count
		degenerate_pairs =
			replay.intersections.result.degenerate_count
		exact_predicates =
			replay.intersections.result.exact_predicate_count
		decoded.intersections_loaded =
			&replay.intersections_loaded
		decoded.intersection_layers = &intersection_layers
		decoded.raw_segments = &raw_segments
		decoded.planar_candidates = &planar_candidates
		decoded.tangent_pairs = &tangent_pairs
		decoded.degenerate_pairs = &degenerate_pairs
		decoded.exact_predicates = &exact_predicates
	}
	if replay.topology_loaded {
		decoded.topology_layers = u64(len(replay.topology.result.layers))
		decoded.topology_vertices = u64(len(replay.topology.result.vertices))
		decoded.topology_paths = u64(len(replay.topology.result.paths))
	}
	if replay.regions_loaded {
		decoded.region_layers = u64(len(replay.regions.result.layers))
		decoded.region_contours =
			u64(len(replay.regions.result.contours))
		decoded.regions = u64(len(replay.regions.result.regions))
		decoded.region_holes = replay.regions.result.hole_count
	}
	if replay.path_plan_loaded {
		decoded.path_plan_layers =
			u64(len(replay.path_plan.result.layers))
		decoded.path_plan_paths =
			u64(len(replay.path_plan.result.paths))
		decoded.path_plan_moves =
			u64(len(replay.path_plan.result.moves))
		decoded.path_plan_travel_moves =
			replay.path_plan.result.travel_move_count
		decoded.path_plan_extrude_moves =
			replay.path_plan.result.extrude_move_count
	}
	if replay.infill_loaded {
		infill_layers = u64(len(replay.infill.result.layers))
		infill_segments = u64(len(replay.infill.result.segments))
		infill_boundary_hits =
			u64(len(replay.infill.result.boundary_hits))
		decoded.infill_loaded = &replay.infill_loaded
		decoded.infill_layers = &infill_layers
		decoded.infill_segments = &infill_segments
		decoded.infill_boundary_hits = &infill_boundary_hits
		decoded.infill_scanlines =
			&replay.infill.result.scanline_count
	}
	if replay.perimeters_loaded {
		perimeter_layers =
			u64(len(replay.perimeters.result.layers))
		perimeter_groups =
			u64(len(replay.perimeters.result.groups))
		perimeter_paths =
			u64(len(replay.perimeters.result.paths))
		perimeter_points =
			u64(len(replay.perimeters.result.points))
		decoded.perimeters_loaded = &replay.perimeters_loaded
		decoded.perimeter_layers = &perimeter_layers
		decoded.perimeter_groups = &perimeter_groups
		decoded.perimeter_paths = &perimeter_paths
		decoded.perimeter_points = &perimeter_points
	}
	if replay.surfaces_loaded {
		surface_layers = u64(len(replay.surfaces.result.layers))
		surface_masks = u64(len(replay.surfaces.result.masks))
		surface_paths = u64(len(replay.surfaces.result.paths))
		surface_points = u64(len(replay.surfaces.result.points))
		decoded.surfaces_loaded = &replay.surfaces_loaded
		decoded.surface_layers = &surface_layers
		decoded.surface_masks = &surface_masks
		decoded.surface_paths = &surface_paths
		decoded.surface_points = &surface_points
		decoded.surface_bottom_masks =
			&replay.surfaces.result.bottom_mask_count
		decoded.surface_top_masks =
			&replay.surfaces.result.top_mask_count
	}
	if replay.unified_sources_loaded {
		unified_source_layers =
			u64(len(replay.unified_sources.result.layers))
		unified_sources =
			u64(len(replay.unified_sources.result.sources))
		unified_source_points =
			u64(len(replay.unified_sources.result.points))
		decoded.unified_sources_loaded =
			&replay.unified_sources_loaded
		decoded.unified_source_layers = &unified_source_layers
		decoded.unified_sources = &unified_sources
		decoded.unified_source_points = &unified_source_points
	}
	if replay.unified_plan_loaded {
		unified_path_plan_layers =
			u64(len(replay.unified_plan.result.layers))
		unified_path_plan_paths =
			u64(len(replay.unified_plan.result.paths))
		unified_path_plan_moves =
			u64(len(replay.unified_plan.result.moves))
		decoded.unified_path_plan_loaded =
			&replay.unified_plan_loaded
		decoded.unified_path_plan_layers =
			&unified_path_plan_layers
		decoded.unified_path_plan_paths =
			&unified_path_plan_paths
		decoded.unified_path_plan_moves =
			&unified_path_plan_moves
		decoded.unified_path_plan_travel_moves =
			&replay.unified_plan.result.travel_move_count
		decoded.unified_path_plan_extrude_moves =
			&replay.unified_plan.result.extrude_move_count
	}
	if replay.extrusion_loaded {
		extrusion_layers =
			u64(len(replay.extrusion.result.layers))
		extrusion_moves =
			u64(len(replay.extrusion.result.moves))
		decoded.extrusion_loaded = &replay.extrusion_loaded
		decoded.extrusion_layers = &extrusion_layers
		decoded.extrusion_moves = &extrusion_moves
		decoded.extrusion_volume_cubic_um =
			&replay.extrusion.result.total_volume_cubic_um
		decoded.extrusion_filament_nm = fmt.tprintf(
			"%d",
			replay.extrusion.result.total_filament_nm,
		)
	}
	if replay.motion_plan_loaded {
		motion_plan_layers =
			u64(len(replay.motion_plan.result.layers))
		motion_plan_operations =
			u64(len(replay.motion_plan.result.operations))
		decoded.motion_plan_loaded = &replay.motion_plan_loaded
		decoded.motion_plan_layers = &motion_plan_layers
		decoded.motion_plan_operations = &motion_plan_operations
		decoded.motion_plan_retractions =
			&replay.motion_plan.result.retraction_count
		decoded.motion_plan_travels =
			&replay.motion_plan.result.travel_count
		decoded.motion_plan_extrusions =
			&replay.motion_plan.result.extrusion_count
		decoded.motion_plan_dwells =
			&replay.motion_plan.result.dwell_count
		decoded.motion_plan_motion_duration_us =
			&replay.motion_plan.result.total_motion_duration_us
		decoded.motion_plan_dwell_duration_us =
			&replay.motion_plan.result.total_dwell_duration_us
		decoded.motion_plan_total_duration_us =
			&replay.motion_plan.result.total_planned_duration_us
	}
	if replay.marlin_loaded {
		marlin_commands =
			u64(len(replay.marlin.result.commands))
		marlin_gcode_bytes =
			u64(len(replay.marlin.result.bytes))
		marlin_layers =
			u64(replay.marlin.result.layer_count)
		decoded.marlin_loaded = &replay.marlin_loaded
		decoded.marlin_commands = &marlin_commands
		decoded.marlin_gcode_bytes = &marlin_gcode_bytes
		decoded.marlin_layers = &marlin_layers
		decoded.marlin_motion_operations =
			&replay.marlin.result.motion_operation_count
	}
	wire := Evidence_Inspect_Wire{
		schema_version = 1,
		source = filepath.base(os.args[1]),
		container = "package" if kind == .Package else "directory",
		request_hash = replay.root.request_hash,
		source_root_id = replay.root.source_root_id,
		stage_count = replay.summary.stage_count,
		file_count = replay.summary.file_count,
		stages = stages,
		decoded = decoded,
		validated = true,
	}
	output, encode_error := json.marshal(
		wire,
		{
			pretty = true,
			use_spaces = true,
			spaces = 2,
			sort_maps_by_key = true,
		},
	)
	if encode_error != nil {
		fmt.eprintln("[hw_slicer] evidence inspection encoding failed")
		os.exit(1)
	}
	defer delete(output)
	fmt.println(string(output))
}
