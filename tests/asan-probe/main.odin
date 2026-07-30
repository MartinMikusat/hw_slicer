package main

main :: proc() {
	bytes := make([]u8, 32)
	pointer := ([^]u8)(raw_data(bytes))
	delete(bytes)
	pointer[0] = 1
}
