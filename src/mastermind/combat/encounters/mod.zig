//! Encounter registry root. Holds shared map-id metadata and the encounter list.

const registry_mod = @import("registry");
const world_memory_mod = @import("../../world/memory.zig");
const thaddius = @import("thaddius/mod.zig");

const BotSnapshot = registry_mod.BotSnapshot;
const WorldSnapshot = world_memory_mod.WorldSnapshot;

pub const thaddius_map_id: u32 = thaddius.map_id;

/// Scripted encounter maps where the GUI **Start fight** arms pulls and routes.
/// Used for prep gating (buffs before **Start fight**); extend when adding encounters.
pub fn mapUsesOperatorPrepGate(map_id: u32) bool {
    return map_id == thaddius.map_id;
}

/// Returns the encounter-assigned tank owner for a hostile, or null if no encounter claims it.
pub fn encounterTankOwner(bots: []const BotSnapshot, world: []const WorldSnapshot, hostile_guid: u64, map_id: u32) ?BotSnapshot {
    if (map_id == thaddius.map_id) return thaddius.tankOwnerForHostile(bots, world, hostile_guid);
    return null;
}
