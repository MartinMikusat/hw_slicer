#!/usr/bin/env bash
set -euo pipefail

# Autonomous end-to-end acceptance suite for hw_slicer.
# Verifies builds, CLI feature matrix, pure-Odin Vatti parity, 4-way CPU/Metal
# determinism & speedup, closed-loop hw-printer-sim execution, and report artifacts.
# Runs strictly locally (never touches physical printer hardware).

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

OUT_DIR="$ROOT_DIR/build/test-out/accept"
mkdir -p "$OUT_DIR"

SKIP_SIM="${ACCEPT_SKIP_SIM:-0}"
for arg in "$@"; do
  case "$arg" in
    --skip-sim) SKIP_SIM=1 ;;
    *) echo "usage: $0 [--skip-sim]" >&2; exit 2 ;;
  esac
done

PASS_COUNT=0
pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  [PASS] $1"
}
fail() {
  echo "  [FAIL] $1" >&2
  exit 1
}

echo "=== 1. Build & Dependency Pin Verification ==="
./build.sh debug >"$OUT_DIR/build-debug.log" 2>&1 || { cat "$OUT_DIR/build-debug.log" >&2; fail "build.sh debug"; }
pass "build.sh debug (dependencies.lock + HWSlicer.app + hw-slicer-cli)"

./build.sh cli-release >"$OUT_DIR/build-release.log" 2>&1 || { cat "$OUT_DIR/build-release.log" >&2; fail "build.sh cli-release"; }
CLI="$ROOT_DIR/build/release/hw-slicer-cli"
[ -x "$CLI" ] || fail "release CLI binary missing"
pass "build.sh cli-release"

# Generate shared calibration pad and cube OBJ for fast feature checks
PAD_OBJ="$OUT_DIR/pad.obj"
cat > "$PAD_OBJ" <<'EOF'
v 0 0 0
v 12 0 0
v 12 12 0
v 0 12 0
v 0 0 1.2
v 12 0 1.2
v 12 12 1.2
v 0 12 1.2
f 1 3 2
f 1 4 3
f 5 6 7
f 5 7 8
f 1 2 6
f 1 6 5
f 2 3 7
f 2 7 6
f 3 4 8
f 3 8 7
f 4 1 5
f 4 5 8
EOF

CUBE_OBJ="$OUT_DIR/cube.obj"
cat > "$CUBE_OBJ" <<'EOF'
v 0 0 0
v 20 0 0
v 20 20 0
v 0 20 0
v 0 0 20
v 20 0 20
v 20 20 20
v 0 20 20
f 1 3 2
f 1 4 3
f 5 6 7
f 5 7 8
f 1 2 6
f 1 6 5
f 2 3 7
f 2 7 6
f 3 4 8
f 3 8 7
f 4 1 5
f 4 5 8
EOF

echo "=== 2. CLI Feature Matrix & Klipper Validation ==="

# 2a. Benchy with scarf seam, arcs, Metal GPU, 3D mesh auto-repair
"$CLI" --input=resources/models/benchy.stl \
  --printer=vcore3 --material=pla --process=0.20-standard \
  --scarf-seam --set arc_fitting=true --gpu \
  --out="$OUT_DIR/benchy-pro.gcode" >"$OUT_DIR/benchy-pro.log" 2>&1 \
  || { cat "$OUT_DIR/benchy-pro.log" >&2; fail "benchy scarf+arcs+gpu"; }
grep -q "SLICE OK:" "$OUT_DIR/benchy-pro.log" || fail "benchy missing SLICE OK"
grep -q "est_time=" "$OUT_DIR/benchy-pro.log" || fail "benchy missing est_time"
grep -q "^START_PRINT " "$OUT_DIR/benchy-pro.gcode" || fail "benchy missing START_PRINT"
grep -q "^END_PRINT" "$OUT_DIR/benchy-pro.gcode" || fail "benchy missing END_PRINT"
grep -q "^EXCLUDE_OBJECT_DEFINE " "$OUT_DIR/benchy-pro.gcode" || fail "benchy missing EXCLUDE_OBJECT_DEFINE"
grep -qE "^G[23] " "$OUT_DIR/benchy-pro.gcode" || fail "benchy missing G2/G3 arcs"
pass "benchy.stl (--scarf-seam --set arc_fitting=true --gpu, validated Klipper G-code + G2/G3 + EXCLUDE_OBJECT)"

# 2b. Spiral vase mode
"$CLI" --input="$CUBE_OBJ" \
  --printer=vcore3 --material=pla --process=0.20-standard \
  --vase-mode \
  --out="$OUT_DIR/vase.gcode" >"$OUT_DIR/vase.log" 2>&1 \
  || { cat "$OUT_DIR/vase.log" >&2; fail "vase mode"; }
grep -q "SLICE OK:" "$OUT_DIR/vase.log" || fail "vase missing SLICE OK"
Z_COUNT="$(grep -cE '^G1 .* Z[0-9]+\.[0-9]+' "$OUT_DIR/vase.gcode" || true)"
[ "$Z_COUNT" -ge 50 ] || fail "vase mode expected continuous helical Z moves, got $Z_COUNT"
pass "spiral vase mode ($Z_COUNT helical Z moves)"

# 2c. Fuzzy skin + height modifier + PAUSE + M600
"$CLI" --input="$PAD_OBJ" \
  --printer=vcore3 --material=pla --process=0.20-standard \
  --fuzzy-skin --modifier=z:0.4..1.0:speed_scale=0.6 --pause-at-layer=2 --color-change=3 \
  --out="$OUT_DIR/pro-combo.gcode" >"$OUT_DIR/pro-combo.log" 2>&1 \
  || { cat "$OUT_DIR/pro-combo.log" >&2; fail "fuzzy+modifier+pause+m600"; }
grep -q "^PAUSE$" "$OUT_DIR/pro-combo.gcode" || fail "missing PAUSE command"
grep -q "^M600$" "$OUT_DIR/pro-combo.gcode" || fail "missing M600 command"
pass "fuzzy skin + z-modifier + PAUSE + M600"

# 2d. Adaptive layers + tree supports + ironing + variable wall + GPU
"$CLI" --input=resources/models/all-in-one-test.stl \
  --printer=vcore3 --material=pla --process=0.20-standard \
  --adaptive-layers --supports --set support_style=tree --set ironing=true --set variable_walls=true --gpu \
  --out="$OUT_DIR/aio-pro.gcode" >"$OUT_DIR/aio-pro.log" 2>&1 \
  || { cat "$OUT_DIR/aio-pro.log" >&2; fail "all-in-one adaptive+tree+ironing+variable-wall"; }
grep -q "SLICE OK:" "$OUT_DIR/aio-pro.log" || fail "all-in-one missing SLICE OK"
pass "all-in-one-test.stl (--adaptive-layers --supports --set support_style=tree --set ironing=true --set variable_walls=true --gpu)"

# 2e. Multi-object plate clone + sequential clearance collision detection
"$CLI" --input="$PAD_OBJ" --clone=2 \
  --printer=vcore3 --material=pla --process=0.28-draft \
  --out="$OUT_DIR/clone-ok.gcode" >"$OUT_DIR/clone-ok.log" 2>&1 \
  || { cat "$OUT_DIR/clone-ok.log" >&2; fail "plate clone=2 failed"; }
if "$CLI" --input="$PAD_OBJ" --clone=2 --sequential \
  --printer=vcore3 --material=pla --process=0.28-draft \
  --out="$OUT_DIR/seq-bad.gcode" >"$OUT_DIR/seq-bad.log" 2>&1; then
  fail "sequential colliding placement should have failed"
fi
grep -q "sequential printing collision" "$OUT_DIR/seq-bad.log" || fail "expected sequential collision message"
pass "multi-object --clone=2 + --sequential collision detection"

echo "=== 3. Pure-Odin Vatti Polygon Engine Parity ==="

"$CLI" --input="$CUBE_OBJ" --printer=vcore3 --material=pla --process=0.20-standard --polygon-provider=clipper2 \
  --out="$OUT_DIR/cube-c2.gcode" >"$OUT_DIR/cube-c2.log" 2>&1 || fail "cube clipper2"
"$CLI" --input="$CUBE_OBJ" --printer=vcore3 --material=pla --process=0.20-standard --polygon-provider=odin \
  --out="$OUT_DIR/cube-odin.gcode" >"$OUT_DIR/cube-odin.log" 2>&1 || fail "cube odin"
F_C2="$(sed -n 's/.*filament=\([0-9.]*\) mm.*/\1/p' "$OUT_DIR/cube-c2.log" | head -n 1)"
F_OD="$(sed -n 's/.*filament=\([0-9.]*\) mm.*/\1/p' "$OUT_DIR/cube-odin.log" | head -n 1)"
awk -v a="$F_C2" -v b="$F_OD" 'BEGIN { d = a - b; if (d < 0) d = -d; if (d > 0.05) exit 1 }' \
  || fail "cube OdinVatti filament delta too high (clipper2=$F_C2 odin=$F_OD)"
pass "cube.obj OdinVatti parity (clipper2=${F_C2}mm, odin=${F_OD}mm)"

"$CLI" --input=resources/models/all-in-one-test.stl --printer=vcore3 --material=pla --process=0.20-standard --polygon-provider=clipper2 --gpu \
  --out="$OUT_DIR/aio-c2.gcode" >"$OUT_DIR/aio-c2.log" 2>&1 || fail "aio clipper2"
"$CLI" --input=resources/models/all-in-one-test.stl --printer=vcore3 --material=pla --process=0.20-standard --polygon-provider=odin --gpu \
  --out="$OUT_DIR/aio-odin.gcode" >"$OUT_DIR/aio-odin.log" 2>&1 || fail "aio odin"
A_C2="$(sed -n 's/.*filament=\([0-9.]*\) mm.*/\1/p' "$OUT_DIR/aio-c2.log" | head -n 1)"
A_OD="$(sed -n 's/.*filament=\([0-9.]*\) mm.*/\1/p' "$OUT_DIR/aio-odin.log" | head -n 1)"
awk -v a="$A_C2" -v b="$A_OD" 'BEGIN { pct = (b - a) / a * 100.0; if (pct < 0) pct = -pct; if (pct > 1.5) exit 1 }' \
  || fail "all-in-one OdinVatti filament delta > 1.5% (clipper2=$A_C2 odin=$A_OD)"
pass "all-in-one-test.stl OdinVatti parity (clipper2=${A_C2}mm, odin=${A_OD}mm)"

echo "=== 4. 4-Way CPU/Metal Determinism & Speedup Check (benchy.stl) ==="

"$CLI" --input=resources/models/benchy.stl --printer=vcore3 --material=pla --process=0.20-standard --threads=1 --no-gpu \
  --out="$OUT_DIR/b-1c.gcode" >"$OUT_DIR/b-1c.log" 2>&1 || fail "benchy 1-core"
"$CLI" --input=resources/models/benchy.stl --printer=vcore3 --material=pla --process=0.20-standard --threads=8 --no-gpu \
  --out="$OUT_DIR/b-8c.gcode" >"$OUT_DIR/b-8c.log" 2>&1 || fail "benchy 8-core"
"$CLI" --input=resources/models/benchy.stl --printer=vcore3 --material=pla --process=0.20-standard --threads=1 --gpu \
  --out="$OUT_DIR/b-1g.gcode" >"$OUT_DIR/b-1g.log" 2>&1 || fail "benchy 1-core+gpu"
"$CLI" --input=resources/models/benchy.stl --printer=vcore3 --material=pla --process=0.20-standard --threads=8 --gpu \
  --out="$OUT_DIR/b-8g.gcode" >"$OUT_DIR/b-8g.log" 2>&1 || fail "benchy 8-core+gpu"

F_1C="$(sed -n 's/.*filament=\([0-9.]*\) mm.*/\1/p' "$OUT_DIR/b-1c.log" | head -n 1)"
F_8C="$(sed -n 's/.*filament=\([0-9.]*\) mm.*/\1/p' "$OUT_DIR/b-8c.log" | head -n 1)"
F_1G="$(sed -n 's/.*filament=\([0-9.]*\) mm.*/\1/p' "$OUT_DIR/b-1g.log" | head -n 1)"
F_8G="$(sed -n 's/.*filament=\([0-9.]*\) mm.*/\1/p' "$OUT_DIR/b-8g.log" | head -n 1)"
[ "$F_1C" = "$F_8C" ] && [ "$F_1C" = "$F_1G" ] && [ "$F_1C" = "$F_8G" ] \
  || fail "non-deterministic filament across modes: 1c=$F_1C 8c=$F_8C 1g=$F_1G 8g=$F_8G"

T_1C="$(sed -n 's/.*total=\([0-9.]*\) ms.*/\1/p' "$OUT_DIR/b-1c.log" | head -n 1)"
T_8C="$(sed -n 's/.*total=\([0-9.]*\) ms.*/\1/p' "$OUT_DIR/b-8c.log" | head -n 1)"
T_1G="$(sed -n 's/.*total=\([0-9.]*\) ms.*/\1/p' "$OUT_DIR/b-1g.log" | head -n 1)"
T_8G="$(sed -n 's/.*total=\([0-9.]*\) ms.*/\1/p' "$OUT_DIR/b-8g.log" | head -n 1)"
awk -v a="$T_1C" -v d="$T_8G" 'BEGIN { if (d >= a) exit 1 }' \
  || fail "8-core+Metal ($T_8G ms) was not faster than 1-core CPU ($T_1C ms)"

ORCA_BIN="/Applications/OrcaSlicer.app/Contents/MacOS/OrcaSlicer"
ORCA_INFO="OrcaSlicer=not-installed"
if [ -x "$ORCA_BIN" ]; then
  ORCA_DIR="$OUT_DIR/orca-ref"
  mkdir -p "$ORCA_DIR"
  cat > "$ORCA_DIR/machine.json" <<'EOF'
{
  "type": "machine",
  "name": "Bench_VCore3_0.4",
  "from": "User",
  "gcode_flavor": "klipper",
  "nozzle_diameter": ["0.4"],
  "printable_area": ["0x0", "300x0", "300x300", "0x300"],
  "printable_height": "300",
  "before_layer_change_gcode": "G92 E0\n",
  "layer_change_gcode": "G92 E0\n",
  "use_relative_e_distances": "1"
}
EOF
  cat > "$ORCA_DIR/process.json" <<'EOF'
{
  "type": "process",
  "name": "Bench_0.20_Standard",
  "from": "User",
  "layer_height": "0.2",
  "initial_layer_print_height": "0.2",
  "wall_loops": "3",
  "top_shell_layers": "4",
  "bottom_shell_layers": "4",
  "sparse_infill_density": "15%",
  "sparse_infill_pattern": "gyroid",
  "enable_support": "0"
}
EOF
  T_ORCA="$(python3 -c '
import subprocess, time, sys, os
t0 = time.perf_counter()
r = subprocess.run([
  sys.argv[1],
  "--load-settings", f"{sys.argv[2]}/machine.json;{sys.argv[2]}/process.json",
  "--slice", "0",
  "--outputdir", sys.argv[2],
  sys.argv[3],
], capture_output=True, text=True)
dt = (time.perf_counter() - t0) * 1000.0
gcode = os.path.join(sys.argv[2], "plate_1.gcode")
if r.returncode != 0 or not os.path.exists(gcode) or os.path.getsize(gcode) == 0:
  sys.stderr.write(r.stderr + "\n")
  sys.exit(1)
print(f"{dt:.2f}")
' "$ORCA_BIN" "$ORCA_DIR" "$ROOT_DIR/resources/models/benchy.stl")" || fail "OrcaSlicer reference benchmark failed"
  RATIO="$(awk -v d="$T_8G" -v o="$T_ORCA" 'BEGIN { printf "%.2f", d / o }')"
  ORCA_INFO="OrcaSlicer=${T_ORCA}ms (hw/orca=${RATIO}x)"
fi
pass "4-way determinism (filament=${F_1C}mm) & speedup (1c=${T_1C}ms, 8c=${T_8C}ms, 1c+gpu=${T_1G}ms, 8c+gpu=${T_8G}ms | ${ORCA_INFO})"

echo "=== 5. Closed-Loop hw-printer-sim Verification ==="
if [ "$SKIP_SIM" = "1" ]; then
  echo "  [SKIP] closed-loop simulator check skipped (--skip-sim)"
else
  ./scripts/sim-verify.sh >"$OUT_DIR/sim-verify.log" 2>&1 \
    || { cat "$OUT_DIR/sim-verify.log" >&2; fail "scripts/sim-verify.sh"; }
  pass "closed-loop hw-printer + hw-printer-sim (zero faults, exact filament & triple-Z lockstep)"
fi

echo "=== 6. Documentation Artifacts ==="
for doc in docs/metal-acceleration.md docs/odin-polygon.md docs/sim-verification.md; do
  [ -s "$doc" ] || fail "missing or empty $doc"
done
pass "reports present (metal-acceleration.md, odin-polygon.md, sim-verification.md)"

echo ""
echo "ACCEPTANCE PASSED: $PASS_COUNT checks succeeded."
