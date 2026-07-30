package main

import "base:intrinsics"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:time"

import benchmark "../../src/benchmark"
import contracts "../../src/contracts"
import features "../../src/features"
import formats "../../src/formats"
import pipeline "../../src/pipeline"
import polygon "../../src/polygon"
import repair "../../src/repair"
import slicing "../../src/slicing"

FEATURE_BENCHMARK_WARMUP_COUNT :: 2
FEATURE_BENCHMARK_ITERATION_COUNT :: 20
FEATURE_BENCHMARK_MAXIMUM_P95_NS :: u64(3_000_000_000)

Feature_Benchmark_Environment :: struct {
	hardware:      string,
	os_build:      string,
	odin_version:  string,
	clang_version: string,
	git_revision:  string,
	git_dirty:     string,
	thermal_state: string,
}

Feature_Benchmark_Metrics :: struct {
	region_count:      u64,
	hole_count:        u64,
	surface_masks:     u64,
	surface_paths:     u64,
	surface_points:    u64,
	surface_booleans:  u64,
	perimeter_paths:   u64,
	perimeter_points:  u64,
	perimeter_offsets: u64,
	infill_segments:   u64,
	infill_offsets:    u64,
	planned_paths:     u64,
	planned_moves:     u64,
	travel_moves:      u64,
	extrude_moves:     u64,
}

Feature_Benchmark_Timings :: struct {
	regions_ns:    u64,
	surfaces_ns:   u64,
	perimeters_ns: u64,
	infill_ns:     u64,
	path_plan_ns:  u64,
}

Feature_Benchmark_Timing_Wire :: struct {
	samples_ns: []u64,
	p50_ns:     u64,
	p95_ns:     u64,
}

Feature_Benchmark_Stage_Timings_Wire :: struct {
	regions:    Feature_Benchmark_Timing_Wire,
	surfaces:   Feature_Benchmark_Timing_Wire,
	perimeters: Feature_Benchmark_Timing_Wire,
	infill:     Feature_Benchmark_Timing_Wire,
	path_plan:  Feature_Benchmark_Timing_Wire,
}

Feature_Benchmark_Wire :: struct {
	schema_version:          u32,
	benchmark:               string,
	fixture_version:         u32,
	fixture:                 string,
	mode:                    string,
	environment:             Feature_Benchmark_Environment,
	warmup_count:            int,
	iteration_count:         int,
	region_count:            u64,
	hole_count:              u64,
	surface_mask_count:      u64,
	surface_path_count:      u64,
	surface_point_count:     u64,
	surface_boolean_calls:   u64,
	perimeter_path_count:    u64,
	perimeter_point_count:   u64,
	perimeter_offset_calls:  u64,
	infill_segment_count:    u64,
	infill_offset_calls:     u64,
	planned_path_count:      u64,
	planned_move_count:      u64,
	travel_move_count:       u64,
	extrude_move_count:      u64,
	topology_policy:         string,
	printable_output:        bool,
	region_hash:             string,
	surface_hash:            string,
	perimeter_hash:          string,
	infill_hash:             string,
	path_plan_hash:          string,
	samples_ns:              []u64,
	p50_ns:                  u64,
	p95_ns:                  u64,
	maximum_p95_ns:          u64,
	stage_timings:           Feature_Benchmark_Stage_Timings_Wire,
	paths_per_second:        f64,
	moves_per_second:        f64,
	validated:               bool,
}

feature_benchmark_sink: u64
feature_benchmark_boolean_calls: u64
feature_benchmark_offset_calls: u64

FEATURE_BENCHMARK_PROVIDER :: polygon.Polygon_Provider{
	name = "Clipper2 counted",
	version = {2, 0, 1},
	boolean = feature_benchmark_boolean,
	offset = feature_benchmark_offset,
}

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln(
			"usage: hw-slicer-feature-benchmark <all-in-one-test.stl>",
		)
		os.exit(2)
	}
	bytes, read_error := formats.source_file_read_bounded(
		os.args[1],
		84,
		formats.DEFAULT_BINARY_STL_LIMITS.max_source_bytes,
	)
	if read_error != .None {
		fmt.eprintf(
			"[hw_slicer] feature benchmark fixture read failed: %v\n",
			read_error,
		)
		os.exit(1)
	}
	defer delete(bytes)
	spine, spine_error := pipeline.slice_spine_binary_stl(bytes, {
		source_units = .Millimetres,
		first_layer_height = 200,
		layer_height = 200,
		max_layer_count = 10_000_000,
	})
	if spine_error != .None ||
	   spine.mesh.source.content_hash !=
	   	benchmark.SPINE_FIXTURE_SOURCE_HASH ||
	   spine.hashes.topology != benchmark.SPINE_FIXTURE_TOPOLOGY_HASH {
		fmt.eprintf(
			"[hw_slicer] feature benchmark spine failed: %v\n",
			spine_error,
		)
		os.exit(1)
	}
	defer pipeline.slice_spine_result_destroy(&spine)
	failure: slicing.Region_Failure
	strict_regions, strict_error := slicing.regions_build(
		spine.topology,
		failure = &failure,
	)
	slicing.region_result_destroy(&strict_regions)
	if strict_error != .Contour_Intersection {
		fmt.eprintln("[hw_slicer] feature benchmark failure changed")
		os.exit(1)
	}
	repair_result, repair_error := repair.contour_path_repair(
		spine.topology,
		polygon.CLIPPER2_PROVIDER,
		{
			failure = failure,
			fill_rule = .Even_Odd,
			lineage_tolerance = 2,
		},
	)
	if repair_error != .None {
		fmt.eprintf(
			"[hw_slicer] feature benchmark repair failed: %v\n",
			repair_error,
		)
		os.exit(1)
	}
	defer repair.contour_repair_result_destroy(&repair_result)
	repair_hash, repair_hash_ok := repair.contour_repair_result_hash(
		spine.hashes.topology,
		repair_result,
	)
	if !repair_hash_ok ||
	   repair_hash != benchmark.SPINE_FIXTURE_REPAIR_HASH {
		fmt.eprintln("[hw_slicer] feature benchmark repair hash changed")
		os.exit(1)
	}
	repaired_topology, apply_error :=
		repair.contour_repair_apply_for_regions(
			spine.topology,
			repair_result,
		)
	if apply_error != .None {
		fmt.eprintf(
			"[hw_slicer] feature benchmark apply failed: %v\n",
			apply_error,
		)
		os.exit(1)
	}
	defer slicing.topology_result_destroy(&repaired_topology)

	for _ in 0..<FEATURE_BENCHMARK_WARMUP_COUNT {
		metrics, _, run_ok := feature_benchmark_run_once(
			repaired_topology,
			repair_hash,
		)
		if !run_ok {os.exit(1)}
		intrinsics.volatile_store(
			&feature_benchmark_sink,
			metrics.planned_moves,
		)
	}
	samples := make([]u64, FEATURE_BENCHMARK_ITERATION_COUNT)
	defer delete(samples)
	region_samples := make([]u64, FEATURE_BENCHMARK_ITERATION_COUNT)
	defer delete(region_samples)
	surface_samples := make([]u64, FEATURE_BENCHMARK_ITERATION_COUNT)
	defer delete(surface_samples)
	perimeter_samples := make([]u64, FEATURE_BENCHMARK_ITERATION_COUNT)
	defer delete(perimeter_samples)
	infill_samples := make([]u64, FEATURE_BENCHMARK_ITERATION_COUNT)
	defer delete(infill_samples)
	path_plan_samples := make([]u64, FEATURE_BENCHMARK_ITERATION_COUNT)
	defer delete(path_plan_samples)
	reference: Feature_Benchmark_Metrics
	for iteration in 0..<FEATURE_BENCHMARK_ITERATION_COUNT {
		started := time.tick_now()
		metrics, timings, run_ok := feature_benchmark_run_once(
			repaired_topology,
			repair_hash,
		)
		elapsed := time.tick_since(started)
		if !run_ok {os.exit(1)}
		if iteration == 0 {
			reference = metrics
		} else if metrics != reference {
			fmt.eprintln("[hw_slicer] feature benchmark counters changed")
			os.exit(1)
		}
		samples[iteration] = u64(max(i64(elapsed), 1))
		region_samples[iteration] = timings.regions_ns
		surface_samples[iteration] = timings.surfaces_ns
		perimeter_samples[iteration] = timings.perimeters_ns
		infill_samples[iteration] = timings.infill_ns
		path_plan_samples[iteration] = timings.path_plan_ns
		intrinsics.volatile_store(
			&feature_benchmark_sink,
			metrics.planned_moves,
		)
	}
	benchmark.sort_u64(samples)
	p50_ns := samples[len(samples)/2]
	p95_index := (95*len(samples)+99)/100-1
	p95_ns := samples[p95_index]
	if p95_ns > FEATURE_BENCHMARK_MAXIMUM_P95_NS {
		fmt.eprintf(
			"[hw_slicer] feature benchmark exceeded p95 limit: %d ns\n",
			p95_ns,
		)
		os.exit(1)
	}
	stage_timings := Feature_Benchmark_Stage_Timings_Wire{
		regions = feature_benchmark_timing_wire(region_samples),
		surfaces = feature_benchmark_timing_wire(surface_samples),
		perimeters = feature_benchmark_timing_wire(perimeter_samples),
		infill = feature_benchmark_timing_wire(infill_samples),
		path_plan = feature_benchmark_timing_wire(path_plan_samples),
	}
	region_hash_text := feature_benchmark_hash_text(
		benchmark.SPINE_FIXTURE_REPAIRED_REGION_HASH,
	)
	defer delete(region_hash_text)
	perimeter_hash_text := feature_benchmark_hash_text(
		benchmark.SPINE_FIXTURE_PERIMETER_HASH,
	)
	defer delete(perimeter_hash_text)
	surface_hash_text := feature_benchmark_hash_text(
		benchmark.SPINE_FIXTURE_SURFACE_HASH,
	)
	defer delete(surface_hash_text)
	infill_hash_text := feature_benchmark_hash_text(
		benchmark.SPINE_FIXTURE_INFILL_HASH,
	)
	defer delete(infill_hash_text)
	path_plan_hash_text := feature_benchmark_hash_text(
		benchmark.SPINE_FIXTURE_PATH_PLAN_HASH,
	)
	defer delete(path_plan_hash_text)
	wire := Feature_Benchmark_Wire{
		schema_version = 3,
		benchmark = "repaired-regions-to-features-and-planar-path-plan",
		fixture_version = 1,
		fixture = "all-in-one-test.stl",
		mode = "release",
		environment = {
			hardware = os.get_env("HW_SLICER_BENCH_HARDWARE"),
			os_build = os.get_env("HW_SLICER_BENCH_OS_BUILD"),
			odin_version = os.get_env("HW_SLICER_BENCH_ODIN"),
			clang_version = os.get_env("HW_SLICER_BENCH_CLANG"),
			git_revision = os.get_env("HW_SLICER_BENCH_GIT"),
			git_dirty = os.get_env("HW_SLICER_BENCH_DIRTY"),
			thermal_state = os.get_env("HW_SLICER_BENCH_THERMAL"),
		},
		warmup_count = FEATURE_BENCHMARK_WARMUP_COUNT,
		iteration_count = FEATURE_BENCHMARK_ITERATION_COUNT,
		region_count = reference.region_count,
		hole_count = reference.hole_count,
		surface_mask_count = reference.surface_masks,
		surface_path_count = reference.surface_paths,
		surface_point_count = reference.surface_points,
		surface_boolean_calls = reference.surface_booleans,
		perimeter_path_count = reference.perimeter_paths,
		perimeter_point_count = reference.perimeter_points,
		perimeter_offset_calls = reference.perimeter_offsets,
		infill_segment_count = reference.infill_segments,
		infill_offset_calls = reference.infill_offsets,
		planned_path_count = reference.planned_paths,
		planned_move_count = reference.planned_moves,
		travel_move_count = reference.travel_moves,
		extrude_move_count = reference.extrude_moves,
		topology_policy = "strict-printable",
		printable_output = true,
		region_hash = string(region_hash_text),
		surface_hash = string(surface_hash_text),
		perimeter_hash = string(perimeter_hash_text),
		infill_hash = string(infill_hash_text),
		path_plan_hash = string(path_plan_hash_text),
		samples_ns = samples,
		p50_ns = p50_ns,
		p95_ns = p95_ns,
		maximum_p95_ns = FEATURE_BENCHMARK_MAXIMUM_P95_NS,
		stage_timings = stage_timings,
		paths_per_second =
			f64(reference.planned_paths)*1_000_000_000/f64(p50_ns),
		moves_per_second =
			f64(reference.planned_moves)*1_000_000_000/f64(p50_ns),
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
		fmt.eprintln("[hw_slicer] feature benchmark encoding failed")
		os.exit(1)
	}
	defer delete(output)
	fmt.println(string(output))
}

feature_benchmark_run_once :: proc(
	topology: slicing.Topology_Result,
	repair_hash: contracts.Content_Hash,
) -> (
	Feature_Benchmark_Metrics,
	Feature_Benchmark_Timings,
	bool,
) {
	timings: Feature_Benchmark_Timings
	stage_started := time.tick_now()
	regions, region_error := slicing.regions_build(topology)
	if region_error != .None {
		fmt.eprintf(
			"[hw_slicer] feature benchmark regions failed: %v\n",
			region_error,
		)
		return {}, {}, false
	}
	defer slicing.region_result_destroy(&regions)
	region_hash, region_hash_ok := slicing.region_result_hash(
		repair_hash,
		topology,
		regions,
	)
	if !region_hash_ok ||
	   region_hash != benchmark.SPINE_FIXTURE_REPAIRED_REGION_HASH {
		fmt.eprintln("[hw_slicer] feature benchmark region hash changed")
		return {}, {}, false
	}
	timings.regions_ns = feature_benchmark_elapsed_ns(stage_started)
	stage_started = time.tick_now()
	feature_benchmark_boolean_calls = 0
	surfaces, surface_error := features.surfaces_classify(
		topology,
		regions,
		FEATURE_BENCHMARK_PROVIDER,
		{
			fill_rule = .Even_Odd,
			topology_policy = .Strict_Printable,
		},
	)
	if surface_error != .None {
		fmt.eprintf(
			"[hw_slicer] feature benchmark surfaces failed: %v\n",
			surface_error,
		)
		return {}, {}, false
	}
	defer features.surface_result_destroy(&surfaces)
	surface_hash, surface_hash_ok := features.surface_result_hash(
		region_hash,
		surfaces,
	)
	if !surface_hash_ok ||
	   surface_hash != benchmark.SPINE_FIXTURE_SURFACE_HASH {
		fmt.eprintln("[hw_slicer] feature benchmark surface hash changed")
		return {}, {}, false
	}
	surface_boolean_calls := feature_benchmark_boolean_calls
	timings.surfaces_ns = feature_benchmark_elapsed_ns(stage_started)
	stage_started = time.tick_now()
	feature_benchmark_offset_calls = 0
	perimeters, perimeter_error := features.perimeters_generate(
		topology,
		regions,
		FEATURE_BENCHMARK_PROVIDER,
		{
			count = 2,
			line_width = 450,
			topology_policy = .Strict_Printable,
			join_type = .Miter,
			miter_limit = 2,
			arc_tolerance = 0,
		},
	)
	if perimeter_error != .None {
		fmt.eprintf(
			"[hw_slicer] feature benchmark perimeters failed: %v\n",
			perimeter_error,
		)
		return {}, {}, false
	}
	defer features.perimeter_result_destroy(&perimeters)
	perimeter_hash, perimeter_hash_ok := features.perimeter_result_hash(
		region_hash,
		perimeters,
	)
	if !perimeter_hash_ok ||
	   perimeter_hash != benchmark.SPINE_FIXTURE_PERIMETER_HASH {
		fmt.eprintln("[hw_slicer] feature benchmark perimeter hash changed")
		return {}, {}, false
	}
	perimeter_offset_calls := feature_benchmark_offset_calls
	timings.perimeters_ns = feature_benchmark_elapsed_ns(stage_started)
	stage_started = time.tick_now()
	feature_benchmark_offset_calls = 0
	infill, infill_error := features.infill_generate(
		topology,
		regions,
		FEATURE_BENCHMARK_PROVIDER,
		{
			spacing = 5_000,
			boundary_inset = 900,
			phase = 0,
			base_axis = .Vertical,
			alternate_each_layer = true,
			topology_policy = .Strict_Printable,
			join_type = .Miter,
			miter_limit = 2,
			arc_tolerance = 0,
		},
	)
	if infill_error != .None {
		fmt.eprintf(
			"[hw_slicer] feature benchmark infill failed: %v\n",
			infill_error,
		)
		return {}, {}, false
	}
	defer features.infill_result_destroy(&infill)
	infill_hash, infill_hash_ok := features.infill_result_hash(
		region_hash,
		infill,
	)
	if !infill_hash_ok ||
	   infill_hash != benchmark.SPINE_FIXTURE_INFILL_HASH {
		fmt.eprintln("[hw_slicer] feature benchmark infill hash changed")
		return {}, {}, false
	}
	infill_offset_calls := feature_benchmark_offset_calls
	timings.infill_ns = feature_benchmark_elapsed_ns(stage_started)
	stage_started = time.tick_now()
	plan, plan_error := features.path_plan_build(
		perimeters,
		infill,
		{
			start = {0, 0},
			inner_perimeters_first = true,
		},
	)
	if plan_error != .None {
		fmt.eprintf(
			"[hw_slicer] feature benchmark path plan failed: %v\n",
			plan_error,
		)
		return {}, {}, false
	}
	defer features.path_plan_result_destroy(&plan)
	plan_hash, plan_hash_ok := features.path_plan_result_hash(
		perimeter_hash,
		infill_hash,
		plan,
	)
	if !plan_hash_ok ||
	   plan_hash != benchmark.SPINE_FIXTURE_PATH_PLAN_HASH {
		fmt.eprintln("[hw_slicer] feature benchmark path hash changed")
		return {}, {}, false
	}
	timings.path_plan_ns = feature_benchmark_elapsed_ns(stage_started)
	return {
		region_count = u64(len(regions.regions)),
		hole_count = regions.hole_count,
		surface_masks = u64(len(surfaces.masks)),
		surface_paths = u64(len(surfaces.paths)),
		surface_points = u64(len(surfaces.points)),
		surface_booleans = surface_boolean_calls,
		perimeter_paths = u64(len(perimeters.paths)),
		perimeter_points = u64(len(perimeters.points)),
		perimeter_offsets = perimeter_offset_calls,
		infill_segments = u64(len(infill.segments)),
		infill_offsets = infill_offset_calls,
		planned_paths = u64(len(plan.paths)),
		planned_moves = u64(len(plan.moves)),
		travel_moves = plan.travel_move_count,
		extrude_moves = plan.extrude_move_count,
	}, timings, true
}

feature_benchmark_boolean :: proc(
	subjects, clips: polygon.Polygon_Set,
	operation: polygon.Polygon_Operation,
	fill_rule: polygon.Polygon_Fill_Rule,
	limits: polygon.Polygon_Limits,
	allocator: mem.Allocator,
) -> (polygon.Polygon_Set, polygon.Polygon_Error) {
	feature_benchmark_boolean_calls += 1
	return polygon.CLIPPER2_PROVIDER.boolean(
		subjects,
		clips,
		operation,
		fill_rule,
		limits,
		allocator,
	)
}

feature_benchmark_offset :: proc(
	input: polygon.Polygon_Set,
	delta: contracts.Micrometres,
	join_type: polygon.Polygon_Join_Type,
	miter_limit, arc_tolerance: f64,
	limits: polygon.Polygon_Limits,
	allocator: mem.Allocator,
) -> (polygon.Polygon_Set, polygon.Polygon_Error) {
	feature_benchmark_offset_calls += 1
	return polygon.CLIPPER2_PROVIDER.offset(
		input,
		delta,
		join_type,
		miter_limit,
		arc_tolerance,
		limits,
		allocator,
	)
}

feature_benchmark_elapsed_ns :: proc(started: time.Tick) -> u64 {
	return u64(max(i64(time.tick_since(started)), 1))
}

feature_benchmark_timing_wire :: proc(
	samples: []u64,
) -> Feature_Benchmark_Timing_Wire {
	benchmark.sort_u64(samples)
	p95_index := (95*len(samples)+99)/100-1
	return {
		samples_ns = samples,
		p50_ns = samples[len(samples)/2],
		p95_ns = samples[p95_index],
	}
}

feature_benchmark_hash_text :: proc(
	hash: contracts.Content_Hash,
) -> []u8 {
	bytes := hash
	return hex.encode(bytes[:])
}
