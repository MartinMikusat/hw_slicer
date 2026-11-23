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
	junction:     i16, // index into Design.junctions when on a bevel/fillet; -1 otherwise
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

// Outward flare (mm per side) from base and top `bevel`/`fillet` junctions at layer top `z`.
// Computes exact C1-tangent circular arcs for horizontal-to-wall, horizontal-to-cone, and
// sloped-cone-to-vertical-column junctions, and returns the contributing junction index (-1 if none).
object_base_flare_info :: proc(object: Object, z, thickness: f64) -> (flare: f64, junction: i16) {
	junction = -1
	if object.base_transition != .None && object.base_transition_size > EPSILON {
		s := object.base_transition_size
		dz := max(0, z-object.z-0.5*thickness)
		base_flare := 0.0
		switch object.base_transition {
		case .None:
		case .Bevel:
			if dz < s-EPSILON {base_flare = s-dz}
		case .Fillet:
			if object.base_lower_slope > 1e-4 {
				// Upper half of a C1-tangent fillet from a sloped cone (slope m1) into a vertical column.
				m1 := object.base_lower_slope
				z_c := s*(math.sqrt(1+m1*m1)-1)/m1
				if dz < z_c-EPSILON {
					rem := z_c-dz
					base_flare = s-math.sqrt(max(0, s*s-rem*rem))
				}
			} else {
				m := 0.0
				if object.shape != .Box && object.height > EPSILON {
					m = (object.size.x-object.top_diameter)*0.5/object.height
				}
				hyp := math.sqrt(1+m*m)
				z_tan := s*(1-m/hyp)
				if dz < z_tan-EPSILON {
					r_c := s*(hyp-m)
					rem := s-dz
					r_fillet := r_c-math.sqrt(max(0, s*s-rem*rem))
					base_flare = r_fillet+m*dz
				}
			}
		}
		if base_flare > flare {
			flare = base_flare
			junction = object.base_junction
		}
	}
	if object.top_fillet_radius > EPSILON && object.shape != .Box && object.height > EPSILON {
		// Lower half of a C1-tangent fillet where this sloped cone meets a vertical column above.
		s := object.top_fillet_radius
		m1 := (object.size.x-object.top_diameter)*0.5/object.height
		if m1 > 1e-4 {
			hyp := math.sqrt(1+m1*m1)
			z_c := s*(hyp-1)/m1
			z_bot := s*(hyp-1)/(m1*hyp)
			dz_top := (object.z+object.height)-(z-0.5*thickness) // positive distance below top
			if dz_top >= 0 && dz_top < z_bot-EPSILON {
				rem := z_c+dz_top
				r_fillet := s-math.sqrt(max(0, s*s-rem*rem)) // relative to R_top
				top_flare := r_fillet-m1*dz_top
				if top_flare > flare {
					flare = top_flare
					junction = object.top_fillet_junction
				}
			}
		}
	}
	return
}

object_base_flare :: proc(object: Object, z, thickness: f64) -> f64 {
	flare, _ := object_base_flare_info(object, z, thickness)
	return flare
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

// Generates layer-ordered moves for `[start_layer, end_layer)` into `t` (reusing `t.moves`).
generate_layers :: proc(d: ^Design, start_layer, end_layer: int, t: ^Toolpath) {
	assert(d.line_width > 0 && d.layer_height > 0 && d.first_layer_height > 0)
	assert(len(d.objects) > 0)
	clear(&t.moves)
	t.start = {}
	t.layers = 0
	t.extruded_length = 0
	t.filament_length = 0
	t.duration = 0
	for object in d.objects {t.layers = max(t.layers, object_layers(d, object))}
	lo := clamp(start_layer, 0, t.layers)
	hi := clamp(end_layer, lo, t.layers)
	g := Generator{d = d, t = t}
	for layer in lo..<hi {
		g.z = d.first_layer_height+f64(layer)*d.layer_height
		g.thickness = d.first_layer_height if layer == 0 else d.layer_height
		for object, index in d.objects {
			start_layer, end_layer := object_layer_span(d, object)
			if layer < start_layer || layer >= end_layer {continue}
			g.feature = index
			g.junction = -1
			g.settings = object.settings
			if object.top_morph_transition != .None && object.top_morph_height > EPSILON {
				morph_start := object.z+object.height-object.top_morph_height
				z_mid := g.z-0.5*g.thickness
				if z_mid > morph_start {
					g.junction = object.top_morph_junction
					t_morph := clamp((z_mid-morph_start)/object.top_morph_height, 0, 1)
					s_morph := t_morph*t_morph*(3-2*t_morph) if object.top_morph_transition == .Fillet else t_morph
					r_out_from := object_size_at_z(object, g.z, g.thickness).x*0.5
					r_out_to := object.top_morph_diameter*0.5
					r_in_from := object.inner_diameter*0.5
					r_in_to := object.top_morph_inner_diameter*0.5
					emitted_outer := 0
					for loop in 0..<object.walls {
						inset := (f64(loop)+0.5)*d.line_width
						min_from := max(d.line_width*0.5, r_in_from+d.line_width*0.5 if r_in_from > 0 else 0)
						min_to := max(d.line_width*0.5, r_in_to+d.line_width*0.5 if r_in_to > 0 else 0)
						if r_out_from-inset < min_from-EPSILON || r_out_to-inset < min_to-EPSILON {break}
						emit_morphed_radial_loop(&g, object.center, r_out_from-inset, object.sides, r_out_to-inset, object.top_morph_sides, s_morph)
						emitted_outer += 1
					}
					if r_in_from > 0 && r_in_to > 0 {
						max_in_from := r_out_from-(f64(emitted_outer)+0.5)*d.line_width
						max_in_to := r_out_to-(f64(emitted_outer)+0.5)*d.line_width
						for loop in 0..<object.walls {
							outset := (f64(loop)+0.5)*d.line_width
							if r_in_from+outset > max_in_from+EPSILON || r_in_to+outset > max_in_to+EPSILON {break}
							emit_morphed_radial_loop(&g, object.center, r_in_from+outset, object.sides, r_in_to+outset, object.top_morph_sides, s_morph)
						}
					}
					continue
				}
			}
			flare, flare_junction := object_base_flare_info(object, g.z, g.thickness)
			if flare > EPSILON {g.junction = flare_junction}
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
}

// Generates layer-ordered moves. Each layer prints the objects in file order, each as
// concentric loops from the outside in (plus inner bore wall loops on hollow tubes).
generate :: proc(d: ^Design, allocator := context.allocator) -> Toolpath {
	t := Toolpath{moves = make([dynamic]Move, allocator)}
	generate_layers(d, 0, max(int), &t)
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
	junction:  i16,
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
		radii: [Box_End]f64
		for end in Box_End {
			base := object.corner_radii[end]
			radius := min(base+flare-inset, half.x, half.y)
			if base > EPSILON && radius > CHORD_TOLERANCE {radii[end] = radius}
		}
		emit_box_loop(g, c, half, radii, object.corner_junctions)
	case .Cylinder, .Tube, .Cone, .Polygon:
		emit_radial_loop(g, object, half.x)
	}
	return true
}

@(private)
emit_box_loop :: proc(g: ^Generator, c, half: [2]f64, radii: [Box_End]f64, junctions: [Box_End]i16) {
	flare_junction := g.junction
	travel(g, c+{radii[.South]-half.x, -half.y})
	for sign in ([?][2]f64{{1, -1}, {1, 1}, {-1, 1}, {-1, -1}}) {
		end := .South if sign.y < 0 else Box_End.North
		radius := radii[end]
		corner := c+sign*half
		if radius == 0 {
			extrude(g, corner)
			continue
		}
		center := c+sign*(half-radius)
		entry := [2]f64{center.x, corner.y}
		exit := [2]f64{corner.x, center.y}
		if sign.x == sign.y {entry, exit = exit, entry}
		extrude(g, entry)
		if flare_junction < 0 {g.junction = junctions[end]}
		extrude_arc(g, exit, center, .CCW)
		g.junction = flare_junction
	}
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

@(private)
radial_radius_at_angle :: proc(radius: f64, sides: int, angle: f64) -> f64 {
	if sides < 3 {return radius}
	sector := 2*math.PI/f64(sides)
	a := math.mod(angle, sector)
	if a < 0 {a += sector}
	delta := a-sector*0.5
	return radius*math.cos(sector*0.5)/math.cos(delta)
}

@(private)
emit_morphed_radial_loop :: proc(
	g: ^Generator,
	c: [2]f64,
	r_from: f64,
	sides_from: int,
	r_to: f64,
	sides_to: int,
	s: f64,
) {
	if sides_from < 3 && sides_to < 3 {
		r := r_from*(1-s)+r_to*s
		travel(g, {c.x+r, c.y})
		extrude_arc(g, {c.x-r, c.y}, c, .CCW)
		extrude_arc(g, {c.x+r, c.y}, c, .CCW)
		return
	}
	n := max(sides_from, sides_to)
	sub := max(6, int(math.ceil(64.0/f64(n))))
	total := n*sub
	d_ang := 2*math.PI/f64(total)
	dc := math.cos(d_ang)
	ds := math.sin(d_ang)
	ca, sa := 1.0, 0.0
	for i in 0..=total {
		angle := f64(i)*d_ang
		rf := radial_radius_at_angle(r_from, sides_from, angle)
		rt := radial_radius_at_angle(r_to, sides_to, angle)
		r := rf*(1-s)+rt*s
		pt := [2]f64{c.x+r*ca, c.y+r*sa}
		if i == 0 {travel(g, pt)} else {extrude(g, pt)}
		next_ca := ca*dc-sa*ds
		sa = ca*ds+sa*dc
		ca = next_ca
	}
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
	append(&g.t.moves, Move{to = target, speed = g.d.travel_speed, acceleration = g.d.travel_acceleration, feature = -1, junction = -1})
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
		junction = g.junction,
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
		junction = g.junction,
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
