// WotLK Greater Blessing assignment — each paladin spec casts a Greater Blessing
// on every class present in the raid. With three specs (Ret/Holy/Prot) each class
// receives all three Greater Blessings from three different casters.
//
//   Retribution → Might
//   Holy        → Wisdom
//   Protection  → Kings

const std = @import("std");
const registry_mod = @import("registry");
const class_spec = @import("../class_spec.zig");
const spells_db = @import("../spells.zig");
const Action = @import("../action.zig").Action;

const BotSnapshot = registry_mod.BotSnapshot;
const Spec = class_spec.Spec;
const Class = class_spec.Class;

pub const data = struct {
    pub const spells = struct {
        pub const greater_blessing_of_kings = spells_db.get(25898);
        pub const greater_blessing_of_might = spells_db.get(48934);
        pub const greater_blessing_of_wisdom = spells_db.get(48938);
    };
};

// 10 playable classes in WotLK.
pub const max_actions: usize = 10;

fn blessingForSpec(spec: Spec) u32 {
    return switch (spec) {
        .retribution => data.spells.greater_blessing_of_might.spell_id,
        .holy_paladin => data.spells.greater_blessing_of_wisdom.spell_id,
        .protection_paladin => data.spells.greater_blessing_of_kings.spell_id,
        else => unreachable,
    };
}

/// Builds one cast_target action per distinct class present on the caster's map.
/// Greater Blessing buffs all raid members of the target's class.
pub fn buildActions(
    caster: BotSnapshot,
    spec: Spec,
    bots: []const BotSnapshot,
    buf: *[max_actions]Action,
) []const Action {
    const blessing_id = blessingForSpec(spec);
    var seen = std.EnumSet(Class).initEmpty();
    var n: usize = 0;
    for (bots) |other| {
        if (n >= buf.len) break;
        if (other.state.guid == 0) continue;
        if (other.state.map_id != caster.state.map_id) continue;
        const class = class_spec.classFromState(other.state) orelse continue;
        if (seen.contains(class)) continue;
        seen.insert(class);
        buf[n] = .{ .cast_target = .{
            .spell_id = blessing_id,
            .target_guid = other.state.guid,
        } };
        n += 1;
    }
    return buf[0..n];
}

test "retribution: warrior and druid both get Might" {
    const std2 = @import("std");
    var caster: BotSnapshot = std2.mem.zeroes(BotSnapshot);
    caster.state.guid = 0x100;
    caster.state.map_id = 1;
    var warrior: BotSnapshot = std2.mem.zeroes(BotSnapshot);
    warrior.state.guid = 0x200;
    warrior.state.map_id = 1;
    warrior.state.class = @intFromEnum(Class.warrior);
    var druid: BotSnapshot = std2.mem.zeroes(BotSnapshot);
    druid.state.guid = 0x300;
    druid.state.map_id = 1;
    druid.state.class = @intFromEnum(Class.druid);
    var buf: [max_actions]Action = undefined;
    const actions = buildActions(caster, .retribution, &.{ warrior, druid }, &buf);
    try std2.testing.expectEqual(@as(usize, 2), actions.len);
    for (actions) |a| {
        try std2.testing.expect(a == .cast_target);
        try std2.testing.expectEqual(data.spells.greater_blessing_of_might.spell_id, a.cast_target.spell_id);
    }
}

test "holy_paladin: warrior and druid both get Wisdom" {
    const std2 = @import("std");
    var caster: BotSnapshot = std2.mem.zeroes(BotSnapshot);
    caster.state.guid = 0x100;
    caster.state.map_id = 1;
    var warrior: BotSnapshot = std2.mem.zeroes(BotSnapshot);
    warrior.state.guid = 0x200;
    warrior.state.map_id = 1;
    warrior.state.class = @intFromEnum(Class.warrior);
    var druid: BotSnapshot = std2.mem.zeroes(BotSnapshot);
    druid.state.guid = 0x300;
    druid.state.map_id = 1;
    druid.state.class = @intFromEnum(Class.druid);
    var buf: [max_actions]Action = undefined;
    const actions = buildActions(caster, .holy_paladin, &.{ warrior, druid }, &buf);
    try std2.testing.expectEqual(@as(usize, 2), actions.len);
    for (actions) |a| {
        try std2.testing.expect(a == .cast_target);
        try std2.testing.expectEqual(data.spells.greater_blessing_of_wisdom.spell_id, a.cast_target.spell_id);
    }
}

test "protection_paladin: warrior and druid both get Kings" {
    const std2 = @import("std");
    var caster: BotSnapshot = std2.mem.zeroes(BotSnapshot);
    caster.state.guid = 0x100;
    caster.state.map_id = 1;
    var warrior: BotSnapshot = std2.mem.zeroes(BotSnapshot);
    warrior.state.guid = 0x200;
    warrior.state.map_id = 1;
    warrior.state.class = @intFromEnum(Class.warrior);
    var druid: BotSnapshot = std2.mem.zeroes(BotSnapshot);
    druid.state.guid = 0x300;
    druid.state.map_id = 1;
    druid.state.class = @intFromEnum(Class.druid);
    var buf: [max_actions]Action = undefined;
    const actions = buildActions(caster, .protection_paladin, &.{ warrior, druid }, &buf);
    try std2.testing.expectEqual(@as(usize, 2), actions.len);
    for (actions) |a| {
        try std2.testing.expect(a == .cast_target);
        try std2.testing.expectEqual(data.spells.greater_blessing_of_kings.spell_id, a.cast_target.spell_id);
    }
}

test "deduplication: two warriors produce one action" {
    const std2 = @import("std");
    var caster: BotSnapshot = std2.mem.zeroes(BotSnapshot);
    caster.state.guid = 0x100;
    caster.state.map_id = 1;
    var w1: BotSnapshot = std2.mem.zeroes(BotSnapshot);
    w1.state.guid = 0x200;
    w1.state.map_id = 1;
    w1.state.class = @intFromEnum(Class.warrior);
    var w2: BotSnapshot = std2.mem.zeroes(BotSnapshot);
    w2.state.guid = 0x300;
    w2.state.map_id = 1;
    w2.state.class = @intFromEnum(Class.warrior);
    var buf: [max_actions]Action = undefined;
    const actions = buildActions(caster, .retribution, &.{ w1, w2 }, &buf);
    try std2.testing.expectEqual(@as(usize, 1), actions.len);
    try std2.testing.expectEqual(w1.state.guid, actions[0].cast_target.target_guid);
}

test "skips bots on different map or with zero guid" {
    const std2 = @import("std");
    var caster: BotSnapshot = std2.mem.zeroes(BotSnapshot);
    caster.state.guid = 0x100;
    caster.state.map_id = 1;
    var other_map: BotSnapshot = std2.mem.zeroes(BotSnapshot);
    other_map.state.guid = 0x200;
    other_map.state.map_id = 2;
    other_map.state.class = @intFromEnum(Class.warrior);
    var zero_guid: BotSnapshot = std2.mem.zeroes(BotSnapshot);
    zero_guid.state.guid = 0;
    zero_guid.state.map_id = 1;
    zero_guid.state.class = @intFromEnum(Class.warrior);
    var buf: [max_actions]Action = undefined;
    const actions = buildActions(caster, .retribution, &.{ other_map, zero_guid }, &buf);
    try std2.testing.expectEqual(@as(usize, 0), actions.len);
}
