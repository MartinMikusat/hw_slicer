package configuration

import "core:mem"
import "core:strings"

Update :: struct {
    section: string,
    key: string,
    value: string,
}

@(private)
Edit_Option :: struct {
    key: string,
    raw_key: string,
    delimiter: string,
    indent: string,
    start_line: int,
    end_line: int,
}

@(private)
Edit_Section :: struct {
    name: string,
    header_line: int,
    insert_after_line: int,
    options: [dynamic]Edit_Option,
}

// Applies key-value overrides in place to the user-override region of `main_text`
// (after the last `[include ...]` directive and before `AUTOSAVE_HEADER`), so every
// updated key wins over included files and `SAVE_CONFIG` while preserving comments,
// includes, and the `SAVE_CONFIG` block verbatim.
apply_overrides :: proc(
    main_text: string,
    updates: []Update,
    allocator := context.allocator,
) -> (result: string, ok: bool) {
    for u in updates {
        if strip(u.section) == "" || strip(u.key) == "" do return "", false
        if strings.contains_any(u.section, "\r\n[]") || strings.contains_any(u.key, "\r\n:=") {
            return "", false
        }
    }
    normalized, _ := strings.replace_all(main_text, "\r\n", "\n", context.temp_allocator)
    if len(updates) == 0 {
        return strings.clone(normalized, allocator), true
    }

    regular := normalized
    autosave_tail := ""
    if pos := strings.index(normalized, AUTOSAVE_HEADER); pos >= 0 {
        regular = normalized[:pos]
        autosave_tail = normalized[pos:]
    }

    raw_lines, _ := strings.split(regular, "\n", context.temp_allocator)
    last_include := -1
    for line, idx in raw_lines {
        stripped := line
        if hash := strings.index_byte(line, '#'); hash >= 0 do stripped = line[:hash]
        name, is_header := section_header(strip(stripped))
        if is_header && strings.has_prefix(name, "include ") {
            last_include = idx
        }
    }

    sections := parse_editable_sections(raw_lines, last_include + 1, context.temp_allocator)

    line_replacements := make(map[int]string, context.temp_allocator)
    line_removed := make(map[int]bool, context.temp_allocator)
    insertions := make(map[int][dynamic]string, context.temp_allocator)
    appended_sections := make([dynamic]string, context.temp_allocator)
    appended_keys := make(map[string][dynamic]string, context.temp_allocator)

    // Deduplicate updates so only the last update for a given (section, lower_key) applies.
    effective := make([dynamic]Update, context.temp_allocator)
    for u, i in updates {
        sec := strip(u.section)
        k_lower := strings.to_lower(strip(u.key), context.temp_allocator)
        superseded := false
        for j in (i + 1)..<len(updates) {
            if strip(updates[j].section) == sec &&
                strings.to_lower(strip(updates[j].key), context.temp_allocator) == k_lower {
                superseded = true
                break
            }
        }
        if !superseded {
            append(&effective, Update{section = sec, key = strip(u.key), value = strip(u.value)})
        }
    }

    for u in effective {
        k_lower := strings.to_lower(u.key, context.temp_allocator)
        sec_idx := find_last_editable_section(sections[:], u.section)
        if sec_idx >= 0 {
            sec := &sections[sec_idx]
            opt_idx := find_last_editable_option(sec.options[:], k_lower)
            if opt_idx >= 0 {
                opt := sec.options[opt_idx]
                line_replacements[opt.start_line] = strings.concatenate({
                    opt.indent, opt.raw_key, opt.delimiter, u.value,
                }, context.temp_allocator)
                for rem in (opt.start_line + 1)..=opt.end_line {
                    line_removed[rem] = true
                }
            } else {
                list, exists := insertions[sec.insert_after_line]
                if !exists {
                    list = make([dynamic]string, context.temp_allocator)
                }
                append(&list, strings.concatenate({u.key, ": ", u.value}, context.temp_allocator))
                insertions[sec.insert_after_line] = list
            }
        } else {
            list, exists := appended_keys[u.section]
            if !exists {
                list = make([dynamic]string, context.temp_allocator)
                append(&appended_sections, u.section)
            }
            append(&list, strings.concatenate({u.key, ": ", u.value}, context.temp_allocator))
            appended_keys[u.section] = list
        }
    }

    out_lines := make([dynamic]string, context.temp_allocator)
    for line, idx in raw_lines {
        if !line_removed[idx] {
            if rep, replaced := line_replacements[idx]; replaced {
                append(&out_lines, rep)
            } else {
                append(&out_lines, line)
            }
        }
        if ins_list, has_ins := insertions[idx]; has_ins {
            for ins in ins_list do append(&out_lines, ins)
        }
    }

    if len(appended_sections) > 0 {
        trailing_blanks := 0
        for len(out_lines) > 0 && strip(out_lines[len(out_lines)-1]) == "" {
            pop(&out_lines)
            trailing_blanks += 1
        }
        if len(out_lines) > 0 {
            append(&out_lines, "")
        }
        for sec_name, s_idx in appended_sections {
            if s_idx > 0 do append(&out_lines, "")
            append(&out_lines, strings.concatenate({"[", sec_name, "]"}, context.temp_allocator))
            for kv in appended_keys[sec_name] {
                append(&out_lines, kv)
            }
        }
        if autosave_tail != "" {
            if trailing_blanks > 0 do append(&out_lines, "")
        } else {
            append(&out_lines, "")
        }
    }

    rebuilt_regular := strings.join(out_lines[:], "\n", context.temp_allocator)
    return strings.concatenate({rebuilt_regular, autosave_tail}, allocator), true
}

@(private)
parse_editable_sections :: proc(
    lines: []string,
    start_index: int,
    allocator: mem.Allocator,
) -> [dynamic]Edit_Section {
    sections := make([dynamic]Edit_Section, allocator)
    current_sec := -1
    current_opt := -1
    opt_indent := 0

    for idx in start_index..<len(lines) {
        raw := lines[idx]
        stripped_hash := raw
        if hash := strings.index_byte(raw, '#'); hash >= 0 do stripped_hash = raw[:hash]
        comment_start := inline_comment_start(stripped_hash)
        value := strip(comment_start < 0 ? stripped_hash : stripped_hash[:comment_start])
        if value == "" do continue

        indent := indent_width(raw)
        if current_sec >= 0 && current_opt >= 0 && indent > opt_indent {
            sections[current_sec].options[current_opt].end_line = idx
            sections[current_sec].insert_after_line = idx
            continue
        }
        opt_indent = indent
        if name, is_header := section_header(value); is_header {
            append(&sections, Edit_Section{
                name = name,
                header_line = idx,
                insert_after_line = idx,
                options = make([dynamic]Edit_Option, allocator),
            })
            current_sec = len(sections) - 1
            current_opt = -1
            continue
        }
        if current_sec < 0 do continue

        delimiter_idx := strings.index_any(value, ":=")
        opt_name := delimiter_idx < 0 ? "" : strings.trim_right_proc(value[:delimiter_idx], is_space)
        if opt_name == "" do continue

        delim := ": "
        if value[delimiter_idx] == '=' {
            delim = " = "
        }
        leading := raw[:indent]
        append(&sections[current_sec].options, Edit_Option{
            key = strings.to_lower(opt_name, allocator),
            raw_key = opt_name,
            delimiter = delim,
            indent = leading,
            start_line = idx,
            end_line = idx,
        })
        current_opt = len(sections[current_sec].options) - 1
        sections[current_sec].insert_after_line = idx
    }
    return sections
}

@(private)
find_last_editable_section :: proc(sections: []Edit_Section, name: string) -> int {
    #reverse for sec, idx in sections {
        if sec.name == name do return idx
    }
    return -1
}

@(private)
find_last_editable_option :: proc(options: []Edit_Option, lower_key: string) -> int {
    #reverse for opt, idx in options {
        if opt.key == lower_key do return idx
    }
    return -1
}
