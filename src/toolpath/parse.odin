package toolpath

import "core:math"
import "core:strconv"
import "core:strings"

// Klipper's G-code handling (klippy/gcode.py, extras/gcode_move.py, extras/gcode_arcs.py and the
// toolhead commands) for the commands that change motion or its timing.

// Commands after which the printer waits an unknown time or moves outside the file.
@(private)
HARD_BARRIERS := [?]string{
	"G28", "M109", "M190", "M191", "M400", "M600", "M0", "M1", "TEMPERATURE_WAIT", "PAUSE",
	"PRINT_START", "START_PRINT", "PRINT_END", "END_PRINT", "BED_MESH_CALIBRATE",
	"QUAD_GANTRY_LEVEL", "Z_TILT_ADJUST", "PROBE", "PROBE_CALIBRATE",
}

@(private)
Params :: struct {
	values: [26]f64,
	present: bit_set[0 ..< 26],
}

@(private)
param :: proc(ps: ^Params, letter: u8) -> (value: f64, ok: bool) {
	i := int(letter - 'A')
	if i in ps.present {return ps.values[i], true}
	return 0, false
}

// Parses the letter-value words after a traditional command, as Klipper's argument split does.
@(private)
parse_words :: proc(rest: string) -> (ps: Params) {
	i := 0
	for i < len(rest) {
		c := rest[i]
		if c < 'A' || c > 'Z' {i += 1; continue}
		j := i + 1
		for j < len(rest) && (rest[j] < 'A' || rest[j] > 'Z') && rest[j] != ' ' {j += 1}
		if value, ok := strconv.parse_f64(strings.trim_space(rest[i + 1:j])); ok && !math.is_nan(value) && !math.is_inf(value) {
			ps.values[c - 'A'] = value
			ps.present += {int(c - 'A')}
		}
		i = j
	}
	return
}

// KEY=value parameter of an extended command.
@(private)
extended_param :: proc(rest, key: string) -> (value: f64, ok: bool) {
	words := rest
	for word in strings.split_iterator(&words, " ") {
		eq := strings.index_byte(word, '=')
		if eq <= 0 || word[:eq] != key {continue}
		value, ok = strconv.parse_f64(word[eq + 1:])
		if ok && (math.is_nan(value) || math.is_inf(value)) {ok = false}
		return
	}
	return
}

@(private)
run_line :: proc(p: ^Path, raw: string, offset: i64) {
	buffer: [LINE_BYTES_MAX]u8
	text := raw
	if semicolon := strings.index_byte(text, ';'); semicolon >= 0 {
		feature_comment(p, text[semicolon + 1:])
		text = text[:semicolon]
	}
	if star := strings.index_byte(text, '*'); star >= 0 {text = text[:star]}
	text = strings.trim_space(text)
	if len(text) == 0 {return}
	for i in 0 ..< len(text) {
		c := text[i]
		buffer[i] = c - 32 if c >= 'a' && c <= 'z' else c
	}
	line := string(buffer[:len(text)])
	if line[0] == 'N' && len(line) > 1 && line[1] >= '0' && line[1] <= '9' {
		space := strings.index_byte(line, ' ')
		if space < 0 {return}
		line = strings.trim_space(line[space:])
	}
	command, rest := line, ""
	if line[0] >= 'A' && line[0] <= 'Z' && len(line) > 1 && line[1] >= '0' && line[1] <= '9' {
		// Traditional command: a letter and a number, parameters may follow without spaces.
		end := 1
		for end < len(line) && ((line[end] >= '0' && line[end] <= '9') || line[end] == '.') {end += 1}
		command, rest = line[:end], line[end:]
	} else if space := strings.index_byte(line, ' '); space >= 0 {
		command, rest = line[:space], line[space + 1:]
	}
	switch command {
	case "G0", "G1":
		ps := parse_words(rest)
		run_g1(p, &ps, offset)
	case "G2", "G3":
		ps := parse_words(rest)
		run_arc(p, &ps, command == "G2", offset)
	case "G4":
		ps := parse_words(rest)
		delay, _ := param(&ps, 'P')
		flush(p, false)
		p.next_dwell += max(delay, 0) / 1000
	case "G90": p.absolute = true
	case "G91": p.absolute = false
	case "M82": p.absolute_e = true
	case "M83": p.absolute_e = false
	case "G92":
		ps := parse_words(rest)
		any := false
		for letter, i in ([4]u8{'X', 'Y', 'Z', 'E'}) {
			if value, ok := param(&ps, letter); ok {
				if i == 3 {value *= p.extrude_factor}
				p.base[i] = p.last[i] - value
				any = true
			}
		}
		if !any {p.base = p.last}
	case "M220":
		ps := parse_words(rest)
		value, ok := param(&ps, 'S')
		if !ok {value = 100}
		if value > 0 {
			value /= 60 * 100
			p.speed = p.speed / p.speed_factor * value
			p.speed_factor = value
		}
	case "M221":
		ps := parse_words(rest)
		value, ok := param(&ps, 'S')
		if !ok {value = 100}
		if value > 0 {
			factor := value / 100
			e_value := (p.last[3] - p.base[3]) / p.extrude_factor
			p.base[3] = p.last[3] - e_value * factor
			p.extrude_factor = factor
		}
	case "M204":
		ps := parse_words(rest)
		accel, ok := param(&ps, 'S')
		if !ok {
			pa, p_ok := param(&ps, 'P')
			ta, t_ok := param(&ps, 'T')
			if !p_ok || !t_ok {return}
			accel = min(pa, ta)
		}
		if accel > 0 {p.limits.max_accel = accel; limits_changed(p)}
	case "SET_VELOCITY_LIMIT":
		l := &p.limits
		if v, ok := extended_param(rest, "VELOCITY"); ok && v > 0 {l.max_velocity = v}
		if v, ok := extended_param(rest, "ACCEL"); ok && v > 0 {l.max_accel = v}
		if v, ok := extended_param(rest, "SQUARE_CORNER_VELOCITY"); ok && v >= 0 {l.square_corner_velocity = v}
		if v, ok := extended_param(rest, "MINIMUM_CRUISE_RATIO"); ok && v >= 0 && v < 1 {l.minimum_cruise_ratio = v}
		limits_changed(p)
	case:
		for barrier in HARD_BARRIERS {
			if command == barrier {
				flush(p, false)
				p.next_barrier = true
				break
			}
		}
	}
}

@(private)
run_g1 :: proc(p: ^Path, ps: ^Params, offset: i64) {
	for letter, i in ([4]u8{'X', 'Y', 'Z', 'E'}) {
		value, ok := param(ps, letter)
		if !ok {continue}
		absolute := p.absolute
		if i == 3 {
			value *= p.extrude_factor
			if !p.absolute_e {absolute = false}
		}
		if absolute {p.last[i] = value + p.base[i]} else {p.last[i] += value}
	}
	if feed, ok := param(ps, 'F'); ok && feed > 0 {p.speed = feed * p.speed_factor}
	submit_move(p, p.last, p.speed, offset)
}

// gcode_arcs.planArc in the XY plane: splits the arc into G1 segments of the configured length.
@(private)
run_arc :: proc(p: ^Path, ps: ^Params, clockwise: bool, offset: i64) {
	if !p.absolute {return}
	current: [4]f64
	for i in 0 ..< 4 {current[i] = p.last[i] - p.base[i]}
	target := [3]f64{current[0], current[1], current[2]}
	if v, ok := param(ps, 'X'); ok {target[0] = v}
	if v, ok := param(ps, 'Y'); ok {target[1] = v}
	if v, ok := param(ps, 'Z'); ok {target[2] = v}
	i_off, _ := param(ps, 'I')
	j_off, _ := param(ps, 'J')
	if i_off == 0 && j_off == 0 {return}
	r_p, r_q := -i_off, -j_off
	center_p, center_q := current[0] - r_p, current[1] - r_q
	rt_alpha, rt_beta := target[0] - center_p, target[1] - center_q
	angular := math.atan2(r_p * rt_beta - r_q * rt_alpha, r_p * rt_alpha + r_q * rt_beta)
	if angular < 0 {angular += 2 * math.PI}
	if clockwise {angular -= 2 * math.PI}
	if angular == 0 && current[0] == target[0] && current[1] == target[1] {angular = 2 * math.PI}
	linear := target[2] - current[2]
	flat := math.hypot(r_p, r_q) * angular
	travel := math.hypot(flat, linear) if linear != 0 else abs(flat)
	segments := max(1, math.floor(travel / max(p.limits.arc_resolution, 0.01)))
	segments = min(segments, 100000)
	theta_per, linear_per := angular / segments, linear / segments
	e_value, has_e := param(ps, 'E')
	e_per, e_base := f64(0), f64(0)
	if has_e {
		if p.absolute_e {e_base = current[3]}
		e_per = (e_value - e_base) / segments
	}
	feed, has_f := param(ps, 'F')
	count := int(segments)
	for k in 1 ..= count {
		theta := f64(k) * theta_per
		cos_t, sin_t := math.cos(theta), math.sin(theta)
		seg: Params
		x := center_p + (-i_off * cos_t + j_off * sin_t)
		y := center_q + (-i_off * sin_t - j_off * cos_t)
		z := current[2] + f64(k) * linear_per
		if k == count {x, y, z = target[0], target[1], target[2]}
		seg.values[int('X' - 'A')], seg.values[int('Y' - 'A')], seg.values[int('Z' - 'A')] = x, y, z
		seg.present += {int('X' - 'A'), int('Y' - 'A'), int('Z' - 'A')}
		if e_per != 0 {
			seg.values[int('E' - 'A')] = e_base + e_per
			seg.present += {int('E' - 'A')}
			if p.absolute_e {e_base += e_per}
		}
		if has_f {
			seg.values[int('F' - 'A')] = feed
			seg.present += {int('F' - 'A')}
		}
		run_g1(p, &seg, offset)
	}
}

TONE_DEFAULT :: 200

// Grey tone of the feature a slicer names in a `;TYPE:` comment (PrusaSlicer, SuperSlicer,
// OrcaSlicer and Cura): outer walls lightest, supports darkest.
@(private)
feature_comment :: proc(p: ^Path, comment: string) {
	text := strings.trim_space(comment)
	if !strings.has_prefix(text, "TYPE:") {return}
	name := strings.to_lower(text[5:], context.temp_allocator)
	switch {
	case strings.contains(name, "support"): p.tone = 120
	case strings.contains(name, "outer") || strings.contains(name, "external"): p.tone = 235
	case strings.contains(name, "top") || strings.contains(name, "ironing"): p.tone = 225
	case strings.contains(name, "wall") || strings.contains(name, "perimeter"): p.tone = 205
	case strings.contains(name, "bridge") || strings.contains(name, "overhang"): p.tone = 190
	case strings.contains(name, "infill") || strings.contains(name, "fill") || strings.contains(name, "skin"): p.tone = 165
	case strings.contains(name, "skirt") || strings.contains(name, "brim"): p.tone = 180
	case: p.tone = TONE_DEFAULT
	}
}
