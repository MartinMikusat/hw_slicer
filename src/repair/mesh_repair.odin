package repair

import "base:runtime"

import contracts "../contracts"
import formats "../formats"

Mesh_Repair_Stats :: struct {
	degenerate_removed: u32,
	normals_flipped:    u32,
	holes_filled:       u32,
}

// Performs pre-slicing 3D mesh cleanup on a Decoded_Mesh:
// 1. Removes out-of-bounds and degenerate/zero-area triangles.
// 2. Makes face orientation consistent across shared edges and turns each component outward.
mesh_auto_repair :: proc(mesh: ^formats.Decoded_Mesh, allocator := context.allocator) -> Mesh_Repair_Stats {
	if mesh == nil || len(mesh.triangle_a) == 0 {return {}}
	stats := Mesh_Repair_Stats{}

	nverts := u32(min(len(mesh.vertex_x), min(len(mesh.vertex_y), len(mesh.vertex_z))))
	nt := len(mesh.triangle_a)

	// Step 1: Drop out-of-bounds and degenerate / zero-area triangles.
	// Fast path: scan first and allocate only when at least one triangle is dropped.
	for i in 0..<nt {
		ia, ib, ic := mesh.triangle_a[i], mesh.triangle_b[i], mesh.triangle_c[i]
		if ia >= nverts || ib >= nverts || ic >= nverts || ia == ib || ib == ic || ic == ia {
			stats.degenerate_removed += 1
			continue
		}
		ux := mesh.vertex_x[ib] - mesh.vertex_x[ia]
		uy := mesh.vertex_y[ib] - mesh.vertex_y[ia]
		uz := mesh.vertex_z[ib] - mesh.vertex_z[ia]
		vx := mesh.vertex_x[ic] - mesh.vertex_x[ia]
		vy := mesh.vertex_y[ic] - mesh.vertex_y[ia]
		vz := mesh.vertex_z[ic] - mesh.vertex_z[ia]
		nx := uy*vz - uz*vy
		ny := uz*vx - ux*vz
		nz := ux*vy - uy*vx
		if nx*nx + ny*ny + nz*nz < 1e-18 {
			stats.degenerate_removed += 1
		}
	}

	if stats.degenerate_removed > 0 {
		kept := nt - int(stats.degenerate_removed)
		keep_a := make([]u32, kept, allocator)
		keep_b := make([]u32, kept, allocator)
		keep_c := make([]u32, kept, allocator)
		keep_ids := make([]contracts.Stable_ID, kept, allocator)
		keep_off := make([]u64, kept, allocator)
		w := 0
		for i in 0..<nt {
			ia, ib, ic := mesh.triangle_a[i], mesh.triangle_b[i], mesh.triangle_c[i]
			if ia >= nverts || ib >= nverts || ic >= nverts || ia == ib || ib == ic || ic == ia {
				continue
			}
			ux := mesh.vertex_x[ib] - mesh.vertex_x[ia]
			uy := mesh.vertex_y[ib] - mesh.vertex_y[ia]
			uz := mesh.vertex_z[ib] - mesh.vertex_z[ia]
			vx := mesh.vertex_x[ic] - mesh.vertex_x[ia]
			vy := mesh.vertex_y[ic] - mesh.vertex_y[ia]
			vz := mesh.vertex_z[ic] - mesh.vertex_z[ia]
			nx := uy*vz - uz*vy
			ny := uz*vx - ux*vz
			nz := ux*vy - uy*vx
			if nx*nx + ny*ny + nz*nz < 1e-18 {
				continue
			}
			keep_a[w] = ia
			keep_b[w] = ib
			keep_c[w] = ic
			keep_ids[w] = mesh.triangle_ids[i]
			keep_off[w] = mesh.source_record_offsets[i]
			w += 1
		}
		delete(mesh.triangle_a, allocator)
		delete(mesh.triangle_b, allocator)
		delete(mesh.triangle_c, allocator)
		delete(mesh.triangle_ids, allocator)
		delete(mesh.source_record_offsets, allocator)
		mesh.triangle_a = keep_a
		mesh.triangle_b = keep_b
		mesh.triangle_c = keep_c
		mesh.triangle_ids = keep_ids
		mesh.source_record_offsets = keep_off
	}

	// Step 2: Make face orientation consistent. Vertices are matched by exact coordinates (STL
	// gives every triangle its own vertices). Orientation propagates across edges shared by
	// exactly two faces; each component is then turned outward (signed volume for nearly closed
	// components, the top face's normal otherwise).
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	face_count := len(mesh.triangle_a)
	if face_count == 0 {return stats}

	next_pow2 :: proc(n: int) -> int {
		p := 16
		for p < n {p <<= 1}
		return p
	}

	vcap := next_pow2(int(nverts) * 2)
	vmask := u64(vcap - 1)
	vtable := make([]u32, vcap, context.temp_allocator) // 0 = empty, id+1 = occupied
	vrep := make([]u32, int(nverts), context.temp_allocator)
	weld := make([]u32, int(nverts), context.temp_allocator)
	unique_verts := u32(0)
	for v in 0..<int(nverts) {
		x, y, z := mesh.vertex_x[v], mesh.vertex_y[v], mesh.vertex_z[v]
		cx := 0.0 if x == 0 else x
		cy := 0.0 if y == 0 else y
		cz := 0.0 if z == 0 else z
		h := transmute(u64)cx * 0x9e3779b97f4a7c15
		h ~= transmute(u64)cy * 0xbf58476d1ce4e5b9
		h ~= transmute(u64)cz * 0x94d049bb133111eb
		h ~= h >> 30
		h *= 0xbf58476d1ce4e5b9
		slot := h & vmask
		for {
			entry := vtable[slot]
			if entry == 0 {
				id := unique_verts
				unique_verts += 1
				vtable[slot] = id + 1
				vrep[id] = u32(v)
				weld[v] = id
				break
			}
			id := entry - 1
			rep := vrep[id]
			if mesh.vertex_x[rep] == x && mesh.vertex_y[rep] == y && mesh.vertex_z[rep] == z {
				weld[v] = id
				break
			}
			slot = (slot + 1) & vmask
		}
	}

	Edge_Slot :: struct {
		key:   u64, // ((u64(lo) << 32) | u64(hi)) + 1; 0 = empty
		face0: u32,
		face1: u32,
		meta:  u32, // low 30 bits = count, bit 30 = dir0, bit 31 = dir1
	}
	DIR0_BIT :: u32(1) << 30
	DIR1_BIT :: u32(1) << 31
	COUNT_MASK :: u32(0x3fff_ffff)

	ecap := next_pow2(max(face_count * 6, 16))
	emask := u64(ecap - 1)
	edges := make([]Edge_Slot, ecap, context.temp_allocator)

	edge_hash :: proc(key: u64) -> u64 {
		h := key * 0x9e3779b97f4a7c15
		return h ~ (h >> 32)
	}
	face_vertices :: proc(mesh: ^formats.Decoded_Mesh, weld: []u32, f: int) -> [3]u32 {
		return {weld[mesh.triangle_a[f]], weld[mesh.triangle_b[f]], weld[mesh.triangle_c[f]]}
	}
	for f in 0..<face_count {
		v := face_vertices(mesh, weld, f)
		for k in 0..<3 {
			a, b := v[k], v[(k+1)%3]
			key := ((u64(min(a, b)) << 32) | u64(max(a, b))) + 1
			slot := edge_hash(key) & emask
			for {
				e := &edges[slot]
				if e.key == 0 {
					e.key = key
					e.face0 = u32(f)
					e.meta = 1 | (DIR0_BIT if a < b else 0)
					break
				}
				if e.key == key {
					cnt := e.meta & COUNT_MASK
					if cnt == 1 {
						e.face1 = u32(f)
						if a < b {e.meta |= DIR1_BIT}
					}
					if cnt < COUNT_MASK {e.meta += 1}
					break
				}
				slot = (slot + 1) & emask
			}
		}
	}
	flip := make([]bool, face_count, context.temp_allocator)
	visited := make([]bool, face_count, context.temp_allocator)
	queue := make([dynamic]u32, 0, 64, context.temp_allocator)
	component := make([dynamic]u32, 0, 64, context.temp_allocator)
	for seed in 0..<face_count {
		if visited[seed] {continue}
		clear(&queue)
		clear(&component)
		visited[seed] = true
		append(&queue, u32(seed))
		edge_total := 0
		boundary_edges := 0
		for head := 0; head < len(queue); head += 1 {
			f := int(queue[head])
			append(&component, u32(f))
			v := face_vertices(mesh, weld, f)
			for k in 0..<3 {
				a, b := v[k], v[(k+1)%3]
				key := ((u64(min(a, b)) << 32) | u64(max(a, b))) + 1
				slot := edge_hash(key) & emask
				for edges[slot].key != key {
					slot = (slot + 1) & emask
				}
				e := edges[slot]
				edge_total += 1
				if (e.meta & COUNT_MASK) != 2 {
					boundary_edges += 1
					continue
				}
				is_face0 := int(e.face0) == f
				g := int(e.face1 if is_face0 else e.face0)
				dir_f := (e.meta & DIR0_BIT) != 0 if is_face0 else (e.meta & DIR1_BIT) != 0
				dir_g := (e.meta & DIR1_BIT) != 0 if is_face0 else (e.meta & DIR0_BIT) != 0
				// Consistent faces run a shared edge in opposite directions.
				g_flip := (dir_f != flip[f]) == dir_g
				if !visited[g] {
					visited[g] = true
					flip[g] = g_flip
					append(&queue, u32(g))
				}
			}
		}
		// Signed volume decides for a nearly closed component. Otherwise (open surfaces, or
		// T-junctions on a small mesh) the face at the component's highest vertex with the
		// steepest normal must face up.
		outward := true
		if boundary_edges*10 <= edge_total {
			vol6 := 0.0
			for f in component {
				ia, ib, ic := mesh.triangle_a[f], mesh.triangle_b[f], mesh.triangle_c[f]
				if flip[f] {ib, ic = ic, ib}
				ax, ay, az := mesh.vertex_x[ia], mesh.vertex_y[ia], mesh.vertex_z[ia]
				bx, by, bz := mesh.vertex_x[ib], mesh.vertex_y[ib], mesh.vertex_z[ib]
				cx, cy, cz := mesh.vertex_x[ic], mesh.vertex_y[ic], mesh.vertex_z[ic]
				vol6 += ax*(by*cz - bz*cy) - ay*(bx*cz - bz*cx) + az*(bx*cy - by*cx)
			}
			outward = vol6 >= 0
		} else {
			top_z := min(f64)
			top_vertex := u32(0)
			for f in component {
				for vi in ([3]u32{mesh.triangle_a[f], mesh.triangle_b[f], mesh.triangle_c[f]}) {
					if mesh.vertex_z[vi] > top_z {
						top_z = mesh.vertex_z[vi]
						top_vertex = weld[vi]
					}
				}
			}
			best_steepness := -1.0
			for f in component {
				v := face_vertices(mesh, weld, int(f))
				if v[0] != top_vertex && v[1] != top_vertex && v[2] != top_vertex {continue}
				ia, ib, ic := mesh.triangle_a[f], mesh.triangle_b[f], mesh.triangle_c[f]
				if flip[f] {ib, ic = ic, ib}
				ux, uy, uz := mesh.vertex_x[ib]-mesh.vertex_x[ia], mesh.vertex_y[ib]-mesh.vertex_y[ia], mesh.vertex_z[ib]-mesh.vertex_z[ia]
				vx, vy, vz := mesh.vertex_x[ic]-mesh.vertex_x[ia], mesh.vertex_y[ic]-mesh.vertex_y[ia], mesh.vertex_z[ic]-mesh.vertex_z[ia]
				nx, ny, nz := uy*vz - uz*vy, uz*vx - ux*vz, ux*vy - uy*vx
				length := nx*nx + ny*ny + nz*nz
				if length <= 0 {continue}
				steepness := nz*nz / length
				if steepness > best_steepness {
					best_steepness = steepness
					outward = nz >= 0
				}
			}
		}
		if !outward {
			for f in component {flip[f] = !flip[f]}
		}
	}
	for f in 0..<face_count {
		if flip[f] {
			mesh.triangle_b[f], mesh.triangle_c[f] = mesh.triangle_c[f], mesh.triangle_b[f]
			stats.normals_flipped += 1
		}
	}

	return stats
}
