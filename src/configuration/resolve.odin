package configuration

import "core:mem/virtual"
import "core:strings"

AUTOSAVE_HEADER :: "\n#*# <---------------------- SAVE_CONFIG ---------------------->\n" +
    "#*# DO NOT EDIT THIS BLOCK OR BELOW. The contents are auto-generated.\n#*#\n"

// Resolves the configuration of `main_path` exactly as Klipper's configfile.py
// loads it. `listing` is every readable path under the configuration root;
// `sources` is the subset already downloaded. A listed include that is not in
// `sources` is reported in `missing` and not applied: download it and resolve
// again until `complete`. `res` must stay at one address until destroyed. Returns
// false only when an arena cannot start.
resolve :: proc(res: ^Resolution, main_path: string, listing: []string, sources: []Source) -> bool {
    assert(res != nil && len(main_path) > 0)
    res^ = {}
    if virtual.arena_init_growing(&res.arena) != nil do return false
    scratch_arena: virtual.Arena
    if virtual.arena_init_growing(&scratch_arena) != nil {
        virtual.arena_destroy(&res.arena)
        return false
    }
    defer virtual.arena_destroy(&scratch_arena)
    arena := virtual.arena_allocator(&res.arena)
    scratch := virtual.arena_allocator(&scratch_arena)
    res.layers = make([dynamic]Layer, arena)
    res.sections = make([dynamic]Section, arena)
    res.diagnostics = make([dynamic]Diagnostic, arena)
    res.missing = make([dynamic]string, arena)
    res.section_index = make(map[string]i32, arena)
    r := Resolver{res = res, arena = arena, scratch = scratch, listing = listing, sources = sources,
        stack = make([dynamic]string, scratch)}

    data, found := source_text(&r, main_path)
    if !found {
        append(&res.missing, strings.clone(main_path, arena))
        return true
    }
    regular, autosave, state := split_autosave(&r, data)
    append(&res.layers, Layer{path = strings.clone(main_path, arena), parent = -1, include_line = -1})
    walk_file(&r, main_path, regular, 0, 0)
    switch state {
    case .Absent:
    case .Corrupt: diagnose(&r, .Save_Config_Corrupt, 0, 0, "")
    case .Present: apply_autosave(&r, main_path, autosave)
    }
    return true
}

Autosave_State :: enum { Absent, Present, Corrupt }

Autosave :: struct {
    lines: []Line,
}

// configfile.py _find_autosave_data. A corrupt block makes the whole file
// regular text, where its `#*#` lines are comments.
split_autosave :: proc(r: ^Resolver, data: string) -> (regular: string, autosave: Autosave, state: Autosave_State) {
    position := strings.index(data, AUTOSAVE_HEADER)
    if position < 0 do return data, {}, .Absent
    regular = data[:position]
    tail := data[position+len(AUTOSAVE_HEADER):]
    stripped := strip(tail)
    leading := len(tail) - len(strings.trim_left_proc(tail, is_space))
    if strings.contains(regular, "\n#*# ") || strings.contains(stripped, AUTOSAVE_HEADER) {
        return data, {}, .Corrupt
    }
    first_line := i32(strings.count(data[:position+len(AUTOSAVE_HEADER)+leading], "\n")) + 1
    raw_lines, _ := strings.split(stripped, "\n", r.scratch)
    lines := make([]Line, len(raw_lines), r.scratch)
    for raw, index in raw_lines {
        prefixed := strings.has_prefix(raw, "#*#")
        if stripped != "" && (!prefixed || (len(raw) >= 4 && !strings.has_prefix(raw, "#*# "))) {
            return data, {}, .Corrupt
        }
        lines[index] = Line{text = len(raw) >= 4 ? raw[4:] : "", number = first_line + i32(index)}
    }
    return regular, Autosave{lines = lines}, .Present
}

// configfile.py _strip_duplicates plus the append of what remains: a value
// already set by the regular configuration wins and the saved one is kept only
// as an ignored entry.
apply_autosave :: proc(r: ^Resolver, main_path: string, autosave: Autosave) {
    if len(r.res.layers) >= LAYERS_MAX {
        report_limit(r, 0, 0)
        return
    }
    layer := i32(len(r.res.layers))
    append(&r.res.layers, Layer{path = strings.clone(main_path, r.arena), kind = .Save_Config,
        parent = 0, include_line = autosave.lines[0].number})
    lines := autosave.lines
    duplicate := make([]bool, len(lines), r.scratch)
    header := make([]bool, len(lines), r.scratch)
    section := ""
    in_section := false
    in_duplicate := false
    for line, index in lines {
        pruned := strings.trim_right_proc(before_comment_character(line.text), is_space)
        if pruned == "" do continue
        if is_space(rune(pruned[0])) {
            duplicate[index] = in_duplicate
            continue
        }
        in_duplicate = false
        if pruned[0] == '[' {
            section = strip(pruned[1:max(1, len(pruned)-1)])
            in_section = true
            header[index] = true
            continue
        }
        if in_section && option_defined(r, section, leading_word(pruned)) {
            in_duplicate = true
            duplicate[index] = true
        }
    }
    effective := make([]Line, len(lines), r.scratch)
    shadow := make([]Line, len(lines), r.scratch)
    for line, index in lines {
        effective[index] = Line{text = duplicate[index] ? "" : line.text, number = line.number}
        shadow[index] = Line{text = (duplicate[index] || header[index]) ? line.text : "", number = line.number}
    }
    parse_chunk(r, effective, layer, false)
    parse_chunk(r, shadow, layer, true)
}

before_comment_character :: proc(text: string) -> string {
    position := strings.index_any(text, "#;")
    return position < 0 ? text : text[:position]
}

option_defined :: proc(r: ^Resolver, section, name: string) -> bool {
    section_index, found := r.res.section_index[section]
    if !found do return false
    _, defined := r.res.sections[section_index].key_index[strings.to_lower(name, r.scratch)]
    return defined
}

leading_word :: proc(text: string) -> string {
    for index in 0..<len(text) {
        character := text[index]
        word := (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') ||
            (character >= '0' && character <= '9') || character == '_'
        if !word do return text[:index]
    }
    return text
}

// configfile.py _parse_config: text between include lines is one chunk, so an
// override placed after an include applies after the included file.
walk_file :: proc(r: ^Resolver, path, text: string, layer: i32, depth: int) {
    append(&r.stack, path)
    defer pop(&r.stack)
    raw_lines, _ := strings.split(text, "\n", r.scratch)
    buffer := make([dynamic]Line, r.scratch)
    for raw, index in raw_lines {
        number := i32(index + 1)
        stripped := raw
        if hash := strings.index_byte(raw, '#'); hash >= 0 do stripped = raw[:hash]
        name, is_header := section_header(stripped)
        if is_header && strings.has_prefix(name, "include ") {
            parse_chunk(r, buffer[:], layer, false)
            clear(&buffer)
            include_files(r, path, strip(name[len("include "):]), layer, number, depth)
            continue
        }
        append(&buffer, Line{text = stripped, number = number})
    }
    parse_chunk(r, buffer[:], layer, false)
}

include_files :: proc(r: ^Resolver, source_path, spec: string, layer, line: i32, depth: int) {
    pattern, inside := join_path(r, source_path, spec)
    if !inside {
        diagnose(r, .Include_Outside_Root, layer, line, spec)
        return
    }
    matches := make([dynamic]string, r.scratch)
    if has_magic(pattern) {
        for candidate in r.listing {
            if glob_match_path(pattern, candidate, r.scratch) do append(&matches, candidate)
        }
        sort_strings(matches[:])
    } else if listed(r, pattern) {
        append(&matches, pattern)
    } else {
        diagnose(r, .Missing_Include, layer, line, spec)
        return
    }
    for path in matches do include_one(r, path, layer, line, depth)
}

include_one :: proc(r: ^Resolver, path: string, parent, line: i32, depth: int) {
    for active in r.stack {
        if active == path {
            diagnose(r, .Recursive_Include, parent, line, path)
            return
        }
    }
    if depth + 1 > INCLUDE_DEPTH_MAX || len(r.res.layers) >= LAYERS_MAX {
        report_limit(r, parent, line)
        return
    }
    text, found := source_text(r, path)
    if !found {
        if !is_missing(r, path) do append(&r.res.missing, strings.clone(path, r.arena))
        return
    }
    if len(text) > FILE_BYTES_MAX {
        diagnose(r, .File_Too_Large, parent, line, path)
        return
    }
    layer := i32(len(r.res.layers))
    append(&r.res.layers, Layer{path = strings.clone(path, r.arena), parent = parent, include_line = line})
    walk_file(r, path, text, layer, depth + 1)
}

source_text :: proc(r: ^Resolver, path: string) -> (text: string, found: bool) {
    for source in r.sources {
        if source.path != path do continue
        if len(source.data) > FILE_BYTES_MAX do return source.data, true
        text, _ = strings.replace_all(source.data, "\r\n", "\n", r.scratch)
        return text, true
    }
    return "", false
}

is_missing :: proc(r: ^Resolver, path: string) -> bool {
    for candidate in r.res.missing do if candidate == path do return true
    return false
}

listed :: proc(r: ^Resolver, path: string) -> bool {
    for candidate in r.listing do if candidate == path do return true
    return false
}

// os.path.join(dirname(source), spec) with lexical dot handling. A leading
// slash or a parent step above the root cannot name a file under the root.
join_path :: proc(r: ^Resolver, source_path, spec: string) -> (joined: string, inside: bool) {
    if strings.has_prefix(spec, "/") do return "", false
    parts := make([dynamic]string, r.scratch)
    directory := source_path
    if slash := strings.last_index_byte(source_path, '/'); slash >= 0 {
        directory = source_path[:slash]
    } else {
        directory = ""
    }
    for source in ([2]string{directory, spec}) {
        pieces, _ := strings.split(source, "/", r.scratch)
        for piece in pieces {
            switch piece {
            case "", ".":
            case "..":
                if len(parts) == 0 do return "", false
                pop(&parts)
            case:
                append(&parts, piece)
            }
        }
    }
    return strings.join(parts[:], "/", r.scratch), len(parts) > 0
}

sort_strings :: proc(values: []string) {
    for index in 1..<len(values) {
        current := values[index]
        position := index
        for position > 0 && values[position-1] > current {
            values[position] = values[position-1]
            position -= 1
        }
        values[position] = current
    }
}
