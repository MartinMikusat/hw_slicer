package features

import "core:mem"

import contracts "../contracts"
import polygon "../polygon"

// Solid bands that keep the shell thick under sloped surfaces (Orca and PrusaSlicer
// "ensure vertical shell thickness"). With L_k the outline of layer k and I_k the area inside its
// perimeters, layer i gets top band I_i minus the intersection of L over the `top_layers` layers
// above it, and bottom band I_i minus the intersection over the `bottom_layers` layers below it:
// a point needs solid fill when one of those layers has no material over or under it. On a
// steep wall the perimeters already give that thickness and the band is empty. Layers past the
// model's top or bottom count as empty, so the bands also contain the ordinary top and bottom
// skin areas.
Vertical_Shell_Result :: struct {
	top:    []polygon.Polygon_Set,
	bottom: []polygon.Polygon_Set,
}

vertical_shell_result_destroy :: proc(result: ^Vertical_Shell_Result, allocator := context.allocator) {
	for &set in result.top {polygon.polygon_set_destroy(&set, allocator)}
	for &set in result.bottom {polygon.polygon_set_destroy(&set, allocator)}
	delete(result.top, allocator)
	delete(result.bottom, allocator)
	result^ = {}
}

vertical_shells_build :: proc(
	model_layers: []polygon.Polygon_Set,
	perimeter_inset: contracts.Micrometres,
	line_width: contracts.Micrometres,
	top_layers, bottom_layers: u32,
	provider: polygon.Polygon_Provider,
	allocator := context.allocator,
) -> Vertical_Shell_Result {
	layer_count := len(model_layers)
	result := Vertical_Shell_Result{
		top    = make([]polygon.Polygon_Set, layer_count, allocator),
		bottom = make([]polygon.Polygon_Set, layer_count, allocator),
	}
	if layer_count == 0 || provider.offset == nil || provider.boolean == nil {return result}

	Inner_Ctx :: struct {
		model_layers: []polygon.Polygon_Set,
		inner:        []polygon.Polygon_Set,
		inset:        contracts.Micrometres,
		provider:     polygon.Polygon_Provider,
		allocator:    mem.Allocator,
	}
	inner := make([]polygon.Polygon_Set, layer_count, allocator)
	defer {
		for &set in inner {polygon.polygon_set_destroy(&set, allocator)}
		delete(inner, allocator)
	}
	ictx := Inner_Ctx{model_layers, inner, perimeter_inset, provider, allocator}
	parallel_for(layer_count, &ictx, proc(c: ^Inner_Ctx, li: int) {
		if len(c.model_layers[li].paths) == 0 {return}
		set, err := c.provider.offset(c.model_layers[li], -c.inset, .Miter, 2.0, 0.0, polygon.DEFAULT_POLYGON_LIMITS, c.allocator)
		if err != .None {
			polygon.polygon_set_destroy(&set, c.allocator)
			return
		}
		c.inner[li] = set
	})

	// pair[k] = L_k intersect L_(k+1); a window of layers is then a few pair intersections
	// instead of one intersection per layer.
	Pair_Ctx :: struct {
		layers, pair: []polygon.Polygon_Set,
		provider:    polygon.Polygon_Provider,
		allocator:   mem.Allocator,
	}
	pair := make([]polygon.Polygon_Set, layer_count, allocator)
	defer {
		for &set in pair {polygon.polygon_set_destroy(&set, allocator)}
		delete(pair, allocator)
	}
	pctx := Pair_Ctx{model_layers, pair, provider, allocator}
	parallel_for(layer_count - 1, &pctx, proc(c: ^Pair_Ctx, k: int) {
		if len(c.layers[k].paths) == 0 || len(c.layers[k + 1].paths) == 0 {return}
		set, err := c.provider.boolean(c.layers[k], c.layers[k + 1], .Intersection, .Non_Zero, polygon.DEFAULT_POLYGON_LIMITS, c.allocator)
		if err != .None {
			polygon.polygon_set_destroy(&set, c.allocator)
			return
		}
		c.pair[k] = set
	})

	Band_Ctx :: struct {
		model_layers:  []polygon.Polygon_Set,
		spacing:       f64,
		inner, pair:   []polygon.Polygon_Set,
		top, bottom:   []polygon.Polygon_Set,
		top_layers:    int,
		bottom_layers: int,
		provider:      polygon.Polygon_Provider,
		allocator:     mem.Allocator,
	}
	bctx := Band_Ctx{model_layers, 1.05 * f64(i64(line_width)), inner, pair, result.top, result.bottom, int(top_layers), int(bottom_layers), provider, allocator}
	parallel_for(layer_count, &bctx, proc(c: ^Band_Ctx, li: int) {
		if len(c.inner[li].paths) == 0 {return}
		object_volume: polygon.Polygon_Set
		if li > 0 && li + 1 < len(c.model_layers) {
			object_volume, _ = c.provider.boolean(c.model_layers[li - 1], c.model_layers[li + 1], .Intersection, .Non_Zero, polygon.DEFAULT_POLYGON_LIMITS, c.allocator)
		}
		defer polygon.polygon_set_destroy(&object_volume, c.allocator)
		top := vertical_shell_band(c.model_layers, c.inner, c.pair, li, li + 1, li + c.top_layers, c.provider, c.allocator)
		bottom := vertical_shell_band(c.model_layers, c.inner, c.pair, li, li - c.bottom_layers, li - 1, c.provider, c.allocator)
		c.top[li] = vertical_shell_regularize(top, c.inner[li], object_volume, c.spacing, c.provider, c.allocator)
		c.bottom[li] = vertical_shell_regularize(bottom, c.inner[li], object_volume, c.spacing, c.provider, c.allocator)
		polygon.polygon_set_destroy(&top, c.allocator)
		polygon.polygon_set_destroy(&bottom, c.allocator)
	})
	return result
}

// inner[li] minus the intersection of layers[first..last]; a layer outside the model empties the
// intersection, so the band is all of inner[li]. The intersection is built from pair[k] =
// layers[k] intersect layers[k+1], stepping two layers at a time.
@(private = "file")
vertical_shell_band :: proc(
	layers, inner, pair: []polygon.Polygon_Set,
	li, first, last: int,
	provider: polygon.Polygon_Provider,
	allocator: mem.Allocator,
) -> polygon.Polygon_Set {
	clone :: proc(set: polygon.Polygon_Set, allocator: mem.Allocator) -> polygon.Polygon_Set {
		points := make([]polygon.Polygon_Point, len(set.points), allocator)
		paths := make([]polygon.Polygon_Path, len(set.paths), allocator)
		copy(points, set.points)
		copy(paths, set.paths)
		return {points = points, paths = paths}
	}
	if last < first {return {}}
	if first < 0 || last >= len(layers) {return clone(inner[li], allocator)}
	// Pieces covering [first, last]: pairs (k, k+1) and, for an odd count, the last single layer.
	covered: polygon.Polygon_Set
	have := false
	k := first
	for k <= last {
		piece := pair[k] if k + 1 <= last else layers[k]
		k += 2 if k + 1 <= last else 1
		if len(piece.paths) == 0 {
			polygon.polygon_set_destroy(&covered, allocator)
			return clone(inner[li], allocator)
		}
		if !have {
			covered = clone(piece, allocator)
			have = true
			continue
		}
		next, err := provider.boolean(covered, piece, .Intersection, .Non_Zero, polygon.DEFAULT_POLYGON_LIMITS, allocator)
		polygon.polygon_set_destroy(&covered, allocator)
		if err != .None {
			polygon.polygon_set_destroy(&next, allocator)
			return clone(inner[li], allocator)
		}
		covered = next
		if len(covered.paths) == 0 {return clone(inner[li], allocator)}
	}
	defer polygon.polygon_set_destroy(&covered, allocator)
	band, err := provider.boolean(inner[li], covered, .Difference, .Non_Zero, polygon.DEFAULT_POLYGON_LIMITS, allocator)
	if err != .None {
		polygon.polygon_set_destroy(&band, allocator)
		return {}
	}
	return band
}

// Orca's regularization of the shell: open away parts narrower than about 0.65 spacing, close
// gaps narrower than 1.2 spacing, shrink back to a 0.2 spacing overlap, drop small pieces
// (smaller than spacing * 1.5 mm, or smaller than spacing * 8 mm and enclosed by the layers
// below and above), and keep only what lies inside the infill area. `spacing` is in micrometres.
@(private = "file")
vertical_shell_regularize :: proc(
	band, inner, object_volume: polygon.Polygon_Set,
	spacing: f64,
	provider: polygon.Polygon_Provider,
	allocator: mem.Allocator,
) -> polygon.Polygon_Set {
	if len(band.paths) == 0 {return {}}
	r_open := 0.5 * 0.65 * spacing
	r_close := 0.5 * 1.2 * spacing
	r_overlap := 0.2 * spacing
	step :: proc(set: polygon.Polygon_Set, d: f64, provider: polygon.Polygon_Provider, allocator: mem.Allocator) -> (polygon.Polygon_Set, bool) {
		out, err := provider.offset(set, contracts.Micrometres(i64(d)), .Square, 2.0, 0.0, polygon.DEFAULT_POLYGON_LIMITS, allocator)
		if err != .None {
			polygon.polygon_set_destroy(&out, allocator)
			return {}, false
		}
		return out, true
	}
	a, ok_a := step(band, -r_open, provider, allocator)
	if !ok_a || len(a.paths) == 0 {return a}
	b, ok_b := step(a, r_open + r_close, provider, allocator)
	polygon.polygon_set_destroy(&a, allocator)
	if !ok_b {return {}}
	c, ok_c := step(b, -(r_close - r_overlap), provider, allocator)
	polygon.polygon_set_destroy(&b, allocator)
	if !ok_c || len(c.paths) == 0 {return c}

	// Drop small pieces. Holes are kept only inside a kept outer path.
	small_area_2 := 2.0 * spacing * 1500.0
	wrapped_area_2 := 2.0 * spacing * 8000.0
	keep := make([]bool, len(c.paths), context.temp_allocator)
	for path, pi in c.paths {
		ring := c.points[path.offset:path.offset+path.count]
		area := f64(polygon.polygon_path_area_2(ring))
		if area <= 0 {continue}
		drop := area < small_area_2
		if !drop && area < wrapped_area_2 && len(object_volume.paths) > 0 {
			piece := polygon.Polygon_Set{points = ring, paths = []polygon.Polygon_Path{{offset = 0, count = path.count}}}
			outside, err := provider.boolean(piece, object_volume, .Difference, .Non_Zero, polygon.DEFAULT_POLYGON_LIMITS, allocator)
			drop = err == .None && len(outside.paths) == 0
			polygon.polygon_set_destroy(&outside, allocator)
		}
		keep[pi] = !drop
	}
	for path, pi in c.paths {
		ring := c.points[path.offset:path.offset+path.count]
		if polygon.polygon_path_area_2(ring) >= 0 {continue}
		probe := ring[0]
		for outer, oi in c.paths {
			if !keep[oi] {continue}
			outer_ring := c.points[outer.offset:outer.offset+outer.count]
			if polygon.polygon_path_area_2(outer_ring) <= 0 {continue}
			if bridge_polygon_contains_twice({points = outer_ring, paths = []polygon.Polygon_Path{{offset = 0, count = outer.count}}}, i64(probe.x)*2, i64(probe.y)*2) {
				keep[pi] = true
				break
			}
		}
	}
	kept_points := make([dynamic]polygon.Polygon_Point, 0, len(c.points), allocator)
	kept_paths := make([dynamic]polygon.Polygon_Path, 0, len(c.paths), allocator)
	for path, pi in c.paths {
		if !keep[pi] {continue}
		append(&kept_paths, polygon.Polygon_Path{offset = u64(len(kept_points)), count = path.count})
		append(&kept_points, ..c.points[path.offset:path.offset+path.count])
	}
	polygon.polygon_set_destroy(&c, allocator)
	if len(kept_paths) == 0 {
		delete(kept_points)
		delete(kept_paths)
		return {}
	}
	kept := polygon.Polygon_Set{points = kept_points[:], paths = kept_paths[:]}
	defer polygon.polygon_set_destroy(&kept, allocator)
	final, err := provider.boolean(kept, inner, .Intersection, .Non_Zero, polygon.DEFAULT_POLYGON_LIMITS, allocator)
	if err != .None {
		polygon.polygon_set_destroy(&final, allocator)
		return {}
	}
	return final
}
