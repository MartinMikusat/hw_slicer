package design

import "core:fmt"
import "core:math"
import "core:mem"
import "core:strconv"
import "core:strings"

Value :: struct {
	amount: f64,
	length: bool,
}

// The physical printer: inputs that designs derive from, and the limits every feature must
// stay within.
Printer :: struct {
	nozzle_diameter:     f64, // mm
	filament_diameter:   f64, // mm
	max_speed:           f64, // mm/s
	max_acceleration:    f64, // mm/s²
	max_volumetric_flow: f64, // mm³/s
}

// Motion and cooling that one feature prints with. Every feature can set its own; unset values
// come from the design-wide defaults.
Feature_Setting :: enum u8 {
	Speed,
	Acceleration,
	Fan,
}

Feature_Settings :: struct {
	speed:        f64, // mm/s
	acceleration: f64, // mm/s²
	fan:          f64, // percent of full part cooling
}

Shape :: enum u8 {
	Box,
	Cylinder,
	Tube,
	Cone,
	Polygon,
	Profile,
}

shape_name :: proc(shape: Shape) -> string {
	switch shape {
	case .Box:      return "box"
	case .Cylinder: return "cylinder"
	case .Tube:     return "tube"
	case .Cone:     return "cone"
	case .Polygon:  return "polygon"
	case .Profile:  return "profile"
	}
	return "object"
}

Base_Transition :: enum u8 {
	None,
	Bevel,  // 45° linear chamfer at the base junction
	Fillet, // concave circular root fillet at the base junction
}

Junction_Kind :: enum u8 {
	Base_Flare,    // horizontal-to-wall or horizontal-to-cone bevel/fillet
	Cone_Fillet,   // C1-tangent fillet from a sloped cone into a vertical column
	Radial_Morph,  // coaxial radial shape morph (e.g. circle -> polygon)
	Corner_Radius, // rounded XY corner radius on a box (`radius = ...`)
}

Box_End :: enum u8 {
	South,
	North,
}

Junction :: struct {
	is_fillet:   bool,
	kind:        Junction_Kind,
	corner_end:  Maybe(Box_End),
	lower_index: int,
	upper_index: int,
	size:        f64,
	max_size:    f64,
	line:        int,
}

Object :: struct {
	shape:                Shape,
	profile:              ^Bezier_Profile,
	name:                 string,
	line:                 int,
	center:               [2]f64, // mm from the bed centre
	z:                    f64,    // base Z offset from the bed (mm)
	size:                 [2]f64, // box width and depth; radial base diameter in both
	top_diameter:         f64,    // radial top diameter (mm); equals size.x when untapered
	inner_diameter:       f64,    // radial inner bore diameter (mm); 0 when solid
	corner_radii:         [Box_End]f64,
	sides:                int,    // polygon side count (>= 3); 0 for smooth circular curves
	height:               f64,
	walls:                int,
	floor:                int,
	base_transition:      Base_Transition,
	base_transition_size: f64,
	base_lower_slope:         f64, // > 0 when filleting a sloped lower cone into this vertical upper feature
	top_fillet_radius:        f64, // > 0 when filleting this sloped cone's top into a vertical upper feature
	top_morph_transition:     Base_Transition, // linear (Bevel) or smoothstep (Fillet) shape morph into upper
	top_morph_height:         f64, // height at top of this object over which it morphs into upper (mm)
	top_morph_sides:          int, // target polygon sides at top (0 for circle, >= 3 for N-gon)
	top_morph_diameter:       f64, // target outer diameter at top (mm)
	top_morph_inner_diameter: f64, // target inner diameter at top (mm)
	base_junction:            i16, // index into Design.junctions, or -1
	top_fillet_junction:      i16, // index into Design.junctions, or -1
	top_morph_junction:       i16, // index into Design.junctions, or -1
	corner_junctions:         [Box_End]i16,
	settings:                 Feature_Settings,
	given:                bit_set[Feature_Setting], // settings the feature sets itself
}

Parameter :: struct {
	name:  string,
	value: Value,
	line:  int,
}

Design :: struct {
	parameters:          [dynamic]Parameter,
	objects:             [dynamic]Object,
	junctions:           [dynamic]Junction,
	material:            string,
	line_width:          f64,
	layer_height:        f64,
	first_layer_height:  f64,
	first_layer_fan:     f64, // percent (default 0)
	nozzle_temperature:  f64, // °C override (0 = material default)
	bed_temperature:     f64, // °C override (0 = material default)
	defaults:            Feature_Settings,
	travel_speed:        f64, // mm/s
	travel_acceleration: f64, // mm/s²
	filament_diameter:   f64,
}

Error :: struct {
	line:     int,
	message:  string,
	position: Maybe([2]f64),
}

DEFAULT_PRINT_SPEED :: 40
DEFAULT_PRINT_ACCELERATION :: 1000
DEFAULT_FAN :: 100
DEFAULT_TRAVEL_SPEED :: 150
DEFAULT_TRAVEL_ACCELERATION :: 3000
MAX_OBJECTS :: 256
MAX_PARAMETERS :: 256
EPSILON :: 1e-9

design_destroy :: proc(d: ^Design) {
	delete(d.material, d.parameters.allocator)
	for parameter in d.parameters {delete(parameter.name, d.parameters.allocator)}
	for object in d.objects {
		if object.profile != nil {destroy_bezier_profile(object.profile, d.objects.allocator)}
		delete(object.name, d.objects.allocator)
	}
	delete(d.parameters)
	delete(d.objects)
	delete(d.junctions)
	d^ = {}
}

// Updates junction `idx` in-place (in-memory interactive edit without reparsing).
set_junction_size :: proc(d: ^Design, idx: int, new_size: f64) -> bool {
	if idx < 0 || idx >= len(d.junctions) {return false}
	j := &d.junctions[idx]
	s := clamp(new_size, 0, j.max_size)
	j.size = s
	lower := &d.objects[j.lower_index]
	upper := &d.objects[j.upper_index]
	active := s > 0.05
	tr := Base_Transition.None
	if active {tr = .Fillet if j.is_fillet else .Bevel}
	switch j.kind {
	case .Base_Flare:
		upper.base_transition = tr
		upper.base_transition_size = s if active else 0
	case .Cone_Fillet:
		lower.top_fillet_radius = s if active else 0
		upper.base_transition = .Fillet if active else .None
		upper.base_transition_size = s if active else 0
	case .Radial_Morph:
		lower.top_morph_transition = tr
		lower.top_morph_height = s if active else 0
	case .Corner_Radius:
		radius := s if active else 0
		if end, split := j.corner_end.?; split {
			lower.corner_radii[end] = radius
		} else {
			lower.corner_radii = {.South = radius, .North = radius}
		}
	}
	return true
}

// Toggles a junction between smooth Fillet and linear Bevel (where supported).
toggle_junction_fillet :: proc(d: ^Design, idx: int) -> bool {
	if idx < 0 || idx >= len(d.junctions) {return false}
	j := &d.junctions[idx]
	if j.kind == .Cone_Fillet || j.kind == .Corner_Radius {return false}
	j.is_fillet = !j.is_fillet
	return set_junction_size(d, idx, j.size)
}

error_destroy :: proc(e: ^Error, allocator := context.allocator) {
	delete(e.message, allocator)
	e^ = {}
}

// Evaluates `source` against `printer`. On failure the result is empty and the error holds a
// message allocated with `allocator`.
evaluate :: proc(source: string, printer: Printer, allocator := context.allocator) -> (result: Design, err: Error, ok: bool) {
	assert(printer.nozzle_diameter > 0)
	assert(printer.filament_diameter > 0)
	assert(printer.max_speed > 0 && printer.max_acceleration > 0 && printer.max_volumetric_flow > 0)
	p := Parser{allocator = allocator}
	p.design.parameters = make([dynamic]Parameter, allocator)
	p.design.objects = make([dynamic]Object, allocator)
	p.design.junctions = make([dynamic]Junction, allocator)
	p.design.filament_diameter = printer.filament_diameter
	p.tokens = make([dynamic]Token, context.temp_allocator)
	defer delete(p.tokens)
	p.object_refs = make([dynamic]Object_Ref, context.temp_allocator)
	defer delete(p.object_refs)
	ok = tokenize(&p, source) &&
		define(&p, "nozzle", {printer.nozzle_diameter, true}, 0) &&
		define(&p, "filament", {printer.filament_diameter, true}, 0) &&
		parse_statements(&p) &&
		resolve_process(&p, printer)
	if !ok {
		design_destroy(&p.design)
		return {}, p.err, false
	}
	return p.design, {}, true
}

value_text :: proc(v: Value, allocator := context.temp_allocator) -> string {
	if v.length {return fmt.aprintf("%.3f mm", v.amount, allocator = allocator)}
	if abs(v.amount-math.round(v.amount)) < EPSILON {return fmt.aprintf("%d", int(math.round(v.amount)), allocator = allocator)}
	return fmt.aprintf("%.3f", v.amount, allocator = allocator)
}

@(private)
Token_Kind :: enum u8 {
	Ident,
	Number,
	Left_Paren,
	Right_Paren,
	Comma,
	Equals,
	Plus,
	Minus,
	Star,
	Slash,
	Newline,
	End,
}

@(private)
Token :: struct {
	kind:  Token_Kind,
	text:  string,
	value: Value,
	line:  int,
	start: int,
}

@(private)
Object_Ref :: struct {
	name:  string,
	index: int,
	line:  int,
}

@(private)
Parser :: struct {
	allocator:   mem.Allocator,
	tokens:      [dynamic]Token,
	position:    int,
	design:      Design,
	object_refs: [dynamic]Object_Ref,
	err:         Error,
}

@(private)
fail :: proc(p: ^Parser, line: int, format: string, args: ..any) -> bool {
	if p.err.message == "" {
		p.err = {line = line, message = fmt.aprintf(format, ..args, allocator = p.allocator)}
	}
	return false
}

@(private)
is_ident_start :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

@(private)
is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

@(private)
tokenize :: proc(p: ^Parser, source: string) -> bool {
	line := 1
	depth := 0
	i := 0
	for i < len(source) {
		c := source[i]
		switch {
		case c == '#':
			for i < len(source) && source[i] != '\n' {i += 1}
		case c == '\n':
			if depth == 0 {append(&p.tokens, Token{kind = .Newline, line = line})}
			line += 1
			i += 1
		case c == ' ' || c == '\t' || c == '\r':
			i += 1
		case is_ident_start(c):
			start := i
			for i < len(source) && (is_ident_start(source[i]) || is_digit(source[i])) {i += 1}
			append(&p.tokens, Token{kind = .Ident, text = source[start:i], line = line})
		case is_digit(c) || (c == '.' && i+1 < len(source) && is_digit(source[i+1])):
			start := i
			for i < len(source) && (is_digit(source[i]) || source[i] == '.') {i += 1}
			amount, parsed := strconv.parse_f64(source[start:i])
			if !parsed {return fail(p, line, "invalid number '%s'", source[start:i])}
			unit_start := i
			for i < len(source) && is_ident_start(source[i]) {i += 1}
			unit := source[unit_start:i]
			if unit != "" && unit != "mm" {return fail(p, line, "unknown unit '%s'; use mm or no unit", unit)}
			append(&p.tokens, Token{kind = .Number, text = source[start:i], value = {amount, unit == "mm"}, line = line, start = start})
		case:
			kind: Token_Kind
			switch c {
			case '(': kind = .Left_Paren; depth += 1
			case ')':
				kind = .Right_Paren
				if depth == 0 {return fail(p, line, "unmatched ')'")}
				depth -= 1
			case ',': kind = .Comma
			case '=': kind = .Equals
			case '+': kind = .Plus
			case '-': kind = .Minus
			case '*': kind = .Star
			case '/': kind = .Slash
			case: return fail(p, line, "unexpected character '%c'", rune(c))
			}
			append(&p.tokens, Token{kind = kind, text = source[i:i+1], line = line, start = i})
			i += 1
		}
	}
	if depth != 0 {return fail(p, line, "missing ')'")}
	append(&p.tokens, Token{kind = .Newline, line = line})
	append(&p.tokens, Token{kind = .End, line = line})
	return true
}

@(private)
peek :: proc(p: ^Parser) -> Token {
	return p.tokens[p.position]
}

@(private)
next :: proc(p: ^Parser) -> Token {
	token := p.tokens[p.position]
	if token.kind != .End {p.position += 1}
	return token
}

@(private)
expect :: proc(p: ^Parser, kind: Token_Kind, what: string) -> (Token, bool) {
	token := next(p)
	if token.kind != kind {
		found := token.text if token.kind != .Newline && token.kind != .End else "end of line"
		return token, fail(p, token.line, "expected %s, found '%s'", what, found)
	}
	return token, true
}

@(private)
lookup :: proc(p: ^Parser, name: string) -> (Value, bool) {
	for parameter in p.design.parameters {
		if parameter.name == name {return parameter.value, true}
	}
	return {}, false
}

@(private)
lookup_object :: proc(p: ^Parser, name: string) -> (int, bool) {
	for ref in p.object_refs {
		if ref.name == name {return ref.index, true}
	}
	return -1, false
}

@(private)
is_object_keyword :: proc(text: string) -> bool {
	return text == "box" || text == "cylinder" || text == "tube" || text == "cone" || text == "polygon" || text == "profile"
}

@(private)
define :: proc(p: ^Parser, name: string, value: Value, line: int) -> bool {
	if _, exists := lookup(p, name); exists {return fail(p, line, "'%s' is already defined", name)}
	if _, exists := lookup_object(p, name); exists {return fail(p, line, "'%s' is already defined", name)}
	if len(p.design.parameters) >= MAX_PARAMETERS {return fail(p, line, "more than %d parameters", MAX_PARAMETERS)}
	append(&p.design.parameters, Parameter{name = strings.clone(name, p.allocator), value = value, line = line})
	return true
}

@(private)
parse_statements :: proc(p: ^Parser) -> bool {
	for peek(p).kind != .End {
		token := next(p)
		switch token.kind {
		case .Newline:
			continue
		case .Ident:
			if token.text == "let" {
				name := expect(p, .Ident, "a name after 'let'") or_return
				expect(p, .Equals, "'='") or_return
				if peek(p).kind == .Ident && is_object_keyword(peek(p).text) {
					if _, exists := lookup(p, name.text); exists {return fail(p, name.line, "'%s' is already defined", name.text)}
					if _, exists := lookup_object(p, name.text); exists {return fail(p, name.line, "'%s' is already defined", name.text)}
					head := next(p)
					parse_object(p, head, name.text) or_return
					append(&p.object_refs, Object_Ref{name = name.text, index = len(p.design.objects)-1, line = name.line})
				} else {
					value := parse_expression(p) or_return
					define(p, name.text, value, name.line) or_return
				}
			} else if token.text == "material" {
				if len(p.design.material) > 0 {
					return fail(p, token.line, "material is already set")
				}
				expect(p, .Equals, "'=' after 'material'") or_return
				mat := expect(p, .Ident, "a material name (e.g. pla, petg, abs)") or_return
				p.design.material = strings.clone(mat.text, p.allocator)
			} else if is_object_keyword(token.text) {
				parse_object(p, token, "") or_return
			} else if token.text == "bevel" || token.text == "fillet" {
				parse_junction(p, token) or_return
			} else {
				return fail(p, token.line, "unknown statement '%s'; use let, box, cylinder, tube, cone, polygon, profile, bevel or fillet", token.text)
			}
			expect(p, .Newline, "end of line") or_return
		case .Number, .Left_Paren, .Right_Paren, .Comma, .Equals, .Plus, .Minus, .Star, .Slash, .End:
			return fail(p, token.line, "unexpected '%s' at the start of a statement", token.text)
		}
	}
	return true
}

@(private)
parse_junction :: proc(p: ^Parser, head: Token) -> bool {
	is_fillet := head.text == "fillet"
	size_key := "radius" if is_fillet else "size"
	expect(p, .Left_Paren, "'(' after bevel/fillet") or_return
	a_tok := expect(p, .Ident, "first object name") or_return
	expect(p, .Comma, "',' after first object name") or_return
	b_tok := expect(p, .Ident, "second object name") or_return
	expect(p, .Comma, "',' before transition size") or_return
	key_tok := expect(p, .Ident, size_key) or_return
	if key_tok.text != size_key {
		return fail(p, key_tok.line, "%s expects '%s = ...', found '%s'", head.text, size_key, key_tok.text)
	}
	expect(p, .Equals, "'='") or_return
	size_val := parse_expression(p) or_return
	expect(p, .Right_Paren, "')'") or_return

	if !size_val.length || size_val.amount <= 0 {
		return fail(p, key_tok.line, "%s '%s' must be a positive length", head.text, size_key)
	}
	a_idx, a_ok := lookup_object(p, a_tok.text)
	if !a_ok {return fail(p, a_tok.line, "'%s' is not a named object", a_tok.text)}
	b_idx, b_ok := lookup_object(p, b_tok.text)
	if !b_ok {return fail(p, b_tok.line, "'%s' is not a named object", b_tok.text)}
	if a_idx == b_idx {return fail(p, head.line, "%s needs two different objects", head.text)}

	a := &p.design.objects[a_idx]
	b := &p.design.objects[b_idx]
	if a.shape == .Profile || b.shape == .Profile {
		return fail(p, head.line, "%s cannot join a constant-section profile", head.text)
	}
	lower, upper: ^Object
	lower_idx, upper_idx: int
	if abs((a.z+a.height)-b.z) <= 1e-4 {
		lower, upper = a, b
		lower_idx, upper_idx = a_idx, b_idx
	} else if abs((b.z+b.height)-a.z) <= 1e-4 {
		lower, upper = b, a
		lower_idx, upper_idx = b_idx, a_idx
	} else {
		return fail(p, head.line, "'%s' and '%s' do not meet on a Z plane", a_tok.text, b_tok.text)
	}
	s := size_val.amount
	if upper.base_transition != .None {
		return fail(p, head.line, "'%s' already has a base bevel or fillet", upper.name)
	}
	// Case 1: Sloped lower cone meeting a vertical upper radial feature at the same diameter
	// (e.g. `fillet(pedestal, sleeve, radius = 12mm)`): attach a shared C1-tangent arc to both.
	same_center := math.hypot(upper.center.x-lower.center.x, upper.center.y-lower.center.y) <= 1e-4
	same_dia := lower.shape != .Box && upper.shape != .Box && abs(lower.top_diameter-upper.size.x) <= 1e-3
	lower_slope := (lower.size.x-lower.top_diameter)*0.5/lower.height if (lower.shape != .Box && lower.height > EPSILON) else 0.0
	upper_slope := (upper.size.x-upper.top_diameter)*0.5/upper.height if (upper.shape != .Box && upper.height > EPSILON) else 0.0
	if is_fillet && same_center && same_dia && lower_slope > 1e-4 && abs(upper_slope) <= 1e-4 {
		hyp := math.sqrt(1+lower_slope*lower_slope)
		z_top := s*(hyp-1)/lower_slope
		z_bot := s*(hyp-1)/(lower_slope*hyp)
		if z_top > upper.height+EPSILON {
			return fail(p, head.line, "%s %.3f mm exceeds '%s' height %.3f mm", head.text, s, upper.name, upper.height)
		}
		if z_bot > lower.height+EPSILON {
			return fail(p, head.line, "%s %.3f mm exceeds '%s' height %.3f mm", head.text, s, lower.name, lower.height)
		}
		j_idx := i16(len(p.design.junctions))
		max_s_top := upper.height*lower_slope/(hyp-1)
		max_s_bot := lower.height*lower_slope*hyp/(hyp-1)
		max_s := max(s, min(max_s_top, max_s_bot))
		append(&p.design.junctions, Junction{
			is_fillet = true, kind = .Cone_Fillet,
			lower_index = lower_idx, upper_index = upper_idx,
			size = s, max_size = max_s, line = head.line,
		})
		lower.top_fillet_radius = s
		lower.top_fillet_junction = j_idx
		upper.base_transition = .Fillet
		upper.base_transition_size = s
		upper.base_lower_slope = lower_slope
		upper.base_junction = j_idx
		return true
	}

	// Case 2: Coaxial radial shape morph (e.g. circular `tube` -> octagonal/hexagonal `polygon`,
	// or mismatched hollow radial features): smoothly loft the top `s` mm of `lower` into `upper`
	// so every outer and inner wall layer connects with printable overhang.
	diff_shape := lower.sides != upper.sides
	diff_hollow := lower.inner_diameter > 0 && (abs(lower.top_diameter-upper.size.x) > 1e-3 || abs(lower.inner_diameter-upper.inner_diameter) > 1e-3)
	if same_center && lower.shape != .Box && upper.shape != .Box && (diff_shape || diff_hollow) {
		if lower.top_morph_transition != .None {
			return fail(p, head.line, "'%s' already has a top morph bevel or fillet", lower.name)
		}
		if s > lower.height+EPSILON {
			return fail(p, head.line, "%s %.3f mm exceeds '%s' height %.3f mm", head.text, s, lower.name, lower.height)
		}
		j_idx := i16(len(p.design.junctions))
		append(&p.design.junctions, Junction{
			is_fillet = is_fillet, kind = .Radial_Morph,
			lower_index = lower_idx, upper_index = upper_idx,
			size = s, max_size = max(s, lower.height), line = head.line,
		})
		lower.top_morph_transition = .Fillet if is_fillet else .Bevel
		lower.top_morph_height = s
		lower.top_morph_sides = upper.sides
		lower.top_morph_diameter = upper.size.x
		lower.top_morph_inner_diameter = upper.inner_diameter
		lower.top_morph_junction = j_idx
		return true
	}

	// Case 3: Upper feature resting on a wider horizontal top face of `lower`.
	max_flare := s
	eff_height := s
	flare_ratio := 1.0
	height_ratio := 1.0
	if is_fillet && upper.shape != .Box && upper.height > EPSILON {
		m := (upper.size.x-upper.top_diameter)*0.5/upper.height
		hyp := math.sqrt(1+m*m)
		flare_ratio = hyp-m
		height_ratio = 1-m/hyp
		max_flare = s*flare_ratio
		eff_height = s*height_ratio
	}
	if eff_height > upper.height+EPSILON {
		return fail(p, head.line, "%s %.3f mm exceeds '%s' height %.3f mm", head.text, s, upper.name, upper.height)
	}
	// Verify the flared footprint fits on the lower object's top face.
	if !junction_fits_on_lower(lower^, upper^, max_flare) {
		return fail(p, head.line, "%s %.3f mm on '%s' extends past '%s' top face", head.text, s, upper.name, lower.name)
	}
	max_s := upper.height/max(height_ratio, 1e-4)
	if lower.shape == .Box {
		lh := lower.size*0.5
		uh := upper.size*0.5
		avail_x := min((lower.center.x+lh.x)-(upper.center.x+uh.x), (upper.center.x-uh.x)-(lower.center.x-lh.x))
		avail_y := min((lower.center.y+lh.y)-(upper.center.y+uh.y), (upper.center.y-uh.y)-(lower.center.y-lh.y))
		avail := max(0, min(avail_x, avail_y))
		max_s = min(max_s, avail/max(flare_ratio, 1e-4))
	} else {
		lr := lower.top_diameter*0.5
		dc := math.hypot(upper.center.x-lower.center.x, upper.center.y-lower.center.y)
		ur := upper.size.x*0.5 if upper.shape != .Box else math.hypot(upper.size.x*0.5, upper.size.y*0.5)
		avail := max(0, lr-dc-ur)
		max_s = min(max_s, avail/max(flare_ratio, 1e-4))
	}
	j_idx := i16(len(p.design.junctions))
	append(&p.design.junctions, Junction{
		is_fillet = is_fillet, kind = .Base_Flare,
		lower_index = lower_idx, upper_index = upper_idx,
		size = s, max_size = max(s, max_s), line = head.line,
	})
	upper.base_transition = .Fillet if is_fillet else .Bevel
	upper.base_transition_size = s
	upper.base_junction = j_idx
	return true
}

@(private)
junction_fits_on_lower :: proc(lower, upper: Object, flare: f64) -> bool {
	tol := 1e-4
	uh := upper.size*0.5 + flare
	if lower.shape == .Box {
		lh := lower.size*0.5
		return upper.center.x-uh.x >= lower.center.x-lh.x-tol &&
			upper.center.x+uh.x <= lower.center.x+lh.x+tol &&
			upper.center.y-uh.y >= lower.center.y-lh.y-tol &&
			upper.center.y+uh.y <= lower.center.y+lh.y+tol
	}
	lr := lower.top_diameter*0.5
	dc := math.hypot(upper.center.x-lower.center.x, upper.center.y-lower.center.y)
	ur := uh.x if upper.shape != .Box else math.hypot(uh.x, uh.y)
	return dc+ur <= lr+tol
}

@(private)
Object_Key :: enum u8 {
	X,
	Y,
	Z,
	Width,
	Depth,
	Radius,
	Radius_South,
	Radius_North,
	Diameter,
	Top_Diameter,
	Inner_Diameter,
	Sides,
	Height,
	Walls,
	Floor,
	Speed,
	Acceleration,
	Fan,
	Outer,
	Hole,
}

@(private)
OBJECT_KEY_NAMES := [Object_Key]string {
	.X              = "x",
	.Y              = "y",
	.Z              = "z",
	.Width          = "width",
	.Depth          = "depth",
	.Radius         = "radius",
	.Radius_South   = "radius_south",
	.Radius_North   = "radius_north",
	.Diameter       = "diameter",
	.Top_Diameter   = "top_diameter",
	.Inner_Diameter = "inner_diameter",
	.Sides          = "sides",
	.Height         = "height",
	.Walls          = "walls",
	.Floor          = "floor",
	.Speed          = "speed",
	.Acceleration   = "acceleration",
	.Fan            = "fan",
	.Outer          = "outer",
	.Hole           = "hole",
}

@(private)
parse_object :: proc(p: ^Parser, head: Token, object_name: string) -> bool {
	shape: Shape
	switch head.text {
	case "box":      shape = .Box
	case "cylinder": shape = .Cylinder
	case "tube":     shape = .Tube
	case "cone":     shape = .Cone
	case "polygon":  shape = .Polygon
	case "profile":  shape = .Profile
	}
	allowed := bit_set[Object_Key]{.X, .Y, .Z, .Height, .Walls, .Floor, .Speed, .Acceleration, .Fan}
	required := bit_set[Object_Key]{.Height, .Walls}
	profile: ^Bezier_Profile
	defer {if profile != nil {destroy_bezier_profile(profile, p.allocator)}}
	if shape == .Box {
		allowed += {.Width, .Depth, .Radius, .Radius_South, .Radius_North}
		required += {.Width, .Depth}
	} else if shape == .Profile {
		allowed += {.Outer, .Hole}
		required += {.Outer}
		profile = new(Bezier_Profile, p.allocator)
		profile.line = head.line
		profile.loops = make([dynamic]Bezier_Loop, p.allocator)
	} else {
		allowed += {.Diameter, .Top_Diameter, .Inner_Diameter, .Sides}
		required += {.Diameter}
		if shape == .Tube {required += {.Inner_Diameter}}
		if shape == .Cone {required += {.Top_Diameter}}
		if shape == .Polygon {required += {.Sides}}
	}
	values: [Object_Key]Value
	seen: bit_set[Object_Key]
	expect(p, .Left_Paren, "'(' after the object name") or_return
	for peek(p).kind != .Right_Paren {
		if card(seen) > 0 {expect(p, .Comma, "',' between arguments") or_return}
		name := expect(p, .Ident, "an argument name") or_return
		key, found := object_key(name.text)
		if !found || key not_in allowed {return fail(p, name.line, "%s has no argument '%s'", head.text, name.text)}
		if key in seen && key != .Hole {return fail(p, name.line, "argument '%s' is given twice", name.text)}
		expect(p, .Equals, "'=' after the argument name") or_return
		if key == .Outer || key == .Hole {
			if key == .Hole && .Outer not_in seen {return fail(p, name.line, "define the outer loop before its holes")}
			parse_profile_loop(p, profile) or_return
			seen += {key}
			continue
		}
		value := parse_expression(p) or_return
		if shape == .Profile && (math.is_nan(value.amount) || math.is_inf(value.amount)) {
			return fail(p, name.line, "profile argument '%s' must be finite", name.text)
		}
		wants_length := key not_in bit_set[Object_Key]{.Sides, .Walls, .Floor, .Speed, .Acceleration, .Fan}
		if value.length != wants_length {
			return fail(p, name.line, "argument '%s' must be %s", name.text, "a length" if wants_length else "a scalar count")
		}
		values[key] = value
		seen += {key}
	}
	expect(p, .Right_Paren, "')'") or_return
	for key in Object_Key {
		if key in required && key not_in seen {return fail(p, head.line, "%s needs argument '%s'", head.text, OBJECT_KEY_NAMES[key])}
	}
	for key in ([3]Object_Key{.Walls, .Floor, .Sides}) {
		if key not_in seen {continue}
		v := values[key].amount
		if shape == .Profile && (v < 0 || v >= f64(max(int))) {
			return fail(p, head.line, "'%s' is outside the supported count range", OBJECT_KEY_NAMES[key])
		}
		if abs(v-math.round(v)) > EPSILON {return fail(p, head.line, "'%s' must be a whole count, got %.3f", OBJECT_KEY_NAMES[key], v)}
	}
	object := Object{
		shape    = shape,
		line     = head.line,
		center   = {values[.X].amount, values[.Y].amount},
		z        = values[.Z].amount,
		height   = values[.Height].amount,
		walls               = int(math.round(values[.Walls].amount)),
		floor               = int(math.round(values[.Floor].amount)),
		base_junction       = -1,
		top_fillet_junction = -1,
		top_morph_junction  = -1,
		corner_junctions    = {.South = -1, .North = -1},
		settings            = {values[.Speed].amount, values[.Acceleration].amount, values[.Fan].amount},
	}
	if .Speed in seen {object.given += {.Speed}}
	if .Acceleration in seen {object.given += {.Acceleration}}
	if .Fan in seen {object.given += {.Fan}}
	if object.z < -EPSILON {return fail(p, head.line, "z must not be negative, got %.3f mm", object.z)}
	if object.z < 0 {object.z = 0}
	if shape == .Box {
		object.size = {values[.Width].amount, values[.Depth].amount}
		object.top_diameter = object.size.x
	} else if shape != .Profile {
		dia := values[.Diameter].amount
		top_dia := values[.Top_Diameter].amount if .Top_Diameter in seen else dia
		inner_dia := values[.Inner_Diameter].amount if .Inner_Diameter in seen else 0
		object.size = {dia, dia}
		object.top_diameter = top_dia
		object.inner_diameter = inner_dia
		if .Sides in seen {
			object.sides = int(math.round(values[.Sides].amount))
			if object.sides < 3 {return fail(p, head.line, "sides must be at least 3, got %d", object.sides)}
		}
		if top_dia <= 0 {return fail(p, head.line, "%s top_diameter must be positive", head.text)}
		if inner_dia < -EPSILON {return fail(p, head.line, "inner_diameter must not be negative")}
		if shape == .Tube && inner_dia <= 0 {return fail(p, head.line, "tube inner_diameter must be positive")}
		if inner_dia > 0 && inner_dia >= min(dia, top_dia)-EPSILON {
			return fail(p, head.line, "inner_diameter %.3f mm must be smaller than outer diameter %.3f mm", inner_dia, min(dia, top_dia))
		}
	}
	if object.walls < 1 {return fail(p, head.line, "walls must be at least 1, got %d", object.walls)}
	if object.floor < 0 {return fail(p, head.line, "floor must not be negative, got %d", object.floor)}
	if (shape != .Profile && (object.size.x <= 0 || object.size.y <= 0)) || object.height <= 0 {return fail(p, head.line, "%s sizes must be positive", head.text)}
	if len(p.design.objects) >= MAX_OBJECTS {return fail(p, head.line, "more than %d objects", MAX_OBJECTS)}
	if object.shape == .Box {
		resolve_box_corners(p, &object, values, seen) or_return
	}
	if len(object_name) > 0 {object.name = strings.clone(object_name, p.allocator)}
	if profile != nil {
		profile.name = object.name
		object.profile = profile
		profile = nil
	}
	append(&p.design.objects, object)
	return true
}

@(private)
resolve_box_corners :: proc(
	p: ^Parser,
	object: ^Object,
	values: [Object_Key]Value,
	seen: bit_set[Object_Key],
) -> bool {
	max_radius := min(object.size.x, object.size.y)*0.5
	for key in ([?]Object_Key{.Radius, .Radius_South, .Radius_North}) {
		if key not_in seen {continue}
		radius := values[key].amount
		if math.is_nan(radius) || math.is_inf(radius) || radius < -EPSILON || radius > max_radius+EPSILON {
			return fail(p, object.line, "%s %.3f mm must be between 0 and %.3f mm",
				OBJECT_KEY_NAMES[key], radius, max_radius)
		}
	}
	shared_radius := clamp(values[.Radius].amount, 0, max_radius)
	object.corner_radii = {.South = shared_radius, .North = shared_radius}
	object_index := len(p.design.objects)
	junction := Junction{
		is_fillet = true,
		kind = .Corner_Radius,
		lower_index = object_index,
		upper_index = object_index,
		size = shared_radius,
		max_size = max_radius,
		line = object.line,
	}
	if .Radius_South not_in seen && .Radius_North not_in seen {
		junction_index := i16(len(p.design.junctions))
		object.corner_junctions = {.South = junction_index, .North = junction_index}
		append(&p.design.junctions, junction)
		return true
	}
	for end in Box_End {
		key := .Radius_South if end == .South else Object_Key.Radius_North
		if key in seen {
			object.corner_radii[end] = clamp(values[key].amount, 0, max_radius)
		}
		junction.corner_end = end
		junction.size = object.corner_radii[end]
		object.corner_junctions[end] = i16(len(p.design.junctions))
		append(&p.design.junctions, junction)
	}
	return true
}

@(private)
object_key :: proc(name: string) -> (Object_Key, bool) {
	for key in Object_Key {
		if OBJECT_KEY_NAMES[key] == name {return key, true}
	}
	return {}, false
}

@(private)
parse_expression :: proc(p: ^Parser) -> (result: Value, ok: bool) {
	left := parse_term(p) or_return
	for peek(p).kind == .Plus || peek(p).kind == .Minus {
		op := next(p)
		right := parse_term(p) or_return
		if left.length != right.length {return {}, fail(p, op.line, "'%s' needs operands of the same kind (length or scalar)", op.text)}
		left.amount = left.amount+right.amount if op.kind == .Plus else left.amount-right.amount
	}
	return left, true
}

@(private)
parse_term :: proc(p: ^Parser) -> (result: Value, ok: bool) {
	left := parse_unary(p) or_return
	for peek(p).kind == .Star || peek(p).kind == .Slash {
		op := next(p)
		right := parse_unary(p) or_return
		if op.kind == .Star {
			if left.length && right.length {return {}, fail(p, op.line, "cannot multiply two lengths")}
			left = {left.amount*right.amount, left.length || right.length}
		} else {
			if right.amount == 0 {return {}, fail(p, op.line, "division by zero")}
			if !left.length && right.length {return {}, fail(p, op.line, "cannot divide a scalar by a length")}
			left = {left.amount/right.amount, left.length && !right.length}
		}
	}
	return left, true
}

@(private)
parse_unary :: proc(p: ^Parser) -> (result: Value, ok: bool) {
	if peek(p).kind == .Minus {
		_ = next(p)
		value := parse_unary(p) or_return
		return {-value.amount, value.length}, true
	}
	return parse_primary(p)
}

@(private)
parse_primary :: proc(p: ^Parser) -> (result: Value, ok: bool) {
	token := next(p)
	#partial switch token.kind {
	case .Number:
		return token.value, true
	case .Left_Paren:
		value := parse_expression(p) or_return
		expect(p, .Right_Paren, "')'") or_return
		return value, true
	case .Ident:
		if peek(p).kind != .Left_Paren {
			value, found := lookup(p, token.text)
			if !found {return {}, fail(p, token.line, "'%s' is not defined", token.text)}
			return value, true
		}
		_ = next(p)
		arguments: [4]Value
		count := 0
		for peek(p).kind != .Right_Paren {
			if count > 0 {expect(p, .Comma, "',' between arguments") or_return}
			if count == len(arguments) {return {}, fail(p, token.line, "too many arguments to '%s'", token.text)}
			arguments[count] = parse_expression(p) or_return
			count += 1
		}
		_ = next(p)
		return call(p, token, arguments[:count])
	}
	found := token.text if token.kind != .Newline && token.kind != .End else "end of line"
	return {}, fail(p, token.line, "expected a value, found '%s'", found)
}

@(private)
call :: proc(p: ^Parser, name: Token, a: []Value) -> (result: Value, ok: bool) {
	arity :: proc(p: ^Parser, name: Token, a: []Value, n: int) -> bool {
		if len(a) != n {return fail(p, name.line, "'%s' takes %d arguments, got %d", name.text, n, len(a))}
		return true
	}
	same :: proc(p: ^Parser, name: Token, a: []Value) -> bool {
		for v in a[1:] {
			if v.length != a[0].length {return fail(p, name.line, "'%s' needs arguments of the same kind", name.text)}
		}
		return true
	}
	switch name.text {
	case "min", "max":
		arity(p, name, a, 2) or_return
		same(p, name, a) or_return
		amount := min(a[0].amount, a[1].amount) if name.text == "min" else max(a[0].amount, a[1].amount)
		return {amount, a[0].length}, true
	case "clamp":
		arity(p, name, a, 3) or_return
		same(p, name, a) or_return
		return {clamp(a[0].amount, a[1].amount, a[2].amount), a[0].length}, true
	case "floor", "ceil", "round":
		arity(p, name, a, 1) or_return
		amount := a[0].amount
		switch name.text {
		case "floor": amount = math.floor(amount+EPSILON)
		case "ceil":  amount = math.ceil(amount-EPSILON)
		case:         amount = math.round(amount)
		}
		return {amount, a[0].length}, true
	case "fit":
		arity(p, name, a, 4) or_return
		if a[0].length {return {}, fail(p, name.line, "fit count must be a scalar")}
		if !a[1].length || !a[2].length || !a[3].length {return {}, fail(p, name.line, "fit unit, minimum and maximum must be lengths")}
		if a[1].amount <= 0 {return {}, fail(p, name.line, "fit unit must be positive")}
		count := math.round(a[0].amount)
		if a[2].amount > 0 {count = max(count, math.ceil(a[2].amount/a[1].amount-EPSILON))}
		if a[3].amount > 0 {count = min(count, math.floor(a[3].amount/a[1].amount+EPSILON))}
		return {max(count, 0), false}, true
	}
	return {}, fail(p, name.line, "unknown function '%s'", name.text)
}

@(private)
resolve_process :: proc(p: ^Parser, printer: Printer) -> bool {
	length :: proc(p: ^Parser, name: string, required: bool, fallback: f64) -> (f64, bool) {
		for parameter in p.design.parameters {
			if parameter.name != name {continue}
			if !parameter.value.length || !(parameter.value.amount > 0 && parameter.value.amount <= max(f64)) {
				return 0, fail(p, parameter.line, "'%s' must be a positive length", name)
			}
			return parameter.value.amount, true
		}
		if required {return 0, fail(p, 1, "define '%s', for example 'let %s = nozzle * 1.1'", name, name)}
		return fallback, true
	}
	scalar :: proc(p: ^Parser, name, unit: string, fallback: f64) -> (f64, bool) {
		for parameter in p.design.parameters {
			if parameter.name != name {continue}
			if parameter.value.length || !(parameter.value.amount >= 0 && parameter.value.amount <= max(f64)) {
				return 0, fail(p, parameter.line, "'%s' must be a scalar in %s", name, unit)
			}
			return parameter.value.amount, true
		}
		return fallback, true
	}
	d := &p.design
	d.line_width = length(p, "line_width", true, 0) or_return
	d.layer_height = length(p, "layer_height", true, 0) or_return
	d.first_layer_height = length(p, "first_layer_height", false, d.layer_height) or_return
	d.first_layer_fan = scalar(p, "first_layer_fan", "percent", 0) or_return
	if d.first_layer_fan < 0 || d.first_layer_fan > 100 {
		return fail(p, 1, "first_layer_fan %.0f must be a percentage from 0 to 100", d.first_layer_fan)
	}
	d.nozzle_temperature = scalar(p, "nozzle_temperature", "°C", 0) or_return
	d.bed_temperature = scalar(p, "bed_temperature", "°C", 0) or_return
	d.defaults.speed = scalar(p, "print_speed", "mm/s", DEFAULT_PRINT_SPEED) or_return
	d.defaults.acceleration = scalar(p, "print_acceleration", "mm/s²", DEFAULT_PRINT_ACCELERATION) or_return
	d.defaults.fan = scalar(p, "fan", "percent", DEFAULT_FAN) or_return
	d.travel_speed = scalar(p, "travel_speed", "mm/s", DEFAULT_TRAVEL_SPEED) or_return
	d.travel_acceleration = scalar(p, "travel_acceleration", "mm/s²", DEFAULT_TRAVEL_ACCELERATION) or_return
	if d.travel_speed <= 0 || d.travel_speed > printer.max_speed {
		return fail(p, 1, "travel_speed must be above 0 and at most the printer's %.0f mm/s", printer.max_speed)
	}
	if d.travel_acceleration <= 0 || d.travel_acceleration > printer.max_acceleration {
		return fail(p, 1, "travel_acceleration must be above 0 and at most the printer's %.0f mm/s²", printer.max_acceleration)
	}
	if len(d.objects) == 0 {return fail(p, 1, "the design has no objects; add a box or cylinder")}
	profile_moves_left := PROFILE_MOVE_LIMIT
	for &object in d.objects {
		if .Speed not_in object.given {object.settings.speed = d.defaults.speed}
		if .Acceleration not_in object.given {object.settings.acceleration = d.defaults.acceleration}
		if .Fan not_in object.given {object.settings.fan = d.defaults.fan}
		settings := object.settings
		if settings.speed <= 0 || settings.speed > printer.max_speed {
			return fail(p, object.line, "speed %.1f mm/s must be above 0 and at most the printer's %.0f mm/s", settings.speed, printer.max_speed)
		}
		if settings.acceleration <= 0 || settings.acceleration > printer.max_acceleration {
			return fail(p, object.line, "acceleration %.0f mm/s² must be above 0 and at most the printer's %.0f mm/s²", settings.acceleration, printer.max_acceleration)
		}
		if settings.fan < 0 || settings.fan > 100 {
			return fail(p, object.line, "fan %.0f must be a percentage from 0 to 100", settings.fan)
		}
		flow := d.line_width*max(d.layer_height, d.first_layer_height)*settings.speed
		if flow > printer.max_volumetric_flow {
			return fail(p, object.line, "%.1f mm/s needs %.1f mm³/s, above the printer's %.1f mm³/s", settings.speed, flow, printer.max_volumetric_flow)
		}
		if object.z == 0 && object.height < d.first_layer_height || object.z > 0 && object.height < d.layer_height {
			return fail(p, object.line, "the object is lower than one layer")
		}
		if object.profile != nil {
			prepare_printable_profile(p, &object, &profile_moves_left) or_return
		}
		if min(object.size.x, object.size.y) < d.line_width {
			return fail(p, object.line, "the object is narrower than one line (%.3f mm)", d.line_width)
		}
		if object.shape != .Box && object.shape != .Profile && object.top_diameter < d.line_width {
			return fail(p, object.line, "the object top_diameter is narrower than one line (%.3f mm)", d.line_width)
		}
		if object.inner_diameter > 0 && (min(object.size.x, object.top_diameter)-object.inner_diameter)*0.5 < d.line_width-EPSILON {
			return fail(p, object.line, "the annular wall is narrower than one line (%.3f mm)", d.line_width)
		}
	}
	return true
}
