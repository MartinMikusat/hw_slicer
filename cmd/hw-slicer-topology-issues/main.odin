package main

import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"

import benchmark "../../src/benchmark"
import contracts "../../src/contracts"
import formats "../../src/formats"
import pipeline "../../src/pipeline"
import slicing "../../src/slicing"

Point_Wire :: struct {
	x_um: i64,
	y_um: i64,
}

Issue_Wire :: struct {
	stable_id:        string,
	entity_id:        string,
	code:             string,
	layer_index:      u32,
	layer_z_um:       i64,
	entity_index:     u32,
	point_a:          Point_Wire,
	point_b:          Point_Wire,
	reference_offset: u64,
	reference_count:  u32,
}

Segment_Reference_Wire :: struct {
	segment_index:  u32,
	segment_id:     string,
	triangle_index: u32,
	triangle_id:    string,
	source_record_offset: u64,
	edge_a:         string,
	edge_b:         string,
}

Planar_Group_Wire :: struct {
	stable_id:         string,
	layer_index:       u32,
	layer_z_um:        i64,
	point_a:           Point_Wire,
	point_b:           Point_Wire,
	face_count:        u32,
	third_below_count: u32,
	third_above_count: u32,
	reference_offset:  u64,
	reference_count:   u32,
}

Planar_Reference_Wire :: struct {
	triangle_index:      u32,
	triangle_id:         string,
	source_record_offset: u64,
	source_edge:         string,
	kind:                string,
}

Vertex_Path_Reference_Wire :: struct {
	issue_index:       u32,
	path_index:        u32,
	local_vertex_index: u32,
}

Topology_Issues_Wire :: struct {
	schema_version:            u32,
	fixture_version:           u32,
	fixture:                   string,
	source_hash:               string,
	topology_hash:             string,
	report_hash:               string,
	open_chain_count:          u64,
	degenerate_loop_count:     u64,
	non_manifold_vertex_count: u64,
	issues:                    []Issue_Wire,
	segment_references:        []Segment_Reference_Wire,
	vertex_path_references:    []Vertex_Path_Reference_Wire,
	planar_report_hash:        string,
	planar_groups:             []Planar_Group_Wire,
	planar_references:         []Planar_Reference_Wire,
	validated:                 bool,
}

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln(
			"usage: hw-slicer-topology-issues <all-in-one-test.stl>",
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
			"[hw_slicer] topology issue fixture read failed: %v\n",
			read_error,
		)
		os.exit(1)
	}
	defer delete(bytes)
	result, slice_error := pipeline.slice_spine_binary_stl(bytes, {
		source_units = .Millimetres,
		first_layer_height = 200,
		layer_height = 200,
		max_layer_count = 10_000_000,
	})
	if slice_error != .None {
		fmt.eprintf(
			"[hw_slicer] topology issue slice failed: %v\n",
			slice_error,
		)
		os.exit(1)
	}
	defer pipeline.slice_spine_result_destroy(&result)

	report, report_error := slicing.topology_issue_report_build(
		result.topology,
		result.snapped,
	)
	defer slicing.topology_issue_report_destroy(&report)
	if report_error != .None {
		fmt.eprintf(
			"[hw_slicer] topology issue report failed: %v\n",
			report_error,
		)
		os.exit(1)
	}
	report_hash, hash_ok := slicing.topology_issue_report_hash(
		result.hashes.topology,
		report,
	)
	if !hash_ok {
		fmt.eprintln("[hw_slicer] topology issue report hash failed")
		os.exit(1)
	}
	planar_report, planar_report_error :=
		slicing.planar_ownership_issue_report_build(
			result.mesh,
			result.schedule,
			result.intersections,
			result.planar_ownership,
		)
	defer slicing.planar_ownership_issue_report_destroy(&planar_report)
	if planar_report_error != .None {
		fmt.eprintf(
			"[hw_slicer] planar ownership issue report failed: %v\n",
			planar_report_error,
		)
		os.exit(1)
	}
	planar_report_hash, planar_hash_ok :=
		slicing.planar_ownership_issue_report_hash(
			result.hashes.planar_ownership,
			planar_report,
		)
	if !planar_hash_ok {
		fmt.eprintln(
			"[hw_slicer] planar ownership issue report hash failed",
		)
		os.exit(1)
	}

	issues := make([]Issue_Wire, len(report.issues))
	references := make(
		[]Segment_Reference_Wire,
		len(report.segment_references),
	)
	planar_groups := make(
		[]Planar_Group_Wire,
		len(planar_report.groups),
	)
	planar_references := make(
		[]Planar_Reference_Wire,
		len(planar_report.references),
	)
	vertex_path_reference_count := 0
	for issue in report.issues {
		if issue.code != .Non_Manifold_Vertex {continue}
		for vertex_index in result.topology.path_vertex_indices {
			if vertex_index == issue.entity_index {
				vertex_path_reference_count += 1
			}
		}
	}
	vertex_path_references := make(
		[]Vertex_Path_Reference_Wire,
		vertex_path_reference_count,
	)
	if len(report.issues) > 0 && issues == nil ||
	   len(report.segment_references) > 0 && references == nil ||
	   len(planar_report.groups) > 0 && planar_groups == nil ||
	   len(planar_report.references) > 0 && planar_references == nil ||
	   vertex_path_reference_count > 0 &&
	   	vertex_path_references == nil {
		delete(issues)
		delete(references)
		delete(planar_groups)
		delete(planar_references)
		delete(vertex_path_references)
		fmt.eprintln("[hw_slicer] topology issue wire allocation failed")
		os.exit(1)
	}
	defer delete(issues)
	defer delete(references)
	defer delete(planar_groups)
	defer delete(planar_references)
	defer delete(vertex_path_references)
	for issue, issue_index in report.issues {
		issues[issue_index] = {
			stable_id = fmt.tprintf("%016x", u64(issue.stable_id)),
			entity_id = fmt.tprintf("%016x", u64(issue.entity_id)),
			code = topology_issue_code_name(issue.code),
			layer_index = issue.layer_index,
			layer_z_um = i64(result.schedule.layer_z[issue.layer_index]),
			entity_index = issue.entity_index,
			point_a = {
				x_um = i64(issue.point_a.x),
				y_um = i64(issue.point_a.y),
			},
			point_b = {
				x_um = i64(issue.point_b.x),
				y_um = i64(issue.point_b.y),
			},
			reference_offset = issue.reference_offset,
			reference_count = issue.reference_count,
		}
	}
	for reference, reference_index in report.segment_references {
		references[reference_index] = {
			segment_index = reference.segment_index,
			segment_id = fmt.tprintf(
				"%016x",
				u64(reference.segment_id),
			),
			triangle_index = reference.triangle_index,
			triangle_id = fmt.tprintf(
				"%016x",
				u64(reference.triangle_id),
			),
			source_record_offset =
				result.mesh.source_record_offsets[
					reference.triangle_index
				],
			edge_a = triangle_edge_name(reference.edge_a),
			edge_b = triangle_edge_name(reference.edge_b),
		}
	}
	for group, group_index in planar_report.groups {
		planar_groups[group_index] = {
			stable_id = fmt.tprintf("%016x", u64(group.stable_id)),
			layer_index = group.layer_index,
			layer_z_um = i64(result.schedule.layer_z[group.layer_index]),
			point_a = {
				x_um = i64(group.point_a.x),
				y_um = i64(group.point_a.y),
			},
			point_b = {
				x_um = i64(group.point_b.x),
				y_um = i64(group.point_b.y),
			},
			face_count = group.face_count,
			third_below_count = group.third_below_count,
			third_above_count = group.third_above_count,
			reference_offset = group.reference_offset,
			reference_count = group.reference_count,
		}
	}
	for reference, reference_index in planar_report.references {
		planar_references[reference_index] = {
			triangle_index = reference.triangle_index,
			triangle_id = fmt.tprintf(
				"%016x",
				u64(reference.triangle_id),
			),
			source_record_offset =
				result.mesh.source_record_offsets[
					reference.triangle_index
				],
			source_edge = triangle_edge_name(reference.source_edge),
			kind = planar_incidence_kind_name(reference.kind),
		}
	}
	vertex_path_reference_write := 0
	for issue, issue_index in report.issues {
		if issue.code != .Non_Manifold_Vertex {continue}
		for path, path_index in result.topology.paths {
			start := int(path.vertex_offset)
			end := start+int(path.vertex_count)
			for vertex_index, local_vertex_index in
			    result.topology.path_vertex_indices[start:end] {
				if vertex_index != issue.entity_index {continue}
				vertex_path_references[vertex_path_reference_write] = {
					issue_index = u32(issue_index),
					path_index = u32(path_index),
					local_vertex_index = u32(local_vertex_index),
				}
				vertex_path_reference_write += 1
			}
		}
	}
	if vertex_path_reference_write != len(vertex_path_references) {
		fmt.eprintln(
			"[hw_slicer] topology path reference count changed",
		)
		os.exit(1)
	}

	source_hash_text := content_hash_text(result.mesh.source.content_hash)
	defer delete(transmute([]u8)source_hash_text)
	topology_hash_text := content_hash_text(result.hashes.topology)
	defer delete(transmute([]u8)topology_hash_text)
	report_hash_text := content_hash_text(report_hash)
	defer delete(transmute([]u8)report_hash_text)
	planar_report_hash_text := content_hash_text(planar_report_hash)
	defer delete(transmute([]u8)planar_report_hash_text)
	validated :=
		result.mesh.source.content_hash ==
			benchmark.SPINE_FIXTURE_SOURCE_HASH &&
		result.hashes.topology ==
			benchmark.SPINE_FIXTURE_TOPOLOGY_HASH &&
		u64(len(report.issues)) ==
			benchmark.SPINE_FIXTURE_TOPOLOGY_ISSUE_COUNT &&
		u64(len(report.segment_references)) ==
			benchmark.SPINE_FIXTURE_TOPOLOGY_ISSUE_REFERENCE_COUNT &&
		report_hash ==
			benchmark.SPINE_FIXTURE_TOPOLOGY_ISSUE_HASH &&
		u64(len(planar_report.groups)) ==
			benchmark.SPINE_FIXTURE_PLANAR_ISSUE_GROUP_COUNT &&
		u64(len(planar_report.references)) ==
			benchmark.SPINE_FIXTURE_PLANAR_ISSUE_REFERENCE_COUNT &&
		planar_report_hash ==
			benchmark.SPINE_FIXTURE_PLANAR_ISSUE_HASH
	wire := Topology_Issues_Wire{
		schema_version = 1,
		fixture_version = 1,
		fixture = "all-in-one-test.stl",
		source_hash = source_hash_text,
		topology_hash = topology_hash_text,
		report_hash = report_hash_text,
		open_chain_count = report.open_chain_count,
		degenerate_loop_count = report.degenerate_loop_count,
		non_manifold_vertex_count =
			report.non_manifold_vertex_count,
		issues = issues,
		segment_references = references,
		vertex_path_references = vertex_path_references,
		planar_report_hash = planar_report_hash_text,
		planar_groups = planar_groups,
		planar_references = planar_references,
		validated = validated,
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
		fmt.eprintln("[hw_slicer] topology issue encoding failed")
		os.exit(1)
	}
	defer delete(output)
	fmt.println(string(output))
	if !validated {os.exit(1)}
}

content_hash_text :: proc(hash: contracts.Content_Hash) -> string {
	bytes := hash
	return string(hex.encode(bytes[:]))
}

topology_issue_code_name :: proc(code: slicing.Topology_Issue_Code) -> string {
	switch code {
	case .Open_Chain:          return "open-chain"
	case .Degenerate_Loop:     return "degenerate-loop"
	case .Non_Manifold_Vertex: return "non-manifold-vertex"
	case .Invalid:             return "invalid"
	}
	return "invalid"
}

triangle_edge_name :: proc(edge: slicing.Triangle_Edge) -> string {
	switch edge {
	case .AB:      return "ab"
	case .BC:      return "bc"
	case .CA:      return "ca"
	case .Invalid: return "invalid"
	}
	return "invalid"
}

planar_incidence_kind_name :: proc(
	kind: slicing.Planar_Incidence_Kind,
) -> string {
	switch kind {
	case .Face:        return "face"
	case .Third_Below: return "third-below"
	case .Third_Above: return "third-above"
	case .Invalid:     return "invalid"
	}
	return "invalid"
}
