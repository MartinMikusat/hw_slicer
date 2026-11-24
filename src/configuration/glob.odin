package configuration

import "core:mem"
import "core:strings"
import "core:unicode/utf8"

has_magic :: proc(pattern: string) -> bool {
    return strings.contains_any(pattern, "*?[")
}

// Mirrors Python glob over a flat file listing: equal component counts, exact
// match for plain components, fnmatch for magic ones, and wildcards never match
// a leading dot unless the pattern component starts with a dot.
glob_match_path :: proc(pattern, path: string, scratch: mem.Allocator) -> bool {
    pattern_parts, _ := strings.split(pattern, "/", scratch)
    path_parts, _ := strings.split(path, "/", scratch)
    if len(pattern_parts) != len(path_parts) do return false
    for pattern_part, index in pattern_parts {
        name := path_parts[index]
        if !has_magic(pattern_part) {
            if pattern_part != name do return false
            continue
        }
        if strings.has_prefix(name, ".") && !strings.has_prefix(pattern_part, ".") do return false
        if !glob_component_match(pattern_part, name, scratch) do return false
    }
    return true
}

glob_component_match :: proc(pattern, name: string, scratch: mem.Allocator) -> bool {
    pattern_runes := utf8.string_to_runes(pattern, scratch)
    name_runes := utf8.string_to_runes(name, scratch)
    pattern_at, name_at := 0, 0
    star_pattern, star_name := -1, 0
    for name_at < len(name_runes) {
        if pattern_at < len(pattern_runes) {
            switch pattern_runes[pattern_at] {
            case '*':
                star_pattern = pattern_at
                star_name = name_at
                pattern_at += 1
                continue
            case '?':
                pattern_at += 1
                name_at += 1
                continue
            case '[':
                matched, next, valid := glob_class_match(pattern_runes, pattern_at, name_runes[name_at])
                if valid && matched {
                    pattern_at = next
                    name_at += 1
                    continue
                }
                if !valid && name_runes[name_at] == '[' {
                    pattern_at += 1
                    name_at += 1
                    continue
                }
            case:
                if pattern_runes[pattern_at] == name_runes[name_at] {
                    pattern_at += 1
                    name_at += 1
                    continue
                }
            }
        }
        if star_pattern < 0 do return false
        pattern_at = star_pattern + 1
        star_name += 1
        name_at = star_name
    }
    for pattern_at < len(pattern_runes) && pattern_runes[pattern_at] == '*' do pattern_at += 1
    return pattern_at == len(pattern_runes)
}

glob_class_match :: proc(pattern: []rune, start: int, subject: rune) -> (matched: bool, next: int, valid: bool) {
    assert(start < len(pattern) && pattern[start] == '[')
    at := start + 1
    negate := at < len(pattern) && pattern[at] == '!'
    if negate do at += 1
    first := at
    for at < len(pattern) {
        if pattern[at] == ']' && at > first { break }
        low := pattern[at]
        if at + 2 < len(pattern) && pattern[at+1] == '-' && pattern[at+2] != ']' {
            if subject >= low && subject <= pattern[at+2] do matched = true
            at += 3
        } else {
            if subject == low do matched = true
            at += 1
        }
    }
    if at >= len(pattern) do return false, 0, false
    return matched != negate, at + 1, true
}
