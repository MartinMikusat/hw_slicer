# Voron 2.4 Full-Printer Slicing Benchmark (`hw_slicer` vs. OrcaSlicer 2.5.1)

End-to-end CLI wall-clock timings for all 155 models in suite `voron2.4` (`runs=1`, matched Klipper 350 mm machine, ABS filament, `voron-2.4-standard` 0.20 mm / 0.40 mm / 4 walls / 5 top & bottom / 40% gyroid, and `voron-2.4-high-stress` 5 walls / 8 top & bottom / 50% gyroid for front idlers).

## Summary

| Metric | Value |
|---|---:|
| Models sliced | 155/155 |
| `hw_slicer` total wall time | **44.78 s** (288.9 ms avg) |
| OrcaSlicer 2.5.1 total wall time | **70.68 s** (456.0 ms avg) |
| Overall wall-time speedup (`Orca / hw`) | **1.58×** |
| Geometric mean speedup | **1.85×** |
| Median speedup | **1.70×** |
| Parts where `hw_slicer` is faster | **152/155** |

## Per-Part Comparison

| # | Part | Profile | Tris | Layers | `hw_slicer` (ms) | OrcaSlicer 2.5.1 (ms) | Speedup (`Orca / hw`) |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `voron-2.4/Electronics_Bay/Controller_Mounts/BIGDIPPER_bracket_set.stl` | `voron-2.4-standard` | 31472 | 35 | 563.6 | 412.9 | **0.73×** |
| 2 | `voron-2.4/Electronics_Bay/Controller_Mounts/BTT_MOT_EXP_bracket.stl` | `voron-2.4-standard` | 23340 | 35 | 181.0 | 295.3 | **1.63×** |
| 3 | `voron-2.4/Electronics_Bay/Controller_Mounts/Duet2_Duet3Mini5_bracket_set.stl` | `voron-2.4-standard` | 29448 | 35 | 221.3 | 389.9 | **1.76×** |
| 4 | `voron-2.4/Electronics_Bay/Controller_Mounts/GTR_bracket_set.stl` | `voron-2.4-standard` | 28420 | 35 | 236.4 | 379.2 | **1.60×** |
| 5 | `voron-2.4/Electronics_Bay/Controller_Mounts/Octopus_bracket_set.stl` | `voron-2.4-standard` | 32524 | 35 | 289.9 | 399.6 | **1.38×** |
| 6 | `voron-2.4/Electronics_Bay/Controller_Mounts/S6_bracket_set.stl` | `voron-2.4-standard` | 30592 | 35 | 273.8 | 415.0 | **1.52×** |
| 7 | `voron-2.4/Electronics_Bay/Controller_Mounts/SKR_Pro_bracket_set.stl` | `voron-2.4-standard` | 31736 | 35 | 278.2 | 413.3 | **1.49×** |
| 8 | `voron-2.4/Electronics_Bay/Controller_Mounts/SKR_bracket_inline_set.stl` | `voron-2.4-standard` | 29580 | 35 | 385.2 | 398.8 | **1.04×** |
| 9 | `voron-2.4/Electronics_Bay/Controller_Mounts/Spider_bracket_set.stl` | `voron-2.4-standard` | 36016 | 45 | 295.6 | 410.2 | **1.39×** |
| 10 | `voron-2.4/Electronics_Bay/Other_PS_Mounts/UHP_200_Mount_x2.stl` | `voron-2.4-standard` | 2792 | 40 | 35.3 | 230.2 | **6.53×** |
| 11 | `voron-2.4/Electronics_Bay/Other_PS_Mounts/UHP_350_Mount_x2.stl` | `voron-2.4-standard` | 2756 | 40 | 35.8 | 234.8 | **6.57×** |
| 12 | `voron-2.4/Electronics_Bay/PSU_stabilizer_50mm.stl` | `voron-2.4-standard` | 8384 | 75 | 75.6 | 207.0 | **2.74×** |
| 13 | `voron-2.4/Electronics_Bay/lrs_200_psu_bracket_x2.stl` | `voron-2.4-standard` | 5244 | 70 | 48.9 | 294.6 | **6.03×** |
| 14 | `voron-2.4/Electronics_Bay/pcb_din_clip_x3.stl` | `voron-2.4-standard` | 1308 | 50 | 32.7 | 184.4 | **5.65×** |
| 15 | `voron-2.4/Electronics_Bay/raspberrypi_bracket.stl` | `voron-2.4-standard` | 22458 | 35 | 168.3 | 267.5 | **1.59×** |
| 16 | `voron-2.4/Electronics_Bay/rs25_psu_bracket.stl` | `voron-2.4-standard` | 4130 | 50 | 41.4 | 252.9 | **6.11×** |
| 17 | `voron-2.4/Electronics_Bay/wago_221-415_mount_3by5.stl` | `voron-2.4-standard` | 1452 | 61 | 37.0 | 176.2 | **4.77×** |
| 18 | `voron-2.4/Exhaust_Filter/[a]_exhaust_fan_grill.stl` | `voron-2.4-standard` | 5642 | 16 | 249.0 | 271.4 | **1.09×** |
| 19 | `voron-2.4/Exhaust_Filter/[a]_exhaust_filter_mount_x2.stl` | `voron-2.4-standard` | 1636 | 20 | 42.1 | 111.3 | **2.64×** |
| 20 | `voron-2.4/Exhaust_Filter/[a]_filter_access_cover.stl` | `voron-2.4-standard` | 6808 | 36 | 166.8 | 238.7 | **1.43×** |
| 21 | `voron-2.4/Exhaust_Filter/exhaust_filter_grill.stl` | `voron-2.4-standard` | 4840 | 28 | 217.6 | 346.0 | **1.59×** |
| 22 | `voron-2.4/Exhaust_Filter/exhaust_filter_housing.stl` | `voron-2.4-standard` | 43928 | 225 | 735.3 | 1081.9 | **1.47×** |
| 23 | `voron-2.4/Gantry/AB_Drive_Units/[a]_cable_cover.stl` | `voron-2.4-standard` | 9390 | 170 | 368.7 | 387.8 | **1.05×** |
| 24 | `voron-2.4/Gantry/AB_Drive_Units/[a]_z_chain_retainer_bracket_x2.stl` | `voron-2.4-standard` | 3566 | 25 | 39.2 | 170.2 | **4.34×** |
| 25 | `voron-2.4/Gantry/AB_Drive_Units/a_drive_frame_lower.stl` | `voron-2.4-standard` | 35520 | 85 | 605.6 | 734.2 | **1.21×** |
| 26 | `voron-2.4/Gantry/AB_Drive_Units/a_drive_frame_upper.stl` | `voron-2.4-standard` | 21786 | 75 | 719.6 | 766.3 | **1.06×** |
| 27 | `voron-2.4/Gantry/AB_Drive_Units/b_drive_frame_lower.stl` | `voron-2.4-standard` | 34126 | 85 | 522.3 | 691.3 | **1.32×** |
| 28 | `voron-2.4/Gantry/AB_Drive_Units/b_drive_frame_upper.stl` | `voron-2.4-standard` | 17836 | 75 | 659.9 | 721.9 | **1.09×** |
| 29 | `voron-2.4/Gantry/Front_Idlers/[a]_tensioner_left.stl` | `voron-2.4-standard` | 6556 | 90 | 138.7 | 264.9 | **1.91×** |
| 30 | `voron-2.4/Gantry/Front_Idlers/[a]_tensioner_right.stl` | `voron-2.4-standard` | 6568 | 90 | 162.8 | 250.9 | **1.54×** |
| 31 | `voron-2.4/Gantry/Front_Idlers/front_idler_left_lower.stl` | `voron-2.4-high-stress` | 11174 | 58 | 237.5 | 293.9 | **1.24×** |
| 32 | `voron-2.4/Gantry/Front_Idlers/front_idler_left_upper.stl` | `voron-2.4-high-stress` | 10584 | 108 | 446.2 | 441.9 | **0.99×** |
| 33 | `voron-2.4/Gantry/Front_Idlers/front_idler_right_lower.stl` | `voron-2.4-high-stress` | 10582 | 108 | 322.6 | 404.8 | **1.25×** |
| 34 | `voron-2.4/Gantry/Front_Idlers/front_idler_right_upper.stl` | `voron-2.4-high-stress` | 11246 | 60 | 238.6 | 306.4 | **1.28×** |
| 35 | `voron-2.4/Gantry/X_Axis/XY_Joints/[a]_endstop_pod_D2F_switch.stl` | `voron-2.4-standard` | 13174 | 70 | 318.9 | 426.9 | **1.34×** |
| 36 | `voron-2.4/Gantry/X_Axis/XY_Joints/[a]_endstop_pod_hall_effect.stl` | `voron-2.4-standard` | 21240 | 70 | 326.2 | 400.2 | **1.23×** |
| 37 | `voron-2.4/Gantry/X_Axis/XY_Joints/[a]_xy_joint_cable_bridge_2hole.stl` | `voron-2.4-standard` | 12156 | 105 | 184.5 | 321.1 | **1.74×** |
| 38 | `voron-2.4/Gantry/X_Axis/XY_Joints/[a]_xy_joint_cable_bridge_3hole.stl` | `voron-2.4-standard` | 12356 | 105 | 188.9 | 330.0 | **1.75×** |
| 39 | `voron-2.4/Gantry/X_Axis/XY_Joints/xy_joint_left_lower_MGN12.stl` | `voron-2.4-standard` | 24544 | 170 | 635.4 | 918.9 | **1.45×** |
| 40 | `voron-2.4/Gantry/X_Axis/XY_Joints/xy_joint_left_upper_MGN12.stl` | `voron-2.4-standard` | 19014 | 80 | 491.9 | 543.4 | **1.10×** |
| 41 | `voron-2.4/Gantry/X_Axis/XY_Joints/xy_joint_right_lower_MGN12.stl` | `voron-2.4-standard` | 29488 | 170 | 716.1 | 953.6 | **1.33×** |
| 42 | `voron-2.4/Gantry/X_Axis/XY_Joints/xy_joint_right_upper_MGN12.stl` | `voron-2.4-standard` | 15090 | 80 | 452.1 | 503.0 | **1.11×** |
| 43 | `voron-2.4/Gantry/X_Axis/X_Carriage/pinda_adapter.stl` | `voron-2.4-standard` | 24274 | 140 | 242.3 | 492.5 | **2.03×** |
| 44 | `voron-2.4/Gantry/X_Axis/X_Carriage/probe_retainer_bracket.stl` | `voron-2.4-standard` | 6064 | 20 | 81.4 | 166.6 | **2.05×** |
| 45 | `voron-2.4/Gantry/X_Axis/X_Carriage/probe_retainer_bracket_9mm.stl` | `voron-2.4-standard` | 6196 | 20 | 45.9 | 167.7 | **3.66×** |
| 46 | `voron-2.4/Gantry/X_Axis/X_Carriage/x_frame_V2TR_MGN12_left.stl` | `voron-2.4-standard` | 13070 | 108 | 397.7 | 565.9 | **1.42×** |
| 47 | `voron-2.4/Gantry/X_Axis/X_Carriage/x_frame_V2TR_MGN12_right.stl` | `voron-2.4-standard` | 19409 | 108 | 341.2 | 631.8 | **1.85×** |
| 48 | `voron-2.4/Gantry/Z_Joints/z_joint_lower_x4.stl` | `voron-2.4-standard` | 31724 | 120 | 360.4 | 522.7 | **1.45×** |
| 49 | `voron-2.4/Gantry/Z_Joints/z_joint_upper_hall_effect.stl` | `voron-2.4-standard` | 26708 | 102 | 372.0 | 401.8 | **1.08×** |
| 50 | `voron-2.4/Gantry/Z_Joints/z_joint_upper_x4.stl` | `voron-2.4-standard` | 26442 | 102 | 370.7 | 394.6 | **1.06×** |
| 51 | `voron-2.4/Gantry/[a]_z_belt_clip_lower_x4.stl` | `voron-2.4-standard` | 2706 | 28 | 83.2 | 139.5 | **1.68×** |
| 52 | `voron-2.4/Gantry/[a]_z_belt_clip_upper_x4.stl` | `voron-2.4-standard` | 2236 | 26 | 91.3 | 149.8 | **1.64×** |
| 53 | `voron-2.4/Gantry/z_chain_bottom_anchor.stl` | `voron-2.4-standard` | 9616 | 75 | 145.3 | 295.1 | **2.03×** |
| 54 | `voron-2.4/Gantry/z_chain_guide.stl` | `voron-2.4-standard` | 17564 | 105 | 186.0 | 362.7 | **1.95×** |
| 55 | `voron-2.4/Panel_Mounting/Front_Doors/door_hinge_x6.stl` | `voron-2.4-standard` | 19900 | 65 | 160.0 | 317.2 | **1.98×** |
| 56 | `voron-2.4/Panel_Mounting/Front_Doors/handle_a_x2.stl` | `voron-2.4-standard` | 4400 | 35 | 71.3 | 180.2 | **2.53×** |
| 57 | `voron-2.4/Panel_Mounting/Front_Doors/handle_b_x2.stl` | `voron-2.4-standard` | 4400 | 35 | 70.0 | 179.9 | **2.57×** |
| 58 | `voron-2.4/Panel_Mounting/Front_Doors/latch_x2.stl` | `voron-2.4-standard` | 2546 | 65 | 100.9 | 171.7 | **1.70×** |
| 59 | `voron-2.4/Panel_Mounting/bottom_panel_clip_x4.stl` | `voron-2.4-standard` | 1384 | 30 | 64.2 | 133.7 | **2.08×** |
| 60 | `voron-2.4/Panel_Mounting/bottom_panel_hinge_x2.stl` | `voron-2.4-standard` | 11032 | 30 | 106.6 | 273.8 | **2.57×** |
| 61 | `voron-2.4/Panel_Mounting/corner_panel_clip_4mm_x8.stl` | `voron-2.4-standard` | 6994 | 35 | 171.8 | 251.1 | **1.46×** |
| 62 | `voron-2.4/Panel_Mounting/corner_panel_clip_6mm_x8.stl` | `voron-2.4-standard` | 7884 | 50 | 196.7 | 314.3 | **1.60×** |
| 63 | `voron-2.4/Panel_Mounting/deck_support_3mm_x8.stl` | `voron-2.4-standard` | 2498 | 29 | 45.7 | 165.8 | **3.63×** |
| 64 | `voron-2.4/Panel_Mounting/deck_support_4mm_x8.stl` | `voron-2.4-standard` | 2544 | 29 | 50.2 | 163.5 | **3.26×** |
| 65 | `voron-2.4/Panel_Mounting/midspan_panel_clip_4mm_x7.stl` | `voron-2.4-standard` | 5978 | 35 | 86.8 | 239.1 | **2.76×** |
| 66 | `voron-2.4/Panel_Mounting/midspan_panel_clip_6mm_x8.stl` | `voron-2.4-standard` | 6536 | 50 | 98.3 | 288.3 | **2.93×** |
| 67 | `voron-2.4/Panel_Mounting/z_belt_cover_a_x2.stl` | `voron-2.4-standard` | 13566 | 33 | 91.6 | 208.0 | **2.27×** |
| 68 | `voron-2.4/Panel_Mounting/z_belt_cover_b_x2.stl` | `voron-2.4-standard` | 13566 | 33 | 90.9 | 206.4 | **2.27×** |
| 69 | `voron-2.4/Skirts/250/front_skirt_a_250.stl` | `voron-2.4-standard` | 14888 | 100 | 520.9 | 799.3 | **1.53×** |
| 70 | `voron-2.4/Skirts/250/front_skirt_b_250.stl` | `voron-2.4-standard` | 14888 | 100 | 527.6 | 801.9 | **1.52×** |
| 71 | `voron-2.4/Skirts/250/rear_center_skirt_250.stl` | `voron-2.4-standard` | 7068 | 100 | 326.0 | 565.3 | **1.73×** |
| 72 | `voron-2.4/Skirts/250/side_skirt_a_250_x2.stl` | `voron-2.4-standard` | 10004 | 100 | 502.7 | 596.5 | **1.19×** |
| 73 | `voron-2.4/Skirts/250/side_skirt_b_250_x2.stl` | `voron-2.4-standard` | 10004 | 100 | 500.9 | 594.7 | **1.19×** |
| 74 | `voron-2.4/Skirts/300/front_skirt_a_300.stl` | `voron-2.4-standard` | 15464 | 100 | 578.9 | 961.0 | **1.66×** |
| 75 | `voron-2.4/Skirts/300/front_skirt_b_300.stl` | `voron-2.4-standard` | 15464 | 100 | 567.2 | 949.2 | **1.67×** |
| 76 | `voron-2.4/Skirts/300/rear_center_skirt_300.stl` | `voron-2.4-standard` | 8430 | 100 | 563.3 | 900.0 | **1.60×** |
| 77 | `voron-2.4/Skirts/300/side_skirt_a_300_x2.stl` | `voron-2.4-standard` | 10762 | 100 | 626.6 | 719.4 | **1.15×** |
| 78 | `voron-2.4/Skirts/300/side_skirt_b_300_x2.stl` | `voron-2.4-standard` | 10762 | 100 | 666.5 | 755.8 | **1.13×** |
| 79 | `voron-2.4/Skirts/350/front_skirt_a_350.stl` | `voron-2.4-standard` | 16018 | 100 | 623.6 | 1095.1 | **1.76×** |
| 80 | `voron-2.4/Skirts/350/front_skirt_b_350.stl` | `voron-2.4-standard` | 16008 | 100 | 625.4 | 1100.2 | **1.76×** |
| 81 | `voron-2.4/Skirts/350/rear_center_skirt_350.stl` | `voron-2.4-standard` | 9468 | 100 | 676.5 | 1242.4 | **1.84×** |
| 82 | `voron-2.4/Skirts/350/side_skirt_a_350_x2.stl` | `voron-2.4-standard` | 11276 | 100 | 712.8 | 885.0 | **1.24×** |
| 83 | `voron-2.4/Skirts/350/side_skirt_b_350_x2.stl` | `voron-2.4-standard` | 11276 | 100 | 728.3 | 896.7 | **1.23×** |
| 84 | `voron-2.4/Skirts/[a]_belt_guard_a_x2.stl` | `voron-2.4-standard` | 12102 | 41 | 179.3 | 347.9 | **1.94×** |
| 85 | `voron-2.4/Skirts/[a]_belt_guard_b_x2.stl` | `voron-2.4-standard` | 12102 | 41 | 182.1 | 356.8 | **1.96×** |
| 86 | `voron-2.4/Skirts/[a]_btt_knob_light_shield.stl` | `voron-2.4-standard` | 14688 | 13 | 94.9 | 218.0 | **2.30×** |
| 87 | `voron-2.4/Skirts/[a]_fan_grill_a_x2.stl` | `voron-2.4-standard` | 6084 | 16 | 219.1 | 269.3 | **1.23×** |
| 88 | `voron-2.4/Skirts/[a]_fan_grill_b_x2.stl` | `voron-2.4-standard` | 6084 | 16 | 225.7 | 272.5 | **1.21×** |
| 89 | `voron-2.4/Skirts/[a]_fan_grill_open_optional_x2.stl` | `voron-2.4-standard` | 2508 | 16 | 188.5 | 200.9 | **1.07×** |
| 90 | `voron-2.4/Skirts/[a]_fan_grill_retainer_x2.stl` | `voron-2.4-standard` | 6142 | 25 | 165.4 | 255.3 | **1.54×** |
| 91 | `voron-2.4/Skirts/[a]_keystone_blank_insert.stl` | `voron-2.4-standard` | 2768 | 74 | 125.2 | 175.1 | **1.40×** |
| 92 | `voron-2.4/Skirts/[a]_mini12864_case_front_insert.stl` | `voron-2.4-standard` | 24914 | 34 | 233.8 | 456.4 | **1.95×** |
| 93 | `voron-2.4/Skirts/[a]_mini12864_case_hinge.stl` | `voron-2.4-standard` | 11456 | 164 | 376.0 | 634.6 | **1.69×** |
| 94 | `voron-2.4/Skirts/keystone_panel.stl` | `voron-2.4-standard` | 13996 | 100 | 617.1 | 1227.7 | **1.99×** |
| 95 | `voron-2.4/Skirts/mini12864_case_front.stl` | `voron-2.4-standard` | 14972 | 95 | 215.9 | 507.7 | **2.35×** |
| 96 | `voron-2.4/Skirts/mini12864_case_rear.stl` | `voron-2.4-standard` | 18470 | 58 | 403.8 | 525.4 | **1.30×** |
| 97 | `voron-2.4/Skirts/power_inlet_IECGS_1.2mm.stl` | `voron-2.4-standard` | 15924 | 100 | 589.1 | 898.3 | **1.52×** |
| 98 | `voron-2.4/Skirts/power_inlet_IECGS_1mm.stl` | `voron-2.4-standard` | 15502 | 100 | 514.2 | 868.2 | **1.69×** |
| 99 | `voron-2.4/Skirts/power_inlet_filtered.stl` | `voron-2.4-standard` | 17478 | 100 | 529.7 | 994.3 | **1.88×** |
| 100 | `voron-2.4/Skirts/side_fan_support_x2.STL` | `voron-2.4-standard` | 19334 | 100 | 538.0 | 646.3 | **1.20×** |
| 101 | `voron-2.4/Spool_Management/bowden_retainer.stl` | `voron-2.4-standard` | 6228 | 50 | 110.5 | 271.5 | **2.46×** |
| 102 | `voron-2.4/Spool_Management/spool_holder.stl` | `voron-2.4-standard` | 8772 | 65 | 313.2 | 449.2 | **1.43×** |
| 103 | `voron-2.4/Superceded_Parts/Frame_Brackets/dual_ramps_bracket_frame.stl` | `voron-2.4-standard` | 4056 | 64 | 289.5 | 447.5 | **1.55×** |
| 104 | `voron-2.4/Superceded_Parts/Frame_Brackets/duet_duex_bracket_frame_x2.stl` | `voron-2.4-standard` | 44732 | 64 | 375.4 | 387.8 | **1.03×** |
| 105 | `voron-2.4/Superceded_Parts/Frame_Brackets/lrs_bracket_frame.stl` | `voron-2.4-standard` | 4662 | 100 | 117.6 | 294.2 | **2.50×** |
| 106 | `voron-2.4/Superceded_Parts/Frame_Brackets/mks_gen_1.4_bracket_frame_x2.stl` | `voron-2.4-standard` | 60224 | 64 | 396.9 | 468.0 | **1.18×** |
| 107 | `voron-2.4/Superceded_Parts/Frame_Brackets/mks_gen_L_bracket_frame_x2.stl` | `voron-2.4-standard` | 60680 | 64 | 336.2 | 441.3 | **1.31×** |
| 108 | `voron-2.4/Superceded_Parts/Frame_Brackets/raspberry_pi_bracket.stl` | `voron-2.4-standard` | 3494 | 63 | 169.0 | 391.4 | **2.32×** |
| 109 | `voron-2.4/Superceded_Parts/Frame_Brackets/rs_25_psu_bracket_frame.stl` | `voron-2.4-standard` | 3146 | 64 | 83.3 | 277.2 | **3.33×** |
| 110 | `voron-2.4/Superceded_Parts/Frame_Brackets/rs_35_bracket_frame.stl` | `voron-2.4-standard` | 3146 | 64 | 87.7 | 292.8 | **3.34×** |
| 111 | `voron-2.4/Superceded_Parts/Frame_Brackets/skr_1.3_bracket_frame.stl` | `voron-2.4-standard` | 44486 | 64 | 377.5 | 376.9 | **1.00×** |
| 112 | `voron-2.4/Superceded_Parts/Frame_Brackets/skr_mini_e3_bracket_frame.stl` | `voron-2.4-standard` | 37988 | 64 | 214.2 | 368.4 | **1.72×** |
| 113 | `voron-2.4/Superceded_Parts/MGN9_X/[a]_belt_clamp_MGN9_x2.stl` | `voron-2.4-standard` | 14932 | 31 | 47.5 | 306.1 | **6.44×** |
| 114 | `voron-2.4/Superceded_Parts/MGN9_X/x_carriage_frame_left_MGN9.stl` | `voron-2.4-standard` | 25548 | 110 | 515.5 | 703.5 | **1.36×** |
| 115 | `voron-2.4/Superceded_Parts/MGN9_X/x_carriage_frame_right_MGN9.stl` | `voron-2.4-standard` | 24934 | 100 | 538.5 | 777.1 | **1.44×** |
| 116 | `voron-2.4/Superceded_Parts/MGN9_X/x_carriage_pivot_block_MGN9.stl` | `voron-2.4-standard` | 13488 | 70 | 159.4 | 301.9 | **1.89×** |
| 117 | `voron-2.4/Superceded_Parts/MGN9_X/xy_joint_left_lower_MGN9.stl` | `voron-2.4-standard` | 9878 | 170 | 502.2 | 958.2 | **1.91×** |
| 118 | `voron-2.4/Superceded_Parts/MGN9_X/xy_joint_left_upper_MGN9.stl` | `voron-2.4-standard` | 20144 | 80 | 482.9 | 597.9 | **1.24×** |
| 119 | `voron-2.4/Superceded_Parts/MGN9_X/xy_joint_right_lower_MGN9.stl` | `voron-2.4-standard` | 30776 | 170 | 938.0 | 1170.7 | **1.25×** |
| 120 | `voron-2.4/Superceded_Parts/MGN9_X/xy_joint_right_upper_MGN9.stl` | `voron-2.4-standard` | 7052 | 80 | 275.9 | 492.8 | **1.79×** |
| 121 | `voron-2.4/Superceded_Parts/ZipChain/XY/zipchain2_xy_end.stl` | `voron-2.4-standard` | 11348 | 50 | 97.5 | 281.9 | **2.89×** |
| 122 | `voron-2.4/Superceded_Parts/ZipChain/XY/zipchain2_xy_link_a.stl` | `voron-2.4-standard` | 9080 | 50 | 159.3 | 301.8 | **1.89×** |
| 123 | `voron-2.4/Superceded_Parts/ZipChain/XY/zipchain2_xy_link_b.stl` | `voron-2.4-standard` | 13076 | 47 | 131.9 | 325.4 | **2.47×** |
| 124 | `voron-2.4/Superceded_Parts/ZipChain/Z/zipchain2_z_end.stl` | `voron-2.4-standard` | 11104 | 50 | 103.8 | 277.9 | **2.68×** |
| 125 | `voron-2.4/Superceded_Parts/ZipChain/Z/zipchain2_z_link_a.stl` | `voron-2.4-standard` | 10112 | 50 | 164.4 | 311.1 | **1.89×** |
| 126 | `voron-2.4/Superceded_Parts/ZipChain/Z/zipchain2_z_link_b.stl` | `voron-2.4-standard` | 16228 | 47 | 157.4 | 349.8 | **2.22×** |
| 127 | `voron-2.4/Superceded_Parts/ZipChain/Z/zipchain2_z_link_b_locking.stl` | `voron-2.4-standard` | 24712 | 47 | 161.6 | 335.9 | **2.08×** |
| 128 | `voron-2.4/Superceded_Parts/[a]_stopgap_80T_hubbed_gear.stl` | `voron-2.4-standard` | 47178 | 57 | 1013.0 | 1039.7 | **1.03×** |
| 129 | `voron-2.4/Superceded_Parts/[a]_z_tensioner_x4_6mm.stl` | `voron-2.4-standard` | 26782 | 90 | 165.2 | 637.9 | **3.86×** |
| 130 | `voron-2.4/Test_Prints/Filament_Card.stl` | `voron-2.4-standard` | 802 | 10 | 30.9 | 125.2 | **4.05×** |
| 131 | `voron-2.4/Test_Prints/Filament_Card_Caddy_25.stl` | `voron-2.4-standard` | 1260 | 100 | 96.2 | 378.6 | **3.94×** |
| 132 | `voron-2.4/Test_Prints/Heatset_Practice.stl` | `voron-2.4-standard` | 7472 | 50 | 143.9 | 251.6 | **1.75×** |
| 133 | `voron-2.4/Test_Prints/Thread_Test_1_x1_Rev1.STL` | `voron-2.4-standard` | 79822 | 80 | 307.0 | 488.8 | **1.59×** |
| 134 | `voron-2.4/Test_Prints/Thread_Test_2_x1_Rev1.STL` | `voron-2.4-standard` | 23656 | 80 | 270.9 | 462.3 | **1.71×** |
| 135 | `voron-2.4/Test_Prints/Thread_Test_3_x1_Rev1.STL` | `voron-2.4-standard` | 19318 | 53 | 165.2 | 385.3 | **2.33×** |
| 136 | `voron-2.4/Test_Prints/Voron_Design_Cube_v7.stl` | `voron-2.4-standard` | 3414 | 150 | 224.9 | 479.5 | **2.13×** |
| 137 | `voron-2.4/Tools/MGN12_rail_guide_x2.stl` | `voron-2.4-standard` | 1216 | 40 | 40.8 | 115.6 | **2.83×** |
| 138 | `voron-2.4/Tools/MGN9_rail_guide_x2.stl` | `voron-2.4-standard` | 620 | 50 | 38.0 | 103.0 | **2.71×** |
| 139 | `voron-2.4/Tools/bed_hole_marking_template_x1_Rev2.STL` | `voron-2.4-standard` | 876 | 50 | 39.1 | 134.7 | **3.45×** |
| 140 | `voron-2.4/Tools/bottom_panel_template.stl` | `voron-2.4-standard` | 2732 | 25 | 95.1 | 141.6 | **1.49×** |
| 141 | `voron-2.4/Tools/pulley_jig.stl` | `voron-2.4-standard` | 2620 | 16 | 32.5 | 136.1 | **4.19×** |
| 142 | `voron-2.4/Z_Drive/[a]_belt_tensioner_a_x2.stl` | `voron-2.4-standard` | 9252 | 44 | 65.9 | 156.5 | **2.37×** |
| 143 | `voron-2.4/Z_Drive/[a]_belt_tensioner_b_x2.stl` | `voron-2.4-standard` | 9252 | 44 | 67.5 | 159.2 | **2.36×** |
| 144 | `voron-2.4/Z_Drive/[a]_z_drive_baseplate_a_x2.stl` | `voron-2.4-standard` | 10084 | 50 | 239.5 | 367.1 | **1.53×** |
| 145 | `voron-2.4/Z_Drive/[a]_z_drive_baseplate_b_x2.stl` | `voron-2.4-standard` | 10084 | 50 | 220.8 | 395.2 | **1.79×** |
| 146 | `voron-2.4/Z_Drive/z_drive_main_a_x2.stl` | `voron-2.4-standard` | 23308 | 134 | 708.7 | 1030.2 | **1.45×** |
| 147 | `voron-2.4/Z_Drive/z_drive_main_b_x2.stl` | `voron-2.4-standard` | 23308 | 134 | 710.9 | 1046.4 | **1.47×** |
| 148 | `voron-2.4/Z_Drive/z_drive_retainer_a_x2.stl` | `voron-2.4-standard` | 16792 | 81 | 393.4 | 627.1 | **1.59×** |
| 149 | `voron-2.4/Z_Drive/z_drive_retainer_b_x2.stl` | `voron-2.4-standard` | 16792 | 81 | 400.5 | 640.3 | **1.60×** |
| 150 | `voron-2.4/Z_Drive/z_motor_mount_a_x2.stl` | `voron-2.4-standard` | 21424 | 210 | 191.4 | 442.1 | **2.31×** |
| 151 | `voron-2.4/Z_Drive/z_motor_mount_b_x2.stl` | `voron-2.4-standard` | 21424 | 210 | 194.2 | 457.0 | **2.35×** |
| 152 | `voron-2.4/Z_Endstop/nozzle_probe.stl` | `voron-2.4-standard` | 17570 | 85 | 372.8 | 593.0 | **1.59×** |
| 153 | `voron-2.4/Z_Idlers/[a]_z_tensioner_9mm_x4.stl` | `voron-2.4-standard` | 27196 | 90 | 167.7 | 646.9 | **3.86×** |
| 154 | `voron-2.4/Z_Idlers/z_tensioner_bracket_a_x2.stl` | `voron-2.4-standard` | 13454 | 130 | 221.0 | 471.2 | **2.13×** |
| 155 | `voron-2.4/Z_Idlers/z_tensioner_bracket_b_x2.stl` | `voron-2.4-standard` | 13762 | 130 | 205.3 | 465.3 | **2.27×** |
