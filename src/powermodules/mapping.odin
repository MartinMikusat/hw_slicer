package powermodules

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"

// Snapshot of Electrobun kb_powerModuleMappings.ts at
// 1fc06c6449b3eedef1e78ee585c5908728625ba0. Decode once per document;
// mappings and rendered strings belong to their supplied allocators.
Module :: struct {
	webUi, tx, rx, canGwId, palkoPos: string,
}
Module_Section :: struct {
	name:        string,
	gridColumns: int,
	modules:     []Module,
}
Module_Panel :: struct {
	sections: []Module_Section,
}
Module_Mapping :: struct {
	id, label, series, variant: string,
	panels:                    []Module_Panel,
}
POWER_MODULES_JSON :: `[{"id":"slim100","label":"SLIM100 - 2/2 (50/50 kW) Power Distribution","series":"SLIM100","panels":[{"sections":[{"name":"PUG1","gridColumns":1,"modules":[{"webUi":"1473","tx":"0x5C1","rx":"0x641","palkoPos":"2"},{"webUi":"1472","tx":"0x5C0","rx":"0x640","palkoPos":"1"}]}]},{"sections":[{"name":"PUG0","gridColumns":1,"modules":[{"webUi":"1457","tx":"0x5B1","rx":"0x631","palkoPos":"2"},{"webUi":"1456","tx":"0x5B0","rx":"0x630","palkoPos":"1"}]}]}]},{"id":"ufc150-90-60","label":"UFC 150 - PRE power modules 90/60 kW (Power distribution 9/6)","series":"UFC150","variant":"90/60","panels":[{"sections":[{"name":"PUG1","gridColumns":3,"modules":[{"webUi":"1477","tx":"0x5C5","rx":"645","canGwId":"21","palkoPos":"6"},{"webUi":"1476","tx":"0x5C4","rx":"644","canGwId":"20","palkoPos":"5"},{"webUi":"1475","tx":"0x5C3","rx":"643","canGwId":"19","palkoPos":"4"},{"webUi":"1474","tx":"0x5C2","rx":"642","canGwId":"18","palkoPos":"3"},{"webUi":"1473","tx":"0x5C1","rx":"641","canGwId":"17","palkoPos":"2"},{"webUi":"1472","tx":"0x5C0","rx":"640","canGwId":"16","palkoPos":"1"}]}]},{"sections":[{"name":"PUG0","gridColumns":3,"modules":[{"webUi":"1461","tx":"0x5B5","rx":"635","canGwId":"5","palkoPos":"6"},{"webUi":"1460","tx":"0x5B4","rx":"634","canGwId":"4","palkoPos":"5"},{"webUi":"1459","tx":"0x5B3","rx":"633","canGwId":"3","palkoPos":"4"},{"webUi":"1458","tx":"0x5B2","rx":"632","canGwId":"2","palkoPos":"3"},{"webUi":"1457","tx":"0x5B1","rx":"631","canGwId":"1","palkoPos":"2"},{"webUi":"1456","tx":"0x5B0","rx":"630","canGwId":"0","palkoPos":"1"},{"webUi":"1464","tx":"0x5B8"},{"webUi":"1463","tx":"0x5B7"},{"webUi":"1462","tx":"0x5B6"}]}]}]},{"id":"ufc150-75-75","label":"UFC 150 - Delta power modules 75/75 kW (Power distribution 6/6)","series":"UFC150","variant":"75/75","panels":[{"sections":[{"name":"PUG1","gridColumns":3,"modules":[{"webUi":"1477","tx":"0x5C5","rx":"645","canGwId":"21","palkoPos":"6"},{"webUi":"1476","tx":"0x5C4","rx":"644","canGwId":"20","palkoPos":"5"},{"webUi":"1475","tx":"0x5C3","rx":"643","canGwId":"19","palkoPos":"4"},{"webUi":"1474","tx":"0x5C2","rx":"642","canGwId":"18","palkoPos":"3"},{"webUi":"1473","tx":"0x5C1","rx":"641","canGwId":"17","palkoPos":"2"},{"webUi":"1472","tx":"0x5C0","rx":"640","canGwId":"16","palkoPos":"1"}]}]},{"sections":[{"name":"PUG0","gridColumns":3,"modules":[{"webUi":"1461","tx":"0x5B5","rx":"635","canGwId":"5","palkoPos":"6"},{"webUi":"1460","tx":"0x5B4","rx":"634","canGwId":"4","palkoPos":"5"},{"webUi":"1459","tx":"0x5B3","rx":"633","canGwId":"3","palkoPos":"4"},{"webUi":"1458","tx":"0x5B2","rx":"632","canGwId":"2","palkoPos":"3"},{"webUi":"1457","tx":"0x5B1","rx":"631","canGwId":"1","palkoPos":"2"},{"webUi":"1456","tx":"0x5B0","rx":"630","canGwId":"0","palkoPos":"1"}]}]}]},{"id":"ufc150-100-50","label":"UFC 150 - Delta power modules 100/50 kW (Power distribution 8/4)","series":"UFC150","variant":"100/50","panels":[{"sections":[{"name":"PUG1","gridColumns":2,"modules":[{"webUi":"1476","tx":"0x5C4","rx":"644","canGwId":"20","palkoPos":"5"},{"webUi":"1475","tx":"0x5C3","rx":"643","canGwId":"19","palkoPos":"4"},{"webUi":"1473","tx":"0x5C1","rx":"641","canGwId":"17","palkoPos":"2"},{"webUi":"1472","tx":"0x5C0","rx":"640","canGwId":"16","palkoPos":"1"}]},{"name":"PUG0","gridColumns":1,"modules":[{"webUi":"1463","tx":"0x5B7","rx":"637","canGwId":"7","palkoPos":"8"},{"webUi":"1462","tx":"0x5B6","rx":"636","canGwId":"6","palkoPos":"7"}]}]},{"sections":[{"name":"PUG0","gridColumns":3,"modules":[{"webUi":"1461","tx":"0x5B5","rx":"635","canGwId":"5","palkoPos":"6"},{"webUi":"1460","tx":"0x5B4","rx":"634","canGwId":"4","palkoPos":"5"},{"webUi":"1459","tx":"0x5B3","rx":"633","canGwId":"3","palkoPos":"4"},{"webUi":"1458","tx":"0x5B2","rx":"632","canGwId":"2","palkoPos":"3"},{"webUi":"1457","tx":"0x5B1","rx":"631","canGwId":"1","palkoPos":"2"},{"webUi":"1456","tx":"0x5B0","rx":"630","canGwId":"0","palkoPos":"1"}]}]}]},{"id":"ufc200","label":"UFC 200 - Delta power modules 100/100 kW (Power distribution 8/8)","series":"UFC200","panels":[{"sections":[{"name":"PUG1","gridColumns":2,"modules":[{"webUi":"1473","tx":"0x5C1","rx":"0x641","canGwId":"17","palkoPos":"2"},{"webUi":"1472","tx":"0x5C0","rx":"0x640","canGwId":"16","palkoPos":"1"},{"webUi":"1478","tx":"0x5C6","rx":"0x646","canGwId":"19","palkoPos":"4"},{"webUi":"1474","tx":"0x5C2","rx":"0x642","canGwId":"18","palkoPos":"3"}]},{"name":"PUG0","gridColumns":2,"modules":[{"webUi":"1457","tx":"0x5B1","rx":"0x631","canGwId":"1","palkoPos":"2"},{"webUi":"1456","tx":"0x5B0","rx":"0x630","canGwId":"0","palkoPos":"1"},{"webUi":"1465","tx":"0x5B9","rx":"0x639","canGwId":"3","palkoPos":"4"},{"webUi":"1458","tx":"0x5B2","rx":"0x632","canGwId":"2","palkoPos":"3"}]}]},{"sections":[{"name":"PUG1","gridColumns":2,"modules":[{"webUi":"1476","tx":"0x5C4","rx":"0x644","canGwId":"21","palkoPos":"6"},{"webUi":"1475","tx":"0x5C3","rx":"0x643","canGwId":"20","palkoPos":"5"},{"webUi":"1481","tx":"0x5C9","rx":"0x649","canGwId":"23","palkoPos":"8"},{"webUi":"1477","tx":"0x5C5","rx":"0x645","canGwId":"22","palkoPos":"7"}]},{"name":"PUG0","gridColumns":2,"modules":[{"webUi":"1460","tx":"0x5B4","rx":"0x634","canGwId":"5","palkoPos":"6"},{"webUi":"1459","tx":"0x5B3","rx":"0x633","canGwId":"4","palkoPos":"5"},{"webUi":"1468","tx":"0x5BC","rx":"0x63C","canGwId":"7","palkoPos":"8"},{"webUi":"1461","tx":"0x5B5","rx":"0x635","canGwId":"6","palkoPos":"7"}]}]}]},{"id":"ufc500","label":"UFC500","series":"UFC500","panels":[{"sections":[{"name":"PUG0","gridColumns":2,"modules":[{"palkoPos":"1"},{"palkoPos":"7"},{"palkoPos":"2"},{"palkoPos":"8"},{"palkoPos":"3"},{"palkoPos":"9"},{"palkoPos":"4"},{"palkoPos":"10"},{"palkoPos":"5"},{"palkoPos":"11"}]}]},{"sections":[{"name":"PUG1","gridColumns":2,"modules":[{"palkoPos":"31"},{"palkoPos":"37"},{"palkoPos":"32"},{"palkoPos":"38"},{"palkoPos":"33"},{"palkoPos":"39"},{"palkoPos":"34"},{"palkoPos":"40"},{"palkoPos":"35"},{"palkoPos":"41"}]}]}]}]`

load :: proc(allocator: mem.Allocator) -> ([]Module_Mapping, bool) {
	rows: []Module_Mapping
	snapshot := POWER_MODULES_JSON
	error := json.unmarshal(transmute([]u8)snapshot, &rows, allocator = allocator)
	if error != nil {return nil, false}
	return rows, true
}

@(private = "file")
pad :: proc(builder: ^strings.Builder, text: string, width: int) {
	strings.write_string(builder, text)
	for _ in len(text)..<width {strings.write_byte(builder, ' ')}
}

text :: proc(mappings: []Module_Mapping, series, variant: string, allocator: mem.Allocator) -> string {
	if len(mappings) == 0 {return "Power module mappings unavailable."}
	for mapping in mappings {
		if !strings.equal_fold(strings.trim_space(series), mapping.series) || strings.trim_space(variant) != mapping.variant {continue}
		builder := strings.builder_make(allocator)
		strings.write_string(&builder, mapping.label)
		labels := DESCRIPTOR_LABELS
		for panel in mapping.panels {
			strings.write_string(&builder, "\n")
			rows := 0
			for section in panel.sections {
				if section.gridColumns > 0 {
					rows = max(rows, (len(section.modules) + section.gridColumns - 1) / section.gridColumns)
					pad(&builder, section.name, section.gridColumns * 22)
				}
			}
			strings.write_string(&builder, "\n")
			for row in 0..<rows {
				for field in 0..<5 {
					has_value := false
					for section in panel.sections {
						for col in 0..<section.gridColumns {
							index := row * section.gridColumns + col
							if index < len(section.modules) {
								value := descriptor_values(section.modules[index])[field]
								has_value = has_value || value != ""
							}
						}
					}
					if !has_value {continue}
					for section in panel.sections {
						for col in 0..<section.gridColumns {
							index := row * section.gridColumns + col
							value := ""
							if index < len(section.modules) {
								raw := descriptor_values(section.modules[index])[field]
								if raw != "" {value = fmt.tprintf("%s: %s", labels[field], raw)}
							}
							pad(&builder, value, 22)
						}
					}
					strings.write_string(&builder, "\n")
				}
			}
		}
		return strings.to_string(builder)
	}
	return fmt.aprintf("Unknown power module mapping: %s %s", series, variant, allocator = allocator)
}

// Board and wiring mapping used by the guided configuration workspace. Each row is a physical
// connector, the Klipper option that selects it, and the component on the other side.
Board_Pin :: struct {
	socket, alias, mcu_pin, component, detail: string,
}
Board_Mapping :: struct {
	id, label, serial, note: string,
	pins:                    []Board_Pin,
}

BOARD_MAPPING_COUNT :: 2

OCTOPUS_PINS := [?]Board_Pin{
	{"MOTOR 0", "x_step/dir/enable", "PF13 / PF12 / PF14", "Stepper X (CoreXY B)", "TMC2209 UART PC4"},
	{"MOTOR 1", "y_step/dir/enable", "PG0 / PG1 / PF15", "Stepper Y (CoreXY A)", "TMC2209 UART PD11"},
	{"MOTOR 4", "e_step/dir/enable", "PF9 / PF10 / PG2", "Extruder (Toolhead)", "TMC2209 UART PF2"},
	{"MOTOR 5", "z0_step/dir/enable", "PC13 / PF0 / PF1", "Stepper Z0 (Front-Left)", "TMC2209 UART PE4"},
	{"MOTOR 6", "z1_step/dir/enable", "PE2 / PE3 / PD4", "Stepper Z1 (Rear-Center)", "TMC2209 UART PE1"},
	{"MOTOR 7", "z2_step/dir/enable", "PE6 / PA14 / PE0", "Stepper Z2 (Front-Right)", "TMC2209 UART PD3"},
	{"HE0", "e_heater_pin", "PA2", "Hotend Cartridge", "24V MOSFET PWM"},
	{"BED_OUT", "heater_bed_heating_pin", "PA1", "AC Bed SSR Input", "Zero-cross SSR drive"},
	{"T0", "e_sensor_pin", "PF4", "Hotend Sensor (PT1000)", "4.7k pullup ADC"},
	{"TB", "heater_bed_sensor_pin", "PF3", "Bed Thermistor (100K)", "NTC 3950 ADC"},
	{"FAN0", "fan_part_cooling_pin", "PA8", "Part Cooling Blower", "PWM 2-wire fan"},
	{"FAN1", "fan_toolhead_cooling_pin", "PE5", "Hotend Heatsink Fan", "Auto on > 50 C"},
	{"FAN2", "fan_controller_board_pin", "PD12", "Electronics Bay Fan", "Active with steppers"},
	{"BLTOUCH", "bltouch_control/sensor", "PB6 / ^PB7", "Z-Probe Servo + Trigger", "5V servo + pullup"},
	{"SPI3", "adxl345_cs_pin", "PB12 / PB13..15", "Toolhead ADXL345", "Input shaper SPI"},
}

EBB42_PINS := [?]Board_Pin{
	{"HE", "heater_pin", "onboard", "Hotend heater", "EBB42 24V MOSFET, CAN toolboard"},
	{"TH", "sensor_pin", "onboard", "Hotend thermistor", "EBB42 NTC input"},
	{"FAN0", "fan pin", "onboard", "Part cooling blower", "EBB42 24V PWM output"},
	{"ADXL345", "cs_pin", "onboard", "Toolhead accelerometer", "Onboard SPI, input shaper"},
	{"CAN", "canbus_uuid", "onboard", "Toolboard link to main MCU", "RJ11/USB-C CAN transceiver"},
}

board_at :: proc(index: int) -> (Board_Mapping, bool) {
	switch index {
	case 0:
		return {id = "octopus-11", label = "BTT Octopus v1.1", serial = "/dev/RatOS/btt-octopus-11", note = "8 TMC2209 drivers, main MCU", pins = OCTOPUS_PINS[:]}, true
	case 1:
		return {id = "ebb42", label = "BTT EBB42 CAN toolboard", serial = "canbus_uuid (toolboard)", note = "Toolhead board on the EVA 3 carriage", pins = EBB42_PINS[:]}, true
	}
	return {}, false
}

board_find :: proc(id: string) -> (Board_Mapping, bool) {
	for index in 0..<BOARD_MAPPING_COUNT {
		if board, ok := board_at(index); ok && board.id == id {return board, true}
	}
	return {}, false
}
