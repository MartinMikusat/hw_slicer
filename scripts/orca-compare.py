#!/usr/bin/env python3
"""
Compare actual slicing output (G-code geometry, filament, motion, layers, 2D footprint IoU,
and print time) between hw_slicer and OrcaSlicer 2.5.1 using matched settings.

Usage:
  ./scripts/orca-compare.py --model=resources/models/benchy.stl
  ./scripts/orca-compare.py --suite=core [--out-json=/tmp/orca_cmp.json]
"""

import argparse
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import time
from collections import defaultdict

ORCA_BIN = "/Applications/OrcaSlicer.app/Contents/MacOS/OrcaSlicer"


def parse_orca_time_seconds(text: str):
    m = re.search(r";\s*estimated printing time \(normal mode\)\s*=\s*(.+)", text)
    if not m:
        return None
    val = m.group(1).strip()
    total = 0
    for num, unit in re.findall(r"(\d+)\s*([dhms])", val):
        n = int(num)
        if unit == "d":
            total += n * 86400
        elif unit == "h":
            total += n * 3600
        elif unit == "m":
            total += n * 60
        elif unit == "s":
            total += n
    return total if total > 0 else None


def parse_hw_time_seconds(stdout_text: str):
    m = re.search(r"est_time=(\d+):(\d+):(\d+)", stdout_text)
    if not m:
        return None
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))


def parse_gcode(path: str):
    """Unified Klipper G-code parser for both hw_slicer and OrcaSlicer outputs."""
    x = 0.0
    y = 0.0
    z = 0.0
    has_xy = False
    relative_e = True
    cur_e = 0.0
    cur_layer_z = None

    net_e = 0.0
    pos_e = 0.0
    neg_e = 0.0
    retractions = 0
    extrude_moves = 0
    travel_moves = 0
    arc_moves = 0
    extrude_len_mm = 0.0
    travel_len_mm = 0.0
    cmd_count = 0

    min_x = float("inf")
    max_x = float("-inf")
    min_y = float("inf")
    max_y = float("-inf")
    min_z = float("inf")
    max_z = float("-inf")

    layer_z_list = []
    layer_z_seen = set()
    layer_e = defaultdict(float)
    layer_segs = defaultdict(list)  # z_key -> list of (x0, y0, x1, y1)

    in_orca_config = False
    orca_est_s = None

    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue
            if line.startswith(";"):
                if line.startswith("; CONFIG_BLOCK_START"):
                    in_orca_config = True
                elif line.startswith("; CONFIG_BLOCK_END"):
                    in_orca_config = False
                elif line.startswith("; estimated printing time (normal mode)"):
                    orca_est_s = parse_orca_time_seconds(line)
                continue
            if in_orca_config:
                continue

            semi = line.find(";")
            if semi >= 0:
                line = line[:semi].strip()
                if not line:
                    continue

            cmd_count += 1
            parts = line.split()
            op = parts[0]

            if op == "M83":
                relative_e = True
                continue
            elif op == "M82":
                relative_e = False
                continue
            elif op == "G92":
                for tok in parts[1:]:
                    if tok.startswith("E"):
                        try:
                            cur_e = float(tok[1:])
                        except ValueError:
                            pass
                continue
            elif op not in ("G0", "G1", "G2", "G3"):
                continue

            nx, ny, nz = x, y, z
            has_x = has_y = has_z = False
            de = 0.0
            has_e = False
            iv = jv = 0.0

            for tok in parts[1:]:
                if len(tok) < 2:
                    continue
                k = tok[0]
                try:
                    v = float(tok[1:])
                except ValueError:
                    continue
                if k == "X":
                    nx = v
                    has_x = True
                elif k == "Y":
                    ny = v
                    has_y = True
                elif k == "Z":
                    nz = v
                    has_z = True
                elif k == "E":
                    has_e = True
                    if relative_e:
                        de = v
                    else:
                        de = v - cur_e
                        cur_e = v
                elif k == "I":
                    iv = v
                elif k == "J":
                    jv = v

            if has_e:
                net_e += de
                if de > 0:
                    pos_e += de
                elif de < 0:
                    neg_e += -de
                    if not has_x and not has_y and de <= -0.1:
                        retractions += 1

            moved_xy = (has_x or has_y) and has_xy and (nx != x or ny != y)
            if moved_xy:
                if op in ("G2", "G3"):
                    cx, cy = x + iv, y + jv
                    r = math.hypot(x - cx, y - cy)
                    a0 = math.atan2(y - cy, x - cx)
                    a1 = math.atan2(ny - cy, nx - cx)
                    da = a1 - a0
                    if op == "G2":
                        while da >= 0:
                            da -= 2.0 * math.pi
                        if abs(da) < 1e-6 and x == nx and y == ny:
                            da = -2.0 * math.pi
                    else:
                        while da <= 0:
                            da += 2.0 * math.pi
                        if abs(da) < 1e-6 and x == nx and y == ny:
                            da = 2.0 * math.pi
                    seg_len = abs(da) * r
                else:
                    seg_len = math.hypot(nx - x, ny - y)

                if de > 0.0:
                    extrude_moves += 1
                    if op in ("G2", "G3"):
                        arc_moves += 1
                    extrude_len_mm += seg_len
                    # Use rounded Z (0.01 mm) as layer key
                    zk = round(nz, 2)
                    if zk not in layer_z_seen:
                        layer_z_seen.add(zk)
                        layer_z_list.append(zk)
                    layer_e[zk] += de
                    layer_segs[zk].append((x, y, nx, ny))
                    if x < min_x: min_x = x
                    if nx < min_x: min_x = nx
                    if x > max_x: max_x = x
                    if nx > max_x: max_x = nx
                    if y < min_y: min_y = y
                    if ny < min_y: min_y = ny
                    if y > max_y: max_y = y
                    if ny > max_y: max_y = ny
                    if nz < min_z: min_z = nz
                    if nz > max_z: max_z = nz
                else:
                    travel_moves += 1
                    travel_len_mm += seg_len

            if has_x or has_y:
                has_xy = True
            x, y, z = nx, ny, nz

    layer_z_list.sort()
    span_x = (max_x - min_x) if max_x > min_x else 0.0
    span_y = (max_y - min_y) if max_y > min_y else 0.0
    cx = (min_x + max_x) * 0.5 if max_x > min_x else 0.0
    cy = (min_y + max_y) * 0.5 if max_y > min_y else 0.0

    return {
        "layers": len(layer_z_list),
        "layer_z_list": layer_z_list,
        "min_z_mm": round(min_z, 3) if min_z < float("inf") else 0.0,
        "max_z_mm": round(max_z, 3) if max_z > float("-inf") else 0.0,
        "span_x_mm": round(span_x, 2),
        "span_y_mm": round(span_y, 2),
        "center_x_mm": cx,
        "center_y_mm": cy,
        "net_filament_mm": round(net_e, 2),
        "pos_filament_mm": round(pos_e, 2),
        "extrude_len_mm": round(extrude_len_mm, 1),
        "travel_len_mm": round(travel_len_mm, 1),
        "e_per_mm": round(net_e / extrude_len_mm, 5) if extrude_len_mm > 0 else 0.0,
        "extrude_moves": extrude_moves,
        "travel_moves": travel_moves,
        "arc_moves": arc_moves,
        "retractions": retractions,
        "commands": cmd_count,
        "bytes": os.path.getsize(path),
        "orca_est_s": orca_est_s,
        "layer_e": layer_e,
        "layer_segs": layer_segs,
    }


def rasterize_segments(segs, cx, cy, cell_mm=0.5, dilate=1):
    """Rasterize centered 2D segments into a set of grid cells (with optional 1-cell dilation)."""
    cells = set()
    inv = 1.0 / cell_mm
    for x0, y0, x1, y1 in segs:
        ax = (x0 - cx) * inv
        ay = (y0 - cy) * inv
        bx = (x1 - cx) * inv
        by = (y1 - cy) * inv
        steps = max(1, int(math.ceil(max(abs(bx - ax), abs(by - ay)))))
        for i in range(steps + 1):
            t = i / steps
            gx = int(round(ax + (bx - ax) * t))
            gy = int(round(ay + (by - ay) * t))
            cells.add((gx, gy))
    if dilate > 0 and cells:
        out = set(cells)
        for gx, gy in cells:
            for dx in range(-dilate, dilate + 1):
                for dy in range(-dilate, dilate + 1):
                    out.add((gx + dx, gy + dy))
        return out
    return cells


def rasterize_silhouette(segs, cx, cy, cell_mm=0.5):
    """Fill horizontal row spans of extruded segments to approximate the 2D part silhouette."""
    row_minmax = {}
    inv = 1.0 / cell_mm
    for x0, y0, x1, y1 in segs:
        ax = (x0 - cx) * inv
        ay = (y0 - cy) * inv
        bx = (x1 - cx) * inv
        by = (y1 - cy) * inv
        steps = max(1, int(math.ceil(max(abs(bx - ax), abs(by - ay)))))
        for i in range(steps + 1):
            t = i / steps
            gx = int(round(ax + (bx - ax) * t))
            gy = int(round(ay + (by - ay) * t))
            if gy not in row_minmax:
                row_minmax[gy] = [gx, gx]
            else:
                if gx < row_minmax[gy][0]:
                    row_minmax[gy][0] = gx
                if gx > row_minmax[gy][1]:
                    row_minmax[gy][1] = gx
    filled = set()
    for gy, (lo, hi) in row_minmax.items():
        for gx in range(lo, hi + 1):
            filled.add((gx, gy))
    return filled


def pearson_r(xs, ys):
    n = len(xs)
    if n < 2:
        return 1.0
    mx = sum(xs) / n
    my = sum(ys) / n
    num = sum((a - mx) * (b - my) for a, b in zip(xs, ys))
    dx = math.sqrt(sum((a - mx) ** 2 for a in xs))
    dy = math.sqrt(sum((b - my) ** 2 for b in ys))
    if dx == 0 or dy == 0:
        return 1.0 if dx == dy else 0.0
    return num / (dx * dy)


def compare_parsed(hw_g, orca_g, hw_est_s=None):
    """Compute extensive structural, filament, motion, and 2D geometric comparison."""
    # Match layers by nearest Z (within 0.05 mm)
    hw_zs = hw_g["layer_z_list"]
    or_zs = orca_g["layer_z_list"]

    # Skip layer 0 (skirt/brim differences) when computing pure model silhouette & Z correlation
    common_pairs = []
    oi = 0
    for hz in hw_zs:
        while oi + 1 < len(or_zs) and abs(or_zs[oi + 1] - hz) < abs(or_zs[oi] - hz):
            oi += 1
        if oi < len(or_zs) and abs(or_zs[oi] - hz) <= 0.06:
            common_pairs.append((hz, or_zs[oi]))

    # Layer-by-layer filament correlation (layers 1..N-1 to exclude skirt/brim on layer 0)
    body_pairs = common_pairs[1:] if len(common_pairs) > 2 else common_pairs
    hw_le = [hw_g["layer_e"][hz] for hz, _ in body_pairs]
    or_le = [orca_g["layer_e"][oz] for _, oz in body_pairs]
    layer_e_r = pearson_r(hw_le, or_le)

    # Dimension delta & body centroid using body layers (excluding layer 0 skirt/brim)
    def body_bounds(g, zs):
        mnx = mny = float("inf")
        mxx = mxy = float("-inf")
        for zk in zs:
            for x0, y0, x1, y1 in g["layer_segs"][zk]:
                if x0 < mnx: mnx = x0
                if x1 < mnx: mnx = x1
                if x0 > mxx: mxx = x0
                if x1 > mxx: mxx = x1
                if y0 < mny: mny = y0
                if y1 < mny: mny = y1
                if y0 > mxy: mxy = y0
                if y1 > mxy: mxy = y1
        if mxx > mnx and mxy > mny:
            return round(mxx - mnx, 2), round(mxy - mny, 2), (mnx + mxx) * 0.5, (mny + mxy) * 0.5
        return 0.0, 0.0, g["center_x_mm"], g["center_y_mm"]

    hw_bx, hw_by, hw_cx, hw_cy = body_bounds(hw_g, [hz for hz, _ in body_pairs])
    or_bx, or_by, or_cx, or_cy = body_bounds(orca_g, [oz for _, oz in body_pairs])

    # Sample up to 12 evenly spaced body layers for 2D footprint & silhouette IoU
    sample_count = min(12, len(body_pairs))
    path_ious = []
    sil_ious = []
    if sample_count > 0:
        step = max(1, len(body_pairs) // sample_count)
        sampled = body_pairs[::step][:sample_count]
        for hz, oz in sampled:
            hsegs = hw_g["layer_segs"][hz]
            osegs = orca_g["layer_segs"][oz]
            if not hsegs or not osegs:
                continue
            hc = rasterize_segments(hsegs, hw_cx, hw_cy, cell_mm=0.5, dilate=1)
            oc = rasterize_segments(osegs, or_cx, or_cy, cell_mm=0.5, dilate=1)
            inter = len(hc & oc)
            union = len(hc | oc)
            if union > 0:
                path_ious.append(inter / union)
            hs = rasterize_silhouette(hsegs, hw_cx, hw_cy, cell_mm=0.5)
            os_ = rasterize_silhouette(osegs, or_cx, or_cy, cell_mm=0.5)
            s_inter = len(hs & os_)
            s_union = len(hs | os_)
            if s_union > 0:
                sil_ious.append(s_inter / s_union)

    def pct(a, b):
        return round((a - b) / b * 100.0, 2) if b > 0 else 0.0

    orca_est_s = orca_g["orca_est_s"]
    mean_path_iou = round(sum(path_ious) / len(path_ious), 3) if path_ious else 0.0
    mean_sil_iou = round(sum(sil_ious) / len(sil_ious), 3) if sil_ious else 0.0

    # Loose practical sanity checks (not 100% exact, flags real defects)
    warnings = []
    if abs(hw_g["layers"] - orca_g["layers"]) > 2:
        warnings.append(f"layer count delta {hw_g['layers'] - orca_g['layers']:+d}")
    if abs(hw_bx - or_bx) > 1.0 or abs(hw_by - or_by) > 1.0:
        warnings.append(f"XY span delta ({hw_bx - or_bx:+.2f}, {hw_by - or_by:+.2f}) mm")
    if abs(hw_g["max_z_mm"] - orca_g["max_z_mm"]) > 0.5:
        warnings.append(f"max Z delta {hw_g['max_z_mm'] - orca_g['max_z_mm']:+.2f} mm")
    fil_pct = pct(hw_g["net_filament_mm"], orca_g["net_filament_mm"])
    if abs(fil_pct) > 25.0:
        warnings.append(f"filament delta {fil_pct:+.1f}%")
    if layer_e_r < 0.85:
        warnings.append(f"low Z-filament correlation r={layer_e_r:.3f}")
    if mean_sil_iou < 0.80:
        warnings.append(f"low 2D silhouette IoU={mean_sil_iou:.3f}")

    return {
        "layers_hw": hw_g["layers"],
        "layers_orca": orca_g["layers"],
        "layers_delta": hw_g["layers"] - orca_g["layers"],
        "max_z_hw_mm": hw_g["max_z_mm"],
        "max_z_orca_mm": orca_g["max_z_mm"],
        "body_span_hw_mm": [hw_bx, hw_by],
        "body_span_orca_mm": [or_bx, or_by],
        "filament_hw_mm": hw_g["net_filament_mm"],
        "filament_orca_mm": orca_g["net_filament_mm"],
        "filament_delta_pct": fil_pct,
        "e_per_mm_hw": hw_g["e_per_mm"],
        "e_per_mm_orca": orca_g["e_per_mm"],
        "extrude_len_hw_mm": hw_g["extrude_len_mm"],
        "extrude_len_orca_mm": orca_g["extrude_len_mm"],
        "extrude_len_delta_pct": pct(hw_g["extrude_len_mm"], orca_g["extrude_len_mm"]),
        "travel_len_hw_mm": hw_g["travel_len_mm"],
        "travel_len_orca_mm": orca_g["travel_len_mm"],
        "travel_len_delta_pct": pct(hw_g["travel_len_mm"], orca_g["travel_len_mm"]),
        "retractions_hw": hw_g["retractions"],
        "retractions_orca": orca_g["retractions"],
        "arcs_hw": hw_g["arc_moves"],
        "arcs_orca": orca_g["arc_moves"],
        "est_time_hw_s": hw_est_s,
        "est_time_orca_s": orca_est_s,
        "est_time_delta_pct": pct(hw_est_s, orca_est_s) if (hw_est_s and orca_est_s) else None,
        "layer_filament_corr_r": round(layer_e_r, 4),
        "mean_path_iou": mean_path_iou,
        "mean_silhouette_iou": mean_sil_iou,
        "warnings": warnings,
    }


def format_time(sec):
    if sec is None:
        return "n/a"
    h = sec // 3600
    m = (sec % 3600) // 60
    s = sec % 60
    return f"{h}h{m:02d}m{s:02d}s" if h > 0 else f"{m}m{s:02d}s"


def print_comparison(name: str, cmp: dict):
    status = "OK" if not cmp["warnings"] else "WARN: " + "; ".join(cmp["warnings"])
    print(f"\n--- {name}  [{status}] ---")
    print(f"  Layers:          hw={cmp['layers_hw']:4d}  orca={cmp['layers_orca']:4d}  (delta {cmp['layers_delta']:+d})  | Max Z: {cmp['max_z_hw_mm']:.2f} vs {cmp['max_z_orca_mm']:.2f} mm")
    print(f"  Body XY span:    hw={cmp['body_span_hw_mm'][0]:.2f}x{cmp['body_span_hw_mm'][1]:.2f} mm  orca={cmp['body_span_orca_mm'][0]:.2f}x{cmp['body_span_orca_mm'][1]:.2f} mm")
    print(f"  Filament (net):  hw={cmp['filament_hw_mm']:8.2f} mm  orca={cmp['filament_orca_mm']:8.2f} mm  ({cmp['filament_delta_pct']:+5.1f}%)  | E/mm: {cmp['e_per_mm_hw']:.4f} vs {cmp['e_per_mm_orca']:.4f}")
    print(f"  Extrude path:    hw={cmp['extrude_len_hw_mm']:8.1f} mm  orca={cmp['extrude_len_orca_mm']:8.1f} mm  ({cmp['extrude_len_delta_pct']:+5.1f}%)")
    print(f"  Travel path:     hw={cmp['travel_len_hw_mm']:8.1f} mm  orca={cmp['travel_len_orca_mm']:8.1f} mm  ({cmp['travel_len_delta_pct']:+5.1f}%)")
    print(f"  Retractions:     hw={cmp['retractions_hw']:6d}       orca={cmp['retractions_orca']:6d}       | G2/G3 arcs: hw={cmp['arcs_hw']} vs orca={cmp['arcs_orca']}")
    t_delta = f" ({cmp['est_time_delta_pct']:+5.1f}%)" if cmp["est_time_delta_pct"] is not None else ""
    print(f"  Est print time:  hw={format_time(cmp['est_time_hw_s']):>9s}   orca={format_time(cmp['est_time_orca_s']):>9s}{t_delta}")
    print(f"  Geometry match:  Z-filament corr r={cmp['layer_filament_corr_r']:.4f} | 2D silhouette IoU={cmp['mean_silhouette_iou']:.3f} | Dilated path IoU={cmp['mean_path_iou']:.3f}")


def main():
    ap = argparse.ArgumentParser(description="Compare hw_slicer G-code output against OrcaSlicer 2.5.1")
    ap.add_argument("--model", action="append", default=[], help="Path to STL/OBJ/3MF model (repeatable)")
    ap.add_argument("--suite", choices=["core"], help="Run standard core models")
    ap.add_argument("--hw-cli", default="build/release/hw-slicer-cli", help="Path to hw-slicer-cli")
    ap.add_argument("--hw-set", action="append", default=[], help="Extra hw-slicer --set key=val")
    ap.add_argument("--orca-set", action="append", default=[], help="Extra OrcaSlicer process key=val")
    ap.add_argument("--out-json", default="", help="Optional JSON output path")
    args = ap.parse_args()

    models = [os.path.abspath(m) for m in args.model]
    if args.suite == "core" or not models:
        for fn in ("benchy.stl", "all-in-one-test.stl", "stanford-bunny.stl"):
            p = os.path.abspath(os.path.join("resources/models", fn))
            if os.path.exists(p):
                models.append(p)

    hw_cli = os.path.abspath(args.hw_cli)
    if not os.path.exists(hw_cli):
        print(f"error: hw-slicer-cli not found at {hw_cli}; run ./build.sh cli-release", file=sys.stderr)
        sys.exit(1)
    if not os.path.exists(ORCA_BIN):
        print(f"error: OrcaSlicer not found at {ORCA_BIN}", file=sys.stderr)
        sys.exit(1)

    mach = {
        "type": "machine", "name": "HW Slicer Benchmark Klipper 350", "from": "User",
        "gcode_flavor": "klipper", "printable_area": ["0x0", "350x0", "350x350", "0x350"],
        "printable_height": "350", "nozzle_diameter": ["0.4"],
        "machine_max_acceleration_x": ["6000"], "machine_max_acceleration_y": ["6000"],
        "machine_max_acceleration_z": ["500"], "machine_max_acceleration_e": ["5000"],
        "machine_max_speed_x": ["300"], "machine_max_speed_y": ["300"],
        "machine_max_speed_z": ["20"], "machine_max_speed_e": ["100"],
        "retraction_length": ["0.8"], "retraction_speed": ["40"],
        "deretraction_speed": ["40"], "z_hop": ["0.4"],
    }
    fil = {
        "type": "filament", "name": "Benchmark PLA", "from": "User",
        "filament_type": ["PLA"], "filament_diameter": ["1.75"], "filament_density": ["1.24"],
        "nozzle_temperature": ["210"], "nozzle_temperature_initial_layer": ["210"],
        "hot_plate_temp": ["60"], "hot_plate_temp_initial_layer": ["60"],
        "fan_min_speed": ["100"], "fan_max_speed": ["100"], "overhang_fan_speed": ["100"],
        "filament_max_volumetric_speed": ["20"],
    }
    proc = {
        "type": "process", "name": "0.20-standard", "from": "User",
        "layer_height": "0.2", "initial_layer_print_height": "0.2",
        "line_width": "0.42", "initial_layer_line_width": "0.42",
        "outer_wall_line_width": "0.42", "inner_wall_line_width": "0.42",
        "top_surface_line_width": "0.42", "sparse_infill_line_width": "0.42",
        "internal_solid_infill_line_width": "0.42", "wall_loops": "3",
        "top_shell_layers": "4", "top_shell_thickness": "0.8",
        "bottom_shell_layers": "4", "bottom_shell_thickness": "0.8",
        "sparse_infill_density": "15%", "sparse_infill_pattern": "gyroid",
        "enable_support": "0", "enable_arc_fitting": "1", "skirt_loops": "1",
        "brim_width": "0", "elefant_foot_compensation": "0.15",
        "outer_wall_speed": "80", "inner_wall_speed": "80",
        "top_surface_speed": "90", "internal_solid_infill_speed": "90",
        "sparse_infill_speed": "120", "gap_infill_speed": "60",
        "bridge_speed": "35", "travel_speed": "200",
    }
    for kv in args.orca_set:
        k, v = kv.split("=", 1)
        proc[k] = v

    report = []
    with tempfile.TemporaryDirectory(prefix="hw-orca-cmp-") as td:
        mp, fp, pp = os.path.join(td, "m.json"), os.path.join(td, "f.json"), os.path.join(td, "p.json")
        json.dump(mach, open(mp, "w"))
        json.dump(fil, open(fp, "w"))
        json.dump(proc, open(pp, "w"))

        for mpath in models:
            name = os.path.basename(mpath)
            hw_out = os.path.join(td, f"hw_{name}.gcode")
            orca_dir = os.path.join(td, f"orca_{name}")
            os.makedirs(orca_dir, exist_ok=True)

            hw_cmd = [hw_cli, f"--input={mpath}", "--printer=vcore3", "--material=pla", "--process=0.20-standard", f"--out={hw_out}"]
            for kv in args.hw_set:
                hw_cmd.extend(["--set", kv])
            t0 = time.perf_counter()
            hp = subprocess.run(hw_cmd, capture_output=True, text=True)
            hw_ms = (time.perf_counter() - t0) * 1000.0
            if hp.returncode != 0:
                print(f"FAIL hw_slicer on {name}: {hp.stderr or hp.stdout}", file=sys.stderr)
                continue

            orca_cmd = [ORCA_BIN, "--slice", "0", "--arrange", "1", "--load-settings", f"{mp};{pp}", "--load-filaments", fp, "--outputdir", orca_dir, mpath]
            t0 = time.perf_counter()
            op = subprocess.run(orca_cmd, cwd=orca_dir, capture_output=True, text=True)
            orca_ms = (time.perf_counter() - t0) * 1000.0
            if op.returncode != 0:
                print(f"FAIL OrcaSlicer on {name}: {op.stderr or op.stdout}", file=sys.stderr)
                continue

            gfiles = sorted(f for f in os.listdir(orca_dir) if f.endswith(".gcode"))
            if not gfiles:
                print(f"FAIL OrcaSlicer produced no gcode for {name}", file=sys.stderr)
                continue
            orca_gcode = os.path.join(orca_dir, gfiles[0])

            hw_g = parse_gcode(hw_out)
            orca_g = parse_gcode(orca_gcode)
            cmp = compare_parsed(hw_g, orca_g, parse_hw_time_seconds(hp.stdout))
            cmp["model"] = name
            cmp["hw_ms"] = round(hw_ms, 1)
            cmp["orca_ms"] = round(orca_ms, 1)
            cmp["speedup"] = round(orca_ms / hw_ms, 2) if hw_ms > 0 else 0.0
            print_comparison(name, cmp)
            report.append(cmp)

    if args.out_json:
        with open(args.out_json, "w") as f:
            json.dump(report, f, indent=2)
        print(f"\nWrote comparison JSON: {args.out_json}")


if __name__ == "__main__":
    main()
