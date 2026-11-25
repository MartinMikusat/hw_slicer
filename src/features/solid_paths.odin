package features

import "core:mem"
import "core:slice"

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import profiles "../profiles"

Solid_Path_Layer :: struct {
	path_offset: u64,
	path_count:  u32,
	hit_offset:  u64,
	hit_count:   u32,
}

Solid_Path :: struct {
	stable_id:          contracts.Stable_ID,
	path_set_id:        contracts.Stable_ID,
	overlap_mask_id:    contracts.Stable_ID,
	overlap_mask_index: u32,
	layer_index:        u32,
	role:               profiles.Printable_Role,
	angle:              profiles.Angle_Millidegrees,
	direction_x:        i64,
	direction_y:        i64,
	mask_path_index:    u64,
	scanline_index:     u64,
	line_coordinate_scaled: i128,
	line_width:         contracts.Micrometres,
	point_a:            polygon.Polygon_Point,
	point_b:            polygon.Polygon_Point,
	hit_offset:         u64,
}

Solid_Path_Result :: struct {
	spacing:          contracts.Micrometres,
	line_width:       contracts.Micrometres,
	boundary_inset:   contracts.Micrometres,
	base_angle:       profiles.Angle_Millidegrees,
	angle_step:       profiles.Angle_Millidegrees,
	direction_scale:  i64,
	layers:           []Solid_Path_Layer,
	paths:            []Solid_Path,
	hits:             []Bridge_Path_Hit,
	connector_boundaries: []polygon.Polygon_Set,
	scanline_count:   u64,
	skin_mask_count:  u64,
	collapsed_count:  u64,
}

Solid_Path_Limits :: struct {
	max_scanlines: u64,
	max_paths:     u64,
	polygon:       polygon.Polygon_Limits,
}

DEFAULT_SOLID_PATH_LIMITS :: Solid_Path_Limits{
	max_scanlines = 1_000_000_000,
	max_paths = 1_000_000_000,
	polygon = polygon.DEFAULT_POLYGON_LIMITS,
}

Solid_Path_Error :: enum u8 {
	None,
	Invalid_Config,
	Invalid_Input,
	Scanline_Limit,
	Path_Limit,
	Provider,
	Odd_Intersection_Count,
	Allocation_Failed,
	Arithmetic,
}

Solid_Path_Options :: struct {
	top_surface_line_width:    contracts.Micrometres, // 0 = inherit nominal
	internal_solid_line_width: contracts.Micrometres, // 0 = inherit nominal
	first_layer_line_width:    contracts.Micrometres, // 0 = inherit nominal
	top_concentric:            bool,
	bottom_concentric:         bool,
}

solid_paths_generate :: proc(
	overlap: Role_Overlap_Result,
	process: profiles.Resolved_Process_Profile,
	provider: polygon.Polygon_Provider,
	limits := DEFAULT_SOLID_PATH_LIMITS,
	allocator := context.allocator,
	options := Solid_Path_Options{},
) -> (Solid_Path_Result, Solid_Path_Error) {
	line_width := process.source.nominal_line_width
	spacing := process.source.solid_infill_spacing
	boundary_inset, inset_ok :=
		support_path_boundary_inset(line_width)
	if process.source.role_overlap != .Subtract_Higher_Priority ||
	   overlap.policy != process.source.role_overlap ||
	   i64(line_width) <= 0 ||
	   i64(spacing) <= 0 ||
	   i64(spacing) > geometry.MAX_PLANAR_COORDINATE_UM ||
	   !inset_ok ||
	   !profiles.angle_valid(process.source.solid_infill_base_angle) ||
	   !profiles.angle_valid(process.source.solid_infill_angle_step) ||
	   provider.offset == nil {
		return {}, .Invalid_Config
	}
	if !solid_path_overlap_valid(overlap) {
		return {}, .Invalid_Input
	}

	boundaries := make(
		[]polygon.Polygon_Set,
		len(overlap.masks),
		allocator,
	)
	if len(overlap.masks) > 0 && boundaries == nil {
		return {}, .Allocation_Failed
	}
	// Skin connectors may leave the scan boundary by up to a quarter line width.
	connector_boundaries := make([]polygon.Polygon_Set, len(overlap.masks), allocator)
	connector_inset := contracts.Micrometres(max(i64(0), i64(boundary_inset) - i64(line_width)/4))
	connectors_owned := false
	defer if !connectors_owned {
		for &boundary in connector_boundaries {
			polygon.polygon_set_destroy(&boundary, allocator)
		}
		delete(connector_boundaries, allocator)
	}
	mask_errors := make([]Solid_Path_Error, len(overlap.masks), allocator)
	defer delete(mask_errors, allocator)

	// Deduplicate identical skin masks across layers (e.g. 5–8 layer top/bottom solid stacks) so
	// both boundary and connector inset offsets run once per unique mask shape.
	mask_count := len(overlap.masks)
	mask_inputs := make([]polygon.Polygon_Set, mask_count, allocator)
	canon_of := make([]int, mask_count, allocator)
	unique_masks := make([dynamic]int, 0, mask_count, allocator)
	defer {
		for &boundary, bi in boundaries {
			if canon_of[bi] != bi {continue}
			polygon.polygon_set_destroy(&boundary, allocator)
		}
		delete(boundaries, allocator)
		for &inp in mask_inputs {polygon.polygon_set_destroy(&inp, allocator)}
		delete(mask_inputs, allocator)
		delete(canon_of, allocator)
		delete(unique_masks)
	}
	if mask_count > 0 {
		cap_pow2 := 16
		for cap_pow2 < mask_count * 2 {cap_pow2 <<= 1}
		ht_mask := u64(cap_pow2 - 1)
		ht := make([]int, cap_pow2, allocator)
		defer delete(ht, allocator)
		for mi in 0..<mask_count {
			canon_of[mi] = -1
			mask := overlap.masks[mi]
			if !solid_path_role_is_skin(mask.role) || mask.path_count == 0 {continue}
			inp, inp_err := role_overlap_mask_input(overlap, u32(mi), allocator)
			if inp_err != .None {
				return {}, solid_path_overlap_error(inp_err)
			}
			mask_inputs[mi] = inp
			h := features_polygon_set_hash64(inp)
			slot := h & ht_mask
			found := -1
			for {
				entry := ht[slot]
				if entry == 0 {break}
				cand := entry - 1
				if features_polygon_sets_equal(mask_inputs[cand], inp) {
					found = cand
					break
				}
				slot = (slot + 1) & ht_mask
			}
			if found >= 0 {
				canon_of[mi] = found
			} else {
				ht[slot] = mi + 1
				canon_of[mi] = mi
				append(&unique_masks, mi)
			}
		}
	}

	Solid_Par_Ctx :: struct {
		mask_inputs:          []polygon.Polygon_Set,
		unique_masks:         []int,
		boundaries:           []polygon.Polygon_Set,
		connector_boundaries: []polygon.Polygon_Set,
		mask_errors:          []Solid_Path_Error,
		boundary_inset:       contracts.Micrometres,
		connector_inset:      contracts.Micrometres,
		provider:             polygon.Polygon_Provider,
		limits:               Solid_Path_Limits,
		allocator:            mem.Allocator,
	}
	spctx := Solid_Par_Ctx{
		mask_inputs          = mask_inputs,
		unique_masks         = unique_masks[:],
		boundaries           = boundaries,
		connector_boundaries = connector_boundaries,
		mask_errors          = mask_errors,
		boundary_inset       = boundary_inset,
		connector_inset      = connector_inset,
		provider             = provider,
		limits               = limits,
		allocator            = allocator,
	}
	parallel_for(len(unique_masks), &spctx, proc(c: ^Solid_Par_Ctx, ui: int) {
		mask_index := c.unique_masks[ui]
		input := c.mask_inputs[mask_index]
		provider_error: polygon.Polygon_Error
		c.boundaries[mask_index], provider_error = c.provider.offset(
			input,
			-contracts.Micrometres(i64(c.boundary_inset)),
			.Miter,
			2,
			0,
			c.limits.polygon,
			c.allocator,
		)
		if provider_error == .None && len(c.boundaries[mask_index].paths) > 0 {
			c.connector_boundaries[mask_index], provider_error = c.provider.offset(
				input,
				-contracts.Micrometres(i64(c.connector_inset)),
				.Miter,
				2,
				0,
				c.limits.polygon,
				c.allocator,
			)
		}
		if provider_error != .None {
			c.mask_errors[mask_index] = .Provider
		}
	})
	for ui in unique_masks {
		if mask_errors[ui] != .None {return {}, mask_errors[ui]}
	}
	for mi in 0..<mask_count {
		src := canon_of[mi]
		if src < 0 || src == mi {continue}
		if len(boundaries[src].paths) > 0 {
			// Share read-only local `boundaries` slice header (only canonical entries are destroyed).
			boundaries[mi] = boundaries[src]
			ok2: bool
			connector_boundaries[mi], ok2 = skin_polygon_clone(connector_boundaries[src], allocator)
			if !ok2 {return {}, .Allocation_Failed}
		}
	}

	maximum_boundary_points := 0
	skin_mask_count: u64
	collapsed_count: u64
	for mask, mask_index in overlap.masks {
		if mask_errors[mask_index] != .None {return {}, mask_errors[mask_index]}
		if !solid_path_role_is_skin(mask.role) {continue}
		skin_mask_count += 1
		if mask.path_count == 0 || len(boundaries[mask_index].paths) == 0 {
			collapsed_count += 1
			continue
		}
		maximum_boundary_points = max(
			maximum_boundary_points,
			len(boundaries[mask_index].points),
		)
	}
	mask_paths := make([]u64, len(overlap.masks), allocator)
	mask_scanlines := make([]u64, len(overlap.masks), allocator)
	mask_path_offsets := make([]u64, len(overlap.masks), allocator)
	mask_path_bufs := make([][]Solid_Path, len(overlap.masks), allocator)
	mask_hit_bufs := make([][]Bridge_Path_Hit, len(overlap.masks), allocator)
	defer {
		for buf in mask_path_bufs {delete(buf, allocator)}
		for buf in mask_hit_bufs {delete(buf, allocator)}
		delete(mask_path_bufs, allocator)
		delete(mask_hit_bufs, allocator)
		delete(mask_paths, allocator)
		delete(mask_scanlines, allocator)
		delete(mask_path_offsets, allocator)
	}
	for &e in mask_errors {e = .None}

	Solid_Scan_Par_Ctx :: struct {
		overlap:        Role_Overlap_Result,
		boundaries:     []polygon.Polygon_Set,
		process:        profiles.Resolved_Process_Profile,
		provider:       polygon.Polygon_Provider,
		options:        Solid_Path_Options,
		spacing:        contracts.Micrometres,
		line_width:     contracts.Micrometres,
		limits:         Solid_Path_Limits,
		allocator:      mem.Allocator,
		mask_paths:     []u64,
		mask_scanlines: []u64,
		mask_path_bufs: [][]Solid_Path,
		mask_hit_bufs:  [][]Bridge_Path_Hit,
		mask_errors:    []Solid_Path_Error,
	}
	ssctx := Solid_Scan_Par_Ctx{
		overlap        = overlap,
		boundaries     = boundaries,
		process        = process,
		provider       = provider,
		options        = options,
		spacing        = spacing,
		line_width     = line_width,
		limits         = limits,
		allocator      = allocator,
		mask_paths     = mask_paths,
		mask_scanlines = mask_scanlines,
		mask_path_bufs = mask_path_bufs,
		mask_hit_bufs  = mask_hit_bufs,
		mask_errors    = mask_errors,
	}
	parallel_for(len(overlap.masks), &ssctx, proc(c: ^Solid_Scan_Par_Ctx, mask_index: int) {
		mask := c.overlap.masks[mask_index]
		if !solid_path_role_is_skin(mask.role) || len(c.boundaries[mask_index].paths) == 0 {return}
		mask_lw := c.line_width
		if mask.layer_index == 0 && i64(c.options.first_layer_line_width) > 0 {
			mask_lw = c.options.first_layer_line_width
		} else if (mask.role == .Top_Skin || mask.role == .Top_Bottom_Skin) && i64(c.options.top_surface_line_width) > 0 {
			mask_lw = c.options.top_surface_line_width
		} else if mask.role == .Bottom_Skin && i64(c.options.internal_solid_line_width) > 0 {
			mask_lw = c.options.internal_solid_line_width
		}
		mask_spacing := mask_lw if mask_lw != c.line_width else c.spacing
		use_concentric := ((mask.role == .Top_Skin || mask.role == .Top_Bottom_Skin) && c.options.top_concentric) ||
			(mask.role == .Bottom_Skin && c.options.bottom_concentric)
		if use_concentric && c.provider.offset != nil {
			pbuf, hbuf, ws := solid_path_concentric_fill(
				c.boundaries[mask_index], mask_spacing, mask_lw,
				mask, u32(mask_index), c.provider, c.limits, c.allocator,
			)
			c.mask_path_bufs[mask_index] = pbuf
			c.mask_hit_bufs[mask_index] = hbuf
			c.mask_paths[mask_index] = u64(len(pbuf))
			c.mask_scanlines[mask_index] = ws
			return
		}
		angle := solid_path_layer_angle(c.process.source.solid_infill_base_angle, c.process.source.solid_infill_angle_step, mask.layer_index)
		dx, dy, dir_ok := bridge_direction_vector(angle)
		if !dir_ok {
			c.mask_errors[mask_index] = .Invalid_Config
			return
		}
		pbuf, hbuf, ws, serr := solid_path_scan_boundary_sweep(
			c.boundaries[mask_index], angle, dx, dy, mask_spacing, mask_lw,
			mask, u32(mask_index), c.limits, c.allocator,
		)
		if serr != .None {
			delete(pbuf, c.allocator)
			delete(hbuf, c.allocator)
			c.mask_errors[mask_index] = serr
			return
		}
		c.mask_path_bufs[mask_index] = pbuf
		c.mask_hit_bufs[mask_index] = hbuf
		c.mask_paths[mask_index] = u64(len(pbuf))
		c.mask_scanlines[mask_index] = ws
	})

	path_count: u64
	scanline_count: u64
	for mask_index in 0..<len(overlap.masks) {
		if mask_errors[mask_index] != .None {return {}, mask_errors[mask_index]}
		wp := mask_paths[mask_index]
		ws := mask_scanlines[mask_index]
		if path_count > limits.max_paths || wp > limits.max_paths - path_count {
			return {}, .Path_Limit
		}
		if scanline_count > limits.max_scanlines || ws > limits.max_scanlines - scanline_count {
			return {}, .Scanline_Limit
		}
		mask_path_offsets[mask_index] = path_count
		path_count += wp
		scanline_count += ws
	}
	if path_count > u64(max(int)) || path_count > u64(max(int))/2 {
		return {}, .Arithmetic
	}

	result := Solid_Path_Result{
		spacing = spacing,
		line_width = line_width,
		boundary_inset = boundary_inset,
		base_angle = process.source.solid_infill_base_angle,
		angle_step = process.source.solid_infill_angle_step,
		direction_scale = BRIDGE_DIRECTION_SCALE,
		scanline_count = scanline_count,
		skin_mask_count = skin_mask_count,
		collapsed_count = collapsed_count,
	}
	result.layers = make([]Solid_Path_Layer, len(overlap.layers), allocator)
	result.paths = make([]Solid_Path, int(path_count), allocator)
	result.hits = make([]Bridge_Path_Hit, int(path_count*2), allocator)
	if len(result.layers) > 0 && result.layers == nil ||
	   path_count > 0 && (result.paths == nil || result.hits == nil) {
		solid_path_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	for mask_index in 0..<len(overlap.masks) {
		pbuf := mask_path_bufs[mask_index]
		if len(pbuf) == 0 {continue}
		off := int(mask_path_offsets[mask_index])
		copy(result.paths[off:], pbuf)
		for k in 0..<len(pbuf) {
			result.paths[off+k].hit_offset = u64(off+k)*2
		}
		copy(result.hits[off*2:], mask_hit_bufs[mask_index])
	}

	path_write: u64
	mask_cursor := 0
	for overlap_layer, layer_index in overlap.layers {
		layer_path_start := path_write
		mask_end := int(overlap_layer.mask_offset) + int(overlap_layer.mask_count)
		for mask_cursor < mask_end {
			path_write += mask_paths[mask_cursor]
			mask_cursor += 1
		}
		layer_path_count := path_write - layer_path_start
		if layer_path_count > u64(max(u32)) || layer_path_count > u64(max(u32))/2 {
			solid_path_result_destroy(&result, allocator)
			return {}, .Arithmetic
		}
		result.layers[layer_index] = {
			path_offset = layer_path_start,
			path_count  = u32(layer_path_count),
			hit_offset  = layer_path_start*2,
			hit_count   = u32(layer_path_count*2),
		}
	}
	if path_write != path_count ||
	   mask_cursor != len(overlap.masks) {
		solid_path_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	result.connector_boundaries = connector_boundaries
	connectors_owned = true
	return result, .None
}

@(private = "file")
solid_path_scan_boundary_sweep :: proc(
	boundary: polygon.Polygon_Set,
	angle: profiles.Angle_Millidegrees,
	direction_x, direction_y: i64,
	spacing, line_width: contracts.Micrometres,
	mask: Role_Overlap_Mask,
	mask_index: u32,
	limits: Solid_Path_Limits,
	allocator: mem.Allocator,
) -> (
	out_paths: []Solid_Path,
	out_hits: []Bridge_Path_Hit,
	scanline_count: u64,
	error: Solid_Path_Error,
) {
	if len(boundary.points) == 0 {return}
	normal_x := -direction_y
	normal_y := direction_x

	Scan_Edge :: struct {
		a, b:       polygon.Polygon_Point,
		fixed_a:    i128,
		fixed_b:    i128,
		proj_lo:    i128,
		proj_hi:    i128,
		path_index: u32,
		edge_index: u32,
	}
	edges := make([dynamic]Scan_Edge, 0, len(boundary.points), context.temp_allocator)
	minimum := max(i128)
	maximum := min(i128)
	for path, path_index in boundary.paths {
		if path.count < 3 || path.offset+path.count > u64(len(boundary.points)) {
			error = .Invalid_Input
			return
		}
		start := int(path.offset)
		cnt := int(path.count)
		for edge_index in 0..<cnt {
			a := boundary.points[start+edge_index]
			b := boundary.points[start+(edge_index+1)%cnt]
			fa := bridge_path_dot(a, normal_x, normal_y)
			fb := bridge_path_dot(b, normal_x, normal_y)
			if fa < minimum {minimum = fa}
			if fa > maximum {maximum = fa}
			if fa == fb {continue}
			append(&edges, Scan_Edge{
				a          = a,
				b          = b,
				fixed_a    = fa,
				fixed_b    = fb,
				proj_lo    = min(fa, fb),
				proj_hi    = max(fa, fb),
				path_index = u32(path_index),
				edge_index = u32(edge_index),
			})
		}
	}
	if len(edges) == 0 || minimum >= maximum {return}

	step := i128(i64(spacing))*i128(BRIDGE_DIRECTION_SCALE)
	if step <= 0 {error = .Invalid_Config; return}
	line, line_ok := bridge_path_first_scanline(minimum, 0, step)
	if !line_ok {error = .Arithmetic; return}

	slice.sort_by(edges[:], proc(x, y: Scan_Edge) -> bool {
		return x.proj_lo < y.proj_lo
	})

	active := make([dynamic]int, 0, 32, context.temp_allocator)
	scratch_hits := make([dynamic]Bridge_Path_Rational_Hit, 0, 32, context.temp_allocator)
	paths_dyn := make([dynamic]Solid_Path, 0, 32, allocator)
	hits_dyn := make([dynamic]Bridge_Path_Hit, 0, 64, allocator)
	path_set_id := contracts.stable_id_child(mask.stable_id, .Feature, 0)
	next_edge := 0
	mask_path_index: u64

	for line < maximum {
		if scanline_count >= limits.max_scanlines {
			delete(paths_dyn)
			delete(hits_dyn)
			error = .Scanline_Limit
			return
		}
		scanline_index := scanline_count
		scanline_count += 1

		// Retire active edges with proj_hi <= line.
		aw := 0
		for ei in active {
			if edges[ei].proj_hi > line {
				active[aw] = ei
				aw += 1
			}
		}
		resize(&active, aw)
		// Activate entering edges with proj_lo <= line.
		for next_edge < len(edges) && edges[next_edge].proj_lo <= line {
			if edges[next_edge].proj_hi > line {
				append(&active, next_edge)
			}
			next_edge += 1
		}

		clear(&scratch_hits)
		for ei in active {
			e := edges[ei]
			denominator := e.fixed_b - e.fixed_a
			delta := line - e.fixed_a
			x_numerator := i128(i64(e.a.x))*denominator + delta*(i128(i64(e.b.x))-i128(i64(e.a.x)))
			y_numerator := i128(i64(e.a.y))*denominator + delta*(i128(i64(e.b.y))-i128(i64(e.a.y)))
			if denominator < 0 {
				denominator = -denominator
				x_numerator = -x_numerator
				y_numerator = -y_numerator
			}
			x, error_x, x_ok := infill_rational_round(x_numerator, denominator)
			y, error_y, y_ok := infill_rational_round(y_numerator, denominator)
			if !x_ok || !y_ok {
				delete(paths_dyn)
				delete(hits_dyn)
				error = .Arithmetic
				return
			}
			sort_numerator := i128(direction_x)*x_numerator + i128(direction_y)*y_numerator
			append(&scratch_hits, Bridge_Path_Rational_Hit{
				boundary_path_index = e.path_index,
				boundary_edge_index = e.edge_index,
				sort_numerator      = sort_numerator,
				x_numerator         = x_numerator,
				y_numerator         = y_numerator,
				denominator         = denominator,
				point               = {x, y},
				error_x_numerator   = error_x,
				error_y_numerator   = error_y,
			})
		}
		hit_count := len(scratch_hits)
		if hit_count&1 != 0 {
			delete(paths_dyn)
			delete(hits_dyn)
			error = .Odd_Intersection_Count
			return
		}
		if hit_count > 1 {
			slice.sort_by(scratch_hits[:], bridge_path_hit_less)
		}
		for hit_index := 0; hit_index < hit_count; hit_index += 2 {
			first := scratch_hits[hit_index]
			second := scratch_hits[hit_index+1]
			if first.point == second.point {continue}
			if u64(len(paths_dyn)) >= limits.max_paths {
				delete(paths_dyn)
				delete(hits_dyn)
				error = .Path_Limit
				return
			}
			append(&paths_dyn, Solid_Path{
				stable_id              = contracts.stable_id_child(path_set_id, .Path, mask_path_index),
				path_set_id            = path_set_id,
				overlap_mask_id        = mask.stable_id,
				overlap_mask_index     = mask_index,
				layer_index            = mask.layer_index,
				role                   = mask.role,
				angle                  = angle,
				direction_x            = direction_x,
				direction_y            = direction_y,
				mask_path_index        = mask_path_index,
				scanline_index         = scanline_index,
				line_coordinate_scaled = line,
				line_width             = line_width,
				point_a                = first.point,
				point_b                = second.point,
			})
			append(&hits_dyn, bridge_path_output_hit(first))
			append(&hits_dyn, bridge_path_output_hit(second))
			mask_path_index += 1
		}
		if line > max(i128)-step {break}
		line += step
	}
	return paths_dyn[:], hits_dyn[:], scanline_count, .None
}

solid_path_layer_angle :: proc(
	base, step: profiles.Angle_Millidegrees,
	layer_index: u32,
) -> profiles.Angle_Millidegrees {
	value := (
		i64(i32(base))+
		i64(layer_index)*i64(i32(step))
	)%180_000
	return profiles.Angle_Millidegrees(i32(value))
}

solid_path_role_is_skin :: proc(role: profiles.Printable_Role) -> bool {
	return role == .Bottom_Skin ||
		role == .Top_Skin ||
		role == .Top_Bottom_Skin
}

solid_path_overlap_valid :: proc(overlap: Role_Overlap_Result) -> bool {
	if overlap.policy != .Subtract_Higher_Priority ||
	   !role_overlap_fill_rule_valid(overlap.fill_rule) {
		return false
	}
	expected_mask_offset: u64
	expected_path_offset: u64
	for layer, layer_index in overlap.layers {
		if layer.mask_offset != expected_mask_offset ||
		   layer.path_offset != expected_path_offset ||
		   layer.mask_offset+u64(layer.mask_count) >
			u64(len(overlap.masks)) ||
		   layer.path_offset+u64(layer.path_count) >
			u64(len(overlap.paths)) {
			return false
		}
		mask_start := int(layer.mask_offset)
		mask_end := mask_start+int(layer.mask_count)
		for mask in overlap.masks[mask_start:mask_end] {
			if mask.layer_index != u32(layer_index) ||
			   mask.path_offset != expected_path_offset ||
			   mask.path_offset+u64(mask.path_count) >
				u64(len(overlap.paths)) ||
			   mask.point_offset+u64(mask.point_count) >
				u64(len(overlap.points)) {
				return false
			}
			expected_path_offset += u64(mask.path_count)
		}
		if expected_path_offset !=
		   layer.path_offset+u64(layer.path_count) {
			return false
		}
		expected_mask_offset += u64(layer.mask_count)
	}
	return expected_mask_offset == u64(len(overlap.masks)) &&
		expected_path_offset == u64(len(overlap.paths))
}

solid_path_bridge_error :: proc(
	error: Bridge_Path_Error,
) -> Solid_Path_Error {
	#partial switch error {
	case .Odd_Intersection_Count: return .Odd_Intersection_Count
	case .Allocation_Failed:      return .Allocation_Failed
	case .Arithmetic:             return .Arithmetic
	}
	return .Invalid_Input
}

solid_path_overlap_error :: proc(
	error: Role_Overlap_Error,
) -> Solid_Path_Error {
	#partial switch error {
	case .Allocation_Failed: return .Allocation_Failed
	case .Arithmetic:        return .Arithmetic
	}
	return .Invalid_Input
}

@(private = "file")
solid_path_concentric_fill :: proc(
	boundary: polygon.Polygon_Set,
	spacing: contracts.Micrometres,
	line_width: contracts.Micrometres,
	mask: Role_Overlap_Mask,
	mask_index: u32,
	provider: polygon.Polygon_Provider,
	limits: Solid_Path_Limits,
	allocator: mem.Allocator,
) -> (paths: []Solid_Path, hits: []Bridge_Path_Hit, ring_count: u64) {
	pbuf := make([dynamic]Solid_Path, 0, 64, allocator)
	hbuf := make([dynamic]Bridge_Path_Hit, 0, 128, allocator)
	path_set_id := contracts.stable_id_child(mask.stable_id, .Feature, 0)
	step := max(i64(50), i64(spacing))
	for ring_idx := u64(0); ring_idx < 512; ring_idx += 1 {
		cur: polygon.Polygon_Set
		owned := false
		if ring_idx == 0 {
			cur = boundary
		} else {
			delta := contracts.Micrometres(-i64(ring_idx) * step)
			err: polygon.Polygon_Error
			cur, err = provider.offset(boundary, delta, .Miter, 2.0, 0.0, limits.polygon, allocator)
			if err != .None || len(cur.paths) == 0 {
				polygon.polygon_set_destroy(&cur, allocator)
				break
			}
			owned = true
		}
		ring_count += 1
		for mp, mpi in cur.paths {
			if mp.count < 3 {continue}
			pts := cur.points[mp.offset:mp.offset+mp.count]
			for pi in 0..<len(pts) {
				pa := pts[pi]
				pb := pts[(pi+1)%len(pts)]
				if pa == pb {continue}
				idx := u64(len(pbuf))
				h_off := u64(len(hbuf))
				append(&hbuf, Bridge_Path_Hit{point = pa})
				append(&hbuf, Bridge_Path_Hit{point = pb})
				append(&pbuf, Solid_Path{
					stable_id              = contracts.stable_id_child(path_set_id, .Path, idx),
					path_set_id            = path_set_id,
					overlap_mask_id        = mask.stable_id,
					overlap_mask_index     = mask_index,
					layer_index            = mask.layer_index,
					role                   = mask.role,
					angle                  = 0,
					direction_x            = BRIDGE_DIRECTION_SCALE,
					direction_y            = 0,
					mask_path_index        = idx,
					scanline_index         = ring_idx,
					line_coordinate_scaled = i128(ring_idx)*1000 + i128(mpi),
					line_width             = line_width,
					point_a                = pa,
					point_b                = pb,
					hit_offset             = h_off,
				})
			}
		}
		if owned {
			polygon.polygon_set_destroy(&cur, allocator)
		}
	}
	return pbuf[:], hbuf[:], ring_count
}

solid_path_result_destroy :: proc(
	result: ^Solid_Path_Result,
	allocator := context.allocator,
) {
	delete(result.layers, allocator)
	delete(result.paths, allocator)
	delete(result.hits, allocator)
	for &boundary in result.connector_boundaries {
		polygon.polygon_set_destroy(&boundary, allocator)
	}
	delete(result.connector_boundaries, allocator)
	result^ = {}
}
