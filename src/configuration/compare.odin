package configuration

import "core:encoding/json"
import "core:mem"

Difference_Kind :: enum u8 { Value_Differs, Only_In_Files, Only_In_Running }

Difference :: struct {
    kind: Difference_Kind,
    section: string,
    key: string,
    files_value: string,
    running_value: string,
}

// Compares the file-derived result with Klipper's running `configfile.config`
// object. Strings are borrowed from `res` and `running`; the caller deletes the
// returned array.
compare_running :: proc(res: ^Resolution, running: json.Object, allocator: mem.Allocator) -> [dynamic]Difference {
    differences := make([dynamic]Difference, allocator)
    for &section in res.sections {
        running_section, section_present := running[section.name].(json.Object)
        for &key in section.keys {
            entry, has_value := final_entry(&key)
            if !has_value do continue
            running_value, key_present := running_section[key.name].(json.String)
            if !section_present || !key_present {
                append(&differences, Difference{kind = .Only_In_Files, section = section.name,
                    key = key.name, files_value = entry.value})
            } else if running_value != entry.value {
                append(&differences, Difference{kind = .Value_Differs, section = section.name,
                    key = key.name, files_value = entry.value, running_value = running_value})
            }
        }
    }
    for section_name, section_value in running {
        running_section, is_object := section_value.(json.Object)
        if !is_object do continue
        for key_name, key_value in running_section {
            key, found := find_key(res, section_name, key_name)
            has_value := false
            if found do _, has_value = final_entry(key)
            if has_value do continue
            text, _ := key_value.(json.String)
            append(&differences, Difference{kind = .Only_In_Running, section = section_name,
                key = key_name, running_value = text})
        }
    }
    return differences
}
