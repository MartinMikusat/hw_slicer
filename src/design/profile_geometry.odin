package design

import "core:fmt"
import "core:math"
import "core:mem"
import "core:slice"
import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"

PROFILE_CHORD_MM :: 0.009
PROFILE_INPUT_POINTS :: 8192
PROFILE_PATH_POINTS :: 131072
PROFILE_INSETS :: 4096

Profile_Paths :: struct {
	bounds_min, bounds_max: [2]f64,
	walls:                  [dynamic]polygon.Polygon_Set,
	floor_lines:            [dynamic][2][2]f64,
}

destroy_profile_paths :: proc(paths: ^Profile_Paths, allocator: mem.Allocator) {
	for &wall in paths.walls {polygon.polygon_set_destroy(&wall, allocator)}
	delete(paths.walls)
	delete(paths.floor_lines)
	paths^ = {}
}

@(private)
profile_dot :: proc(a, b: [2]f64) -> f64 {
	return a.x*b.x+a.y*b.y
}

@(private)
closest_on_profile_segment :: proc(p, a, b: [2]f64) -> [2]f64 {
	d := b-a
	length2 := profile_dot(d, d)
	if length2 == 0 {return a}
	return a+d*clamp(profile_dot(p-a, d)/length2, 0, 1)
}

flatten_profile_segment :: proc(a, b: Bezier_Anchor, points: ^[dynamic][2]f64) -> bool {
	from, to := anchor_controls(a), anchor_controls(b)
	return flatten_cubic(from[0], from[0]+from[2], to[0]+to[1], to[0], 0, points)
}

@(private)
flatten_cubic :: proc(a, b, c, d: [2]f64, depth: int, points: ^[dynamic][2]f64) -> bool {
	if len(points^) >= PROFILE_INPUT_POINTS {return false}
	db := b-closest_on_profile_segment(b, a, d)
	dc := c-closest_on_profile_segment(c, a, d)
	if max(profile_dot(db, db), profile_dot(dc, dc)) <= PROFILE_CHORD_MM*PROFILE_CHORD_MM {
		append(points, d)
		return true
	}
	if depth == 20 {return false}
	ab, bc, cd := (a+b)*0.5, (b+c)*0.5, (c+d)*0.5
	abc, bcd := (ab+bc)*0.5, (bc+cd)*0.5
	mid := (abc+bcd)*0.5
	return flatten_cubic(a, ab, abc, mid, depth+1, points) &&
	       flatten_cubic(mid, bcd, cd, d, depth+1, points)
}

@(private)
profile_mm :: proc(p: polygon.Polygon_Point) -> [2]f64 {
	return {f64(p.x)*0.001, f64(p.y)*0.001}
}

@(private)
profile_ring :: proc(set: polygon.Polygon_Set, idx: int) -> []polygon.Polygon_Point {
	path := set.paths[idx]
	return set.points[path.offset:path.offset+path.count]
}

@(private)
profile_cross :: proc(a, b, c: polygon.Polygon_Point) -> i128 {
	return i128(b.x-a.x)*i128(c.y-a.y)-i128(b.y-a.y)*i128(c.x-a.x)
}

@(private)
profile_inside :: proc(p: polygon.Polygon_Point, ring: []polygon.Polygon_Point) -> bool {
	inside := false
	a := ring[len(ring)-1]
	for b in ring {
		if (a.y > p.y) != (b.y > p.y) && ((profile_cross(a, b, p) > 0) == (b.y > a.y)) {
			inside = !inside
		}
		a = b
	}
	return inside
}

@(private)
Profile_Edge :: struct {
	a, b: polygon.Polygon_Point,
	loop, index: int,
}

@(private)
profile_edges_intersect :: proc(e, f: Profile_Edge) -> (hit: bool, xy: [2]f64) {
	a, b, c, d := e.a, e.b, f.a, f.b
	if max(a.y, b.y) < min(c.y, d.y) || max(c.y, d.y) < min(a.y, b.y) ||
	   max(a.x, b.x) < min(c.x, d.x) || max(c.x, d.x) < min(a.x, b.x) {return}
	abc, abd := profile_cross(a, b, c), profile_cross(a, b, d)
	cda, cdb := profile_cross(c, d, a), profile_cross(c, d, b)
	if (abc > 0 && abd > 0) || (abc < 0 && abd < 0) ||
	   (cda > 0 && cdb > 0) || (cda < 0 && cdb < 0) {return}
	if cda != cdb {
		return true, profile_mm(a)+(profile_mm(b)-profile_mm(a))*(f64(cda)/f64(cda-cdb))
	}
	for p in ([2]polygon.Polygon_Point{a, b}) {
		if min(c.x, d.x) <= p.x && p.x <= max(c.x, d.x) && min(c.y, d.y) <= p.y && p.y <= max(c.y, d.y) {
			return true, profile_mm(p)
		}
	}
	return true, profile_mm(c)
}

@(private)
profile_geometry_error :: proc(loop: Bezier_Loop, xy: [2]f64, reason: string, allocator: mem.Allocator) -> Error {
	message := fmt.aprintf("loop '%s' at local (%.3f, %.3f) mm: %s", loop.name, xy.x, xy.y, reason, allocator = allocator)
	return {line = loop.line, position = xy, message = message}
}

@(private)
validate_profile_region :: proc(profile: ^Bezier_Profile, set: polygon.Polygon_Set, allocator: mem.Allocator) -> Error {
	edges := make([dynamic]Profile_Edge, 0, len(set.points), allocator)
	defer delete(edges)
	for _, i in set.paths {
		ring := profile_ring(set, i)
		for a, j in ring {
			b := ring[(j+1)%len(ring)]
			c := ring[(j+2)%len(ring)]
			if profile_cross(a, b, c) == 0 &&
			   i128(b.x-a.x)*i128(c.x-b.x)+i128(b.y-a.y)*i128(c.y-b.y) <= 0 {
				return profile_geometry_error(profile.loops[i], profile_mm(b), "outline doubles back", allocator)
			}
			append(&edges, Profile_Edge{a, b, i, j})
		}
	}
	slice.sort_by(edges[:], proc(a, b: Profile_Edge)->bool {return min(a.a.x, a.b.x) < min(b.a.x, b.b.x)})
	for e, i in edges {
		for f in edges[i+1:] {
			if min(f.a.x, f.b.x) > max(e.a.x, e.b.x) {break}
			if e.loop == f.loop {
				gap := abs(e.index-f.index)
				if gap == 1 || gap == int(set.paths[e.loop].count)-1 {continue}
			}
			if hit, xy := profile_edges_intersect(e, f); hit {
				reason := fmt.tprintf("touches or crosses loop '%s'", profile.loops[f.loop].name)
				return profile_geometry_error(profile.loops[e.loop], xy, reason, allocator)
			}
		}
	}
	for i in 1..<len(set.paths) {
		p := profile_ring(set, i)[0]
		if !profile_inside(p, profile_ring(set, 0)) {
			return profile_geometry_error(profile.loops[i], profile_mm(p), "hole is outside the outer loop", allocator)
		}
		for j in 1..<len(set.paths) {
			if i != j && profile_inside(p, profile_ring(set, j)) {
				return profile_geometry_error(profile.loops[i], profile_mm(p), "hole is inside another hole", allocator)
			}
		}
	}
	return {}
}

@(private)
flatten_profile_region :: proc(profile: ^Bezier_Profile, points: ^[dynamic]polygon.Polygon_Point,
	rings: ^[dynamic]polygon.Polygon_Path, allocator: mem.Allocator) -> Error {
	flattened := make([dynamic][2]f64, allocator)
	defer delete(flattened)
	for loop, li in profile.loops {
		start := len(points^)
		if len(loop.anchors) == 0 {return profile_geometry_error(loop, {}, "loop needs anchors", allocator)}
		for a, i in loop.anchors {
			b := loop.anchors[(i+1)%len(loop.anchors)]
			start_xy := anchor_controls(a)[0]
			start_x, x_error := geometry.millimetres_to_micrometres(contracts.Millimetres(start_xy.x))
			start_y, y_error := geometry.millimetres_to_micrometres(contracts.Millimetres(start_xy.y))
			if x_error != .None || y_error != .None {
				return profile_geometry_error(loop, start_xy, "anchor is outside the geometry range", allocator)
			}
			start_point := polygon.Polygon_Point{start_x, start_y}
			has_length := false
			clear(&flattened)
			if !flatten_profile_segment(a, b, &flattened) {
				return profile_geometry_error(loop, anchor_controls(a)[0], "curve exceeds the subdivision limit", allocator)
			}
			for p in flattened {
				x, xe := geometry.millimetres_to_micrometres(contracts.Millimetres(p.x))
				y, ye := geometry.millimetres_to_micrometres(contracts.Millimetres(p.y))
				if xe != .None || ye != .None {return profile_geometry_error(loop, p, "coordinate is outside the geometry range", allocator)}
				q := polygon.Polygon_Point{x, y}
				if q != start_point {has_length = true}
				if len(points^) == start || points^[len(points^)-1] != q {append(points, q)}
				if len(points^) > PROFILE_INPUT_POINTS {return profile_geometry_error(loop, p, "profile exceeds the point limit", allocator)}
			}
			if !has_length {
				reason := fmt.tprintf("segment from '%s' to '%s' collapses on the micrometre grid", a.name, b.name)
				return profile_geometry_error(loop, start_xy, reason, allocator)
			}
		}
		if len(points^)-start >= 2 && points^[start] == points^[len(points^)-1] {pop(points)}
		ring := points^[start:]
		if len(ring) < 3 {return profile_geometry_error(loop, anchor_controls(loop.anchors[0])[0], "loop collapses on the micrometre grid", allocator)}
		area := polygon.polygon_path_area_2(ring)
		if (li == 0 && area < 0) || (li > 0 && area > 0) {slice.reverse(ring)}
		append(rings, polygon.Polygon_Path{u64(start), u64(len(ring))})
	}
	return {}
}

@(private)
Profile_Edge_Block :: struct {
	low, high: [2]f64,
	first, end: int,
	left, right: int,
}

@(private)
profile_edge_tree :: proc(nodes: ^[dynamic]Profile_Edge_Block, ring: []polygon.Polygon_Point, first, end: int) -> int {
	node := Profile_Edge_Block{first = first, end = end}
	if end-first <= 8 {
		node.low = profile_mm(ring[first])
		node.high = node.low
		for i in first+1..=end {
			xy := profile_mm(ring[i%len(ring)])
			for axis in 0..<2 {
				node.low[axis] = min(node.low[axis], xy[axis])
				node.high[axis] = max(node.high[axis], xy[axis])
			}
		}
	} else {
		middle := first+(end-first)/2
		node.left = profile_edge_tree(nodes, ring, first, middle)
		node.right = profile_edge_tree(nodes, ring, middle, end)
		a, b := nodes^[node.left], nodes^[node.right]
		for axis in 0..<2 {
			node.low[axis] = min(a.low[axis], b.low[axis])
			node.high[axis] = max(a.high[axis], b.high[axis])
		}
	}
	append(nodes, node)
	return len(nodes^)-1
}

@(private)
profile_block_distance2 :: proc(xy: [2]f64, block: Profile_Edge_Block) -> f64 {
	delta := [2]f64{
		max(0, block.low.x-xy.x, xy.x-block.high.x),
		max(0, block.low.y-xy.y, xy.y-block.high.y),
	}
	return profile_dot(delta, delta)
}

@(private)
Profile_Gap :: struct {
	distance2: f64,
	point, projection: [2]f64,
	visits: int,
}

@(private)
closest_profile_block :: proc(xy: [2]f64, ring: []polygon.Polygon_Point, nodes: []Profile_Edge_Block,
	index: int, best: ^Profile_Gap) {
	node := nodes[index]
	if best.visits >= 1_000_000 || profile_block_distance2(xy, node) >= best.distance2 {return}
	best.visits += 1
	if node.end-node.first > 8 {
		near, far := node.left, node.right
		if profile_block_distance2(xy, nodes[far]) < profile_block_distance2(xy, nodes[near]) {
			near, far = far, near
		}
		closest_profile_block(xy, ring, nodes, near, best)
		closest_profile_block(xy, ring, nodes, far, best)
		return
	}
	for i in node.first..<node.end {
		projection := closest_on_profile_segment(xy, profile_mm(ring[i]), profile_mm(ring[(i+1)%len(ring)]))
		diff := xy-projection
		distance2 := profile_dot(diff, diff)
		if distance2 < best.distance2 {
			best.distance2 = distance2
			best.point = xy
			best.projection = projection
		}
	}
}

@(private)
closest_profile_gap :: proc(a, b: []polygon.Polygon_Point, allocator: mem.Allocator) -> Profile_Gap {
	best := Profile_Gap{distance2 = max(f64)}
	nodes := make([dynamic]Profile_Edge_Block, allocator)
	defer delete(nodes)
	for pass in 0..<2 {
		points, edges := a, b
		if pass == 1 {points, edges = b, a}
		clear(&nodes)
		root := profile_edge_tree(&nodes, edges, 0, len(edges))
		for p in points {
			closest_profile_block(profile_mm(p), edges, nodes[:], root, &best)
			if best.visits >= 1_000_000 {return best}
		}
	}
	return best
}

@(private)
profile_gap_location :: proc(a, b: []polygon.Polygon_Point, allocator: mem.Allocator) -> [2]f64 {
	gap := closest_profile_gap(a, b, allocator)
	return (gap.point+gap.projection)*0.5
}

@(private)
validate_profile_first_wall :: proc(profile: ^Bezier_Profile, source, wall: polygon.Polygon_Set,
	allocator: mem.Allocator) -> Error {
	outer := -1
	for _, i in wall.paths {
		ring := profile_ring(wall, i)
		if polygon.polygon_path_area_2(ring) <= 0 {continue}
		if outer >= 0 {
			loc := profile_gap_location(profile_ring(wall, outer), ring, allocator)
			return profile_geometry_error(profile.loops[0], loc, "first bead cannot pass through the waist", allocator)
		}
		outer = i
	}
	if outer < 0 {
		return profile_geometry_error(profile.loops[0], profile_mm(source.points[0]), "no full-width bead fits", allocator)
	}
	owners := make([]int, len(wall.paths), allocator)
	defer delete(owners)
	for i in 1..<len(source.paths) {
		ring := profile_ring(source, i)
		hole := -1
		for _, j in wall.paths {
			if j != outer && profile_inside(ring[0], profile_ring(wall, j)) {
				hole = j
				break
			}
		}
		if hole < 0 {
			loc := profile_gap_location(ring, profile_ring(source, 0), allocator)
			return profile_geometry_error(profile.loops[i], loc, "first bead cannot separate hole from the outer boundary", allocator)
		}
		if owners[hole] != 0 {
			loc := profile_gap_location(ring, profile_ring(source, owners[hole]), allocator)
			return profile_geometry_error(profile.loops[i], loc, "first bead cannot pass between holes", allocator)
		}
		owners[hole] = i
	}
	return {}
}

@(private)
Profile_Scan_Crossing :: struct {
	row: int,
	x:   f64,
}

@(private)
profile_floor_lines :: proc(paths: ^Profile_Paths, line_width: f64, allocator: mem.Allocator) -> bool {
	domain := paths.walls[0]
	low, high := max(f64), -max(f64)
	for p in domain.points {
		y := profile_mm(p).y
		low = min(low, y)
		high = max(high, y)
	}
	row_count := max(1, math.ceil((high-low)/line_width))
	if row_count > PROFILE_INSETS {return false}
	rows := int(row_count)
	pitch := (high-low)/f64(rows)
	crossings := make([dynamic]Profile_Scan_Crossing, allocator)
	defer delete(crossings)
	for _, r in domain.paths {
		ring := profile_ring(domain, r)
		previous := profile_mm(ring[len(ring)-1])
		for p in ring {
			a, b := previous, profile_mm(p)
			previous = b
			if a.y == b.y {continue}
			if a.y > b.y {a, b = b, a}
			first := clamp(int(math.floor((a.y-low)/pitch-0.5)), 0, rows)
			end := clamp(int(math.ceil((b.y-low)/pitch-0.5))+1, 0, rows)
			for row in first..<end {
				y := low+(f64(row)+0.5)*pitch
				if y < a.y || y >= b.y {continue}
				if len(crossings) >= PROFILE_PATH_POINTS {return false}
				x := a.x+(b.x-a.x)*(y-a.y)/(b.y-a.y)
				append(&crossings, Profile_Scan_Crossing{row, x})
			}
		}
	}
	slice.sort_by(crossings[:], proc(a, b: Profile_Scan_Crossing) -> bool {
		if a.row != b.row {return a.row < b.row}
		return a.x < b.x if a.row%2 == 0 else a.x > b.x
	})
	if len(crossings)%2 != 0 {return false}
	for i := 0; i < len(crossings); i += 2 {
		a, b := crossings[i], crossings[i+1]
		if a.row != b.row {return false}
		if abs(b.x-a.x) < 0.001 {continue}
		y := low+(f64(a.row)+0.5)*pitch
		append(&paths.floor_lines, [2][2]f64{{a.x, y}, {b.x, y}})
	}
	return true
}

prepare_profile_paths :: proc(profile: ^Bezier_Profile, line_width: f64, walls, floor: int,
	allocator: mem.Allocator) -> Error {
	assert(profile != nil)
	if len(profile.loops) == 0 {
		return {line = profile.line, message = fmt.aprintf("profile '%s' needs an outer loop", profile.name, allocator = allocator)}
	}
	outer := profile.loops[0]
	if walls < 1 || walls > PROFILE_INSETS || !(line_width >= 0.002 && line_width <= 1000000.0) {
		return profile_geometry_error(outer, {}, "wall count or bead width is outside the offset limits", allocator)
	}
	points := make([dynamic]polygon.Polygon_Point, allocator)
	defer delete(points)
	rings := make([dynamic]polygon.Polygon_Path, allocator)
	defer delete(rings)
	if err := flatten_profile_region(profile, &points, &rings, allocator); err.message != "" {return err}
	source := polygon.Polygon_Set{points[:], rings[:]}
	if err := validate_profile_region(profile, source, allocator); err.message != "" {return err}

	built := Profile_Paths{
		walls = make([dynamic]polygon.Polygon_Set, allocator),
		floor_lines = make([dynamic][2][2]f64, allocator),
		bounds_min = profile_mm(points[0]),
		bounds_max = profile_mm(points[0]),
	}
	defer destroy_profile_paths(&built, allocator)
	for p in points {
		xy := profile_mm(p)
		for axis in 0..<2 {
			built.bounds_min[axis] = min(built.bounds_min[axis], xy[axis])
			built.bounds_max[axis] = max(built.bounds_max[axis], xy[axis])
		}
	}
	limits := polygon.Polygon_Limits{PROFILE_INPUT_POINTS, PROFILE_INPUT_POINTS/3, PROFILE_PATH_POINTS, PROFILE_PATH_POINTS/3}
	point_count := 0
	for band in 0..<walls {
		inset := contracts.Micrometres(math.round((0.5+f64(band))*line_width*1000))
		wall, err := polygon.clipper2_offset(source, -inset, .Round, 2, 1, limits, allocator)
		if err != .None {
			return profile_geometry_error(outer, built.bounds_min, fmt.tprintf("polygon offset failed (%v)", err), allocator)
		}
		if band == 0 {
			if issue := validate_profile_first_wall(profile, source, wall, allocator); issue.message != "" {
				polygon.polygon_set_destroy(&wall, allocator)
				return issue
			}
		}
		if len(wall.paths) == 0 {break}
		append(&built.walls, wall)
		point_count += len(wall.points)
		if point_count > PROFILE_PATH_POINTS {return profile_geometry_error(outer, built.bounds_min, "wall point limit exceeded", allocator)}
	}
	if floor > 0 && !profile_floor_lines(&built, line_width, allocator) {
		return profile_geometry_error(outer, built.bounds_min, "solid floor exceeds the scanline limits", allocator)
	}
	destroy_profile_paths(&profile.paths, allocator)
	profile.paths = built
	built = {}
	return {}
}

profile_layer_move_bound :: proc(paths: ^Profile_Paths, floor: bool) -> int {
	count := 0
	for wall, i in paths.walls {
		if floor && i > 0 {break}
		count += len(wall.points)+len(wall.paths)
	}
	if floor {count += 2*len(paths.floor_lines)}
	return count
}

@(private)
emit_profile_layer :: proc(g: ^Generator, object: Object, solid: bool) {
	paths := &object.profile.paths
	for wall, i in paths.walls {
		if solid && i > 0 {break}
		for _, j in wall.paths {
			ring := profile_ring(wall, j)
			start := object.center+profile_mm(ring[0])
			travel(g, start)
			for p in ring[1:] {extrude(g, object.center+profile_mm(p))}
			extrude(g, start)
		}
	}
	if solid {
		for line in paths.floor_lines {
			travel(g, object.center+line[0])
			extrude(g, object.center+line[1])
		}
	}
}
