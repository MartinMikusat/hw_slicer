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
	keep_a := make([dynamic]u32, 0, nt, allocator)
	keep_b := make([dynamic]u32, 0, nt, allocator)
	keep_c := make([dynamic]u32, 0, nt, allocator)
	keep_ids := make([dynamic]contracts.Stable_ID, 0, nt, allocator)
	keep_off := make([dynamic]u64, 0, nt, allocator)

	// Step 1: Drop out-of-bounds and degenerate / zero-area triangles.
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
			continue
		}
		append(&keep_a, ia)
		append(&keep_b, ib)
		append(&keep_c, ic)
		append(&keep_ids, mesh.triangle_ids[i])
		append(&keep_off, mesh.source_record_offsets[i])
	}

	if stats.degenerate_removed == 0 {
		delete(keep_a)
		delete(keep_b)
		delete(keep_c)
		delete(keep_ids)
		delete(keep_off)
	} else {
		delete(mesh.triangle_a, allocator)
		delete(mesh.triangle_b, allocator)
		delete(mesh.triangle_c, allocator)
		delete(mesh.triangle_ids, allocator)
		delete(mesh.source_record_offsets, allocator)
		mesh.triangle_a = keep_a[:]
		mesh.triangle_b = keep_b[:]
		mesh.triangle_c = keep_c[:]
		mesh.triangle_ids = keep_ids[:]
		mesh.source_record_offsets = keep_off[:]
	}

	// Step 2: Make face orientation consistent. Vertices are matched by exact coordinates (STL
	// gives every triangle its own vertices). Orientation propagates across edges shared by
	// exactly two faces; each component is then turned outward (signed volume for nearly closed
	// components, the top face's normal otherwise).
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	face_count := len(mesh.triangle_a)
	welded := make(map[[3]f64]u32, int(nverts), context.temp_allocator)
	weld := make([]u32, int(nverts), context.temp_allocator)
	for v in 0..<int(nverts) {
		key := [3]f64{mesh.vertex_x[v], mesh.vertex_y[v], mesh.vertex_z[v]}
		id, found := welded[key]
		if !found {
			id = u32(len(welded))
			welded[key] = id
		}
		weld[v] = id
	}
	Edge_Use :: struct {
		faces: [2]u32,
		count: u32,
		dirs:  [2]bool, // true when the face runs the edge from its lower to its higher vertex
	}
	edges := make(map[u64]Edge_Use, face_count*2, context.temp_allocator)
	face_vertices :: proc(mesh: ^formats.Decoded_Mesh, weld: []u32, f: int) -> [3]u32 {
		return {weld[mesh.triangle_a[f]], weld[mesh.triangle_b[f]], weld[mesh.triangle_c[f]]}
	}
	for f in 0..<face_count {
		v := face_vertices(mesh, weld, f)
		for k in 0..<3 {
			a, b := v[k], v[(k+1)%3]
			key := (u64(min(a, b)) << 32) | u64(max(a, b))
			use := edges[key]
			if use.count < 2 {
				use.faces[use.count] = u32(f)
				use.dirs[use.count] = a < b
			}
			use.count += 1
			edges[key] = use
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
				use := edges[(u64(min(a, b)) << 32) | u64(max(a, b))]
				edge_total += 1
				if use.count != 2 {
					boundary_edges += 1
					continue
				}
				side := 0 if int(use.faces[0]) == f else 1
				g := int(use.faces[1-side])
				// Consistent faces run a shared edge in opposite directions.
				g_flip := (use.dirs[side] != flip[f]) == use.dirs[1-side]
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
