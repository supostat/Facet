// The JS write side of the upper-seam mutation codec (Р5): it emits the same flat
// tagged binary stream that the Zig decoder (src/core/mutations.zig) reads, so a React
// commit flushes one ArrayBuffer per commit. This file is a HAND-WRITTEN PLACEHOLDER
// whose layout constants mirror the Zig layout table by hand; it is NOT compiled or
// wired in this phase (no TS toolchain exists yet — empty package.json, no esbuild/tsc).
// The round-trip is closed Zig-side by a co-located encoding helper derived from the
// same comptime layout description; this file stands up with the React host config in a
// later phase, when the TS toolchain lands and a layout-constants drift lock against the
// Zig table is added.

/// The mutation tag byte, mirroring the Zig `Tag` enum discriminants exactly. The numeric
/// value IS the on-wire tag; it must match src/core/mutations.zig.
export const Tag = {
  Create: 0,
  Update: 1,
  Append: 2,
  Insert: 3,
  Remove: 4,
} as const;

/// The fixed bit position of each prop in the UPDATE propMask, mirroring the Zig `Prop`
/// declaration order (the wire-format invariant the Zig `expected_bit` lock pins). Only
/// the 17 f32-valued props are encodable this phase; the three reserved positions
/// (crossAlign / direction / text) are listed for bit-position parity but rejected by the
/// Zig decoder as BadPropMask until their enum/string encoding lands with the host config.
export const PropBit = {
  positionX: 0,
  positionY: 1,
  width: 2,
  height: 3,
  colorR: 4,
  colorG: 5,
  colorB: 6,
  colorA: 7,
  cornerRadius: 8,
  mainSize: 9,
  crossSize: 10,
  paddingTop: 11,
  paddingRight: 12,
  paddingBottom: 13,
  paddingLeft: 14,
  gap: 15,
  flexGrow: 16,
  // Reserved bit positions — not encodable this phase (rejected by the Zig decoder).
  crossAlign: 17,
  direction: 18,
  text: 19,
} as const;

/// The element kind byte in a CREATE, mirroring the Zig `Kind` enum discriminants.
export const Kind = {
  View: 0,
  Text: 1,
} as const;

/// A single mutation the host config queues during a React commit.
export type Mutation =
  | { tag: typeof Tag.Create; id: number; kind: number }
  | { tag: typeof Tag.Update; id: number; props: ReadonlyArray<{ bit: number; value: number }> }
  | { tag: typeof Tag.Append; parent: number; child: number }
  | { tag: typeof Tag.Insert; parent: number; child: number; anchor: number }
  | { tag: typeof Tag.Remove; id: number };

/// Encodes a batch of mutations into the flat binary ArrayBuffer the Zig decoder reads.
/// Not implemented in this phase: the React host config that drives it stands up with the
/// TS toolchain in a later phase. The round-trip is exercised Zig-side meanwhile.
export function encodeMutations(_mutations: ReadonlyArray<Mutation>): ArrayBuffer {
  throw new Error("encodeMutations is not wired yet; the React host config lands with the TS toolchain (Ф17)");
}
