package formats

import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"

OBJ_CORPUS_POSITIONS: string :
	`v 0 0 0
v 3 0 0
v 3 3 0
v 1.5 1 0
v 0 3 0
`

@(test)
obj_polygon_rotation_winding_and_relative_index_corpus_test :: proc(
	t: ^testing.T,
) {
	faces := [?]string{
		"1 2 3 4 5",
		"2 3 4 5 1",
		"3 4 5 1 2",
		"4 5 1 2 3",
		"5 1 2 3 4",
		"5 4 3 2 1",
		"4 3 2 1 5",
		"3 2 1 5 4",
		"2 1 5 4 3",
		"1 5 4 3 2",
		"-5 -4 -3 -2 -1",
		"-1 -2 -3 -4 -5",
	}
	for face in faces {
		builder: strings.Builder
		strings.builder_init(&builder)
		fmt.sbprintf(&builder, "%sf %s\n", OBJ_CORPUS_POSITIONS, face)
		source := strings.to_string(builder)
		result, error := obj_decode(
			transmute([]u8)source,
			.Millimetres,
		)
		testing.expect_value(t, error, Decode_Error.None)
		testing.expect_value(t, len(result.mesh.triangle_ids), 3)
		area := obj_corpus_triangle_area(result.mesh)
		testing.expect(
			t,
			math.abs(area-6.0) <= 1e-12,
			"triangulated polygon area must equal the source polygon area",
		)
		obj_decoded_mesh_destroy(&result)
		strings.builder_destroy(&builder)
	}
}

obj_corpus_triangle_area :: proc(mesh: Decoded_Mesh) -> f64 {
	area: f64
	for triangle_index in 0..<len(mesh.triangle_ids) {
		a := int(mesh.triangle_a[triangle_index])
		b := int(mesh.triangle_b[triangle_index])
		c := int(mesh.triangle_c[triangle_index])
		signed_area_2 :=
			(mesh.vertex_x[b]-mesh.vertex_x[a])*
			(mesh.vertex_y[c]-mesh.vertex_y[a])-
			(mesh.vertex_y[b]-mesh.vertex_y[a])*
			(mesh.vertex_x[c]-mesh.vertex_x[a])
		area += math.abs(signed_area_2)*0.5
	}
	return area
}
