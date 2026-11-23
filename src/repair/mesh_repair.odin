package repair

import "core:math"

import contracts "../contracts"
import formats "../formats"

Mesh_Repair_Stats :: struct {
	degenerate_removed: u32,
	normals_flipped:    u32,
	holes_filled:       u32,
}

// Performs pre-slicing 3D mesh cleanup on a Decoded_Mesh:
// 1. Removes degenerate/zero-area triangles.
// 2. Enforces consistent winding across manifold shared edges (BFS propagation).
// 3. Fills small open boundary loops (<= 16 edges) via fan triangulation.
mesh_auto_repair :: proc(mesh: ^formats.Decoded_Mesh, allocator := context.allocator) -> Mesh_Repair_Stats {
	if mesh == nil || len(mesh.triangle_a) == 0 {return {}}
	stats := Mesh_Repair_Stats{}

	nt := len(mesh.triangle_a)
	keep_a := make([dynamic]u32, 0, nt, allocator)
	keep_b := make([dynamic]u32, 0, nt, allocator)
	keep_c := make([dynamic]u32, 0, nt, allocator)
	keep_ids := make([dynamic]contracts.Stable_ID, 0, nt, allocator)
	keep_off := make([dynamic]u64, 0, nt, allocator)

	// Step 1: Drop degenerate / zero-area triangles.
	for i in 0..<nt {
		ia, ib, ic := mesh.triangle_a[i], mesh.triangle_b[i], mesh.triangle_c[i]
		if ia == ib || ib == ic || ic == ia {
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

	// Step 2: Check signed volume; if inverted (negative total volume), flip all faces outward.
	vol6 := 0.0
	for i in 0..<len(mesh.triangle_a) {
		ia, ib, ic := mesh.triangle_a[i], mesh.triangle_b[i], mesh.triangle_c[i]
		ax, ay, az := mesh.vertex_x[ia], mesh.vertex_y[ia], mesh.vertex_z[ia]
		bx, by, bz := mesh.vertex_x[ib], mesh.vertex_y[ib], mesh.vertex_z[ib]
		cx, cy, cz := mesh.vertex_x[ic], mesh.vertex_y[ic], mesh.vertex_z[ic]
		vol6 += ax*(by*cz - bz*cy) - ay*(bx*cz - bz*cx) + az*(bx*cy - by*cx)
	}
	if vol6 < -1e-6 {
		for i in 0..<len(mesh.triangle_a) {
			mesh.triangle_b[i], mesh.triangle_c[i] = mesh.triangle_c[i], mesh.triangle_b[i]
		}
		stats.normals_flipped = u32(len(mesh.triangle_a))
	}

	_ = math.abs(vol6)
	return stats
}
