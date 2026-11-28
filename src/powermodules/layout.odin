package powermodules

import "core:math"
import "core:mem"
import "core:strings"

Rect :: struct {
	x, y, width, height: f32,
}
Diagram_Header :: struct {
	box:  Rect,
	name: string,
}
Diagram_Module :: struct {
	box:    Rect,
	module: Module,
}
Diagram :: struct {
	width, height: f32,
	panels:        [4]Rect,
	headers:       [8]Diagram_Header,
	modules:       [32]Diagram_Module,
	panel_count, header_count, module_count: int,
}
DESCRIPTOR_LABELS :: [5]string{"WEB UI:", "TX:", "RX:", "CAN GW ID:", "PALKO pos.:"}

descriptor_values :: proc(module: Module) -> [5]string {
	return {module.webUi, module.tx, module.rx, module.canGwId, module.palkoPos}
}

find :: proc(mappings: []Module_Mapping, series, variant: string) -> (Module_Mapping, bool) {
	for mapping in mappings {
		if strings.equal_fold(strings.trim_space(series), mapping.series) && strings.trim_space(variant) == mapping.variant {
			return mapping, true
		}
	}
	return {}, false
}

// Preserve the reference's panel/section/row-major cabinet orientation. Narrow
// panes scroll horizontally; module positions never wrap into another cabinet.
diagram :: proc(mapping: Module_Mapping, ch, line_height, available_width: f32) -> (Diagram, bool) {
	if !(ch > 0 && ch <= 256 && line_height > 0 && line_height <= 512 && available_width >= 0) ||
		math.is_inf(available_width, 0) || len(mapping.panels) == 0 || len(mapping.panels) > 4 {
		return {}, false
	}
	columns_max := 0
	module_count, header_count := 0, 0
	for panel in mapping.panels {
		columns := 0
		if len(panel.sections) == 0 {return {}, false}
		for section in panel.sections {
			if section.gridColumns <= 0 || section.gridColumns > 8 || len(section.modules) == 0 ||
				len(section.modules) % section.gridColumns != 0 {
				return {}, false
			}
			columns += section.gridColumns
			header_count += 1
			module_count += len(section.modules)
		}
		columns_max = max(columns_max, columns)
	}
	if header_count > 8 || module_count > 32 || columns_max > 8 {return {}, false}
	// Valid table text can exceed the cabinet geometry ceiling. Cap expansion
	// here so every host retains the full table without rejecting its diagram.
	output := Diagram{width = max(min(available_width, 1e6), f32(columns_max) * 22 * ch + f32(columns_max - 1) * ch + 4 * ch)}
	for panel in mapping.panels {
		columns, rows := 0, 0
		for section in panel.sections {
			columns += section.gridColumns
			rows = max(rows, len(section.modules) / section.gridColumns)
		}
		card_width := (output.width - 4 * ch - f32(columns - 1) * ch) / f32(columns)
		top := output.height + line_height
		x := 2 * ch
		y := top + line_height
		for section in panel.sections {
			width := f32(section.gridColumns) * card_width + f32(section.gridColumns - 1) * ch
			output.headers[output.header_count] = {{x, y, width, line_height}, section.name}
			output.header_count += 1
			x += width + ch
		}
		y += line_height + ch
		for row in 0..<rows {
			fields := 0
			for section in panel.sections {
				for col in 0..<section.gridColumns {
					index := row * section.gridColumns + col
					if index >= len(section.modules) {continue}
					count := 0
					for value in descriptor_values(section.modules[index]) {
						if value != "" {count += 1}
					}
					fields = max(fields, count)
				}
			}
			height := f32(fields) * line_height + 2 * ch
			x = 2 * ch
			for section in panel.sections {
				for col in 0..<section.gridColumns {
					index := row * section.gridColumns + col
					if index < len(section.modules) {
						output.modules[output.module_count] = {{x, y, card_width, height}, section.modules[index]}
						output.module_count += 1
					}
					x += card_width + ch
				}
			}
			y += height + ch
		}
		output.panels[output.panel_count] = {0, top, output.width, y - ch + line_height - top}
		output.panel_count += 1
		output.height = y - ch + line_height
	}
	assert(output.module_count == module_count)
	assert(output.header_count == header_count)
	return output, true
}

// One complete spoken/readable value per module, shared by both native hosts.
describe :: proc(module: Module, allocator: mem.Allocator) -> string {
	builder := strings.builder_make(allocator)
	labels := DESCRIPTOR_LABELS
	for value, field in descriptor_values(module) {
		if value == "" {continue}
		if len(strings.to_string(builder)) > 0 {strings.write_string(&builder, ", ")}
		strings.write_string(&builder, labels[field])
		strings.write_byte(&builder, ' ')
		strings.write_string(&builder, value)
	}
	return strings.to_string(builder)
}

find_id :: proc(mappings: []Module_Mapping, id: string) -> (Module_Mapping, bool) {
	for mapping in mappings {
		if mapping.id == id {return mapping, true}
	}
	return {}, false
}
