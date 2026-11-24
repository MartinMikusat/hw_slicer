package features

import workers "../workers"

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
