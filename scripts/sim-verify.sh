#!/usr/bin/env bash
set -euo pipefail

# Closed-loop verification: slice a mesh with hw-slicer-cli and execute the resulting
# Klipper G-code end-to-end through hw-printer + hw-printer-sim (local pseudo-terminal only;
# never connects to physical hardware).

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PRINTER_DIR="${HW_PRINTER_DIR:-$ROOT_DIR/../hw_printer}"
# Use the most recently built CLI, so a stale release build never stands in for current code.
SLICER_BIN="$ROOT_DIR/build/hw-slicer-cli"
RELEASE_BIN="$ROOT_DIR/build/release/hw-slicer-cli"
if [ -x "$RELEASE_BIN" ] && { [ ! -x "$SLICER_BIN" ] || [ "$RELEASE_BIN" -nt "$SLICER_BIN" ]; }; then
  SLICER_BIN="$RELEASE_BIN"
fi
echo "==> Using $SLICER_BIN"
SIM_BIN="$PRINTER_DIR/build/darwin_arm64-debug/hw-printer-sim"
HOST_BIN="$PRINTER_DIR/build/darwin_arm64-debug/hw-printer"

OUT_DIR="$ROOT_DIR/build/test-out/sim-verify"
mkdir -p "$OUT_DIR"

MODEL="${1:-}"
shift || true

if [ -z "$MODEL" ]; then
  MODEL="$OUT_DIR/sim-pad.obj"
  cat > "$MODEL" <<'EOF'
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
fi

if [ ! -x "$SLICER_BIN" ]; then
  echo "error: hw-slicer-cli not found; run ./build.sh cli-release or ./build.sh debug" >&2
  exit 1
fi
if [ ! -x "$SIM_BIN" ] || [ ! -x "$HOST_BIN" ]; then
  if [ ! -x "$PRINTER_DIR/build.sh" ]; then
    echo "error: hw-printer / hw-printer-sim missing and $PRINTER_DIR/build.sh not found" >&2
    exit 1
  fi
  echo "==> Building hw-printer and hw-printer-sim (debug)"
  (cd "$PRINTER_DIR" && ./build.sh debug darwin_arm64)
  if [ ! -x "$SIM_BIN" ] || [ ! -x "$HOST_BIN" ]; then
    echo "error: hw-printer build did not produce $SIM_BIN and $HOST_BIN" >&2
    exit 1
  fi
fi

GCODE="$OUT_DIR/job.gcode"
STEPS="$OUT_DIR/job.steps"
SIM_LOG="$OUT_DIR/sim.log"
HOST_LOG="$OUT_DIR/host.log"
SLICE_LOG="$OUT_DIR/slice.log"
PTY_LINK="/tmp/hw-slicer-verify-$$"

cleanup() {
  if [ -n "${SIM_PID:-}" ]; then
    kill "$SIM_PID" 2>/dev/null || true
    wait "$SIM_PID" 2>/dev/null || true
  fi
  rm -f "$PTY_LINK"
}
trap cleanup EXIT

echo "==> Slicing $MODEL"
"$SLICER_BIN" --input="$MODEL" \
  --printer=vcore3 \
  --material=pla \
  --process=0.28-draft \
  --set arc_fitting=true \
  --set z_hop_mm=0.4 \
  "$@" \
  --out="$GCODE" | tee "$SLICE_LOG"

PRED_FILAMENT="$(sed -n 's/.*filament=\([0-9.]*\) mm.*/\1/p' "$SLICE_LOG" | head -n 1)"
if [ -z "$PRED_FILAMENT" ]; then
  echo "FAIL: could not parse predicted filament from slicer output" >&2
  exit 1
fi

echo "==> Starting local hw-printer-sim on $PTY_LINK"
"$SIM_BIN" --link="$PTY_LINK" --steps="$STEPS" >"$SIM_LOG" 2>&1 &
SIM_PID=$!

for _ in $(seq 1 50); do
  [ -e "$PTY_LINK" ] && break
  sleep 0.1
done

echo "==> Running hw-printer against $GCODE (--skip-heat)"
"$HOST_BIN" --serial="$PTY_LINK" --gcode="$GCODE" --skip-heat >"$HOST_LOG" 2>&1

# Stop hw-printer-sim so it flushes and closes the step log before verification
kill "$SIM_PID" 2>/dev/null || true
wait "$SIM_PID" 2>/dev/null || true
SIM_PID=""

# Assert zero errors, warnings, or shutdowns in host and sim logs
if grep -E '\[(ERROR|WARN )\]|shutdown' "$HOST_LOG" "$SIM_LOG" >/dev/null 2>&1; then
  echo "FAIL: warnings, errors, or shutdown detected in logs:" >&2
  grep -E '\[(ERROR|WARN )\]|shutdown' "$HOST_LOG" "$SIM_LOG" >&2
  exit 1
fi

# Assert final extruded E matches slicer prediction within 0.05 mm
ACTUAL_E="$(sed -n 's/.*E \([0-9.]*\)$/\1/p' "$HOST_LOG" | tail -n 1)"
if [ -z "$ACTUAL_E" ]; then
  echo "FAIL: could not parse final E from host log" >&2
  exit 1
fi
awk -v pred="$PRED_FILAMENT" -v act="$ACTUAL_E" 'BEGIN {
  d = pred - act; if (d < 0) d = -d;
  if (d > 0.05) {
    printf "FAIL: filament mismatch pred=%.2f mm actual=%.2f mm (delta=%.3f mm)\n", pred, act, d > "/dev/stderr";
    exit 1;
  }
}'

# Assert all 6 steppers executed steps and triple-Z (PC13/PE2/PE6) are in exact lockstep
TOTAL_STEPS="$(wc -l < "$STEPS" | tr -d ' ')"
awk '
  { c[$1]++ }
  END {
    pins[1]="PF13"; pins[2]="PG0"; pins[3]="PC13"; pins[4]="PE2"; pins[5]="PE6"; pins[6]="PF11";
    for (i = 1; i <= 6; i++) {
      p = pins[i];
      if (c[p] + 0 <= 0) {
        printf "FAIL: pin %s recorded 0 steps\n", p > "/dev/stderr";
        exit 1;
      }
    }
    if (c["PC13"] != c["PE2"] || c["PC13"] != c["PE6"]) {
      printf "FAIL: triple-Z mismatch PC13=%d PE2=%d PE6=%d\n", c["PC13"], c["PE2"], c["PE6"] > "/dev/stderr";
      exit 1;
    }
    for (i = 1; i <= 6; i++) {
      printf "    pin %-4s : %d steps\n", pins[i], c[pins[i]];
    }
  }
' "$STEPS"

echo "==> PASS: Closed-loop print verified (filament=${ACTUAL_E}mm vs pred=${PRED_FILAMENT}mm, steps=${TOTAL_STEPS}, triple-Z lockstep)"
