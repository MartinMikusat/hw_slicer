package features

import "core:mem"

import workers "../workers"

// Allocates a slice without zero-initializing its backing memory. Only use when every element
// (and every field within it) is unconditionally written before being read.
@(private)
features_make_non_zeroed :: proc(
	$T: typeid/[]$E,
	count: int,
	allocator := context.allocator,
) -> T {
	if count <= 0 {return nil}
	elem_size := size_of(E)
	if elem_size == 0 || count > max(int) / elem_size {return nil}
	raw, err := mem.alloc_bytes_non_zeroed(count * elem_size, align_of(E), allocator)
	if err != nil || raw == nil {return nil}
	return ([^]E)(raw_data(raw))[:count]
}

@(private)
g_worker_threads: int = 1

set_worker_threads :: proc(n: int) {
	g_worker_threads = clamp(n, 1, workers.MAX_WORKERS)
}

get_worker_threads :: proc() -> int {
	return clamp(g_worker_threads, 1, workers.MAX_WORKERS)
}

// Runs `body(ctx, index)` for index in 0..<count on the shared worker pool, using up to
// `get_worker_threads()` threads. Caller ensures each index writes to disjoint storage.
@(private)
parallel_for :: proc(count: int, ctx: ^$T, body: proc(ctx: ^T, index: int), min_count := 4) {
	workers.parallel_for(count, ctx, body, get_worker_threads(), min_count)
}

// Compile-time specialized in-place quicksort + insertion sort (replaces slice.sort_by smoothsort).
@(private)
features_fast_sort :: proc(data: []$T, $less: proc(a, b: T) -> bool) {
	lo, hi := 0, len(data)
	for hi - lo > 16 {
		mid := lo + (hi - lo) / 2
		last := hi - 1
		if less(data[mid], data[lo]) {data[mid], data[lo] = data[lo], data[mid]}
		if less(data[last], data[lo]) {data[last], data[lo] = data[lo], data[last]}
		if less(data[last], data[mid]) {data[last], data[mid] = data[mid], data[last]}
		pivot := data[mid]
		i, j := lo, last
		for i <= j {
			for less(data[i], pivot) {i += 1}
			for less(pivot, data[j]) {j -= 1}
			if i <= j {
				data[i], data[j] = data[j], data[i]
				i += 1
				j -= 1
			}
		}
		if j - lo < hi - i {
			features_fast_sort(data[lo:j + 1], less)
			lo = i
		} else {
			features_fast_sort(data[i:hi], less)
			hi = j + 1
		}
	}
	for a := lo + 1; a < hi; a += 1 {
		key := data[a]
		b := a - 1
		for b >= lo && less(key, data[b]) {
			data[b + 1] = data[b]
			b -= 1
		}
		data[b + 1] = key
	}
}
