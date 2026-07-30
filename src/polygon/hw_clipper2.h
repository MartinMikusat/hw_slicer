#ifndef HW_SLICER_CLIPPER2_H
#define HW_SLICER_CLIPPER2_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct HW_Clipper2_Point {
	int64_t x;
	int64_t y;
} HW_Clipper2_Point;

typedef struct HW_Clipper2_Path {
	uint64_t offset;
	uint64_t count;
} HW_Clipper2_Path;

typedef struct HW_Clipper2_Paths_View {
	const HW_Clipper2_Point *points;
	uint64_t point_count;
	const HW_Clipper2_Path *paths;
	uint64_t path_count;
} HW_Clipper2_Paths_View;

typedef struct HW_Clipper2_Paths_Result {
	HW_Clipper2_Point *points;
	uint64_t point_count;
	HW_Clipper2_Path *paths;
	uint64_t path_count;
} HW_Clipper2_Paths_Result;

enum HW_Clipper2_Error {
	HW_CLIPPER2_NONE = 0,
	HW_CLIPPER2_INVALID_INPUT = 1,
	HW_CLIPPER2_INPUT_LIMIT = 2,
	HW_CLIPPER2_OUTPUT_LIMIT = 3,
	HW_CLIPPER2_ALLOCATION_FAILED = 4,
	HW_CLIPPER2_EXECUTION_FAILED = 5,
};

const char *hw_clipper2_version(void);

int32_t hw_clipper2_boolean(
	uint8_t operation,
	uint8_t fill_rule,
	HW_Clipper2_Paths_View subjects,
	HW_Clipper2_Paths_View clips,
	uint64_t maximum_output_points,
	uint64_t maximum_output_paths,
	HW_Clipper2_Paths_Result *result
);

int32_t hw_clipper2_offset(
	HW_Clipper2_Paths_View input,
	double delta,
	uint8_t join_type,
	double miter_limit,
	double arc_tolerance,
	uint64_t maximum_output_points,
	uint64_t maximum_output_paths,
	HW_Clipper2_Paths_Result *result
);

void hw_clipper2_paths_dispose(HW_Clipper2_Paths_Result *result);

#ifdef __cplusplus
}
#endif

#endif
