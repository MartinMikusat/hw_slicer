package features

import "core:math"
import "core:mem"

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import slicing "../slicing"

// Keep configuration enums in a full word at provider call boundaries.
Feature_Topology_Policy :: enum u32 {
	Strict_Printable,
	Diagnostic_Closed_Regions,
}

Perimeter_Config :: struct {
	count:                      u32,
	line_width:                 contracts.Micrometres,
	outer_line_width:           contracts.Micrometres, // 0 = inherit line_width
	inner_line_width:           contracts.Micrometres, // 0 = inherit line_width
	first_layer_line_width:     contracts.Micrometres, // 0 = inherit line_width
	first_layer_count:          u32,                   // 0 = inherit count
	first_layer_inset_um:       contracts.Micrometres,
	xy_contour_compensation_um: contracts.Micrometres, // + expands outer, - shrinks outer
	xy_hole_compensation_um:    contracts.Micrometres, // + enlarges holes, - shrinks holes
	precise_outer_wall:         bool,
	layer_height_um:            contracts.Micrometres, // used by precise_outer_wall spacing
	topology_policy:            Feature_Topology_Policy,
	join_type:                  polygon.Polygon_Join_Type,
	miter_limit:                f64,
	arc_tolerance:              f64,
}

Perimeter_Limits :: struct {
	max_groups: u64,
	max_paths:  u64,
	max_points: u64,
	polygon:    polygon.Polygon_Limits,
}

DEFAULT_PERIMETER_LIMITS :: Perimeter_Limits{
	max_groups = 100_000_000,
	max_paths = 200_000_000,
	max_points = 1_000_000_000,
	polygon = polygon.DEFAULT_POLYGON_LIMITS,
}

Perimeter_Layer :: struct {
	group_offset: u64,
	group_count:  u32,
	path_offset:  u64,
	path_count:   u32,
}

Perimeter_Group :: struct {
	region_id:       contracts.Stable_ID,
	region_index:    u32,
	layer_index:     u32,
	perimeter_index: u32,
	delta:           contracts.Micrometres,
	path_offset:     u64,
	path_count:      u32,
}

Perimeter_Path :: struct {
	stable_id:         contracts.Stable_ID,
	region_id:         contracts.Stable_ID,
	region_index:      u32,
	layer_index:       u32,
	perimeter_index:   u32,
	group_path_index:  u32,
	point_offset:      u64,
	point_count:       u32,
	signed_area_2:     i128,
	winding:           geometry.Predicate_Sign,
}

Perimeter_Result :: struct {
	config: Perimeter_Config,
	layers: []Perimeter_Layer,
	groups: []Perimeter_Group,
	paths:  []Perimeter_Path,
	points: []polygon.Polygon_Point,
}

Perimeter_Error :: enum u8 {
	None,
	Invalid_Config,
	Invalid_Input,
	Group_Limit,
	Path_Limit,
	Point_Limit,
	Provider,
	Allocation_Failed,
	Arithmetic,
}

perimeters_generate :: proc(
	topology: slicing.Topology_Result,
	regions: slicing.Region_Result,
	provider: polygon.Polygon_Provider,
	requested_config: Perimeter_Config,
	limits := DEFAULT_PERIMETER_LIMITS,
	allocator := context.allocator,
) -> (Perimeter_Result, Perimeter_Error) {
	config := requested_config
	if !perimeter_config_valid(config) || provider.offset == nil {
		return {}, .Invalid_Config
	}
	if config.arc_tolerance == 0 {config.arc_tolerance = 0}
	if len(regions.layers) != len(topology.layers) {
		return {}, .Invalid_Input
	}
	if len(regions.layers) == 0 && len(regions.regions) > 0 {
		return {}, .Invalid_Input
	}
	if config.topology_policy == .Strict_Printable &&
	   (topology.open_chain_count > 0 ||
	    topology.degenerate_loop_count > 0 ||
	    topology.non_manifold_vertex_count > 0) {
		return {}, .Invalid_Input
	}
	if u64(len(regions.layers)) > u64(max(u32)) ||
	   u64(len(regions.regions)) > u64(max(u32)) {
		return {}, .Arithmetic
	}
	group_count_128 := u128(len(regions.regions))*u128(config.count)
	if group_count_128 > u128(limits.max_groups) {
		return {}, .Group_Limit
	}
	if group_count_128 > u128(max(int)) {
		return {}, .Arithmetic
	}
	group_count := int(group_count_128)
	temporary_outputs := make(
		[]polygon.Polygon_Set,
		group_count,
		allocator,
	)
	result := Perimeter_Result{config = config}
	result.layers = make(
		[]Perimeter_Layer,
		len(regions.layers),
		allocator,
	)
	result.groups = make([]Perimeter_Group, group_count, allocator)
	if group_count > 0 &&
	   (temporary_outputs == nil || result.groups == nil) ||
	   len(regions.layers) > 0 && result.layers == nil {
		delete(temporary_outputs, allocator)
		perimeter_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	defer {
		for &output in temporary_outputs {
			polygon.polygon_set_destroy(&output, allocator)
		}
		delete(temporary_outputs, allocator)
	}

	// Deduplicate regions with identical 2D contours and inset settings (common on prismatic CAD
	// vertical walls) so offsetting runs once per unique region shape.
	region_count := len(regions.regions)
	region_inputs := make([]polygon.Polygon_Set, region_count, allocator)
	canon_of := make([]int, region_count, allocator)
	unique_regions := make([dynamic]int, 0, region_count, allocator)
	defer {
		for &inp in region_inputs {polygon.polygon_set_destroy(&inp, allocator)}
		delete(region_inputs, allocator)
		delete(canon_of, allocator)
		delete(unique_regions)
	}
	if region_count > 0 {
		has_l0_special := i64(config.first_layer_inset_um) > 0 ||
			i64(config.first_layer_line_width) > 0 ||
			config.first_layer_count > 0
		cap_pow2 := 16
		for cap_pow2 < region_count * 2 {cap_pow2 <<= 1}
		ht_mask := u64(cap_pow2 - 1)
		ht := make([]int, cap_pow2, allocator)
		defer delete(ht, allocator)
		for r_idx in 0..<region_count {
			inp, inp_err := perimeter_region_input(topology, regions, u32(r_idx), allocator)
			if inp_err != .None {
				perimeter_result_destroy(&result, allocator)
				return {}, inp_err
			}
			region_inputs[r_idx] = inp
			is_l0 := has_l0_special && regions.regions[r_idx].layer_index == 0
			h := features_polygon_set_hash64(inp) ~ (u64(0x9e3779b97f4a7c15) if is_l0 else 0)
			slot := h & ht_mask
			found := -1
			for {
				entry := ht[slot]
				if entry == 0 {break}
				cand := entry - 1
				cand_l0 := has_l0_special && regions.regions[cand].layer_index == 0
				if cand_l0 == is_l0 && features_polygon_sets_equal(region_inputs[cand], inp) {
					found = cand
					break
				}
				slot = (slot + 1) & ht_mask
			}
			if found >= 0 {
				canon_of[r_idx] = found
			} else {
				ht[slot] = r_idx + 1
				canon_of[r_idx] = r_idx
				append(&unique_regions, r_idx)
			}
		}
	}

	Perim_Par_Ctx :: struct {
		regions:           slicing.Region_Result,
		region_inputs:     []polygon.Polygon_Set,
		unique_regions:    []int,
		provider:          polygon.Polygon_Provider,
		config:            Perimeter_Config,
		limits:            Perimeter_Limits,
		temporary_outputs: []polygon.Polygon_Set,
		region_errors:     []Perimeter_Error,
		allocator:         mem.Allocator,
	}
	region_errors := make([]Perimeter_Error, region_count, allocator)
	defer delete(region_errors, allocator)
	pctx := Perim_Par_Ctx{
		regions           = regions,
		region_inputs     = region_inputs,
		unique_regions    = unique_regions[:],
		provider          = provider,
		config            = config,
		limits            = limits,
		temporary_outputs = temporary_outputs,
		region_errors     = region_errors,
		allocator         = allocator,
	}
	parallel_for(len(unique_regions), &pctx, proc(c: ^Perim_Par_Ctx, ui: int) {
		region_index := c.unique_regions[ui]
		region := c.regions.regions[region_index]
		input := c.region_inputs[region_index]
		comp_owned: polygon.Polygon_Set
		defer polygon.polygon_set_destroy(&comp_owned, c.allocator)
		if i64(c.config.xy_contour_compensation_um) != 0 || i64(c.config.xy_hole_compensation_um) != 0 {
			if compensated, comp_ok := perimeter_apply_xy_compensation(input, c.config, c.provider, c.limits.polygon, c.allocator); comp_ok {
				comp_owned = compensated
				input = comp_owned
			}
		}
		if len(input.paths) == 0 {return}
		base_slot := region_index * int(c.config.count)
		eff_count := c.config.count
		if region.layer_index == 0 && c.config.first_layer_count > 0 && c.config.first_layer_count < eff_count {
			eff_count = c.config.first_layer_count
		}
		for perimeter_index in 0..<eff_count {
			base_delta, delta_ok := perimeter_delta_for_layer(c.config, region.layer_index, perimeter_index)
			if !delta_ok {
				c.region_errors[region_index] = .Arithmetic
				return
			}
			delta := base_delta
			if region.layer_index == 0 && i64(c.config.first_layer_inset_um) > 0 {
				delta = contracts.Micrometres(i64(base_delta) - i64(c.config.first_layer_inset_um))
			}
			slot := base_slot + int(perimeter_index)
			output_error: polygon.Polygon_Error
			c.temporary_outputs[slot], output_error =
				c.provider.offset(
					input,
					delta,
					c.config.join_type,
					c.config.miter_limit,
					c.config.arc_tolerance,
					c.limits.polygon,
					c.allocator,
				)
			if output_error == .None && len(c.temporary_outputs[slot].paths) == 0 &&
			   perimeter_index == 0 && delta != base_delta {
				polygon.polygon_set_destroy(&c.temporary_outputs[slot], c.allocator)
				delta = base_delta
				c.temporary_outputs[slot], output_error =
					c.provider.offset(
						input,
						delta,
						c.config.join_type,
						c.config.miter_limit,
						c.config.arc_tolerance,
						c.limits.polygon,
						c.allocator,
					)
			}
			if output_error != .None {
				c.region_errors[region_index] = .Provider
				return
			}
		}
	})

	total_paths: u64
	total_points: u64
	group_write := 0
	for region, region_index in regions.regions {
		src_region := canon_of[region_index]
		if region_errors[src_region] != .None {
			perimeter_result_destroy(&result, allocator)
			return {}, region_errors[src_region]
		}
		for perimeter_index in 0..<config.count {
			base_delta, _ := perimeter_delta(config, perimeter_index)
			output := temporary_outputs[src_region * int(config.count) + int(perimeter_index)]
			if total_paths > limits.max_paths ||
			   u64(len(output.paths)) >
			   	limits.max_paths-total_paths {
				perimeter_result_destroy(&result, allocator)
				return {}, .Path_Limit
			}
			if total_points > limits.max_points ||
			   u64(len(output.points)) >
			   	limits.max_points-total_points {
				perimeter_result_destroy(&result, allocator)
				return {}, .Point_Limit
			}
			if u64(len(output.paths)) > u64(max(u32)) {
				perimeter_result_destroy(&result, allocator)
				return {}, .Arithmetic
			}
			result.groups[group_write] = {
				region_id = region.stable_id,
				region_index = u32(region_index),
				layer_index = region.layer_index,
				perimeter_index = perimeter_index,
				delta = base_delta,
				path_offset = total_paths,
				path_count = u32(len(output.paths)),
			}
			total_paths += u64(len(output.paths))
			total_points += u64(len(output.points))
			group_write += 1
		}
	}
	if group_write != group_count ||
	   total_paths > u64(max(int)) ||
	   total_points > u64(max(int)) {
		perimeter_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}

	result.paths = make([]Perimeter_Path, int(total_paths), allocator)
	result.points = make(
		[]polygon.Polygon_Point,
		int(total_points),
		allocator,
	)
	if total_paths > 0 && result.paths == nil ||
	   total_points > 0 && result.points == nil {
		perimeter_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	path_write := 0
	point_write := 0
	for group, group_index in result.groups {
		src_slot := canon_of[int(group.region_index)] * int(config.count) + int(group.perimeter_index)
		output := temporary_outputs[src_slot]
		for output_path, output_path_index in output.paths {
			if output_path.count > u64(max(u32)) {
				perimeter_result_destroy(&result, allocator)
				return {}, .Arithmetic
			}
			source_start := int(output_path.offset)
			source_end := source_start+int(output_path.count)
			points := output.points[source_start:source_end]
			area := polygon.polygon_path_area_2(points)
			if area == 0 {
				perimeter_result_destroy(&result, allocator)
				return {}, .Provider
			}
			winding := geometry.Predicate_Sign.Positive
			if area < 0 {winding = .Negative}
			ordinal, ordinal_ok := feature_perimeter_ordinal(
				group.perimeter_index,
				u32(output_path_index),
			)
			if !ordinal_ok {
				perimeter_result_destroy(&result, allocator)
				return {}, .Arithmetic
			}
			result.paths[path_write] = {
				stable_id = contracts.stable_id_child(
					group.region_id,
					.Feature,
					ordinal,
				),
				region_id = group.region_id,
				region_index = group.region_index,
				layer_index = group.layer_index,
				perimeter_index = group.perimeter_index,
				group_path_index = u32(output_path_index),
				point_offset = u64(point_write),
				point_count = u32(len(points)),
				signed_area_2 = area,
				winding = winding,
			}
			copy(
				result.points[point_write:point_write+len(points)],
				points,
			)
			path_write += 1
			point_write += len(points)
		}
	}
	if path_write != len(result.paths) || point_write != len(result.points) {
		perimeter_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}

	layer_path_offset: u64
	for region_layer, layer_index in regions.layers {
		group_offset := region_layer.region_offset*u64(config.count)
		group_count_for_layer :=
			u64(region_layer.region_count)*u64(config.count)
		if group_count_for_layer > u64(max(u32)) {
			perimeter_result_destroy(&result, allocator)
			return {}, .Arithmetic
		}
		path_count_for_layer: u64
		if group_count_for_layer > 0 {
			first_group := result.groups[group_offset]
			if first_group.path_offset != layer_path_offset {
				perimeter_result_destroy(&result, allocator)
				return {}, .Arithmetic
			}
			group_end := group_offset+group_count_for_layer
			for group in result.groups[group_offset:group_end] {
				path_count_for_layer += u64(group.path_count)
			}
		}
		if path_count_for_layer > u64(max(u32)) {
			perimeter_result_destroy(&result, allocator)
			return {}, .Arithmetic
		}
		result.layers[layer_index] = {
			group_offset = group_offset,
			group_count = u32(group_count_for_layer),
			path_offset = layer_path_offset,
			path_count = u32(path_count_for_layer),
		}
		layer_path_offset += path_count_for_layer
	}
	if layer_path_offset != total_paths {
		perimeter_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
}

perimeter_region_input :: proc(
	topology: slicing.Topology_Result,
	regions: slicing.Region_Result,
	region_index: u32,
	allocator := context.allocator,
) -> (polygon.Polygon_Set, Perimeter_Error) {
	if u64(region_index) >= u64(len(regions.regions)) {
		return {}, .Invalid_Input
	}
	region := regions.regions[region_index]
	if region.contour_count == 0 ||
	   region.contour_offset+u64(region.contour_count) >
	   	u64(len(regions.region_contour_indices)) {
		return {}, .Invalid_Input
	}
	point_count: u64
	start := int(region.contour_offset)
	end := start+int(region.contour_count)
	for contour_index in regions.region_contour_indices[start:end] {
		if u64(contour_index) >= u64(len(regions.contours)) {
			return {}, .Invalid_Input
		}
		contour := regions.contours[contour_index]
		if contour.region_index != region_index ||
		   u64(contour.path_index) >= u64(len(topology.paths)) {
			return {}, .Invalid_Input
		}
		path_point_count :=
			u64(topology.paths[contour.path_index].vertex_count)
		if point_count > u64(max(int)) ||
		   path_point_count > u64(max(int))-point_count {
			return {}, .Arithmetic
		}
		point_count += path_point_count
	}
	if point_count > u64(max(int)) {return {}, .Arithmetic}
	result: polygon.Polygon_Set
	result.points = make(
		[]polygon.Polygon_Point,
		int(point_count),
		allocator,
	)
	result.paths = make(
		[]polygon.Polygon_Path,
		int(region.contour_count),
		allocator,
	)
	if result.points == nil || result.paths == nil {
		polygon.polygon_set_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	point_write := 0
	for contour_index, local_contour_index in
	    regions.region_contour_indices[start:end] {
		contour := regions.contours[contour_index]
		path := topology.paths[contour.path_index]
		result.paths[local_contour_index] = {
			offset = u64(point_write),
			count = u64(path.vertex_count),
		}
		for local_point_index in 0..<int(path.vertex_count) {
			source_point_index := local_point_index
			if contour.reverse_path {
				source_point_index =
					int(path.vertex_count)-1-local_point_index
			}
			point := slicing.region_path_point(
				topology,
				path,
				source_point_index,
			)
			result.points[point_write] = {point.x, point.y}
			point_write += 1
		}
	}
	if point_write != len(result.points) {
		polygon.polygon_set_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
}

perimeter_line_width_for :: proc(
	config: Perimeter_Config,
	layer_index: u32,
	perimeter_index: u32,
) -> contracts.Micrometres {
	if layer_index == 0 && i64(config.first_layer_line_width) > 0 {
		return config.first_layer_line_width
	}
	if perimeter_index == 0 && i64(config.outer_line_width) > 0 {
		return config.outer_line_width
	}
	if perimeter_index > 0 && i64(config.inner_line_width) > 0 {
		return config.inner_line_width
	}
	return config.line_width
}

perimeter_delta_for_layer :: proc(
	config: Perimeter_Config,
	layer_index: u32,
	perimeter_index: u32,
) -> (contracts.Micrometres, bool) {
	outer_w := i128(i64(perimeter_line_width_for(config, layer_index, 0)))
	inner_w := i128(i64(perimeter_line_width_for(config, layer_index, 1)))
	distance: i128
	if perimeter_index == 0 {
		distance = outer_w / 2
	} else {
		precise_extra := i128(i64(config.layer_height_um) / 4) if config.precise_outer_wall && i64(config.layer_height_um) > 0 else 0
		distance = outer_w + precise_extra + inner_w/2 + i128(perimeter_index - 1)*inner_w
	}
	if distance <= 0 || distance > i128(geometry.MAX_PLANAR_COORDINATE_UM) {
		return 0, false
	}
	return contracts.Micrometres(-i64(distance)), true
}

@(private = "file")
perimeter_apply_xy_compensation :: proc(
	input: polygon.Polygon_Set,
	config: Perimeter_Config,
	provider: polygon.Polygon_Provider,
	limits: polygon.Polygon_Limits,
	allocator: mem.Allocator,
) -> (polygon.Polygon_Set, bool) {
	if len(input.paths) == 0 || provider.offset == nil {return {}, false}
	outer_comp := config.xy_contour_compensation_um
	hole_comp := config.xy_hole_compensation_um
	// Separate outer (CCW, area > 0) and holes (CW, area < 0).
	outer_pts := make([dynamic]polygon.Polygon_Point, 0, len(input.points), context.temp_allocator)
	outer_paths := make([dynamic]polygon.Polygon_Path, 0, 2, context.temp_allocator)
	hole_pts := make([dynamic]polygon.Polygon_Point, 0, len(input.points), context.temp_allocator)
	hole_paths := make([dynamic]polygon.Polygon_Path, 0, len(input.paths), context.temp_allocator)
	for p in input.paths {
		ring := input.points[p.offset:p.offset+p.count]
		area := polygon.polygon_path_area_2(ring)
		if area > 0 {
			off := u64(len(outer_pts))
			append(&outer_pts, ..ring)
			append(&outer_paths, polygon.Polygon_Path{offset = off, count = p.count})
		} else if area < 0 {
			// Reverse CW hole to CCW so positive hole_comp expands the hole.
			off := u64(len(hole_pts))
			for k := len(ring) - 1; k >= 0; k -= 1 {
				append(&hole_pts, ring[k])
			}
			append(&hole_paths, polygon.Polygon_Path{offset = off, count = p.count})
		}
	}
	if len(outer_paths) == 0 {return {}, false}
	outer_set := polygon.Polygon_Set{points = outer_pts[:], paths = outer_paths[:]}
	comp_outer: polygon.Polygon_Set
	outer_owned := false
	defer if outer_owned {polygon.polygon_set_destroy(&comp_outer, allocator)}
	if i64(outer_comp) != 0 {
		err: polygon.Polygon_Error
		comp_outer, err = provider.offset(outer_set, outer_comp, config.join_type, config.miter_limit, config.arc_tolerance, limits, allocator)
		if err != .None {return {}, false}
		outer_owned = true
	} else {
		comp_outer = outer_set
	}
	if len(hole_paths) == 0 {
		if outer_owned {
			outer_owned = false
			return comp_outer, true
		}
		return {}, false
	}
	hole_set := polygon.Polygon_Set{points = hole_pts[:], paths = hole_paths[:]}
	comp_holes: polygon.Polygon_Set
	holes_owned := false
	defer if holes_owned {polygon.polygon_set_destroy(&comp_holes, allocator)}
	if i64(hole_comp) != 0 {
		err: polygon.Polygon_Error
		comp_holes, err = provider.offset(hole_set, hole_comp, config.join_type, config.miter_limit, config.arc_tolerance, limits, allocator)
		if err != .None {return {}, false}
		holes_owned = true
	} else {
		comp_holes = hole_set
	}
	if len(comp_holes.paths) == 0 {
		if outer_owned {
			outer_owned = false
			return comp_outer, true
		}
		// Copy outer_set into allocator
		res := polygon.Polygon_Set{
			points = make([]polygon.Polygon_Point, len(comp_outer.points), allocator),
			paths  = make([]polygon.Polygon_Path, len(comp_outer.paths), allocator),
		}
		copy(res.points, comp_outer.points)
		copy(res.paths, comp_outer.paths)
		return res, true
	}
	if provider.boolean == nil {return {}, false}
	diff, diff_err := provider.boolean(comp_outer, comp_holes, .Difference, .Non_Zero, limits, allocator)
	if diff_err != .None {
		polygon.polygon_set_destroy(&diff, allocator)
		return {}, false
	}
	return diff, true
}

perimeter_delta :: proc(
	config: Perimeter_Config,
	perimeter_index: u32,
) -> (contracts.Micrometres, bool) {
	return perimeter_delta_for_layer(config, 1, perimeter_index)
}

perimeter_join_type_valid :: proc(
	join_type: polygon.Polygon_Join_Type,
) -> bool {
	switch join_type {
	case .Square, .Bevel, .Round, .Miter:
		return true
	}
	return false
}

perimeter_config_valid :: proc(config: Perimeter_Config) -> bool {
	return config.count > 0 &&
		config.count <= FEATURE_PERIMETER_COUNT_LIMIT &&
		i64(config.line_width) > 0 &&
		i64(config.line_width)&1 == 0 &&
		i64(config.line_width) <= geometry.MAX_PLANAR_COORDINATE_UM &&
		!math.is_nan(config.miter_limit) &&
		!math.is_inf(config.miter_limit) &&
		!math.is_nan(config.arc_tolerance) &&
		!math.is_inf(config.arc_tolerance) &&
		config.miter_limit >= 1 &&
		config.arc_tolerance >= 0 &&
		(config.topology_policy == .Strict_Printable ||
		 config.topology_policy == .Diagnostic_Closed_Regions) &&
		perimeter_join_type_valid(config.join_type)
}

perimeter_result_destroy :: proc(
	result: ^Perimeter_Result,
	allocator := context.allocator,
) {
	delete(result.layers, allocator)
	delete(result.groups, allocator)
	delete(result.paths, allocator)
	delete(result.points, allocator)
	result^ = {}
}
