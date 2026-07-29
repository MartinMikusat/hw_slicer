import assert from "node:assert/strict";
import test from "node:test";

import { actionSlotFromKey } from "../src/lib/action-shortcuts.ts";

test("maps the physical number row independently of the keyboard layout", () => {
  assert.equal(actionSlotFromKey("Digit1", "+"), 1);
  assert.equal(actionSlotFromKey("Digit4", "č"), 4);
});

test("maps numpad and numeric key events", () => {
  assert.equal(actionSlotFromKey("Numpad2", "2"), 2);
  assert.equal(actionSlotFromKey("Unidentified", "3"), 3);
});

test("ignores keys outside the numbered action range", () => {
  assert.equal(actionSlotFromKey("Digit5", "5"), null);
  assert.equal(actionSlotFromKey("KeyA", "a"), null);
});
