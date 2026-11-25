package features

import "core:math"
import "core:mem"

import contracts "../contracts"
import polygon "../polygon"
import profiles "../profiles"
import workers "../workers"

Ironing_Type :: enum u8 {
	None,
	Top,
	Topmost,
	All_Solid,
}

Ironing_Config :: struct {
	enabled:         bool,
	ironing_type:    Ironing_Type,          // default .Top when enabled
	spacing_um:      contracts.Micrometres, // default 150 um (0.15 mm)
	flow_percent:    u32,                   // default 15%
	inset_um:        contracts.Micrometres,
	nozzle_diameter: contracts.Micrometres,
	line_width:      contracts.Micrometres,
	min_width_um:    contracts.Micrometres, // must be >= layer height for rounded-bead extrusion
	provider:        polygon.Polygon_Provider,
}

Ironing_Path :: struct {
	layer_index: u32,
	points:      []polygon.Polygon_Point,
	line_widths: []contracts.Micrometres,
}

Ironing_Result :: struct {
	paths: []Ironing_Path,
}

ironing_result_destroy :: proc(r: ^Ironing_Result, allocator := context.allocator) {
	for p in r.paths {
		delete(p.points, allocator)
		delete(p.line_widths, allocator)
	}
	delete(r.paths, allocator)
	r^ = {}
}

// Reorders each layer's top/bottom skin paths strictly monotonically by (mask_index, scanline_index, projection)
// so adjacent skin lines are always laid down in one consistent sweep direction without seam ridges.
solid_paths_sort_monotonic :: proc(solids: ^Solid_Path_Result) {
	if solids == nil || len(solids.paths) == 0 {return}
	Monotonic_Ctx :: struct {
		layers: []Solid_Path_Layer,
		paths:  []Solid_Path,
	}
	mctx := Monotonic_Ctx{layers = solids.layers, paths = solids.paths}
	parallel_for(len(solids.layers), &mctx, proc(c: ^Monotonic_Ctx, li: int) {
		layer := c.layers[li]
		if layer.path_count < 2 {return}
		start := int(layer.path_offset)
		end := start + int(layer.path_count)
		if end > len(c.paths) {return}
		Sort_Key :: struct {
			role: profiles.Printable_Role,
			mask_index: u32,
			line_coordinate: i128,
			projection: i128,
			index: int,
		}
		paths := c.paths[start:end]
		keys := features_make_non_zeroed([]Sort_Key, len(paths), context.temp_allocator)
		ordered := features_make_non_zeroed([]Solid_Path, len(paths), context.temp_allocator)
		if keys == nil || ordered == nil {return}
		for path, i in paths {
			keys[i] = {
				role = path.role,
				mask_index = path.overlap_mask_index,
				line_coordinate = path.line_coordinate_scaled,
				projection = i128(i64(path.point_a.x))*i128(path.direction_x) +
					i128(i64(path.point_a.y))*i128(path.direction_y),
				index = i,
			}
		}
		features_fast_sort(keys, proc(a, b: Sort_Key) -> bool {
			if a.role != b.role {return u8(a.role) < u8(b.role)}
			if a.mask_index != b.mask_index {return a.mask_index < b.mask_index}
			if a.line_coordinate != b.line_coordinate {return a.line_coordinate < b.line_coordinate}
			if a.projection != b.projection {return a.projection < b.projection}
			return a.index < b.index
		})
		for key, i in keys {
			ordered[i] = paths[key.index]
		}
		copy(paths, ordered)
	})
}

ironing_paths_generate :: proc(
	overlap: Role_Overlap_Result,
	surfaces: Surface_Result,
	model_layers: []polygon.Polygon_Set,
	config: Ironing_Config,
	allocator := context.allocator,
) -> Ironing_Result {
	itype := config.ironing_type
	if itype == .None && config.enabled {
		itype = .Top
	}
	if itype == .None || i64(config.spacing_um) <= 0 || i64(config.line_width) <= 0 {
		return {}
	}
	flow_pct := config.flow_percent
	if flow_pct == 0 || flow_pct > 50 {flow_pct = 15}
	floor_w := max(i64(50), i64(config.min_width_um))
	iron_width := contracts.Micrometres(max(floor_w, (i64(config.line_width) * i64(flow_pct)) / 100))
	spacing := f64(i64(config.spacing_um))
	angle_rad := math.PI * 0.25 // 45 deg cross-ironing pass

	Iron_Mask_Item :: struct {
		layer_index: u32,
		boundary:    polygon.Polygon_Set,
		outline:     polygon.Polygon_Set,
	}
	items := make([dynamic]Iron_Mask_Item, 0, 64, allocator)
	defer {
		for &it in items {polygon.polygon_set_destroy(&it.boundary, allocator)}
		delete(items)
	}

	if itype == .Top || itype == .Topmost {
		topmost_layer: u32
		if itype == .Topmost {
			for mask in surfaces.masks {
				if mask.kind == .Top_Exposed && mask.path_count > 0 {
					topmost_layer = max(topmost_layer, mask.layer_index)
				}
			}
		}
		for mask, index in surfaces.masks {
			if mask.kind != .Top_Exposed || mask.path_count == 0 ||
			   (itype == .Topmost && mask.layer_index != topmost_layer) {continue}
			if u64(mask.layer_index) >= u64(len(model_layers)) {return {}}
			boundary, err := skin_surface_input(surfaces, u32(index), allocator)
			if err != .None {return {}}
			append(&items, Iron_Mask_Item{
				layer_index = mask.layer_index,
				boundary    = boundary,
				outline     = model_layers[mask.layer_index],
			})
		}
	} else {
		for mask, index in overlap.masks {
			if mask.path_count == 0 || !solid_path_role_is_skin(mask.role) {continue}
			boundary, err := role_overlap_mask_input(overlap, u32(index), allocator)
			if err != .None {return {}}
			append(&items, Iron_Mask_Item{layer_index = mask.layer_index, boundary = boundary})
		}
	}

	n_items := len(items)
	if n_items == 0 {return {}}

	canon_of := make([]int, n_items, allocator)
	unique_idx := make([dynamic]int, 0, n_items, allocator)
	defer delete(canon_of, allocator)
	defer delete(unique_idx)
	{
		cap_pow2 := 16
		for cap_pow2 < n_items * 2 {cap_pow2 <<= 1}
		ht_mask := u64(cap_pow2 - 1)
		ht := make([]int, cap_pow2, allocator)
		defer delete(ht, allocator)
		for i in 0..<n_items {
			item := items[i]
			h := features_polygon_set_hash64(item.boundary) ~
				(features_polygon_set_hash64(item.outline) * 1099511628211)
			slot := h & ht_mask
			found := -1
			for {
				entry := ht[slot]
				if entry == 0 {break}
				cand := entry - 1
				if features_polygon_sets_equal(items[cand].boundary, item.boundary) &&
				   features_polygon_sets_equal(items[cand].outline, item.outline) {
					found = cand
					break
				}
				slot = (slot + 1) & ht_mask
			}
			if found >= 0 {
				canon_of[i] = found
			} else {
				ht[slot] = i + 1
				canon_of[i] = i
				append(&unique_idx, i)
			}
		}
	}

	per_item_paths := make([][]Ironing_Path, n_items, allocator)
	defer {
		for paths in per_item_paths {delete(paths, allocator)}
		delete(per_item_paths, allocator)
	}

	Iron_Par_Ctx :: struct {
		items:          []Iron_Mask_Item,
		unique_idx:     []int,
		per_item_paths: [][]Ironing_Path,
		config:         Ironing_Config,
		angle_rad:      f64,
		spacing:        f64,
		iron_width:     contracts.Micrometres,
		allocator:      mem.Allocator,
	}
	ictx := Iron_Par_Ctx{
		items          = items[:],
		unique_idx     = unique_idx[:],
		per_item_paths = per_item_paths,
		config         = config,
		angle_rad      = angle_rad,
		spacing        = spacing,
		iron_width     = iron_width,
		allocator      = allocator,
	}
	parallel_for(len(unique_idx), &ictx, proc(c: ^Iron_Par_Ctx, ui: int) {
		idx := c.unique_idx[ui]
		item := c.items[idx]
		boundary := item.boundary
		if len(item.outline.paths) > 0 {
			inset := c.config.inset_um if c.config.inset_um > 0 else c.config.nozzle_diameter/2
			if inset > 0 && c.config.provider.offset != nil && c.config.provider.boolean != nil {
				scratch := workers.scratch_allocator()
				safe_outline, offset_error := c.config.provider.offset(
					item.outline, -inset, .Miter, 2.0, 0.0, polygon.DEFAULT_POLYGON_LIMITS, scratch,
				)
				if offset_error != .None || len(safe_outline.paths) == 0 {return}
				clipped, clip_error := c.config.provider.boolean(
					boundary, safe_outline, .Intersection, .Non_Zero, polygon.DEFAULT_POLYGON_LIMITS, scratch,
				)
				if clip_error != .None {return}
				boundary = clipped
			}
		} else if i64(c.config.inset_um) > 0 && c.config.provider.offset != nil {
			ins, err := c.config.provider.offset(
				boundary,
				-c.config.inset_um,
				.Miter,
				2.0,
				0.0,
				polygon.DEFAULT_POLYGON_LIMITS,
				workers.scratch_allocator(),
			)
			if err == .None {
				boundary = ins
			}
		}
		if len(boundary.paths) == 0 {return}
		min_x, min_y, max_x, max_y := infill_pat_bounds(boundary)
		if max_x <= min_x || max_y <= min_y {return}

		tmp_infill := make([dynamic]Infill_Pattern_Path, 0, 64, context.temp_allocator)
		infill_pat_hatch(
			&tmp_infill,
			boundary,
			item.layer_index,
			min_x, min_y, max_x, max_y,
			c.angle_rad,
			c.spacing,
			0.0,
			c.iron_width,
			c.allocator,
		)
		infill_pat_connect(&tmp_infill, 0, boundary, max(c.spacing * 4.0, 1_000.0), c.iron_width, c.allocator)
		if len(tmp_infill) == 0 {return}
		local := make([]Ironing_Path, len(tmp_infill), c.allocator)
		for tp, ti in tmp_infill {
			local[ti] = {
				layer_index = tp.layer_index,
				points      = tp.points,
				line_widths = tp.line_widths,
			}
		}
		c.per_item_paths[idx] = local
	})

	total_paths := 0
	for i in 0..<n_items {
		total_paths += len(per_item_paths[canon_of[i]])
	}
	if total_paths == 0 {return {}}
	out := make([]Ironing_Path, total_paths, allocator)
	write := 0
	for i in 0..<n_items {
		src := canon_of[i]
		src_paths := per_item_paths[src]
		if len(src_paths) == 0 {continue}
		if src == i {
			for p in src_paths {
				out[write] = p
				write += 1
			}
		} else {
			li := items[i].layer_index
			for p in src_paths {
				cp := make([]polygon.Polygon_Point, len(p.points), allocator)
				cw := make([]contracts.Micrometres, len(p.line_widths), allocator)
				copy(cp, p.points)
				copy(cw, p.line_widths)
				out[write] = {layer_index = li, points = cp, line_widths = cw}
				write += 1
			}
		}
	}
	return Ironing_Result{paths = out[:write]}
}
