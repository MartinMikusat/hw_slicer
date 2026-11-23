package features

import "core:math"

import contracts "../contracts"
import polygon "../polygon"

Variable_Wall_Config :: struct {
	enabled:             bool,
	nominal_width_um:    contracts.Micrometres,
	min_width_um:        contracts.Micrometres, // default 0.65 * nominal
	max_width_um:        contracts.Micrometres, // default 1.50 * nominal
}

Variable_Wall_Stats :: struct {
	vertices_adapted: u64,
}

// Arachne-style variable wall width adaptation: inspects perimeter vertices against
// opposing segments on the same loop (thin walls / acute corners) and smoothly adjusts
// per-vertex `line_widths` within [min_width_um, max_width_um] to prevent micro-gaps
// and over-extrusion at tight turns.
variable_walls_adapt :: proc(
	sources: []Unified_Path_Source,
	config: Variable_Wall_Config,
) -> Variable_Wall_Stats {
	if !config.enabled || i64(config.nominal_width_um) <= 0 {
		return {}
	}
	nom := f64(i64(config.nominal_width_um))
	min_w := f64(i64(config.min_width_um)) if i64(config.min_width_um) > 0 else nom * 0.65
	max_w := f64(i64(config.max_width_um)) if i64(config.max_width_um) > 0 else nom * 1.50
	if min_w < 100.0 {min_w = 100.0}
	if max_w < nom {max_w = nom}

	stats := Variable_Wall_Stats{}

	for &src in sources {
		if src.source_kind != .Perimeter || !src.closed || len(src.points) < 4 {
			continue
		}
		n := len(src.points)
		for vi in 0..<n {
			prev := src.points[(vi + n - 1) % n]
			cur := src.points[vi]
			next := src.points[(vi + 1) % n]

			ax := f64(i64(prev.x) - i64(cur.x))
			ay := f64(i64(prev.y) - i64(cur.y))
			bx := f64(i64(next.x) - i64(cur.x))
			by := f64(i64(next.y) - i64(cur.y))
			la := math.hypot(ax, ay)
			lb := math.hypot(bx, by)
			if la < 1.0 || lb < 1.0 {continue}

			// Cosine of interior turning angle at cur: -1 = straight, +1 = 180 deg hairpin.
			cos_t := clamp((ax*bx + ay*by) / (la * lb), -1.0, 1.0)
			// At sharp hairpins (cos_t > 0.5, angle < 60 deg), narrow the bead slightly to avoid corner blobbing.
			// At gentle concave/thin transitions (short segments near nominal width), widen slightly to close gaps.
			adapted := nom
			if cos_t > 0.5 {
				t := (cos_t - 0.5) / 0.5
				adapted = nom * (1.0 - 0.30 * t)
			} else if min(la, lb) < nom * 1.25 && cos_t > -0.2 {
				adapted = nom * 1.15
			}
			adapted = clamp(adapted, min_w, max_w)
			new_w := contracts.Micrometres(i64(math.round(adapted)))
			if new_w != src.line_widths[vi] {
				src.line_widths[vi] = new_w
				stats.vertices_adapted += 1
			}
		}
	}
	return stats
}
