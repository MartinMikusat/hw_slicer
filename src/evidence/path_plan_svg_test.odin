package evidence

import "core:os"
import "core:testing"

import features "../features"

@(test)
path_plan_svg_layer_matches_golden_and_enforces_limits_test :: proc(
	t: ^testing.T,
) {
	perimeter_hash, infill_hash, result := path_plan_artifact_test_fixture()
	defer features.path_plan_result_destroy(&result)
	bytes, encode_error := path_plan_artifact_encode(
		perimeter_hash,
		infill_hash,
		result,
	)
	defer delete(bytes)
	testing.expect_value(t, encode_error, Path_Plan_Artifact_Error.None)
	artifact, decode_error := path_plan_artifact_decode(bytes)
	defer path_plan_artifact_destroy(&artifact)
	testing.expect_value(t, decode_error, Path_Plan_Artifact_Error.None)

	svg, render_error := path_plan_svg_render_layer(artifact, 0)
	defer delete(svg)
	testing.expect_value(t, render_error, Path_Plan_SVG_Error.None)
	expected, read_ok := os.read_entire_file(
		"testdata/evidence/path-plan-layer-v1.svg",
		context.temp_allocator,
	)
	testing.expect(t, read_ok)
	testing.expect_value(t, string(svg), string(expected))

	_, layer_error := path_plan_svg_render_layer(artifact, 1)
	testing.expect_value(
		t,
		layer_error,
		Path_Plan_SVG_Error.Layer_Out_Of_Range,
	)
	limits := DEFAULT_PATH_PLAN_SVG_LIMITS
	limits.max_moves = 0
	_, move_limit_error := path_plan_svg_render_layer(artifact, 0, limits)
	testing.expect_value(
		t,
		move_limit_error,
		Path_Plan_SVG_Error.Move_Limit,
	)
	limits = DEFAULT_PATH_PLAN_SVG_LIMITS
	limits.max_bytes = 1
	_, byte_limit_error := path_plan_svg_render_layer(artifact, 0, limits)
	testing.expect_value(
		t,
		byte_limit_error,
		Path_Plan_SVG_Error.Byte_Limit,
	)
	artifact.result_hash[0] = artifact.result_hash[0] ~ 1
	_, artifact_error := path_plan_svg_render_layer(artifact, 0)
	testing.expect_value(
		t,
		artifact_error,
		Path_Plan_SVG_Error.Invalid_Artifact,
	)

	empty_result := features.Path_Plan_Result{
		topology_policy = .Strict_Printable,
		layers = make([]features.Planned_Layer, 1),
	}
	defer features.path_plan_result_destroy(&empty_result)
	empty_bytes, empty_encode_error :=
		path_plan_artifact_encode({}, {}, empty_result)
	defer delete(empty_bytes)
	testing.expect_value(
		t,
		empty_encode_error,
		Path_Plan_Artifact_Error.None,
	)
	empty_artifact, empty_decode_error :=
		path_plan_artifact_decode(empty_bytes)
	defer path_plan_artifact_destroy(&empty_artifact)
	testing.expect_value(
		t,
		empty_decode_error,
		Path_Plan_Artifact_Error.None,
	)
	_, empty_error := path_plan_svg_render_layer(empty_artifact, 0)
	testing.expect_value(
		t,
		empty_error,
		Path_Plan_SVG_Error.Empty_Layer,
	)
}
