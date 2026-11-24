# Voron 2.4 Full-Printer Slicing Benchmark (`hw_slicer` vs. OrcaSlicer 2.5.1)

End-to-end CLI wall-clock timings for all 155 models in suite `voron2.4` (`runs=1`, matched Klipper 350 mm machine, ABS filament, `voron-2.4-standard` 0.20 mm / 0.40 mm / 4 walls / 5 top & bottom / 40% gyroid, and `voron-2.4-high-stress` 5 walls / 8 top & bottom / 50% gyroid for front idlers).

## Summary

| Metric | Value |
|---|---:|
| Models sliced | 155/155 |
| `hw_slicer` total wall time | **39.04 s** (251.8 ms avg) |
| OrcaSlicer 2.5.1 total wall time | **72.90 s** (470.3 ms avg) |
| Overall wall-time speedup (`Orca / hw`) | **1.87×** |
| Geometric mean speedup | **2.14×** |
| Median speedup | **1.95×** |
| Parts where `hw_slicer` is faster | **155/155** |

## Per-Part Comparison

| # | Part | Profile | Tris | Layers | `hw_slicer` (ms) | OrcaSlicer 2.5.1 (ms) | Speedup (`Orca / hw`) |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `voron-2.4/Electronics_Bay/Controller_Mounts/BIGDIPPER_bracket_set.stl` | `voron-2.4-standard` | 31472 | 35 | 330.4 | 592.1 | **1.79×** |
| 2 | `voron-2.4/Electronics_Bay/Controller_Mounts/BTT_MOT_EXP_bracket.stl` | `voron-2.4-standard` | 23340 | 35 | 154.9 | 311.5 | **2.01×** |
| 3 | `voron-2.4/Electronics_Bay/Controller_Mounts/Duet2_Duet3Mini5_bracket_set.stl` | `voron-2.4-standard` | 29448 | 35 | 193.1 | 397.8 | **2.06×** |
| 4 | `voron-2.4/Electronics_Bay/Controller_Mounts/GTR_bracket_set.stl` | `voron-2.4-standard` | 28420 | 35 | 194.0 | 385.4 | **1.99×** |
| 5 | `voron-2.4/Electronics_Bay/Controller_Mounts/Octopus_bracket_set.stl` | `voron-2.4-standard` | 32524 | 35 | 233.6 | 406.8 | **1.74×** |
| 6 | `voron-2.4/Electronics_Bay/Controller_Mounts/S6_bracket_set.stl` | `voron-2.4-standard` | 30592 | 35 | 227.0 | 427.9 | **1.88×** |
| 7 | `voron-2.4/Electronics_Bay/Controller_Mounts/SKR_Pro_bracket_set.stl` | `voron-2.4-standard` | 31736 | 35 | 224.4 | 419.6 | **1.87×** |
| 8 | `voron-2.4/Electronics_Bay/Controller_Mounts/SKR_bracket_inline_set.stl` | `voron-2.4-standard` | 29580 | 35 | 324.2 | 406.0 | **1.25×** |
| 9 | `voron-2.4/Electronics_Bay/Controller_Mounts/Spider_bracket_set.stl` | `voron-2.4-standard` | 36016 | 45 | 243.2 | 418.2 | **1.72×** |
| 10 | `voron-2.4/Electronics_Bay/Other_PS_Mounts/UHP_200_Mount_x2.stl` | `voron-2.4-standard` | 2792 | 40 | 32.4 | 229.7 | **7.10×** |
| 11 | `voron-2.4/Electronics_Bay/Other_PS_Mounts/UHP_350_Mount_x2.stl` | `voron-2.4-standard` | 2756 | 40 | 32.1 | 236.7 | **7.38×** |
| 12 | `voron-2.4/Electronics_Bay/PSU_stabilizer_50mm.stl` | `voron-2.4-standard` | 8384 | 75 | 68.3 | 208.2 | **3.05×** |
| 13 | `voron-2.4/Electronics_Bay/lrs_200_psu_bracket_x2.stl` | `voron-2.4-standard` | 5244 | 70 | 44.9 | 297.8 | **6.63×** |
| 14 | `voron-2.4/Electronics_Bay/pcb_din_clip_x3.stl` | `voron-2.4-standard` | 1308 | 50 | 24.1 | 184.0 | **7.63×** |
| 15 | `voron-2.4/Electronics_Bay/raspberrypi_bracket.stl` | `voron-2.4-standard` | 22458 | 35 | 139.4 | 270.4 | **1.94×** |
| 16 | `voron-2.4/Electronics_Bay/rs25_psu_bracket.stl` | `voron-2.4-standard` | 4130 | 50 | 36.3 | 257.8 | **7.10×** |
| 17 | `voron-2.4/Electronics_Bay/wago_221-415_mount_3by5.stl` | `voron-2.4-standard` | 1452 | 61 | 36.1 | 177.9 | **4.92×** |
| 18 | `voron-2.4/Exhaust_Filter/[a]_exhaust_fan_grill.stl` | `voron-2.4-standard` | 5642 | 16 | 208.6 | 276.4 | **1.33×** |
| 19 | `voron-2.4/Exhaust_Filter/[a]_exhaust_filter_mount_x2.stl` | `voron-2.4-standard` | 1636 | 20 | 39.0 | 114.6 | **2.94×** |
| 20 | `voron-2.4/Exhaust_Filter/[a]_filter_access_cover.stl` | `voron-2.4-standard` | 6808 | 36 | 156.2 | 233.0 | **1.49×** |
| 21 | `voron-2.4/Exhaust_Filter/exhaust_filter_grill.stl` | `voron-2.4-standard` | 4840 | 28 | 161.8 | 352.9 | **2.18×** |
| 22 | `voron-2.4/Exhaust_Filter/exhaust_filter_housing.stl` | `voron-2.4-standard` | 43928 | 225 | 646.5 | 1094.2 | **1.69×** |
| 23 | `voron-2.4/Gantry/AB_Drive_Units/[a]_cable_cover.stl` | `voron-2.4-standard` | 9390 | 170 | 325.5 | 384.6 | **1.18×** |
| 24 | `voron-2.4/Gantry/AB_Drive_Units/[a]_z_chain_retainer_bracket_x2.stl` | `voron-2.4-standard` | 3566 | 25 | 35.2 | 156.0 | **4.43×** |
| 25 | `voron-2.4/Gantry/AB_Drive_Units/a_drive_frame_lower.stl` | `voron-2.4-standard` | 35520 | 85 | 525.8 | 757.6 | **1.44×** |
| 26 | `voron-2.4/Gantry/AB_Drive_Units/a_drive_frame_upper.stl` | `voron-2.4-standard` | 21786 | 75 | 605.4 | 754.3 | **1.25×** |
| 27 | `voron-2.4/Gantry/AB_Drive_Units/b_drive_frame_lower.stl` | `voron-2.4-standard` | 34126 | 85 | 451.1 | 703.0 | **1.56×** |
| 28 | `voron-2.4/Gantry/AB_Drive_Units/b_drive_frame_upper.stl` | `voron-2.4-standard` | 17836 | 75 | 513.6 | 733.7 | **1.43×** |
| 29 | `voron-2.4/Gantry/Front_Idlers/[a]_tensioner_left.stl` | `voron-2.4-standard` | 6556 | 90 | 128.0 | 250.1 | **1.95×** |
| 30 | `voron-2.4/Gantry/Front_Idlers/[a]_tensioner_right.stl` | `voron-2.4-standard` | 6568 | 90 | 146.3 | 247.5 | **1.69×** |
| 31 | `voron-2.4/Gantry/Front_Idlers/front_idler_left_lower.stl` | `voron-2.4-high-stress` | 11174 | 58 | 222.6 | 296.0 | **1.33×** |
| 32 | `voron-2.4/Gantry/Front_Idlers/front_idler_left_upper.stl` | `voron-2.4-high-stress` | 10584 | 108 | 409.7 | 444.8 | **1.09×** |
| 33 | `voron-2.4/Gantry/Front_Idlers/front_idler_right_lower.stl` | `voron-2.4-high-stress` | 10582 | 108 | 302.0 | 414.8 | **1.37×** |
| 34 | `voron-2.4/Gantry/Front_Idlers/front_idler_right_upper.stl` | `voron-2.4-high-stress` | 11246 | 60 | 229.2 | 319.1 | **1.39×** |
| 35 | `voron-2.4/Gantry/X_Axis/XY_Joints/[a]_endstop_pod_D2F_switch.stl` | `voron-2.4-standard` | 13174 | 70 | 267.9 | 449.8 | **1.68×** |
| 36 | `voron-2.4/Gantry/X_Axis/XY_Joints/[a]_endstop_pod_hall_effect.stl` | `voron-2.4-standard` | 21240 | 70 | 276.5 | 389.9 | **1.41×** |
| 37 | `voron-2.4/Gantry/X_Axis/XY_Joints/[a]_xy_joint_cable_bridge_2hole.stl` | `voron-2.4-standard` | 12156 | 105 | 173.9 | 325.1 | **1.87×** |
| 38 | `voron-2.4/Gantry/X_Axis/XY_Joints/[a]_xy_joint_cable_bridge_3hole.stl` | `voron-2.4-standard` | 12356 | 105 | 180.2 | 335.6 | **1.86×** |
| 39 | `voron-2.4/Gantry/X_Axis/XY_Joints/xy_joint_left_lower_MGN12.stl` | `voron-2.4-standard` | 24544 | 170 | 536.1 | 933.0 | **1.74×** |
| 40 | `voron-2.4/Gantry/X_Axis/XY_Joints/xy_joint_left_upper_MGN12.stl` | `voron-2.4-standard` | 19014 | 80 | 427.6 | 554.4 | **1.30×** |
| 41 | `voron-2.4/Gantry/X_Axis/XY_Joints/xy_joint_right_lower_MGN12.stl` | `voron-2.4-standard` | 29488 | 170 | 628.6 | 991.2 | **1.58×** |
| 42 | `voron-2.4/Gantry/X_Axis/XY_Joints/xy_joint_right_upper_MGN12.stl` | `voron-2.4-standard` | 15090 | 80 | 399.1 | 536.5 | **1.34×** |
| 43 | `voron-2.4/Gantry/X_Axis/X_Carriage/pinda_adapter.stl` | `voron-2.4-standard` | 24274 | 140 | 230.7 | 512.3 | **2.22×** |
| 44 | `voron-2.4/Gantry/X_Axis/X_Carriage/probe_retainer_bracket.stl` | `voron-2.4-standard` | 6064 | 20 | 66.8 | 169.5 | **2.54×** |
| 45 | `voron-2.4/Gantry/X_Axis/X_Carriage/probe_retainer_bracket_9mm.stl` | `voron-2.4-standard` | 6196 | 20 | 43.2 | 177.5 | **4.11×** |
| 46 | `voron-2.4/Gantry/X_Axis/X_Carriage/x_frame_V2TR_MGN12_left.stl` | `voron-2.4-standard` | 13070 | 108 | 356.1 | 586.9 | **1.65×** |
| 47 | `voron-2.4/Gantry/X_Axis/X_Carriage/x_frame_V2TR_MGN12_right.stl` | `voron-2.4-standard` | 19409 | 108 | 321.8 | 657.4 | **2.04×** |
| 48 | `voron-2.4/Gantry/Z_Joints/z_joint_lower_x4.stl` | `voron-2.4-standard` | 31724 | 120 | 303.2 | 531.2 | **1.75×** |
| 49 | `voron-2.4/Gantry/Z_Joints/z_joint_upper_hall_effect.stl` | `voron-2.4-standard` | 26708 | 102 | 329.0 | 424.0 | **1.29×** |
| 50 | `voron-2.4/Gantry/Z_Joints/z_joint_upper_x4.stl` | `voron-2.4-standard` | 26442 | 102 | 322.1 | 412.8 | **1.28×** |
| 51 | `voron-2.4/Gantry/[a]_z_belt_clip_lower_x4.stl` | `voron-2.4-standard` | 2706 | 28 | 79.7 | 143.6 | **1.80×** |
| 52 | `voron-2.4/Gantry/[a]_z_belt_clip_upper_x4.stl` | `voron-2.4-standard` | 2236 | 26 | 89.6 | 151.4 | **1.69×** |
| 53 | `voron-2.4/Gantry/z_chain_bottom_anchor.stl` | `voron-2.4-standard` | 9616 | 75 | 136.3 | 301.9 | **2.21×** |
| 54 | `voron-2.4/Gantry/z_chain_guide.stl` | `voron-2.4-standard` | 17564 | 105 | 173.2 | 385.7 | **2.23×** |
| 55 | `voron-2.4/Panel_Mounting/Front_Doors/door_hinge_x6.stl` | `voron-2.4-standard` | 19900 | 65 | 152.0 | 328.8 | **2.16×** |
| 56 | `voron-2.4/Panel_Mounting/Front_Doors/handle_a_x2.stl` | `voron-2.4-standard` | 4400 | 35 | 65.3 | 187.7 | **2.87×** |
| 57 | `voron-2.4/Panel_Mounting/Front_Doors/handle_b_x2.stl` | `voron-2.4-standard` | 4400 | 35 | 66.5 | 189.1 | **2.84×** |
| 58 | `voron-2.4/Panel_Mounting/Front_Doors/latch_x2.stl` | `voron-2.4-standard` | 2546 | 65 | 89.0 | 177.8 | **2.00×** |
| 59 | `voron-2.4/Panel_Mounting/bottom_panel_clip_x4.stl` | `voron-2.4-standard` | 1384 | 30 | 57.8 | 142.7 | **2.47×** |
| 60 | `voron-2.4/Panel_Mounting/bottom_panel_hinge_x2.stl` | `voron-2.4-standard` | 11032 | 30 | 103.0 | 280.3 | **2.72×** |
| 61 | `voron-2.4/Panel_Mounting/corner_panel_clip_4mm_x8.stl` | `voron-2.4-standard` | 6994 | 35 | 152.9 | 262.0 | **1.71×** |
| 62 | `voron-2.4/Panel_Mounting/corner_panel_clip_6mm_x8.stl` | `voron-2.4-standard` | 7884 | 50 | 172.2 | 307.0 | **1.78×** |
| 63 | `voron-2.4/Panel_Mounting/deck_support_3mm_x8.stl` | `voron-2.4-standard` | 2498 | 29 | 51.0 | 167.2 | **3.28×** |
| 64 | `voron-2.4/Panel_Mounting/deck_support_4mm_x8.stl` | `voron-2.4-standard` | 2544 | 29 | 49.0 | 167.1 | **3.41×** |
| 65 | `voron-2.4/Panel_Mounting/midspan_panel_clip_4mm_x7.stl` | `voron-2.4-standard` | 5978 | 35 | 80.7 | 247.2 | **3.07×** |
| 66 | `voron-2.4/Panel_Mounting/midspan_panel_clip_6mm_x8.stl` | `voron-2.4-standard` | 6536 | 50 | 90.2 | 295.1 | **3.27×** |
| 67 | `voron-2.4/Panel_Mounting/z_belt_cover_a_x2.stl` | `voron-2.4-standard` | 13566 | 33 | 83.5 | 215.4 | **2.58×** |
| 68 | `voron-2.4/Panel_Mounting/z_belt_cover_b_x2.stl` | `voron-2.4-standard` | 13566 | 33 | 86.5 | 219.4 | **2.54×** |
| 69 | `voron-2.4/Skirts/250/front_skirt_a_250.stl` | `voron-2.4-standard` | 14888 | 100 | 473.1 | 825.2 | **1.74×** |
| 70 | `voron-2.4/Skirts/250/front_skirt_b_250.stl` | `voron-2.4-standard` | 14888 | 100 | 476.2 | 821.9 | **1.73×** |
| 71 | `voron-2.4/Skirts/250/rear_center_skirt_250.stl` | `voron-2.4-standard` | 7068 | 100 | 296.4 | 578.8 | **1.95×** |
| 72 | `voron-2.4/Skirts/250/side_skirt_a_250_x2.stl` | `voron-2.4-standard` | 10004 | 100 | 422.1 | 604.7 | **1.43×** |
| 73 | `voron-2.4/Skirts/250/side_skirt_b_250_x2.stl` | `voron-2.4-standard` | 10004 | 100 | 431.9 | 630.7 | **1.46×** |
| 74 | `voron-2.4/Skirts/300/front_skirt_a_300.stl` | `voron-2.4-standard` | 15464 | 100 | 539.0 | 989.8 | **1.84×** |
| 75 | `voron-2.4/Skirts/300/front_skirt_b_300.stl` | `voron-2.4-standard` | 15464 | 100 | 523.9 | 1003.9 | **1.92×** |
| 76 | `voron-2.4/Skirts/300/rear_center_skirt_300.stl` | `voron-2.4-standard` | 8430 | 100 | 518.3 | 917.2 | **1.77×** |
| 77 | `voron-2.4/Skirts/300/side_skirt_a_300_x2.stl` | `voron-2.4-standard` | 10762 | 100 | 535.1 | 750.3 | **1.40×** |
| 78 | `voron-2.4/Skirts/300/side_skirt_b_300_x2.stl` | `voron-2.4-standard` | 10762 | 100 | 529.1 | 768.7 | **1.45×** |
| 79 | `voron-2.4/Skirts/350/front_skirt_a_350.stl` | `voron-2.4-standard` | 16018 | 100 | 560.9 | 1136.6 | **2.03×** |
| 80 | `voron-2.4/Skirts/350/front_skirt_b_350.stl` | `voron-2.4-standard` | 16008 | 100 | 591.9 | 1131.6 | **1.91×** |
| 81 | `voron-2.4/Skirts/350/rear_center_skirt_350.stl` | `voron-2.4-standard` | 9468 | 100 | 631.2 | 1298.2 | **2.06×** |
| 82 | `voron-2.4/Skirts/350/side_skirt_a_350_x2.stl` | `voron-2.4-standard` | 11276 | 100 | 570.1 | 1090.3 | **1.91×** |
| 83 | `voron-2.4/Skirts/350/side_skirt_b_350_x2.stl` | `voron-2.4-standard` | 11276 | 100 | 689.7 | 1194.0 | **1.73×** |
| 84 | `voron-2.4/Skirts/[a]_belt_guard_a_x2.stl` | `voron-2.4-standard` | 12102 | 41 | 168.7 | 421.7 | **2.50×** |
| 85 | `voron-2.4/Skirts/[a]_belt_guard_b_x2.stl` | `voron-2.4-standard` | 12102 | 41 | 177.4 | 374.3 | **2.11×** |
| 86 | `voron-2.4/Skirts/[a]_btt_knob_light_shield.stl` | `voron-2.4-standard` | 14688 | 13 | 85.1 | 237.2 | **2.79×** |
| 87 | `voron-2.4/Skirts/[a]_fan_grill_a_x2.stl` | `voron-2.4-standard` | 6084 | 16 | 184.5 | 279.7 | **1.52×** |
| 88 | `voron-2.4/Skirts/[a]_fan_grill_b_x2.stl` | `voron-2.4-standard` | 6084 | 16 | 197.8 | 286.4 | **1.45×** |
| 89 | `voron-2.4/Skirts/[a]_fan_grill_open_optional_x2.stl` | `voron-2.4-standard` | 2508 | 16 | 171.1 | 208.8 | **1.22×** |
| 90 | `voron-2.4/Skirts/[a]_fan_grill_retainer_x2.stl` | `voron-2.4-standard` | 6142 | 25 | 153.4 | 268.5 | **1.75×** |
| 91 | `voron-2.4/Skirts/[a]_keystone_blank_insert.stl` | `voron-2.4-standard` | 2768 | 74 | 118.5 | 185.8 | **1.57×** |
| 92 | `voron-2.4/Skirts/[a]_mini12864_case_front_insert.stl` | `voron-2.4-standard` | 24914 | 34 | 231.8 | 488.0 | **2.10×** |
| 93 | `voron-2.4/Skirts/[a]_mini12864_case_hinge.stl` | `voron-2.4-standard` | 11456 | 164 | 353.4 | 657.8 | **1.86×** |
| 94 | `voron-2.4/Skirts/keystone_panel.stl` | `voron-2.4-standard` | 13996 | 100 | 534.1 | 979.8 | **1.83×** |
| 95 | `voron-2.4/Skirts/mini12864_case_front.stl` | `voron-2.4-standard` | 14972 | 95 | 182.9 | 470.3 | **2.57×** |
| 96 | `voron-2.4/Skirts/mini12864_case_rear.stl` | `voron-2.4-standard` | 18470 | 58 | 250.4 | 464.1 | **1.85×** |
| 97 | `voron-2.4/Skirts/power_inlet_IECGS_1.2mm.stl` | `voron-2.4-standard` | 15924 | 100 | 467.4 | 889.6 | **1.90×** |
| 98 | `voron-2.4/Skirts/power_inlet_IECGS_1mm.stl` | `voron-2.4-standard` | 15502 | 100 | 454.2 | 903.2 | **1.99×** |
| 99 | `voron-2.4/Skirts/power_inlet_filtered.stl` | `voron-2.4-standard` | 17478 | 100 | 478.2 | 956.3 | **2.00×** |
| 100 | `voron-2.4/Skirts/side_fan_support_x2.STL` | `voron-2.4-standard` | 19334 | 100 | 455.6 | 647.0 | **1.42×** |
| 101 | `voron-2.4/Spool_Management/bowden_retainer.stl` | `voron-2.4-standard` | 6228 | 50 | 105.2 | 279.0 | **2.65×** |
| 102 | `voron-2.4/Spool_Management/spool_holder.stl` | `voron-2.4-standard` | 8772 | 65 | 278.1 | 458.3 | **1.65×** |
| 103 | `voron-2.4/Superceded_Parts/Frame_Brackets/dual_ramps_bracket_frame.stl` | `voron-2.4-standard` | 4056 | 64 | 279.7 | 479.9 | **1.72×** |
| 104 | `voron-2.4/Superceded_Parts/Frame_Brackets/duet_duex_bracket_frame_x2.stl` | `voron-2.4-standard` | 44732 | 64 | 345.1 | 409.1 | **1.19×** |
| 105 | `voron-2.4/Superceded_Parts/Frame_Brackets/lrs_bracket_frame.stl` | `voron-2.4-standard` | 4662 | 100 | 121.3 | 306.6 | **2.53×** |
| 106 | `voron-2.4/Superceded_Parts/Frame_Brackets/mks_gen_1.4_bracket_frame_x2.stl` | `voron-2.4-standard` | 60224 | 64 | 340.8 | 487.7 | **1.43×** |
| 107 | `voron-2.4/Superceded_Parts/Frame_Brackets/mks_gen_L_bracket_frame_x2.stl` | `voron-2.4-standard` | 60680 | 64 | 305.2 | 493.9 | **1.62×** |
| 108 | `voron-2.4/Superceded_Parts/Frame_Brackets/raspberry_pi_bracket.stl` | `voron-2.4-standard` | 3494 | 63 | 161.3 | 416.1 | **2.58×** |
| 109 | `voron-2.4/Superceded_Parts/Frame_Brackets/rs_25_psu_bracket_frame.stl` | `voron-2.4-standard` | 3146 | 64 | 79.0 | 291.1 | **3.68×** |
| 110 | `voron-2.4/Superceded_Parts/Frame_Brackets/rs_35_bracket_frame.stl` | `voron-2.4-standard` | 3146 | 64 | 80.2 | 291.6 | **3.63×** |
| 111 | `voron-2.4/Superceded_Parts/Frame_Brackets/skr_1.3_bracket_frame.stl` | `voron-2.4-standard` | 44486 | 64 | 334.6 | 400.5 | **1.20×** |
| 112 | `voron-2.4/Superceded_Parts/Frame_Brackets/skr_mini_e3_bracket_frame.stl` | `voron-2.4-standard` | 37988 | 64 | 210.1 | 351.4 | **1.67×** |
| 113 | `voron-2.4/Superceded_Parts/MGN9_X/[a]_belt_clamp_MGN9_x2.stl` | `voron-2.4-standard` | 14932 | 31 | 49.2 | 336.9 | **6.85×** |
| 114 | `voron-2.4/Superceded_Parts/MGN9_X/x_carriage_frame_left_MGN9.stl` | `voron-2.4-standard` | 25548 | 110 | 503.5 | 753.1 | **1.50×** |
| 115 | `voron-2.4/Superceded_Parts/MGN9_X/x_carriage_frame_right_MGN9.stl` | `voron-2.4-standard` | 24934 | 100 | 436.7 | 757.2 | **1.73×** |
| 116 | `voron-2.4/Superceded_Parts/MGN9_X/x_carriage_pivot_block_MGN9.stl` | `voron-2.4-standard` | 13488 | 70 | 135.7 | 308.5 | **2.27×** |
| 117 | `voron-2.4/Superceded_Parts/MGN9_X/xy_joint_left_lower_MGN9.stl` | `voron-2.4-standard` | 9878 | 170 | 418.7 | 935.3 | **2.23×** |
| 118 | `voron-2.4/Superceded_Parts/MGN9_X/xy_joint_left_upper_MGN9.stl` | `voron-2.4-standard` | 20144 | 80 | 391.7 | 562.4 | **1.44×** |
| 119 | `voron-2.4/Superceded_Parts/MGN9_X/xy_joint_right_lower_MGN9.stl` | `voron-2.4-standard` | 30776 | 170 | 729.7 | 1088.8 | **1.49×** |
| 120 | `voron-2.4/Superceded_Parts/MGN9_X/xy_joint_right_upper_MGN9.stl` | `voron-2.4-standard` | 7052 | 80 | 217.9 | 478.5 | **2.20×** |
| 121 | `voron-2.4/Superceded_Parts/ZipChain/XY/zipchain2_xy_end.stl` | `voron-2.4-standard` | 11348 | 50 | 82.6 | 271.8 | **3.29×** |
| 122 | `voron-2.4/Superceded_Parts/ZipChain/XY/zipchain2_xy_link_a.stl` | `voron-2.4-standard` | 9080 | 50 | 129.2 | 288.5 | **2.23×** |
| 123 | `voron-2.4/Superceded_Parts/ZipChain/XY/zipchain2_xy_link_b.stl` | `voron-2.4-standard` | 13076 | 47 | 103.8 | 311.9 | **3.00×** |
| 124 | `voron-2.4/Superceded_Parts/ZipChain/Z/zipchain2_z_end.stl` | `voron-2.4-standard` | 11104 | 50 | 84.1 | 264.2 | **3.14×** |
| 125 | `voron-2.4/Superceded_Parts/ZipChain/Z/zipchain2_z_link_a.stl` | `voron-2.4-standard` | 10112 | 50 | 147.7 | 300.8 | **2.04×** |
| 126 | `voron-2.4/Superceded_Parts/ZipChain/Z/zipchain2_z_link_b.stl` | `voron-2.4-standard` | 16228 | 47 | 121.7 | 325.5 | **2.67×** |
| 127 | `voron-2.4/Superceded_Parts/ZipChain/Z/zipchain2_z_link_b_locking.stl` | `voron-2.4-standard` | 24712 | 47 | 142.9 | 342.2 | **2.39×** |
| 128 | `voron-2.4/Superceded_Parts/[a]_stopgap_80T_hubbed_gear.stl` | `voron-2.4-standard` | 47178 | 57 | 793.2 | 1033.2 | **1.30×** |
| 129 | `voron-2.4/Superceded_Parts/[a]_z_tensioner_x4_6mm.stl` | `voron-2.4-standard` | 26782 | 90 | 156.5 | 645.5 | **4.12×** |
| 130 | `voron-2.4/Test_Prints/Filament_Card.stl` | `voron-2.4-standard` | 802 | 10 | 29.0 | 128.4 | **4.43×** |
| 131 | `voron-2.4/Test_Prints/Filament_Card_Caddy_25.stl` | `voron-2.4-standard` | 1260 | 100 | 74.9 | 381.6 | **5.09×** |
| 132 | `voron-2.4/Test_Prints/Heatset_Practice.stl` | `voron-2.4-standard` | 7472 | 50 | 110.5 | 252.1 | **2.28×** |
| 133 | `voron-2.4/Test_Prints/Thread_Test_1_x1_Rev1.STL` | `voron-2.4-standard` | 79822 | 80 | 247.2 | 484.0 | **1.96×** |
| 134 | `voron-2.4/Test_Prints/Thread_Test_2_x1_Rev1.STL` | `voron-2.4-standard` | 23656 | 80 | 225.3 | 443.2 | **1.97×** |
| 135 | `voron-2.4/Test_Prints/Thread_Test_3_x1_Rev1.STL` | `voron-2.4-standard` | 19318 | 53 | 132.7 | 373.9 | **2.82×** |
| 136 | `voron-2.4/Test_Prints/Voron_Design_Cube_v7.stl` | `voron-2.4-standard` | 3414 | 150 | 192.1 | 465.1 | **2.42×** |
| 137 | `voron-2.4/Tools/MGN12_rail_guide_x2.stl` | `voron-2.4-standard` | 1216 | 40 | 35.1 | 110.2 | **3.14×** |
| 138 | `voron-2.4/Tools/MGN9_rail_guide_x2.stl` | `voron-2.4-standard` | 620 | 50 | 39.5 | 104.8 | **2.65×** |
| 139 | `voron-2.4/Tools/bed_hole_marking_template_x1_Rev2.STL` | `voron-2.4-standard` | 876 | 50 | 33.6 | 131.0 | **3.90×** |
| 140 | `voron-2.4/Tools/bottom_panel_template.stl` | `voron-2.4-standard` | 2732 | 25 | 86.8 | 140.8 | **1.62×** |
| 141 | `voron-2.4/Tools/pulley_jig.stl` | `voron-2.4-standard` | 2620 | 16 | 32.0 | 132.9 | **4.15×** |
| 142 | `voron-2.4/Z_Drive/[a]_belt_tensioner_a_x2.stl` | `voron-2.4-standard` | 9252 | 44 | 62.4 | 154.1 | **2.47×** |
| 143 | `voron-2.4/Z_Drive/[a]_belt_tensioner_b_x2.stl` | `voron-2.4-standard` | 9252 | 44 | 63.5 | 151.2 | **2.38×** |
| 144 | `voron-2.4/Z_Drive/[a]_z_drive_baseplate_a_x2.stl` | `voron-2.4-standard` | 10084 | 50 | 199.6 | 370.0 | **1.85×** |
| 145 | `voron-2.4/Z_Drive/[a]_z_drive_baseplate_b_x2.stl` | `voron-2.4-standard` | 10084 | 50 | 195.4 | 368.0 | **1.88×** |
| 146 | `voron-2.4/Z_Drive/z_drive_main_a_x2.stl` | `voron-2.4-standard` | 23308 | 134 | 587.6 | 1188.1 | **2.02×** |
| 147 | `voron-2.4/Z_Drive/z_drive_main_b_x2.stl` | `voron-2.4-standard` | 23308 | 134 | 650.6 | 1324.8 | **2.04×** |
| 148 | `voron-2.4/Z_Drive/z_drive_retainer_a_x2.stl` | `voron-2.4-standard` | 16792 | 81 | 381.3 | 681.0 | **1.79×** |
| 149 | `voron-2.4/Z_Drive/z_drive_retainer_b_x2.stl` | `voron-2.4-standard` | 16792 | 81 | 341.0 | 651.2 | **1.91×** |
| 150 | `voron-2.4/Z_Drive/z_motor_mount_a_x2.stl` | `voron-2.4-standard` | 21424 | 210 | 185.0 | 460.6 | **2.49×** |
| 151 | `voron-2.4/Z_Drive/z_motor_mount_b_x2.stl` | `voron-2.4-standard` | 21424 | 210 | 185.9 | 472.4 | **2.54×** |
| 152 | `voron-2.4/Z_Endstop/nozzle_probe.stl` | `voron-2.4-standard` | 17570 | 85 | 352.8 | 660.9 | **1.87×** |
| 153 | `voron-2.4/Z_Idlers/[a]_z_tensioner_9mm_x4.stl` | `voron-2.4-standard` | 27196 | 90 | 164.5 | 631.6 | **3.84×** |
| 154 | `voron-2.4/Z_Idlers/z_tensioner_bracket_a_x2.stl` | `voron-2.4-standard` | 13454 | 130 | 198.7 | 509.8 | **2.57×** |
| 155 | `voron-2.4/Z_Idlers/z_tensioner_bracket_b_x2.stl` | `voron-2.4-standard` | 13762 | 130 | 203.4 | 676.9 | **3.33×** |
