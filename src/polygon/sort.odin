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

// Adaptive LSD radix sort for i64 slices:
// - n < 96: `fast_sort` (L1-resident, zero stack memset, zero temp alloc).
// - span < 256: 1-pass 8-bit counting sort (1 KB u32 histogram).
// - span < 65536: 2-pass 8-bit radix sort (2 KB u32 histograms).
// - n < 2048 && span < 2^24: 3-pass 8-bit radix sort (3 KB u32 histograms vs 32 KB 11-bit).
// - n >= 2048 && span < 2^22: 2-pass 11-bit radix sort (16 KB u32 histograms).
@(private)
radix_sort_i64 :: proc(data: []i64) {
	n := len(data)
	if n < 96 {
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
	if span >= (1 << 24) || (n >= 2048 && span >= (1 << 22)) {
		fast_sort(data, proc(a, b: i64) -> bool {return a < b})
		return
	}
	tmp := make_temp_non_zeroed(i64, n)
	if span < 256 {
		counts: [256]u32
		for v in data {counts[u64(v - min_v)] += 1}
		sum: u32
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
	if span < 65536 {
		c0: [256]u32
		c1: [256]u32
		for v in data {
			u := u64(v - min_v)
			c0[u & 0xff] += 1
			c1[u >> 8] += 1
		}
		s0, s1: u32
		for b in 0..<256 {
			t0 := c0[b]; c0[b] = s0; s0 += t0
			t1 := c1[b]; c1[b] = s1; s1 += t1
		}
		for v in data {
			k := u64(v - min_v) & 0xff
			tmp[c0[k]] = v
			c0[k] += 1
		}
		for v in tmp {
			k := u64(v - min_v) >> 8
			data[c1[k]] = v
			c1[k] += 1
		}
		return
	}
	if n < 2048 {
		// 3-pass 8-bit radix sort: 3 KB stack histograms instead of 32 KB 11-bit histograms.
		c0: [256]u32
		c1: [256]u32
		c2: [256]u32
		for v in data {
			u := u64(v - min_v)
			c0[u & 0xff] += 1
			c1[(u >> 8) & 0xff] += 1
			c2[u >> 16] += 1
		}
		s0, s1, s2: u32
		for b in 0..<256 {
			t0 := c0[b]; c0[b] = s0; s0 += t0
			t1 := c1[b]; c1[b] = s1; s1 += t1
			t2 := c2[b]; c2[b] = s2; s2 += t2
		}
		for v in data {
			k := u64(v - min_v) & 0xff
			tmp[c0[k]] = v
			c0[k] += 1
		}
		for v in tmp {
			k := (u64(v - min_v) >> 8) & 0xff
			data[c1[k]] = v
			c1[k] += 1
		}
		for v in data {
			k := u64(v - min_v) >> 16
			tmp[c2[k]] = v
			c2[k] += 1
		}
		copy(data, tmp)
		return
	}
	RADIX_BITS :: 11
	RADIX_SIZE :: 1 << RADIX_BITS
	RADIX_MASK :: RADIX_SIZE - 1
	c0: [RADIX_SIZE]u32
	c1: [RADIX_SIZE]u32
	for v in data {
		u := u64(v - min_v)
		c0[u & RADIX_MASK] += 1
		c1[u >> RADIX_BITS] += 1
	}
	s0, s1: u32
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

// Adaptive LSD radix sort on a struct slice by an i64 key.
// Returns true if radix-sorted by `key_fn`; returns false if caller should fall back to `fast_sort`.
@(private)
radix_sort_by_i64 :: proc(data: []$T, $key_fn: proc(v: T) -> i64) -> bool {
	n := len(data)
	if n < 96 {return false}
	min_v := key_fn(data[0])
	max_v := min_v
	for v in data[1:] {
		k := key_fn(v)
		if k < min_v {min_v = k}
		if k > max_v {max_v = k}
	}
	span := u64(max_v - min_v)
	if span == 0 {return true}
	if span >= (1 << 24) || (n >= 2048 && span >= (1 << 22)) {return false}
	tmp := make_temp_non_zeroed(T, n)
	if span < 256 {
		counts: [256]u32
		for v in data {counts[u64(key_fn(v) - min_v)] += 1}
		sum: u32
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
	if span < 65536 {
		c0: [256]u32
		c1: [256]u32
		for v in data {
			u := u64(key_fn(v) - min_v)
			c0[u & 0xff] += 1
			c1[u >> 8] += 1
		}
		s0, s1: u32
		for b in 0..<256 {
			t0 := c0[b]; c0[b] = s0; s0 += t0
			t1 := c1[b]; c1[b] = s1; s1 += t1
		}
		for v in data {
			k := u64(key_fn(v) - min_v) & 0xff
			tmp[c0[k]] = v
			c0[k] += 1
		}
		for v in tmp {
			k := u64(key_fn(v) - min_v) >> 8
			data[c1[k]] = v
			c1[k] += 1
		}
		return true
	}
	if n < 2048 {
		c0: [256]u32
		c1: [256]u32
		c2: [256]u32
		for v in data {
			u := u64(key_fn(v) - min_v)
			c0[u & 0xff] += 1
			c1[(u >> 8) & 0xff] += 1
			c2[u >> 16] += 1
		}
		s0, s1, s2: u32
		for b in 0..<256 {
			t0 := c0[b]; c0[b] = s0; s0 += t0
			t1 := c1[b]; c1[b] = s1; s1 += t1
			t2 := c2[b]; c2[b] = s2; s2 += t2
		}
		for v in data {
			k := u64(key_fn(v) - min_v) & 0xff
			tmp[c0[k]] = v
			c0[k] += 1
		}
		for v in tmp {
			k := (u64(key_fn(v) - min_v) >> 8) & 0xff
			data[c1[k]] = v
			c1[k] += 1
		}
		for v in data {
			k := u64(key_fn(v) - min_v) >> 16
			tmp[c2[k]] = v
			c2[k] += 1
		}
		copy(data, tmp)
		return true
	}
	RADIX_BITS :: 11
	RADIX_SIZE :: 1 << RADIX_BITS
	RADIX_MASK :: RADIX_SIZE - 1
	c0: [RADIX_SIZE]u32
	c1: [RADIX_SIZE]u32
	for v in data {
		u := u64(key_fn(v) - min_v)
		c0[u & RADIX_MASK] += 1
		c1[u >> RADIX_BITS] += 1
	}
	s0, s1: u32
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
