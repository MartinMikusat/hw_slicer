package main

import "base:runtime"
import "core:math"
import "core:strconv"
import "core:strings"

ENVIRONMENT_LEVEL_WIDTH_MIN :: 8

// Image-based lighting input: a Radiance equirectangular map with a mip chain
// for roughness-dependent reflections, and the cosine-convolved diffuse irradiance as nine spherical
// harmonics (already divided by pi, so the shader multiplies it by the albedo). Direction to texel:
// u = atan2(z, x) / 2pi + 0.5, v = acos(y) / pi, with y up and the top row looking up.
Environment :: struct {
	width, height: int,
	levels:        [][]f32, // RGB per texel; level 0 is the full image, each next level halves both sides
	sh:            [9][3]f32,
}

// Decodes a Radiance .hdr file (flat or new-style run-length scanlines) to linear RGB floats.
radiance_decode :: proc(data: []byte, allocator: runtime.Allocator) -> (pixels: []f32, width, height: int, ok: bool) {
	position := 0
	line_next :: proc(data: []byte, position: ^int) -> (line: string, found: bool) {
		start := position^
		for position^ < len(data) {
			if data[position^] == '\n' {
				line = string(data[start:position^])
				position^ += 1
				return line, true
			}
			position^ += 1
		}
		return "", false
	}
	signature, signature_found := line_next(data, &position)
	if !signature_found || !strings.has_prefix(signature, "#?") {return}
	for {
		line, found := line_next(data, &position)
		if !found {return}
		if line == "" {break}
	}
	resolution, resolution_found := line_next(data, &position)
	if !resolution_found {return}
	fields := strings.fields(resolution, context.temp_allocator)
	if len(fields) != 4 || fields[0] != "-Y" || fields[2] != "+X" {return}
	parsed_height, height_ok := strconv.parse_int(fields[1])
	parsed_width, width_ok := strconv.parse_int(fields[3])
	if !height_ok || !width_ok || parsed_width < 8 || parsed_width > 32767 || parsed_height < 1 || parsed_height > 32767 {return}
	width, height = parsed_width, parsed_height

	scanline := make([]byte, width * 4, context.temp_allocator)
	pixels = make([]f32, width * height * 3, allocator)
	for y in 0 ..< height {
		if position + 4 > len(data) {delete(pixels, allocator); return nil, 0, 0, false}
		if data[position] == 2 && data[position + 1] == 2 && data[position + 2] & 0x80 == 0 {
			if int(data[position + 2]) << 8 | int(data[position + 3]) != width {delete(pixels, allocator); return nil, 0, 0, false}
			position += 4
			for channel in 0 ..< 4 {
				x := 0
				for x < width {
					if position >= len(data) {delete(pixels, allocator); return nil, 0, 0, false}
					count := int(data[position])
					position += 1
					if count > 128 {
						count -= 128
						if position >= len(data) || x + count > width {delete(pixels, allocator); return nil, 0, 0, false}
						value := data[position]
						position += 1
						for _ in 0 ..< count {scanline[x * 4 + channel] = value; x += 1}
					} else {
						if count == 0 || position + count > len(data) || x + count > width {delete(pixels, allocator); return nil, 0, 0, false}
						for _ in 0 ..< count {scanline[x * 4 + channel] = data[position]; position += 1; x += 1}
					}
				}
			}
		} else {
			if position + width * 4 > len(data) {delete(pixels, allocator); return nil, 0, 0, false}
			copy(scanline, data[position:position + width * 4])
			position += width * 4
		}
		for x in 0 ..< width {
			exponent := scanline[x * 4 + 3]
			scale: f32 = exponent == 0 ? 0 : math.ldexp(f32(1), int(exponent) - 136)
			for channel in 0 ..< 3 {pixels[(y * width + x) * 3 + channel] = f32(scanline[x * 4 + channel]) * scale}
		}
	}
	return pixels, width, height, true
}

environment_build :: proc(data: []byte, allocator: runtime.Allocator) -> (environment: Environment, ok: bool) {
	pixels, width, height, decoded := radiance_decode(data, allocator)
	if !decoded {return}
	environment.width, environment.height = width, height
	levels := make([dynamic][]f32, 0, 12, allocator)
	append(&levels, pixels)
	level_width, level_height := width, height
	for level_width / 2 >= ENVIRONMENT_LEVEL_WIDTH_MIN && level_height / 2 >= 1 {
		next_width, next_height := level_width / 2, level_height / 2
		next := make([]f32, next_width * next_height * 3, allocator)
		source := levels[len(levels) - 1]
		for y in 0 ..< next_height {
			for x in 0 ..< next_width {
				for channel in 0 ..< 3 {
					sum: f32
					for dy in 0 ..< 2 {
						for dx in 0 ..< 2 {sum += source[((2 * y + dy) * level_width + 2 * x + dx) * 3 + channel]}
					}
					next[(y * next_width + x) * 3 + channel] = sum / 4
				}
			}
		}
		append(&levels, next)
		level_width, level_height = next_width, next_height
	}
	environment.levels = levels[:]
	environment.sh = irradiance_harmonics(pixels, width, height)
	return environment, true
}

// Real spherical harmonics up to order 2 in the order Y00, Y1-1 (y), Y10 (z), Y11 (x), Y2-2 (xy), Y2-1 (yz),
// Y20, Y21 (xz), Y22 (x2 - y2); the shader evaluates the same basis.
sh_basis :: proc(d: [3]f32) -> [9]f32 {
	return {
		0.282095,
		0.488603 * d.y,
		0.488603 * d.z,
		0.488603 * d.x,
		1.092548 * d.x * d.y,
		1.092548 * d.y * d.z,
		0.315392 * (3 * d.z * d.z - 1),
		1.092548 * d.x * d.z,
		0.546274 * (d.x * d.x - d.y * d.y),
	}
}

irradiance_harmonics :: proc(pixels: []f32, width, height: int) -> (sh: [9][3]f32) {
	for y in 0 ..< height {
		theta := (f32(y) + 0.5) / f32(height) * math.PI
		weight := math.sin(theta) * (2 * math.PI / f32(width)) * (math.PI / f32(height))
		for x in 0 ..< width {
			phi := ((f32(x) + 0.5) / f32(width) - 0.5) * 2 * math.PI
			direction := [3]f32{math.sin(theta) * math.cos(phi), math.cos(theta), math.sin(theta) * math.sin(phi)}
			basis := sh_basis(direction)
			for i in 0 ..< 9 {
				for channel in 0 ..< 3 {sh[i][channel] += pixels[(y * width + x) * 3 + channel] * basis[i] * weight}
			}
		}
	}
	// Convolution with the clamped cosine lobe per band, divided by pi: 1, 2/3, 1/4.
	band := [9]f32{1, 2.0 / 3, 2.0 / 3, 2.0 / 3, 0.25, 0.25, 0.25, 0.25, 0.25}
	for i in 0 ..< 9 {
		for channel in 0 ..< 3 {sh[i][channel] *= band[i]}
	}
	return
}

renderer_environment_upload :: proc(renderer: ^Renderer) -> bool {
	environment, ok := environment_build(#load("../resources/studio_small_03_1k.hdr"), context.temp_allocator)
	if !ok {return false}
	descriptor := msg_id_u_u_u_bool(objc_getClass("MTLTextureDescriptor"), sel_registerName("texture2DDescriptorWithPixelFormat:width:height:mipmapped:"), 115, uint(environment.width), uint(environment.height), false)
	msg_void_u(descriptor, sel_registerName("setMipmapLevelCount:"), uint(len(environment.levels)))
	msg_void_u(descriptor, sel_registerName("setUsage:"), 1)
	renderer.environment = msg_id_id(renderer.device, sel_registerName("newTextureWithDescriptor:"), descriptor)
	if renderer.environment == nil {return false}
	width, height := environment.width, environment.height
	for level, index in environment.levels {
		texels := make([][4]f16, width*height, context.temp_allocator)
		for texel in 0..<len(texels) {
			texels[texel] = {f16(min(level[texel*3],65000)), f16(min(level[texel*3+1],65000)), f16(min(level[texel*3+2],65000)), 1}
		}
		msg_void_region(renderer.environment, sel_registerName("replaceRegion:mipmapLevel:withBytes:bytesPerRow:"), {{0,0,0},{uint(width),uint(height),1}}, uint(index), raw_data(texels), uint(width)*size_of([4]f16))
		width, height = width/2, height/2
	}
	for coefficient, index in environment.sh {renderer.harmonics[index] = {coefficient.x,coefficient.y,coefficient.z,0}}
	return true
}
