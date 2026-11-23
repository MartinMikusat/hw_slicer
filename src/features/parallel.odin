package features

import "core:sync"
import "core:thread"

@(private)
g_worker_threads: int = 1

set_worker_threads :: proc(n: int) {
	g_worker_threads = clamp(n, 1, 16)
}

get_worker_threads :: proc() -> int {
	return clamp(g_worker_threads, 1, 16)
}

// Runs `body(ctx, index)` for index in 0..<count across up to `get_worker_threads()` threads
// using atomic dynamic work-stealing. Caller ensures each index writes to disjoint storage.
@(private)
parallel_for :: proc(count: int, ctx: ^$T, body: proc(ctx: ^T, index: int)) {
	if count <= 0 {return}
	workers := get_worker_threads()
	if workers <= 1 || count < 4 {
		for i in 0..<count {body(ctx, i)}
		return
	}

	Runner :: struct {
		ctx:   ^T,
		body:  proc(ctx: ^T, index: int),
		next:  int,
		count: int,
	}
	r := Runner{ctx = ctx, body = body, next = 0, count = count}
	worker_fn :: proc(rp: ^Runner) {
		for {
			idx := sync.atomic_add(&rp.next, 1)
			if idx >= rp.count {break}
			rp.body(rp.ctx, idx)
		}
	}
	spawned_worker_fn :: proc(rp: ^Runner) {
		defer free_all(context.temp_allocator)
		worker_fn(rp)
	}

	spawn_count := min(workers - 1, count - 1)
	threads: [15]^thread.Thread
	for wi in 0..<spawn_count {
		threads[wi] = thread.create_and_start_with_poly_data(&r, spawned_worker_fn)
	}
	worker_fn(&r)
	for wi in 0..<spawn_count {
		if threads[wi] != nil {
			thread.join(threads[wi])
			thread.destroy(threads[wi])
		}
	}
}
