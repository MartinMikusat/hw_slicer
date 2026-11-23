package features

import "base:runtime"
import "core:math"

import contracts "../contracts"
import polygon "../polygon"
import profiles "../profiles"
import slicing "../slicing"

Tree_Support_Config :: struct {
	overhang_angle_deg:  f64,                   // default 45.0
	branch_angle_deg:    f64,                   // default 45.0
	tip_radius_um:       contracts.Micrometres, // default 800 um (0.8 mm)
	trunk_max_radius_um: contracts.Micrometres, // default 6000 um (6.0 mm)
	tip_spacing_um:      contracts.Micrometres, // default 4000 um (4.0 mm)
	xy_clearance_um:     contracts.Micrometres, // default 600 um (0.6 mm)
	interface_layers:    u32,                   // default 2
	line_width_um:       contracts.Micrometres,
	bed_min_x:           contracts.Micrometres,
	bed_max_x:           contracts.Micrometres,
	bed_min_y:           contracts.Micrometres,
	bed_max_y:           contracts.Micrometres,
}

Tree_Support_Path :: struct {
	layer_index:  u32,
	is_interface: bool,
	points:       []polygon.Polygon_Point,
	line_widths:  []contracts.Micrometres,
}

Tree_Support_Result :: struct {
	paths:       []Tree_Support_Path,
	tip_count:   u64,
	branch_nodes: u64,
}

tree_support_result_destroy :: proc(r: ^Tree_Support_Result, allocator := context.allocator) {
	for p in r.paths {
		delete(p.points, allocator)
		delete(p.line_widths, allocator)
	}
	delete(r.paths, allocator)
	r^ = {}
}

@(private = "file")
Tree_Branch :: struct {
	x:           f64,
	y:           f64,
	radius:      f64,
	tip_layers:  u32, // layers remaining in interface zone at top of branch
	paths:       [dynamic]int, // indices of the rings this branch (and branches merged into it) emitted
	dead:        bool,
}

// Generates organic/tree support rings from overhang tips routed top-down to the build plate.
tree_supports_generate :: proc(
	topology: slicing.Topology_Result,
	regions: slicing.Region_Result,
	model_layers: []polygon.Polygon_Set,
	layer_z: []contracts.Micrometres,
	config: Tree_Support_Config,
	allocator := context.allocator,
) -> Tree_Support_Result {
	layer_count := len(regions.layers)
	if layer_count < 2 || len(model_layers) != layer_count || i64(config.line_width_um) <= 0 {
		return {}
	}

	tip_r := f64(i64(config.tip_radius_um)) if i64(config.tip_radius_um) > 0 else 800.0
	max_r := f64(i64(config.trunk_max_radius_um)) if i64(config.trunk_max_radius_um) > 0 else 6000.0
	spacing := f64(i64(config.tip_spacing_um)) if i64(config.tip_spacing_um) > 0 else 4000.0
	branch_ang := config.branch_angle_deg if config.branch_angle_deg > 5.0 && config.branch_angle_deg < 75.0 else 45.0
	tan_branch := math.tan(branch_ang * math.PI / 180.0)
	iface_layers := config.interface_layers if config.interface_layers > 0 else 2
	lw := config.line_width_um
	overhang_ang := config.overhang_angle_deg if config.overhang_angle_deg > 0.0 && config.overhang_angle_deg < 89.0 else 45.0
	tan_overhang := math.tan(overhang_ang * math.PI / 180.0)
	// A ring keeps the XY clearance plus half its line width from the model.
	keep_out := f64(i64(config.xy_clearance_um)) + f64(i64(lw)) / 2.0

	// Compute model centroid on layer 0 (fallback: bed center) for outward avoidance steering.
	cx_sum, cy_sum: f64
	c_cnt: int
	for pt in model_layers[0].points {
		cx_sum += f64(i64(pt.x))
		cy_sum += f64(i64(pt.y))
		c_cnt += 1
	}
	model_cx := cx_sum / f64(c_cnt) if c_cnt > 0 else 0.5 * f64(i64(config.bed_min_x) + i64(config.bed_max_x))
	model_cy := cy_sum / f64(c_cnt) if c_cnt > 0 else 0.5 * f64(i64(config.bed_min_y) + i64(config.bed_max_y))

	// Step 1: Detect overhang tip clusters per layer (sampling outer contour vertices unsupported by layer-1).
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	tips_per_layer := make([][dynamic][2]f64, layer_count, context.temp_allocator)
	total_tips: u64
	for li := 1; li < layer_count; li += 1 {
		prev_model := model_layers[li - 1]
		reg_layer := regions.layers[li]
		r_start := int(reg_layer.region_offset)
		r_end := r_start + int(reg_layer.region_count)
		for ri in r_start..<r_end {
			reg := regions.regions[ri]
			if reg.contour_count == 0 {continue}
			ci := regions.region_contour_indices[reg.contour_offset]
			contour := regions.contours[ci]
			path := topology.paths[contour.path_index]
			vc := int(path.vertex_count)
			if vc < 3 {continue}
			// Sample along contour vertices.
			stride := max(1, vc / 64)
			// A point overhangs when it lies farther outside the layer below than the overhang
			// angle allows: layer height * tan(angle), with the angle measured from vertical.
			layer_dz := f64(i64(layer_z[li]) - i64(layer_z[li - 1]))
			allowed_um := max(0.0, layer_dz) * tan_overhang
			for vi := 0; vi < vc; vi += stride {
				pt := slicing.region_path_point(topology, path, vi)
				if bridge_polygon_contains_twice(prev_model, i64(pt.x)*2, i64(pt.y)*2) {
					continue
				}
				if tree_support_boundary_distance(prev_model, f64(i64(pt.x)), f64(i64(pt.y))) <= allowed_um {
					continue
				}
				// Cluster against existing tips on this layer.
				px, py := f64(i64(pt.x)), f64(i64(pt.y))
				too_close := false
				for existing in tips_per_layer[li] {
					if math.hypot(px - existing[0], py - existing[1]) < spacing {
						too_close = true
						break
					}
				}
				if !too_close {
					if tips_per_layer[li].allocator.procedure == nil {
						tips_per_layer[li] = make([dynamic][2]f64, 0, 8, context.temp_allocator)
					}
					append(&tips_per_layer[li], [2]f64{px, py})
					total_tips += 1
				}
			}
		}
	}

	if total_tips == 0 {
		return {}
	}

	// Step 2: Top-down branch propagation, obstacle avoidance, and merging.
	active := make([dynamic]Tree_Branch, 0, 64, context.temp_allocator)
	out_paths := make([dynamic]Tree_Support_Path, 0, 256, allocator)
	dead_paths := make([dynamic]bool, 0, 256, context.temp_allocator)

	for li := layer_count - 1; li >= 0; li -= 1 {
		// Spawn new branches for tips detected at li + 1 (so tips terminate 1 layer below the overhang).
		if li + 1 < layer_count {
			for tip in tips_per_layer[li + 1] {
				// Avoid spawning if an active branch is already right underneath.
				covered := false
				for b in active {
					if math.hypot(tip[0] - b.x, tip[1] - b.y) < max(b.radius, spacing * 0.6) {
						covered = true
						break
					}
				}
				if !covered {
					append(&active, Tree_Branch{
						x          = tip[0],
						y          = tip[1],
						radius     = tip_r,
						tip_layers = iface_layers,
						paths      = make([dynamic]int, 0, 8, context.temp_allocator),
					})
				}
			}
		}

		if len(active) == 0 {continue}

		dz := 200.0
		if li + 1 < layer_count {
			d := f64(i64(layer_z[li + 1]) - i64(layer_z[li]))
			if d > 10.0 {dz = d}
		}
		max_step := dz * tan_branch

		// Avoid model collisions on layer `li` by steering outward away from model centroid.
		cur_model := model_layers[li]
		for &b in active {
			bx_i := i64(math.round(b.x))
			by_i := i64(math.round(b.y))
			if bridge_polygon_contains_twice(cur_model, bx_i*2, by_i*2) {
				dx := b.x - model_cx
				dy := b.y - model_cy
				dlen := math.hypot(dx, dy)
				if dlen < 1.0 {
					dx, dy, dlen = 1.0, 0.0, 1.0
				}
				b.x += (dx / dlen) * max_step
				b.y += (dy / dlen) * max_step
			}
			// Taper trunk gently downward for stability.
			if b.tip_layers == 0 {
				b.radius = min(max_r, b.radius + dz * 0.04)
			}
		}

		// Merge overlapping branches.
		merged := make([dynamic]Tree_Branch, 0, len(active), context.temp_allocator)
		used := make([]bool, len(active), context.temp_allocator)
		for i in 0..<len(active) {
			if used[i] {continue}
			acc := active[i]
			w_sum := acc.radius * acc.radius
			wx := acc.x * w_sum
			wy := acc.y * w_sum
			for j := i + 1; j < len(active); j += 1 {
				if used[j] {continue}
				other := active[j]
				if math.hypot(acc.x - other.x, acc.y - other.y) <= (acc.radius + other.radius) * 0.85 {
					used[j] = true
					wj := other.radius * other.radius
					wx += other.x * wj
					wy += other.y * wj
					w_sum += wj
					acc.radius = min(max_r, math.sqrt(w_sum))
					if other.tip_layers > acc.tip_layers {
						acc.tip_layers = other.tip_layers
					}
					append(&acc.paths, ..other.paths[:])
				}
			}
			acc.x = wx / w_sum
			acc.y = wy / w_sum
			append(&merged, acc)
		}
		clear(&active)
		for m in merged {append(&active, m)}

		// Emit hollow 16-gon ring per active branch on layer `li`. A branch that cannot keep the
		// clearance, even after moving away from the model by up to one branch-angle step, or that
		// leaves the bed, ends here and its rings above are removed: a trunk with a gap would leave
		// those rings resting on nothing.
		min_clear := f64(i64(lw)) + keep_out
		Emitted_Ring :: struct {
			branch: int,
			x, y:   f64,
			radius: f64,
		}
		emitted := make([dynamic]Emitted_Ring, 0, len(active), context.temp_allocator)
		blocked := make([dynamic]int, 0, 8, context.temp_allocator)
		for &b, branch_index in active {
			is_iface := b.tip_layers > 0
			if b.tip_layers > 0 {b.tip_layers -= 1}

			inside := bridge_polygon_contains_twice(cur_model, i64(math.round(b.x))*2, i64(math.round(b.y))*2)
			distance, near_x, near_y := tree_support_nearest_boundary(cur_model, b.x, b.y)
			if inside || distance < min_clear {
				// Move from the nearest boundary point outward until the clearance holds.
				dx, dy := b.x - near_x, b.y - near_y
				if inside {dx, dy = -dx, -dy}
				dlen := math.hypot(dx, dy)
				target_x, target_y := b.x, b.y
				if dlen > 1e-9 {
					target_x = near_x + dx / dlen * min_clear * 1.01
					target_y = near_y + dy / dlen * min_clear * 1.01
				}
				// A new branch has no rings yet, so it may move the full clearance off the overhang
				// edge where its tip was found; later layers move at most one branch-angle step.
				allowed_move := max_step if len(b.paths) > 0 else max(max_step, min_clear * 1.01)
				if math.hypot(target_x - b.x, target_y - b.y) <= allowed_move {
					b.x, b.y = target_x, target_y
					inside = bridge_polygon_contains_twice(cur_model, i64(math.round(b.x))*2, i64(math.round(b.y))*2)
					distance, _, _ = tree_support_nearest_boundary(cur_model, b.x, b.y)
				}
			}
			ring_r := min(b.radius, distance - keep_out)
			fits := !inside && ring_r >= f64(i64(lw))

			sides :: 16
			pts: []polygon.Polygon_Point
			if fits {
				pts = make([]polygon.Polygon_Point, sides, allocator)
				for s in 0..<sides {
					ang := (2.0 * math.PI * f64(s)) / f64(sides)
					px := contracts.Micrometres(i64(math.round(b.x + ring_r * math.cos(ang))))
					py := contracts.Micrometres(i64(math.round(b.y + ring_r * math.sin(ang))))
					if i64(px) < i64(config.bed_min_x) || i64(px) > i64(config.bed_max_x) ||
					   i64(py) < i64(config.bed_min_y) || i64(py) > i64(config.bed_max_y) {
						fits = false
						break
					}
					pts[s] = {x = px, y = py}
				}
			}
			if !fits {
				delete(pts, allocator)
				append(&blocked, branch_index)
				continue
			}
			append(&emitted, Emitted_Ring{branch_index, b.x, b.y, ring_r})
			ws := make([]contracts.Micrometres, sides, allocator)
			for s in 0..<sides {ws[s] = lw}
			append(&b.paths, len(out_paths))
			append(&out_paths, Tree_Support_Path{
				layer_index  = u32(li),
				is_interface = is_iface,
				points       = pts,
				line_widths  = ws,
			})
			append(&dead_paths, false)
		}
		// A blocked branch ends. If a ring emitted on this layer overlaps its footprint, that ring
		// carries it: its rings join that branch and are removed only if that branch dies later.
		// Otherwise its rings would float and are removed now.
		for branch_index in blocked {
			b := &active[branch_index]
			carrier := -1
			for ring in emitted {
				if math.hypot(b.x - ring.x, b.y - ring.y) <= b.radius + ring.radius {
					carrier = ring.branch
					break
				}
			}
			if carrier >= 0 {
				append(&active[carrier].paths, ..b.paths[:])
			} else {
				for index in b.paths {dead_paths[index] = true}
			}
			b.dead = true
		}
		for i := len(active) - 1; i >= 0; i -= 1 {
			if active[i].dead {unordered_remove(&active, i)}
		}
	}

	// Keep only rings of branches that reached the build plate.
	kept := 0
	for path, index in out_paths {
		if dead_paths[index] {
			delete(path.points, allocator)
			delete(path.line_widths, allocator)
			continue
		}
		out_paths[kept] = path
		kept += 1
	}
	resize(&out_paths, kept)
	total_nodes := u64(kept)

	return Tree_Support_Result{
		paths        = out_paths[:],
		tip_count    = total_tips,
		branch_nodes = total_nodes,
	}
}

// The distance from (x, y) to the nearest edge of any path in `set` and that nearest point, or
// +Inf for an empty set.
@(private = "file")
tree_support_nearest_boundary :: proc(set: polygon.Polygon_Set, x, y: f64) -> (distance, near_x, near_y: f64) {
	best_sq := math.INF_F64
	near_x, near_y = x, y
	for path in set.paths {
		n := int(path.count)
		if n < 2 || path.offset+path.count > u64(len(set.points)) {continue}
		start := int(path.offset)
		prev := set.points[start + n - 1]
		for i in 0..<n {
			cur := set.points[start + i]
			ax, ay := f64(i64(prev.x)), f64(i64(prev.y))
			dx, dy := f64(i64(cur.x)) - ax, f64(i64(cur.y)) - ay
			len_sq := dx*dx + dy*dy
			t := 0.0
			if len_sq > 0 {t = clamp(((x - ax)*dx + (y - ay)*dy) / len_sq, 0.0, 1.0)}
			px, py := ax + t*dx, ay + t*dy
			d_sq := (x - px)*(x - px) + (y - py)*(y - py)
			if d_sq < best_sq {
				best_sq = d_sq
				near_x, near_y = px, py
			}
			prev = cur
		}
	}
	return math.sqrt(best_sq), near_x, near_y
}

// The distance from (x, y) to the nearest edge of any path in `set`, or +Inf for an empty set.
@(private = "file")
tree_support_boundary_distance :: proc(set: polygon.Polygon_Set, x, y: f64) -> f64 {
	best_sq := math.INF_F64
	for path in set.paths {
		n := int(path.count)
		if n < 2 || path.offset+path.count > u64(len(set.points)) {continue}
		start := int(path.offset)
		prev := set.points[start + n - 1]
		for i in 0..<n {
			cur := set.points[start + i]
			ax, ay := f64(i64(prev.x)), f64(i64(prev.y))
			dx, dy := f64(i64(cur.x)) - ax, f64(i64(cur.y)) - ay
			len_sq := dx*dx + dy*dy
			t := 0.0
			if len_sq > 0 {t = clamp(((x - ax)*dx + (y - ay)*dy) / len_sq, 0.0, 1.0)}
			ex, ey := x - (ax + t*dx), y - (ay + t*dy)
			best_sq = min(best_sq, ex*ex + ey*ey)
			prev = cur
		}
	}
	return math.sqrt(best_sq)
}
