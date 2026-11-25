package workers

import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:sync"
import "core:thread"

// Most threads a parallel loop uses, the calling thread included.
MAX_WORKERS :: 16

// Per-thread growing virtual arena for worker-loop scratch allocations that must not alias
// `context.temp_allocator` (e.g. intermediate `Polygon_Set`s returned by `odin_vatti_boolean`,
// which itself uses `DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()` internally). Reclaimed automatically
// at the end of every `parallel_for` iteration.
@(private = "file", thread_local)
g_worker_scratch: virtual.Arena
@(private = "file", thread_local)
g_worker_scratch_init: bool

scratch_allocator :: proc() -> mem.Allocator {
	if !g_worker_scratch_init {
		_ = virtual.arena_init_growing(&g_worker_scratch)
		g_worker_scratch_init = true
	}
	return virtual.arena_allocator(&g_worker_scratch)
}

scratch_destroy :: proc() {
	if g_worker_scratch_init {
		virtual.arena_destroy(&g_worker_scratch)
		g_worker_scratch_init = false
	}
}

// One process-wide set of worker threads that every parallel loop of the slicer shares. Threads
// start on first use and are never stopped; idle threads wait on a condition variable. Several
// threads may run parallel loops at the same time, and a loop may run inside another loop's body.
@(private = "file")
Pool :: struct {
	mutex:        sync.Mutex,
	// Signalled when a job is posted and when the last helper leaves a job.
	changed:      sync.Cond,
	jobs:         [dynamic]^Job,
	threads:      [MAX_WORKERS-1]^thread.Thread,
	thread_count: int,
}

@(private = "file")
g_pool: Pool

// A posted loop. `work` pulls indices until none are left.
@(private = "file")
Job :: struct {
	work:        proc(job: ^Job),
	next:        int,
	count:       int,
	// Threads other than the caller currently inside `work`, and how many may join.
	helpers:     int,
	max_helpers: int,
	// The caller's assertion handler, so a failure on a pool thread is recorded like one on the caller.
	assertion_failure_proc: runtime.Assertion_Failure_Proc,
}

// Runs `body(ctx, index)` for every index in 0..<count on up to `limit` threads, the caller
// included, and returns when all indices are done. Indices are handed out one at a time from an
// atomic counter, so each index must write only storage of its own. Below `min_count` indices, or
// with a limit of 1, the caller runs every index itself.
parallel_for :: proc(count: int, ctx: ^$T, body: proc(ctx: ^T, index: int), limit: int, min_count := 4) {
	if count <= 0 {return}
	workers := clamp(limit, 1, MAX_WORKERS)
	if workers <= 1 || count < min_count {
		for i in 0..<count {
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
			had_scratch := g_worker_scratch_init
			mark: virtual.Arena_Temp
			if had_scratch {mark = virtual.arena_temp_begin(&g_worker_scratch)}
			body(ctx, i)
			if had_scratch {
				virtual.arena_temp_end(mark)
			} else if g_worker_scratch_init {
				virtual.arena_free_all(&g_worker_scratch)
			}
		}
		return
	}
	Typed_Job :: struct {
		job:  Job,
		ctx:  ^T,
		body: proc(ctx: ^T, index: int),
	}
	typed := Typed_Job{ctx = ctx, body = body}
	typed.job.count = count
	typed.job.max_helpers = min(workers-1, count-1)
	typed.job.work = proc(job: ^Job) {
		t := (^Typed_Job)(job)
		for {
			index := sync.atomic_add(&job.next, 1)
			if index >= job.count {break}
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
			had_scratch := g_worker_scratch_init
			mark: virtual.Arena_Temp
			if had_scratch {mark = virtual.arena_temp_begin(&g_worker_scratch)}
			t.body(t.ctx, index)
			if had_scratch {
				virtual.arena_temp_end(mark)
			} else if g_worker_scratch_init {
				virtual.arena_free_all(&g_worker_scratch)
			}
		}
	}
	run(&typed.job, workers-1)
}

@(private = "file")
run :: proc(job: ^Job, threads_wanted: int) {
	p := &g_pool
	job.assertion_failure_proc = context.assertion_failure_proc
	sync.mutex_lock(&p.mutex)
	// The job list outlives every caller, so it must not use a caller's (possibly arena) allocator.
	if p.jobs == nil {p.jobs = make([dynamic]^Job, 0, 32, runtime.heap_allocator())}
	for p.thread_count < threads_wanted {
		p.threads[p.thread_count] = thread.create_and_start_with_poly_data(p, worker_main)
		p.thread_count += 1
	}
	append(&p.jobs, job)
	sync.cond_broadcast(&p.changed)
	sync.mutex_unlock(&p.mutex)

	job.work(job)

	// No helper may join once the job is off the list; wait for those still inside it, because
	// the job and its context live on this thread's stack.
	sync.mutex_lock(&p.mutex)
	for posted, index in p.jobs {
		if posted == job {
			ordered_remove(&p.jobs, index)
			break
		}
	}
	for job.helpers > 0 {sync.cond_wait(&p.changed, &p.mutex)}
	sync.mutex_unlock(&p.mutex)
}

@(private = "file")
worker_main :: proc(p: ^Pool) {
	sync.mutex_lock(&p.mutex)
	for {
		job := find_job(p)
		for job == nil {
			sync.cond_wait(&p.changed, &p.mutex)
			job = find_job(p)
		}
		job.helpers += 1
		sync.mutex_unlock(&p.mutex)
		context.assertion_failure_proc = job.assertion_failure_proc
		job.work(job)
		free_all(context.temp_allocator)
		sync.mutex_lock(&p.mutex)
		job.helpers -= 1
		if job.helpers == 0 {sync.cond_broadcast(&p.changed)}
	}
}

// A posted job that still has indices and room for another helper. The caller holds the mutex.
@(private = "file")
find_job :: proc(p: ^Pool) -> ^Job {
	for job in p.jobs {
		if job.helpers < job.max_helpers && sync.atomic_load(&job.next) < job.count {return job}
	}
	return nil
}
