const std = @import("std");
const tree = @import("tree.zig");
const dirty = @import("dirty.zig");
const Tree = tree.Tree;
const Node = tree.Node;
const Kind = tree.Kind;

/// The wire-contract prop type: the Ф10 dirty Prop, re-exported so the propMask bit
/// positions, the encodable predicate, and debug.zig's dumpMutations all name one type.
/// Reusing it makes the Prop DECLARATION ORDER a wire-format invariant (the expected_bit
/// lock pins it).
pub const Prop = dirty.Prop;

// mutations.zig is the Zig decode endpoint of the UPPER seam (Р5): the flat binary
// mutation stream React's host config (Ф17) emits is read here linearly, applied to
// the shadow tree (Ф7), and routed through the dirty classifier (Ф10). The wire
// layout is declared ONCE in tag_layouts and the propMask is positional over the Ф10
// Prop enum, so the JS encoder, this decoder, and debug.zig's dumpMutations all share
// one source of truth — a desync is a compile error (the expected_bit lock + the
// applyProp total switch), not a runtime bug. The buffer is the one externally-shaped
// input path (§4), so apply is reject-whole-buffer: a first pass validates the whole
// buffer touching NO tree state, a second pass applies only on full success, leaving
// the tree + dirty flags byte-identical on any malformed input.

/// The five mutation kinds. The discriminant is the on-wire tag byte; reordering or
/// renumbering changes the wire format, so the value is frozen by this declaration
/// and mirrored in src/ui/mutationCodec.ts.
pub const Tag = enum(u8) {
    create,
    update,
    append,
    insert,
    remove,
};

/// The typed errors applyMutations surfaces at the boundary. Every one is a recoverable
/// rejection of malformed input — never a panic, never a partially-mutated tree.
/// ShortRead: a read ran past the buffer end. UnknownTag: a tag byte outside Tag.
/// UnknownKind: a CREATE element kind outside Kind. BadPropMask: a propMask bit that is
/// out of range or names a non-encodable prop. UnknownId: an operand id not live at that
/// point in the buffer. DuplicateId: a CREATE of an id already live. InvalidAnchor: an
/// INSERT anchor that is not a real child of the named parent. AlreadyParented: an
/// APPEND/INSERT whose child already has a parent (re-parenting/duplicate-parent) — node
/// MOVES are out of scope for Ф16, deferred to Ф17's reconciler host config. WouldCycle:
/// an APPEND/INSERT whose parent is a descendant of the child, which would close a cycle.
/// OutOfMemory: an arena or scratch allocation failed.
pub const ApplyError = error{
    ShortRead,
    UnknownTag,
    UnknownKind,
    BadPropMask,
    UnknownId,
    DuplicateId,
    InvalidAnchor,
    AlreadyParented,
    WouldCycle,
    OutOfMemory,
};

/// The number of Prop variants, the wire width of the propMask in bits. The mask is a
/// u32, so this must stay ≤ 32 — asserted by the expected_bit lock below.
pub const PROP_COUNT = @typeInfo(Prop).@"enum".fields.len;

/// A prop's fixed bit position in the propMask: its `@intFromEnum` position, so the bit
/// order IS the Prop declaration order. Frozen against the JS wire contract by the
/// expected_bit lock so a Prop reorder is a compile error, not a silent wire desync.
pub fn propBit(prop: Prop) u5 {
    return @intFromEnum(prop);
}

/// Whether a prop carries an f32 value on the wire this phase. The three non-f32 props
/// (cross_align/direction enums, text ?[]const u8) are reserved bit positions but
/// REJECTED as BadPropMask — their enum/string encoding lands with the host config
/// (Ф17). A total switch with no else so a new Prop must be classified here too.
pub fn encodable(prop: Prop) bool {
    return switch (prop) {
        .position_x,
        .position_y,
        .width,
        .height,
        .color_r,
        .color_g,
        .color_b,
        .color_a,
        .corner_radius,
        .main_size,
        .cross_size,
        .padding_top,
        .padding_right,
        .padding_bottom,
        .padding_left,
        .gap,
        .flex_grow,
        => true,
        .cross_align,
        .direction,
        .text,
        => false,
    };
}

/// A field a tag carries on the wire, in declared order. id/kind/prop_mask are
/// fixed-width; masked_values is the variable run of f32s for the bits set in the
/// preceding prop_mask (only UPDATE has it, and only after a prop_mask field).
const FieldKind = enum { id, kind, prop_mask, masked_values };

/// The ONE wire-layout description: each tag's field list in canonical order. The
/// decoder (validatePass/applyPass via Cursor) and the encoder (encode, the round-trip
/// helper) both walk THIS table, so the two sides cannot diverge by construction. A
/// changed field list moves both sides together.
const tag_layouts = layouts: {
    var table: [@typeInfo(Tag).@"enum".fields.len][]const FieldKind = undefined;
    table[@intFromEnum(Tag.create)] = &.{ .id, .kind };
    table[@intFromEnum(Tag.update)] = &.{ .id, .prop_mask, .masked_values };
    table[@intFromEnum(Tag.append)] = &.{ .id, .id };
    table[@intFromEnum(Tag.insert)] = &.{ .id, .id, .id };
    table[@intFromEnum(Tag.remove)] = &.{.id};
    break :layouts table;
};

/// The byte width of each fixed-width wire field. masked_values is variable and not
/// listed here; its width is popcount(mask) * VALUE_WIDTH, computed at read time.
const TAG_WIDTH = 1;
const ID_WIDTH = 4;
const KIND_WIDTH = 1;
const MASK_WIDTH = 4;
const VALUE_WIDTH = 4;

/// A bounds-checked linear reader over the mutation buffer. Every read advances offset
/// and rejects a read past the end as ShortRead BEFORE touching the bytes, so a
/// truncated buffer is a recoverable error, never an out-of-bounds access. The readers
/// are pub so debug.zig's dumpMutations decodes the same stream through them.
pub const Cursor = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn remaining(self: *const Cursor) usize {
        return self.bytes.len - self.offset;
    }

    fn atEnd(self: *const Cursor) bool {
        return self.offset == self.bytes.len;
    }

    pub fn readTag(self: *Cursor) ApplyError!Tag {
        if (self.remaining() < TAG_WIDTH) return error.ShortRead;
        const byte = self.bytes[self.offset];
        self.offset += TAG_WIDTH;
        return std.meta.intToEnum(Tag, byte) catch error.UnknownTag;
    }

    pub fn readKind(self: *Cursor) ApplyError!Kind {
        if (self.remaining() < KIND_WIDTH) return error.ShortRead;
        const byte = self.bytes[self.offset];
        self.offset += KIND_WIDTH;
        return std.meta.intToEnum(Kind, byte) catch error.UnknownKind;
    }

    pub fn readId(self: *Cursor) ApplyError!u32 {
        if (self.remaining() < ID_WIDTH) return error.ShortRead;
        const value = std.mem.readInt(u32, self.bytes[self.offset..][0..ID_WIDTH], .little);
        self.offset += ID_WIDTH;
        return value;
    }

    pub fn readMask(self: *Cursor) ApplyError!u32 {
        if (self.remaining() < MASK_WIDTH) return error.ShortRead;
        const value = std.mem.readInt(u32, self.bytes[self.offset..][0..MASK_WIDTH], .little);
        self.offset += MASK_WIDTH;
        return value;
    }

    pub fn readValue(self: *Cursor) ApplyError!f32 {
        if (self.remaining() < VALUE_WIDTH) return error.ShortRead;
        const bits = std.mem.readInt(u32, self.bytes[self.offset..][0..VALUE_WIDTH], .little);
        self.offset += VALUE_WIDTH;
        return @as(f32, @bitCast(bits));
    }
};

/// Validates a propMask: every set bit must be in range AND name an encodable prop.
/// A bit ≥ PROP_COUNT, or a bit naming a reserved non-f32 prop (cross_align/direction/
/// text), is BadPropMask. Returns the count of set (and so value-bearing) bits.
fn validateMask(mask: u32) ApplyError!u6 {
    var bit: u5 = 0;
    while (bit < PROP_COUNT) : (bit += 1) {
        if (mask & (@as(u32, 1) << bit) != 0) {
            if (!encodable(@enumFromInt(bit))) return error.BadPropMask;
        }
    }
    // Any bit at or above PROP_COUNT is a reserved/undefined position.
    const out_of_range_mask: u32 = if (PROP_COUNT >= 32) 0 else ~((@as(u32, 1) << @intCast(PROP_COUNT)) - 1);
    if (mask & out_of_range_mask != 0) return error.BadPropMask;
    return @popCount(mask);
}

/// Applies one masked f32 value to its prop on a node, raising the correct dirty flag.
/// A TOTAL switch with NO else (mirroring dirty.classify) so every encodable Prop maps
/// to exactly one arm and an unclassified Prop is a compile error. The paint arm builds
/// a single-field PropsUpdate via an inline switch and routes through Tree.updateNodeProps
/// (which raises paint_dirty), so the paint write stays on the one updateNodeProps path.
/// The layout f32 arm writes the Node field directly then routes the dirty class through
/// dirty.markDirty (which bubbles layout_dirty). The three reserved non-encodable props
/// are unreachable: pass 1 rejected any mask bit naming them.
fn applyProp(node: *Node, prop: Prop, value: f32) void {
    switch (prop) {
        .position_x,
        .position_y,
        .width,
        .height,
        .color_r,
        .color_g,
        .color_b,
        .color_a,
        .corner_radius,
        => {
            var update: tree.PropsUpdate = .{};
            switch (prop) {
                inline .position_x,
                .position_y,
                .width,
                .height,
                .color_r,
                .color_g,
                .color_b,
                .color_a,
                .corner_radius,
                => |paint_prop| @field(update, @tagName(paint_prop)) = value,
                else => unreachable,
            }
            Tree.updateNodeProps(node, update);
        },
        .main_size,
        .cross_size,
        .padding_top,
        .padding_right,
        .padding_bottom,
        .padding_left,
        .gap,
        .flex_grow,
        => {
            switch (prop) {
                inline .main_size,
                .cross_size,
                .padding_top,
                .padding_right,
                .padding_bottom,
                .padding_left,
                .gap,
                .flex_grow,
                => |layout_prop| @field(node, @tagName(layout_prop)) = value,
                else => unreachable,
            }
            dirty.markDirty(node, prop);
        },
        .cross_align, .direction, .text => unreachable,
    }
}

/// Applies a flat mutation buffer to the tree with reject-whole-buffer atomicity. An
/// empty buffer is an explicit no-op success. validatePass touches no tree state; only
/// on its full success does applyPass run, so any ApplyError leaves the tree and all
/// dirty flags byte-identical to the pre-call state. []const u8 is read-only so the
/// facade's mutable []u8 from arrayBufferBytes coerces in cleanly (Ф17).
pub fn applyMutations(t: *Tree, bytes: []const u8) ApplyError!void {
    if (bytes.len == 0) return;
    try validatePass(t, bytes);
    try applyPass(t, bytes);
}

/// The first (validate) pass: walks the whole buffer against a running model of which
/// ids are live, which children each parent has, and which parent each child has, WITHOUT
/// mutating the tree. It seeds the live-id set lazily from the real tree and the parent→
/// child adjacency lazily per touched parent, then mirrors each tag's structural effect
/// into that model so a forward reference to an id CREATEd earlier in the same buffer is
/// legal and an INSERT anchor's child-of-parent validity is checked here — preventing the
/// tree.zig childIndex unreachable in pass 2. The parent_of map (child→parent) lets the
/// two structural guards run in O(depth): an APPEND/INSERT of an already-parented child is
/// AlreadyParented (no re-parenting in Ф16 — moves are deferred to Ф17), and an APPEND/
/// INSERT whose parent is a descendant of the child is WouldCycle. parent_of overlays the
/// real tree's `.parent`: an in-buffer attach records parent_of[child]=parent, a REMOVE
/// drops the pruned ids' entries, and an unrecorded id falls back to the live tree's
/// `child.parent`. All scratch lives on the backing allocator (t.nodes.allocator), NOT the
/// tree arena.
fn validatePass(t: *Tree, bytes: []const u8) ApplyError!void {
    const scratch = t.nodes.allocator;

    var live = std.AutoHashMap(u32, void).init(scratch);
    defer live.deinit();
    {
        var it = t.nodes.keyIterator();
        while (it.next()) |id| try live.put(id.*, {});
    }

    var adjacency = std.AutoHashMap(u32, std.ArrayList(u32)).init(scratch);
    defer {
        var values = adjacency.valueIterator();
        while (values.next()) |list| list.deinit(scratch);
        adjacency.deinit();
    }

    var parent_of = std.AutoHashMap(u32, u32).init(scratch);
    defer parent_of.deinit();

    // The ids this buffer CREATEd: model-parentless until an in-buffer attach, so their
    // parenthood reads ONLY from the model (parent_of), never from a stale live-tree
    // `.parent`. This is the seam that makes REMOVE-then-CREATE of the same id legal — the
    // reborn id's old node still carries its pre-REMOVE `.parent` (validatePass never
    // mutates the tree), and orphaned overrides that ghost.
    var orphaned = std.AutoHashMap(u32, void).init(scratch);
    defer orphaned.deinit();

    var cursor: Cursor = .{ .bytes = bytes };
    while (!cursor.atEnd()) {
        switch (try cursor.readTag()) {
            .create => {
                const id = try cursor.readId();
                _ = try cursor.readKind();
                if (live.contains(id)) return error.DuplicateId;
                try live.put(id, {});
                try orphaned.put(id, {});
            },
            .update => {
                const id = try cursor.readId();
                if (!live.contains(id)) return error.UnknownId;
                const value_count = try validateMask(try cursor.readMask());
                var read: u6 = 0;
                while (read < value_count) : (read += 1) _ = try cursor.readValue();
            },
            .append => {
                const parent = try cursor.readId();
                const child = try cursor.readId();
                if (!live.contains(parent) or !live.contains(child)) return error.UnknownId;
                if (isParented(t, &parent_of, &orphaned, child)) return error.AlreadyParented;
                if (wouldCycle(t, &parent_of, &orphaned, parent, child)) return error.WouldCycle;
                try appendToAdjacency(t, scratch, &adjacency, parent, child);
                try parent_of.put(child, parent);
            },
            .insert => {
                const parent = try cursor.readId();
                const child = try cursor.readId();
                const anchor = try cursor.readId();
                if (!live.contains(parent) or !live.contains(child) or !live.contains(anchor)) {
                    return error.UnknownId;
                }
                if (isParented(t, &parent_of, &orphaned, child)) return error.AlreadyParented;
                if (wouldCycle(t, &parent_of, &orphaned, parent, child)) return error.WouldCycle;
                try insertIntoAdjacency(t, scratch, &adjacency, parent, child, anchor);
                try parent_of.put(child, parent);
            },
            .remove => {
                const id = try cursor.readId();
                if (!live.contains(id)) return error.UnknownId;
                removeSubtreeFromModel(t, &live, &adjacency, &parent_of, &orphaned, scratch, id);
            },
        }
    }
}

/// Whether child already has a parent in the validate model: a recorded in-buffer attach
/// (parent_of) OR — for an id NOT created in this buffer — a real non-null `child.parent` on
/// the live tree. Forbids re-parenting and the duplicate-parent corruption (the same child
/// APPENDed under two parents). An in-buffer-CREATEd id (in `orphaned`, and not yet in
/// parent_of) reads parentless and ignores any stale live-tree `.parent` left by a
/// REMOVE-then-CREATE of the same id. The live `.parent` is a read-only consult —
/// validatePass never mutates the tree.
fn isParented(
    t: *Tree,
    parent_of: *const std.AutoHashMap(u32, u32),
    orphaned: *const std.AutoHashMap(u32, void),
    child: u32,
) bool {
    if (parent_of.contains(child)) return true;
    if (orphaned.contains(child)) return false;
    if (t.lookup(child)) |node| return node.parent != null;
    return false;
}

/// Whether attaching child under parent would close a cycle: true iff parent is a
/// descendant of child (including parent == child, a self-parent). Walks parent's ancestor
/// chain — first the validate model's parent_of, then (for an id NOT CREATEd in this
/// buffer) the real tree's `.parent` — and reports a cycle if it reaches child. A
/// model-parentless ancestor (in parent_of: no; in orphaned: yes, OR a real root) ends the
/// walk. A fresh parentless parent has an empty ancestor chain and can never reach child,
/// so legitimate tree-building passes. The walk terminates: every step moves strictly
/// toward a root, and isParented already rejected an already-parented child, so the model
/// holds no pre-existing cycle to loop on.
fn wouldCycle(
    t: *Tree,
    parent_of: *const std.AutoHashMap(u32, u32),
    orphaned: *const std.AutoHashMap(u32, void),
    parent: u32,
    child: u32,
) bool {
    var ancestor: u32 = parent;
    while (true) {
        if (ancestor == child) return true;
        if (parent_of.get(ancestor)) |next| {
            ancestor = next;
        } else if (orphaned.contains(ancestor)) {
            return false;
        } else if (t.lookup(ancestor)) |node| {
            if (node.parent) |real_parent| {
                ancestor = real_parent.id;
            } else return false;
        } else return false;
    }
}

/// Mirrors Tree.unregisterSubtree in the validate model: prunes id AND every descendant
/// from the live set, drops their adjacency entries, and drops their parent_of/orphaned
/// entries, so a later op naming any removed descendant rejects with UnknownId (not a
/// now-unregistered lookup `.?` on null in applyPass), a post-REMOVE INSERT cannot consult a
/// stale child list (no childIndex unreachable in the tree), and a REMOVE-then-re-attach of
/// a freed id is legal (the parent_of map never goes stale). It walks BOTH the validate
/// adjacency model (children APPENDed/INSERTed in THIS buffer) and the real tree
/// (pre-existing descendants), so an in-buffer-attached child and a pre-existing one are
/// both pruned. The two sources may name the same descendant; live.remove,
/// adjacency.fetchRemove, and parent_of/orphaned removal are idempotent so a double visit is
/// harmless and the walk terminates (every id is removed from live once).
fn removeSubtreeFromModel(
    t: *Tree,
    live: *std.AutoHashMap(u32, void),
    adjacency: *std.AutoHashMap(u32, std.ArrayList(u32)),
    parent_of: *std.AutoHashMap(u32, u32),
    orphaned: *std.AutoHashMap(u32, void),
    scratch: std.mem.Allocator,
    id: u32,
) void {
    _ = live.remove(id);
    _ = parent_of.remove(id);
    _ = orphaned.remove(id);
    if (adjacency.fetchRemove(id)) |entry| {
        var children = entry.value;
        for (children.items) |child| removeSubtreeFromModel(t, live, adjacency, parent_of, orphaned, scratch, child);
        children.deinit(scratch);
    } else if (t.lookup(id)) |node| {
        for (node.children.items) |child| removeSubtreeFromModel(t, live, adjacency, parent_of, orphaned, scratch, child.id);
    }
}

/// The lazily-materialized child list of a parent in the validate model, seeded once
/// from the parent's real children and mutated for in-buffer APPEND/INSERT. The first
/// touch copies the live children so a buffer-local insert/append builds on the real
/// structure without mutating the tree.
fn adjacencyEntry(
    t: *Tree,
    scratch: std.mem.Allocator,
    adjacency: *std.AutoHashMap(u32, std.ArrayList(u32)),
    parent: u32,
) ApplyError!*std.ArrayList(u32) {
    const gop = try adjacency.getOrPut(parent);
    if (!gop.found_existing) {
        gop.value_ptr.* = .empty;
        if (t.lookup(parent)) |node| {
            for (node.children.items) |child| try gop.value_ptr.append(scratch, child.id);
        }
    }
    return gop.value_ptr;
}

fn appendToAdjacency(
    t: *Tree,
    scratch: std.mem.Allocator,
    adjacency: *std.AutoHashMap(u32, std.ArrayList(u32)),
    parent: u32,
    child: u32,
) ApplyError!void {
    const children = try adjacencyEntry(t, scratch, adjacency, parent);
    try children.append(scratch, child);
}

fn insertIntoAdjacency(
    t: *Tree,
    scratch: std.mem.Allocator,
    adjacency: *std.AutoHashMap(u32, std.ArrayList(u32)),
    parent: u32,
    child: u32,
    anchor: u32,
) ApplyError!void {
    const children = try adjacencyEntry(t, scratch, adjacency, parent);
    const anchor_index = std.mem.indexOfScalar(u32, children.items, anchor) orelse return error.InvalidAnchor;
    try children.insert(scratch, anchor_index, child);
}

/// The second (apply) pass: a fresh Cursor over the SAME buffer, dispatching each tag to
/// the matching Ф7 tree op. It runs only after validatePass fully succeeded, so every
/// lookup is sound (t.lookup(id).?), every CREATE id is fresh, and every INSERT anchor is
/// a real child — no defensive re-check, no rollback. CREATE bubbles structural-dirty on
/// the new node; APPEND/INSERT on the parent (the gaining container); REMOVE on the
/// parent BEFORE the detach unregisters it. A propless UPDATE (mask 0) reads no values
/// and touches nothing. OutOfMemory from an arena grow propagates; pass 1 already proved
/// the structure, so this is the only residual error and the tree state mirrors a
/// genuine allocation failure (the host re-flushes), not a logic rejection.
fn applyPass(t: *Tree, bytes: []const u8) ApplyError!void {
    var cursor: Cursor = .{ .bytes = bytes };
    while (!cursor.atEnd()) {
        switch (try cursor.readTag()) {
            .create => {
                const id = try cursor.readId();
                const kind = try cursor.readKind();
                const node = try t.createWithId(id, kind);
                dirty.markStructuralDirty(node);
            },
            .update => {
                const node = t.lookup(try cursor.readId()).?;
                const mask = try cursor.readMask();
                var bit: u5 = 0;
                while (bit < PROP_COUNT) : (bit += 1) {
                    if (mask & (@as(u32, 1) << bit) != 0) {
                        applyProp(node, @enumFromInt(bit), try cursor.readValue());
                    }
                }
            },
            .append => {
                const parent = t.lookup(try cursor.readId()).?;
                const child = t.lookup(try cursor.readId()).?;
                try t.appendChild(parent, child);
                dirty.markStructuralDirty(parent);
            },
            .insert => {
                const parent = t.lookup(try cursor.readId()).?;
                const child = t.lookup(try cursor.readId()).?;
                const anchor = t.lookup(try cursor.readId()).?;
                try t.insertBefore(parent, child, anchor);
                dirty.markStructuralDirty(parent);
            },
            .remove => {
                const node = t.lookup(try cursor.readId()).?;
                if (node.parent) |parent| dirty.markStructuralDirty(parent);
                t.removeNode(node);
            },
        }
    }
}

// createWithId from CREATE registers a JS-owned id, so its allocation can fail with
// OutOfMemory; that is the only ApplyError applyPass can raise that validatePass did not
// already exclude. Every other applyPass error union member is structurally impossible
// post-validation, kept only because the shared Cursor readers carry the full ApplyError
// set — they never trigger here.

// ── Round-trip encoder (test helper, derived from the SAME tag_layouts) ──────────────
// The Zig write side that closes the round-trip in this phase (mirroring the
// non-compiled src/ui/mutationCodec.ts placeholder): it walks tag_layouts to emit each
// field, so encode offsets and the Cursor read offsets are both derived from the one
// table and cannot drift. Used only by the co-located tests; the production write side
// is the JS host config (Ф17).

const Encoder = struct {
    buffer: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) Encoder {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Encoder) void {
        self.buffer.deinit(self.allocator);
    }

    fn putTag(self: *Encoder, tag: Tag) !void {
        try self.buffer.append(self.allocator, @intFromEnum(tag));
    }

    fn putKind(self: *Encoder, kind: Kind) !void {
        try self.buffer.append(self.allocator, @intFromEnum(kind));
    }

    fn putU32(self: *Encoder, value: u32) !void {
        var encoded: [4]u8 = undefined;
        std.mem.writeInt(u32, &encoded, value, .little);
        try self.buffer.appendSlice(self.allocator, &encoded);
    }

    fn putValue(self: *Encoder, value: f32) !void {
        try self.putU32(@bitCast(value));
    }

    fn create(self: *Encoder, id: u32, kind: Kind) !void {
        try self.putTag(.create);
        try self.putU32(id);
        try self.putKind(kind);
    }

    /// A single propMask UPDATE: the mask, then the values for the set bits in ascending
    /// bit order — the SAME order applyPass reads them.
    fn update(self: *Encoder, id: u32, props: []const PropValue) !void {
        try self.putTag(.update);
        try self.putU32(id);
        var mask: u32 = 0;
        for (props) |entry| mask |= @as(u32, 1) << propBit(entry.prop);
        try self.putU32(mask);
        var bit: u5 = 0;
        while (bit < PROP_COUNT) : (bit += 1) {
            if (mask & (@as(u32, 1) << bit) != 0) {
                try self.putValue(valueForBit(props, bit));
            }
        }
    }

    fn append(self: *Encoder, parent: u32, child: u32) !void {
        try self.putTag(.append);
        try self.putU32(parent);
        try self.putU32(child);
    }

    fn insert(self: *Encoder, parent: u32, child: u32, anchor: u32) !void {
        try self.putTag(.insert);
        try self.putU32(parent);
        try self.putU32(child);
        try self.putU32(anchor);
    }

    fn remove(self: *Encoder, id: u32) !void {
        try self.putTag(.remove);
        try self.putU32(id);
    }

    fn bytes(self: *const Encoder) []const u8 {
        return self.buffer.items;
    }
};

const PropValue = struct { prop: Prop, value: f32 };

fn valueForBit(props: []const PropValue, bit: u5) f32 {
    for (props) |entry| {
        if (propBit(entry.prop) == bit) return entry.value;
    }
    unreachable;
}

// ── Comptime locks ───────────────────────────────────────────────────────────────────

/// The frozen bit position of every Prop, pinned independently of propBit so a reorder
/// of the Ф10 Prop enum is a compile error here (the Ф10 name-keyed class lock is
/// order-independent and would NOT catch a bit-position desync). The comptime length
/// assert against the enum field count makes the table exhaustive: a new Prop without an
/// entry fails the length assert; a reordered Prop fails the per-entry bit assert.
const expected_bit = [_]struct { prop: Prop, bit: u5 }{
    .{ .prop = .position_x, .bit = 0 },
    .{ .prop = .position_y, .bit = 1 },
    .{ .prop = .width, .bit = 2 },
    .{ .prop = .height, .bit = 3 },
    .{ .prop = .color_r, .bit = 4 },
    .{ .prop = .color_g, .bit = 5 },
    .{ .prop = .color_b, .bit = 6 },
    .{ .prop = .color_a, .bit = 7 },
    .{ .prop = .corner_radius, .bit = 8 },
    .{ .prop = .main_size, .bit = 9 },
    .{ .prop = .cross_size, .bit = 10 },
    .{ .prop = .padding_top, .bit = 11 },
    .{ .prop = .padding_right, .bit = 12 },
    .{ .prop = .padding_bottom, .bit = 13 },
    .{ .prop = .padding_left, .bit = 14 },
    .{ .prop = .gap, .bit = 15 },
    .{ .prop = .flex_grow, .bit = 16 },
    .{ .prop = .cross_align, .bit = 17 },
    .{ .prop = .direction, .bit = 18 },
    .{ .prop = .text, .bit = 19 },
};

comptime {
    std.debug.assert(expected_bit.len == PROP_COUNT);
    std.debug.assert(PROP_COUNT <= 32);
    for (expected_bit) |entry| {
        std.debug.assert(propBit(entry.prop) == entry.bit);
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const debug = @import("debug.zig");

/// A machine-mode tree dump for the atomicity asserts: a malformed buffer must leave this
/// byte-identical to its pre-call value. Caller frees.
fn treeDump(t: *Tree) ![]const u8 {
    var sink: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer sink.deinit();
    try debug.dump(t, &sink.writer, false);
    return sink.toOwnedSlice();
}

/// Asserts applyMutations(bytes) rejects with the expected error AND leaves the tree
/// byte-identical to its pre-call dump (reject-whole-buffer). The decoded buffer is
/// attached on a dump mismatch so a failure localizes to the mutation that corrupted state.
fn expectRejectedAtomic(t: *Tree, bytes: []const u8, expected: ApplyError) !void {
    const before = try treeDump(t);
    defer testing.allocator.free(before);

    try testing.expectError(expected, applyMutations(t, bytes));

    const after = try treeDump(t);
    defer testing.allocator.free(after);

    if (!std.mem.eql(u8, before, after)) {
        var decoded: std.Io.Writer.Allocating = .init(testing.allocator);
        defer decoded.deinit();
        debug.dumpMutations(bytes, &decoded.writer, false) catch {};
        std.debug.print("tree mutated by a rejected buffer\n{s}\n", .{decoded.written()});
    }
    try testing.expectEqualStrings(before, after);
}

test "the propMask bit positions are pinned to the frozen wire contract" {
    comptime std.debug.assert(expected_bit.len == @typeInfo(Prop).@"enum".fields.len);
    inline for (expected_bit) |entry| {
        try testing.expectEqual(entry.bit, propBit(entry.prop));
    }
}

test "the propMask wire width covers every Prop bit" {
    try testing.expect(PROP_COUNT <= 32);
    // The highest valid bit is the last Prop; the mask is a u32, so it spans every bit.
    try testing.expectEqual(@as(u5, PROP_COUNT - 1), propBit(.text));
}

test "an out-of-range propMask bit is rejected as BadPropMask" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    _ = try t.createWithId(0, .view);

    // Bit 20 is one past the highest valid prop (text == 19) → out of range.
    var encoder = Encoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.putTag(.update);
    try encoder.putU32(0);
    try encoder.putU32(@as(u32, 1) << 20);
    try expectRejectedAtomic(&t, encoder.bytes(), error.BadPropMask);
}

test "a propMask bit naming a reserved non-encodable prop is rejected as BadPropMask" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    _ = try t.createWithId(0, .view);

    // bit 19 == text, reserved-but-rejected this phase.
    var encoder = Encoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.putTag(.update);
    try encoder.putU32(0);
    try encoder.putU32(@as(u32, 1) << propBit(.text));
    try expectRejectedAtomic(&t, encoder.bytes(), error.BadPropMask);
}

test "an empty buffer is a no-op success leaving the tree unchanged" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    _ = try t.createWithId(0, .view);

    const before = try treeDump(&t);
    defer testing.allocator.free(before);

    try applyMutations(&t, &.{});

    const after = try treeDump(&t);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "CREATE round-trips to a registered node of the encoded kind" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();

    var encoder = Encoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.create(7, .text);

    try applyMutations(&t, encoder.bytes());

    const node = t.lookup(7).?;
    try testing.expectEqual(Kind.text, node.kind);
    try testing.expectEqual(@as(?*Node, null), node.parent);
}

test "APPEND round-trips a child under a parent in document order" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();

    var encoder = Encoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.create(0, .view);
    try encoder.create(1, .view);
    try encoder.create(2, .view);
    try encoder.append(0, 1);
    try encoder.append(0, 2);

    try applyMutations(&t, encoder.bytes());

    const parent = t.lookup(0).?;
    try testing.expectEqual(@as(usize, 2), parent.children.items.len);
    try testing.expectEqual(@as(u32, 1), parent.children.items[0].id);
    try testing.expectEqual(@as(u32, 2), parent.children.items[1].id);
    try testing.expectEqual(parent, t.lookup(1).?.parent.?);
}

test "INSERT round-trips a child immediately before its anchor" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();

    var encoder = Encoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.create(0, .view);
    try encoder.create(1, .view);
    try encoder.create(2, .view);
    try encoder.create(3, .view);
    try encoder.append(0, 1);
    try encoder.append(0, 2);
    try encoder.insert(0, 3, 2);

    try applyMutations(&t, encoder.bytes());

    const parent = t.lookup(0).?;
    try testing.expectEqual(@as(usize, 3), parent.children.items.len);
    try testing.expectEqual(@as(u32, 1), parent.children.items[0].id);
    try testing.expectEqual(@as(u32, 3), parent.children.items[1].id);
    try testing.expectEqual(@as(u32, 2), parent.children.items[2].id);
}

test "REMOVE round-trips a detach and unregister of the named node" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();

    var encoder = Encoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.create(0, .view);
    try encoder.create(1, .view);
    try encoder.append(0, 1);
    try encoder.remove(1);

    try applyMutations(&t, encoder.bytes());

    try testing.expectEqual(@as(?*Node, null), t.lookup(1));
    try testing.expectEqual(@as(usize, 0), t.lookup(0).?.children.items.len);
}

test "UPDATE round-trips exactly the masked props and leaves the rest byte-unchanged" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const node = try t.createWithId(0, .view);
    node.position_y = 99;
    node.color_g = 0.5;

    var encoder = Encoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.update(0, &.{
        .{ .prop = .position_x, .value = 12 },
        .{ .prop = .color_r, .value = 0.25 },
    });

    try applyMutations(&t, encoder.bytes());

    try testing.expectEqual(@as(f32, 12), node.position_x);
    try testing.expectEqual(@as(f32, 0.25), node.color_r);
    // The unmasked fields are byte-untouched.
    try testing.expectEqual(@as(f32, 99), node.position_y);
    try testing.expectEqual(@as(f32, 0.5), node.color_g);
}

test "a composed sequence builds a known multi-node tree" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();

    var encoder = Encoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.create(0, .view);
    try encoder.create(1, .view);
    try encoder.create(2, .text);
    try encoder.append(0, 1);
    try encoder.append(1, 2);
    try encoder.update(2, &.{.{ .prop = .width, .value = 64 }});

    try applyMutations(&t, encoder.bytes());

    const dumped = try treeDump(&t);
    defer testing.allocator.free(dumped);

    const expected =
        "node id=0 kind=view parent=none children=[1] pos=0.0000,0.0000 size=0.0000,0.0000 color=0.0000,0.0000,0.0000,0.0000 radius=0.0000 layout=0.0000,0.0000,0.0000,0.0000 layout_dirty=true paint_dirty=false\n" ++
        "node id=1 kind=view parent=0 children=[2] pos=0.0000,0.0000 size=0.0000,0.0000 color=0.0000,0.0000,0.0000,0.0000 radius=0.0000 layout=0.0000,0.0000,0.0000,0.0000 layout_dirty=true paint_dirty=false\n" ++
        "node id=2 kind=text parent=1 children=[] pos=0.0000,0.0000 size=64.0000,0.0000 color=0.0000,0.0000,0.0000,0.0000 radius=0.0000 layout=0.0000,0.0000,0.0000,0.0000 layout_dirty=true paint_dirty=true\n";
    try testing.expectEqualStrings(expected, dumped);
}

test "a forward reference to an in-buffer CREATEd id is legal" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();

    var encoder = Encoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.create(0, .view);
    try encoder.create(1, .view);
    try encoder.append(0, 1); // 1 was created earlier in the same buffer

    try applyMutations(&t, encoder.bytes());
    try testing.expectEqual(@as(usize, 1), t.lookup(0).?.children.items.len);
}

test "a REMOVE-then-CREATE of the same id in one buffer is legal" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    _ = try t.createWithId(0, .view);

    var encoder = Encoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.remove(0);
    try encoder.create(0, .text);

    try applyMutations(&t, encoder.bytes());
    try testing.expectEqual(Kind.text, t.lookup(0).?.kind);
}

test "a truncated buffer is a ShortRead and the tree is byte-identical" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    _ = try t.createWithId(0, .view);

    var encoder = Encoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.create(1, .view);
    // Drop the kind byte off the CREATE so the buffer ends mid-record.
    const full = encoder.bytes();
    try expectRejectedAtomic(&t, full[0 .. full.len - 1], error.ShortRead);
}

test "an unknown tag byte is an UnknownTag and the tree is byte-identical" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    _ = try t.createWithId(0, .view);

    try expectRejectedAtomic(&t, &.{0xFF}, error.UnknownTag);
}

test "an unknown CREATE kind is an UnknownKind and the tree is byte-identical" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    _ = try t.createWithId(0, .view);

    var encoder = Encoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.putTag(.create);
    try encoder.putU32(1);
    try encoder.buffer.append(encoder.allocator, 0x7F); // kind byte outside Kind
    try expectRejectedAtomic(&t, encoder.bytes(), error.UnknownKind);
}

test "an operation naming an unregistered id is an UnknownId and the tree is byte-identical" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    _ = try t.createWithId(0, .view);

    var encoder = Encoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.append(0, 42); // 42 was never created

    try expectRejectedAtomic(&t, encoder.bytes(), error.UnknownId);
}

test "a CREATE of an already-live id is a DuplicateId and the tree is byte-identical" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    _ = try t.createWithId(5, .view);

    var encoder = Encoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.create(5, .text);

    try expectRejectedAtomic(&t, encoder.bytes(), error.DuplicateId);
}

test "an INSERT against an anchor that is not a child of the parent is an InvalidAnchor" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    _ = try t.createWithId(0, .view);
    _ = try t.createWithId(1, .view);
    _ = try t.createWithId(2, .view); // exists but is NOT a child of 0

    var encoder = Encoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.insert(0, 1, 2);

    try expectRejectedAtomic(&t, encoder.bytes(), error.InvalidAnchor);
}

test "a malformed mutation late in a buffer rejects the whole buffer atomically" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    _ = try t.createWithId(0, .view);

    // Valid CREATE + APPEND, then a CREATE colliding with the existing id 0 — the
    // earlier valid mutations must NOT be applied (reject-whole-buffer).
    var encoder = Encoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.create(1, .view);
    try encoder.append(0, 1);
    try encoder.create(0, .text);

    try expectRejectedAtomic(&t, encoder.bytes(), error.DuplicateId);
    // The whole buffer was rejected, so node 1 was never created.
    try testing.expectEqual(@as(?*Node, null), t.lookup(1));
}

test "a REMOVE of a parent then a reference to a removed descendant rejects without a panic" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const parent = try t.createWithId(0, .view);
    const child = try t.createWithId(1, .view);
    const grandchild = try t.createWithId(2, .view);
    try t.appendChild(parent, child);
    try t.appendChild(child, grandchild);

    // REMOVE 0 unregisters its whole subtree (1 and 2). A later UPDATE of the
    // now-unregistered grandchild must reject as UnknownId, NOT reach the applyPass
    // t.lookup(2).? on a null id (a panic under ReleaseSafe).
    var encoder = Encoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.remove(0);
    try encoder.update(2, &.{.{ .prop = .position_x, .value = 0 }});

    try expectRejectedAtomic(&t, encoder.bytes(), error.UnknownId);
}

test "a REMOVE of a parent then an INSERT against its former child as anchor rejects without a panic" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const parent = try t.createWithId(0, .view);
    const child = try t.createWithId(1, .view);
    try t.appendChild(parent, child);
    _ = try t.createWithId(2, .view); // a live node to try to INSERT

    // REMOVE 0 unregisters 0 and 1. An INSERT naming the removed parent (and the
    // removed child as anchor) must reject as UnknownId — never consult a stale
    // adjacency child list and never reach the tree.zig childIndex unreachable.
    var encoder = Encoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.remove(0);
    try encoder.insert(0, 2, 1);

    try expectRejectedAtomic(&t, encoder.bytes(), error.UnknownId);
}

test "a buffer that would close a parent-child cycle rejects as WouldCycle without a stack overflow" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();

    // CREATE 0, 1; APPEND 0<-1 (1 under 0); APPEND 1<-0 — the second attach makes 0 a
    // child of 1 while 1 is already a child of 0, closing a cycle. Caught at validatePass
    // as WouldCycle, so the whole buffer is rejected and no tree walk ever recurses forever.
    var encoder = Encoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.create(0, .view);
    try encoder.create(1, .view);
    try encoder.append(0, 1);
    try encoder.append(1, 0);

    try expectRejectedAtomic(&t, encoder.bytes(), error.WouldCycle);
}

test "a buffer that gives one child two parents rejects as AlreadyParented" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();

    // CREATE 0, 1, 2; APPEND 0<-2; APPEND 1<-2 — node 2 attached under both 0 and 1. The
    // second attach sees 2 already parented and rejects as AlreadyParented (no duplicate
    // parent escapes the boundary).
    var encoder = Encoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.create(0, .view);
    try encoder.create(1, .view);
    try encoder.create(2, .view);
    try encoder.append(0, 2);
    try encoder.append(1, 2);

    try expectRejectedAtomic(&t, encoder.bytes(), error.AlreadyParented);
}

test "a self-parenting APPEND rejects as WouldCycle" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();

    // APPEND 0<-0: parent == child, the degenerate cycle. The parentless child 0 is not
    // yet parented, so the cycle guard (parent is a descendant of child, parent == child)
    // fires first as WouldCycle.
    var encoder = Encoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.create(0, .view);
    try encoder.append(0, 0);

    try expectRejectedAtomic(&t, encoder.bytes(), error.WouldCycle);
}

test "re-parenting a child already attached on the live tree rejects as AlreadyParented" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const parent = try t.createWithId(0, .view);
    const child = try t.createWithId(1, .view);
    const other = try t.createWithId(2, .view);
    try t.appendChild(parent, child); // 1 is a live child of 0
    _ = other;

    // APPEND 2<-1 would move the live child 1 under a new parent 2 — a node MOVE, out of
    // scope for Ф16. The live `.parent` is consulted read-only and the move is rejected.
    var encoder = Encoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.append(2, 1);

    try expectRejectedAtomic(&t, encoder.bytes(), error.AlreadyParented);
}

test "a REMOVE frees an id so it can be re-attached fresh later in the same buffer" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const parent = try t.createWithId(0, .view);
    const child = try t.createWithId(1, .view);
    const adopter = try t.createWithId(2, .view);
    try t.appendChild(parent, child); // 1 starts as a child of 0
    _ = adopter;

    // REMOVE 1 unregisters it (dropping its parent_of entry), CREATE 1 reborns it
    // parentless, APPEND 2<-1 attaches the fresh id under 2 — legal, no AlreadyParented
    // from a stale parent_of/`.parent`.
    var encoder = Encoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.remove(1);
    try encoder.create(1, .view);
    try encoder.append(2, 1);

    try applyMutations(&t, encoder.bytes());

    try testing.expectEqual(@as(usize, 0), t.lookup(0).?.children.items.len);
    try testing.expectEqual(@as(usize, 1), t.lookup(2).?.children.items.len);
    try testing.expectEqual(@as(u32, 1), t.lookup(2).?.children.items[0].id);
    try testing.expectEqual(t.lookup(2).?, t.lookup(1).?.parent.?);
}

test "a legitimate multi-node build with APPEND and INSERT of fresh children passes" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();

    // A deep, branching build: every attached child is a freshly CREATEd, not-yet-parented
    // node, so neither structural guard fires and the tree builds exactly as encoded.
    var encoder = Encoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.create(0, .view);
    try encoder.create(1, .view);
    try encoder.create(2, .view);
    try encoder.create(3, .view);
    try encoder.create(4, .view);
    try encoder.append(0, 1);
    try encoder.append(0, 3);
    try encoder.insert(0, 2, 3); // 2 lands between 1 and 3
    try encoder.append(1, 4); // a grandchild under 1

    try applyMutations(&t, encoder.bytes());

    const root = t.lookup(0).?;
    try testing.expectEqual(@as(usize, 3), root.children.items.len);
    try testing.expectEqual(@as(u32, 1), root.children.items[0].id);
    try testing.expectEqual(@as(u32, 2), root.children.items[1].id);
    try testing.expectEqual(@as(u32, 3), root.children.items[2].id);
    try testing.expectEqual(@as(usize, 1), t.lookup(1).?.children.items.len);
    try testing.expectEqual(@as(u32, 4), t.lookup(1).?.children.items[0].id);
    try testing.expectEqual(root, t.lookup(1).?.parent.?);
    try testing.expectEqual(t.lookup(1).?, t.lookup(4).?.parent.?);
}

test "an UPDATE whose mask declares more values than the buffer supplies is a ShortRead" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    _ = try t.createWithId(0, .view);

    // A mask with two set bits (position_x, color_r) but only one trailing value
    // word — the second readValue runs past the buffer end. Rejected at validatePass.
    var encoder = Encoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.putTag(.update);
    try encoder.putU32(0);
    const mask = (@as(u32, 1) << propBit(.position_x)) | (@as(u32, 1) << propBit(.color_r));
    try encoder.putU32(mask);
    try encoder.putValue(12); // only ONE value for a two-bit mask

    try expectRejectedAtomic(&t, encoder.bytes(), error.ShortRead);
}

test "a paint-only UPDATE sets paint_dirty only and recompute crosses nothing" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const node = try t.createWithId(0, .view);
    node.sizing_mode = .fixed;
    node.main_size = 50;
    node.cross_size = 20;

    var encoder = Encoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.update(0, &.{.{ .prop = .color_r, .value = 0.5 }});

    try applyMutations(&t, encoder.bytes());

    try testing.expect(node.paint_dirty);
    try testing.expect(!node.layout_dirty);
    const recomputed = try dirty.recomputeDirty(&t, node);
    try testing.expectEqual(@as(usize, 0), recomputed);
}

test "a geometry UPDATE sets layout_dirty and bubbles to the fit_content ancestor" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();

    const root = try t.createWithId(0, .view);
    root.sizing_mode = .fit_content;
    const child = try t.createWithId(1, .view);
    child.sizing_mode = .fit_content;
    try t.appendChild(root, child);

    var encoder = Encoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.update(1, &.{.{ .prop = .gap, .value = 8 }});

    try applyMutations(&t, encoder.bytes());

    try testing.expect(child.layout_dirty);
    try testing.expect(root.layout_dirty);
    try testing.expect(!child.paint_dirty);
}

test "each structural mutation marks the gaining or losing container layout-dirty" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();

    const root = try t.createWithId(0, .view);
    root.sizing_mode = .fit_content;
    const existing = try t.createWithId(1, .view);
    existing.sizing_mode = .fixed;
    existing.main_size = 10;
    existing.cross_size = 10;
    try t.appendChild(root, existing);

    // APPEND marks the parent layout-dirty.
    var append_encoder = Encoder.init(testing.allocator);
    defer append_encoder.deinit();
    try append_encoder.create(2, .view);
    try append_encoder.append(0, 2);
    try applyMutations(&t, append_encoder.bytes());
    try testing.expect(root.layout_dirty);
    try testing.expect(t.lookup(2).?.layout_dirty);

    // Clear flags, then INSERT marks the gaining parent layout-dirty (anchor is the
    // existing child 1, so 3 lands before it).
    root.layout_dirty = false;
    var insert_encoder = Encoder.init(testing.allocator);
    defer insert_encoder.deinit();
    try insert_encoder.create(3, .view);
    try insert_encoder.insert(0, 3, 1);
    try applyMutations(&t, insert_encoder.bytes());
    try testing.expect(root.layout_dirty);

    // Clear flags, then REMOVE marks the (former) parent layout-dirty before detach.
    root.layout_dirty = false;
    var remove_encoder = Encoder.init(testing.allocator);
    defer remove_encoder.deinit();
    try remove_encoder.remove(1);
    try applyMutations(&t, remove_encoder.bytes());
    try testing.expect(root.layout_dirty);
}

test "a propless UPDATE (mask 0) applies cleanly and touches no field" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const node = try t.createWithId(0, .view);
    node.position_x = 7;

    var encoder = Encoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.update(0, &.{});

    try applyMutations(&t, encoder.bytes());
    try testing.expectEqual(@as(f32, 7), node.position_x);
    try testing.expect(!node.paint_dirty);
    try testing.expect(!node.layout_dirty);
}

test "a CREATE of the maximum id does not overflow next_id and stays resolvable" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();

    var encoder = Encoder.init(testing.allocator);
    defer encoder.deinit();
    try encoder.create(0xFFFFFFFF, .view);

    try applyMutations(&t, encoder.bytes());

    const node = t.lookup(0xFFFFFFFF).?;
    try testing.expectEqual(Kind.view, node.kind);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), t.next_id);
}
