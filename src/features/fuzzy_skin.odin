package features

import "core:math"

import contracts "../contracts"
import polygon "../polygon"
import profiles "../profiles"

Fuzzy_Skin_Mode :: enum u8 {
	None,
	Contour,   // outer contour outer wall only
	All,       // outer walls of both outer contours and holes
	All_Walls, // all perimeter walls (outer + inner)
}

Fuzzy_Skin_Config :: struct {
	enabled:        bool,
	mode:           Fuzzy_Skin_Mode,       // default .All when enabled
	thickness_um:   contracts.Micrometres, // default 300 um (0.3 mm)
	point_dist_um:  contracts.Micrometres, // default 800 um (0.8 mm)
	first_layer:    bool,                  // default false (skip layer 0)
}

Fuzzy_Skin_Stats :: struct {
	loops_perturbed: u64,
	vertices_added:  u64,
}

// Applies deterministic hash-seeded outward normal jitter along outer perimeter loops
// (skipping layer 0 so bed adhesion remains flat and predictable).
fuzzy_skin_apply :: proc(
	sources: []Unified_Path_Source,
	perimeters: Perimeter_Result,
	config: Fuzzy_Skin_Config,
	printer: profiles.Printer_Profile,
	owned_points: ^[dynamic][]polygon.Polygon_Point,
	owned_widths: ^[dynamic][]contracts.Micrometres,
	allocator := context.allocator,
) -> Fuzzy_Skin_Stats {
	mode := config.mode
	if mode == .None && config.enabled {
		mode = .All
	}
	if mode == .None {return {}}
	thick := f64(i64(config.thickness_um)) if i64(config.thickness_um) > 0 else 300.0
	pdist := f64(i64(config.point_dist_um)) if i64(config.point_dist_um) > 0 else 800.0
	stats := Fuzzy_Skin_Stats{}

	for &src in sources {
		if src.source_kind != .Perimeter || !src.closed || len(src.points) < 3 {
			continue
		}
		if src.layer_index == 0 && !config.first_layer {
			continue
		}
		if int(src.source_index) >= len(perimeters.paths) {
			continue
		}
		pp := perimeters.paths[src.source_index]
		switch mode {
		case .None:
			continue
		case .Contour:
			if pp.perimeter_index != 0 || pp.winding != .Positive {continue}
		case .All:
			if pp.perimeter_index != 0 {continue}
		case .All_Walls:
			// perturb all perimeter walls
		}
		n := len(src.points)
		new_pts := make([dynamic]polygon.Polygon_Point, 0, n * 2, allocator)
		new_ws := make([dynamic]contracts.Micrometres, 0, n * 2, allocator)

		for i in 0..<n {
			a := src.points[i]
			b := src.points[(i + 1) % n]
			wa := src.line_widths[i]
			dx := f64(i64(b.x) - i64(a.x))
			dy := f64(i64(b.y) - i64(a.y))
			seg_len := math.hypot(dx, dy)
			if seg_len < 1.0 {continue}
			// Right-hand unit normal (outward for CCW outer perimeters).
			nx := dy / seg_len
			ny := -dx / seg_len

			steps := max(1, int(math.floor(seg_len / pdist)))
			if steps > 64 {steps = 64}
			for s in 0..<steps {
				t := f64(s) / f64(steps)
				bx := f64(i64(a.x)) + dx * t
				by := f64(i64(a.y)) + dy * t
				// Deterministic hash in [0, 1] from (layer_index, i, s).
				h := fuzzy_hash_u64(u64(src.layer_index)*0x9e3779b97f4a7c15 ~ u64(i)*0xbf58476d1ce4e5b9 ~ u64(s)*0x94d049bb133111eb)
				jitter := (f64(h & 0xFFFF) / 65535.0) * thick
				px := clamp(i64(math.round(bx + nx*jitter)), i64(printer.axis_minimum_x), i64(printer.axis_maximum_x))
				py := clamp(i64(math.round(by + ny*jitter)), i64(printer.axis_minimum_y), i64(printer.axis_maximum_y))
				pt := polygon.Polygon_Point{x = contracts.Micrometres(px), y = contracts.Micrometres(py)}
				if len(new_pts) == 0 || new_pts[len(new_pts)-1] != pt {
					append(&new_pts, pt)
					append(&new_ws, wa)
				}
			}
		}
		for len(new_pts) > 1 && new_pts[len(new_pts)-1] == new_pts[0] {
			pop(&new_pts)
			pop(&new_ws)
		}
		if len(new_pts) >= 3 {
			src.points = new_pts[:]
			src.line_widths = new_ws[:]
			append(owned_points, new_pts[:])
			append(owned_widths, new_ws[:])
			stats.loops_perturbed += 1
			stats.vertices_added += u64(len(new_pts))
		} else {
			delete(new_pts)
			delete(new_ws)
		}
	}
	return stats
}

@(private = "file")
fuzzy_hash_u64 :: proc(x: u64) -> u64 {
	v := x
	v ~= v >> 30
	v *= 0xbf58476d1ce4e5b9
	v ~= v >> 27
	v *= 0x94d049bb133111eb
	v ~= v >> 31
	return v
}
