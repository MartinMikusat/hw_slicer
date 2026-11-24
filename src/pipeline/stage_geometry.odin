package pipeline

import "core:sync"

import contracts "../contracts"
import polygon "../polygon"
import profiles "../profiles"
import slicing "../slicing"

// One straight piece of a stage result, in millimetres. The frame is the slice frame moved so that
// the centre of the model footprint is at the origin and the bed at z = 0, which is the frame the
// viewer draws the model in.
Result_Segment :: struct {
	a, b:        [3]f32,
	owner_stage: Stage_Id,
	feature_id:  contracts.Stable_ID,
	role:        profiles.Printable_Role,
}

@(private = "file")
role_owner_stage :: proc(role: profiles.Printable_Role, fallback: Stage_Id) -> Stage_Id {
	switch role {
	case .Perimeter:                                 return .Perimeters
	case .Bridge:                                    return .Bridges
	case .Top_Skin, .Bottom_Skin, .Top_Bottom_Skin:  return .Solid_Paths
	case .Sparse_Infill:                             return .Sparse_Infill
	case .Gap, .Thin_Wall:                           return .Gap_Fill
	case .Support, .Support_Interface:               return .Supports
	case .Invalid:                                   return fallback
	}
	return fallback
}

// Number of layers in the current layer schedule, or 0 when the schedule has no result.
workspace_layer_count :: proc(w: ^Workspace) -> int {
	s := w.session
	sync.mutex_lock(&s.lock)
	defer sync.mutex_unlock(&s.lock)
	if !session_readable(s, {.Layer_Schedule}) {return 0}
	return len(s.schedule.print_z)
}

// The layer whose section plane is closest to `z_mm`, and the height it prints at.
workspace_layer_at :: proc(w: ^Workspace, z_mm: f32) -> (layer: int, print_z_mm: f32, ok: bool) {
	s := w.session
	sync.mutex_lock(&s.lock)
	defer sync.mutex_unlock(&s.lock)
	if !session_readable(s, {.Layer_Schedule}) || len(s.schedule.layer_z) == 0 {return}
	target := f64(z_mm)*1000
	best := max(f64)
	for plane, index in s.schedule.layer_z {
		distance := abs(f64(plane)-target)
		if distance < best {
			best = distance
			layer = index
		}
	}
	return layer, f32(f64(s.schedule.print_z[layer])/1000), true
}

// Appends the result of one stage on one layer as segments. Returns false, and appends nothing,
// when the stage or a stage whose data it refers to has no readable result, or the stage has no
// planar result (the model).
workspace_stage_segments :: proc(w: ^Workspace, id: Stage_Id, layer: int, out: ^[dynamic]Result_Segment) -> bool {
	s := w.session
	sync.mutex_lock(&s.lock)
	defer sync.mutex_unlock(&s.lock)
	if !session_readable(s, {.Model, .Layer_Schedule, id}) {return false}
	if layer < 0 || layer >= len(s.schedule.print_z) {return false}
	b := s.mesh.bounds
	e := Segment_Emitter{
		out         = out,
		origin      = {f64(b.minimum.x+b.maximum.x)*0.5, f64(b.minimum.y+b.maximum.y)*0.5},
		z           = f32(f64(s.schedule.print_z[layer])/1000),
		owner_stage = id,
	}
	start := len(out)
	switch id {
	case .Model:
		return false
	case .Layer_Schedule:
		lo := [2]f64{f64(b.minimum.x), f64(b.minimum.y)}
		hi := [2]f64{f64(b.maximum.x), f64(b.maximum.y)}
		corners := [4][2]f64{{lo.x, lo.y}, {hi.x, lo.y}, {hi.x, hi.y}, {lo.x, hi.y}}
		for i in 0..<4 {emit_mm(&e, corners[i], corners[(i+1)%4])}
	case .Intersections:
		r := s.snapped
		if layer >= len(r.layers) {return false}
		l := r.layers[layer]
		for i in int(l.offset)..<min(int(l.offset)+int(l.count), len(r.segments.x0)) {
			emit_um(&e, {i64(r.segments.x0[i]), i64(r.segments.y0[i])}, {i64(r.segments.x1[i]), i64(r.segments.y1[i])})
		}
	case .Topology:
		t := session_active_topology(s)
		if layer >= len(t.layers) {return false}
		l := t.layers[layer]
		for p in int(l.path_offset)..<min(int(l.path_offset)+int(l.path_count), len(t.paths)) {
			emit_topology_path(&e, t, t.paths[p])
		}
	case .Regions:
		if !session_readable(s, {.Topology}) {return false}
		t := session_active_topology(s)
		r := s.regions
		if layer >= len(r.layers) {return false}
		l := r.layers[layer]
		for c in int(l.contour_offset)..<min(int(l.contour_offset)+int(l.contour_count), len(r.contours)) {
			path := int(r.contours[c].path_index)
			if path < len(t.paths) {emit_topology_path(&e, t, t.paths[path])}
		}
	case .Surfaces_Skin:
		if layer < len(s.surfaces.layers) {
			l := s.surfaces.layers[layer]
			for p in int(l.path_offset)..<min(int(l.path_offset)+int(l.path_count), len(s.surfaces.paths)) {
				path := s.surfaces.paths[p]
				emit_points(&e, s.surfaces.points, int(path.point_offset), int(path.point_count), true)
			}
		}
		if layer < len(s.skins.layers) {
			l := s.skins.layers[layer]
			for p in int(l.path_offset)..<min(int(l.path_offset)+int(l.path_count), len(s.skins.paths)) {
				path := s.skins.paths[p]
				emit_points(&e, s.skins.points, int(path.point_offset), int(path.point_count), true)
			}
		}
	case .Perimeters:
		r := s.perimeters
		if layer >= len(r.layers) {return false}
		l := r.layers[layer]
		for p in int(l.path_offset)..<min(int(l.path_offset)+int(l.path_count), len(r.paths)) {
			emit_points(&e, r.points, int(r.paths[p].point_offset), int(r.paths[p].point_count), true)
		}
	case .Bridges:
		r := s.bridges
		if layer >= len(r.layers) {return false}
		l := r.layers[layer]
		for p in int(l.path_offset)..<min(int(l.path_offset)+int(l.path_count), len(r.paths)) {
			emit_point_pair(&e, r.paths[p].point_a, r.paths[p].point_b)
		}
	case .Solid_Areas:
		r := s.overlap
		if layer >= len(r.layers) {return false}
		l := r.layers[layer]
		for p in int(l.path_offset)..<min(int(l.path_offset)+int(l.path_count), len(r.paths)) {
			path := r.paths[p]
			emit_points(&e, r.points, int(path.point_offset), int(path.point_count), true)
		}
	case .Solid_Paths:
		r := s.solids
		if layer < len(r.layers) {
			l := r.layers[layer]
			for p in int(l.path_offset)..<min(int(l.path_offset)+int(l.path_count), len(r.paths)) {
				sp := r.paths[p]
				e.feature_id = sp.stable_id
				e.role = sp.role
				emit_point_pair(&e, sp.point_a, sp.point_b)
			}
		}
		for ir in s.ironing.paths {
			if int(ir.layer_index) == layer {
				e.feature_id = {}
				e.role = .Top_Skin
				emit_points(&e, ir.points, 0, len(ir.points), false)
			}
		}
	case .Sparse_Infill:
		if layer < len(s.infill.layers) {
			l := s.infill.layers[layer]
			for i in int(l.segment_offset)..<min(int(l.segment_offset)+int(l.segment_count), len(s.infill.segments)) {
				emit_point_pair(&e, s.infill.segments[i].point_a, s.infill.segments[i].point_b)
			}
		}
		for path in s.pattern_infill.paths {
			if int(path.layer_index) == layer {emit_points(&e, path.points, 0, len(path.points), false)}
		}
	case .Gap_Fill:
		r := s.gaps
		if layer >= len(r.layers) {return false}
		l := r.layers[layer]
		for p in int(l.path_offset)..<min(int(l.path_offset)+int(l.path_count), len(r.paths)) {
			path := r.paths[p]
			first := int(path.vertex_offset)
			last := min(first+int(path.vertex_count), len(r.vertices))
			for v in first+1..<last {emit_point_pair(&e, r.vertices[v-1].point, r.vertices[v].point)}
		}
	case .Supports:
		if layer < len(s.supports.layers) {
			l := s.supports.layers[layer]
			for p in int(l.path_offset)..<min(int(l.path_offset)+int(l.path_count), len(s.supports.paths)) {
				emit_point_pair(&e, s.supports.paths[p].point_a, s.supports.paths[p].point_b)
			}
		}
		for path in s.tree_supports.paths {
			if int(path.layer_index) == layer {
				e.role = .Support_Interface if path.is_interface else .Support
				emit_points(&e, path.points, 0, len(path.points), true)
			}
		}
		for loop in s.adhesion.loops {
			if int(loop.layer_index) == layer {
				e.role = .Perimeter
				emit_points(&e, loop.points, 0, len(loop.points), true)
			}
		}
	case .Path_Plan:
		r := s.unified_plan
		if layer >= len(r.layers) {return false}
		l := r.layers[layer]
		for m in int(l.move_offset)..<min(int(l.move_offset)+int(l.move_count), len(r.moves)) {
			move := r.moves[m]
			if move.kind == .Extrude {
				e.owner_stage = role_owner_stage(move.role, .Path_Plan)
				e.feature_id = move.stable_id
				e.role = move.role
				emit_point_pair(&e, move.point_a, move.point_b)
			}
		}
	case .Motion, .Gcode:
		if !session_readable(s, {.Motion}) {return false}
		for l in s.motion.layers {
			if int(l.layer_index) != layer {continue}
			first := int(l.operation_offset)
			for o in first..<min(first+int(l.operation_count), len(s.motion.operations)) {
				op := s.motion.operations[o]
				if op.kind == .Extrude {
					e.owner_stage = role_owner_stage(op.role, id)
					e.feature_id = op.stable_id
					e.role = op.role
					emit_point_pair(&e, op.point_a, op.point_b)
				}
			}
		}
	}
	return len(out) > start
}

@(private = "file")
Segment_Emitter :: struct {
	out:         ^[dynamic]Result_Segment,
	origin:      [2]f64,
	z:           f32,
	owner_stage: Stage_Id,
	feature_id:  contracts.Stable_ID,
	role:        profiles.Printable_Role,
}

@(private = "file")
emit_mm :: proc(e: ^Segment_Emitter, a, b: [2]f64) {
	append(e.out, Result_Segment{
		a           = {f32(a.x-e.origin.x), f32(a.y-e.origin.y), e.z},
		b           = {f32(b.x-e.origin.x), f32(b.y-e.origin.y), e.z},
		owner_stage = e.owner_stage,
		feature_id  = e.feature_id,
		role        = e.role,
	})
}

@(private = "file")
emit_um :: proc(e: ^Segment_Emitter, a, b: [2]i64) {
	emit_mm(e, {f64(a.x)/1000, f64(a.y)/1000}, {f64(b.x)/1000, f64(b.y)/1000})
}

@(private = "file")
emit_point_pair :: proc(e: ^Segment_Emitter, a, b: polygon.Polygon_Point) {
	emit_um(e, {i64(a.x), i64(a.y)}, {i64(b.x), i64(b.y)})
}

@(private = "file")
emit_points :: proc(e: ^Segment_Emitter, points: []polygon.Polygon_Point, offset, count: int, closed: bool) {
	last := min(offset+count, len(points))
	if last-offset < 2 {return}
	for i in offset+1..<last {emit_point_pair(e, points[i-1], points[i])}
	if closed {emit_point_pair(e, points[last-1], points[offset])}
}

@(private = "file")
emit_topology_path :: proc(e: ^Segment_Emitter, t: slicing.Topology_Result, path: slicing.Topology_Path) {
	first := int(path.vertex_offset)
	last := min(first+int(path.vertex_count), len(t.path_vertex_indices))
	if last-first < 2 {return}
	point :: proc(t: slicing.Topology_Result, index: int) -> [2]i64 {
		v := t.vertices[t.path_vertex_indices[index]].point
		return {i64(v.x), i64(v.y)}
	}
	for i in first+1..<last {emit_um(e, point(t, i-1), point(t, i))}
	if path.kind == .Loop {emit_um(e, point(t, last-1), point(t, first))}
}

// True when every listed stage holds a result that no run is changing. The caller holds the lock.
@(private = "package")
session_readable :: proc(s: ^Slice_Session, ids: Stage_Set) -> bool {
	for id in ids {
		state := s.slots[id].state
		if state != .Complete && state != .Stale {return false}
	}
	return true
}

workspace_stage_readable :: proc(w: ^Workspace, id: Stage_Id) -> bool {
	if w == nil || w.session == nil {return false}
	s := w.session
	sync.mutex_lock(&s.lock)
	defer sync.mutex_unlock(&s.lock)
	return session_readable(s, {id})
}
