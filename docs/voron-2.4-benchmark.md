# Voron 2.4 Full-Printer Slicing Benchmark (`hw_slicer` vs. OrcaSlicer 2.5.1)

End-to-end CLI wall-clock timings for all 155 models in suite `voron2.4` (`runs=1`, matched Klipper 350 mm machine, ABS filament, `voron-2.4-standard` 0.20 mm / 0.40 mm / 4 walls / 5 top & bottom / 40% gyroid, and `voron-2.4-high-stress` 5 walls / 8 top & bottom / 50% gyroid for front idlers).

## Summary

| Metric | Value |
|---|---:|
| Models sliced | 155/155 |
| `hw_slicer` total wall time | **46.13 s** (297.6 ms avg) |
| OrcaSlicer 2.5.1 total wall time | **77.89 s** (502.5 ms avg) |
| Overall wall-time speedup (`Orca / hw`) | **1.69×** |
| Geometric mean speedup | **1.96×** |
| Median speedup | **1.78×** |
| Parts where `hw_slicer` is faster | **154/155** |

## Per-Part Comparison

| # | Part | Profile | Tris | Layers | `hw_slicer` (ms) | OrcaSlicer 2.5.1 (ms) | Speedup (`Orca / hw`) |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `voron-2.4/Electronics_Bay/Controller_Mounts/BIGDIPPER_bracket_set.stl` | `voron-2.4-standard` | 31472 | 35 | 320.6 | 427.4 | **1.33×** |
| 2 | `voron-2.4/Electronics_Bay/Controller_Mounts/BTT_MOT_EXP_bracket.stl` | `voron-2.4-standard` | 23340 | 35 | 165.9 | 301.7 | **1.82×** |
| 3 | `voron-2.4/Electronics_Bay/Controller_Mounts/Duet2_Duet3Mini5_bracket_set.stl` | `voron-2.4-standard` | 29448 | 35 | 210.9 | 398.0 | **1.89×** |
| 4 | `voron-2.4/Electronics_Bay/Controller_Mounts/GTR_bracket_set.stl` | `voron-2.4-standard` | 28420 | 35 | 212.4 | 386.6 | **1.82×** |
| 5 | `voron-2.4/Electronics_Bay/Controller_Mounts/Octopus_bracket_set.stl` | `voron-2.4-standard` | 32524 | 35 | 255.6 | 453.7 | **1.78×** |
| 6 | `voron-2.4/Electronics_Bay/Controller_Mounts/S6_bracket_set.stl` | `voron-2.4-standard` | 30592 | 35 | 276.7 | 412.1 | **1.49×** |
| 7 | `voron-2.4/Electronics_Bay/Controller_Mounts/SKR_Pro_bracket_set.stl` | `voron-2.4-standard` | 31736 | 35 | 243.7 | 422.9 | **1.74×** |
| 8 | `voron-2.4/Electronics_Bay/Controller_Mounts/SKR_bracket_inline_set.stl` | `voron-2.4-standard` | 29580 | 35 | 368.7 | 403.8 | **1.10×** |
| 9 | `voron-2.4/Electronics_Bay/Controller_Mounts/Spider_bracket_set.stl` | `voron-2.4-standard` | 36016 | 45 | 278.1 | 423.0 | **1.52×** |
| 10 | `voron-2.4/Electronics_Bay/Other_PS_Mounts/UHP_200_Mount_x2.stl` | `voron-2.4-standard` | 2792 | 40 | 33.5 | 234.4 | **6.99×** |
| 11 | `voron-2.4/Electronics_Bay/Other_PS_Mounts/UHP_350_Mount_x2.stl` | `voron-2.4-standard` | 2756 | 40 | 33.3 | 238.0 | **7.15×** |
| 12 | `voron-2.4/Electronics_Bay/PSU_stabilizer_50mm.stl` | `voron-2.4-standard` | 8384 | 75 | 73.1 | 212.8 | **2.91×** |
| 13 | `voron-2.4/Electronics_Bay/lrs_200_psu_bracket_x2.stl` | `voron-2.4-standard` | 5244 | 70 | 47.2 | 300.3 | **6.36×** |
| 14 | `voron-2.4/Electronics_Bay/pcb_din_clip_x3.stl` | `voron-2.4-standard` | 1308 | 50 | 25.4 | 186.5 | **7.33×** |
| 15 | `voron-2.4/Electronics_Bay/raspberrypi_bracket.stl` | `voron-2.4-standard` | 22458 | 35 | 154.4 | 274.7 | **1.78×** |
| 16 | `voron-2.4/Electronics_Bay/rs25_psu_bracket.stl` | `voron-2.4-standard` | 4130 | 50 | 38.1 | 263.4 | **6.92×** |
| 17 | `voron-2.4/Electronics_Bay/wago_221-415_mount_3by5.stl` | `voron-2.4-standard` | 1452 | 61 | 37.6 | 179.1 | **4.76×** |
| 18 | `voron-2.4/Exhaust_Filter/[a]_exhaust_fan_grill.stl` | `voron-2.4-standard` | 5642 | 16 | 233.7 | 273.3 | **1.17×** |
| 19 | `voron-2.4/Exhaust_Filter/[a]_exhaust_filter_mount_x2.stl` | `voron-2.4-standard` | 1636 | 20 | 41.0 | 113.4 | **2.77×** |
| 20 | `voron-2.4/Exhaust_Filter/[a]_filter_access_cover.stl` | `voron-2.4-standard` | 6808 | 36 | 159.3 | 233.9 | **1.47×** |
| 21 | `voron-2.4/Exhaust_Filter/exhaust_filter_grill.stl` | `voron-2.4-standard` | 4840 | 28 | 178.5 | 354.8 | **1.99×** |
| 22 | `voron-2.4/Exhaust_Filter/exhaust_filter_housing.stl` | `voron-2.4-standard` | 43928 | 225 | 700.9 | 1119.4 | **1.60×** |
| 23 | `voron-2.4/Gantry/AB_Drive_Units/[a]_cable_cover.stl` | `voron-2.4-standard` | 9390 | 170 | 358.6 | 386.8 | **1.08×** |
| 24 | `voron-2.4/Gantry/AB_Drive_Units/[a]_z_chain_retainer_bracket_x2.stl` | `voron-2.4-standard` | 3566 | 25 | 37.6 | 156.5 | **4.16×** |
| 25 | `voron-2.4/Gantry/AB_Drive_Units/a_drive_frame_lower.stl` | `voron-2.4-standard` | 35520 | 85 | 579.2 | 766.0 | **1.32×** |
| 26 | `voron-2.4/Gantry/AB_Drive_Units/a_drive_frame_upper.stl` | `voron-2.4-standard` | 21786 | 75 | 697.1 | 764.4 | **1.10×** |
| 27 | `voron-2.4/Gantry/AB_Drive_Units/b_drive_frame_lower.stl` | `voron-2.4-standard` | 34126 | 85 | 491.1 | 707.4 | **1.44×** |
| 28 | `voron-2.4/Gantry/AB_Drive_Units/b_drive_frame_upper.stl` | `voron-2.4-standard` | 17836 | 75 | 565.7 | 732.4 | **1.29×** |
| 29 | `voron-2.4/Gantry/Front_Idlers/[a]_tensioner_left.stl` | `voron-2.4-standard` | 6556 | 90 | 141.8 | 255.3 | **1.80×** |
| 30 | `voron-2.4/Gantry/Front_Idlers/[a]_tensioner_right.stl` | `voron-2.4-standard` | 6568 | 90 | 166.7 | 257.6 | **1.54×** |
| 31 | `voron-2.4/Gantry/Front_Idlers/front_idler_left_lower.stl` | `voron-2.4-high-stress` | 11174 | 58 | 259.7 | 307.1 | **1.18×** |
| 32 | `voron-2.4/Gantry/Front_Idlers/front_idler_left_upper.stl` | `voron-2.4-high-stress` | 10584 | 108 | 449.4 | 445.5 | **0.99×** |
| 33 | `voron-2.4/Gantry/Front_Idlers/front_idler_right_lower.stl` | `voron-2.4-high-stress` | 10582 | 108 | 336.3 | 420.7 | **1.25×** |
| 34 | `voron-2.4/Gantry/Front_Idlers/front_idler_right_upper.stl` | `voron-2.4-high-stress` | 11246 | 60 | 249.2 | 325.3 | **1.31×** |
| 35 | `voron-2.4/Gantry/X_Axis/XY_Joints/[a]_endstop_pod_D2F_switch.stl` | `voron-2.4-standard` | 13174 | 70 | 299.6 | 453.4 | **1.51×** |
| 36 | `voron-2.4/Gantry/X_Axis/XY_Joints/[a]_endstop_pod_hall_effect.stl` | `voron-2.4-standard` | 21240 | 70 | 308.9 | 399.8 | **1.29×** |
| 37 | `voron-2.4/Gantry/X_Axis/XY_Joints/[a]_xy_joint_cable_bridge_2hole.stl` | `voron-2.4-standard` | 12156 | 105 | 193.6 | 329.9 | **1.70×** |
| 38 | `voron-2.4/Gantry/X_Axis/XY_Joints/[a]_xy_joint_cable_bridge_3hole.stl` | `voron-2.4-standard` | 12356 | 105 | 198.7 | 345.9 | **1.74×** |
| 39 | `voron-2.4/Gantry/X_Axis/XY_Joints/xy_joint_left_lower_MGN12.stl` | `voron-2.4-standard` | 24544 | 170 | 609.5 | 985.3 | **1.62×** |
| 40 | `voron-2.4/Gantry/X_Axis/XY_Joints/xy_joint_left_upper_MGN12.stl` | `voron-2.4-standard` | 19014 | 80 | 518.2 | 617.5 | **1.19×** |
| 41 | `voron-2.4/Gantry/X_Axis/XY_Joints/xy_joint_right_lower_MGN12.stl` | `voron-2.4-standard` | 29488 | 170 | 826.0 | 1396.2 | **1.69×** |
| 42 | `voron-2.4/Gantry/X_Axis/XY_Joints/xy_joint_right_upper_MGN12.stl` | `voron-2.4-standard` | 15090 | 80 | 738.3 | 1091.9 | **1.48×** |
| 43 | `voron-2.4/Gantry/X_Axis/X_Carriage/pinda_adapter.stl` | `voron-2.4-standard` | 24274 | 140 | 382.3 | 1027.9 | **2.69×** |
| 44 | `voron-2.4/Gantry/X_Axis/X_Carriage/probe_retainer_bracket.stl` | `voron-2.4-standard` | 6064 | 20 | 131.0 | 240.7 | **1.84×** |
| 45 | `voron-2.4/Gantry/X_Axis/X_Carriage/probe_retainer_bracket_9mm.stl` | `voron-2.4-standard` | 6196 | 20 | 59.6 | 268.2 | **4.50×** |
| 46 | `voron-2.4/Gantry/X_Axis/X_Carriage/x_frame_V2TR_MGN12_left.stl` | `voron-2.4-standard` | 13070 | 108 | 707.5 | 800.6 | **1.13×** |
| 47 | `voron-2.4/Gantry/X_Axis/X_Carriage/x_frame_V2TR_MGN12_right.stl` | `voron-2.4-standard` | 19409 | 108 | 478.6 | 759.1 | **1.59×** |
| 48 | `voron-2.4/Gantry/Z_Joints/z_joint_lower_x4.stl` | `voron-2.4-standard` | 31724 | 120 | 340.8 | 560.1 | **1.64×** |
| 49 | `voron-2.4/Gantry/Z_Joints/z_joint_upper_hall_effect.stl` | `voron-2.4-standard` | 26708 | 102 | 364.4 | 437.9 | **1.20×** |
| 50 | `voron-2.4/Gantry/Z_Joints/z_joint_upper_x4.stl` | `voron-2.4-standard` | 26442 | 102 | 409.2 | 490.4 | **1.20×** |
| 51 | `voron-2.4/Gantry/[a]_z_belt_clip_lower_x4.stl` | `voron-2.4-standard` | 2706 | 28 | 100.7 | 153.0 | **1.52×** |
| 52 | `voron-2.4/Gantry/[a]_z_belt_clip_upper_x4.stl` | `voron-2.4-standard` | 2236 | 26 | 99.3 | 157.9 | **1.59×** |
| 53 | `voron-2.4/Gantry/z_chain_bottom_anchor.stl` | `voron-2.4-standard` | 9616 | 75 | 198.9 | 424.1 | **2.13×** |
| 54 | `voron-2.4/Gantry/z_chain_guide.stl` | `voron-2.4-standard` | 17564 | 105 | 350.9 | 454.4 | **1.29×** |
| 55 | `voron-2.4/Panel_Mounting/Front_Doors/door_hinge_x6.stl` | `voron-2.4-standard` | 19900 | 65 | 200.7 | 382.4 | **1.91×** |
| 56 | `voron-2.4/Panel_Mounting/Front_Doors/handle_a_x2.stl` | `voron-2.4-standard` | 4400 | 35 | 72.6 | 192.4 | **2.65×** |
| 57 | `voron-2.4/Panel_Mounting/Front_Doors/handle_b_x2.stl` | `voron-2.4-standard` | 4400 | 35 | 77.1 | 193.4 | **2.51×** |
| 58 | `voron-2.4/Panel_Mounting/Front_Doors/latch_x2.stl` | `voron-2.4-standard` | 2546 | 65 | 99.7 | 179.0 | **1.80×** |
| 59 | `voron-2.4/Panel_Mounting/bottom_panel_clip_x4.stl` | `voron-2.4-standard` | 1384 | 30 | 63.7 | 173.0 | **2.72×** |
| 60 | `voron-2.4/Panel_Mounting/bottom_panel_hinge_x2.stl` | `voron-2.4-standard` | 11032 | 30 | 169.7 | 338.0 | **1.99×** |
| 61 | `voron-2.4/Panel_Mounting/corner_panel_clip_4mm_x8.stl` | `voron-2.4-standard` | 6994 | 35 | 209.1 | 309.7 | **1.48×** |
| 62 | `voron-2.4/Panel_Mounting/corner_panel_clip_6mm_x8.stl` | `voron-2.4-standard` | 7884 | 50 | 240.3 | 379.1 | **1.58×** |
| 63 | `voron-2.4/Panel_Mounting/deck_support_3mm_x8.stl` | `voron-2.4-standard` | 2498 | 29 | 54.8 | 206.3 | **3.77×** |
| 64 | `voron-2.4/Panel_Mounting/deck_support_4mm_x8.stl` | `voron-2.4-standard` | 2544 | 29 | 64.5 | 200.9 | **3.12×** |
| 65 | `voron-2.4/Panel_Mounting/midspan_panel_clip_4mm_x7.stl` | `voron-2.4-standard` | 5978 | 35 | 109.7 | 317.1 | **2.89×** |
| 66 | `voron-2.4/Panel_Mounting/midspan_panel_clip_6mm_x8.stl` | `voron-2.4-standard` | 6536 | 50 | 138.1 | 358.6 | **2.60×** |
| 67 | `voron-2.4/Panel_Mounting/z_belt_cover_a_x2.stl` | `voron-2.4-standard` | 13566 | 33 | 104.9 | 298.8 | **2.85×** |
| 68 | `voron-2.4/Panel_Mounting/z_belt_cover_b_x2.stl` | `voron-2.4-standard` | 13566 | 33 | 117.1 | 261.1 | **2.23×** |
| 69 | `voron-2.4/Skirts/250/front_skirt_a_250.stl` | `voron-2.4-standard` | 14888 | 100 | 689.7 | 1065.1 | **1.54×** |
| 70 | `voron-2.4/Skirts/250/front_skirt_b_250.stl` | `voron-2.4-standard` | 14888 | 100 | 694.5 | 1090.0 | **1.57×** |
| 71 | `voron-2.4/Skirts/250/rear_center_skirt_250.stl` | `voron-2.4-standard` | 7068 | 100 | 427.9 | 705.6 | **1.65×** |
| 72 | `voron-2.4/Skirts/250/side_skirt_a_250_x2.stl` | `voron-2.4-standard` | 10004 | 100 | 615.8 | 857.0 | **1.39×** |
| 73 | `voron-2.4/Skirts/250/side_skirt_b_250_x2.stl` | `voron-2.4-standard` | 10004 | 100 | 627.3 | 795.7 | **1.27×** |
| 74 | `voron-2.4/Skirts/300/front_skirt_a_300.stl` | `voron-2.4-standard` | 15464 | 100 | 653.2 | 1339.1 | **2.05×** |
| 75 | `voron-2.4/Skirts/300/front_skirt_b_300.stl` | `voron-2.4-standard` | 15464 | 100 | 737.1 | 1226.1 | **1.66×** |
| 76 | `voron-2.4/Skirts/300/rear_center_skirt_300.stl` | `voron-2.4-standard` | 8430 | 100 | 687.8 | 1059.1 | **1.54×** |
| 77 | `voron-2.4/Skirts/300/side_skirt_a_300_x2.stl` | `voron-2.4-standard` | 10762 | 100 | 653.5 | 808.9 | **1.24×** |
| 78 | `voron-2.4/Skirts/300/side_skirt_b_300_x2.stl` | `voron-2.4-standard` | 10762 | 100 | 597.6 | 768.1 | **1.29×** |
| 79 | `voron-2.4/Skirts/350/front_skirt_a_350.stl` | `voron-2.4-standard` | 16018 | 100 | 699.3 | 1248.4 | **1.79×** |
| 80 | `voron-2.4/Skirts/350/front_skirt_b_350.stl` | `voron-2.4-standard` | 16008 | 100 | 690.2 | 1210.7 | **1.75×** |
| 81 | `voron-2.4/Skirts/350/rear_center_skirt_350.stl` | `voron-2.4-standard` | 9468 | 100 | 861.0 | 1519.2 | **1.76×** |
| 82 | `voron-2.4/Skirts/350/side_skirt_a_350_x2.stl` | `voron-2.4-standard` | 11276 | 100 | 729.5 | 1218.9 | **1.67×** |
| 83 | `voron-2.4/Skirts/350/side_skirt_b_350_x2.stl` | `voron-2.4-standard` | 11276 | 100 | 809.3 | 1078.8 | **1.33×** |
| 84 | `voron-2.4/Skirts/[a]_belt_guard_a_x2.stl` | `voron-2.4-standard` | 12102 | 41 | 184.3 | 374.2 | **2.03×** |
| 85 | `voron-2.4/Skirts/[a]_belt_guard_b_x2.stl` | `voron-2.4-standard` | 12102 | 41 | 188.3 | 369.1 | **1.96×** |
| 86 | `voron-2.4/Skirts/[a]_btt_knob_light_shield.stl` | `voron-2.4-standard` | 14688 | 13 | 92.5 | 225.5 | **2.44×** |
| 87 | `voron-2.4/Skirts/[a]_fan_grill_a_x2.stl` | `voron-2.4-standard` | 6084 | 16 | 200.2 | 282.2 | **1.41×** |
| 88 | `voron-2.4/Skirts/[a]_fan_grill_b_x2.stl` | `voron-2.4-standard` | 6084 | 16 | 209.2 | 280.8 | **1.34×** |
| 89 | `voron-2.4/Skirts/[a]_fan_grill_open_optional_x2.stl` | `voron-2.4-standard` | 2508 | 16 | 175.2 | 203.9 | **1.16×** |
| 90 | `voron-2.4/Skirts/[a]_fan_grill_retainer_x2.stl` | `voron-2.4-standard` | 6142 | 25 | 159.0 | 262.2 | **1.65×** |
| 91 | `voron-2.4/Skirts/[a]_keystone_blank_insert.stl` | `voron-2.4-standard` | 2768 | 74 | 127.2 | 179.9 | **1.41×** |
| 92 | `voron-2.4/Skirts/[a]_mini12864_case_front_insert.stl` | `voron-2.4-standard` | 24914 | 34 | 230.9 | 461.3 | **2.00×** |
| 93 | `voron-2.4/Skirts/[a]_mini12864_case_hinge.stl` | `voron-2.4-standard` | 11456 | 164 | 364.0 | 653.6 | **1.80×** |
| 94 | `voron-2.4/Skirts/keystone_panel.stl` | `voron-2.4-standard` | 13996 | 100 | 561.0 | 974.6 | **1.74×** |
| 95 | `voron-2.4/Skirts/mini12864_case_front.stl` | `voron-2.4-standard` | 14972 | 95 | 235.7 | 489.9 | **2.08×** |
| 96 | `voron-2.4/Skirts/mini12864_case_rear.stl` | `voron-2.4-standard` | 18470 | 58 | 304.9 | 456.0 | **1.50×** |
| 97 | `voron-2.4/Skirts/power_inlet_IECGS_1.2mm.stl` | `voron-2.4-standard` | 15924 | 100 | 517.8 | 893.4 | **1.73×** |
| 98 | `voron-2.4/Skirts/power_inlet_IECGS_1mm.stl` | `voron-2.4-standard` | 15502 | 100 | 538.7 | 908.5 | **1.69×** |
| 99 | `voron-2.4/Skirts/power_inlet_filtered.stl` | `voron-2.4-standard` | 17478 | 100 | 522.0 | 1014.8 | **1.94×** |
| 100 | `voron-2.4/Skirts/side_fan_support_x2.STL` | `voron-2.4-standard` | 19334 | 100 | 551.8 | 758.8 | **1.38×** |
| 101 | `voron-2.4/Spool_Management/bowden_retainer.stl` | `voron-2.4-standard` | 6228 | 50 | 128.7 | 363.4 | **2.82×** |
| 102 | `voron-2.4/Spool_Management/spool_holder.stl` | `voron-2.4-standard` | 8772 | 65 | 392.5 | 515.6 | **1.31×** |
| 103 | `voron-2.4/Superceded_Parts/Frame_Brackets/dual_ramps_bracket_frame.stl` | `voron-2.4-standard` | 4056 | 64 | 336.3 | 506.3 | **1.51×** |
| 104 | `voron-2.4/Superceded_Parts/Frame_Brackets/duet_duex_bracket_frame_x2.stl` | `voron-2.4-standard` | 44732 | 64 | 375.1 | 428.8 | **1.14×** |
| 105 | `voron-2.4/Superceded_Parts/Frame_Brackets/lrs_bracket_frame.stl` | `voron-2.4-standard` | 4662 | 100 | 124.3 | 308.8 | **2.48×** |
| 106 | `voron-2.4/Superceded_Parts/Frame_Brackets/mks_gen_1.4_bracket_frame_x2.stl` | `voron-2.4-standard` | 60224 | 64 | 389.5 | 478.3 | **1.23×** |
| 107 | `voron-2.4/Superceded_Parts/Frame_Brackets/mks_gen_L_bracket_frame_x2.stl` | `voron-2.4-standard` | 60680 | 64 | 325.6 | 464.5 | **1.43×** |
| 108 | `voron-2.4/Superceded_Parts/Frame_Brackets/raspberry_pi_bracket.stl` | `voron-2.4-standard` | 3494 | 63 | 168.5 | 433.3 | **2.57×** |
| 109 | `voron-2.4/Superceded_Parts/Frame_Brackets/rs_25_psu_bracket_frame.stl` | `voron-2.4-standard` | 3146 | 64 | 91.0 | 346.0 | **3.80×** |
| 110 | `voron-2.4/Superceded_Parts/Frame_Brackets/rs_35_bracket_frame.stl` | `voron-2.4-standard` | 3146 | 64 | 93.5 | 356.9 | **3.82×** |
| 111 | `voron-2.4/Superceded_Parts/Frame_Brackets/skr_1.3_bracket_frame.stl` | `voron-2.4-standard` | 44486 | 64 | 363.2 | 436.0 | **1.20×** |
| 112 | `voron-2.4/Superceded_Parts/Frame_Brackets/skr_mini_e3_bracket_frame.stl` | `voron-2.4-standard` | 37988 | 64 | 263.6 | 354.1 | **1.34×** |
| 113 | `voron-2.4/Superceded_Parts/MGN9_X/[a]_belt_clamp_MGN9_x2.stl` | `voron-2.4-standard` | 14932 | 31 | 47.5 | 318.2 | **6.69×** |
| 114 | `voron-2.4/Superceded_Parts/MGN9_X/x_carriage_frame_left_MGN9.stl` | `voron-2.4-standard` | 25548 | 110 | 525.6 | 747.1 | **1.42×** |
| 115 | `voron-2.4/Superceded_Parts/MGN9_X/x_carriage_frame_right_MGN9.stl` | `voron-2.4-standard` | 24934 | 100 | 453.4 | 753.9 | **1.66×** |
| 116 | `voron-2.4/Superceded_Parts/MGN9_X/x_carriage_pivot_block_MGN9.stl` | `voron-2.4-standard` | 13488 | 70 | 134.4 | 291.3 | **2.17×** |
| 117 | `voron-2.4/Superceded_Parts/MGN9_X/xy_joint_left_lower_MGN9.stl` | `voron-2.4-standard` | 9878 | 170 | 476.2 | 941.8 | **1.98×** |
| 118 | `voron-2.4/Superceded_Parts/MGN9_X/xy_joint_left_upper_MGN9.stl` | `voron-2.4-standard` | 20144 | 80 | 437.2 | 557.4 | **1.27×** |
| 119 | `voron-2.4/Superceded_Parts/MGN9_X/xy_joint_right_lower_MGN9.stl` | `voron-2.4-standard` | 30776 | 170 | 826.8 | 1092.1 | **1.32×** |
| 120 | `voron-2.4/Superceded_Parts/MGN9_X/xy_joint_right_upper_MGN9.stl` | `voron-2.4-standard` | 7052 | 80 | 242.1 | 478.0 | **1.97×** |
| 121 | `voron-2.4/Superceded_Parts/ZipChain/XY/zipchain2_xy_end.stl` | `voron-2.4-standard` | 11348 | 50 | 88.8 | 267.3 | **3.01×** |
| 122 | `voron-2.4/Superceded_Parts/ZipChain/XY/zipchain2_xy_link_a.stl` | `voron-2.4-standard` | 9080 | 50 | 136.6 | 310.9 | **2.28×** |
| 123 | `voron-2.4/Superceded_Parts/ZipChain/XY/zipchain2_xy_link_b.stl` | `voron-2.4-standard` | 13076 | 47 | 110.5 | 319.0 | **2.89×** |
| 124 | `voron-2.4/Superceded_Parts/ZipChain/Z/zipchain2_z_end.stl` | `voron-2.4-standard` | 11104 | 50 | 95.2 | 266.3 | **2.80×** |
| 125 | `voron-2.4/Superceded_Parts/ZipChain/Z/zipchain2_z_link_a.stl` | `voron-2.4-standard` | 10112 | 50 | 143.4 | 305.5 | **2.13×** |
| 126 | `voron-2.4/Superceded_Parts/ZipChain/Z/zipchain2_z_link_b.stl` | `voron-2.4-standard` | 16228 | 47 | 125.5 | 333.1 | **2.65×** |
| 127 | `voron-2.4/Superceded_Parts/ZipChain/Z/zipchain2_z_link_b_locking.stl` | `voron-2.4-standard` | 24712 | 47 | 152.6 | 409.7 | **2.68×** |
| 128 | `voron-2.4/Superceded_Parts/[a]_stopgap_80T_hubbed_gear.stl` | `voron-2.4-standard` | 47178 | 57 | 944.2 | 1065.1 | **1.13×** |
| 129 | `voron-2.4/Superceded_Parts/[a]_z_tensioner_x4_6mm.stl` | `voron-2.4-standard` | 26782 | 90 | 165.6 | 663.8 | **4.01×** |
| 130 | `voron-2.4/Test_Prints/Filament_Card.stl` | `voron-2.4-standard` | 802 | 10 | 31.3 | 128.7 | **4.11×** |
| 131 | `voron-2.4/Test_Prints/Filament_Card_Caddy_25.stl` | `voron-2.4-standard` | 1260 | 100 | 82.2 | 372.0 | **4.53×** |
| 132 | `voron-2.4/Test_Prints/Heatset_Practice.stl` | `voron-2.4-standard` | 7472 | 50 | 124.5 | 261.1 | **2.10×** |
| 133 | `voron-2.4/Test_Prints/Thread_Test_1_x1_Rev1.STL` | `voron-2.4-standard` | 79822 | 80 | 273.1 | 470.1 | **1.72×** |
| 134 | `voron-2.4/Test_Prints/Thread_Test_2_x1_Rev1.STL` | `voron-2.4-standard` | 23656 | 80 | 238.2 | 446.0 | **1.87×** |
| 135 | `voron-2.4/Test_Prints/Thread_Test_3_x1_Rev1.STL` | `voron-2.4-standard` | 19318 | 53 | 143.9 | 378.9 | **2.63×** |
| 136 | `voron-2.4/Test_Prints/Voron_Design_Cube_v7.stl` | `voron-2.4-standard` | 3414 | 150 | 214.6 | 468.1 | **2.18×** |
| 137 | `voron-2.4/Tools/MGN12_rail_guide_x2.stl` | `voron-2.4-standard` | 1216 | 40 | 39.4 | 113.5 | **2.88×** |
| 138 | `voron-2.4/Tools/MGN9_rail_guide_x2.stl` | `voron-2.4-standard` | 620 | 50 | 38.0 | 103.0 | **2.71×** |
| 139 | `voron-2.4/Tools/bed_hole_marking_template_x1_Rev2.STL` | `voron-2.4-standard` | 876 | 50 | 36.3 | 134.3 | **3.70×** |
| 140 | `voron-2.4/Tools/bottom_panel_template.stl` | `voron-2.4-standard` | 2732 | 25 | 83.8 | 138.7 | **1.66×** |
| 141 | `voron-2.4/Tools/pulley_jig.stl` | `voron-2.4-standard` | 2620 | 16 | 32.5 | 136.7 | **4.20×** |
| 142 | `voron-2.4/Z_Drive/[a]_belt_tensioner_a_x2.stl` | `voron-2.4-standard` | 9252 | 44 | 64.3 | 151.2 | **2.35×** |
| 143 | `voron-2.4/Z_Drive/[a]_belt_tensioner_b_x2.stl` | `voron-2.4-standard` | 9252 | 44 | 65.7 | 155.2 | **2.36×** |
| 144 | `voron-2.4/Z_Drive/[a]_z_drive_baseplate_a_x2.stl` | `voron-2.4-standard` | 10084 | 50 | 217.8 | 395.4 | **1.82×** |
| 145 | `voron-2.4/Z_Drive/[a]_z_drive_baseplate_b_x2.stl` | `voron-2.4-standard` | 10084 | 50 | 209.8 | 371.1 | **1.77×** |
| 146 | `voron-2.4/Z_Drive/z_drive_main_a_x2.stl` | `voron-2.4-standard` | 23308 | 134 | 613.6 | 1022.5 | **1.67×** |
| 147 | `voron-2.4/Z_Drive/z_drive_main_b_x2.stl` | `voron-2.4-standard` | 23308 | 134 | 606.3 | 1016.7 | **1.68×** |
| 148 | `voron-2.4/Z_Drive/z_drive_retainer_a_x2.stl` | `voron-2.4-standard` | 16792 | 81 | 357.0 | 625.6 | **1.75×** |
| 149 | `voron-2.4/Z_Drive/z_drive_retainer_b_x2.stl` | `voron-2.4-standard` | 16792 | 81 | 367.0 | 658.5 | **1.79×** |
| 150 | `voron-2.4/Z_Drive/z_motor_mount_a_x2.stl` | `voron-2.4-standard` | 21424 | 210 | 192.4 | 448.0 | **2.33×** |
| 151 | `voron-2.4/Z_Drive/z_motor_mount_b_x2.stl` | `voron-2.4-standard` | 21424 | 210 | 193.1 | 490.5 | **2.54×** |
| 152 | `voron-2.4/Z_Endstop/nozzle_probe.stl` | `voron-2.4-standard` | 17570 | 85 | 359.2 | 646.1 | **1.80×** |
| 153 | `voron-2.4/Z_Idlers/[a]_z_tensioner_9mm_x4.stl` | `voron-2.4-standard` | 27196 | 90 | 176.4 | 622.6 | **3.53×** |
| 154 | `voron-2.4/Z_Idlers/z_tensioner_bracket_a_x2.stl` | `voron-2.4-standard` | 13454 | 130 | 212.7 | 454.9 | **2.14×** |
| 155 | `voron-2.4/Z_Idlers/z_tensioner_bracket_b_x2.stl` | `voron-2.4-standard` | 13762 | 130 | 206.5 | 471.4 | **2.28×** |
