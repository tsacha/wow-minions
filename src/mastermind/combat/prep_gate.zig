//! Operator prep gating for scripted encounter maps (e.g. Thaddius pull room).

const proto = @import("protocol");
const encounter = @import("encounters/mod.zig");
const class_spec = @import("class_spec.zig");
const spec_registry = @import("specs/spec_registry.zig");
const action_mod = @import("action.zig");

const Action = action_mod.Action;
const Spec = class_spec.Spec;

/// On prep-gated encounter maps before **Start fight**, idle players may only emit
/// OOC buffs. Once the client reports combat, combat-only spells may pass.
pub fn actionAllowed(
    operator_fight_started: bool,
    state: proto.State,
    action: Action,
    spec: Spec,
) bool {
    if (operator_fight_started) return true;
    if (!encounter.mapUsesOperatorPrepGate(state.map_id)) return true;

    const check_fn = spec_registry.meta(spec).out_of_combat_check orelse return false;
    const in_combat = proto.hasUnitFlag(state.unit_flags, .in_combat);

    switch (action) {
        .none => return true,
        .cast => |id| return spellAllowed(check_fn, in_combat, id),
        .cast_instant => |id| return spellAllowed(check_fn, in_combat, id),
        .cast_target => |ct| return spellAllowed(check_fn, in_combat, ct.spell_id),
        .cast_target_instant => |ct| return spellAllowed(check_fn, in_combat, ct.spell_id),
        else => return false,
    }
}

fn spellAllowed(check_fn: spec_registry.OutOfCombatCheckFn, in_combat: bool, spell_id: u32) bool {
    const out_of_combat = check_fn(spell_id);
    return if (in_combat) !out_of_combat else out_of_combat;
}

test "actionAllowed: prep gate allows combat actions once unit is in combat" {
    const std = @import("std");

    var state = std.mem.zeroes(proto.State);
    state.map_id = encounter.thaddius_map_id;
    state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);

    try std.testing.expect(actionAllowed(false, state, .{ .cast_instant = 3738 }, .restoration_shaman));
}

test "actionAllowed: prep gate blocks combat-only spells out of combat" {
    const std = @import("std");

    var state = std.mem.zeroes(proto.State);
    state.map_id = encounter.thaddius_map_id;

    try std.testing.expect(!actionAllowed(false, state, .{ .cast_instant = 3738 }, .restoration_shaman));
}
