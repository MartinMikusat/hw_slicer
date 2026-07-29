export type ActionSlot = 1 | 2 | 3 | 4;

export function actionSlotFromKey(code: string, key: string): ActionSlot | null {
  const codeMatch = /^(?:Digit|Numpad)([1-4])$/.exec(code);
  const keyMatch = /^[1-4]$/.exec(key);
  const value = codeMatch?.[1] ?? keyMatch?.[0];
  return value ? (Number(value) as ActionSlot) : null;
}
