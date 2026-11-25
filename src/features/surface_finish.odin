package features

import "base:runtime"
import "core:math"
import "core:slice"

import contracts "../contracts"
import polygon "../polygon"
import profiles "../profiles"

Ironing_Type :: enum u8 {
	None,
	Top,
	Topmost,
	All_Solid,
}

Ironing_Config :: struct {
	enabled:      bool,
	ironing_type: Ironing_Type,          // default .Top when enabled
	spacing_um:   contracts.Micrometres, // default 150 um (0.15 mm)
	flow_percent: u32,                   // default 15%
	inset_um:     contracts.Micrometres, // default 0 (optional inset from mask boundary)
	line_width:   contracts.Micrometres,
	min_width_um: contracts.Micrometres, // must be >= layer height for rounded-bead extrusion
	provider:     polygon.Polygon_Provider,
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
	for layer in solids.layers {
		if layer.path_count < 2 {continue}
		start := int(layer.path_offset)
		end := start + int(layer.path_count)
		if end > len(solids.paths) {continue}
		slice.sort_by(solids.paths[start:end], proc(a, b: Solid_Path) -> bool {
			if a.role != b.role {return u8(a.role) < u8(b.role)}
			if a.overlap_mask_index != b.overlap_mask_index {
				return a.overlap_mask_index < b.overlap_mask_index
			}
			if a.line_coordinate_scaled != b.line_coordinate_scaled {
				return a.line_coordinate_scaled < b.line_coordinate_scaled
			}
			proj_a := i128(i64(a.point_a.x))*i128(a.direction_x) + i128(i64(a.point_a.y))*i128(a.direction_y)
			proj_b := i128(i64(b.point_a.x))*i128(b.direction_x) + i128(i64(b.point_a.y))*i128(b.direction_y)
			return proj_a < proj_b
		})
	}
}

// Generates a fine low-flow ironing pass across top, topmost, or all solid masks.
ironing_paths_generate :: proc(
	overlap: Role_Overlap_Result,
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

	topmost_layer: u32 = 0
	has_topmost := false
	if itype == .Topmost {
		for mask in overlap.masks {
			if (mask.role == .Top_Skin || mask.role == .Top_Bottom_Skin) && mask.path_count > 0 {
				if !has_topmost || mask.layer_index > topmost_layer {
					topmost_layer = mask.layer_index
					has_topmost = true
				}
			}
		}
		if !has_topmost {return {}}
	}

	out := make([dynamic]Ironing_Path, 0, 128, allocator)
	for mask in overlap.masks {
		switch itype {
		case .None:
			continue
		case .Top:
			if mask.role != .Top_Skin && mask.role != .Top_Bottom_Skin {continue}
		case .Topmost:
			if (mask.role != .Top_Skin && mask.role != .Top_Bottom_Skin) || mask.layer_index != topmost_layer {continue}
		case .All_Solid:
			if mask.role != .Top_Skin && mask.role != .Bottom_Skin && mask.role != .Top_Bottom_Skin {continue}
		}
		if mask.path_count == 0 {continue}
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

		// Build temporary Polygon_Set for this mask.
		p_start := int(mask.path_offset)
		p_end := p_start + int(mask.path_count)
		pts := make([dynamic]polygon.Polygon_Point, 0, 64, context.temp_allocator)
		paths := make([dynamic]polygon.Polygon_Path, 0, int(mask.path_count), context.temp_allocator)
		for mp in overlap.paths[p_start:p_end] {
			if mp.point_count < 3 {continue}
			off := u64(len(pts))
			ps := int(mp.point_offset)
			pe := ps + int(mp.point_count)
			for pt in overlap.points[ps:pe] {
				append(&pts, pt)
			}
			append(&paths, polygon.Polygon_Path{offset = off, count = u64(mp.point_count)})
		}
		if len(paths) == 0 {continue}
		boundary := polygon.Polygon_Set{points = pts[:], paths = paths[:]}
		inset_owned: polygon.Polygon_Set
		defer polygon.polygon_set_destroy(&inset_owned, allocator)
		if i64(config.inset_um) > 0 && config.provider.offset != nil {
			ins, err := config.provider.offset(
				boundary,
				-config.inset_um,
				.Miter,
				2.0,
				0.0,
				polygon.DEFAULT_POLYGON_LIMITS,
				allocator,
			)
			if err == .None {
				inset_owned = ins
				boundary = inset_owned
			} else {
				polygon.polygon_set_destroy(&ins, allocator)
			}
		}
		if len(boundary.paths) == 0 {continue}
		min_x, min_y, max_x, max_y := infill_pat_bounds(boundary)
		if max_x <= min_x || max_y <= min_y {continue}

		tmp_infill := make([dynamic]Infill_Pattern_Path, 0, 32, context.temp_allocator)
		infill_pat_hatch(
			&tmp_infill,
			boundary,
			mask.layer_index,
			min_x, min_y, max_x, max_y,
			angle_rad,
			spacing,
			0.0,
			iron_width,
			allocator,
		)
		for tp in tmp_infill {
			append(&out, Ironing_Path{
				layer_index = tp.layer_index,
				points      = tp.points,
				line_widths = tp.line_widths,
			})
		}
	}
	return Ironing_Result{paths = out[:]}
}
