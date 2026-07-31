const std = @import("std");
const proto = @import("protocol");
const registry_mod = @import("registry");
const spells_db = @import("spells.zig");
const Action = @import("action.zig").Action;
const world_query = @import("world_query.zig");

const BotSnapshot = registry_mod.BotSnapshot;

fn distanceSq(bot: BotSnapshot, target: proto.ScanEntry) f32 {
    const dx = target.x - bot.state.x;
    const dy = target.y - bot.state.y;
    return dx * dx + dy * dy;
}

pub fn castInstantIfReadyInRange(
    bot: BotSnapshot,
    target: proto.ScanEntry,
    spell: spells_db.Spell,
) ?Action {
    if (world_query.hasCooldown(&bot.state.cooldowns, bot.state.cooldown_count, spell.spell_id)) return null;

    const d2 = distanceSq(bot, target);
    const max2 = spell.range_yards * spell.range_yards;
    if (d2 > max2) return null;

    return .{ .cast_target_instant = .{ .spell_id = spell.spell_id, .target_guid = target.guid } };
}

test "castInstantIfReadyInRange: respects max range and cooldown" {
    const spell = spells_db.get(49576);
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.game_time_ms = 1000;

    var target = std.mem.zeroes(proto.ScanEntry);
    target.guid = 0xabc;
    target.x = 15.0;

    const ok = castInstantIfReadyInRange(bot, target, spell);
    try std.testing.expect(ok != null);
    try std.testing.expectEqual(spell.spell_id, ok.?.cast_target_instant.spell_id);

    target.x = 0.0;
    try std.testing.expect(castInstantIfReadyInRange(bot, target, spell) != null);

    target.x = 35.0;
    try std.testing.expect(castInstantIfReadyInRange(bot, target, spell) == null);

    target.x = 15.0;
    bot.state.cooldown_count = 1;
    bot.state.cooldowns[0] = .{ .spell_id = spell.spell_id, .category = 0, .remaining_ms = 1000, .duration_ms = 1000 };
    try std.testing.expect(castInstantIfReadyInRange(bot, target, spell) == null);
}
