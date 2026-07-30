package main

import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"

import contracts "../../src/contracts"
import formats "../../src/formats"
import pipeline "../../src/pipeline"
import slicing "../../src/slicing"

Spine_Hashes_Wire :: struct {
	request:          string,
	three_mf_scene:   string,
	decoded_mesh:     string,
	canonical_mesh:   string,
	mesh_audit:       string,
	layer_schedule:   string,
	layer_spans:      string,
	intersections:    string,
	primary_snapped:  string,
	planar_ownership: string,
	snapped:          string,
	topology:         string,
}

Spine_Wire :: struct {
	schema_version:            u32,
	source_format:             string,
	source_units:              string,
	source_bytes:              u64,
	triangle_count:            int,
	welded_vertex_count:       u64,
	degenerate_triangle_count: u64,
	duplicate_face_group_count: u64,
	boundary_edge_count:       u64,
	non_manifold_edge_count:   u64,
	inconsistent_winding_count: u64,
	layer_count:               int,
	triangle_layer_pairs:      int,
	raw_segment_count:         int,
	planar_candidate_count:    int,
	owned_planar_segment_count: int,
	unresolved_planar_groups:  u64,
	suppressed_planar_groups:  u64,
	snapped_segment_count:     int,
	collapsed_segment_count:   u64,
	loop_count:                int,
	open_chain_count:          u64,
	degenerate_loop_count:     u64,
	non_manifold_vertex_count: u64,
	topology_issue_reference_count: u64,
	topology_issue_hash:       string,
	exact_predicate_count:     u64,
	hashes:                    Spine_Hashes_Wire,
}

main :: proc() {
	if len(os.args) < 3 || len(os.args) > 5 {
		spine_usage()
		os.exit(2)
	}
	is_three_mf := os.args[2] == "auto"
	source_units: contracts.Source_Units
	units_ok := true
	if !is_three_mf {
		source_units, units_ok = spine_parse_units(os.args[2])
	}
	if !units_ok {
		fmt.eprintf("[hw_slicer] invalid source units: %s\n", os.args[2])
		spine_usage()
		os.exit(2)
	}
	first_layer_height: i64 = 200
	layer_height: i64 = 200
	if len(os.args) >= 4 {
		first_layer_height, units_ok = strconv.parse_i64(os.args[3])
		if !units_ok || first_layer_height <= 0 {
			fmt.eprintln("[hw_slicer] first-layer-um must be positive")
			os.exit(2)
		}
	}
	if len(os.args) >= 5 {
		layer_height, units_ok = strconv.parse_i64(os.args[4])
		if !units_ok || layer_height <= 0 {
			fmt.eprintln("[hw_slicer] layer-height-um must be positive")
			os.exit(2)
		}
	}
	bytes, read_ok := spine_read_bounded_input(os.args[1])
	if !read_ok {
		os.exit(1)
	}
	defer delete(bytes)
	result: pipeline.Slice_Spine_Result
	slice_error: pipeline.Slice_Spine_Error
	if is_three_mf {
		result, slice_error = pipeline.slice_spine_three_mf(bytes, {
			first_layer_height =
				contracts.Micrometres(first_layer_height),
			layer_height = contracts.Micrometres(layer_height),
			max_layer_count = 10_000_000,
		})
	} else {
		result, slice_error = pipeline.slice_spine_mesh(bytes, {
			source_units = source_units,
			first_layer_height =
				contracts.Micrometres(first_layer_height),
			layer_height = contracts.Micrometres(layer_height),
			max_layer_count = 10_000_000,
		})
	}
	if slice_error != .None {
		fmt.eprintf("[hw_slicer] slice spine failed: %v\n", slice_error)
		os.exit(1)
	}
	defer pipeline.slice_spine_result_destroy(&result)

	topology_issues, topology_issue_error :=
		slicing.topology_issue_report_build(
			result.topology,
			result.snapped,
		)
	defer slicing.topology_issue_report_destroy(&topology_issues)
	if topology_issue_error != .None {
		fmt.eprintf(
			"[hw_slicer] topology issue report failed: %v\n",
			topology_issue_error,
		)
		os.exit(1)
	}
	topology_issue_hash, topology_issue_hash_ok :=
		slicing.topology_issue_report_hash(
			result.hashes.topology,
			topology_issues,
		)
	if !topology_issue_hash_ok {
		fmt.eprintln("[hw_slicer] topology issue report hash failed")
		os.exit(1)
	}
	topology_issue_hash_text := spine_hash_text(topology_issue_hash)
	defer delete(transmute([]u8)topology_issue_hash_text)

	hashes := spine_hashes_wire_make(result.hashes)
	defer spine_hashes_wire_destroy(&hashes)
	loop_count := 0
	for path in result.topology.paths {
		if path.kind == .Loop {loop_count += 1}
	}
	wire := Spine_Wire{
		schema_version = 3,
		source_format = spine_format_name(result.mesh.source.format),
		source_units = spine_units_name(result.mesh.source.units),
		source_bytes = u64(len(bytes)),
		triangle_count = len(result.mesh.triangle_ids),
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
		layer_count = len(result.schedule.layer_z),
		triangle_layer_pairs = len(result.span_index.triangle_ids),
		raw_segment_count = len(result.intersections.segments.segment_ids),
		planar_candidate_count =
			len(result.intersections.planar_candidates),
		owned_planar_segment_count =
			len(result.planar_ownership.segments.segment_ids),
		unresolved_planar_groups =
			result.planar_ownership.unresolved_group_count,
		suppressed_planar_groups =
			result.planar_ownership.suppressed_group_count,
		snapped_segment_count = len(result.snapped.segments.segment_ids),
		collapsed_segment_count = result.snapped.collapsed_count,
		loop_count = loop_count,
		open_chain_count = result.topology.open_chain_count,
		degenerate_loop_count = result.topology.degenerate_loop_count,
		non_manifold_vertex_count =
			result.topology.non_manifold_vertex_count,
		topology_issue_reference_count =
			u64(len(topology_issues.segment_references)),
		topology_issue_hash = topology_issue_hash_text,
		exact_predicate_count =
			result.intersections.exact_predicate_count,
		hashes = hashes,
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
		fmt.eprintln("[hw_slicer] result encoding failed")
		os.exit(1)
	}
	defer delete(output)
	fmt.println(string(output))
}

spine_read_bounded_input :: proc(path: string) -> ([]u8, bool) {
	bytes, error := formats.source_file_read_bounded(
		path,
		22,
		formats.DEFAULT_BINARY_STL_LIMITS.max_source_bytes,
	)
	switch error {
	case .None:
		return bytes, true
	case .Open_Failed:
		fmt.eprintf("[hw_slicer] cannot open input: %s\n", path)
	case .Size_Limit:
		fmt.eprintln("[hw_slicer] input size is outside the source limit")
	case .Allocation_Failed:
		fmt.eprintln("[hw_slicer] input allocation failed")
	case .Read_Failed:
		fmt.eprintln("[hw_slicer] input read failed")
	case .Changed_During_Read:
		fmt.eprintln("[hw_slicer] input changed during read")
	}
	return nil, false
}

spine_parse_units :: proc(value: string) -> (contracts.Source_Units, bool) {
	switch value {
	case "um": return .Micrometres, true
	case "mm": return .Millimetres, true
	case "cm": return .Centimetres, true
	case "m":  return .Metres, true
	case "in": return .Inches, true
	case "ft": return .Feet, true
	}
	return .Unspecified, false
}

spine_units_name :: proc(value: contracts.Source_Units) -> string {
	switch value {
	case .Micrometres: return "um"
	case .Millimetres: return "mm"
	case .Centimetres: return "cm"
	case .Metres:      return "m"
	case .Inches:      return "in"
	case .Feet:        return "ft"
	case .Unspecified: return "unspecified"
	}
	return "unspecified"
}

spine_format_name :: proc(value: contracts.Source_Format) -> string {
	switch value {
	case .Binary_STL: return "binary-stl"
	case .Three_MF:   return "3mf"
	case .ASCII_STL:  return "ascii-stl"
	case .OBJ:        return "obj"
	case .Invalid:    return "invalid"
	}
	return "invalid"
}

spine_hashes_wire_make :: proc(
	hashes: pipeline.Slice_Spine_Hashes,
) -> Spine_Hashes_Wire {
	return {
		request = spine_hash_text(hashes.request),
		three_mf_scene = spine_hash_text(hashes.three_mf_scene),
		decoded_mesh = spine_hash_text(hashes.decoded_mesh),
		canonical_mesh = spine_hash_text(hashes.canonical_mesh),
		mesh_audit = spine_hash_text(hashes.mesh_audit),
		layer_schedule = spine_hash_text(hashes.layer_schedule),
		layer_spans = spine_hash_text(hashes.layer_spans),
		intersections = spine_hash_text(hashes.intersections),
		primary_snapped = spine_hash_text(hashes.primary_snapped),
		planar_ownership = spine_hash_text(hashes.planar_ownership),
		snapped = spine_hash_text(hashes.snapped),
		topology = spine_hash_text(hashes.topology),
	}
}

spine_hashes_wire_destroy :: proc(hashes: ^Spine_Hashes_Wire) {
	delete(transmute([]u8)hashes.request)
	delete(transmute([]u8)hashes.three_mf_scene)
	delete(transmute([]u8)hashes.decoded_mesh)
	delete(transmute([]u8)hashes.canonical_mesh)
	delete(transmute([]u8)hashes.mesh_audit)
	delete(transmute([]u8)hashes.layer_schedule)
	delete(transmute([]u8)hashes.layer_spans)
	delete(transmute([]u8)hashes.intersections)
	delete(transmute([]u8)hashes.primary_snapped)
	delete(transmute([]u8)hashes.planar_ownership)
	delete(transmute([]u8)hashes.snapped)
	delete(transmute([]u8)hashes.topology)
	hashes^ = {}
}

spine_hash_text :: proc(hash: contracts.Content_Hash) -> string {
	bytes := hash
	return string(hex.encode(bytes[:]))
}

spine_usage :: proc() {
	fmt.eprintln(
		"usage: hw-slicer-spine <input> <auto|um|mm|cm|m|in|ft> " +
		"[first-layer-um] [layer-height-um]",
	)
}
