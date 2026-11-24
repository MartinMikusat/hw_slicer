package toolpath

// Locks the simulated timeline to the printer clock. Each live position sample either confirms
// the playback (its position lies on the planned path near the predicted time) or corrects it.

LOCK_TOLERANCE_MM :: 1.5
LOCK_WINDOW_SECONDS :: 1.0
LOCK_JUMP_SECONDS :: 0.4
LOCK_MISSES_MAX :: 4
// Klipper reads a few seconds of moves ahead of the motion it executes.
SEARCH_BEHIND_SECONDS :: 8.0

Lock_State :: enum u8 {Searching, Locked}

Lock :: struct {
	state: Lock_State,
	anchor_e, anchor_t, rate: f64,
	candidate_e, candidate_t: f64,
	has_candidate: bool,
	misses: int,
	// Simulated time of the last confirmed sample; playback holds at barriers after it.
	confirmed_t: f64,
}

lock_time :: proc(l: ^Lock, eventtime: f64) -> f64 {
	return l.anchor_t + l.rate * (eventtime - l.anchor_e)
}

@(private)
lock_acquire :: proc(l: ^Lock, eventtime, t: f64) {
	l.state = .Locked
	l.anchor_e, l.anchor_t, l.rate = eventtime, t, 1
	l.misses = 0
	l.has_candidate = false
	l.confirmed_t = t
}

// Feeds one printer sample: `pos` was the commanded position at printer time `eventtime`.
// Returns true when the lock state changed.
lock_sample :: proc(l: ^Lock, p: ^Path, eventtime: f64, pos: [3]f32, file_position: i64, has_file_position: bool) -> bool {
	previous := l.state
	switch l.state {
	case .Locked:
		predicted := lock_time(l, eventtime)
		// After an unconfirmed barrier the printer resumes from the barrier at an unknown time.
		barrier, after_barrier := next_barrier(p, l.confirmed_t, predicted)
		if after_barrier {predicted = barrier}
		t, dist, ok := match(p, pos, predicted - LOCK_WINDOW_SECONDS, predicted + LOCK_WINDOW_SECONDS, predicted, 2)
		if ok && dist <= LOCK_TOLERANCE_MM {
			err := t - predicted
			if after_barrier || abs(err) > LOCK_JUMP_SECONDS {
				l.anchor_e, l.anchor_t = eventtime, t
			} else {
				l.anchor_t, l.anchor_e = predicted + 0.5 * err, eventtime
				l.rate = clamp(l.rate + 0.08 * err, 0.25, 4)
			}
			l.misses = 0
			l.confirmed_t = t
		} else {
			l.misses += 1
			if l.misses >= LOCK_MISSES_MAX {
				l.state = .Searching
				l.has_candidate = false
			}
		}
	case .Searching:
		if l.has_candidate {
			predicted := l.candidate_t + (eventtime - l.candidate_e)
			t, dist, ok := match(p, pos, predicted - 0.5, predicted + 0.75, predicted, 2)
			if ok && dist <= LOCK_TOLERANCE_MM {
				lock_acquire(l, eventtime, t)
				break
			}
		}
		l.has_candidate = false
		if !has_file_position {break}
		read_t, ok := time_at_offset(p, file_position)
		if !ok {break}
		t, dist, found := match(p, pos, read_t - SEARCH_BEHIND_SECONDS, read_t, read_t, 0.05)
		if found && dist <= LOCK_TOLERANCE_MM {
			l.candidate_e, l.candidate_t, l.has_candidate = eventtime, t, true
		}
	}
	return l.state != previous
}

// Simulated time to draw at printer time `eventtime`: the toolhead waits at a barrier until a
// sample confirms the printer has passed it, and at the end of the planned moves.
lock_render_time :: proc(l: ^Lock, p: ^Path, eventtime: f64) -> f64 {
	t := lock_time(l, eventtime)
	if barrier, ok := next_barrier(p, l.confirmed_t, t); ok {t = barrier}
	if _, end, ok := span(p); ok {t = min(t, end)}
	return t
}
