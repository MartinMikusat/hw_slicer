package main

import "core:fmt"
import "core:slice"
import "core:strings"

import mr "./moonraker"

// Caches the selected Moonraker file's image thumbnail outside the list-owned buffers, so the
// interface can show its size and upload it as a texture. Fetching stays in the Moonraker client:
// the poll asks for metadata, then for the selected image thumbnail, and copies the bytes once the
// client reports the read ready.

PRINTER_THUMBNAIL_DIMENSION_MAX :: 1024

Printer_Thumbnail_Status :: enum u8 { None, Loading, Ready, Failed }

Printer_Thumbnail_State :: struct {
	path:   string,
	data:   []byte,
	width:  int,
	height: int,
	bytes:  int,
	serial: u64,
	status: Printer_Thumbnail_Status,
}

// One printer session per process, and Printer_State has no thumbnail field to attach to.
printer_thumbnail: Printer_Thumbnail_State

printer_thumbnail_destroy :: proc(t: ^Printer_Thumbnail_State) {
	delete(t.path)
	delete(t.data)
	t^ = {}
}

// Keeps the cache in sync with the selected file; returns true when the cache changed.
printer_thumbnail_poll :: proc(p: ^Printer_State, selected_index: int) -> bool {
	c := &p.client
	t := &printer_thumbnail
	if selected_index < 0 || selected_index >= len(c.state.files) ||
	   c.native == nil || c.state.connection != .Connected {
		if t.status == .None && len(t.path) == 0 {return false}
		printer_thumbnail_destroy(t)
		return true
	}
	file := &c.state.files[selected_index]
	if t.path != file.path {
		printer_thumbnail_destroy(t)
		t.path = strings.clone(file.path)
		t.status = .Loading
		return true
	}
	thumb := &file.thumbnails[.Image]
	if thumb.status == .Ready {
		if t.serial == thumb.serial && t.status == .Ready {return false}
		width, height, size, ok := printer_thumbnail_png_size(thumb.data)
		delete(t.data)
		t.data, t.width, t.height, t.bytes, t.serial = nil, 0, 0, size, thumb.serial
		if ok {
			t.data = slice.clone(thumb.data)
			t.width, t.height = width, height
			t.status = .Ready
		} else {
			t.status = .Failed
		}
		return true
	}
	if thumb.status == .Failed {
		if t.status == .Loading || t.status == .None {
			t.status = .Failed
			return true
		}
		return false
	}
	if t.status == .Ready {return false}
	if file.metadata_status == .Failed {
		if t.status == .Failed {return false}
		t.status = .Failed
		return true
	}
	if file.metadata_status == .Ready {
		if file.metadata.thumbnails[.Image] == "" {
			if t.status == .None {return false}
			t.status = .None
			return true
		}
		if c.thumbnail_fetch.id == 0 && mr.thumbnail_wanted(file, .Image) &&
		   mr.thumbnail_begin(c, selected_index, .Image) {
			t.status = .Loading
			return true
		}
		return false
	}
	if file.metadata_status == .None && mr.metadata(c, file.path) {
		t.status = .Loading
		return true
	}
	return false
}

// Reads the PNG signature and IHDR header: dimensions and encoded byte size.
printer_thumbnail_png_size :: proc(data: []byte) -> (width, height, size: int, ok: bool) {
	size = len(data)
	if len(data) < 24 {return}
	signature := [8]byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}
	for b, i in signature do if data[i] != b {return}
	if data[12] != 'I' || data[13] != 'H' || data[14] != 'D' || data[15] != 'R' {return}
	w := int(data[16])<<24 | int(data[17])<<16 | int(data[18])<<8 | int(data[19])
	h := int(data[20])<<24 | int(data[21])<<16 | int(data[22])<<8 | int(data[23])
	if w < 1 || h < 1 || w > PRINTER_THUMBNAIL_DIMENSION_MAX || h > PRINTER_THUMBNAIL_DIMENSION_MAX {
		return
	}
	return w, h, size, true
}

// Status or dimensions for the interface; valid until the next call.
printer_thumbnail_label :: proc(t: ^Printer_Thumbnail_State) -> string {
	switch t.status {
	case .Ready:   return fmt.tprintf("%d×%d PNG · %.1f KB", t.width, t.height, f64(t.bytes)/1024)
	case .Loading: return "loading thumbnail"
	case .Failed:  return "thumbnail unavailable"
	case .None:    return "no thumbnail"
	}
	return ""
}
