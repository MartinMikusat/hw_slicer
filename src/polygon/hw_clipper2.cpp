#include "hw_clipper2.h"

#include "clipper2/clipper.engine.h"
#include "clipper2/clipper.offset.h"

#include <cmath>
#include <cstddef>
#include <limits>
#include <new>
#include <utility>

using Clipper2Lib::ClipType;
using Clipper2Lib::Clipper64;
using Clipper2Lib::ClipperOffset;
using Clipper2Lib::EndType;
using Clipper2Lib::FillRule;
using Clipper2Lib::JoinType;
using Clipper2Lib::Path64;
using Clipper2Lib::Paths64;
using Clipper2Lib::Point64;

static_assert(sizeof(HW_Clipper2_Point) == 16);
static_assert(offsetof(HW_Clipper2_Point, x) == 0);
static_assert(offsetof(HW_Clipper2_Point, y) == 8);
static_assert(sizeof(HW_Clipper2_Path) == 16);
static_assert(offsetof(HW_Clipper2_Path, offset) == 0);
static_assert(offsetof(HW_Clipper2_Path, count) == 8);
static_assert(sizeof(HW_Clipper2_Paths_View) == 32);
static_assert(sizeof(HW_Clipper2_Paths_Result) == 32);

namespace {

bool paths_view_valid(const HW_Clipper2_Paths_View &view) {
	if ((view.point_count > 0 && view.points == nullptr) ||
	    (view.path_count > 0 && view.paths == nullptr) ||
	    view.point_count > std::numeric_limits<std::size_t>::max() ||
	    view.path_count > std::numeric_limits<std::size_t>::max()) {
		return false;
	}
	uint64_t expected_offset = 0;
	for (uint64_t index = 0; index < view.path_count; ++index) {
		const HW_Clipper2_Path &path = view.paths[index];
		if (path.offset != expected_offset || path.count < 3 ||
		    expected_offset > view.point_count ||
		    path.count > view.point_count - expected_offset) {
			return false;
		}
		expected_offset += path.count;
	}
	return expected_offset == view.point_count;
}

Paths64 paths_convert(const HW_Clipper2_Paths_View &view) {
	Paths64 output;
	output.reserve(static_cast<std::size_t>(view.path_count));
	for (uint64_t path_index = 0; path_index < view.path_count; ++path_index) {
		const HW_Clipper2_Path &source_path = view.paths[path_index];
		Path64 path;
		path.reserve(static_cast<std::size_t>(source_path.count));
		for (uint64_t point_index = 0;
		     point_index < source_path.count;
		     ++point_index) {
			const HW_Clipper2_Point &point =
				view.points[source_path.offset + point_index];
			path.emplace_back(point.x, point.y);
		}
		output.emplace_back(std::move(path));
	}
	return output;
}

int32_t paths_export(
	const Paths64 &input,
	uint64_t maximum_output_points,
	uint64_t maximum_output_paths,
	HW_Clipper2_Paths_Result *result
) {
	if (input.size() > maximum_output_paths) {
		return HW_CLIPPER2_OUTPUT_LIMIT;
	}
	uint64_t point_count = 0;
	for (const Path64 &path : input) {
		if (point_count > maximum_output_points ||
		    path.size() > maximum_output_points - point_count) {
			return HW_CLIPPER2_OUTPUT_LIMIT;
		}
		point_count += static_cast<uint64_t>(path.size());
	}
	if (input.empty()) {
		return HW_CLIPPER2_NONE;
	}
	auto *points = new (std::nothrow) HW_Clipper2_Point[point_count];
	auto *paths = new (std::nothrow) HW_Clipper2_Path[input.size()];
	if (points == nullptr || paths == nullptr) {
		delete[] points;
		delete[] paths;
		return HW_CLIPPER2_ALLOCATION_FAILED;
	}
	uint64_t point_write = 0;
	for (std::size_t path_index = 0;
	     path_index < input.size();
	     ++path_index) {
		const Path64 &path = input[path_index];
		paths[path_index] = {
			point_write,
			static_cast<uint64_t>(path.size()),
		};
		for (const Point64 &point : path) {
			points[point_write] = {point.x, point.y};
			++point_write;
		}
	}
	result->points = points;
	result->point_count = point_count;
	result->paths = paths;
	result->path_count = static_cast<uint64_t>(input.size());
	return HW_CLIPPER2_NONE;
}

}  // namespace

extern "C" const char *hw_clipper2_version(void) {
	return CLIPPER2_VERSION;
}

extern "C" int32_t hw_clipper2_boolean(
	uint8_t operation,
	uint8_t fill_rule,
	HW_Clipper2_Paths_View subjects,
	HW_Clipper2_Paths_View clips,
	uint64_t maximum_output_points,
	uint64_t maximum_output_paths,
	HW_Clipper2_Paths_Result *result
) {
	if (result == nullptr || operation < 1 || operation > 4 ||
	    fill_rule > 3 || !paths_view_valid(subjects) ||
	    !paths_view_valid(clips)) {
		return HW_CLIPPER2_INVALID_INPUT;
	}
	*result = {};
	try {
		Clipper64 clipper;
		clipper.AddSubject(paths_convert(subjects));
		clipper.AddClip(paths_convert(clips));
		Paths64 solution;
		if (!clipper.Execute(
			    static_cast<ClipType>(operation),
			    static_cast<FillRule>(fill_rule),
			    solution)) {
			return HW_CLIPPER2_EXECUTION_FAILED;
		}
		return paths_export(
			solution,
			maximum_output_points,
			maximum_output_paths,
			result);
	} catch (const std::bad_alloc &) {
		return HW_CLIPPER2_ALLOCATION_FAILED;
	} catch (...) {
		return HW_CLIPPER2_EXECUTION_FAILED;
	}
}

extern "C" int32_t hw_clipper2_offset(
	HW_Clipper2_Paths_View input,
	double delta,
	uint8_t join_type,
	double miter_limit,
	double arc_tolerance,
	uint64_t maximum_output_points,
	uint64_t maximum_output_paths,
	HW_Clipper2_Paths_Result *result
) {
	if (result == nullptr || join_type > 3 || !paths_view_valid(input) ||
	    !std::isfinite(delta) || !std::isfinite(miter_limit) ||
	    !std::isfinite(arc_tolerance) || miter_limit < 1 ||
	    arc_tolerance < 0) {
		return HW_CLIPPER2_INVALID_INPUT;
	}
	*result = {};
	try {
		ClipperOffset offsetter(miter_limit, arc_tolerance);
		offsetter.AddPaths(
			paths_convert(input),
			static_cast<JoinType>(join_type),
			EndType::Polygon);
		Paths64 solution;
		offsetter.Execute(delta, solution);
		if (offsetter.ErrorCode() != 0) {
			return HW_CLIPPER2_EXECUTION_FAILED;
		}
		return paths_export(
			solution,
			maximum_output_points,
			maximum_output_paths,
			result);
	} catch (const std::bad_alloc &) {
		return HW_CLIPPER2_ALLOCATION_FAILED;
	} catch (...) {
		return HW_CLIPPER2_EXECUTION_FAILED;
	}
}

extern "C" void hw_clipper2_paths_dispose(
	HW_Clipper2_Paths_Result *result
) {
	if (result == nullptr) {
		return;
	}
	delete[] result->points;
	delete[] result->paths;
	*result = {};
}
