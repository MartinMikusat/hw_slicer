package polygon

import "core:mem"

// Allocates a non-zeroed slice on `context.temp_allocator` for buffers overwritten before read.
@(private)
make_temp_non_zeroed :: proc($T: typeid, n: int) -> []T {
	if n <= 0 {return nil}
	raw, err := mem.alloc_bytes_non_zeroed(n * size_of(T), align_of(T), context.temp_allocator)
	if err != .None || len(raw) == 0 {return nil}
	return ([^]T)(raw_data(raw))[:n]
}

// Deterministic in-place sort for the polygon engine's hot paths: quicksort with a
// median-of-three pivot, insertion sort below 16 elements, and recursion into the smaller side
// only. `$less` is compile-time specialized so the comparator inlines with zero indirect calls.
@(private)
fast_sort :: proc(data: []$T, $less: proc(a, b: T) -> bool) {
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
			fast_sort(data[lo:j + 1], less)
			lo = i
		} else {
			fast_sort(data[i:hi], less)
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

// 1- or 2-pass 11-bit LSD radix sort for i64 slices whose span fits in 22 bits (~4.19 m in µm).
// Falls back to `fast_sort` for small slices or wide spans.
@(private)
radix_sort_i64 :: proc(data: []i64) {
	n := len(data)
	if n < 64 {
		fast_sort(data, proc(a, b: i64) -> bool {return a < b})
		return
	}
	min_v, max_v := data[0], data[0]
	for v in data[1:] {
		if v < min_v {min_v = v}
		if v > max_v {max_v = v}
	}
	span := u64(max_v - min_v)
	if span == 0 {return}
	if span >= (1 << 22) {
		fast_sort(data, proc(a, b: i64) -> bool {return a < b})
		return
	}
	RADIX_BITS :: 11
	RADIX_SIZE :: 1 << RADIX_BITS
	RADIX_MASK :: RADIX_SIZE - 1
	tmp := make_temp_non_zeroed(i64, n)
	if span < RADIX_SIZE {
		counts: [RADIX_SIZE]int
		for v in data {counts[u64(v - min_v)] += 1}
		sum := 0
		for &c in counts {
			cnt := c
			c = sum
			sum += cnt
		}
		for v in data {
			k := u64(v - min_v)
			tmp[counts[k]] = v
			counts[k] += 1
		}
		copy(data, tmp)
		return
	}
	// Pass 0 (bits 0..10) + Pass 1 (bits 11..21) histograms in one scan.
	c0: [RADIX_SIZE]int
	c1: [RADIX_SIZE]int
	for v in data {
		u := u64(v - min_v)
		c0[u & RADIX_MASK] += 1
		c1[u >> RADIX_BITS] += 1
	}
	s0, s1 := 0, 0
	for b in 0..<RADIX_SIZE {
		t0 := c0[b]; c0[b] = s0; s0 += t0
		t1 := c1[b]; c1[b] = s1; s1 += t1
	}
	for v in data {
		k := u64(v - min_v) & RADIX_MASK
		tmp[c0[k]] = v
		c0[k] += 1
	}
	for v in tmp {
		k := u64(v - min_v) >> RADIX_BITS
		data[c1[k]] = v
		c1[k] += 1
	}
}

// 1- or 2-pass 11-bit LSD radix sort on a struct slice by an i64 key (22-bit span fast path).
// Returns true if radix-sorted by `key_fn`; returns false if caller should fall back to `fast_sort`.
@(private)
radix_sort_by_i64 :: proc(data: []$T, $key_fn: proc(v: T) -> i64) -> bool {
	n := len(data)
	if n < 64 {return false}
	min_v := key_fn(data[0])
	max_v := min_v
	for v in data[1:] {
		k := key_fn(v)
		if k < min_v {min_v = k}
		if k > max_v {max_v = k}
	}
	span := u64(max_v - min_v)
	if span == 0 {return true}
	if span >= (1 << 22) {return false}
	RADIX_BITS :: 11
	RADIX_SIZE :: 1 << RADIX_BITS
	RADIX_MASK :: RADIX_SIZE - 1
	tmp := make_temp_non_zeroed(T, n)
	if span < RADIX_SIZE {
		counts: [RADIX_SIZE]int
		for v in data {counts[u64(key_fn(v) - min_v)] += 1}
		sum := 0
		for &c in counts {
			cnt := c
			c = sum
			sum += cnt
		}
		for v in data {
			k := u64(key_fn(v) - min_v)
			tmp[counts[k]] = v
			counts[k] += 1
		}
		copy(data, tmp)
		return true
	}
	c0: [RADIX_SIZE]int
	c1: [RADIX_SIZE]int
	for v in data {
		u := u64(key_fn(v) - min_v)
		c0[u & RADIX_MASK] += 1
		c1[u >> RADIX_BITS] += 1
	}
	s0, s1 := 0, 0
	for b in 0..<RADIX_SIZE {
		t0 := c0[b]; c0[b] = s0; s0 += t0
		t1 := c1[b]; c1[b] = s1; s1 += t1
	}
	for v in data {
		k := u64(key_fn(v) - min_v) & RADIX_MASK
		tmp[c0[k]] = v
		c0[k] += 1
	}
	for v in tmp {
		k := u64(key_fn(v) - min_v) >> RADIX_BITS
		data[c1[k]] = v
		c1[k] += 1
	}
	return true
}
