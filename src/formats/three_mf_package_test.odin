package formats

import "core:testing"

import contracts "../contracts"

THREE_MF_TEST_CONTENT_TYPES ::
	`<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Override PartName="/3D/3dmodel.model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/></Types>`
THREE_MF_TEST_RELATIONSHIPS ::
	`<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Target="/3D/3dmodel.model" Id="rel-1" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>`
THREE_MF_TEST_MODEL ::
	`<model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources/><build/></model>`

three_mf_test_package :: proc(
	relationships := THREE_MF_TEST_RELATIONSHIPS,
	model := THREE_MF_TEST_MODEL,
) -> [dynamic]u8 {
	items := [3]Bounded_Zip_Test_Item{
		{THREE_MF_CONTENT_TYPES_PATH, THREE_MF_TEST_CONTENT_TYPES},
		{THREE_MF_ROOT_RELATIONSHIPS_PATH, relationships},
		{"3D/3dmodel.model", model},
	}
	return bounded_zip_test_make_stored_many(items[:])
}

@(test)
three_mf_package_resolves_and_validates_the_start_model_part_test :: proc(
	t: ^testing.T,
) {
	source := three_mf_test_package()
	defer delete(source)
	package_result, error := three_mf_package_open(source[:])
	defer three_mf_package_destroy(&package_result)
	testing.expect_value(t, error, Three_MF_Package_Error.None)
	testing.expect_value(t, package_result.model_path, "3D/3dmodel.model")
	testing.expect_value(
		t,
		string(package_result.model_bytes),
		THREE_MF_TEST_MODEL,
	)
	testing.expect_value(t, len(package_result.parts), 3)
	testing.expect(
		t,
		package_result.source_root_id != contracts.INVALID_STABLE_ID,
	)
	testing.expect_value(
		t,
		package_result.parts[0].role,
		Three_MF_Package_Part_Role.Content_Types,
	)
	testing.expect_value(
		t,
		package_result.parts[1].role,
		Three_MF_Package_Part_Role.Root_Relationships,
	)
	model_part := package_result.parts[2]
	testing.expect_value(
		t,
		model_part.role,
		Three_MF_Package_Part_Role.Model,
	)
	testing.expect_value(t, model_part.path, "3D/3dmodel.model")
	testing.expect(
		t,
		model_part.stable_id != contracts.INVALID_STABLE_ID,
	)
	extracted, extract_error := three_mf_package_part_extract(
		package_result,
		2,
	)
	defer delete(extracted)
	testing.expect_value(t, extract_error, Bounded_Zip_Error.None)
	testing.expect_value(t, string(extracted), THREE_MF_TEST_MODEL)
	testing.expect_value(
		t,
		package_result.source.format,
		contracts.Source_Format.Three_MF,
	)
	testing.expect_value(
		t,
		package_result.source.byte_count,
		u64(len(source)),
	)
}

@(test)
three_mf_package_rejects_external_model_relationships_test :: proc(
	t: ^testing.T,
) {
	relationships :=
		`<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rel-1" Target="https://example.com/model" TargetMode="External" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>`
	source := three_mf_test_package(relationships)
	defer delete(source)
	_, error := three_mf_package_open(source[:])
	testing.expect_value(
		t,
		error,
		Three_MF_Package_Error.External_Model_Relationship,
	)
}

@(test)
three_mf_package_rejects_external_and_duplicate_relationships_test :: proc(
	t: ^testing.T,
) {
	external_relationships :=
		`<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rel-1" Target="/3D/3dmodel.model" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/><Relationship Id="rel-2" Target="C:/outside.png" Type="urn:test"/></Relationships>`
	external_source := three_mf_test_package(external_relationships)
	defer delete(external_source)
	_, external_error := three_mf_package_open(external_source[:])

	duplicate_relationships :=
		`<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="same" Target="/3D/3dmodel.model" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/><Relationship Id="same" Target="/inside.png" Type="urn:test"/></Relationships>`
	duplicate_source := three_mf_test_package(duplicate_relationships)
	defer delete(duplicate_source)
	_, duplicate_error := three_mf_package_open(duplicate_source[:])

	testing.expect_value(
		t,
		external_error,
		Three_MF_Package_Error.External_Relationship,
	)
	testing.expect_value(
		t,
		duplicate_error,
		Three_MF_Package_Error.Relationships_Invalid,
	)
}

@(test)
three_mf_package_validates_the_model_relationship_part_test :: proc(
	t: ^testing.T,
) {
	model_relationships :=
		`<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rel-1" Target="https://example.com/texture.png" TargetMode="External" Type="urn:test"/></Relationships>`
	items := [4]Bounded_Zip_Test_Item{
		{THREE_MF_CONTENT_TYPES_PATH, THREE_MF_TEST_CONTENT_TYPES},
		{THREE_MF_ROOT_RELATIONSHIPS_PATH, THREE_MF_TEST_RELATIONSHIPS},
		{"3D/3dmodel.model", THREE_MF_TEST_MODEL},
		{"3D/_rels/3dmodel.model.rels", model_relationships},
	}
	source := bounded_zip_test_make_stored_many(items[:])
	defer delete(source)
	package_result, error := three_mf_package_open(source[:])
	defer three_mf_package_destroy(&package_result)
	testing.expect_value(
		t,
		error,
		Three_MF_Package_Error.External_Relationship,
	)
}

@(test)
three_mf_package_part_extract_rejects_mutated_provenance_test :: proc(
	t: ^testing.T,
) {
	source := three_mf_test_package()
	defer delete(source)
	package_result, package_error := three_mf_package_open(source[:])
	defer three_mf_package_destroy(&package_result)
	testing.expect_value(
		t,
		package_error,
		Three_MF_Package_Error.None,
	)
	original_crc := package_result.parts[2].crc32
	package_result.parts[2].crc32 ~= 1
	extracted, extract_error := three_mf_package_part_extract(
		package_result,
		2,
	)
	defer delete(extracted)
	testing.expect_value(
		t,
		extract_error,
		Bounded_Zip_Error.Size_Mismatch,
	)
	package_result.parts[2].crc32 = original_crc
}

@(test)
three_mf_package_marks_model_relationship_part_provenance_test :: proc(
	t: ^testing.T,
) {
	model_relationships :=
		`<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rel-1" Target="/3D/texture.png" Type="urn:test"/></Relationships>`
	items := [4]Bounded_Zip_Test_Item{
		{THREE_MF_CONTENT_TYPES_PATH, THREE_MF_TEST_CONTENT_TYPES},
		{THREE_MF_ROOT_RELATIONSHIPS_PATH, THREE_MF_TEST_RELATIONSHIPS},
		{"3D/3dmodel.model", THREE_MF_TEST_MODEL},
		{"3D/_rels/3dmodel.model.rels", model_relationships},
	}
	source := bounded_zip_test_make_stored_many(items[:])
	defer delete(source)
	package_result, package_error := three_mf_package_open(source[:])
	defer three_mf_package_destroy(&package_result)
	testing.expect_value(
		t,
		package_error,
		Three_MF_Package_Error.None,
	)
	testing.expect_value(t, len(package_result.parts), 4)
	testing.expect_value(
		t,
		package_result.parts[3].role,
		Three_MF_Package_Part_Role.Model_Relationships,
	)
}

@(test)
three_mf_package_rejects_dtd_or_entity_model_parts_test :: proc(
	t: ^testing.T,
) {
	model :=
		`<!DOCTYPE model [<!ENTITY external SYSTEM "file:///tmp/x">]><model/>`
	source := three_mf_test_package(model = model)
	defer delete(source)
	_, error := three_mf_package_open(source[:])
	testing.expect_value(
		t,
		error,
		Three_MF_Package_Error.XML_Prohibited_Construct,
	)
}

@(test)
three_mf_package_rejects_multiple_xml_roots_test :: proc(t: ^testing.T) {
	model :=
		`<model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources/><build/></model><model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources/><build/></model>`
	source := three_mf_test_package(model = model)
	defer delete(source)
	_, error := three_mf_package_open(source[:])
	testing.expect_value(t, error, Three_MF_Package_Error.XML_Invalid)
}

@(test)
three_mf_package_requires_a_model_content_type_test :: proc(t: ^testing.T) {
	items := [3]Bounded_Zip_Test_Item{
		{
			THREE_MF_CONTENT_TYPES_PATH,
			`<Types><Override PartName="/3D/3dmodel.model" ContentType="text/xml"/></Types>`,
		},
		{THREE_MF_ROOT_RELATIONSHIPS_PATH, THREE_MF_TEST_RELATIONSHIPS},
		{"3D/3dmodel.model", THREE_MF_TEST_MODEL},
	}
	source := bounded_zip_test_make_stored_many(items[:])
	defer delete(source)
	_, error := three_mf_package_open(source[:])
	testing.expect_value(
		t,
		error,
		Three_MF_Package_Error.Model_Content_Type,
	)
}

@(test)
three_mf_xml_preflight_bounds_nesting_before_dom_allocation_test :: proc(
	t: ^testing.T,
) {
	part: [dynamic]u8
	append(
		&part,
		`<model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">`,
	)
	for _ in 0..<int(THREE_MF_XML_MAX_DEPTH) {
		append(&part, "<x>")
	}
	for _ in 0..<int(THREE_MF_XML_MAX_DEPTH) {
		append(&part, "</x>")
	}
	append(&part, "</model>")
	defer delete(part)
	error := three_mf_xml_preflight(part[:], 1024)
	testing.expect_value(
		t,
		error,
		Three_MF_Package_Error.XML_Depth_Limit,
	)
}

@(test)
three_mf_xml_preflight_bounds_attributes_before_dom_allocation_test :: proc(
	t: ^testing.T,
) {
	part: [dynamic]u8
	append(&part, "<model")
	for _ in 0..<int(THREE_MF_XML_MAX_ATTRIBUTES)+1 {
		append(&part, ` a="1"`)
	}
	append(&part, "/>")
	defer delete(part)
	error := three_mf_xml_preflight(part[:], 1)
	testing.expect_value(
		t,
		error,
		Three_MF_Package_Error.XML_Attribute_Limit,
	)
}

@(test)
three_mf_package_rejects_control_parts_in_the_wrong_namespace_test :: proc(
	t: ^testing.T,
) {
	relationships :=
		`<Relationships xmlns="urn:wrong"><Relationship Id="rel-1" Target="/3D/3dmodel.model" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>`
	source := three_mf_test_package(relationships)
	defer delete(source)
	_, error := three_mf_package_open(source[:])
	testing.expect_value(
		t,
		error,
		Three_MF_Package_Error.Relationships_Invalid,
	)
}
