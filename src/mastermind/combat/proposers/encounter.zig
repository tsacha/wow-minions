// Encounter proposer: priority .encounter.
// Routes by map_id to the matching encounter module.

const context = @import("../context.zig");
const intent = @import("../intent/mod.zig");
const target_store = @import("../target_store.zig");
const role_mod = @import("../role.zig");
const registry_mod = @import("registry");
const world_memory_mod = @import("../../world/memory.zig");
const proto = @import("protocol");
const thaddius = @import("../encounters/thaddius/mod.zig");

pub const ActiveIntent = intent.ActiveIntent;
pub const CombatContext = context.CombatContext;
pub const TargetStore = target_store;
pub const FollowStore = role_mod.FollowStore;
pub const BotSnapshot = registry_mod.BotSnapshot;
pub const WorldSnapshot = world_memory_mod.WorldSnapshot;

pub const IntentStore = intent.IntentStore;

pub const Encounter = struct {
    map_id: u32,
    beginTick: *const fn (bots: []const BotSnapshot, world: []const WorldSnapshot, events: []const proto.SpellEvent, operator_fight_started: bool, intent_store: *const IntentStore) void,
    proposeIntent: *const fn (ctx: *const CombatContext, targets: *TargetStore, follow: *FollowStore) ?ActiveIntent,
};

const registered = [_]Encounter{
    .{ .map_id = thaddius.map_id, .beginTick = thaddius.beginTick, .proposeIntent = thaddius.proposeIntent },
};

pub fn beginTick(bots: []const BotSnapshot, world: []const WorldSnapshot, events: []const proto.SpellEvent, operator_fight_started: bool, intent_store: *const IntentStore) void {
    for (registered) |enc| {
        enc.beginTick(bots, world, events, operator_fight_started, intent_store);
    }
}

pub fn proposeIntent(ctx: *const CombatContext, targets: *TargetStore, follow: *FollowStore) ?ActiveIntent {
    for (registered) |enc| {
        if (enc.map_id == ctx.bot.state.map_id) {
            return enc.proposeIntent(ctx, targets, follow);
        }
    }
    return null;
}
