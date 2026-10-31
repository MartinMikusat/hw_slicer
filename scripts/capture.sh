#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT=${1:-"$ROOT/.hw-slicer-runtime/capture.png"}
mkdir -p "$(dirname "$OUTPUT")"

WINDOW_ID=$(
  swift - <<'SWIFT'
import CoreGraphics
import Foundation

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    let layer = window[kCGWindowLayer as String] as? Int ?? -1
    guard layer == 0, owner == "HWSlicer" || owner == "HW Slicer" else { continue }
    if let number = window[kCGWindowNumber as String] as? Int {
        print(number)
        exit(0)
    }
}
exit(1)
SWIFT
) || {
  echo "[hw_slicer] no visible HWSlicer window" >&2
  exit 1
}

screencapture -x -o -l"$WINDOW_ID" "$OUTPUT"
printf '[hw_slicer] captured window %s to %s\n' "$WINDOW_ID" "$OUTPUT"
