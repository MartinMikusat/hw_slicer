package features

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import profiles "../profiles"

Unified_Path_Source_Layer :: struct {
	source_offset: u64,
	source_count:  u32,
	point_offset:  u64,
	point_count:   u32,
}

Unified_Path_Source_Result :: struct {
	inner_perimeters_first: bool,
	nominal_line_width:     contracts.Micrometres,
	layers:                 []Unified_Path_Source_Layer,
	sources:                []Unified_Path_Source,
	points:                 []polygon.Polygon_Point,
	line_widths:            []contracts.Micrometres,
}

Unified_Path_Source_Limits :: struct {
	max_sources: u64,
	max_points:  u64,
}

DEFAULT_UNIFIED_PATH_SOURCE_LIMITS :: Unified_Path_Source_Limits{
	max_sources = 1_000_000_000,
	max_points = 4_000_000_000,
}

Unified_Path_Source_Error :: enum u8 {
	None,
	Invalid_Config,
	Invalid_Input,
	Source_Limit,
	Point_Limit,
	Allocation_Failed,
	Arithmetic,
}

Wall_Sequence :: enum u8 {
	Inner_Outer,
	Outer_Inner,
	Inner_Outer_Inner,
}

unified_path_sources_build :: proc(
	layer_ids: []contracts.Stable_ID,
	perimeters: Perimeter_Result,
	bridges: Bridge_Path_Result,
	gaps: Gap_Centerline_Result,
	solids: Solid_Path_Result,
	infill: Infill_Result,
	supports: Support_Path_Result,
	process: profiles.Resolved_Process_Profile,
	inner_perimeters_first: bool,
	limits := DEFAULT_UNIFIED_PATH_SOURCE_LIMITS,
	allocator := context.allocator,
	wall_sequence: Wall_Sequence = .Inner_Outer,
	skip_final_validate := false,
) -> (Unified_Path_Source_Result, Unified_Path_Source_Error) {
	layer_count := len(layer_ids)
	if i64(process.source.nominal_line_width) <= 0 ||
	   i64(process.source.nominal_line_width) >
		geometry.MAX_PLANAR_COORDINATE_UM {
		return {}, .Invalid_Config
	}
	if len(perimeters.layers) != layer_count ||
	   len(bridges.layers) != layer_count ||
	   len(gaps.layers) != layer_count ||
	   len(solids.layers) != layer_count ||
	   len(infill.layers) != layer_count ||
	   len(supports.layers) != layer_count ||
	   !unified_path_source_ranges_valid(
			perimeters,
			bridges,
			gaps,
			solids,
			infill,
			supports,
	   ) {
		return {}, .Invalid_Input
	}
	source_count_128 :=
		u128(len(perimeters.paths))+
		u128(len(bridges.paths))+
		u128(len(gaps.paths))+
		u128(len(solids.paths))+
		u128(len(infill.segments))+
		u128(len(supports.paths))
	if source_count_128 > u128(limits.max_sources) {
		return {}, .Source_Limit
	}
	point_count_128 :=
		u128(len(perimeters.points))+
		u128(len(bridges.paths))*2+
		u128(len(gaps.vertices))+
		u128(len(solids.paths))*2+
		u128(len(infill.segments))*2+
		u128(len(supports.paths))*2
	if point_count_128 > u128(limits.max_points) {
		return {}, .Point_Limit
	}
	if source_count_128 > u128(max(int)) ||
	   point_count_128 > u128(max(int)) ||
	   source_count_128 > u128(max(u32)) {
		return {}, .Arithmetic
	}
	source_count := int(source_count_128)
	point_count := int(point_count_128)
	result := Unified_Path_Source_Result{
		inner_perimeters_first = inner_perimeters_first,
		nominal_line_width = process.source.nominal_line_width,
	}
	result.layers = make(
		[]Unified_Path_Source_Layer,
		layer_count,
		allocator,
	)
	result.sources = features_make_non_zeroed(
		[]Unified_Path_Source,
		source_count,
		allocator,
	)
	result.points = features_make_non_zeroed(
		[]polygon.Polygon_Point,
		point_count,
		allocator,
	)
	result.line_widths = features_make_non_zeroed(
		[]contracts.Micrometres,
		point_count,
		allocator,
	)
	if layer_count > 0 && result.layers == nil ||
	   source_count > 0 && result.sources == nil ||
	   point_count > 0 &&
		(result.points == nil || result.line_widths == nil) {
		unified_path_source_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	Layer_Budget :: struct {
		src_base:   int,
		src_cap:    int,
		pt_base:    int,
		pt_cap:     int,
		src_actual: int,
		pt_actual:  int,
		err:        Unified_Path_Source_Error,
	}
	budgets := make([]Layer_Budget, layer_count, allocator)
	defer delete(budgets, allocator)
	if layer_count > 0 && budgets == nil {
		unified_path_source_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	src_cur := 0
	pt_cur := 0
	for li in 0..<layer_count {
		pl := perimeters.layers[li]
		bl := bridges.layers[li]
		gl := gaps.layers[li]
		sl := solids.layers[li]
		il := infill.layers[li]
		supl := supports.layers[li]

		l_src := int(pl.path_count) + int(bl.path_count) + int(gl.path_count) +
			int(sl.path_count) + int(il.segment_count) + int(supl.path_count)
		layer_points := 2 * (u128(bl.path_count) + u128(sl.path_count) +
			u128(il.segment_count) + u128(supl.path_count))
		for pi in int(pl.path_offset)..<int(pl.path_offset)+int(pl.path_count) {
			layer_points += u128(perimeters.paths[pi].point_count)
		}
		for gi in int(gl.path_offset)..<int(gl.path_offset)+int(gl.path_count) {
			layer_points += u128(gaps.paths[gi].vertex_count)
		}
		if l_src > source_count-src_cur || layer_points > u128(point_count-pt_cur) {
			unified_path_source_result_destroy(&result, allocator)
			return {}, .Invalid_Input
		}
		l_pt := int(layer_points)
		budgets[li] = {
			src_base = src_cur,
			src_cap  = l_src,
			pt_base  = pt_cur,
			pt_cap   = l_pt,
		}
		src_cur += l_src
		pt_cur += l_pt
	}

	Unified_Source_Par_Ctx :: struct {
		layer_ids:              []contracts.Stable_ID,
		perimeters:             Perimeter_Result,
		bridges:                Bridge_Path_Result,
		gaps:                   Gap_Centerline_Result,
		solids:                 Solid_Path_Result,
		infill:                 Infill_Result,
		supports:               Support_Path_Result,
		process:                profiles.Resolved_Process_Profile,
		inner_perimeters_first: bool,
		wall_sequence:          Wall_Sequence,
		result:                 ^Unified_Path_Source_Result,
		budgets:                []Layer_Budget,
	}
	uctx := Unified_Source_Par_Ctx{
		layer_ids              = layer_ids,
		perimeters             = perimeters,
		bridges                = bridges,
		gaps                   = gaps,
		solids                 = solids,
		infill                 = infill,
		supports               = supports,
		process                = process,
		inner_perimeters_first = inner_perimeters_first,
		wall_sequence          = wall_sequence,
		result                 = &result,
		budgets                = budgets,
	}

	parallel_for(layer_count, &uctx, proc(c: ^Unified_Source_Par_Ctx, layer_index: int) {
		layer_id := c.layer_ids[layer_index]
		b := &c.budgets[layer_index]
		if layer_id == contracts.INVALID_STABLE_ID {
			b.err = .Invalid_Input
			return
		}
		src_end_cap := b.src_base + b.src_cap
		pt_end_cap := b.pt_base + b.pt_cap
		source_write := b.src_base
		point_write := b.pt_base
		source_order: u64

		append_local :: proc(
			result: ^Unified_Path_Source_Result,
			source_write, point_write: ^int,
			src_limit, pt_limit: int,
			stable_id, layer_id: contracts.Stable_ID,
			layer_index: u32,
			role: profiles.Printable_Role,
			source_kind: Unified_Path_Source_Kind,
			source_index: u32,
			source_order: u64,
			closed: bool,
			points: []polygon.Polygon_Point,
			widths: []contracts.Micrometres,
			uniform_width: contracts.Micrometres,
		) -> bool {
			if source_write^ >= src_limit ||
			   point_write^ > pt_limit ||
			   len(points) > pt_limit - point_write^ ||
			   widths != nil && len(widths) != len(points) ||
			   widths == nil && i64(uniform_width) <= 0 {
				return false
			}
			point_start := point_write^
			copy(result.points[point_start:point_start+len(points)], points)
			if widths == nil {
				for &width in result.line_widths[point_start:point_start+len(points)] {
					width = uniform_width
				}
			} else {
				copy(result.line_widths[point_start:point_start+len(points)], widths)
			}
			point_write^ += len(points)
			result.sources[source_write^] = {
				stable_id   = stable_id,
				layer_id    = layer_id,
				layer_index = layer_index,
				role        = role,
				source_kind = source_kind,
				source_index = source_index,
				source_order = source_order,
				closed      = closed,
				points      = result.points[point_start:point_write^],
				line_widths = result.line_widths[point_start:point_write^],
			}
			source_write^ += 1
			return true
		}

		perimeter_layer := c.perimeters.layers[layer_index]
		group_cursor := int(perimeter_layer.group_offset)
		group_end := group_cursor + int(perimeter_layer.group_count)
		for group_cursor < group_end {
			region_group_end := group_cursor + int(c.perimeters.config.count)
			if region_group_end > group_end {
				b.err = .Invalid_Input
				return
			}
			eff_seq := c.wall_sequence
			if !c.inner_perimeters_first && eff_seq == .Inner_Outer {
				eff_seq = .Outer_Inner
			}
			n_walls := int(c.perimeters.config.count)
			for local_group_index in 0..<n_walls {
				group_index := group_cursor + local_group_index
				switch eff_seq {
				case .Inner_Outer:
					group_index = region_group_end - 1 - local_group_index
				case .Outer_Inner:
					group_index = group_cursor + local_group_index
				case .Inner_Outer_Inner:
					if n_walls >= 2 {
						if local_group_index == 0 {
							group_index = group_cursor + 1
						} else if local_group_index == 1 {
							group_index = group_cursor + 0
						} else {
							group_index = group_cursor + local_group_index
						}
					}
				}
				group := c.perimeters.groups[group_index]
				if group.layer_index != u32(layer_index) {
					b.err = .Invalid_Input
					return
				}
				layer_path_end := perimeter_layer.path_offset + u64(perimeter_layer.path_count)
				if group.path_offset < perimeter_layer.path_offset ||
				   group.path_offset > layer_path_end ||
				   u64(group.path_count) > layer_path_end - group.path_offset {
					b.err = .Invalid_Input
					return
				}
				path_start := int(group.path_offset)
				path_end := path_start + int(group.path_count)
				perim_lw := perimeter_line_width_for(c.perimeters.config, u32(layer_index), group.perimeter_index)
				for path_index in path_start..<path_end {
					path := c.perimeters.paths[path_index]
					if path.layer_index != u32(layer_index) ||
					   path.region_id != group.region_id ||
					   path.region_index != group.region_index ||
					   path.perimeter_index != group.perimeter_index ||
					   path.point_offset + u64(path.point_count) > u64(len(c.perimeters.points)) {
						b.err = .Invalid_Input
						return
					}
					points_start := int(path.point_offset)
					points_end := points_start + int(path.point_count)
					if !append_local(
						c.result, &source_write, &point_write, src_end_cap, pt_end_cap,
						path.stable_id, layer_id, u32(layer_index),
						.Perimeter, .Perimeter, u32(path_index), source_order, true,
						c.perimeters.points[points_start:points_end], nil, perim_lw,
					) {
						b.err = .Invalid_Input
						return
					}
					c.result.sources[source_write-1].perimeter_index = path.perimeter_index
					source_order += 1
				}
			}
			group_cursor = region_group_end
		}

		bridge_layer := c.bridges.layers[layer_index]
		path_start := int(bridge_layer.path_offset)
		path_end := path_start + int(bridge_layer.path_count)
		source_order = 0
		for path_index in path_start..<path_end {
			path := c.bridges.paths[path_index]
			if path.layer_index != u32(layer_index) || path.role != .Bridge {
				b.err = .Invalid_Input
				return
			}
			points := [2]polygon.Polygon_Point{path.point_a, path.point_b}
			if !append_local(
				c.result, &source_write, &point_write, src_end_cap, pt_end_cap,
				path.stable_id, layer_id, u32(layer_index),
				.Bridge, .Bridge, u32(path_index), source_order, false,
				points[:], nil, path.line_width,
			) {
				b.err = .Invalid_Input
				return
			}
			source_order += 1
		}

		gap_layer := c.gaps.layers[layer_index]
		path_start = int(gap_layer.path_offset)
		path_end = path_start + int(gap_layer.path_count)
		source_order = 0
		for path_index in path_start..<path_end {
			path := c.gaps.paths[path_index]
			if path.layer_index != u32(layer_index) ||
			   path.vertex_offset + u64(path.vertex_count) > u64(len(c.gaps.vertices)) {
				b.err = .Invalid_Input
				return
			}
			vertex_start := int(path.vertex_offset)
			vertex_end := vertex_start + int(path.vertex_count)
			vertices := c.gaps.vertices[vertex_start:vertex_end]
			if len(vertices) < 2 || source_write >= src_end_cap || len(vertices) > pt_end_cap - point_write {
				b.err = .Invalid_Input
				return
			}
			p_start := point_write
			for vertex in vertices {
				if i64(vertex.line_width) <= 0 {
					b.err = .Invalid_Input
					return
				}
				c.result.points[point_write] = vertex.point
				c.result.line_widths[point_write] = vertex.line_width
				point_write += 1
			}
			c.result.sources[source_write] = {
				stable_id    = path.stable_id,
				layer_id     = layer_id,
				layer_index  = path.layer_index,
				role         = path.role,
				source_kind  = .Gap_Centerline,
				source_index = u32(path_index),
				source_order = source_order,
				closed       = false,
				points       = c.result.points[p_start:point_write],
				line_widths  = c.result.line_widths[p_start:point_write],
			}
			source_write += 1
			source_order += 1
		}

		solid_layer := c.solids.layers[layer_index]
		path_start = int(solid_layer.path_offset)
		path_end = path_start + int(solid_layer.path_count)
		source_order = 0
		connect_limit := 2 * i128(i64(c.solids.spacing))
		connect_limit_sq := connect_limit * connect_limit
		chain := make([dynamic]polygon.Polygon_Point, 0, 64, context.temp_allocator)
		for path_index in path_start..<path_end {
			path := c.solids.paths[path_index]
			if path.layer_index != u32(layer_index) || !solid_path_role_is_skin(path.role) {
				b.err = .Invalid_Input
				return
			}
		}
		used := make([]bool, path_end - path_start, context.temp_allocator)
		group_start := path_start
		for group_start < path_end {
			g0 := c.solids.paths[group_start]
			group_end := group_start + 1
			for group_end < path_end {
				q := c.solids.paths[group_end]
				if q.overlap_mask_index != g0.overlap_mask_index || q.role != g0.role ||
				   q.angle != g0.angle || q.line_width != g0.line_width {break}
				group_end += 1
			}
			for seed in group_start..<group_end {
				if used[seed - path_start] {continue}
				used[seed - path_start] = true
				seed_path := c.solids.paths[seed]
				clear(&chain)
				append(&chain, seed_path.point_a, seed_path.point_b)
				last := seed
				for {
					end := chain[len(chain)-1]
					if last+1 < group_end && !used[last+1-path_start] {
						nxt := c.solids.paths[last+1]
						if nxt.scanline_index == c.solids.paths[last].scanline_index && nxt.point_a == end {
							used[last+1-path_start] = true
							append(&chain, nxt.point_b)
							last += 1
							continue
						}
					}
					next_scanline := c.solids.paths[last].scanline_index + 1
					best := -1
					best_d: u128
					best_a := true
					for k in last+1..<group_end {
						cand := c.solids.paths[k]
						if cand.scanline_index > next_scanline {break}
						if used[k-path_start] || cand.scanline_index != next_scanline {continue}
						da := path_plan_distance_2(end, cand.point_a)
						db := path_plan_distance_2(end, cand.point_b)
						d := min(da, db)
						if i128(d) > connect_limit_sq {continue}
						if !solid_connector_inside(c.solids, cand.overlap_mask_index, end, cand.point_a if da <= db else cand.point_b) {continue}
						if best < 0 || d < best_d {
							best = k
							best_d = d
							best_a = da <= db
						}
					}
					if best < 0 {break}
					used[best - path_start] = true
					cand := c.solids.paths[best]
					if best_a {
						append(&chain, cand.point_a, cand.point_b)
					} else {
						append(&chain, cand.point_b, cand.point_a)
					}
					last = best
				}
				if !append_local(
					c.result, &source_write, &point_write, src_end_cap, pt_end_cap,
					seed_path.stable_id, layer_id, u32(layer_index),
					seed_path.role, .Solid, u32(seed), source_order, false,
					chain[:], nil, seed_path.line_width,
				) {
					b.err = .Invalid_Input
					return
				}
				source_order += 1
			}
			group_start = group_end
		}

		infill_layer := c.infill.layers[layer_index]
		segment_start := int(infill_layer.segment_offset)
		segment_end := segment_start + int(infill_layer.segment_count)
		source_order = 0
		for segment_index in segment_start..<segment_end {
			segment := c.infill.segments[segment_index]
			if segment.layer_index != u32(layer_index) {
				b.err = .Invalid_Input
				return
			}
			points := [2]polygon.Polygon_Point{segment.point_a, segment.point_b}
			if !append_local(
				c.result, &source_write, &point_write, src_end_cap, pt_end_cap,
				segment.stable_id, layer_id, u32(layer_index),
				.Sparse_Infill, .Sparse_Infill, u32(segment_index), source_order, false,
				points[:], nil, c.process.source.nominal_line_width,
			) {
				b.err = .Invalid_Input
				return
			}
			source_order += 1
		}

		support_layer := c.supports.layers[layer_index]
		path_start = int(support_layer.path_offset)
		path_end = path_start + int(support_layer.path_count)
		source_order = 0
		for path_index in path_start..<path_end {
			path := c.supports.paths[path_index]
			if path.layer_index != u32(layer_index) ||
			   path.role != .Support && path.role != .Support_Interface {
				b.err = .Invalid_Input
				return
			}
			points := [2]polygon.Polygon_Point{path.point_a, path.point_b}
			if !append_local(
				c.result, &source_write, &point_write, src_end_cap, pt_end_cap,
				path.stable_id, layer_id, u32(layer_index),
				path.role, .Support, u32(path_index), source_order, false,
				points[:], nil, path.line_width,
			) {
				b.err = .Invalid_Input
				return
			}
			source_order += 1
		}

		b.src_actual = source_write - b.src_base
		b.pt_actual = point_write - b.pt_base
	})

	source_write := 0
	point_write := 0
	need_pt_compact := false
	for b in budgets {
		if b.err != .None {
			unified_path_source_result_destroy(&result, allocator)
			return {}, b.err
		}
		if b.pt_actual != b.pt_cap {need_pt_compact = true}
	}
	for b, layer_index in budgets {
		if b.src_actual > int(max(u32)) || b.pt_actual > int(max(u32)) {
			unified_path_source_result_destroy(&result, allocator)
			return {}, .Arithmetic
		}
		if b.src_actual > 0 && source_write != b.src_base {
			copy(result.sources[source_write:source_write+b.src_actual], result.sources[b.src_base:b.src_base+b.src_actual])
		}
		if need_pt_compact && b.pt_actual > 0 && point_write != b.pt_base {
			copy(result.points[point_write:point_write+b.pt_actual], result.points[b.pt_base:b.pt_base+b.pt_actual])
			copy(result.line_widths[point_write:point_write+b.pt_actual], result.line_widths[b.pt_base:b.pt_base+b.pt_actual])
			pt_cursor := point_write
			for si in source_write..<source_write+b.src_actual {
				n := len(result.sources[si].points)
				result.sources[si].points = result.points[pt_cursor:pt_cursor+n]
				result.sources[si].line_widths = result.line_widths[pt_cursor:pt_cursor+n]
				pt_cursor += n
			}
		}
		result.layers[layer_index] = {
			source_offset = u64(source_write),
			source_count  = u32(b.src_actual),
			point_offset  = u64(point_write),
			point_count   = u32(b.pt_actual),
		}
		source_write += b.src_actual
		point_write += b.pt_actual
	}
	if source_write > len(result.sources) ||
	   point_write > len(result.points) {
		unified_path_source_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	// Joined skin lines need fewer sources than the per-path upper bound.
	result.sources = result.sources[:source_write]
	result.points = result.points[:point_write]
	result.line_widths = result.line_widths[:point_write]
	if !skip_final_validate {
		for source in result.sources {
			_, source_ok := unified_path_source_validate(source, layer_ids)
			if !source_ok {
				unified_path_source_result_destroy(&result, allocator)
				return {}, .Invalid_Input
			}
		}
	}
	return result, .None
}



unified_path_source_ranges_valid :: proc(
	perimeters: Perimeter_Result,
	bridges: Bridge_Path_Result,
	gaps: Gap_Centerline_Result,
	solids: Solid_Path_Result,
	infill: Infill_Result,
	supports: Support_Path_Result,
) -> bool {
	if perimeters.config.count == 0 {return false}
	expected_group_offset: u64
	expected_perimeter_path_offset: u64
	expected_bridge_path_offset: u64
	expected_gap_path_offset: u64
	expected_solid_path_offset: u64
	expected_infill_offset: u64
	expected_support_path_offset: u64
	for _, layer_index in perimeters.layers {
		perimeter_layer := perimeters.layers[layer_index]
		bridge_layer := bridges.layers[layer_index]
		gap_layer := gaps.layers[layer_index]
		solid_layer := solids.layers[layer_index]
		infill_layer := infill.layers[layer_index]
		support_layer := supports.layers[layer_index]
		if perimeter_layer.group_offset != expected_group_offset ||
		   perimeter_layer.path_offset !=
			expected_perimeter_path_offset ||
		   bridge_layer.path_offset != expected_bridge_path_offset ||
		   gap_layer.path_offset != expected_gap_path_offset ||
		   solid_layer.path_offset != expected_solid_path_offset ||
		   infill_layer.segment_offset != expected_infill_offset ||
		   support_layer.path_offset != expected_support_path_offset ||
		   perimeter_layer.group_offset+
			u64(perimeter_layer.group_count) >
			u64(len(perimeters.groups)) ||
		   perimeter_layer.path_offset+
			u64(perimeter_layer.path_count) >
			u64(len(perimeters.paths)) ||
		   bridge_layer.path_offset+u64(bridge_layer.path_count) >
			u64(len(bridges.paths)) ||
		   gap_layer.path_offset+u64(gap_layer.path_count) >
			u64(len(gaps.paths)) ||
		   solid_layer.path_offset+u64(solid_layer.path_count) >
			u64(len(solids.paths)) ||
		   infill_layer.segment_offset+
			u64(infill_layer.segment_count) >
			u64(len(infill.segments)) ||
		   support_layer.path_offset+u64(support_layer.path_count) >
			u64(len(supports.paths)) {
			return false
		}
		expected_group_offset += u64(perimeter_layer.group_count)
		expected_perimeter_path_offset +=
			u64(perimeter_layer.path_count)
		expected_bridge_path_offset += u64(bridge_layer.path_count)
		expected_gap_path_offset += u64(gap_layer.path_count)
		expected_solid_path_offset += u64(solid_layer.path_count)
		expected_infill_offset += u64(infill_layer.segment_count)
		expected_support_path_offset += u64(support_layer.path_count)
	}
	return expected_group_offset == u64(len(perimeters.groups)) &&
		expected_perimeter_path_offset == u64(len(perimeters.paths)) &&
		expected_bridge_path_offset == u64(len(bridges.paths)) &&
		expected_gap_path_offset == u64(len(gaps.paths)) &&
		expected_solid_path_offset == u64(len(solids.paths)) &&
		expected_infill_offset == u64(len(infill.segments)) &&
		expected_support_path_offset == u64(len(supports.paths))
}

unified_path_source_result_destroy :: proc(
	result: ^Unified_Path_Source_Result,
	allocator := context.allocator,
) {
	delete(result.layers, allocator)
	delete(result.sources, allocator)
	delete(result.points, allocator)
	delete(result.line_widths, allocator)
	result^ = {}
}

// A skin connector from p to q prints inside its mask when it crosses no edge of the connector
// boundary and its midpoint lies inside that boundary. Without a boundary the scanlines stay
// separate.
@(private = "file")
solid_connector_inside :: proc(solids: Solid_Path_Result, mask_index: u32, p, q: polygon.Polygon_Point) -> bool {
	if int(mask_index) >= len(solids.connector_boundaries) {return false}
	boundary := solids.connector_boundaries[mask_index]
	if len(boundary.paths) == 0 {return false}
	ENDPOINT_TOLERANCE_UM :: 5.0
	min_x, max_x := min(i64(p.x), i64(q.x)), max(i64(p.x), i64(q.x))
	min_y, max_y := min(i64(p.y), i64(q.y)), max(i64(p.y), i64(q.y))
	orient :: proc(a, b, c: polygon.Polygon_Point) -> i128 {
		return (i128(i64(b.x))-i128(i64(a.x)))*(i128(i64(c.y))-i128(i64(a.y))) -
		       (i128(i64(b.y))-i128(i64(a.y)))*(i128(i64(c.x))-i128(i64(a.x)))
	}
	sgn :: proc(v: i128) -> int {return 1 if v > 0 else (-1 if v < 0 else 0)}
	chord_length := f64(path_plan_distance_2(p, q))
	for path in boundary.paths {
		ring := boundary.points[path.offset:path.offset+path.count]
		for a, ai in ring {
			b := ring[(ai+1) % len(ring)]
			if max(i64(a.x), i64(b.x)) < min_x || min(i64(a.x), i64(b.x)) > max_x ||
			   max(i64(a.y), i64(b.y)) < min_y || min(i64(a.y), i64(b.y)) > max_y {continue}
			o1 := orient(p, q, a)
			o2 := orient(p, q, b)
			o3 := orient(a, b, p)
			o4 := orient(a, b, q)
			if sgn(o1)*sgn(o2) > 0 || sgn(o3)*sgn(o4) >= 0 || (o1 == 0 && o2 == 0) {continue}
			t := f64(o3) / (f64(o3) - f64(o4))
			along := t * t * chord_length
			tail := (1 - t) * (1 - t) * chord_length
			if along < ENDPOINT_TOLERANCE_UM*ENDPOINT_TOLERANCE_UM ||
			   tail < ENDPOINT_TOLERANCE_UM*ENDPOINT_TOLERANCE_UM {continue}
			return false
		}
	}
	return bridge_polygon_contains_twice(boundary, i64(p.x)+i64(q.x), i64(p.y)+i64(q.y))
}
