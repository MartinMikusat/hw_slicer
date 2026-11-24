package toolpath

import "core:math"

// Klipper's look-ahead planner (klippy/toolhead.py Move and LookAheadQueue) applied to the moves of
// a G-code file, producing the timed trapezoid of every move.

LOOKAHEAD_FLUSH_TIME :: 0.150
BUFFER_TIME_HIGH :: 1.0
QUEUE_MOVES_MAX :: 8192
UNLIMITED_ACCEL :: 99999999.9
UNLIMITED_V2 :: 999999999.9

Limits :: struct {
	max_velocity, max_accel, square_corner_velocity, minimum_cruise_ratio: f64,
	max_z_velocity, max_z_accel: f64,
	max_extrude_only_velocity, max_extrude_only_accel, instantaneous_corner_velocity: f64,
	arc_resolution: f64,
	filament_diameter: f64,
}

// Material laid down by one extruding move: a bead whose top runs from p0 to p1.
Deposit :: struct {
	p0, p1: [3]f32,
	t0, t1: f64,
	width, height: f32,
	tone: u8,
}

// One timed move. Position at distance d along the move is start + dir * d.
Move :: struct {
	time: f64,
	offset: i64,
	start, dir: [3]f32,
	start_v, cruise_v, accel: f32,
	accel_t, cruise_t, decel_t: f32,
	// The printer may wait an unknown time before this move (heating, homing, macros).
	barrier: bool,
}

@(private)
Pending :: struct {
	start: [3]f64,
	axes_r: [3]f64,
	e_r: f64,
	move_d, accel, junction_deviation, min_move_t: f64,
	max_start_v2, max_cruise_v2, delta_v2, next_junction_v2: f64,
	max_mcr_start_v2, mcr_delta_v2: f64,
	kinematic, barrier: bool,
	dwell: f64,
	offset: i64,
	// Bead cross-section for an extruding move, zero width otherwise.
	width, height: f32,
	tone: u8,
}

@(private)
Junction :: struct {
	start_v2, cruise_v2, next_start_v2: f64,
	has_cruise: bool,
}

@(private)
limit_speed :: proc(m: ^Pending, speed, accel: f64) {
	speed2 := speed * speed
	if speed2 < m.max_cruise_v2 {
		m.max_cruise_v2 = speed2
		m.min_move_t = m.move_d / speed
	}
	m.accel = min(m.accel, accel)
	m.delta_v2 = 2 * m.move_d * m.accel
	m.mcr_delta_v2 = min(m.mcr_delta_v2, m.delta_v2)
}

@(private)
calc_junction :: proc(p: ^Path, m, prev: ^Pending) {
	if !m.kinematic || !prev.kinematic {return}
	extruder_v2 := m.max_cruise_v2
	if diff_r := m.e_r - prev.e_r; diff_r != 0 {
		v := p.limits.instantaneous_corner_velocity / abs(diff_r)
		extruder_v2 = v * v
	}
	max_start_v2 := min(m.max_cruise_v2, prev.max_cruise_v2, prev.next_junction_v2,
		prev.max_start_v2 + prev.delta_v2, extruder_v2)
	cos_theta := -(m.axes_r[0] * prev.axes_r[0] + m.axes_r[1] * prev.axes_r[1] + m.axes_r[2] * prev.axes_r[2])
	sin_theta_d2 := math.sqrt(max(0.5 * (1 - cos_theta), 0))
	cos_theta_d2 := math.sqrt(max(0.5 * (1 + cos_theta), 0))
	one_minus_sin := 1 - sin_theta_d2
	if one_minus_sin > 0 && cos_theta_d2 > 0 {
		r_jd := sin_theta_d2 / one_minus_sin
		move_jd_v2 := r_jd * m.junction_deviation * m.accel
		pmove_jd_v2 := r_jd * prev.junction_deviation * prev.accel
		quarter_tan := 0.25 * sin_theta_d2 / cos_theta_d2
		max_start_v2 = min(max_start_v2, move_jd_v2, pmove_jd_v2, m.delta_v2 * quarter_tan, prev.delta_v2 * quarter_tan)
	}
	m.max_start_v2 = max_start_v2
	m.max_mcr_start_v2 = min(max_start_v2, prev.max_mcr_start_v2 + prev.mcr_delta_v2)
}

@(private)
limits_changed :: proc(p: ^Path) {
	l := &p.limits
	p.junction_deviation = l.square_corner_velocity * l.square_corner_velocity * (math.SQRT_TWO - 1) / l.max_accel
	p.mcr_pseudo_accel = l.max_accel * (1 - l.minimum_cruise_ratio)
}

// toolhead.move: queues the move from the commanded position to `target` at `speed` mm/s.
@(private)
submit_move :: proc(p: ^Path, target: [4]f64, speed: f64, offset: i64) {
	axes_d: [4]f64
	for i in 0 ..< 4 {axes_d[i] = target[i] - p.commanded[i]}
	m := Pending{start = {p.commanded[0], p.commanded[1], p.commanded[2]}, offset = offset,
		junction_deviation = p.junction_deviation, kinematic = true}
	velocity := min(speed, p.limits.max_velocity)
	m.accel = p.limits.max_accel
	m.move_d = math.sqrt(axes_d[0] * axes_d[0] + axes_d[1] * axes_d[1] + axes_d[2] * axes_d[2])
	if m.move_d < 1e-9 {
		axes_d[0], axes_d[1], axes_d[2] = 0, 0, 0
		m.move_d = abs(axes_d[3])
		if m.move_d == 0 {return}
		m.accel = UNLIMITED_ACCEL
		velocity = speed
		m.kinematic = false
	}
	if velocity <= 0 {return}
	inv := 1 / m.move_d
	m.axes_r = {axes_d[0] * inv, axes_d[1] * inv, axes_d[2] * inv}
	m.e_r = axes_d[3] * inv
	m.min_move_t = m.move_d / velocity
	m.max_cruise_v2 = velocity * velocity
	m.delta_v2 = 2 * m.move_d * m.accel
	m.next_junction_v2 = UNLIMITED_V2
	m.mcr_delta_v2 = 2 * m.move_d * p.mcr_pseudo_accel
	if m.kinematic && axes_d[2] != 0 {
		z_ratio := m.move_d / abs(axes_d[2])
		limit_speed(&m, p.limits.max_z_velocity * z_ratio, p.limits.max_z_accel * z_ratio)
	}
	if axes_d[3] != 0 && ((axes_d[0] == 0 && axes_d[1] == 0) || m.e_r < 0) {
		inv_r := 1 / abs(m.e_r)
		limit_speed(&m, p.limits.max_extrude_only_velocity * inv_r, p.limits.max_extrude_only_accel * inv_r)
	}
	if m.kinematic && m.e_r > 0 && (axes_d[0] != 0 || axes_d[1] != 0) {
		bead_shape(p, &m, target[2])
	}
	m.barrier, m.dwell = p.next_barrier, p.next_dwell
	p.next_barrier, p.next_dwell = false, 0
	p.commanded = target
	if !m.kinematic {p.commanded[0], p.commanded[1], p.commanded[2] = m.start[0], m.start[1], m.start[2]}
	append(&p.queue, m)
	if len(p.queue) == 1 {return}
	calc_junction(p, &p.queue[len(p.queue) - 1], &p.queue[len(p.queue) - 2])
	p.junction_flush -= m.min_move_t
	if p.junction_flush <= 0 {flush(p, true)}
	if len(p.queue) >= QUEUE_MOVES_MAX {flush(p, false)}
}

// LookAheadQueue.flush: commits the moves whose junction speeds are final (lazy) or all moves.
flush :: proc(p: ^Path, lazy: bool) {
	p.junction_flush = LOOKAHEAD_FLUSH_TIME
	queue := p.queue[:]
	update_flush_count := lazy
	flush_count := len(queue)
	if flush_count == 0 {return}
	resize(&p.junctions, flush_count)
	next_start_v2, next_mcr_start_v2, peak_cruise_v2 := f64(0), f64(0), f64(0)
	pending_cv2_assign := 0
	for i := flush_count - 1; i >= 0; i -= 1 {
		m := &queue[i]
		reachable_start_v2 := next_start_v2 + m.delta_v2
		start_v2 := min(m.max_start_v2, reachable_start_v2)
		j := Junction{start_v2 = start_v2, next_start_v2 = next_start_v2}
		pending_cv2_assign += 1
		reach_mcr_start_v2 := next_mcr_start_v2 + m.mcr_delta_v2
		mcr_start_v2 := min(m.max_mcr_start_v2, reach_mcr_start_v2)
		if mcr_start_v2 < reach_mcr_start_v2 {
			if mcr_start_v2 + m.mcr_delta_v2 > next_mcr_start_v2 || pending_cv2_assign > 1 {
				if update_flush_count && peak_cruise_v2 != 0 {
					flush_count = i + pending_cv2_assign
					update_flush_count = false
				}
				peak_cruise_v2 = (mcr_start_v2 + reach_mcr_start_v2) * 0.5
			}
			j.cruise_v2 = min((start_v2 + reachable_start_v2) * 0.5, m.max_cruise_v2, peak_cruise_v2)
			j.has_cruise = true
			pending_cv2_assign = 0
		}
		p.junctions[i] = j
		next_start_v2 = start_v2
		next_mcr_start_v2 = mcr_start_v2
	}
	if update_flush_count || flush_count == 0 {return}
	prev_cruise_v2 := f64(0)
	for i in 0 ..< flush_count {
		j := p.junctions[i]
		cruise_v2 := j.cruise_v2 if j.has_cruise else min(prev_cruise_v2, j.start_v2)
		commit(p, &queue[i], min(j.start_v2, cruise_v2), cruise_v2, min(j.next_start_v2, cruise_v2))
		prev_cruise_v2 = cruise_v2
	}
	remove_range(&p.queue, 0, flush_count)
}

// Move.set_junction, then appends the timed move to the ring.
@(private)
commit :: proc(p: ^Path, m: ^Pending, start_v2, cruise_v2, end_v2: f64) {
	half_inv_accel := 0.5 / m.accel
	accel_d := (cruise_v2 - start_v2) * half_inv_accel
	decel_d := (cruise_v2 - end_v2) * half_inv_accel
	cruise_d := m.move_d - accel_d - decel_d
	// Klipper never plans a zero cruise speed; a degenerate file must not stall the timeline.
	start_v, cruise_v, end_v := math.sqrt(max(start_v2, 0)), math.sqrt(max(cruise_v2, 1e-6)), math.sqrt(max(end_v2, 0))
	accel_t := accel_d / ((start_v + cruise_v) * 0.5) if start_v + cruise_v > 0 else 0
	cruise_t := cruise_d / cruise_v
	decel_t := decel_d / ((end_v + cruise_v) * 0.5) if end_v + cruise_v > 0 else 0
	p.cursor_time += m.dwell
	out := Move{
		time = p.cursor_time,
		offset = m.offset,
		start = {f32(m.start[0]), f32(m.start[1]), f32(m.start[2])},
		dir = {f32(m.axes_r[0]), f32(m.axes_r[1]), f32(m.axes_r[2])},
		start_v = f32(start_v),
		cruise_v = f32(cruise_v),
		accel = f32(m.accel),
		accel_t = f32(max(accel_t, 0)),
		cruise_t = f32(max(cruise_t, 0)),
		decel_t = f32(max(decel_t, 0)),
		barrier = m.barrier,
	}
	p.cursor_time += f64(out.accel_t) + f64(out.cruise_t) + f64(out.decel_t)
	if m.width > 0 {
		end := m.start + [3]f64{m.axes_r[0], m.axes_r[1], m.axes_r[2]} * m.move_d
		append(&p.deposits, Deposit{
			p0 = out.start, p1 = {f32(end[0]), f32(end[1]), f32(end[2])},
			t0 = out.time, t1 = p.cursor_time,
			width = m.width, height = m.height, tone = m.tone,
		})
	}
	p.moves[p.count % u64(len(p.moves))] = out
	p.count += 1
}

// Layer height from the step to this extrusion height, and the width that carries the extruded
// volume over that height.
@(private)
bead_shape :: proc(p: ^Path, m: ^Pending, z: f64) {
	if z > p.layer_z + 1e-3 {
		p.layer_height = z - p.layer_z if p.layer_z > 0 else z
		p.layer_z = z
	} else if z < p.layer_z - 1e-3 {
		p.layer_z = z
	}
	height := clamp(p.layer_height, 0.04, 1.2)
	radius := 0.5 * p.limits.filament_diameter
	area := m.e_r * math.PI * radius * radius
	m.height = f32(height)
	m.width = f32(clamp(area / height, 0.05, 3))
	m.tone = p.tone
}
