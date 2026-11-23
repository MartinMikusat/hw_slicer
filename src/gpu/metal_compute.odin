package slicer_gpu

import "core:c"

Poly_Edge :: struct {
	ax: i64,
	ay: i64,
	bx: i64,
	by: i64,
}

Layer_Edge_Range :: struct {
	offset: u32,
	count:  u32,
}

Point_Query :: struct {
	x2:        i64,
	y2:        i64,
	layer_idx: u32,
	_pad:      u32,
}

Slice_Pair :: struct {
	tri_idx:   u32,
	layer_idx: u32,
}

Slice_Triangle :: struct {
	ax, ay, az: f32,
	bx, by, bz: f32,
	cx, cy, cz: f32,
}

Slice_Seg_Out :: struct {
	x0, y0, x1, y1: f32,
	valid:          u32,
	_pad:           u32,
}

Travel_Query :: struct {
	ax, ay:    i64,
	bx, by:    i64,
	layer_idx: u32,
	_pad:      u32,
}

SHADER_SOURCE :: #load("../../shaders/slicer_compute.metal", cstring)

@(default_calling_convention = "c")
foreign {
	hw_metal_compute_init :: proc(shader_source: cstring) -> bool ---
	hw_metal_batch_point_in_polygon :: proc(
		edges: [^]Poly_Edge,
		edge_count: u32,
		layer_ranges: [^]Layer_Edge_Range,
		layer_count: u32,
		queries: [^]Point_Query,
		query_count: u32,
		out_results: [^]u8,
	) -> bool ---
	hw_metal_batch_triangle_plane_intersect :: proc(
		tris: [^]Slice_Triangle,
		tri_count: u32,
		layer_z_mm: [^]f32,
		layer_count: u32,
		pairs: [^]Slice_Pair,
		pair_count: u32,
		out_segs: [^]Slice_Seg_Out,
	) -> bool ---
	hw_metal_batch_travel_crosses_exterior :: proc(
		edges: [^]Poly_Edge,
		edge_count: u32,
		layer_ranges: [^]Layer_Edge_Range,
		layer_count: u32,
		queries: [^]Travel_Query,
		query_count: u32,
		out_results: [^]u8,
	) -> bool ---
}

metal_init :: proc() -> bool {
	return hw_metal_compute_init(SHADER_SOURCE)
}

metal_batch_point_in_polygon :: proc(
	edges: []Poly_Edge,
	layer_ranges: []Layer_Edge_Range,
	queries: []Point_Query,
	out_results: []u8,
) -> bool {
	if len(queries) == 0 || len(layer_ranges) == 0 || len(out_results) < len(queries) {
		return false
	}
	if !metal_init() {return false}
	return hw_metal_batch_point_in_polygon(
		raw_data(edges),
		u32(len(edges)),
		raw_data(layer_ranges),
		u32(len(layer_ranges)),
		raw_data(queries),
		u32(len(queries)),
		raw_data(out_results),
	)
}

metal_batch_triangle_plane_intersect :: proc(
	tris: []Slice_Triangle,
	layer_z_mm: []f32,
	pairs: []Slice_Pair,
	out_segs: []Slice_Seg_Out,
) -> bool {
	if len(pairs) == 0 || len(tris) == 0 || len(layer_z_mm) == 0 || len(out_segs) < len(pairs) {
		return false
	}
	if !metal_init() {return false}
	return hw_metal_batch_triangle_plane_intersect(
		raw_data(tris),
		u32(len(tris)),
		raw_data(layer_z_mm),
		u32(len(layer_z_mm)),
		raw_data(pairs),
		u32(len(pairs)),
		raw_data(out_segs),
	)
}

metal_batch_travel_crosses_exterior :: proc(
	edges: []Poly_Edge,
	layer_ranges: []Layer_Edge_Range,
	queries: []Travel_Query,
	out_results: []u8,
) -> bool {
	if len(queries) == 0 || len(layer_ranges) == 0 || len(out_results) < len(queries) {
		return false
	}
	if !metal_init() {return false}
	return hw_metal_batch_travel_crosses_exterior(
		raw_data(edges),
		u32(len(edges)),
		raw_data(layer_ranges),
		u32(len(layer_ranges)),
		raw_data(queries),
		u32(len(queries)),
		raw_data(out_results),
	)
}

_ :: c.int
