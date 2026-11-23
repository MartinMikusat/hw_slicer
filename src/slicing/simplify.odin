package slicing

import "core:mem"

import geometry "../geometry"

@(private = "file")
point_to_segment_dist_sq :: proc(px, py, ax, ay, bx, by: f64) -> f64 {
	dx := bx - ax
	dy := by - ay
	len_sq := dx*dx + dy*dy
	if len_sq <= 1e-12 {
		ex := px - ax
		ey := py - ay
		return ex*ex + ey*ey
	}
	t := ((px - ax)*dx + (py - ay)*dy) / len_sq
	if t < 0.0 {t = 0.0} else if t > 1.0 {t = 1.0}
	cx := ax + t*dx
	cy := ay + t*dy
	ex := px - cx
	ey := py - cy
	return ex*ex + ey*ey
}

@(private = "file")
Rdp_Range :: struct {
	lo, hi: int,
}

@(private = "file")
rdp_chain_mark :: proc(
	pts: [][2]f64,
	indices: []int,
	keep: []bool,
	tol_sq: f64,
	stack: ^[dynamic]Rdp_Range,
) {
	n := len(indices)
	if n <= 2 {return}
	clear(stack)
	append(stack, Rdp_Range{lo = 0, hi = n - 1})
	for len(stack) > 0 {
		r := pop(stack)
		if r.hi - r.lo <= 1 {continue}
		a := pts[indices[r.lo]]
		b := pts[indices[r.hi]]
		best_dist := -1.0
		best_pos := -1
		for k in r.lo + 1 ..< r.hi {
			p := pts[indices[k]]
			d := point_to_segment_dist_sq(p[0], p[1], a[0], a[1], b[0], b[1])
			if d > best_dist {
				best_dist = d
				best_pos = k
			}
		}
		if best_pos >= 0 && best_dist > tol_sq {
			keep[indices[best_pos]] = true
			append(stack, Rdp_Range{lo = r.lo, hi = best_pos})
			append(stack, Rdp_Range{lo = best_pos, hi = r.hi})
		}
	}
}

@(private = "file")
signed_area_2_loop :: proc(topo: Topology_Result, v_indices: []u32) -> i128 {
	n := len(v_indices)
	if n < 3 {return 0}
	area: i128
	for i in 0 ..< n {
		a := topo.vertices[v_indices[i]].point
		b := topo.vertices[v_indices[(i + 1) % n]].point
		area += i128(a.x)*i128(b.y) - i128(b.x)*i128(a.y)
	}
	return area
}

topology_simplify_contours :: proc(
	topo: Topology_Result,
	tolerance_um: f64,
	allocator := context.allocator,
) -> (Topology_Result, bool) {
	if tolerance_um <= 0.0 || len(topo.paths) == 0 {
		return {}, false
	}
	tol_sq := tolerance_um * tolerance_um

	out_layers := make([]Topology_Layer, len(topo.layers), allocator)
	out_vertices := make([dynamic]Topology_Vertex, 0, len(topo.vertices) / 2 + 16, allocator)
	out_paths := make([]Topology_Path, len(topo.paths), allocator)
	out_vidx := make([dynamic]u32, 0, len(topo.path_vertex_indices) / 2 + 16, allocator)
	out_sidx := make([dynamic]u32, 0, len(topo.path_segment_indices) / 2 + 16, allocator)

	pts_buf := make([dynamic][2]f64, 0, 256, allocator)
	defer delete(pts_buf)
	keep_buf := make([dynamic]bool, 0, 256, allocator)
	defer delete(keep_buf)
	chain_a := make([dynamic]int, 0, 256, allocator)
	defer delete(chain_a)
	chain_b := make([dynamic]int, 0, 256, allocator)
	defer delete(chain_b)
	kept_vidx := make([dynamic]u32, 0, 256, allocator)
	defer delete(kept_vidx)
	kept_sidx := make([dynamic]u32, 0, 256, allocator)
	defer delete(kept_sidx)
	rdp_stack := make([dynamic]Rdp_Range, 0, 64, allocator)
	defer delete(rdp_stack)

	// Map original global vertex index -> new global vertex index (per-layer reset via stamp).
	v_remap := make([]u32, len(topo.vertices), allocator)
	defer delete(v_remap, allocator)
	v_seen := make([]u32, len(topo.vertices), allocator)
	defer delete(v_seen, allocator)

	for layer, layer_idx in topo.layers {
		stamp := u32(layer_idx + 1)
		layer_v_start := len(out_vertices)
		layer_p_start := int(layer.path_offset)
		p_end := layer_p_start + int(layer.path_count)

		for p_idx in layer_p_start ..< p_end {
			p := topo.paths[p_idx]
			v_start := int(p.vertex_offset)
			v_cnt := int(p.vertex_count)
			s_start := int(p.segment_offset)
			s_cnt := int(p.segment_count)

			clear(&kept_vidx)
			clear(&kept_sidx)

			used_simplified := false
			if p.kind == .Loop && v_cnt > 4 {
				resize(&pts_buf, v_cnt)
				resize(&keep_buf, v_cnt)
				for k in 0 ..< v_cnt {
					pt := topo.vertices[topo.path_vertex_indices[v_start + k]].point
					pts_buf[k] = {f64(pt.x), f64(pt.y)}
					keep_buf[k] = false
				}
				// Find vertex farthest from index 0 to split the closed ring into two chains.
				p0 := pts_buf[0]
				far_idx := 1
				far_d2 := -1.0
				for k in 1 ..< v_cnt {
					dx := pts_buf[k][0] - p0[0]
					dy := pts_buf[k][1] - p0[1]
					d2 := dx*dx + dy*dy
					if d2 > far_d2 {
						far_d2 = d2
						far_idx = k
					}
				}
				keep_buf[0] = true
				keep_buf[far_idx] = true

				clear(&chain_a)
				for k in 0 ..= far_idx {
					append(&chain_a, k)
				}
				clear(&chain_b)
				for k in far_idx ..< v_cnt {
					append(&chain_b, k)
				}
				append(&chain_b, 0)

				rdp_chain_mark(pts_buf[:], chain_a[:], keep_buf[:], tol_sq, &rdp_stack)
				rdp_chain_mark(pts_buf[:], chain_b[:], keep_buf[:], tol_sq, &rdp_stack)

				for k in 0 ..< v_cnt {
					if keep_buf[k] {
						append(&kept_vidx, topo.path_vertex_indices[v_start + k])
						if k < s_cnt {
							append(&kept_sidx, topo.path_segment_indices[s_start + k])
						}
					}
				}

				if len(kept_vidx) >= 3 && len(kept_vidx) < v_cnt {
					new_area := signed_area_2_loop(topo, kept_vidx[:])
					orig_pos := p.signed_area_2 > 0
					orig_neg := p.signed_area_2 < 0
					same_sign := (orig_pos && new_area > 0) || (orig_neg && new_area < 0)
					if same_sign {
						used_simplified = true
					}
				}
			}

			if !used_simplified {
				clear(&kept_vidx)
				clear(&kept_sidx)
				for k in 0 ..< v_cnt {
					append(&kept_vidx, topo.path_vertex_indices[v_start + k])
				}
				for k in 0 ..< s_cnt {
					append(&kept_sidx, topo.path_segment_indices[s_start + k])
				}
			}

			new_v_off := u64(len(out_vidx))
			new_s_off := u64(len(out_sidx))
			for old_vi in kept_vidx {
				if v_seen[old_vi] != stamp {
					v_seen[old_vi] = stamp
					v_remap[old_vi] = u32(len(out_vertices))
					append(&out_vertices, topo.vertices[old_vi])
				}
				append(&out_vidx, v_remap[old_vi])
			}
			for si in kept_sidx {
				append(&out_sidx, si)
			}

			new_area := p.signed_area_2
			new_winding := p.winding
			if used_simplified {
				new_area = signed_area_2_loop(topo, kept_vidx[:])
				new_winding = .Positive if new_area > 0 else (.Negative if new_area < 0 else .Zero)
			}

			out_paths[p_idx] = {
				id             = p.id,
				layer_index    = p.layer_index,
				kind           = p.kind,
				vertex_offset  = new_v_off,
				vertex_count   = u32(len(kept_vidx)),
				segment_offset = new_s_off,
				segment_count  = u32(len(kept_sidx)),
				signed_area_2  = new_area,
				winding        = new_winding,
			}
		}

		out_layers[layer_idx] = {
			vertex_offset = u64(layer_v_start),
			vertex_count  = u32(len(out_vertices) - layer_v_start),
			path_offset   = layer.path_offset,
			path_count    = layer.path_count,
		}
	}

	res := Topology_Result{
		layers                    = out_layers,
		vertices                  = out_vertices[:],
		paths                     = out_paths,
		path_vertex_indices       = out_vidx[:],
		path_segment_indices      = out_sidx[:],
		open_chain_count          = topo.open_chain_count,
		degenerate_loop_count     = topo.degenerate_loop_count,
		non_manifold_vertex_count = topo.non_manifold_vertex_count,
	}
	return res, true
}
