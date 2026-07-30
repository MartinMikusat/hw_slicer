package formats

import "core:testing"

Format_Mutation_Target :: enum u8 {
	Binary_STL,
	ASCII_STL,
	OBJ,
	Three_MF,
}

@(test)
bounded_format_decoders_survive_deterministic_truncation_and_byte_mutations_test :: proc(
	t: ^testing.T,
) {
	binary := binary_stl_test_triangle()
	ascii := transmute([]u8)ASCII_STL_TEST_TRIANGLE
	obj := transmute([]u8)OBJ_TEST_TRIANGLE
	three_mf := three_mf_test_package(model = THREE_MF_TEST_SCENE_MODEL)
	defer delete(three_mf)
	seeds := [?][]u8{binary[:], ascii, obj, three_mf[:]}
	targets := [?]Format_Mutation_Target{
		.Binary_STL,
		.ASCII_STL,
		.OBJ,
		.Three_MF,
	}
	total_attempts := 0
	total_rejections := 0
	for seed, seed_index in seeds {
		attempts, rejections := format_mutation_corpus_run(
			seed,
			targets[seed_index],
		)
		total_attempts += attempts
		total_rejections += rejections
	}
	testing.expect(t, total_attempts >= 1_000)
	testing.expect(t, total_rejections > 0)
}

format_mutation_corpus_run :: proc(
	seed: []u8,
	target: Format_Mutation_Target,
) -> (attempts, rejections: int) {
	if !format_mutation_decode(seed, target) {
		return 0, 0
	}
	for end in 0..<len(seed) {
		if !format_mutation_decode(seed[:end], target) {
			rejections += 1
		}
		attempts += 1
	}
	mutated := make([]u8, len(seed))
	defer delete(mutated)
	copy(mutated, seed)
	for offset in 0..<len(mutated) {
		original := mutated[offset]
		mutated[offset] = original~0x5a
		if !format_mutation_decode(mutated, target) {
			rejections += 1
		}
		attempts += 1
		mutated[offset] = 0
		if !format_mutation_decode(mutated, target) {
			rejections += 1
		}
		attempts += 1
		mutated[offset] = original
	}
	return
}

format_mutation_decode :: proc(
	bytes: []u8,
	target: Format_Mutation_Target,
) -> bool {
	switch target {
	case .Binary_STL:
		mesh, error := binary_stl_decode(bytes, .Millimetres)
		defer decoded_mesh_destroy(&mesh)
		return error == .None
	case .ASCII_STL:
		mesh, error := ascii_stl_decode(bytes, .Millimetres)
		defer decoded_mesh_destroy(&mesh)
		return error == .None
	case .OBJ:
		mesh, error := obj_decode(bytes, .Millimetres)
		defer obj_decoded_mesh_destroy(&mesh)
		return error == .None
	case .Three_MF:
		package_result, package_error := three_mf_package_open(bytes)
		defer three_mf_package_destroy(&package_result)
		if package_error != .None {return false}
		scene, model_error := three_mf_model_decode(package_result)
		defer three_mf_scene_destroy(&scene)
		return model_error == .None
	}
	return false
}
