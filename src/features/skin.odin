package features

import "core:mem"

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import profiles "../profiles"
import slicing "../slicing"

Skin_Kind :: enum u8 {
	Invalid,
	Bottom,
	Top,
	Top_Bottom,
}

Skin_Config :: struct {
	fill_rule:             polygon.Polygon_Fill_Rule,
	top:                   profiles.Skin_Target,
	bottom:                profiles.Skin_Target,
	skip_source_filtering: bool,
	omit_top_skin:         bool,
}

Skin_Limits :: struct {
	max_masks:             u64,
	max_paths:             u64,
	max_points:            u64,
	max_source_references: u64,
	polygon:               polygon.Polygon_Limits,
}

DEFAULT_SKIN_LIMITS :: Skin_Limits{
	max_masks = 200_000_000,
	max_paths = 400_000_000,
	max_points = 2_000_000_000,
	max_source_references = 1_000_000_000,
	polygon = polygon.DEFAULT_POLYGON_LIMITS,
}

Skin_Layer :: struct {
	mask_offset:             u64,
	mask_count:              u32,
	path_offset:             u64,
	path_count:              u32,
	source_reference_offset: u64,
	source_reference_count:  u32,
}

Skin_Mask :: struct {
	stable_id:               contracts.Stable_ID,
	region_id:               contracts.Stable_ID,
	region_index:            u32,
	layer_index:             u32,
	kind:                    Skin_Kind,
	path_offset:             u64,
	path_count:              u32,
	point_offset:            u64,
	point_count:             u32,
	source_reference_offset: u64,
	source_reference_count:  u32,
}

Skin_Path :: struct {
	stable_id:       contracts.Stable_ID,
	mask_id:         contracts.Stable_ID,
	mask_path_index: u32,
	point_offset:    u64,
	point_count:     u32,
	signed_area_2:   i128,
	winding:         geometry.Predicate_Sign,
}

Skin_Source_Reference :: struct {
	surface_mask_index: u32,
	surface_id:         contracts.Stable_ID,
	surface_kind:       Surface_Kind,
	source_layer_index: u32,
}

Skin_Result :: struct {
	config:                 Skin_Config,
	layers:                 []Skin_Layer,
	masks:                  []Skin_Mask,
	paths:                  []Skin_Path,
	points:                 []polygon.Polygon_Point,
	source_references:      []Skin_Source_Reference,
	bottom_mask_count:      u64,
	top_mask_count:         u64,
	top_bottom_mask_count:  u64,
}

Skin_Error :: enum u8 {
	None,
	Invalid_Config,
	Invalid_Input,
	Mask_Limit,
	Path_Limit,
	Point_Limit,
	Source_Reference_Limit,
	Provider,
	Allocation_Failed,
	Arithmetic,
}

skins_propagate :: proc(
	topology: slicing.Topology_Result,
	regions: slicing.Region_Result,
	surfaces: Surface_Result,
	layer_heights: []contracts.Micrometres,
	provider: polygon.Polygon_Provider,
	config: Skin_Config,
	limits := DEFAULT_SKIN_LIMITS,
	allocator := context.allocator,
) -> (Skin_Result, Skin_Error) {
	if !skin_config_valid(config) || provider.boolean == nil {
		return {}, .Invalid_Config
	}
	if len(layer_heights) != len(regions.layers) ||
	   len(surfaces.layers) != len(regions.layers) ||
	   len(topology.layers) != len(regions.layers) {
		return {}, .Invalid_Input
	}
	for height in layer_heights {
		if i64(height) <= 0 {return {}, .Invalid_Input}
	}
	if surfaces.config.fill_rule != config.fill_rule {
		return {}, .Invalid_Input
	}
	if len(regions.regions) > max(int)/3 ||
	   len(regions.regions) > max(int)/2 ||
	   u64(len(surfaces.masks)) > u64(max(u32)) {
		return {}, .Arithmetic
	}

	region_inputs := make(
		[]polygon.Polygon_Set,
		len(regions.regions),
		allocator,
	)
	accumulators := make(
		[]polygon.Polygon_Set,
		len(regions.regions)*2,
		allocator,
	)
	outputs := make(
		[]polygon.Polygon_Set,
		len(regions.regions)*3,
		allocator,
	)
	contribution_sources := make(
		[][dynamic]u32,
		len(regions.regions)*2,
		allocator,
	)
	output_sources := make(
		[][dynamic]u32,
		len(regions.regions)*3,
		allocator,
	)
	if len(regions.regions) > 0 &&
	   (region_inputs == nil || accumulators == nil ||
	    outputs == nil || contribution_sources == nil ||
	    output_sources == nil) {
		delete(region_inputs, allocator)
		delete(accumulators, allocator)
		delete(outputs, allocator)
		delete(contribution_sources, allocator)
		delete(output_sources, allocator)
		return {}, .Allocation_Failed
	}
	for &sources in contribution_sources {
		sources = make([dynamic]u32, allocator)
	}
	for &sources in output_sources {
		sources = make([dynamic]u32, allocator)
	}
	defer {
		for &input in region_inputs {
			polygon.polygon_set_destroy(&input, allocator)
		}
		for &set in accumulators {
			polygon.polygon_set_destroy(&set, allocator)
		}
		for &set in outputs {
			polygon.polygon_set_destroy(&set, allocator)
		}
		for &sources in contribution_sources {
			delete(sources)
		}
		for &sources in output_sources {
			delete(sources)
		}
		delete(region_inputs, allocator)
		delete(accumulators, allocator)
		delete(outputs, allocator)
		delete(contribution_sources, allocator)
		delete(output_sources, allocator)
	}

	filtered_source_count: u64
	for _, region_index in regions.regions {
		input, input_error := perimeter_region_input(
			topology,
			regions,
			u32(region_index),
			allocator,
		)
		if input_error != .None {
			if input_error == .Allocation_Failed {
				return {}, .Allocation_Failed
			}
			if input_error == .Arithmetic {
				return {}, .Arithmetic
			}
			return {}, .Invalid_Input
		}
		region_inputs[region_index] = input
	}

	Skin_Layer_Item :: struct {
		surface_mask_index: u32,
		accumulator_kind:   int,
	}
	surface_inputs := make([]polygon.Polygon_Set, len(surfaces.masks), allocator)
	defer {
		for &si in surface_inputs {
			polygon.polygon_set_destroy(&si, allocator)
		}
		delete(surface_inputs, allocator)
	}
	surface_bboxes := make([][4]i64, len(surfaces.masks), allocator)
	defer delete(surface_bboxes, allocator)
	region_bboxes := make([][4]i64, len(regions.regions), allocator)
	defer delete(region_bboxes, allocator)
	for ri, region_index in region_inputs {
		region_bboxes[region_index] = skin_polygon_bbox(ri)
	}
	layer_items := make([][dynamic]Skin_Layer_Item, len(regions.layers), allocator)
	defer {
		for &li in layer_items {delete(li)}
		delete(layer_items, allocator)
	}
	for surface_mask, surface_mask_index in surfaces.masks {
		if config.omit_top_skin && surface_mask.kind == .Top_Exposed {continue}
		target := config.bottom
		accumulator_kind := 0
		if surface_mask.kind == .Top_Exposed {
			target = config.top
			accumulator_kind = 1
		}
		first_layer, last_layer, range_ok := skin_target_layer_range(
			layer_heights,
			surface_mask.layer_index,
			surface_mask.kind,
			target,
		)
		if !range_ok {return {}, .Invalid_Input}
		source_input, source_error := skin_surface_input(
			surfaces,
			u32(surface_mask_index),
			allocator,
		)
		if source_error != .None {
			if source_error == .Allocation_Failed {
				return {}, .Allocation_Failed
			}
			if source_error == .Arithmetic {
				return {}, .Arithmetic
			}
			return {}, .Invalid_Input
		}
		surface_inputs[surface_mask_index] = source_input
		surface_bboxes[surface_mask_index] = skin_polygon_bbox(source_input)
		for target_layer in int(first_layer)..=int(last_layer) {
			append(&layer_items[target_layer], Skin_Layer_Item{
				surface_mask_index = u32(surface_mask_index),
				accumulator_kind   = accumulator_kind,
			})
		}
	}

	// Deduplicate regions that share identical 2D geometry and identical target layer_items
	// (common across 5–8 layer top/bottom solid stacks on prismatic CAD parts).
	region_count := len(regions.regions)
	canon_of := make([]int, region_count, allocator)
	unique_regions := make([dynamic]int, 0, region_count, allocator)
	defer {
		delete(canon_of, allocator)
		delete(unique_regions)
	}
	if region_count > 0 {
		cap_pow2 := 16
		for cap_pow2 < region_count * 2 {cap_pow2 <<= 1}
		ht_mask := u64(cap_pow2 - 1)
		ht := make([]int, cap_pow2, allocator)
		defer delete(ht, allocator)
		for r_idx in 0..<region_count {
			li := int(regions.regions[r_idx].layer_index)
			items := layer_items[li]
			h := features_polygon_set_hash64(region_inputs[r_idx])
			for it in items {
				h = (h ~ (u64(it.surface_mask_index) | (u64(it.accumulator_kind) << 32))) * 1099511628211
			}
			slot := h & ht_mask
			found := -1
			for {
				entry := ht[slot]
				if entry == 0 {break}
				cand := entry - 1
				cand_li := int(regions.regions[cand].layer_index)
				cand_items := layer_items[cand_li]
				if len(cand_items) == len(items) &&
				   features_polygon_sets_equal(region_inputs[cand], region_inputs[r_idx]) {
					same_items := true
					for ii in 0..<len(items) {
						if cand_items[ii] != items[ii] {
							same_items = false
							break
						}
					}
					if same_items {
						found = cand
						break
					}
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

	region_errors := make([]Skin_Error, region_count, allocator)
	defer delete(region_errors, allocator)
	region_filtered := make([]u64, region_count, allocator)
	defer delete(region_filtered, allocator)

	Skin_Par_Ctx :: struct {
		regions:              slicing.Region_Result,
		surfaces:             Surface_Result,
		surface_inputs:       []polygon.Polygon_Set,
		surface_bboxes:       [][4]i64,
		layer_items:          [][dynamic]Skin_Layer_Item,
		region_inputs:        []polygon.Polygon_Set,
		region_bboxes:        [][4]i64,
		unique_regions:       []int,
		accumulators:         []polygon.Polygon_Set,
		outputs:              []polygon.Polygon_Set,
		contribution_sources: [][dynamic]u32,
		output_sources:       [][dynamic]u32,
		provider:             polygon.Polygon_Provider,
		config:               Skin_Config,
		limits:               Skin_Limits,
		allocator:            mem.Allocator,
		region_errors:        []Skin_Error,
		region_filtered:      []u64,
	}
	sctx := Skin_Par_Ctx{
		regions              = regions,
		surfaces             = surfaces,
		surface_inputs       = surface_inputs,
		surface_bboxes       = surface_bboxes,
		layer_items          = layer_items,
		region_inputs        = region_inputs,
		region_bboxes        = region_bboxes,
		unique_regions       = unique_regions[:],
		accumulators         = accumulators,
		outputs              = outputs,
		contribution_sources = contribution_sources,
		output_sources       = output_sources,
		provider             = provider,
		config               = config,
		limits               = limits,
		allocator            = allocator,
		region_errors        = region_errors,
		region_filtered      = region_filtered,
	}

	parallel_for(len(unique_regions), &sctx, proc(c: ^Skin_Par_Ctx, ui: int) {
		region_index := c.unique_regions[ui]
		target_layer := int(c.regions.regions[region_index].layer_index)
		rb := c.region_bboxes[region_index]

		for item in c.layer_items[target_layer] {
			src_in := c.surface_inputs[item.surface_mask_index]
			if len(src_in.paths) == 0 {continue}
			sb := c.surface_bboxes[item.surface_mask_index]
			if sb[1] < rb[0] || rb[1] < sb[0] || sb[3] < rb[2] || rb[3] < sb[2] {
				continue
			}
			contribution, provider_error := c.provider.boolean(
				src_in,
				c.region_inputs[region_index],
				.Intersection,
				c.config.fill_rule,
				c.limits.polygon,
				c.allocator,
			)
			if provider_error != .None {
				c.region_errors[region_index] = .Provider
				return
			}
			if len(contribution.paths) == 0 {
				polygon.polygon_set_destroy(&contribution, c.allocator)
				continue
			}
			accumulator_index := region_index*2 + item.accumulator_kind
			accumulate_error := skin_polygon_accumulate(
				&c.accumulators[accumulator_index],
				&contribution,
				c.provider,
				c.config.fill_rule,
				c.limits.polygon,
				c.allocator,
			)
			if accumulate_error != .None {
				c.region_errors[region_index] = .Allocation_Failed if accumulate_error == .Allocation_Failed else .Provider
				return
			}
			if !c.config.skip_source_filtering {
				append(&c.contribution_sources[accumulator_index], item.surface_mask_index)
			}
		}

		local_filtered: u64
		bottom := c.accumulators[region_index*2]
		top := c.accumulators[region_index*2+1]
		output_offset := region_index*3
		combined: polygon.Polygon_Set
		if len(bottom.paths) > 0 && len(top.paths) > 0 {
			provider_error: polygon.Polygon_Error
			combined, provider_error = c.provider.boolean(
				bottom,
				top,
				.Intersection,
				c.config.fill_rule,
				c.limits.polygon,
				c.allocator,
			)
			if provider_error != .None {
				c.region_errors[region_index] = .Provider
				return
			}
		}
		if len(bottom.paths) > 0 {
			if len(combined.paths) > 0 {
				output, provider_error := c.provider.boolean(
					bottom,
					combined,
					.Difference,
					c.config.fill_rule,
					c.limits.polygon,
					c.allocator,
				)
				if provider_error != .None {
					polygon.polygon_set_destroy(&combined, c.allocator)
					c.region_errors[region_index] = .Provider
					return
				}
				c.outputs[output_offset] = output
			} else {
				c.outputs[output_offset] = bottom
				c.accumulators[region_index*2] = {}
			}
		}
		if len(top.paths) > 0 {
			if len(combined.paths) > 0 {
				output, provider_error := c.provider.boolean(
					top,
					combined,
					.Difference,
					c.config.fill_rule,
					c.limits.polygon,
					c.allocator,
				)
				if provider_error != .None {
					polygon.polygon_set_destroy(&combined, c.allocator)
					c.region_errors[region_index] = .Provider
					return
				}
				c.outputs[output_offset+1] = output
			} else {
				c.outputs[output_offset+1] = top
				c.accumulators[region_index*2+1] = {}
			}
		}
		c.outputs[output_offset+2] = combined

		if !c.config.skip_source_filtering {
			for kind_index in 0 ..< 3 {
				output := c.outputs[output_offset+kind_index]
				if len(output.paths) == 0 {continue}
				bottom_sources: []u32
				top_sources: []u32
				if kind_index != 1 {
					bottom_sources = c.contribution_sources[region_index*2][:]
				}
				if kind_index != 0 {
					top_sources = c.contribution_sources[region_index*2+1][:]
				}
				source_error := skin_filter_output_sources(
					&c.output_sources[output_offset+kind_index],
					output,
					bottom_sources,
					top_sources,
					c.surfaces,
					c.provider,
					c.config.fill_rule,
					c.limits,
					&local_filtered,
					c.allocator,
				)
				if source_error != .None {
					c.region_errors[region_index] = source_error
					return
				}
			}
		}
		c.region_filtered[region_index] = local_filtered
	})

	for ui in unique_regions {
		if region_errors[ui] != .None {return {}, region_errors[ui]}
		filtered_source_count += region_filtered[ui]
	}
	// Clone canonical outputs to deduplicated sibling regions.
	for r_idx in 0..<region_count {
		src := canon_of[r_idx]
		if src == r_idx {continue}
		filtered_source_count += region_filtered[src]
		for kind_index in 0..<3 {
			src_out := outputs[src*3 + kind_index]
			if len(src_out.paths) > 0 {
				ok: bool
				outputs[r_idx*3 + kind_index], ok = skin_polygon_clone(src_out, allocator)
				if !ok {return {}, .Allocation_Failed}
			}
			if !config.skip_source_filtering && len(output_sources[src*3 + kind_index]) > 0 {
				append(&output_sources[r_idx*3 + kind_index], ..output_sources[src*3 + kind_index][:])
			}
		}
	}

	total_masks: u64
	total_paths: u64
	total_points: u64
	total_source_references: u64
	for &output, output_index in outputs {
		if len(output.paths) == 0 {continue}
		if !config.skip_source_filtering && len(output_sources[output_index]) == 0 {
			// Drop sub-micrometre rounding slivers that do not intersect any source surface.
			polygon.polygon_set_destroy(&output, allocator)
			continue
		}
		total_masks += 1
		if total_masks > limits.max_masks {
			return {}, .Mask_Limit
		}
		if total_paths > limits.max_paths ||
		   u64(len(output.paths)) > limits.max_paths-total_paths {
			return {}, .Path_Limit
		}
		if total_points > limits.max_points ||
		   u64(len(output.points)) > limits.max_points-total_points {
			return {}, .Point_Limit
		}
		if total_source_references > limits.max_source_references ||
		   u64(len(output_sources[output_index])) >
		   	limits.max_source_references-total_source_references {
			return {}, .Source_Reference_Limit
		}
		total_paths += u64(len(output.paths))
		total_points += u64(len(output.points))
		total_source_references +=
			u64(len(output_sources[output_index]))
	}
	if total_masks > u64(max(int)) ||
	   total_paths > u64(max(int)) ||
	   total_points > u64(max(int)) ||
	   total_source_references > u64(max(int)) {
		return {}, .Arithmetic
	}

	result := Skin_Result{config = config}
	result.layers = make([]Skin_Layer, len(regions.layers), allocator)
	result.masks = make([]Skin_Mask, int(total_masks), allocator)
	result.paths = make([]Skin_Path, int(total_paths), allocator)
	result.points = make(
		[]polygon.Polygon_Point,
		int(total_points),
		allocator,
	)
	result.source_references = make(
		[]Skin_Source_Reference,
		int(total_source_references),
		allocator,
	)
	if len(result.layers) > 0 && result.layers == nil ||
	   total_masks > 0 && result.masks == nil ||
	   total_paths > 0 && result.paths == nil ||
	   total_points > 0 && result.points == nil ||
	   total_source_references > 0 &&
	   	result.source_references == nil {
		skin_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	mask_write := 0
	path_write := 0
	point_write := 0
	source_write := 0
	for layer, layer_index in regions.layers {
		layer_mask_start := mask_write
		layer_path_start := path_write
		layer_source_start := source_write
		region_start := int(layer.region_offset)
		region_end := region_start+int(layer.region_count)
		for region_index in region_start..<region_end {
			for kind_index in 0..<3 {
				output_index := region_index*3+kind_index
				output := outputs[output_index]
				if len(output.paths) == 0 {continue}
				kind := Skin_Kind(kind_index+1)
				ordinal, ordinal_ok := feature_skin_ordinal(kind)
				if !ordinal_ok {
					skin_result_destroy(&result, allocator)
					return {}, .Arithmetic
				}
				region := regions.regions[region_index]
				mask_id := contracts.stable_id_child(
					region.stable_id,
					.Feature,
					ordinal,
				)
				mask_path_start := path_write
				mask_point_start := point_write
				mask_source_start := source_write
				for source_index in output_sources[output_index] {
					source := surfaces.masks[source_index]
					result.source_references[source_write] = {
						surface_mask_index = source_index,
						surface_id = source.stable_id,
						surface_kind = source.kind,
						source_layer_index = source.layer_index,
					}
					source_write += 1
				}
				for source_path, local_path_index in output.paths {
					if source_path.count > u64(max(u32)) {
						skin_result_destroy(&result, allocator)
						return {}, .Arithmetic
					}
					start := int(source_path.offset)
					end := start+int(source_path.count)
					points := output.points[start:end]
					area := polygon.polygon_path_area_2(points)
					winding := geometry.Predicate_Sign.Positive
					if area < 0 {winding = .Negative}
					result.paths[path_write] = {
						stable_id = contracts.stable_id_child(
							mask_id,
							.Path,
							u64(local_path_index),
						),
						mask_id = mask_id,
						mask_path_index = u32(local_path_index),
						point_offset = u64(point_write),
						point_count = u32(source_path.count),
						signed_area_2 = area,
						winding = winding,
					}
					copy(
						result.points[
							point_write:
							point_write+len(points)
						],
						points,
					)
					path_write += 1
					point_write += len(points)
				}
				result.masks[mask_write] = {
					stable_id = mask_id,
					region_id = region.stable_id,
					region_index = u32(region_index),
					layer_index = u32(layer_index),
					kind = kind,
					path_offset = u64(mask_path_start),
					path_count = u32(path_write-mask_path_start),
					point_offset = u64(mask_point_start),
					point_count = u32(point_write-mask_point_start),
					source_reference_offset =
						u64(mask_source_start),
					source_reference_count =
						u32(source_write-mask_source_start),
				}
				switch kind {
				case .Bottom:     result.bottom_mask_count += 1
				case .Top:        result.top_mask_count += 1
				case .Top_Bottom: result.top_bottom_mask_count += 1
				case .Invalid:
				}
				mask_write += 1
			}
		}
		result.layers[layer_index] = {
			mask_offset = u64(layer_mask_start),
			mask_count = u32(mask_write-layer_mask_start),
			path_offset = u64(layer_path_start),
			path_count = u32(path_write-layer_path_start),
			source_reference_offset = u64(layer_source_start),
			source_reference_count = u32(source_write-layer_source_start),
		}
	}
	if mask_write != len(result.masks) ||
	   path_write != len(result.paths) ||
	   point_write != len(result.points) ||
	   source_write != len(result.source_references) {
		skin_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
}

skin_target_layer_range :: proc(
	layer_heights: []contracts.Micrometres,
	source_layer: u32,
	kind: Surface_Kind,
	target: profiles.Skin_Target,
) -> (u32, u32, bool) {
	if u64(source_layer) >= u64(len(layer_heights)) ||
	   !profiles.skin_target_valid(target) ||
	   kind != .Bottom_Exposed && kind != .Top_Exposed {
		return 0, 0, false
	}
	first := int(source_layer)
	last := int(source_layer)
	accumulated: i128
	count: u32
	index := int(source_layer)
	for {
		height := i64(layer_heights[index])
		if height <= 0 {return 0, 0, false}
		accumulated += i128(height)
		count += 1
		if kind == .Bottom_Exposed {
			last = index
		} else {
			first = index
		}
		if accumulated >= i128(target.thickness) &&
		   count >= target.minimum_layers {
			break
		}
		if kind == .Bottom_Exposed {
			if index+1 >= len(layer_heights) {break}
			index += 1
		} else {
			if index == 0 {break}
			index -= 1
		}
	}
	return u32(first), u32(last), true
}

@(private = "file")
skin_polygon_bbox :: proc(s: polygon.Polygon_Set) -> [4]i64 {
	if len(s.points) == 0 {
		return {1, -1, 1, -1}
	}
	p0 := s.points[0]
	min_x := i64(p0.x)
	max_x := min_x
	min_y := i64(p0.y)
	max_y := min_y
	for p in s.points[1:] {
		px := i64(p.x)
		py := i64(p.y)
		if px < min_x {min_x = px}
		if px > max_x {max_x = px}
		if py < min_y {min_y = py}
		if py > max_y {max_y = py}
	}
	return {min_x, max_x, min_y, max_y}
}

skin_polygon_accumulate :: proc(
	accumulator: ^polygon.Polygon_Set,
	contribution: ^polygon.Polygon_Set,
	provider: polygon.Polygon_Provider,
	fill_rule: polygon.Polygon_Fill_Rule,
	limits: polygon.Polygon_Limits,
	allocator: mem.Allocator,
) -> Skin_Error {
	if len(accumulator.paths) == 0 {
		accumulator^ = contribution^
		contribution^ = {}
		return .None
	}
	merged, provider_error := provider.boolean(
		accumulator^,
		contribution^,
		.Union,
		fill_rule,
		limits,
		allocator,
	)
	polygon.polygon_set_destroy(contribution, allocator)
	if provider_error != .None {return .Provider}
	polygon.polygon_set_destroy(accumulator, allocator)
	accumulator^ = merged
	return .None
}

skin_polygon_clone :: proc(
	source: polygon.Polygon_Set,
	allocator: mem.Allocator,
) -> (polygon.Polygon_Set, bool) {
	result: polygon.Polygon_Set
	result.paths = make([]polygon.Polygon_Path, len(source.paths), allocator)
	result.points = make([]polygon.Polygon_Point, len(source.points), allocator)
	if len(source.paths) > 0 && result.paths == nil ||
	   len(source.points) > 0 && result.points == nil {
		polygon.polygon_set_destroy(&result, allocator)
		return {}, false
	}
	copy(result.paths, source.paths)
	copy(result.points, source.points)
	return result, true
}

skin_surface_input :: proc(
	surfaces: Surface_Result,
	mask_index: u32,
	allocator: mem.Allocator,
) -> (polygon.Polygon_Set, Skin_Error) {
	if u64(mask_index) >= u64(len(surfaces.masks)) {
		return {}, .Invalid_Input
	}
	mask := surfaces.masks[mask_index]
	if mask.path_offset+u64(mask.path_count) > u64(len(surfaces.paths)) ||
	   mask.point_offset+u64(mask.point_count) > u64(len(surfaces.points)) {
		return {}, .Invalid_Input
	}
	result: polygon.Polygon_Set
	result.paths = make(
		[]polygon.Polygon_Path,
		int(mask.path_count),
		allocator,
	)
	result.points = make(
		[]polygon.Polygon_Point,
		int(mask.point_count),
		allocator,
	)
	if result.paths == nil || result.points == nil {
		polygon.polygon_set_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	point_write: u64
	path_start := int(mask.path_offset)
	path_end := path_start+int(mask.path_count)
	for path, local_path_index in surfaces.paths[path_start:path_end] {
		if point_write+u64(path.point_count) > u64(len(result.points)) {
			polygon.polygon_set_destroy(&result, allocator)
			return {}, .Arithmetic
		}
		result.paths[local_path_index] = {
			offset = point_write,
			count = u64(path.point_count),
		}
		source_start := int(path.point_offset)
		source_end := source_start+int(path.point_count)
		copy(
			result.points[int(point_write):int(point_write)+
				int(path.point_count)],
			surfaces.points[source_start:source_end],
		)
		point_write += u64(path.point_count)
	}
	if point_write != u64(len(result.points)) {
		polygon.polygon_set_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
}

skin_filter_output_sources :: proc(
	result: ^[dynamic]u32,
	output: polygon.Polygon_Set,
	bottom_sources, top_sources: []u32,
	surfaces: Surface_Result,
	provider: polygon.Polygon_Provider,
	fill_rule: polygon.Polygon_Fill_Rule,
	limits: Skin_Limits,
	total_source_count: ^u64,
	allocator: mem.Allocator,
) -> Skin_Error {
	bottom_index := 0
	top_index := 0
	for bottom_index < len(bottom_sources) ||
	    top_index < len(top_sources) {
		source_index: u32
		if top_index >= len(top_sources) ||
		   bottom_index < len(bottom_sources) &&
		   	bottom_sources[bottom_index] < top_sources[top_index] {
			source_index = bottom_sources[bottom_index]
			bottom_index += 1
		} else if bottom_index >= len(bottom_sources) ||
		          top_sources[top_index] <
		          	bottom_sources[bottom_index] {
			source_index = top_sources[top_index]
			top_index += 1
		} else {
			source_index = bottom_sources[bottom_index]
			bottom_index += 1
			top_index += 1
		}
		source, source_error := skin_surface_input(
			surfaces,
			source_index,
			allocator,
		)
		if source_error != .None {return source_error}
		overlap, provider_error := provider.boolean(
			output,
			source,
			.Intersection,
			fill_rule,
			limits.polygon,
			allocator,
		)
		polygon.polygon_set_destroy(&source, allocator)
		if provider_error != .None {return .Provider}
		contributes := len(overlap.paths) > 0
		polygon.polygon_set_destroy(&overlap, allocator)
		if !contributes {continue}
		if total_source_count^ >= limits.max_source_references {
			return .Source_Reference_Limit
		}
		append(result, source_index)
		total_source_count^ += 1
	}
	return .None
}

skin_config_valid :: proc(config: Skin_Config) -> bool {
	fill_valid := config.fill_rule == .Even_Odd ||
		config.fill_rule == .Non_Zero ||
		config.fill_rule == .Positive
	return fill_valid &&
		profiles.skin_target_valid(config.top) &&
		profiles.skin_target_valid(config.bottom)
}

skin_result_destroy :: proc(
	result: ^Skin_Result,
	allocator := context.allocator,
) {
	delete(result.layers, allocator)
	delete(result.masks, allocator)
	delete(result.paths, allocator)
	delete(result.points, allocator)
	delete(result.source_references, allocator)
	result^ = {}
}
