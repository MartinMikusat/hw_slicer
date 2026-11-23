package polygon

// Deterministic in-place sort for the polygon engine's hot paths: quicksort with a
// median-of-three pivot, insertion sort below 16 elements, and recursion into the smaller side
// only. Not stable; callers give total orders or do not depend on the order of equal elements.
@(private)
fast_sort :: proc(data: []$T, less: proc(a, b: T) -> bool) {
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
