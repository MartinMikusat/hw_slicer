# 3MF Consortium test fixtures

These files come from the official
[`3mf-samples`](https://github.com/3MFConsortium/3mf-samples) repository at
commit `665e20dc4d7777fd4c9702bca86a2d4028440337`.

The upstream Core `MustPass` and `MustFail` directories are empty at this
commit. These Core examples verify package compatibility. They do not represent
a complete conformance suite.

| Local file | Upstream file | SHA-256 |
| --- | --- | --- |
| `core/box.3mf` | `examples/core/box.3mf` | `d45d18cbbc4f189c2951b5c8c400333c0de633c4b88608dc6f5416b8f7677524` |
| `core/cylinder.3mf` | `examples/core/cylinder.3mf` | `2a263ec8c0e35a677b3a3fc97941f4596a8df3c071bac94551a4512ae95ca086` |
| `archive-must-pass/MUSTPASS_Chapter2.1_PartsRelationships.3mf` | `validation tests/_archive/3mf-Verify/MUSTPASS/MUSTPASS_Chapter2.1_PartsRelationships.3mf` | `e16d5eaf45b3c178575e2d92ec9bc81176f3dd2ca0ecf41368db9670a6623cc7` |
| `archive-must-pass/MUSTPASS_Chapter2.3a_IgnorableMarkup.3mf` | `validation tests/_archive/3mf-Verify/MUSTPASS/MUSTPASS_Chapter2.3a_IgnorableMarkup.3mf` | `80207083fc6c7b1d97793803fd050fb56cad2420246cc318128fd80180a6bb53` |
| `archive-must-pass/MUSTPASS_Chapter3.2c_MultipleItemsTransform.3mf` | `validation tests/_archive/3mf-Verify/MUSTPASS/MUSTPASS_Chapter3.2c_MultipleItemsTransform.3mf` | `535ca50b2de4659a6d696e03e18ee3d7646265655e0a3f0607734582421afce7` |
| `archive-must-pass/MUSTPASS_Chapter3.4.1c_MustIgnoreUndefinedMetadataName.3mf` | `validation tests/_archive/3mf-Verify/MUSTPASS/MUSTPASS_Chapter3.4.1c_MustIgnoreUndefinedMetadataName.3mf` | `a2fa11225ab7bd1cd9d22422f2519fe6b2300905706c850089c758a168131092` |
| `archive-must-pass/MUSTPASS_Chapter3.4.3a_MustNotOutputNonReferencedObjects.3mf` | `validation tests/_archive/3mf-Verify/MUSTPASS/MUSTPASS_Chapter3.4.3a_MustNotOutputNonReferencedObjects.3mf` | `5e44c36ea13fe6f579738caac3c5b82617369604c07141e223272f9abc9dbf8e` |
| `archive-must-pass/MUSTPASS_Chapter4.2_Components.3mf` | `validation tests/_archive/3mf-Verify/MUSTPASS/MUSTPASS_Chapter4.2_Components.3mf` | `edafa758aed598d9a960dc48b04971be6861e017d41bd5fafe81b609c731b2c7` |
| `archive-must-pass/MUSTPASS_Chapter5.1c_MaterialResources_sRGB_RGB_Colors.3mf` | `validation tests/_archive/3mf-Verify/MUSTPASS/MUSTPASS_Chapter5.1c_MaterialResources_sRGB_RGB_Colors.3mf` | `f33c92890c5aa5a55246c826b9dd5e1a13a9c6c140e7783730dae1a08ec2e87f` |
| `archive-must-fail/MUSTFAIL_Chapter2.1.1b_PartsRelationships_LinkToExternal.3mf` | `validation tests/_archive/3mf-Verify/MUSTFAIL/MUSTFAIL_Chapter2.1.1b_PartsRelationships_LinkToExternal.3mf` | `f3a9600d57a104533cfcc3402c03852de3e59923d52b3125f29ee05c5ce72043` |
| `archive-must-fail/MUSTFAIL_Chapter3.4a_MoreThanOneModel.3mf` | `validation tests/_archive/3mf-Verify/MUSTFAIL/MUSTFAIL_Chapter3.4a_MoreThanOneModel.3mf` | `804f9f81a43d99f4732f277b28df3236b8d1fc62e93a28262ae1151d06c26fb8` |
| `archive-must-fail/MUSTFAIL_Chapter3.4.1b_DuplicatedMetadataName.3mf` | `validation tests/_archive/3mf-Verify/MUSTFAIL/MUSTFAIL_Chapter3.4.1b_DuplicatedMetadataName.3mf` | `63a4f31762243567a2f7c227e421ea507fc35ba829a5f74fd7cfdba9241ec294` |

The files use the adjacent [`LICENSE`](LICENSE).
