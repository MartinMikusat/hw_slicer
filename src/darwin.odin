package main

import "core:os"
import "core:strings"

Id :: rawptr
Sel :: rawptr

NS_Point :: struct {x, y: f64}
NS_Size :: struct {width, height: f64}
NS_Rect :: struct {origin: NS_Point, size: NS_Size}

MTL_Clear_Color :: struct {red, green, blue, alpha: f64}
MTL_Origin :: struct {x, y, z: uint}
MTL_Size :: struct {width, height, depth: uint}
MTL_Region :: struct {origin: MTL_Origin, size: MTL_Size}
MTL_Viewport :: struct {
	origin_x, origin_y, width, height, near_z, far_z: f64,
}

foreign import objc "system:objc"
foreign objc {
	objc_getClass :: proc "c" (name: cstring) -> Id ---
	sel_registerName :: proc "c" (name: cstring) -> Sel ---
}

objc_send_address: rawptr

objc_initialize :: proc() -> bool {
	if objc_send_address != nil {return true}
	handle := os.dlopen("/usr/lib/libobjc.A.dylib", os.RTLD_NOW)
	if handle == nil {return false}
	objc_send_address = os.dlsym(handle, "objc_msgSend")
	return objc_send_address != nil
}

msg_id :: proc(receiver: Id, selector: Sel) -> Id {
	p := transmute(proc "c" (Id, Sel) -> Id)objc_send_address
	return p(receiver, selector)
}

msg_cstring :: proc(receiver: Id, selector: Sel) -> cstring {
	p := transmute(proc "c" (Id, Sel) -> cstring)objc_send_address
	return p(receiver, selector)
}

ns_error_text :: proc(error: Id) -> string {
	if error == nil {return "no NSError payload"}
	description := msg_id(error, sel_registerName("localizedDescription"))
	if description == nil {return "NSError has no description"}
	value := msg_cstring(description, sel_registerName("UTF8String"))
	if value == nil {return "NSError description is not UTF-8"}
	return string(value)
}

msg_void :: proc(receiver: Id, selector: Sel) {
	p := transmute(proc "c" (Id, Sel))objc_send_address
	p(receiver, selector)
}

msg_id_id :: proc(receiver: Id, selector: Sel, value: Id) -> Id {
	p := transmute(proc "c" (Id, Sel, Id) -> Id)objc_send_address
	return p(receiver, selector, value)
}

msg_void_id :: proc(receiver: Id, selector: Sel, value: Id) {
	p := transmute(proc "c" (Id, Sel, Id))objc_send_address
	p(receiver, selector, value)
}

msg_void_bool :: proc(receiver: Id, selector: Sel, value: bool) {
	p := transmute(proc "c" (Id, Sel, bool))objc_send_address
	p(receiver, selector, value)
}

msg_void_u :: proc(receiver: Id, selector: Sel, value: uint) {
	p := transmute(proc "c" (Id, Sel, uint))objc_send_address
	p(receiver, selector, value)
}

msg_void_f64 :: proc(receiver: Id, selector: Sel, value: f64) {
	p := transmute(proc "c" (Id, Sel, f64))objc_send_address
	p(receiver, selector, value)
}

msg_void_clear_color :: proc(
	receiver: Id,
	selector: Sel,
	value: MTL_Clear_Color,
) {
	p := transmute(proc "c" (Id, Sel, MTL_Clear_Color))objc_send_address
	p(receiver, selector, value)
}

msg_id_u :: proc(receiver: Id, selector: Sel, value: uint) -> Id {
	p := transmute(proc "c" (Id, Sel, uint) -> Id)objc_send_address
	return p(receiver, selector, value)
}

msg_id_id_error :: proc(
	receiver: Id,
	selector: Sel,
	value: Id,
	error: ^Id,
) -> Id {
	p := transmute(proc "c" (Id, Sel, Id, ^Id) -> Id)objc_send_address
	return p(receiver, selector, value, error)
}

msg_id_id_id_error :: proc(
	receiver: Id,
	selector: Sel,
	a, b: Id,
	error: ^Id,
) -> Id {
	p := transmute(proc "c" (Id, Sel, Id, Id, ^Id) -> Id)objc_send_address
	return p(receiver, selector, a, b, error)
}

msg_id_u_u_u_bool :: proc(
	receiver: Id,
	selector: Sel,
	a, b, c: uint,
	d: bool,
) -> Id {
	p := transmute(proc "c" (Id, Sel, uint, uint, uint, bool) -> Id)objc_send_address
	return p(receiver, selector, a, b, c, d)
}

msg_id_ptr_u_u :: proc(
	receiver: Id,
	selector: Sel,
	bytes: rawptr,
	length, options: uint,
) -> Id {
	p := transmute(proc "c" (Id, Sel, rawptr, uint, uint) -> Id)objc_send_address
	return p(receiver, selector, bytes, length, options)
}

msg_void_ptr_u_u :: proc(
	receiver: Id,
	selector: Sel,
	bytes: rawptr,
	length, index: uint,
) {
	p := transmute(proc "c" (Id, Sel, rawptr, uint, uint))objc_send_address
	p(receiver, selector, bytes, length, index)
}

msg_void_id_u :: proc(receiver: Id, selector: Sel, value: Id, index: uint) {
	p := transmute(proc "c" (Id, Sel, Id, uint))objc_send_address
	p(receiver, selector, value, index)
}

msg_void_id_u_u :: proc(
	receiver: Id,
	selector: Sel,
	value: Id,
	offset, index: uint,
) {
	p := transmute(proc "c" (Id, Sel, Id, uint, uint))objc_send_address
	p(receiver, selector, value, offset, index)
}

msg_void_u_u_u :: proc(receiver: Id, selector: Sel, a, b, c: uint) {
	p := transmute(proc "c" (Id, Sel, uint, uint, uint))objc_send_address
	p(receiver, selector, a, b, c)
}

msg_void_region :: proc(
	receiver: Id,
	selector: Sel,
	region: MTL_Region,
	level: uint,
	bytes: rawptr,
	bytes_per_row: uint,
) {
	p := transmute(proc "c" (
		Id,
		Sel,
		MTL_Region,
		uint,
		rawptr,
		uint,
	))objc_send_address
	p(receiver, selector, region, level, bytes, bytes_per_row)
}

msg_void_size :: proc(receiver: Id, selector: Sel, value: NS_Size) {
	p := transmute(proc "c" (Id, Sel, NS_Size))objc_send_address
	p(receiver, selector, value)
}

msg_void_viewport :: proc(receiver: Id, selector: Sel, value: MTL_Viewport) {
	p := transmute(proc "c" (Id, Sel, MTL_Viewport))objc_send_address
	p(receiver, selector, value)
}

msg_id_index :: proc(receiver: Id, selector: Sel, index: uint) -> Id {
	p := transmute(proc "c" (Id, Sel, uint) -> Id)objc_send_address
	return p(receiver, selector, index)
}

nsstring :: proc(value: string) -> Id {
	if len(value) == 0 {
		return msg_id(objc_getClass("NSString"), sel_registerName("string"))
	}
	c_value := strings.clone_to_cstring(value, context.temp_allocator)
	p := transmute(proc "c" (Id, Sel, cstring) -> Id)objc_send_address
	return p(
		objc_getClass("NSString"),
		sel_registerName("stringWithUTF8String:"),
		c_value,
	)
}
