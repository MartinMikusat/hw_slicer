package configuration

import "core:mem"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

Line :: struct {
    text: string,
    number: i32,
}

// State of one RawConfigParser.read_file call: Klipper parses the text between
// includes as an independent unit, so a chunk has no section until it opens one.
Chunk :: struct {
    section: i32,
    key: i32,
    has_option: bool,
    option_line: i32,
    indent: int,
    pieces: [dynamic]string,
}

Resolver :: struct {
    res: ^Resolution,
    arena: mem.Allocator,
    scratch: mem.Allocator,
    listing: []string,
    sources: []Source,
    stack: [dynamic]string,
    entries: int,
    keys: int,
    limit_reported: bool,
}

is_space :: proc(character: rune) -> bool {
    return unicode.is_space(character) || (character >= 0x1c && character <= 0x1f)
}

strip :: proc(text: string) -> string {
    return strings.trim_right_proc(strings.trim_left_proc(text, is_space), is_space)
}

// Python RawConfigParser._read on one chunk, with Klipper's comment stripping
// already applied by the caller. Entries are recorded when an option ends.
parse_chunk :: proc(r: ^Resolver, lines: []Line, layer: i32, ignored: bool) {
    chunk := Chunk{section = -1, key = -1, pieces = make([dynamic]string, r.scratch)}
    for line in lines {
        comment_start := inline_comment_start(line.text)
        value := strip(comment_start < 0 ? line.text : line.text[:comment_start])
        if value == "" {
            if comment_start < 0 && chunk.has_option do append(&chunk.pieces, "")
            continue
        }
        indent := indent_width(line.text)
        if chunk.section >= 0 && chunk.has_option && indent > chunk.indent {
            append(&chunk.pieces, value)
            continue
        }
        chunk.indent = indent
        if name, is_header := section_header(value); is_header {
            chunk_flush(r, &chunk, layer, ignored)
            open_section(r, &chunk, name, layer, line.number)
            continue
        }
        if chunk.section < 0 {
            diagnose(r, .Missing_Section_Header, layer, line.number, "")
            continue
        }
        delimiter := strings.index_any(value, ":=")
        name := delimiter < 0 ? "" : strings.trim_right_proc(value[:delimiter], is_space)
        if name == "" {
            diagnose(r, .Invalid_Option_Line, layer, line.number, "")
            continue
        }
        chunk_flush(r, &chunk, layer, ignored)
        chunk.option_line = line.number
        open_option(r, &chunk, name)
        if chunk.has_option do append(&chunk.pieces, strip(value[delimiter+1:]))
    }
    chunk_flush(r, &chunk, layer, ignored)
}

chunk_flush :: proc(r: ^Resolver, chunk: ^Chunk, layer: i32, ignored: bool) {
    if !chunk.has_option do return
    assert(chunk.section >= 0 && chunk.key >= 0)
    joined := strings.join(chunk.pieces[:], "\n", r.arena)
    value := strings.trim_right_proc(joined, is_space)
    clear(&chunk.pieces)
    chunk.has_option = false
    if r.entries >= ENTRIES_MAX {
        report_limit(r, layer, chunk.option_line)
        return
    }
    r.entries += 1
    key := &r.res.sections[chunk.section].keys[chunk.key]
    append(&key.entries, Entry{layer = layer, line = chunk.option_line, value = value, ignored = ignored})
}

open_section :: proc(r: ^Resolver, chunk: ^Chunk, name: string, layer, line: i32) {
    chunk.has_option = false
    index, found := r.res.section_index[name]
    if !found {
        stored := strings.clone(name, r.arena)
        append(&r.res.sections, Section{name = stored, keys = make([dynamic]Key, r.arena),
            key_index = make(map[string]i32, r.arena)})
        index = i32(len(r.res.sections) - 1)
        r.res.section_index[stored] = index
        if stored == "DEFAULT" do diagnose(r, .Default_Section, layer, line, "")
    }
    chunk.section = index
}

open_option :: proc(r: ^Resolver, chunk: ^Chunk, raw_name: string) {
    assert(chunk.section >= 0)
    name := strings.to_lower(raw_name, r.scratch)
    section := &r.res.sections[chunk.section]
    index, found := section.key_index[name]
    if !found {
        if r.keys >= KEYS_MAX {
            report_limit(r, 0, chunk.option_line)
            chunk.has_option = false
            return
        }
        r.keys += 1
        stored := strings.clone(name, r.arena)
        append(&section.keys, Key{name = stored, entries = make([dynamic]Entry, r.arena)})
        index = i32(len(section.keys) - 1)
        section.key_index[stored] = index
    }
    chunk.key = index
    chunk.has_option = true
}

// The first semicolon that starts the line or follows whitespace.
inline_comment_start :: proc(text: string) -> int {
    for index in 0..<len(text) {
        if text[index] != ';' do continue
        if index == 0 do return 0
        previous, _ := utf8.decode_last_rune_in_string(text[:index])
        if is_space(previous) do return index
    }
    return -1
}

indent_width :: proc(text: string) -> int {
    width := 0
    for character in text {
        if !is_space(character) do break
        width += 1
    }
    return width
}

// RawConfigParser.SECTCRE: the greedy header runs to the last bracket.
section_header :: proc(text: string) -> (name: string, ok: bool) {
    if len(text) < 3 || text[0] != '[' do return "", false
    close := strings.last_index_byte(text, ']')
    if close < 2 do return "", false
    return text[1:close], true
}

diagnose :: proc(r: ^Resolver, kind: Diagnostic_Kind, layer, line: i32, detail: string) {
    if len(r.res.diagnostics) >= DIAGNOSTICS_MAX do return
    append(&r.res.diagnostics, Diagnostic{kind = kind, layer = layer, line = line,
        detail = strings.clone(detail, r.arena)})
}

report_limit :: proc(r: ^Resolver, layer, line: i32) {
    if r.limit_reported do return
    r.limit_reported = true
    diagnose(r, .Limit_Exceeded, layer, line, "")
}
