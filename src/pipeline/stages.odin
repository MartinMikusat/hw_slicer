package pipeline

import "core:mem"

import contracts "../contracts"
import profiles "../profiles"

// Engine stages in execution order. Each stage has one result slot in a Slice_Session and
// depends only on the stages listed in its descriptor.
Stage_Id :: enum u8 {
	Model,
	Layer_Schedule,
	Intersections,
	Topology,
	Regions,
	Surfaces_Skin,
	Perimeters,
	Bridges,
	Solid_Skin,
	Sparse_Infill,
	Gap_Fill,
	Supports,
	Path_Plan,
	Motion,
	Gcode,
}

Stage_Set :: bit_set[Stage_Id]

Stage_State :: enum u8 {
	Not_Run,
	Running,
	Complete,
	Stale,
	Failed,
}

// Workspace groups shown to the operator. Several engine stages can share one group.
Stage_Group :: enum u8 {
	Model_Placement,
	Layer_Schedule,
	Mesh_Intersections,
	Contours_Topology,
	Regions,
	Surfaces_Skin,
	Perimeters,
	Infill,
	Supports_Bridges,
	Path_Plan,
	Motion_Gcode,
}

Stage_Descriptor :: struct {
	name:    string,
	purpose: string,
	inputs:  Stage_Set,
	group:   Stage_Group,
	// Names of the two counts that a stage reports in its slot.
	counts:  [2]string,
}

stage_descriptors := [Stage_Id]Stage_Descriptor {
	.Model = {
		name = "Model",
		counts = {"Triangles", ""},
		purpose = "Repairs the mesh, centres it on the bed and normalizes its units.",
		group = .Model_Placement,
	},
	.Layer_Schedule = {
		name = "Layer schedule",
		counts = {"Layers", ""},
		purpose = "Chooses the Z height of every layer, fixed or adaptive.",
		inputs = {.Model},
		group = .Layer_Schedule,
	},
	.Intersections = {
		name = "Mesh intersections",
		counts = {"Segments", ""},
		purpose = "Intersects the mesh with each layer plane and snaps the segments.",
		inputs = {.Layer_Schedule},
		group = .Mesh_Intersections,
	},
	.Topology = {
		name = "Contours and topology",
		counts = {"Paths", ""},
		purpose = "Joins segments into closed contours and simplifies them.",
		inputs = {.Intersections},
		group = .Contours_Topology,
	},
	.Regions = {
		name = "Regions",
		counts = {"Regions", "Contour repairs"},
		purpose = "Builds nested outer and hole regions per layer and repairs crossing contours.",
		inputs = {.Topology},
		group = .Regions,
	},
	.Surfaces_Skin = {
		name = "Surfaces and skin",
		counts = {"Surface masks", "Skin masks"},
		purpose = "Classifies top and bottom surfaces and propagates the skin depth.",
		inputs = {.Layer_Schedule, .Regions},
		group = .Surfaces_Skin,
	},
	.Perimeters = {
		name = "Perimeters",
		counts = {"Perimeter paths", ""},
		purpose = "Offsets each region into perimeter loops.",
		inputs = {.Regions},
		group = .Perimeters,
	},
	.Bridges = {
		name = "Bridges",
		counts = {"Bridge masks", "Bridge paths"},
		purpose = "Finds unsupported spans and chooses a bridge direction for each.",
		inputs = {.Regions},
		group = .Supports_Bridges,
	},
	.Solid_Skin = {
		name = "Solid skin",
		counts = {"Solid paths", "Ironing paths"},
		purpose = "Resolves overlapping roles and fills skin areas, including ironing.",
		inputs = {.Layer_Schedule, .Regions, .Surfaces_Skin, .Bridges},
		group = .Surfaces_Skin,
	},
	.Sparse_Infill = {
		name = "Sparse infill",
		counts = {"Infill paths", "Line spacing µm"},
		purpose = "Fills the interior outside the solid areas with the infill pattern.",
		inputs = {.Layer_Schedule, .Regions, .Surfaces_Skin, .Solid_Skin},
		group = .Infill,
	},
	.Gap_Fill = {
		name = "Gap fill",
		counts = {"Gap paths", "Gap vertices"},
		purpose = "Fills thin gaps that the perimeters leave uncovered.",
		inputs = {.Regions, .Perimeters},
		group = .Perimeters,
	},
	.Supports = {
		name = "Supports and adhesion",
		counts = {"Support paths", ""},
		purpose = "Generates supports, then the skirt and brim around them.",
		inputs = {.Model, .Layer_Schedule, .Regions},
		group = .Supports_Bridges,
	},
	.Path_Plan = {
		name = "Path plan",
		counts = {"Extrude moves", "Travel moves"},
		purpose = "Merges all print roles into ordered paths with seams and travel moves.",
		inputs = {.Layer_Schedule, .Perimeters, .Bridges, .Solid_Skin, .Sparse_Infill, .Gap_Fill, .Supports},
		group = .Path_Plan,
	},
	.Motion = {
		name = "Motion",
		counts = {"Operations", "Arcs fitted"},
		purpose = "Computes extrusion and speeds, then fits arcs and applies modifiers.",
		inputs = {.Layer_Schedule, .Regions, .Path_Plan},
		group = .Motion_Gcode,
	},
	.Gcode = {
		name = "G-code",
		counts = {"Bytes", "Commands"},
		purpose = "Emits and validates Klipper G-code.",
		inputs = {.Motion},
		group = .Motion_Gcode,
	},
}

stage_group_names := [Stage_Group]string {
	.Model_Placement    = "Model and placement",
	.Layer_Schedule     = "Layer schedule",
	.Mesh_Intersections = "Mesh intersections",
	.Contours_Topology  = "Contours and topology",
	.Regions            = "Regions",
	.Surfaces_Skin      = "Surfaces and skin",
	.Perimeters         = "Perimeters",
	.Infill             = "Infill",
	.Supports_Bridges   = "Supports and bridges",
	.Path_Plan          = "Path plan",
	.Motion_Gcode       = "Motion and G-code",
}

// Stages that make up one workspace group, in execution order.
stage_group_members :: proc(group: Stage_Group) -> Stage_Set {
	set: Stage_Set
	for id in Stage_Id {
		if stage_descriptors[id].group == group {set += {id}}
	}
	return set
}

// The stage and every stage that depends on it, directly or through other stages.
stage_downstream :: proc(id: Stage_Id) -> Stage_Set {
	set := Stage_Set{id}
	for later in Stage_Id {
		if later <= id {continue}
		if stage_descriptors[later].inputs & set != {} {set += {later}}
	}
	return set
}

// The stage and every stage it needs, directly or through other stages.
stage_upstream :: proc(id: Stage_Id) -> Stage_Set {
	set := Stage_Set{id}
	for i := int(id); i >= 0; i -= 1 {
		earlier := Stage_Id(i)
		if earlier in set {set += stage_descriptors[earlier].inputs}
	}
	return set
}

@(private = "file")
hash_pod :: proc(h: ^contracts.Canonical_Hash, value: $T) {
	v := value
	contracts.canonical_hash_append_bytes(h, mem.ptr_to_bytes(&v))
}

@(private = "file")
hash_content :: proc(h: ^contracts.Canonical_Hash, value: contracts.Content_Hash) {
	contracts.canonical_hash_append_content_hash(h, value)
}

// Hash of every setting that the stage reads directly. A setting that reaches a stage through the
// whole process document is covered by the profile stage hashes, which over-approximate; a stage
// never hashes less than it reads. Settings that only change speed, not results, such as the worker
// thread count, are excluded.
stage_settings_hash :: proc(
	id: Stage_Id,
	profile: profiles.Resolved_Profiles,
	options: Slice_Run_Options,
) -> contracts.Content_Hash {
	h: contracts.Canonical_Hash
	contracts.canonical_hash_init(&h, "hw-slicer/stage-settings", 1)
	contracts.canonical_hash_append_u8(&h, u8(id))
	p := profile.process.source
	pr := profile.printer
	stage_hashes := profiles.profile_stage_hashes(profile)
	revisions := profiles.profile_revisions(profile)
	switch id {
	case .Model:
		hash_pod(&h, options.source_units)
		hash_pod(&h, options.mesh_auto_repair)
		hash_pod(&h, options.center_on_bed)
		if options.center_on_bed {
			hash_pod(&h, pr.axis_minimum_x)
			hash_pod(&h, pr.axis_maximum_x)
			hash_pod(&h, pr.axis_minimum_y)
			hash_pod(&h, pr.axis_maximum_y)
		}
	case .Layer_Schedule:
		hash_pod(&h, options.source_units)
		hash_pod(&h, p.first_layer_height)
		hash_pod(&h, p.layer_height)
		hash_pod(&h, options.max_layer_count)
		hash_pod(&h, options.adaptive_layers)
		if options.adaptive_layers {
			hash_pod(&h, pr.minimum_layer_height)
			hash_pod(&h, pr.maximum_layer_height)
		}
	case .Intersections:
	case .Topology:
		hash_pod(&h, options.contour_simplify_tolerance_um)
	case .Regions:
		hash_pod(&h, options.max_contour_repairs)
		hash_pod(&h, options.use_native_polygon)
	case .Surfaces_Skin:
		hash_pod(&h, p.top_skin)
		hash_pod(&h, p.bottom_skin)
		hash_pod(&h, options.use_native_polygon)
	case .Perimeters:
		hash_pod(&h, p.perimeter_count)
		hash_pod(&h, p.nominal_line_width)
		hash_pod(&h, options.elephant_foot_compensation_um)
		hash_pod(&h, options.use_native_polygon)
	case .Bridges:
		hash_content(&h, stage_hashes.generate_features)
		hash_pod(&h, options.use_native_polygon)
	case .Solid_Skin:
		hash_content(&h, stage_hashes.generate_features)
		hash_pod(&h, options.use_native_polygon)
		hash_pod(&h, options.ensure_vertical_shells)
		hash_pod(&h, options.monotonic_skin)
		hash_pod(&h, options.ironing_enabled)
		hash_pod(&h, options.ironing_spacing_um)
		hash_pod(&h, options.ironing_flow_percent)
		hash_pod(&h, p.perimeter_count)
		hash_pod(&h, p.nominal_line_width)
		hash_pod(&h, p.top_skin)
		hash_pod(&h, p.bottom_skin)
		hash_pod(&h, p.first_layer_height)
		hash_pod(&h, p.layer_height)
	case .Sparse_Infill:
		hash_pod(&h, options.infill_density_percent)
		hash_pod(&h, options.infill_pattern)
		hash_pod(&h, p.nominal_line_width)
		hash_pod(&h, p.layer_height)
		hash_pod(&h, p.perimeter_count)
		hash_pod(&h, options.use_native_polygon)
	case .Gap_Fill:
		hash_content(&h, stage_hashes.generate_features)
		hash_pod(&h, p.nominal_line_width)
		hash_pod(&h, options.use_native_polygon)
	case .Supports:
		hash_content(&h, stage_hashes.generate_features)
		hash_pod(&h, options.use_native_polygon)
		hash_pod(&h, options.enable_supports)
		hash_pod(&h, options.support_style_tree)
		hash_pod(&h, p.nominal_line_width)
		hash_pod(&h, p.support_pattern)
		hash_pod(&h, p.support_overhang_angle)
		hash_pod(&h, p.support_clearance_xy)
		hash_pod(&h, p.support_interface_layers)
		hash_pod(&h, pr.axis_minimum_x)
		hash_pod(&h, pr.axis_maximum_x)
		hash_pod(&h, pr.axis_minimum_y)
		hash_pod(&h, pr.axis_maximum_y)
		hash_pod(&h, options.skirt_loops)
		hash_pod(&h, options.skirt_distance_um)
		hash_pod(&h, options.skirt_height_layers)
		hash_pod(&h, options.brim_width_um)
		hash_pod(&h, options.brim_gap_um)
		hash_pod(&h, options.brim_inner)
		hash_pod(&h, options.elephant_foot_compensation_um)
	case .Path_Plan:
		hash_content(&h, stage_hashes.generate_features)
		hash_pod(&h, options.inner_perimeters_first)
		hash_pod(&h, options.variable_walls_enabled)
		hash_pod(&h, options.fuzzy_skin_enabled)
		hash_pod(&h, options.fuzzy_thickness_um)
		hash_pod(&h, options.fuzzy_point_dist_um)
		hash_pod(&h, options.has_plan_start)
		hash_pod(&h, options.plan_start)
		hash_pod(&h, options.seam_strategy)
		hash_pod(&h, p.seam)
		hash_pod(&h, p.seam_visibility)
		hash_pod(&h, p.nominal_line_width)
		hash_pod(&h, p.first_layer_height)
		hash_pod(&h, p.layer_height)
		hash_pod(&h, pr.axis_minimum_x)
		hash_pod(&h, pr.axis_minimum_y)
	case .Motion:
		hash_content(&h, revisions.printer)
		hash_content(&h, revisions.material)
		hash_content(&h, revisions.process)
		hash_pod(&h, options.wipe_distance_um)
		hash_pod(&h, options.overhang_slowdown_enabled)
		hash_pod(&h, options.overhang_speed_percent)
		hash_pod(&h, options.use_gpu)
		hash_pod(&h, options.scarf_seam_enabled)
		hash_pod(&h, options.scarf_length_um)
		hash_pod(&h, options.vase_mode)
		hash_pod(&h, options.arc_fitting_enabled)
		hash_pod(&h, options.arc_tolerance_um)
		hash_pod(&h, len(options.modifiers))
		for modifier in options.modifiers {hash_pod(&h, modifier)}
	case .Gcode:
		hash_content(&h, revisions.printer)
		hash_content(&h, revisions.dialect)
		hash_pod(&h, len(options.object_name))
		contracts.canonical_hash_append_string(&h, options.object_name)
		hash_pod(&h, len(options.pause_layers))
		for layer in options.pause_layers {hash_pod(&h, layer)}
		hash_pod(&h, len(options.color_change_layers))
		for layer in options.color_change_layers {hash_pod(&h, layer)}
	}
	return contracts.canonical_hash_final(&h)
}
