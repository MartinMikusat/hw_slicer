package pipeline

import "core:math"
import "core:slice"

import contracts "../contracts"
import formats "../formats"
import profiles "../profiles"

Plate_Transform :: struct {
	scale_x:   f64,
	scale_y:   f64,
	scale_z:   f64,
	rot_x_deg: f64,
	rot_y_deg: f64,
	rot_z_deg: f64,
	trans_x:   f64,
	trans_y:   f64,
	lay_flat:  bool,
}

DEFAULT_PLATE_TRANSFORM :: Plate_Transform{
	scale_x = 1.0,
	scale_y = 1.0,
	scale_z = 1.0,
}

Plate_Object :: struct {
	name:      string,
	mesh:      formats.Decoded_Mesh,
	transform: Plate_Transform,
	min_x:     f64,
	max_x:     f64,
	min_y:     f64,
	max_y:     f64,
	min_z:     f64,
	max_z:     f64,
}

plate_object_clone :: proc(src: Plate_Object, new_name: string, allocator := context.allocator) -> Plate_Object {
	nv := len(src.mesh.vertex_x)
	nt := len(src.mesh.triangle_a)
	dst := Plate_Object{
		name      = new_name,
		transform = src.transform,
		min_x     = src.min_x,
		max_x     = src.max_x,
		min_y     = src.min_y,
		max_y     = src.max_y,
		min_z     = src.min_z,
		max_z     = src.max_z,
		mesh      = formats.Decoded_Mesh{
			source                = src.mesh.source,
			source_root_id        = src.mesh.source_root_id,
			vertex_x              = make([]f64, nv, allocator),
			vertex_y              = make([]f64, nv, allocator),
			vertex_z              = make([]f64, nv, allocator),
			vertex_ids            = make([]contracts.Stable_ID, nv, allocator),
			triangle_a            = make([]u32, nt, allocator),
			triangle_b            = make([]u32, nt, allocator),
			triangle_c            = make([]u32, nt, allocator),
			triangle_ids          = make([]contracts.Stable_ID, nt, allocator),
			source_record_offsets = make([]u64, nt, allocator),
		},
	}
	copy(dst.mesh.vertex_x, src.mesh.vertex_x)
	copy(dst.mesh.vertex_y, src.mesh.vertex_y)
	copy(dst.mesh.vertex_z, src.mesh.vertex_z)
	copy(dst.mesh.vertex_ids, src.mesh.vertex_ids)
	copy(dst.mesh.triangle_a, src.mesh.triangle_a)
	copy(dst.mesh.triangle_b, src.mesh.triangle_b)
	copy(dst.mesh.triangle_c, src.mesh.triangle_c)
	copy(dst.mesh.triangle_ids, src.mesh.triangle_ids)
	copy(dst.mesh.source_record_offsets, src.mesh.source_record_offsets)
	return dst
}

plate_object_compute_bounds :: proc(obj: ^Plate_Object) {
	if len(obj.mesh.vertex_x) == 0 {return}
	min_x, max_x := obj.mesh.vertex_x[0], obj.mesh.vertex_x[0]
	min_y, max_y := obj.mesh.vertex_y[0], obj.mesh.vertex_y[0]
	min_z, max_z := obj.mesh.vertex_z[0], obj.mesh.vertex_z[0]
	for i in 1..<len(obj.mesh.vertex_x) {
		x, y, z := obj.mesh.vertex_x[i], obj.mesh.vertex_y[i], obj.mesh.vertex_z[i]
		if x < min_x {min_x = x}
		if x > max_x {max_x = x}
		if y < min_y {min_y = y}
		if y > max_y {max_y = y}
		if z < min_z {min_z = z}
		if z > max_z {max_z = z}
	}
	obj.min_x, obj.max_x = min_x, max_x
	obj.min_y, obj.max_y = min_y, max_y
	obj.min_z, obj.max_z = min_z, max_z
}

// Applies Scale, Euler XYZ rotation, optional Lay-on-Flattest-Face alignment, and Z=0 drop.
plate_object_apply_transform :: proc(obj: ^Plate_Object) {
	n := len(obj.mesh.vertex_x)
	if n == 0 {return}
	t := obj.transform
	sx := t.scale_x if t.scale_x > 0 else 1.0
	sy := t.scale_y if t.scale_y > 0 else 1.0
	sz := t.scale_z if t.scale_z > 0 else 1.0

	rx := t.rot_x_deg * math.PI / 180.0
	ry := t.rot_y_deg * math.PI / 180.0
	rz := t.rot_z_deg * math.PI / 180.0
	cx, sx_r := math.cos(rx), math.sin(rx)
	cy, sy_r := math.cos(ry), math.sin(ry)
	cz, sz_r := math.cos(rz), math.sin(rz)

	for i in 0..<n {
		x := obj.mesh.vertex_x[i] * sx
		y := obj.mesh.vertex_y[i] * sy
		z := obj.mesh.vertex_z[i] * sz
		// Rotate X
		if rx != 0 {
			y1 := y*cx - z*sx_r
			z1 := y*sx_r + z*cx
			y, z = y1, z1
		}
		// Rotate Y
		if ry != 0 {
			x1 := x*cy + z*sy_r
			z1 := -x*sy_r + z*cy
			x, z = x1, z1
		}
		// Rotate Z
		if rz != 0 {
			x1 := x*cz - y*sz_r
			y1 := x*sz_r + y*cz
			x, y = x1, y1
		}
		obj.mesh.vertex_x[i] = x
		obj.mesh.vertex_y[i] = y
		obj.mesh.vertex_z[i] = z
	}

	if t.lay_flat {
		plate_object_lay_flat(obj)
	}

	plate_object_compute_bounds(obj)
	// Drop object cleanly onto Z = 0 and apply XY translation.
	dz := -obj.min_z
	for i in 0..<n {
		obj.mesh.vertex_x[i] += t.trans_x
		obj.mesh.vertex_y[i] += t.trans_y
		obj.mesh.vertex_z[i] += dz
	}
	plate_object_compute_bounds(obj)
}

// Finds the largest-area planar face normal and rotates it to point straight down (0, 0, -1).
@(private = "file")
plate_object_lay_flat :: proc(obj: ^Plate_Object) {
	if len(obj.mesh.triangle_a) == 0 {return}
	best_area := 0.0
	best_n := [3]f64{0, 0, -1}
	for ti in 0..<len(obj.mesh.triangle_a) {
		ia, ib, ic := obj.mesh.triangle_a[ti], obj.mesh.triangle_b[ti], obj.mesh.triangle_c[ti]
		ux := obj.mesh.vertex_x[ib] - obj.mesh.vertex_x[ia]
		uy := obj.mesh.vertex_y[ib] - obj.mesh.vertex_y[ia]
		uz := obj.mesh.vertex_z[ib] - obj.mesh.vertex_z[ia]
		vx := obj.mesh.vertex_x[ic] - obj.mesh.vertex_x[ia]
		vy := obj.mesh.vertex_y[ic] - obj.mesh.vertex_y[ia]
		vz := obj.mesh.vertex_z[ic] - obj.mesh.vertex_z[ia]
		nx := uy*vz - uz*vy
		ny := uz*vx - ux*vz
		nz := ux*vy - uy*vx
		area2 := math.sqrt(nx*nx + ny*ny + nz*nz)
		if area2 > best_area {
			best_area = area2
			best_n = {nx / area2, ny / area2, nz / area2}
		}
	}
	if best_area <= 1e-9 {return}
	// Rodrigues rotation from best_n to (0, 0, -1).
	// cross(best_n, (0,0,-1)) = (-best_n.y, best_n.x, 0), dot = -best_n.z.
	dot := -best_n[2]
	if dot > 0.9999 {return}
	if dot < -0.9999 {
		// 180 deg flip around X axis.
		for i in 0..<len(obj.mesh.vertex_y) {
			obj.mesh.vertex_y[i] = -obj.mesh.vertex_y[i]
			obj.mesh.vertex_z[i] = -obj.mesh.vertex_z[i]
		}
		return
	}
	kx := -best_n[1]
	ky := best_n[0]
	klen := math.hypot(kx, ky)
	if klen < 1e-9 {return}
	kx /= klen
	ky /= klen
	ang := math.acos(clamp(dot, -1.0, 1.0))
	ca, sa := math.cos(ang), math.sin(ang)
	one_c := 1.0 - ca
	for i in 0..<len(obj.mesh.vertex_x) {
		x, y, z := obj.mesh.vertex_x[i], obj.mesh.vertex_y[i], obj.mesh.vertex_z[i]
		// k = (kx, ky, 0)
		kd := kx*x + ky*y
		cx_v := ky*z
		cy_v := -kx*z
		cz_v := kx*y - ky*x
		obj.mesh.vertex_x[i] = x*ca + cx_v*sa + kx*kd*one_c
		obj.mesh.vertex_y[i] = y*ca + cy_v*sa + ky*kd*one_c
		obj.mesh.vertex_z[i] = z*ca + cz_v*sa
	}
}

// Deterministic 2D shelf-packing auto-arrange centered on the printer's build plate.
plate_auto_arrange :: proc(
	objects: []Plate_Object,
	printer: profiles.Printer_Profile,
	gap_mm := 8.0,
) -> bool {
	if len(objects) == 0 {return true}
	bed_w := f64(i64(printer.axis_maximum_x) - i64(printer.axis_minimum_x)) / 1000.0
	bed_d := f64(i64(printer.axis_maximum_y) - i64(printer.axis_minimum_y)) / 1000.0
	bed_cx := f64(i64(printer.axis_minimum_x) + i64(printer.axis_maximum_x)) / 2000.0
	bed_cy := f64(i64(printer.axis_minimum_y) + i64(printer.axis_maximum_y)) / 2000.0

	order := make([]int, len(objects), context.temp_allocator)
	for i in 0..<len(objects) {
		plate_object_compute_bounds(&objects[i])
		order[i] = i
	}
	slice.sort_by(order, proc(a, b: int) -> bool {
		return a < b
	})

	usable_w := max(10.0, bed_w - 20.0)
	cursor_x := 0.0
	cursor_y := 0.0
	row_h := 0.0
	placed_x := make([]f64, len(objects), context.temp_allocator)
	placed_y := make([]f64, len(objects), context.temp_allocator)

	group_max_x := 0.0
	group_max_y := 0.0
	for idx in order {
		obj := &objects[idx]
		w := obj.max_x - obj.min_x
		h := obj.max_y - obj.min_y
		if cursor_x > 0 && cursor_x + w > usable_w {
			cursor_x = 0.0
			cursor_y += row_h + gap_mm
			row_h = 0.0
		}
		placed_x[idx] = cursor_x
		placed_y[idx] = cursor_y
		cursor_x += w + gap_mm
		if h > row_h {row_h = h}
		if cursor_x - gap_mm > group_max_x {group_max_x = cursor_x - gap_mm}
		if cursor_y + h > group_max_y {group_max_y = cursor_y + h}
	}

	if group_max_x > bed_w || group_max_y > bed_d {
		return false
	}

	off_x := bed_cx - group_max_x * 0.5
	off_y := bed_cy - group_max_y * 0.5
	for i in 0..<len(objects) {
		obj := &objects[i]
		dx := off_x + placed_x[i] - obj.min_x
		dy := off_y + placed_y[i] - obj.min_y
		dz := -obj.min_z
		for vi in 0..<len(obj.mesh.vertex_x) {
			obj.mesh.vertex_x[vi] += dx
			obj.mesh.vertex_y[vi] += dy
			obj.mesh.vertex_z[vi] += dz
		}
		plate_object_compute_bounds(obj)
	}
	return true
}

// Merges all positioned Plate_Objects into one unified Decoded_Mesh for slicing.
plate_merge_to_mesh :: proc(
	objects: []Plate_Object,
	allocator := context.allocator,
) -> formats.Decoded_Mesh {
	total_v := 0
	total_t := 0
	for obj in objects {
		total_v += len(obj.mesh.vertex_x)
		total_t += len(obj.mesh.triangle_a)
	}
	base_source := objects[0].mesh.source if len(objects) > 0 else contracts.Source_Asset{units = .Millimetres}
	base_root := objects[0].mesh.source_root_id if len(objects) > 0 else contracts.Stable_ID(1)
	out := formats.Decoded_Mesh{
		source                = base_source,
		source_root_id        = base_root,
		vertex_x              = make([]f64, total_v, allocator),
		vertex_y              = make([]f64, total_v, allocator),
		vertex_z              = make([]f64, total_v, allocator),
		vertex_ids            = make([]contracts.Stable_ID, total_v, allocator),
		triangle_a            = make([]u32, total_t, allocator),
		triangle_b            = make([]u32, total_t, allocator),
		triangle_c            = make([]u32, total_t, allocator),
		triangle_ids          = make([]contracts.Stable_ID, total_t, allocator),
		source_record_offsets = make([]u64, total_t, allocator),
	}
	v_off := 0
	t_off := 0
	for obj in objects {
		nv := len(obj.mesh.vertex_x)
		nt := len(obj.mesh.triangle_a)
		copy(out.vertex_x[v_off:v_off+nv], obj.mesh.vertex_x)
		copy(out.vertex_y[v_off:v_off+nv], obj.mesh.vertex_y)
		copy(out.vertex_z[v_off:v_off+nv], obj.mesh.vertex_z)
		for vi in 0..<nv {
			out.vertex_ids[v_off + vi] = contracts.stable_id_child(base_root, .Vertex, u64(v_off + vi))
		}
		for ti in 0..<nt {
			out.triangle_a[t_off + ti] = obj.mesh.triangle_a[ti] + u32(v_off)
			out.triangle_b[t_off + ti] = obj.mesh.triangle_b[ti] + u32(v_off)
			out.triangle_c[t_off + ti] = obj.mesh.triangle_c[ti] + u32(v_off)
			out.triangle_ids[t_off + ti] = contracts.stable_id_child(base_root, .Triangle, u64(t_off + ti))
			out.source_record_offsets[t_off + ti] = u64(t_off + ti)
		}
		v_off += nv
		t_off += nt
	}
	return out
}
