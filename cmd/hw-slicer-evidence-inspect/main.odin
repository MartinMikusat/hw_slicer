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
	extrusion_loaded:      bool `json:"extrusion_loaded,omitempty"`,
	extrusion_layers:      u64  `json:"extrusion_layers,omitempty"`,
	extrusion_moves:       u64  `json:"extrusion_moves,omitempty"`,
	extrusion_volume_cubic_um: u64 `json:"extrusion_volume_cubic_um,omitempty"`,
	extrusion_filament_nm: string `json:"extrusion_filament_nm,omitempty"`,
	motion_plan_loaded:    bool `json:"motion_plan_loaded,omitempty"`,
	motion_plan_layers:    u64  `json:"motion_plan_layers,omitempty"`,
	motion_plan_operations: u64 `json:"motion_plan_operations,omitempty"`,
	motion_plan_retractions: u64 `json:"motion_plan_retractions,omitempty"`,
	motion_plan_travels:   u64  `json:"motion_plan_travels,omitempty"`,
	motion_plan_extrusions: u64 `json:"motion_plan_extrusions,omitempty"`,
	motion_plan_dwells:    u64  `json:"motion_plan_dwells,omitempty"`,
	motion_plan_motion_duration_us: u64 `json:"motion_plan_motion_duration_us,omitempty"`,
	motion_plan_dwell_duration_us: u64 `json:"motion_plan_dwell_duration_us,omitempty"`,
	motion_plan_total_duration_us: u64 `json:"motion_plan_total_duration_us,omitempty"`,
	marlin_loaded:         bool `json:"marlin_loaded,omitempty"`,
	marlin_commands:       u64  `json:"marlin_commands,omitempty"`,
	marlin_gcode_bytes:    u64  `json:"marlin_gcode_bytes,omitempty"`,
	marlin_layers:         u64  `json:"marlin_layers,omitempty"`,
	marlin_motion_operations: u64 `json:"marlin_motion_operations,omitempty"`,
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
	decoded := Evidence_Inspect_Decoded_Wire{
		topology_loaded = replay.topology_loaded,
		regions_loaded = replay.regions_loaded,
		path_plan_loaded = replay.path_plan_loaded,
		extrusion_loaded = replay.extrusion_loaded,
		motion_plan_loaded = replay.motion_plan_loaded,
		marlin_loaded = replay.marlin_loaded,
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
	if replay.extrusion_loaded {
		decoded.extrusion_layers =
			u64(len(replay.extrusion.result.layers))
		decoded.extrusion_moves =
			u64(len(replay.extrusion.result.moves))
		decoded.extrusion_volume_cubic_um =
			replay.extrusion.result.total_volume_cubic_um
		decoded.extrusion_filament_nm = fmt.tprintf(
			"%d",
			replay.extrusion.result.total_filament_nm,
		)
	}
	if replay.motion_plan_loaded {
		decoded.motion_plan_layers =
			u64(len(replay.motion_plan.result.layers))
		decoded.motion_plan_operations =
			u64(len(replay.motion_plan.result.operations))
		decoded.motion_plan_retractions =
			replay.motion_plan.result.retraction_count
		decoded.motion_plan_travels =
			replay.motion_plan.result.travel_count
		decoded.motion_plan_extrusions =
			replay.motion_plan.result.extrusion_count
		decoded.motion_plan_dwells =
			replay.motion_plan.result.dwell_count
		decoded.motion_plan_motion_duration_us =
			replay.motion_plan.result.total_motion_duration_us
		decoded.motion_plan_dwell_duration_us =
			replay.motion_plan.result.total_dwell_duration_us
		decoded.motion_plan_total_duration_us =
			replay.motion_plan.result.total_planned_duration_us
	}
	if replay.marlin_loaded {
		decoded.marlin_commands =
			u64(len(replay.marlin.result.commands))
		decoded.marlin_gcode_bytes =
			u64(len(replay.marlin.result.bytes))
		decoded.marlin_layers =
			u64(replay.marlin.result.layer_count)
		decoded.marlin_motion_operations =
			replay.marlin.result.motion_operation_count
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
