package design

import "core:math"
import "core:mem"
import "core:strconv"
import "core:strings"

import geometry "../geometry"

Bezier_Profile :: struct {
	name:  string,
	line:  int,
	loops: [dynamic]Bezier_Loop,
	paths: Profile_Paths,
}

Bezier_Loop :: struct {
	name:    string,
	line:    int,
	anchors: [dynamic]Bezier_Anchor,
}

Bezier_Anchor :: struct {
	name:            string,
	line:            int,
	smooth:          bool,
	position:        [2]f64,
	handles:         [2][2]f64,
	tangent_angle:   f64,
	handle_lengths:  [2]f64,
	shift:           [6]f64,
	saved_shift:     [6]f64,
	shift_spans:     [6][2]int,
	insert_at:       int,
}

@(private)
destroy_bezier_profile :: proc(profile: ^Bezier_Profile, allocator: mem.Allocator) {
	for loop in profile.loops {
		for anchor in loop.anchors {delete(anchor.name, allocator)}
		delete(loop.anchors)
		delete(loop.name, allocator)
	}
	delete(profile.loops)
	destroy_profile_paths(&profile.paths, allocator)
	free(profile, allocator)
}

anchor_controls :: proc(anchor: Bezier_Anchor) -> (controls: [3][2]f64) {
	controls[0] = anchor.position + {anchor.shift[0], anchor.shift[1]}
	if anchor.smooth {
		angle := anchor.tangent_angle + math.to_radians(anchor.shift[2])
		tangent := [2]f64{math.cos(angle), math.sin(angle)}
		controls[1] = -tangent*(anchor.handle_lengths[0]+anchor.shift[3])
		controls[2] = tangent*(anchor.handle_lengths[1]+anchor.shift[4])
	} else {
		controls[1] = anchor.handles[0] + {anchor.shift[2], anchor.shift[3]}
		controls[2] = anchor.handles[1] + {anchor.shift[4], anchor.shift[5]}
	}
	return
}

move_anchor_control :: proc(anchor: ^Bezier_Anchor, control: int, delta: [2]f64) {
	assert(control >= 0 && control < 3)
	if control == 0 || !anchor.smooth {
		anchor.shift[control*2] += delta.x
		anchor.shift[control*2+1] += delta.y
		return
	}
	vector := anchor_controls(anchor^)[control]+delta
	length := math.hypot(vector.x, vector.y)
	if length > EPSILON {
		tangent := -vector if control == 1 else vector
		anchor.shift[2] = math.to_degrees(math.atan2(tangent.y, tangent.x)-anchor.tangent_angle)
	}
	anchor.shift[control+2] = length-anchor.handle_lengths[control-1]
}

@(private)
parse_profile_loop :: proc(p: ^Parser, profile: ^Bezier_Profile) -> bool {
	head := expect(p, .Ident, "loop") or_return
	if head.text != "loop" {return fail(p, head.line, "expected loop(name, anchors...)")}
	expect(p, .Left_Paren, "'(' after loop") or_return
	name := expect(p, .Ident, "a loop name") or_return
	if len(profile.loops) >= 128 {return fail(p, head.line, "a profile can contain at most 128 loops")}
	for loop in profile.loops {
		if loop.name == name.text {return fail(p, name.line, "duplicate profile loop '%s'", name.text)}
	}
	append(&profile.loops, Bezier_Loop{
		name = strings.clone(name.text, p.allocator),
		line = name.line,
		anchors = make([dynamic]Bezier_Anchor, p.allocator),
	})
	loop := &profile.loops[len(profile.loops)-1]
	for peek(p).kind == .Comma {
		_ = next(p)
		if len(loop.anchors) >= 1024 {return fail(p, name.line, "loop '%s' exceeds 1024 anchors", name.text)}
		parse_profile_anchor(p, loop) or_return
	}
	expect(p, .Right_Paren, "')' after the anchors") or_return
	if len(loop.anchors) < 2 {return fail(p, name.line, "loop '%s' needs at least two anchors", name.text)}
	return true
}

@(private)
parse_profile_anchor :: proc(p: ^Parser, loop: ^Bezier_Loop) -> bool {
	head := expect(p, .Ident, "smooth or corner") or_return
	if head.text != "smooth" && head.text != "corner" {return fail(p, head.line, "expected smooth or corner")}
	expect(p, .Left_Paren, "'(' after anchor type") or_return
	name := expect(p, .Ident, "an anchor name") or_return
	for anchor in loop.anchors {
		if anchor.name == name.text {return fail(p, name.line, "duplicate anchor '%s' in loop '%s'", name.text, loop.name)}
	}
	anchor := Bezier_Anchor{smooth = head.text == "smooth", line = name.line}
	values: [6]f64
	for &v, i in values {
		expect(p, .Comma, "',' before coordinate") or_return
		value := parse_expression(p) or_return
		tangent := anchor.smooth && (i == 2 || i == 3)
		if value.length == tangent || math.is_nan(value.amount) || math.is_inf(value.amount) {
			return fail(p, name.line, "argument %d of anchor '%s' must be a finite %s", i+1, name.text, "scalar" if tangent else "length")
		}
		v = value.amount
	}
	anchor.position = {values[0], values[1]}
	if anchor.smooth {
		if values[2] == 0 && values[3] == 0 {return fail(p, name.line, "smooth anchor '%s' needs a nonzero tangent", name.text)}
		if values[4] < 0 || values[5] < 0 {return fail(p, name.line, "negative handle length at '%s'", name.text)}
		anchor.tangent_angle = math.atan2(values[3], values[2])
		anchor.handle_lengths = {values[4], values[5]}
	} else {
		anchor.handles = {{values[2], values[3]}, {values[4], values[5]}}
	}
	if peek(p).kind == .Comma {
		_ = next(p)
		parse_anchor_shift(p, &anchor) or_return
	}
	if anchor.smooth && (values[4]+anchor.shift[3] < 0 || values[5]+anchor.shift[4] < 0) {
		return fail(p, name.line, "shift gives '%s' a negative handle length", name.text)
	}
	close := expect(p, .Right_Paren, "')' after the anchor") or_return
	anchor.insert_at = close.start
	anchor.name = strings.clone(name.text, p.allocator)
	append(&loop.anchors, anchor)
	return true
}

@(private)
parse_anchor_shift :: proc(p: ^Parser, anchor: ^Bezier_Anchor) -> bool {
	head := expect(p, .Ident, "shift") or_return
	if head.text != "shift" {return fail(p, head.line, "the optional final anchor argument is shift(...)")}
	expect(p, .Left_Paren, "'(' after shift") or_return
	n := 5 if anchor.smooth else 6
	for i in 0..<n {
		if i > 0 {expect(p, .Comma, "',' between displacements") or_return}
		start := peek(p).start
		negative := peek(p).kind == .Minus
		if negative {_ = next(p)}
		value := expect(p, .Number, "a literal displacement") or_return
		scalar := anchor.smooth && i == 2
		if value.value.length == scalar || math.is_nan(value.value.amount) || math.is_inf(value.value.amount) {
			return fail(p, value.line, "shift argument %d must be a finite %s", i+1, "angle in degrees" if scalar else "length")
		}
		anchor.shift[i] = -value.value.amount if negative else value.value.amount
		anchor.shift_spans[i] = {start, value.start+len(value.text)}
	}
	expect(p, .Right_Paren, "')' after shift") or_return
	anchor.saved_shift = anchor.shift
	return true
}

profile_source :: proc(d: ^Design, original: string, allocator := context.allocator) -> string {
	builder := strings.builder_make(0, len(original), allocator)
	defer strings.builder_destroy(&builder)
	cursor := 0
	digits: [512]byte
	for object in d.objects {
		if object.profile == nil {continue}
		for loop in object.profile.loops {
			for anchor in loop.anchors {
				if anchor.shift == anchor.saved_shift {continue}
				insert := anchor.shift_spans[0][1] == 0
				if insert {
					strings.write_string(&builder, original[cursor:anchor.insert_at])
					cursor = anchor.insert_at
					strings.write_string(&builder, ", shift(")
				}
				n := 5 if anchor.smooth else 6
				for i in 0..<n {
					if insert {
						if i > 0 {strings.write_string(&builder, ", ")}
					} else {
						if anchor.shift[i] == anchor.saved_shift[i] {continue}
						span := anchor.shift_spans[i]
						strings.write_string(&builder, original[cursor:span[0]])
						cursor = span[1]
					}
					number := strconv.write_float(digits[:], anchor.shift[i], 'f', -1, 64, nil)
					strings.write_string(&builder, number)
					if !anchor.smooth || i != 2 {strings.write_string(&builder, "mm")}
				}
				if insert {strings.write_string(&builder, ")")}
			}
		}
	}
	strings.write_string(&builder, original[cursor:])
	return strings.clone(strings.to_string(builder), allocator)
}

PROFILE_MOVE_LIMIT :: 1_000_000
PROFILE_LAYER_LIMIT :: 65_536

@(private)
prepare_printable_profile :: proc(p: ^Parser, object: ^Object, moves_left: ^int) -> bool {
	d := &p.design
	last_layer := (object.z+object.height-d.first_layer_height)/d.layer_height
	if !(last_layer >= -PROFILE_LAYER_LIMIT && last_layer <= PROFILE_LAYER_LIMIT-1) {
		return fail(p, object.line, "profile exceeds the %d layer limit", PROFILE_LAYER_LIMIT)
	}
	err := prepare_profile_paths(object.profile, d.line_width, object.walls, object.floor, p.allocator)
	if err.message != "" {
		if local, located := err.position.?; located {err.position = object.center+local}
		p.err = err
		return false
	}
	paths := &object.profile.paths
	object.size = paths.bounds_max-paths.bounds_min
	coordinate_limit := f64(geometry.MAX_PLANAR_COORDINATE_UM)/geometry.MICROMETRES_PER_MILLIMETRE
	if object.z+object.height > coordinate_limit {
		return fail(p, object.line, "profile height exceeds the geometry coordinate range")
	}
	for axis in 0..<2 {
		if object.center[axis]+paths.bounds_min[axis] < -coordinate_limit ||
		   object.center[axis]+paths.bounds_max[axis] > coordinate_limit {
			return fail(p, object.line, "profile placement exceeds the geometry coordinate range")
		}
	}
	start, end := object_layer_span(d, object^)
	floors := min(end-start, object.floor)
	walls := end-start-floors
	moves := profile_layer_move_bound(paths, true)*floors + profile_layer_move_bound(paths, false)*walls
	if moves > moves_left^ {
		return fail(p, object.line, "profile toolpaths exceed the %d move limit for a design", PROFILE_MOVE_LIMIT)
	}
	moves_left^ -= moves
	return true
}
