package features

import "core:mem"

import contracts "../contracts"
import polygon "../polygon"
import workers "../workers"

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

	// Deduplicate identical model layers so offset(-perimeter_inset) runs once per unique layer shape.
	canon_layer := make([]int, layer_count, allocator)
	unique_layers := make([dynamic]int, 0, layer_count, allocator)
	defer delete(canon_layer, allocator)
	defer delete(unique_layers)
	{
		cap_pow2 := 16
		for cap_pow2 < layer_count * 2 {cap_pow2 <<= 1}
		ht_mask := u64(cap_pow2 - 1)
		ht := make([]int, cap_pow2, allocator)
		defer delete(ht, allocator)
		for li in 0..<layer_count {
			ml := model_layers[li]
			if len(ml.paths) == 0 {
				canon_layer[li] = li
				continue
			}
			h := features_polygon_set_hash64(ml)
			slot := h & ht_mask
			found := -1
			for {
				entry := ht[slot]
				if entry == 0 {break}
				cand := entry - 1
				if features_polygon_sets_equal(model_layers[cand], ml) {
					found = cand
					break
				}
				slot = (slot + 1) & ht_mask
			}
			if found >= 0 {
				canon_layer[li] = found
			} else {
				ht[slot] = li + 1
				canon_layer[li] = li
				append(&unique_layers, li)
			}
		}
	}

	Inner_Ctx :: struct {
		model_layers:  []polygon.Polygon_Set,
		unique_layers: []int,
		inner:         []polygon.Polygon_Set,
		inset:         contracts.Micrometres,
		provider:      polygon.Polygon_Provider,
		allocator:     mem.Allocator,
	}
	inner := make([]polygon.Polygon_Set, layer_count, allocator)
	defer {
		for ui in unique_layers {polygon.polygon_set_destroy(&inner[ui], allocator)}
		delete(inner, allocator)
	}
	ictx := Inner_Ctx{model_layers, unique_layers[:], inner, perimeter_inset, provider, allocator}
	parallel_for(len(unique_layers), &ictx, proc(c: ^Inner_Ctx, idx: int) {
		li := c.unique_layers[idx]
		if len(c.model_layers[li].paths) == 0 {return}
		set, err := c.provider.offset(c.model_layers[li], -c.inset, .Miter, 2.0, 0.0, polygon.DEFAULT_POLYGON_LIMITS, c.allocator)
		if err != .None {
			polygon.polygon_set_destroy(&set, c.allocator)
			return
		}
		c.inner[li] = set
	})
	for li in 0..<layer_count {
		if canon_layer[li] != li {
			inner[li] = inner[canon_layer[li]]
		}
	}

	// pair[k] = L_k intersect L_(k+1); skip boolean when L_k == L_(k+1) (borrow read-only!).
	Pair_Ctx :: struct {
		layers, pair: []polygon.Polygon_Set,
		canon_layer:  []int,
		pair_owned:   []bool,
		provider:     polygon.Polygon_Provider,
		allocator:    mem.Allocator,
	}
	pair := make([]polygon.Polygon_Set, layer_count, allocator)
	pair_owned := make([]bool, layer_count, allocator)
	defer {
		for k in 0..<layer_count {
			if pair_owned[k] {polygon.polygon_set_destroy(&pair[k], allocator)}
		}
		delete(pair, allocator)
		delete(pair_owned, allocator)
	}
	pctx := Pair_Ctx{model_layers, pair, canon_layer, pair_owned, provider, allocator}
	parallel_for(layer_count - 1, &pctx, proc(c: ^Pair_Ctx, k: int) {
		if len(c.layers[k].paths) == 0 || len(c.layers[k + 1].paths) == 0 {return}
		if c.canon_layer[k] == c.canon_layer[k + 1] {
			c.pair[k] = c.layers[k]
			return
		}
		set, err := c.provider.boolean(c.layers[k], c.layers[k + 1], .Intersection, .Non_Zero, polygon.DEFAULT_POLYGON_LIMITS, c.allocator)
		if err != .None {
			polygon.polygon_set_destroy(&set, c.allocator)
			return
		}
		c.pair[k] = set
		c.pair_owned[k] = true
	})

	Band_Ctx :: struct {
		model_layers:  []polygon.Polygon_Set,
		canon_layer:   []int,
		spacing:       f64,
		inner, pair:   []polygon.Polygon_Set,
		top, bottom:   []polygon.Polygon_Set,
		top_layers:    int,
		bottom_layers: int,
		provider:      polygon.Polygon_Provider,
		allocator:     mem.Allocator,
	}
	bctx := Band_Ctx{model_layers, canon_layer, 1.05 * f64(i64(line_width)), inner, pair, result.top, result.bottom, int(top_layers), int(bottom_layers), provider, allocator}
	parallel_for(layer_count, &bctx, proc(c: ^Band_Ctx, li: int) {
		if len(c.inner[li].paths) == 0 {return}
		my_canon := c.canon_layer[li]
		top_identical := c.top_layers > 0 && li + c.top_layers < len(c.model_layers)
		if top_identical {
			for k in li + 1..=li + c.top_layers {
				if c.canon_layer[k] != my_canon {top_identical = false; break}
			}
		}
		bottom_identical := c.bottom_layers > 0 && li - c.bottom_layers >= 0
		if bottom_identical {
			for k in li - c.bottom_layers..<li {
				if c.canon_layer[k] != my_canon {bottom_identical = false; break}
			}
		}
		if top_identical && bottom_identical {return}

		top: polygon.Polygon_Set
		if !top_identical {
			top = vertical_shell_band(c.model_layers, c.inner, c.pair, li, li + 1, li + c.top_layers, c.provider, workers.scratch_allocator())
		}
		bottom: polygon.Polygon_Set
		if !bottom_identical {
			bottom = vertical_shell_band(c.model_layers, c.inner, c.pair, li, li - c.bottom_layers, li - 1, c.provider, workers.scratch_allocator())
		}
		if len(top.paths) == 0 && len(bottom.paths) == 0 {return}

		ov_state := Lazy_Object_Volume{
			model_layers = c.model_layers,
			canon_layer  = c.canon_layer,
			li           = li,
			provider     = c.provider,
		}
		if len(top.paths) > 0 {
			c.top[li] = vertical_shell_regularize(top, c.inner[li], &ov_state, c.spacing, c.provider, c.allocator)
		}
		if len(bottom.paths) > 0 {
			c.bottom[li] = vertical_shell_regularize(bottom, c.inner[li], &ov_state, c.spacing, c.provider, c.allocator)
		}
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
	// Intermediate intersections live on the thread-local scratch arena (reclaimed per iteration).
	scratch := workers.scratch_allocator()
	covered: polygon.Polygon_Set
	have := false
	k := first
	for k <= last {
		piece := pair[k] if k + 1 <= last else layers[k]
		k += 2 if k + 1 <= last else 1
		if len(piece.paths) == 0 {
			return clone(inner[li], allocator)
		}
		if !have {
			covered = piece
			have = true
			continue
		}
		next, err := provider.boolean(covered, piece, .Intersection, .Non_Zero, polygon.DEFAULT_POLYGON_LIMITS, scratch)
		if err != .None {
			return clone(inner[li], allocator)
		}
		covered = next
		if len(covered.paths) == 0 {return clone(inner[li], allocator)}
	}
	band, err := provider.boolean(inner[li], covered, .Difference, .Non_Zero, polygon.DEFAULT_POLYGON_LIMITS, allocator)
	if err != .None {
		polygon.polygon_set_destroy(&band, allocator)
		return {}
	}
	return band
}

@(private = "file")
Lazy_Object_Volume :: struct {
	model_layers: []polygon.Polygon_Set,
	canon_layer:  []int,
	li:           int,
	provider:     polygon.Polygon_Provider,
	computed:     bool,
	value:        polygon.Polygon_Set,
}

@(private = "file")
lazy_object_volume_get :: proc(ov: ^Lazy_Object_Volume, scratch: mem.Allocator) -> polygon.Polygon_Set {
	if !ov.computed {
		ov.computed = true
		if ov.li > 0 && ov.li + 1 < len(ov.model_layers) {
			if ov.canon_layer[ov.li - 1] == ov.canon_layer[ov.li + 1] {
				ov.value = ov.model_layers[ov.li - 1]
			} else {
				ov.value, _ = ov.provider.boolean(
					ov.model_layers[ov.li - 1],
					ov.model_layers[ov.li + 1],
					.Intersection,
					.Non_Zero,
					polygon.DEFAULT_POLYGON_LIMITS,
					scratch,
				)
			}
		}
	}
	return ov.value
}

// Orca's regularization of the shell: open away parts narrower than about 0.65 spacing, close
// gaps narrower than 1.2 spacing, shrink back to a 0.2 spacing overlap, drop small pieces
// (smaller than spacing * 1.5 mm, or smaller than spacing * 8 mm and enclosed by the layers
// below and above), and keep only what lies inside the infill area. `spacing` is in micrometres.
@(private = "file")
vertical_shell_regularize :: proc(
	band, inner: polygon.Polygon_Set,
	ov: ^Lazy_Object_Volume,
	spacing: f64,
	provider: polygon.Polygon_Provider,
	allocator: mem.Allocator,
) -> polygon.Polygon_Set {
	if len(band.paths) == 0 {return {}}
	scratch := workers.scratch_allocator()
	r_open := 0.5 * 0.65 * spacing
	r_close := 0.5 * 1.2 * spacing
	r_overlap := 0.2 * spacing
	step :: proc(set: polygon.Polygon_Set, d: f64, provider: polygon.Polygon_Provider, alloc: mem.Allocator) -> (polygon.Polygon_Set, bool) {
		out, err := provider.offset(set, contracts.Micrometres(i64(d)), .Square, 2.0, 0.0, polygon.DEFAULT_POLYGON_LIMITS, alloc)
		if err != .None {
			return {}, false
		}
		return out, true
	}
	a, ok_a := step(band, -r_open, provider, scratch)
	if !ok_a || len(a.paths) == 0 {return {}}
	b, ok_b := step(a, r_open + r_close, provider, scratch)
	if !ok_b {return {}}
	c, ok_c := step(b, -(r_close - r_overlap), provider, scratch)
	if !ok_c || len(c.paths) == 0 {return {}}

	// Drop small pieces. Holes are kept only inside a kept outer path.
	small_area_2 := 2.0 * spacing * 1500.0
	wrapped_area_2 := 2.0 * spacing * 8000.0
	keep := make([]bool, len(c.paths), scratch)
	for path, pi in c.paths {
		ring := c.points[path.offset:path.offset+path.count]
		area := f64(polygon.polygon_path_area_2(ring))
		if area <= 0 {continue}
		drop := area < small_area_2
		if !drop && area < wrapped_area_2 {
			object_volume := lazy_object_volume_get(ov, scratch)
			if len(object_volume.paths) > 0 {
				piece := polygon.Polygon_Set{points = ring, paths = []polygon.Polygon_Path{{offset = 0, count = path.count}}}
				outside, err := provider.boolean(piece, object_volume, .Difference, .Non_Zero, polygon.DEFAULT_POLYGON_LIMITS, scratch)
				drop = err == .None && len(outside.paths) == 0
			}
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
	kept_points := make([dynamic]polygon.Polygon_Point, 0, len(c.points), scratch)
	kept_paths := make([dynamic]polygon.Polygon_Path, 0, len(c.paths), scratch)
	for path, pi in c.paths {
		if !keep[pi] {continue}
		append(&kept_paths, polygon.Polygon_Path{offset = u64(len(kept_points)), count = path.count})
		append(&kept_points, ..c.points[path.offset:path.offset+path.count])
	}
	if len(kept_paths) == 0 {
		return {}
	}
	kept := polygon.Polygon_Set{points = kept_points[:], paths = kept_paths[:]}
	final, err := provider.boolean(kept, inner, .Intersection, .Non_Zero, polygon.DEFAULT_POLYGON_LIMITS, allocator)
	if err != .None {
		polygon.polygon_set_destroy(&final, allocator)
		return {}
	}
	return final
}
