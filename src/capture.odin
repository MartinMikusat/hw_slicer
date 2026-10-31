package main

import "core:os"

bmp_write :: proc(
	path: string,
	pixels: []u8,
	width, height: uint,
) -> bool {
	if width == 0 || height == 0 {return false}
	stride := (int(width)*3+3) & ~int(3)
	byte_count := 54+int(height)*stride
	if len(pixels) < int(width*height*4) {return false}
	bytes := make([]u8, byte_count)
	defer delete(bytes)
	bytes[0] = 'B'
	bytes[1] = 'M'
	put_u32_le(bytes, 2, u32(byte_count))
	put_u32_le(bytes, 10, 54)
	put_u32_le(bytes, 14, 40)
	put_i32_le(bytes, 18, i32(width))
	put_i32_le(bytes, 22, i32(height))
	put_u16_le(bytes, 26, 1)
	put_u16_le(bytes, 28, 24)
	put_u32_le(bytes, 34, u32(int(height)*stride))
	for row in 0..<int(height) {
		source := row*int(width)*4
		target := 54+(int(height)-1-row)*stride
		for column in 0..<int(width) {
			bytes[target+column*3+0] = pixels[source+column*4+0]
			bytes[target+column*3+1] = pixels[source+column*4+1]
			bytes[target+column*3+2] = pixels[source+column*4+2]
		}
	}
	return os.write_entire_file_from_bytes(path, bytes) == nil
}

put_u16_le :: proc(bytes: []u8, offset: int, value: u16) {
	bytes[offset+0] = u8(value)
	bytes[offset+1] = u8(value>>8)
}

put_u32_le :: proc(bytes: []u8, offset: int, value: u32) {
	bytes[offset+0] = u8(value)
	bytes[offset+1] = u8(value>>8)
	bytes[offset+2] = u8(value>>16)
	bytes[offset+3] = u8(value>>24)
}

put_i32_le :: proc(bytes: []u8, offset: int, value: i32) {
	put_u32_le(bytes, offset, u32(value))
}
