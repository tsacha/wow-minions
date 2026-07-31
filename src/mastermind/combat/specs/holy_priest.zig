//! Holy Priest healer spec metadata. Rotation is handled elsewhere for now.

const registry_mod = @import("registry");
const world_memory_mod = @import("../../world/memory.zig");
const spells_db = @import("../spells.zig");
const Action = @import("../action.zig").Action;

const BotSnapshot = registry_mod.BotSnapshot;
const WorldSnapshot = world_memory_mod.WorldSnapshot;

pub const data = struct {
    pub const spells = struct {
        pub const flash_heal = spells_db.get(48071);
        pub const greater_heal = spells_db.get(48072);
        pub const divine_hymn = spells_db.get(64843);
    };
    pub const resources = struct {};
};

pub fn plan(bot: BotSnapshot, world: []const WorldSnapshot) Action {
    _ = bot;
    _ = world;
    return .none;
}
