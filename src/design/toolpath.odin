package design

import "core:math"

Arc_Kind :: enum u8 {
	None,
	CW,  // G2
	CCW, // G3
}

// One nozzle move to `to`. Extruding moves lay a bead `width` wide whose top is at to.z and
// that is `height` thick. When `arc != .None`, the move follows a circular arc around `center`.
Move :: struct {
	to:           [3]f64,
	center:       [2]f64, // XY arc centre (mm from bed centre) when arc != .None
	width:        f64,
	height:       f64,
	speed:        f64, // mm/s
	acceleration: f64, // mm/s²
	fan:          f64, // percent; extruding moves only
	extrude:      bool,
	arc:          Arc_Kind,
	feature:      int, // index of the object that extrudes it; -1 for travel
}

Toolpath :: struct {
	start:           [3]f64,
	moves:           [dynamic]Move,
	layers:          int,
	extruded_length: f64, // mm of bead
	filament_length: f64, // mm of filament
	duration:        f64, // seconds
}

MAX_CIRCLE_SEGMENTS :: 720
MIN_CIRCLE_SEGMENTS :: 12
CHORD_TOLERANCE :: 0.01 // mm between a circle and its polygon

toolpath_destroy :: proc(t: ^Toolpath) {
	delete(t.moves)
	t^ = {}
}

// The `[start_layer, end_layer)` layer range of `object`.
object_layer_span :: proc(d: ^Design, object: Object) -> (start_layer, end_layer: int) {
	if object.z >= d.first_layer_height*0.5 {
		start_layer = 1 + max(0, int(math.round((object.z-d.first_layer_height)/d.layer_height)))
	}
	top := object.z+object.height
	end_layer = 1 + max(start_layer, int(math.round((top-d.first_layer_height)/d.layer_height)))
	return
}

// The ending layer index of `object`.
object_layers :: proc(d: ^Design, object: Object) -> int {
	_, end_layer := object_layer_span(d, object)
	return end_layer
}

// Outward base flare (mm per side) from a `bevel` or `fillet` junction at layer top `z`.
object_base_flare :: proc(object: Object, z, thickness: f64) -> f64 {
	if object.base_transition == .None || object.base_transition_size <= EPSILON {return 0}
	s := object.base_transition_size
	dz := clamp(z-object.z-0.5*thickness, 0, s)
	if dz >= s-EPSILON {return 0}
	switch object.base_transition {
	case .None:   return 0
	case .Bevel:  return s-dz
	case .Fillet:
		rem := s-dz
		return s-math.sqrt(max(0, s*s-rem*rem))
	}
	return 0
}

// Effective outer size of `object` at layer height `z` (interpolates tapered cones and base bevel/fillet).
object_size_at_z :: proc(object: Object, z, thickness: f64) -> [2]f64 {
	base := object.size
	if object.shape != .Box && abs(object.top_diameter-object.size.x) > EPSILON && object.height > EPSILON {
		t := clamp((z-object.z)/object.height, 0, 1)
		dia := object.size.x+(object.top_diameter-object.size.x)*t
		base = {dia, dia}
	}
	flare := object_base_flare(object, z, thickness)
	return {base.x+2*flare, base.y+2*flare}
}

// Generates layer-ordered moves. Each layer prints the objects in file order, each as
// concentric loops from the outside in (plus inner bore wall loops on hollow tubes).
generate :: proc(d: ^Design, allocator := context.allocator) -> Toolpath {
	assert(d.line_width > 0 && d.layer_height > 0 && d.first_layer_height > 0)
	assert(len(d.objects) > 0)
	t := Toolpath{moves = make([dynamic]Move, allocator)}
	for object in d.objects {t.layers = max(t.layers, object_layers(d, object))}
	g := Generator{d = d, t = &t}
	for layer in 0..<t.layers {
		g.z = d.first_layer_height+f64(layer)*d.layer_height
		g.thickness = d.first_layer_height if layer == 0 else d.layer_height
		for object, index in d.objects {
			start_layer, end_layer := object_layer_span(d, object)
			if layer < start_layer || layer >= end_layer {continue}
			g.feature = index
			g.settings = object.settings
			flare := object_base_flare(object, g.z, g.thickness)
			solid := (layer-start_layer) < object.floor
			extra_walls := int(math.ceil(flare/d.line_width)) if flare > EPSILON else 0
			loops := max(int) if solid else (object.walls+extra_walls)
			emitted_outer := 0
			for loop in 0..<loops {
				inset := (f64(loop)+0.5)*d.line_width
				if !emit_loop(&g, object, inset) {
					if solid {emit_centre_line(&g, object, f64(loop)*d.line_width)}
					break
				}
				emitted_outer += 1
			}
			if !solid && object.shape != .Box && object.inner_diameter > 0 {
				size_z := object_size_at_z(object, g.z, g.thickness)
				r_outer := size_z.x*0.5
				r_inner := object.inner_diameter*0.5
				max_inner_r := r_outer-(f64(emitted_outer)+0.5)*d.line_width
				for loop in 0..<object.walls {
					r_loop := r_inner+(f64(loop)+0.5)*d.line_width
					if r_loop > max_inner_r+EPSILON {break}
					emit_radial_loop(&g, object, r_loop)
				}
			}
		}
	}
	return t
}

@(private)
Generator :: struct {
	d:         ^Design,
	t:         ^Toolpath,
	z:         f64,
	thickness: f64,
	position:  [3]f64,
	started:   bool,
	feature:   int,
	settings:  Feature_Settings,
}

// Emits the loop at `inset` from the outline; false when the loop would not fit.
@(private)
emit_loop :: proc(g: ^Generator, object: Object, inset: f64) -> bool {
	size_z := object_size_at_z(object, g.z, g.thickness)
	half := size_z*0.5-inset
	min_half := g.d.line_width*0.5
	if object.shape != .Box && object.inner_diameter > 0 {
		min_half = max(min_half, object.inner_diameter*0.5+g.d.line_width*0.5)
	}
	if min(half.x, half.y) < min_half-EPSILON {return false}
	c := object.center
	switch object.shape {
	case .Box:
		flare := object_base_flare(object, g.z, g.thickness)
		r_base := clamp(object.radius, 0, min(object.size.x, object.size.y)*0.5)
		r_outer := (r_base+flare) if r_base > EPSILON else 0
		r_corner := clamp(r_outer-inset, 0, min(half.x, half.y))
		if r_corner <= CHORD_TOLERANCE {
			corners := [5][2]f64{
				{c.x-half.x, c.y-half.y},
				{c.x+half.x, c.y-half.y},
				{c.x+half.x, c.y+half.y},
				{c.x-half.x, c.y+half.y},
				{c.x-half.x, c.y-half.y},
			}
			travel(g, corners[0])
			for corner in corners[1:] {extrude(g, corner)}
		} else {
			emit_rounded_box_loop(g, c, half, r_corner)
		}
	case .Cylinder, .Tube, .Cone, .Polygon:
		emit_radial_loop(g, object, half.x)
	}
	return true
}

@(private)
emit_rounded_box_loop :: proc(g: ^Generator, c, half: [2]f64, r: f64) {
	hx := max(0, half.x-r)
	hy := max(0, half.y-r)

	travel(g, {c.x-hx, c.y-half.y})
	if hx > EPSILON {extrude(g, {c.x+hx, c.y-half.y})}
	extrude_arc(g, {c.x+half.x, c.y-hy}, {c.x+hx, c.y-hy}, .CCW)
	if hy > EPSILON {extrude(g, {c.x+half.x, c.y+hy})}
	extrude_arc(g, {c.x+hx, c.y+half.y}, {c.x+hx, c.y+hy}, .CCW)
	if hx > EPSILON {extrude(g, {c.x-hx, c.y+half.y})}
	extrude_arc(g, {c.x-half.x, c.y+hy}, {c.x-hx, c.y+hy}, .CCW)
	if hy > EPSILON {extrude(g, {c.x-half.x, c.y-hy})}
	extrude_arc(g, {c.x-hx, c.y-half.y}, {c.x-hx, c.y-hy}, .CCW)
}

@(private)
emit_radial_loop :: proc(g: ^Generator, object: Object, radius: f64) {
	c := object.center
	if object.sides >= 3 {
		segments := clamp(object.sides, 3, MAX_CIRCLE_SEGMENTS)
		travel(g, {c.x+radius, c.y})
		for i in 1..=segments {
			angle := 2*math.PI*f64(i)/f64(segments)
			extrude(g, {c.x+radius*math.cos(angle), c.y+radius*math.sin(angle)})
		}
		return
	}
	// Smooth circles emit two exact 180° CCW Klipper arcs (G3).
	travel(g, {c.x+radius, c.y})
	extrude_arc(g, {c.x-radius, c.y}, c, .CCW)
	extrude_arc(g, {c.x+radius, c.y}, c, .CCW)
}

// Fills the strip left inside a solid box layer after its last loop, which is narrower than
// two lines, with one line along its long axis. `filled` is the width taken from each side.
@(private)
emit_centre_line :: proc(g: ^Generator, object: Object, filled: f64) {
	if object.shape != .Box {return}
	half := object_size_at_z(object, g.z, g.thickness)*0.5-filled
	w := g.d.line_width
	if min(half.x, half.y)*2 < w*0.25 {return}
	c := object.center
	if half.x >= half.y {
		reach := max(half.x-w*0.5, 0)
		travel(g, {c.x-reach, c.y})
		extrude(g, {c.x+reach, c.y})
	} else {
		reach := max(half.y-w*0.5, 0)
		travel(g, {c.x, c.y-reach})
		extrude(g, {c.x, c.y+reach})
	}
}

@(private)
travel :: proc(g: ^Generator, to: [2]f64) {
	target := [3]f64{to.x, to.y, g.z}
	if !g.started {
		g.t.start = target
		g.position = target
		g.started = true
		return
	}
	if target == g.position {return}
	distance := length3(target-g.position)
	append(&g.t.moves, Move{to = target, speed = g.d.travel_speed, acceleration = g.d.travel_acceleration, feature = -1})
	g.t.duration += distance/g.d.travel_speed
	g.position = target
}

@(private)
extrude :: proc(g: ^Generator, to: [2]f64) {
	assert(g.started)
	target := [3]f64{to.x, to.y, g.z}
	distance := length3(target-g.position)
	if distance <= 0 {return}
	w, h := g.d.line_width, g.thickness
	settings := g.settings
	append(&g.t.moves, Move{
		to = target,
		width = w,
		height = h,
		speed = settings.speed,
		acceleration = settings.acceleration,
		fan = settings.fan,
		extrude = true,
		feature = g.feature,
	})
	// A bead's cross-section is a rectangle with semicircular sides.
	area := (w-h)*h+math.PI*h*h/4
	filament_area := math.PI*g.d.filament_diameter*g.d.filament_diameter/4
	g.t.extruded_length += distance
	g.t.filament_length += distance*area/filament_area
	g.t.duration += distance/settings.speed
	g.position = target
}

// Computes signed sweep angle (radians) and radius for an XY arc from `from` to `to` around `center`.
arc_geometry :: proc(from, to, center: [2]f64, arc: Arc_Kind) -> (radius, sweep: f64) {
	r0 := from-center
	r1 := to-center
	radius = math.hypot(r0.x, r0.y)
	if radius <= EPSILON {return 0, 0}
	sweep = math.atan2(r0.x*r1.y-r0.y*r1.x, r0.x*r1.x+r0.y*r1.y)
	if arc == .CCW {
		if sweep <= EPSILON {sweep += 2*math.PI}
	} else if arc == .CW {
		if sweep >= -EPSILON {sweep -= 2*math.PI}
	}
	return
}

@(private)
extrude_arc :: proc(g: ^Generator, to, center: [2]f64, arc: Arc_Kind) {
	assert(g.started)
	radius, sweep := arc_geometry({g.position.x, g.position.y}, to, center, arc)
	distance := radius*abs(sweep)
	if distance <= EPSILON {return}
	target := [3]f64{to.x, to.y, g.z}
	w, h := g.d.line_width, g.thickness
	settings := g.settings
	append(&g.t.moves, Move{
		to = target,
		center = center,
		width = w,
		height = h,
		speed = settings.speed,
		acceleration = settings.acceleration,
		fan = settings.fan,
		extrude = true,
		arc = arc,
		feature = g.feature,
	})
	area := (w-h)*h+math.PI*h*h/4
	filament_area := math.PI*g.d.filament_diameter*g.d.filament_diameter/4
	g.t.extruded_length += distance
	g.t.filament_length += distance*area/filament_area
	g.t.duration += distance/settings.speed
	g.position = target
}

@(private)
length3 :: proc(v: [3]f64) -> f64 {
	return math.sqrt(v.x*v.x+v.y*v.y+v.z*v.z)
}
