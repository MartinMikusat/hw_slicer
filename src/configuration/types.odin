package configuration

import "core:mem/virtual"

LAYERS_MAX :: 512
INCLUDE_DEPTH_MAX :: 32
KEYS_MAX :: 65536
ENTRIES_MAX :: 262144
DIAGNOSTICS_MAX :: 256
FILE_BYTES_MAX :: 4 * 1024 * 1024

Layer_Kind :: enum u8 { File, Save_Config }

// One application of a file: a file included twice is two layers. A Save_Config
// layer is the auto-generated tail of the main file.
Layer :: struct {
    path: string,
    kind: Layer_Kind,
    parent: i32,
    include_line: i32,
}

// Entries of one key are in application order; the last entry that is not
// ignored supplies the value Klipper uses.
Entry :: struct {
    layer: i32,
    line: i32,
    value: string,
    ignored: bool,
}

Key :: struct {
    name: string,
    entries: [dynamic]Entry,
}

Section :: struct {
    name: string,
    keys: [dynamic]Key,
    key_index: map[string]i32,
}

Diagnostic_Kind :: enum u8 {
    Missing_Include, Recursive_Include, Include_Outside_Root, Missing_Section_Header,
    Invalid_Option_Line, Save_Config_Corrupt, Default_Section, File_Too_Large, Limit_Exceeded,
}

Diagnostic :: struct {
    kind: Diagnostic_Kind,
    layer: i32,
    line: i32,
    detail: string,
}

// Owns every string and array it holds in one arena. Destroy it after the
// last borrower, including views returned by the lookup procedures.
Resolution :: struct {
    arena: virtual.Arena,
    layers: [dynamic]Layer,
    sections: [dynamic]Section,
    diagnostics: [dynamic]Diagnostic,
    missing: [dynamic]string,
    section_index: map[string]i32,
}

Source :: struct {
    path: string,
    data: string,
}

resolution_destroy :: proc(res: ^Resolution) {
    assert(res != nil)
    virtual.arena_destroy(&res.arena)
    res^ = {}
}

complete :: proc(res: ^Resolution) -> bool {
    return len(res.missing) == 0
}

find_section :: proc(res: ^Resolution, name: string) -> (index: i32, ok: bool) {
    index, ok = res.section_index[name]
    return
}

find_key :: proc(res: ^Resolution, section, name: string) -> (key: ^Key, ok: bool) {
    section_index := res.section_index[section] or_return
    key_index := res.sections[section_index].key_index[name] or_return
    return &res.sections[section_index].keys[key_index], true
}

final_entry :: proc(key: ^Key) -> (entry: Entry, ok: bool) {
    #reverse for candidate in key.entries {
        if !candidate.ignored do return candidate, true
    }
    return {}, false
}

diagnostic_text :: proc(kind: Diagnostic_Kind) -> string {
    switch kind {
    case .Missing_Include: return "Include file does not exist"
    case .Recursive_Include: return "Recursive include of a configuration file"
    case .Include_Outside_Root: return "Include path leaves the configuration root"
    case .Missing_Section_Header: return "Option line before any section header"
    case .Invalid_Option_Line: return "Line is neither a section header nor an option"
    case .Save_Config_Corrupt: return "SAVE_CONFIG block is corrupt and ignored"
    case .Default_Section: return "DEFAULT section inheritance is not modelled"
    case .File_Too_Large: return "Configuration file exceeds the size limit"
    case .Limit_Exceeded: return "Resolution limit exceeded; result is truncated"
    }
    return ""
}
