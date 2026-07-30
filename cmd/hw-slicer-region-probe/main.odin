package main

import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"

import benchmark "../../src/benchmark"
import evidence "../../src/evidence"
import features "../../src/features"
import formats "../../src/formats"
import pipeline "../../src/pipeline"
import polygon "../../src/polygon"
import repair "../../src/repair"
import slicing "../../src/slicing"

Region_Failure_Wire :: struct {
	error:           string,
	layer_index:     u32,
	contour_index_a: u32,
	contour_index_b: u32,
	path_index_a:    u32,
	path_index_b:    u32,
	edge_index_a:    u32,
	edge_index_b:    u32,
}

Region_Probe_Wire :: struct {
	schema_version:   u32,
	fixture_version:  u32,
	fixture:          string,
	source_bytes:     u64,
	source_hash:      string,
	topology_hash:    string,
	topology_issue_error: string,
	topology_issue_count: u64,
	topology_issue_reference_count: u64,
	topology_issue_hash: string,
	loop_count:       u64,
	open_chain_count: u64,
	degenerate_loop_count: u64,
	non_manifold_vertex_count: u64,
	accepted:         bool,
	region_count:     u64,
	hole_count:       u64,
	failure:          Region_Failure_Wire,
	repair_attempted: bool,
	repair_error:     string,
	repair_fill_rule: string,
	repair_lineage_tolerance_um: i64,
	repair_output_path_count: u64,
	repair_output_point_count: u64,
	repair_edge_count: u64,
	repair_source_count: u64,
	repair_maximum_deviation_um: u64,
	repair_hash:      string,
	apply_error:      string,
	repaired_region_error: string,
	repaired_open_chain_count: u64,
	repaired_degenerate_loop_count: u64,
	repaired_non_manifold_vertex_count: u64,
	repaired_region_count: u64,
	repaired_hole_count: u64,
	repaired_region_hash: string,
	repaired_failure: Region_Failure_Wire,
	surface_error:    string,
	surface_fill_rule: string,
	surface_mask_count: u64,
	bottom_surface_mask_count: u64,
	top_surface_mask_count: u64,
	surface_path_count: u64,
	surface_point_count: u64,
	surface_hash:     string,
	perimeter_error:  string,
	perimeter_count:  u32,
	perimeter_line_width_um: i64,
	perimeter_group_count: u64,
	perimeter_path_count: u64,
	perimeter_point_count: u64,
	perimeter_hash:   string,
	infill_error:     string,
	infill_spacing_um: i64,
	infill_boundary_inset_um: i64,
	infill_scanline_count: u64,
	infill_segment_count: u64,
	infill_boundary_hit_count: u64,
	infill_hash:      string,
	path_plan_error: string,
	planned_path_count: u64,
	planned_move_count: u64,
	planned_travel_move_count: u64,
	planned_extrude_move_count: u64,
	path_plan_hash: string,
	feature_topology_policy: string,
	feature_output_printable: bool,
	validated:        bool,
}

main :: proc() {
	if len(os.args) != 2 && len(os.args) != 3 {
		fmt.eprintln(
			"usage: hw-slicer-region-probe <all-in-one-test.stl> [topology-artifact]",
		)
		os.exit(2)
	}
	if len(os.args) == 3 {
		if os.args[2] == os.args[1] {
			fmt.eprintln(
				"[hw_slicer] topology artifact must differ from the source",
			)
			os.exit(2)
		}
		if info, error := os.lstat(os.args[2]); error == nil {
			os.file_info_delete(info)
			fmt.eprintln(
				"[hw_slicer] topology artifact destination already exists",
			)
			os.exit(2)
		}
	}
	bytes, read_error := formats.source_file_read_bounded(
		os.args[1],
		84,
		formats.DEFAULT_BINARY_STL_LIMITS.max_source_bytes,
	)
	if read_error != .None {
		fmt.eprintf(
			"[hw_slicer] region probe fixture read failed: %v\n",
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
			"[hw_slicer] region probe slice failed: %v\n",
			slice_error,
		)
		os.exit(1)
	}
	defer pipeline.slice_spine_result_destroy(&result)
	if len(os.args) == 3 {
		topology_capture, topology_capture_error :=
			evidence.topology_capture_encode(
				"topology.bin",
				{
					level = .Primitives,
					byte_limit = 256*1024*1024,
					item_limit = 10_000_000,
				},
				{},
				result.hashes.snapped,
				len(result.snapped.segments.segment_ids),
				result.topology,
			)
		if topology_capture_error != .None {
			fmt.eprintf(
				"[hw_slicer] topology artifact capture failed: %v\n",
				topology_capture_error,
			)
			os.exit(1)
		}
		defer evidence.topology_capture_destroy(&topology_capture)
		if !os.write_entire_file(os.args[2], topology_capture.bytes) {
			fmt.eprintln("[hw_slicer] topology artifact write failed")
			os.exit(1)
		}
	}

	topology_issues, topology_issue_error :=
		slicing.topology_issue_report_build(
			result.topology,
			result.snapped,
		)
	defer slicing.topology_issue_report_destroy(&topology_issues)
	topology_issue_hash, topology_issue_hash_ok :=
		slicing.topology_issue_report_hash(
			result.hashes.topology,
			topology_issues,
		)

	failure: slicing.Region_Failure
	regions, region_error := slicing.regions_build(
		result.topology,
		failure = &failure,
	)
	defer slicing.region_result_destroy(&regions)
	repair_result: repair.Contour_Repair_Result
	repair_error: repair.Contour_Repair_Error
	if region_error == .Contour_Intersection {
		repair_result, repair_error = repair.contour_path_repair(
			result.topology,
			polygon.CLIPPER2_PROVIDER,
			{
				failure = failure,
				fill_rule = .Even_Odd,
				lineage_tolerance = 2,
			},
		)
	}
	defer repair.contour_repair_result_destroy(&repair_result)
	repair_hash, repair_hash_ok := repair.contour_repair_result_hash(
		result.hashes.topology,
		repair_result,
	)
	repaired_topology: slicing.Topology_Result
	apply_error: repair.Contour_Repair_Error
	if repair_error == .None {
		repaired_topology, apply_error =
			repair.contour_repair_apply_for_regions(
				result.topology,
				repair_result,
			)
	}
	defer slicing.topology_result_destroy(&repaired_topology)
	repaired_failure: slicing.Region_Failure
	repaired_regions: slicing.Region_Result
	repaired_region_error: slicing.Region_Error
	if apply_error == .None {
		repaired_regions, repaired_region_error = slicing.regions_build(
			repaired_topology,
			failure = &repaired_failure,
		)
	}
	defer slicing.region_result_destroy(&repaired_regions)
	repaired_region_hash, repaired_region_hash_ok :=
		slicing.region_result_hash(
			repair_hash,
			repaired_topology,
			repaired_regions,
		)
	surfaces: features.Surface_Result
	surface_error: features.Surface_Error
	if repaired_region_error == .None {
		surfaces, surface_error = features.surfaces_classify(
			repaired_topology,
			repaired_regions,
			polygon.CLIPPER2_PROVIDER,
			{
				fill_rule = .Even_Odd,
				topology_policy = .Strict_Printable,
			},
		)
	}
	defer features.surface_result_destroy(&surfaces)
	surface_hash, surface_hash_ok := features.surface_result_hash(
		repaired_region_hash,
		surfaces,
	)
	perimeters: features.Perimeter_Result
	perimeter_error: features.Perimeter_Error
	if repaired_region_error == .None {
		perimeters, perimeter_error = features.perimeters_generate(
			repaired_topology,
			repaired_regions,
			polygon.CLIPPER2_PROVIDER,
			{
				count = 2,
				line_width = 450,
				topology_policy = .Strict_Printable,
				join_type = .Miter,
				miter_limit = 2,
				arc_tolerance = 0,
			},
		)
	}
	defer features.perimeter_result_destroy(&perimeters)
	perimeter_hash, perimeter_hash_ok := features.perimeter_result_hash(
		repaired_region_hash,
		perimeters,
	)
	infill: features.Infill_Result
	infill_error: features.Infill_Error
	if repaired_region_error == .None {
		infill, infill_error = features.infill_generate(
			repaired_topology,
			repaired_regions,
			polygon.CLIPPER2_PROVIDER,
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
	}
	defer features.infill_result_destroy(&infill)
	infill_hash, infill_hash_ok := features.infill_result_hash(
		repaired_region_hash,
		infill,
	)
	path_plan: features.Path_Plan_Result
	path_plan_error: features.Path_Plan_Error
	if perimeter_error == .None && infill_error == .None {
		path_plan, path_plan_error = features.path_plan_build(
			perimeters,
			infill,
			{
				start = {0, 0},
				inner_perimeters_first = true,
			},
		)
	}
	defer features.path_plan_result_destroy(&path_plan)
	path_plan_hash, path_plan_hash_ok := features.path_plan_result_hash(
		perimeter_hash,
		infill_hash,
		path_plan,
	)
	loop_count: u64
	for path in result.topology.paths {
		if path.kind == .Loop {loop_count += 1}
	}
	validated :=
		result.mesh.source.content_hash ==
			benchmark.SPINE_FIXTURE_SOURCE_HASH &&
		result.hashes.topology ==
			benchmark.SPINE_FIXTURE_TOPOLOGY_HASH &&
		topology_issue_error == .None &&
		topology_issue_hash_ok &&
		u64(len(topology_issues.issues)) ==
			benchmark.SPINE_FIXTURE_TOPOLOGY_ISSUE_COUNT &&
		u64(len(topology_issues.segment_references)) ==
			benchmark.SPINE_FIXTURE_TOPOLOGY_ISSUE_REFERENCE_COUNT &&
		topology_issue_hash ==
			benchmark.SPINE_FIXTURE_TOPOLOGY_ISSUE_HASH &&
		region_error == .Contour_Intersection &&
		failure.error == region_error &&
		failure.layer_index ==
			benchmark.SPINE_FIXTURE_REGION_FAILURE_LAYER &&
		failure.contour_index_a ==
			benchmark.SPINE_FIXTURE_REGION_FAILURE_CONTOUR &&
		failure.contour_index_b ==
			benchmark.SPINE_FIXTURE_REGION_FAILURE_CONTOUR &&
		failure.path_index_a ==
			benchmark.SPINE_FIXTURE_REGION_FAILURE_PATH &&
		failure.path_index_b ==
			benchmark.SPINE_FIXTURE_REGION_FAILURE_PATH &&
		failure.edge_index_a ==
			benchmark.SPINE_FIXTURE_REGION_FAILURE_EDGE_A &&
		failure.edge_index_b ==
			benchmark.SPINE_FIXTURE_REGION_FAILURE_EDGE_B &&
		repair_error == .None &&
		repair_hash_ok &&
		repair_hash == benchmark.SPINE_FIXTURE_REPAIR_HASH &&
		u64(len(repair_result.output.paths)) ==
			benchmark.SPINE_FIXTURE_REPAIR_OUTPUT_PATH_COUNT &&
		u64(len(repair_result.output.points)) ==
			benchmark.SPINE_FIXTURE_REPAIR_OUTPUT_POINT_COUNT &&
		u64(len(repair_result.edges)) ==
			benchmark.SPINE_FIXTURE_REPAIR_EDGE_COUNT &&
		u64(len(repair_result.sources)) ==
			benchmark.SPINE_FIXTURE_REPAIR_SOURCE_COUNT &&
		repair_result.maximum_deviation_um ==
			benchmark.SPINE_FIXTURE_REPAIR_MAXIMUM_DEVIATION_UM &&
		apply_error == .None &&
		repaired_region_error == .None &&
		repaired_topology.open_chain_count == 0 &&
		repaired_topology.degenerate_loop_count == 0 &&
		repaired_topology.non_manifold_vertex_count == 0 &&
		repaired_region_hash_ok &&
		u64(len(repaired_regions.regions)) ==
			benchmark.SPINE_FIXTURE_REPAIRED_REGION_COUNT &&
		repaired_regions.hole_count ==
			benchmark.SPINE_FIXTURE_REPAIRED_HOLE_COUNT &&
		repaired_region_hash ==
			benchmark.SPINE_FIXTURE_REPAIRED_REGION_HASH &&
		surface_error == .None &&
		surface_hash_ok &&
		u64(len(surfaces.masks)) ==
			benchmark.SPINE_FIXTURE_SURFACE_MASK_COUNT &&
		surfaces.bottom_mask_count ==
			benchmark.SPINE_FIXTURE_BOTTOM_SURFACE_MASK_COUNT &&
		surfaces.top_mask_count ==
			benchmark.SPINE_FIXTURE_TOP_SURFACE_MASK_COUNT &&
		u64(len(surfaces.paths)) ==
			benchmark.SPINE_FIXTURE_SURFACE_PATH_COUNT &&
		u64(len(surfaces.points)) ==
			benchmark.SPINE_FIXTURE_SURFACE_POINT_COUNT &&
		surface_hash == benchmark.SPINE_FIXTURE_SURFACE_HASH &&
		perimeter_error == .None &&
		perimeter_hash_ok &&
		u64(len(perimeters.groups)) ==
			benchmark.SPINE_FIXTURE_PERIMETER_GROUP_COUNT &&
		u64(len(perimeters.paths)) ==
			benchmark.SPINE_FIXTURE_PERIMETER_PATH_COUNT &&
		u64(len(perimeters.points)) ==
			benchmark.SPINE_FIXTURE_PERIMETER_POINT_COUNT &&
		perimeter_hash == benchmark.SPINE_FIXTURE_PERIMETER_HASH &&
		infill_error == .None &&
		infill_hash_ok &&
		infill.scanline_count ==
			benchmark.SPINE_FIXTURE_INFILL_SCANLINE_COUNT &&
		u64(len(infill.segments)) ==
			benchmark.SPINE_FIXTURE_INFILL_SEGMENT_COUNT &&
		u64(len(infill.boundary_hits)) ==
			benchmark.SPINE_FIXTURE_INFILL_BOUNDARY_HIT_COUNT &&
		infill_hash == benchmark.SPINE_FIXTURE_INFILL_HASH &&
		path_plan_error == .None &&
		path_plan_hash_ok &&
		u64(len(path_plan.paths)) ==
			benchmark.SPINE_FIXTURE_PLANNED_PATH_COUNT &&
		u64(len(path_plan.moves)) ==
			benchmark.SPINE_FIXTURE_PLANNED_MOVE_COUNT &&
		path_plan.travel_move_count ==
			benchmark.SPINE_FIXTURE_PLANNED_TRAVEL_MOVE_COUNT &&
		path_plan.extrude_move_count ==
			benchmark.SPINE_FIXTURE_PLANNED_EXTRUDE_MOVE_COUNT &&
		path_plan_hash == benchmark.SPINE_FIXTURE_PATH_PLAN_HASH &&
		result.topology.open_chain_count == 0 &&
		result.topology.degenerate_loop_count == 0 &&
		result.topology.non_manifold_vertex_count == 1
	source_hash_bytes := result.mesh.source.content_hash
	source_hash := hex.encode(source_hash_bytes[:])
	defer delete(source_hash)
	topology_hash_bytes := result.hashes.topology
	topology_hash := hex.encode(topology_hash_bytes[:])
	defer delete(topology_hash)
	topology_issue_hash_bytes := topology_issue_hash
	topology_issue_hash_text := hex.encode(topology_issue_hash_bytes[:])
	defer delete(topology_issue_hash_text)
	repair_hash_bytes := repair_hash
	repair_hash_text := hex.encode(repair_hash_bytes[:])
	defer delete(repair_hash_text)
	repaired_region_hash_bytes := repaired_region_hash
	repaired_region_hash_text := hex.encode(repaired_region_hash_bytes[:])
	defer delete(repaired_region_hash_text)
	surface_hash_bytes := surface_hash
	surface_hash_text := hex.encode(surface_hash_bytes[:])
	defer delete(surface_hash_text)
	perimeter_hash_bytes := perimeter_hash
	perimeter_hash_text := hex.encode(perimeter_hash_bytes[:])
	defer delete(perimeter_hash_text)
	infill_hash_bytes := infill_hash
	infill_hash_text := hex.encode(infill_hash_bytes[:])
	defer delete(infill_hash_text)
	path_plan_hash_bytes := path_plan_hash
	path_plan_hash_text := hex.encode(path_plan_hash_bytes[:])
	defer delete(path_plan_hash_text)
	wire := Region_Probe_Wire{
		schema_version = 6,
		fixture_version = 1,
		fixture = "all-in-one-test.stl",
		source_bytes = u64(len(bytes)),
		source_hash = string(source_hash),
		topology_hash = string(topology_hash),
		topology_issue_error =
			topology_issue_error_name(topology_issue_error),
		topology_issue_count = u64(len(topology_issues.issues)),
		topology_issue_reference_count =
			u64(len(topology_issues.segment_references)),
		topology_issue_hash = string(topology_issue_hash_text),
		loop_count = loop_count,
		open_chain_count = result.topology.open_chain_count,
		degenerate_loop_count = result.topology.degenerate_loop_count,
		non_manifold_vertex_count =
			result.topology.non_manifold_vertex_count,
		accepted = region_error == .None,
		region_count = u64(len(regions.regions)),
		hole_count = regions.hole_count,
		failure = {
			error = region_error_name(region_error),
			layer_index = failure.layer_index,
			contour_index_a = failure.contour_index_a,
			contour_index_b = failure.contour_index_b,
			path_index_a = failure.path_index_a,
			path_index_b = failure.path_index_b,
			edge_index_a = failure.edge_index_a,
			edge_index_b = failure.edge_index_b,
		},
		repair_attempted = region_error == .Contour_Intersection,
		repair_error = contour_repair_error_name(repair_error),
		repair_fill_rule = "even-odd",
		repair_lineage_tolerance_um = 2,
		repair_output_path_count = u64(len(repair_result.output.paths)),
		repair_output_point_count = u64(len(repair_result.output.points)),
		repair_edge_count = u64(len(repair_result.edges)),
		repair_source_count = u64(len(repair_result.sources)),
		repair_maximum_deviation_um =
			repair_result.maximum_deviation_um,
		repair_hash = string(repair_hash_text),
		apply_error = contour_repair_error_name(apply_error),
		repaired_region_error =
			region_error_name(repaired_region_error),
		repaired_open_chain_count =
			repaired_topology.open_chain_count,
		repaired_degenerate_loop_count =
			repaired_topology.degenerate_loop_count,
		repaired_non_manifold_vertex_count =
			repaired_topology.non_manifold_vertex_count,
		repaired_region_count = u64(len(repaired_regions.regions)),
		repaired_hole_count = repaired_regions.hole_count,
		repaired_region_hash = string(repaired_region_hash_text),
		repaired_failure = {
			error = region_error_name(repaired_failure.error),
			layer_index = repaired_failure.layer_index,
			contour_index_a = repaired_failure.contour_index_a,
			contour_index_b = repaired_failure.contour_index_b,
			path_index_a = repaired_failure.path_index_a,
			path_index_b = repaired_failure.path_index_b,
			edge_index_a = repaired_failure.edge_index_a,
			edge_index_b = repaired_failure.edge_index_b,
		},
		surface_error = surface_error_name(surface_error),
		surface_fill_rule = "even-odd",
		surface_mask_count = u64(len(surfaces.masks)),
		bottom_surface_mask_count = surfaces.bottom_mask_count,
		top_surface_mask_count = surfaces.top_mask_count,
		surface_path_count = u64(len(surfaces.paths)),
		surface_point_count = u64(len(surfaces.points)),
		surface_hash = string(surface_hash_text),
		perimeter_error = perimeter_error_name(perimeter_error),
		perimeter_count = 2,
		perimeter_line_width_um = 450,
		perimeter_group_count = u64(len(perimeters.groups)),
		perimeter_path_count = u64(len(perimeters.paths)),
		perimeter_point_count = u64(len(perimeters.points)),
		perimeter_hash = string(perimeter_hash_text),
		infill_error = infill_error_name(infill_error),
		infill_spacing_um = 5_000,
		infill_boundary_inset_um = 900,
		infill_scanline_count = infill.scanline_count,
		infill_segment_count = u64(len(infill.segments)),
		infill_boundary_hit_count = u64(len(infill.boundary_hits)),
		infill_hash = string(infill_hash_text),
		path_plan_error = path_plan_error_name(path_plan_error),
		planned_path_count = u64(len(path_plan.paths)),
		planned_move_count = u64(len(path_plan.moves)),
		planned_travel_move_count = path_plan.travel_move_count,
		planned_extrude_move_count = path_plan.extrude_move_count,
		path_plan_hash = string(path_plan_hash_text),
		feature_topology_policy = "strict-printable",
		feature_output_printable = true,
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
		fmt.eprintln("[hw_slicer] region probe encoding failed")
		os.exit(1)
	}
	defer delete(output)
	fmt.println(string(output))
	if !validated {os.exit(1)}
}

surface_error_name :: proc(error: features.Surface_Error) -> string {
	switch error {
	case .None:              return "none"
	case .Invalid_Config:    return "invalid-config"
	case .Invalid_Input:     return "invalid-input"
	case .Mask_Limit:        return "mask-limit"
	case .Path_Limit:        return "path-limit"
	case .Point_Limit:       return "point-limit"
	case .Provider:          return "provider"
	case .Allocation_Failed: return "allocation-failed"
	case .Arithmetic:        return "arithmetic"
	}
	return "invalid"
}

topology_issue_error_name :: proc(
	error: slicing.Topology_Issue_Error,
) -> string {
	switch error {
	case .None:              return "none"
	case .Invalid_Input:     return "invalid-input"
	case .Issue_Limit:       return "issue-limit"
	case .Reference_Limit:   return "reference-limit"
	case .Allocation_Failed: return "allocation-failed"
	case .Arithmetic:        return "arithmetic"
	}
	return "invalid"
}

region_error_name :: proc(error: slicing.Region_Error) -> string {
	switch error {
	case .None:                 return "none"
	case .Invalid_Input:        return "invalid-input"
	case .Contour_Limit:        return "contour-limit"
	case .Region_Limit:         return "region-limit"
	case .Pair_Test_Limit:      return "pair-test-limit"
	case .Contour_Intersection: return "contour-intersection"
	case .Arithmetic:           return "arithmetic"
	case .Allocation_Failed:    return "allocation-failed"
	}
	return "invalid"
}

path_plan_error_name :: proc(error: features.Path_Plan_Error) -> string {
	switch error {
	case .None:              return "none"
	case .Invalid_Config:    return "invalid-config"
	case .Invalid_Input:     return "invalid-input"
	case .Path_Limit:        return "path-limit"
	case .Move_Limit:        return "move-limit"
	case .Allocation_Failed: return "allocation-failed"
	case .Arithmetic:        return "arithmetic"
	}
	return "invalid"
}

infill_error_name :: proc(error: features.Infill_Error) -> string {
	switch error {
	case .None:                   return "none"
	case .Invalid_Config:         return "invalid-config"
	case .Invalid_Input:          return "invalid-input"
	case .Scanline_Limit:         return "scanline-limit"
	case .Segment_Limit:          return "segment-limit"
	case .Provider:               return "provider"
	case .Odd_Intersection_Count: return "odd-intersection-count"
	case .Allocation_Failed:      return "allocation-failed"
	case .Arithmetic:             return "arithmetic"
	}
	return "invalid"
}

perimeter_error_name :: proc(error: features.Perimeter_Error) -> string {
	switch error {
	case .None:              return "none"
	case .Invalid_Config:    return "invalid-config"
	case .Invalid_Input:     return "invalid-input"
	case .Group_Limit:       return "group-limit"
	case .Path_Limit:        return "path-limit"
	case .Point_Limit:       return "point-limit"
	case .Provider:          return "provider"
	case .Allocation_Failed: return "allocation-failed"
	case .Arithmetic:        return "arithmetic"
	}
	return "invalid"
}

contour_repair_error_name :: proc(
	error: repair.Contour_Repair_Error,
) -> string {
	switch error {
	case .None:                  return "none"
	case .Invalid_Input:         return "invalid-input"
	case .Not_Self_Intersection: return "not-self-intersection"
	case .Lineage_Limit:         return "lineage-limit"
	case .Lineage_Incomplete:    return "lineage-incomplete"
	case .Provider:              return "provider"
	case .Allocation_Failed:     return "allocation-failed"
	case .Arithmetic:            return "arithmetic"
	}
	return "invalid"
}
