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

Printer :: struct {
	nozzle_diameter:   f64, // mm
	filament_diameter: f64, // mm
}

Shape :: enum u8 {
	Box,
	Cylinder,
}

Object :: struct {
	shape:  Shape,
	line:   int,
	center: [2]f64, // mm from the bed centre
	size:   [2]f64, // box width and depth; cylinder diameter in both
	height: f64,
	walls:  int,
	floor:  int,
}

Parameter :: struct {
	name:  string,
	value: Value,
	line:  int,
}

Design :: struct {
	parameters:         [dynamic]Parameter,
	objects:            [dynamic]Object,
	line_width:         f64,
	layer_height:       f64,
	first_layer_height: f64,
	print_speed:        f64, // mm/s
	travel_speed:       f64, // mm/s
	filament_diameter:  f64,
}

Error :: struct {
	line:    int,
	message: string,
}

DEFAULT_PRINT_SPEED :: 40
DEFAULT_TRAVEL_SPEED :: 150
MAX_OBJECTS :: 256
MAX_PARAMETERS :: 256
EPSILON :: 1e-9

design_destroy :: proc(d: ^Design) {
	for parameter in d.parameters {delete(parameter.name, d.parameters.allocator)}
	delete(d.parameters)
	delete(d.objects)
	d^ = {}
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
	p := Parser{allocator = allocator}
	p.design.parameters = make([dynamic]Parameter, allocator)
	p.design.objects = make([dynamic]Object, allocator)
	p.design.filament_diameter = printer.filament_diameter
	p.tokens = make([dynamic]Token, context.temp_allocator)
	defer delete(p.tokens)
	ok = tokenize(&p, source) &&
		define(&p, "nozzle", {printer.nozzle_diameter, true}, 0) &&
		define(&p, "filament", {printer.filament_diameter, true}, 0) &&
		parse_statements(&p) &&
		resolve_process(&p)
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
}

@(private)
Parser :: struct {
	allocator: mem.Allocator,
	tokens:    [dynamic]Token,
	position:  int,
	design:    Design,
	err:       Error,
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
			append(&p.tokens, Token{kind = .Number, text = source[start:i], value = {amount, unit == "mm"}, line = line})
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
			append(&p.tokens, Token{kind = kind, text = source[i:i+1], line = line})
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
define :: proc(p: ^Parser, name: string, value: Value, line: int) -> bool {
	if _, exists := lookup(p, name); exists {return fail(p, line, "'%s' is already defined", name)}
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
				value := parse_expression(p) or_return
				define(p, name.text, value, name.line) or_return
			} else if token.text == "box" || token.text == "cylinder" {
				parse_object(p, token) or_return
			} else {
				return fail(p, token.line, "unknown statement '%s'; use let, box or cylinder", token.text)
			}
			expect(p, .Newline, "end of line") or_return
		case .Number, .Left_Paren, .Right_Paren, .Comma, .Equals, .Plus, .Minus, .Star, .Slash, .End:
			return fail(p, token.line, "unexpected '%s' at the start of a statement", token.text)
		}
	}
	return true
}

@(private)
Object_Key :: enum u8 {
	X,
	Y,
	Width,
	Depth,
	Diameter,
	Height,
	Walls,
	Floor,
}

@(private)
OBJECT_KEY_NAMES := [Object_Key]string {
	.X        = "x",
	.Y        = "y",
	.Width    = "width",
	.Depth    = "depth",
	.Diameter = "diameter",
	.Height   = "height",
	.Walls    = "walls",
	.Floor    = "floor",
}

@(private)
parse_object :: proc(p: ^Parser, head: Token) -> bool {
	shape := Shape.Box if head.text == "box" else Shape.Cylinder
	allowed := bit_set[Object_Key]{.X, .Y, .Height, .Walls, .Floor}
	required := bit_set[Object_Key]{.Height, .Walls}
	if shape == .Box {
		allowed += {.Width, .Depth}
		required += {.Width, .Depth}
	} else {
		allowed += {.Diameter}
		required += {.Diameter}
	}
	values: [Object_Key]Value
	seen: bit_set[Object_Key]
	expect(p, .Left_Paren, "'(' after the object name") or_return
	for peek(p).kind != .Right_Paren {
		if card(seen) > 0 {expect(p, .Comma, "',' between arguments") or_return}
		name := expect(p, .Ident, "an argument name") or_return
		key, found := object_key(name.text)
		if !found || key not_in allowed {return fail(p, name.line, "%s has no argument '%s'", head.text, name.text)}
		if key in seen {return fail(p, name.line, "argument '%s' is given twice", name.text)}
		expect(p, .Equals, "'=' after the argument name") or_return
		value := parse_expression(p) or_return
		wants_length := key != .Walls && key != .Floor
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
	for key in ([2]Object_Key{.Walls, .Floor}) {
		v := values[key].amount
		if abs(v-math.round(v)) > EPSILON {return fail(p, head.line, "'%s' must be a whole count, got %.3f", OBJECT_KEY_NAMES[key], v)}
	}
	object := Object{
		shape  = shape,
		line   = head.line,
		center = {values[.X].amount, values[.Y].amount},
		height = values[.Height].amount,
		walls  = int(math.round(values[.Walls].amount)),
		floor  = int(math.round(values[.Floor].amount)),
	}
	if shape == .Box {
		object.size = {values[.Width].amount, values[.Depth].amount}
	} else {
		object.size = {values[.Diameter].amount, values[.Diameter].amount}
	}
	if object.walls < 1 {return fail(p, head.line, "walls must be at least 1, got %d", object.walls)}
	if object.floor < 0 {return fail(p, head.line, "floor must not be negative, got %d", object.floor)}
	if object.size.x <= 0 || object.size.y <= 0 || object.height <= 0 {return fail(p, head.line, "%s sizes must be positive", head.text)}
	if len(p.design.objects) >= MAX_OBJECTS {return fail(p, head.line, "more than %d objects", MAX_OBJECTS)}
	append(&p.design.objects, object)
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
resolve_process :: proc(p: ^Parser) -> bool {
	length :: proc(p: ^Parser, name: string, required: bool, fallback: f64) -> (f64, bool) {
		for parameter in p.design.parameters {
			if parameter.name != name {continue}
			if !parameter.value.length || parameter.value.amount <= 0 {
				return 0, fail(p, parameter.line, "'%s' must be a positive length", name)
			}
			return parameter.value.amount, true
		}
		if required {return 0, fail(p, 1, "define '%s', for example 'let %s = nozzle * 1.1'", name, name)}
		return fallback, true
	}
	speed :: proc(p: ^Parser, name: string, fallback: f64) -> (f64, bool) {
		for parameter in p.design.parameters {
			if parameter.name != name {continue}
			if parameter.value.length || parameter.value.amount <= 0 {
				return 0, fail(p, parameter.line, "'%s' must be a positive scalar in mm/s", name)
			}
			return parameter.value.amount, true
		}
		return fallback, true
	}
	d := &p.design
	d.line_width = length(p, "line_width", true, 0) or_return
	d.layer_height = length(p, "layer_height", true, 0) or_return
	d.first_layer_height = length(p, "first_layer_height", false, d.layer_height) or_return
	d.print_speed = speed(p, "print_speed", DEFAULT_PRINT_SPEED) or_return
	d.travel_speed = speed(p, "travel_speed", DEFAULT_TRAVEL_SPEED) or_return
	if len(d.objects) == 0 {return fail(p, 1, "the design has no objects; add a box or cylinder")}
	for object in d.objects {
		if min(object.size.x, object.size.y) < d.line_width {
			return fail(p, object.line, "the object is narrower than one line (%.3f mm)", d.line_width)
		}
		if object.height < d.first_layer_height {
			return fail(p, object.line, "the object is lower than the first layer (%.3f mm)", d.first_layer_height)
		}
	}
	return true
}
