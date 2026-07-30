package main

import "base:intrinsics"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:time"

import benchmark "../../src/benchmark"
import formats "../../src/formats"
import pipeline "../../src/pipeline"

SPINE_BENCHMARK_WARMUP_COUNT :: 1
SPINE_BENCHMARK_ITERATION_COUNT :: 5

Spine_Benchmark_Environment :: struct {
	hardware:      string,
	os_build:      string,
	odin_version:  string,
	clang_version: string,
	git_revision:  string,
	git_dirty:     string,
	thermal_state: string,
}

Spine_Benchmark_Metrics :: struct {
	triangle_count:         u64,
	welded_vertex_count:    u64,
	degenerate_triangle_count: u64,
	duplicate_face_group_count: u64,
	boundary_edge_count:    u64,
	non_manifold_edge_count: u64,
	inconsistent_winding_count: u64,
	layer_count:            u64,
	triangle_layer_pairs:   u64,
	planar_candidate_count: u64,
	owned_planar_segments:  u64,
	unresolved_planar_groups: u64,
	snapped_segment_count:  u64,
	loop_count:             u64,
	open_chain_count:       u64,
	exact_predicate_count:  u64,
}

Spine_Benchmark_Wire :: struct {
	schema_version:           u32,
	benchmark:                string,
	fixture_version:          u32,
	fixture:                  string,
	mode:                     string,
	environment:              Spine_Benchmark_Environment,
	warmup_count:             int,
	iteration_count:          int,
	source_bytes:             u64,
	triangle_count:           u64,
	welded_vertex_count:      u64,
	degenerate_triangle_count: u64,
	duplicate_face_group_count: u64,
	boundary_edge_count:      u64,
	non_manifold_edge_count:  u64,
	inconsistent_winding_count: u64,
	layer_count:              u64,
	triangle_layer_pairs:     u64,
	planar_candidate_count:   u64,
	owned_planar_segments:    u64,
	unresolved_planar_groups: u64,
	snapped_segment_count:    u64,
	loop_count:               u64,
	open_chain_count:         u64,
	exact_predicate_count:    u64,
	mesh_audit_hash:          string,
	topology_hash:            string,
	samples_ns:               []u64,
	p50_ns:                   u64,
	p95_ns:                   u64,
	pairs_per_second:         f64,
	layers_per_second:        f64,
	validated:                bool,
}

spine_benchmark_sink: u64

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln(
			"usage: hw-slicer-spine-benchmark <all-in-one-test.stl>",
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
			"[hw_slicer] benchmark fixture read failed: %v\n",
			read_error,
		)
		os.exit(1)
	}
	defer delete(bytes)
	for _ in 0..<SPINE_BENCHMARK_WARMUP_COUNT {
		metrics, run_ok := spine_benchmark_run_once(bytes)
		if !run_ok {os.exit(1)}
		intrinsics.volatile_store(
			&spine_benchmark_sink,
			metrics.triangle_layer_pairs,
		)
	}
	samples := make([]u64, SPINE_BENCHMARK_ITERATION_COUNT)
	defer delete(samples)
	reference: Spine_Benchmark_Metrics
	for iteration in 0..<SPINE_BENCHMARK_ITERATION_COUNT {
		started := time.tick_now()
		metrics, run_ok := spine_benchmark_run_once(bytes)
		elapsed := time.tick_since(started)
		if !run_ok {os.exit(1)}
		if iteration == 0 {
			reference = metrics
		} else if metrics != reference {
			fmt.eprintln("[hw_slicer] benchmark counters changed")
			os.exit(1)
		}
		samples[iteration] = u64(max(i64(elapsed), 1))
		intrinsics.volatile_store(
			&spine_benchmark_sink,
			metrics.triangle_layer_pairs,
		)
	}
	benchmark.sort_u64(samples)
	p50_ns := samples[len(samples)/2]
	p95_index := (95*len(samples)+99)/100-1
	p95_ns := samples[p95_index]
	topology_hash_bytes := benchmark.SPINE_FIXTURE_TOPOLOGY_HASH
	topology_hash_text := hex.encode(topology_hash_bytes[:])
	defer delete(topology_hash_text)
	audit_hash_bytes := benchmark.SPINE_FIXTURE_MESH_AUDIT_HASH
	audit_hash_text := hex.encode(audit_hash_bytes[:])
	defer delete(audit_hash_text)
	wire := Spine_Benchmark_Wire{
		schema_version = 2,
		benchmark = "binary-stl-slice-spine",
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
		warmup_count = SPINE_BENCHMARK_WARMUP_COUNT,
		iteration_count = SPINE_BENCHMARK_ITERATION_COUNT,
		source_bytes = u64(len(bytes)),
		triangle_count = reference.triangle_count,
		welded_vertex_count = reference.welded_vertex_count,
		degenerate_triangle_count =
			reference.degenerate_triangle_count,
		duplicate_face_group_count =
			reference.duplicate_face_group_count,
		boundary_edge_count = reference.boundary_edge_count,
		non_manifold_edge_count =
			reference.non_manifold_edge_count,
		inconsistent_winding_count =
			reference.inconsistent_winding_count,
		layer_count = reference.layer_count,
		triangle_layer_pairs = reference.triangle_layer_pairs,
		planar_candidate_count = reference.planar_candidate_count,
		owned_planar_segments = reference.owned_planar_segments,
		unresolved_planar_groups =
			reference.unresolved_planar_groups,
		snapped_segment_count = reference.snapped_segment_count,
		loop_count = reference.loop_count,
		open_chain_count = reference.open_chain_count,
		exact_predicate_count = reference.exact_predicate_count,
		mesh_audit_hash = string(audit_hash_text),
		topology_hash = string(topology_hash_text),
		samples_ns = samples,
		p50_ns = p50_ns,
		p95_ns = p95_ns,
		pairs_per_second =
			f64(reference.triangle_layer_pairs)*1_000_000_000/f64(p50_ns),
		layers_per_second =
			f64(reference.layer_count)*1_000_000_000/f64(p50_ns),
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
		fmt.eprintln("[hw_slicer] benchmark result encoding failed")
		os.exit(1)
	}
	defer delete(output)
	fmt.println(string(output))
}

spine_benchmark_run_once :: proc(
	bytes: []u8,
) -> (Spine_Benchmark_Metrics, bool) {
	result, error := pipeline.slice_spine_binary_stl(bytes, {
		source_units = .Millimetres,
		first_layer_height = 200,
		layer_height = 200,
		max_layer_count = 10_000_000,
	})
	if error != .None {
		fmt.eprintf("[hw_slicer] benchmark slice failed: %v\n", error)
		return {}, false
	}
	defer pipeline.slice_spine_result_destroy(&result)
	if result.mesh.source.content_hash != benchmark.SPINE_FIXTURE_SOURCE_HASH {
		fmt.eprintln("[hw_slicer] benchmark source hash mismatch")
		return {}, false
	}
	if result.hashes.topology != benchmark.SPINE_FIXTURE_TOPOLOGY_HASH {
		fmt.eprintln("[hw_slicer] benchmark topology hash mismatch")
		return {}, false
	}
	if result.hashes.mesh_audit !=
	   benchmark.SPINE_FIXTURE_MESH_AUDIT_HASH {
		fmt.eprintln("[hw_slicer] benchmark mesh audit hash mismatch")
		return {}, false
	}
	loop_count: u64
	for path in result.topology.paths {
		if path.kind == .Loop {loop_count += 1}
	}
	return {
		triangle_count = u64(len(result.mesh.triangle_ids)),
		welded_vertex_count = result.mesh_audit.welded_vertex_count,
		degenerate_triangle_count =
			result.mesh_audit.degenerate_triangle_count,
		duplicate_face_group_count =
			result.mesh_audit.duplicate_face_group_count,
		boundary_edge_count = result.mesh_audit.boundary_edge_count,
		non_manifold_edge_count =
			result.mesh_audit.non_manifold_edge_count,
		inconsistent_winding_count =
			result.mesh_audit.inconsistent_winding_count,
		layer_count = u64(len(result.schedule.layer_z)),
		triangle_layer_pairs = u64(len(result.span_index.triangle_ids)),
		planar_candidate_count =
			u64(len(result.intersections.planar_candidates)),
		owned_planar_segments =
			u64(len(result.planar_ownership.segments.segment_ids)),
		unresolved_planar_groups =
			result.planar_ownership.unresolved_group_count,
		snapped_segment_count =
			u64(len(result.snapped.segments.segment_ids)),
		loop_count = loop_count,
		open_chain_count = result.topology.open_chain_count,
		exact_predicate_count =
			result.intersections.exact_predicate_count,
	}, true
}
