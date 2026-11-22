package design

import "core:math"

// One nozzle move to `to`. Extruding moves lay a bead `width` wide whose top is at to.z and
// that is `height` thick.
Move :: struct {
	to:      [3]f64,
	width:   f64,
	height:  f64,
	speed:   f64, // mm/s
	extrude: bool,
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

// The layer count of `object`: its first layer, then whole layers up to its height.
object_layers :: proc(d: ^Design, object: Object) -> int {
	return 1 + max(0, int(math.round((object.height-d.first_layer_height)/d.layer_height)))
}

// Generates layer-ordered moves. Each layer prints the objects in file order, each as
// concentric loops from the outside in.
generate :: proc(d: ^Design, allocator := context.allocator) -> Toolpath {
	assert(d.line_width > 0 && d.layer_height > 0 && d.first_layer_height > 0)
	assert(len(d.objects) > 0)
	t := Toolpath{moves = make([dynamic]Move, allocator)}
	for object in d.objects {t.layers = max(t.layers, object_layers(d, object))}
	g := Generator{d = d, t = &t}
	for layer in 0..<t.layers {
		g.z = d.first_layer_height+f64(layer)*d.layer_height
		g.thickness = d.first_layer_height if layer == 0 else d.layer_height
		for object in d.objects {
			count := object_layers(d, object)
			if layer >= count {continue}
			solid := layer < object.floor
			loops := max(int) if solid else object.walls
			for loop in 0..<loops {
				inset := (f64(loop)+0.5)*d.line_width
				if !emit_loop(&g, object, inset) {
					if solid {emit_centre_line(&g, object, f64(loop)*d.line_width)}
					break
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
}

// Emits the loop at `inset` from the outline; false when the loop would not fit.
@(private)
emit_loop :: proc(g: ^Generator, object: Object, inset: f64) -> bool {
	half := object.size*0.5-inset
	if min(half.x, half.y) < g.d.line_width*0.5 {return false}
	c := object.center
	switch object.shape {
	case .Box:
		corners := [5][2]f64{
			{c.x-half.x, c.y-half.y},
			{c.x+half.x, c.y-half.y},
			{c.x+half.x, c.y+half.y},
			{c.x-half.x, c.y+half.y},
			{c.x-half.x, c.y-half.y},
		}
		travel(g, corners[0])
		for corner in corners[1:] {extrude(g, corner)}
	case .Cylinder:
		radius := half.x
		segments := MAX_CIRCLE_SEGMENTS
		if radius > CHORD_TOLERANCE {
			segments = int(math.ceil(math.PI/math.acos(1-CHORD_TOLERANCE/radius)))
		}
		segments = clamp(segments, MIN_CIRCLE_SEGMENTS, MAX_CIRCLE_SEGMENTS)
		travel(g, {c.x+radius, c.y})
		for i in 1..=segments {
			angle := 2*math.PI*f64(i)/f64(segments)
			extrude(g, {c.x+radius*math.cos(angle), c.y+radius*math.sin(angle)})
		}
	}
	return true
}

// Fills the strip left inside a solid box layer after its last loop, which is narrower than
// two lines, with one line along its long axis. `filled` is the width taken from each side.
@(private)
emit_centre_line :: proc(g: ^Generator, object: Object, filled: f64) {
	if object.shape != .Box {return}
	half := object.size*0.5-filled
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
	append(&g.t.moves, Move{to = target, speed = g.d.travel_speed})
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
	append(&g.t.moves, Move{to = target, width = w, height = h, speed = g.d.print_speed, extrude = true})
	// A bead's cross-section is a rectangle with semicircular sides.
	area := (w-h)*h+math.PI*h*h/4
	filament_area := math.PI*g.d.filament_diameter*g.d.filament_diameter/4
	g.t.extruded_length += distance
	g.t.filament_length += distance*area/filament_area
	g.t.duration += distance/g.d.print_speed
	g.position = target
}

@(private)
length3 :: proc(v: [3]f64) -> f64 {
	return math.sqrt(v.x*v.x+v.y*v.y+v.z*v.z)
}
