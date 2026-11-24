package toolpath

import "core:math"

// Timed toolpath of one print file: the G-code state, the look-ahead queue and a ring of
// committed moves that keeps the most recent `capacity` moves.
LINE_BYTES_MAX :: 1024

Path :: struct {
	moves: []Move,
	count: u64,
	queue: [dynamic]Pending,
	junctions: [dynamic]Junction,
	junction_flush, cursor_time: f64,
	next_dwell: f64,
	next_barrier: bool,
	limits: Limits,
	junction_deviation, mcr_pseudo_accel: f64,
	// gcode_move state
	last, base, commanded: [4]f64,
	absolute, absolute_e: bool,
	speed, speed_factor, extrude_factor: f64,
	line: [LINE_BYTES_MAX]u8,
	line_len: int,
	line_offset: i64,
	line_overflow: bool,
	parsed: i64,
	finished: bool,
	// Extruded beads committed since the owner last drained them, in time order.
	deposits: [dynamic]Deposit,
	layer_z, layer_height: f64,
	tone: u8,
}

init :: proc(p: ^Path, capacity: int, limits: Limits, allocator := context.allocator) {
	assert(capacity > 0)
	assert(limits.max_velocity > 0 && limits.max_accel > 0)
	p^ = {}
	p.moves = make([]Move, capacity, allocator)
	p.queue = make([dynamic]Pending, 0, 256, allocator)
	p.junctions = make([dynamic]Junction, 0, 256, allocator)
	p.deposits = make([dynamic]Deposit, 0, 4096, allocator)
	p.tone = TONE_DEFAULT
	p.limits = limits
	limits_changed(p)
	p.junction_flush = BUFFER_TIME_HIGH
	p.absolute, p.absolute_e = true, true
	p.speed = 25
	p.speed_factor = 1.0 / 60.0
	p.extrude_factor = 1
}

destroy :: proc(p: ^Path) {
	delete(p.moves)
	delete(p.queue)
	delete(p.junctions)
	delete(p.deposits)
	p^ = {}
}

// Parses the next bytes of the file, which must continue at p.parsed.
feed :: proc(p: ^Path, data: []byte) {
	assert(!p.finished)
	for b in data {
		if b == '\n' {
			if !p.line_overflow {run_line(p, string(p.line[:p.line_len]), p.line_offset)}
			p.line_len = 0
			p.line_overflow = false
			p.parsed += 1
			p.line_offset = p.parsed
			continue
		}
		if p.line_len < LINE_BYTES_MAX {
			p.line[p.line_len] = b
			p.line_len += 1
		} else {
			p.line_overflow = true
		}
		p.parsed += 1
	}
}

// Ends the file: the printer stops after the last move.
finish :: proc(p: ^Path) {
	if p.finished {return}
	if p.line_len > 0 && !p.line_overflow {run_line(p, string(p.line[:p.line_len]), p.line_offset)}
	p.line_len = 0
	flush(p, false)
	p.finished = true
}

move_duration :: proc(m: Move) -> f64 {return f64(m.accel_t) + f64(m.cruise_t) + f64(m.decel_t)}

// Distance travelled `rel` seconds into the move.
move_distance :: proc(m: Move, rel: f64) -> f64 {
	r := clamp(rel, 0, move_duration(m))
	a, v0, vc := f64(m.accel), f64(m.start_v), f64(m.cruise_v)
	at, ct := f64(m.accel_t), f64(m.cruise_t)
	accel_d := (v0 + vc) * 0.5 * at
	if r < at {return v0 * r + 0.5 * a * r * r}
	if r < at + ct {return accel_d + vc * (r - at)}
	d := r - at - ct
	return accel_d + vc * ct + vc * d - 0.5 * a * d * d
}

// Seconds into the move at which it has travelled `dist`.
move_time_at :: proc(m: Move, dist: f64) -> f64 {
	a, v0, vc := f64(m.accel), f64(m.start_v), f64(m.cruise_v)
	at, ct := f64(m.accel_t), f64(m.cruise_t)
	accel_d := (v0 + vc) * 0.5 * at
	cruise_d := vc * ct
	d := max(dist, 0)
	if d <= accel_d {
		if a <= 0 {return d / max(v0, 1e-9)}
		return (-v0 + math.sqrt(v0 * v0 + 2 * a * d)) / a
	}
	if d <= accel_d + cruise_d {return at + (d - accel_d) / max(vc, 1e-9)}
	rd := d - accel_d - cruise_d
	if a <= 0 {return at + ct + rd / max(vc, 1e-9)}
	return min(at + ct + (vc - math.sqrt(max(vc * vc - 2 * a * rd, 0))) / a, move_duration(m))
}

move_position :: proc(m: Move, rel: f64) -> [3]f32 {
	return m.start + m.dir * f32(move_distance(m, rel))
}

@(private)
first_index :: proc(p: ^Path) -> u64 {
	capacity := u64(len(p.moves))
	return p.count - capacity if p.count > capacity else 0
}

@(private)
at :: proc(p: ^Path, i: u64) -> Move {return p.moves[i % u64(len(p.moves))]}

// Index of the last retained move starting at or before t.
@(private)
index_at :: proc(p: ^Path, t: f64) -> (index: u64, ok: bool) {
	lo, hi := first_index(p), p.count
	if lo == hi || at(p, lo).time > t {return lo, false}
	for hi - lo > 1 {
		mid := lo + (hi - lo) / 2
		if at(p, mid).time <= t {lo = mid} else {hi = mid}
	}
	return lo, true
}

// Time range of the retained, committed moves.
span :: proc(p: ^Path) -> (start, end: f64, ok: bool) {
	if p.count == 0 {return 0, 0, false}
	first, last := at(p, first_index(p)), at(p, p.count - 1)
	return first.time, last.time + move_duration(last), true
}

position :: proc(p: ^Path, t: f64) -> (pos: [3]f32, ok: bool) {
	if p.count == 0 {return {}, false}
	i, found := index_at(p, t)
	m := at(p, i)
	if !found {return m.start, true}
	return move_position(m, t - m.time), true
}

// End of the moves read before file offset `offset`: Klipper has executed nothing after it.
time_at_offset :: proc(p: ^Path, offset: i64) -> (t: f64, ok: bool) {
	if p.count == 0 {return 0, false}
	lo, hi := first_index(p), p.count
	if at(p, lo).offset >= offset {return 0, false}
	if at(p, hi - 1).offset < offset && !p.finished && offset > p.parsed {return 0, false}
	for hi - lo > 1 {
		mid := lo + (hi - lo) / 2
		if at(p, mid).offset < offset {lo = mid} else {hi = mid}
	}
	m := at(p, lo)
	return m.time + move_duration(m), true
}

// First barrier at or after `after` and no later than `until`. A sample confirmed exactly at a
// barrier (the toolhead still waiting there) keeps it in force.
next_barrier :: proc(p: ^Path, after, until: f64) -> (t: f64, ok: bool) {
	i, _ := index_at(p, after)
	for ; i < p.count; i += 1 {
		m := at(p, i)
		if m.time > until {break}
		if m.barrier && m.time >= after {return m.time, true}
	}
	return 0, false
}

// The time in [t0, t1] whose position is nearest `pos`, preferring times near `predicted`:
// each second away from it costs `weight` millimetres.
match :: proc(p: ^Path, pos: [3]f32, t0, t1, predicted, weight: f64) -> (t, dist: f64, ok: bool) {
	if p.count == 0 || t1 <= t0 {return}
	i, _ := index_at(p, t0)
	best := max(f64)
	target := [3]f64{f64(pos[0]), f64(pos[1]), f64(pos[2])}
	for ; i < p.count; i += 1 {
		m := at(p, i)
		if m.time > t1 {break}
		duration := move_duration(m)
		lo, hi := max(t0 - m.time, 0), min(t1 - m.time, duration)
		if hi < lo {continue}
		start := [3]f64{f64(m.start[0]), f64(m.start[1]), f64(m.start[2])}
		dir := [3]f64{f64(m.dir[0]), f64(m.dir[1]), f64(m.dir[2])}
		rel: f64
		if dir == {} {
			rel = clamp(predicted - m.time, lo, hi)
		} else {
			d_lo, d_hi := move_distance(m, lo), move_distance(m, hi)
			along := clamp((target - start)[0] * dir[0] + (target - start)[1] * dir[1] + (target - start)[2] * dir[2], d_lo, d_hi)
			rel = clamp(move_time_at(m, along), lo, hi)
		}
		q := move_position(m, rel)
		delta := target - [3]f64{f64(q[0]), f64(q[1]), f64(q[2])}
		d := math.sqrt(delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2])
		score := d + weight * abs(m.time + rel - predicted)
		if score < best {
			best = score
			t, dist, ok = m.time + rel, d, true
		}
	}
	return
}
