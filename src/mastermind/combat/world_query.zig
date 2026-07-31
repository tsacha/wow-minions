const std = @import("std");
const proto = @import("protocol");
const world_memory_mod = @import("../world/memory.zig");

const WorldSnapshot = world_memory_mod.WorldSnapshot;

pub fn scanForGuid(world: []const WorldSnapshot, guid: u64) ?proto.ScanEntry {
    if (guid == 0) return null;
    for (world) |snap| {
        if (snap.scan.guid == guid) return snap.scan;
    }
    return null;
}

pub fn scanForGuidOnMap(world: []const WorldSnapshot, guid: u64, map_id: u32) ?proto.ScanEntry {
    if (guid == 0) return null;
    for (world) |snap| {
        if (snap.map_id == map_id and snap.scan.guid == guid) return snap.scan;
    }
    return null;
}

pub fn entryForGuidOnMap(world: []const WorldSnapshot, guid: u64, map_id: u32) ?WorldSnapshot {
    if (guid == 0) return null;
    for (world) |snap| {
        if (snap.map_id == map_id and snap.scan.guid == guid) return snap;
    }
    return null;
}

/// Player's selected target when the client reports a hostile reaction and the
/// fused scan (if present) does not veto the attack. Returns null when there is
/// no target, reaction is not hostile, or the scan entry fails `isHostileAttackTarget`.
pub fn primaryHostileAttackGuid(state: proto.State, world: []const WorldSnapshot) ?u64 {
    const guid = state.target_guid;
    if (guid == 0) return null;

    const reaction = state.target_unit_reaction;
    if (reaction == unit_reaction_unknown) {
        if (scanForGuidOnMap(world, guid, state.map_id)) |scan| {
            if (isAttackableTargetIgnoringReaction(scan)) return guid;
        }
        return null;
    }
    if (reaction < unit_reaction_hostile_min or reaction > unit_reaction_hostile_max) return null;

    if (scanForGuidOnMap(world, guid, state.map_id)) |scan| {
        if (!isHostileAttackTarget(scan, reaction)) return null;
    }

    return guid;
}

/// Name prefix match on scan UTF-8 name (NUL-terminated in wire buffer).
pub fn scanByNamePrefix(world: []const WorldSnapshot, prefix: []const u8) ?proto.ScanEntry {
    if (prefix.len == 0) return null;
    for (world) |snap| {
        const name = std.mem.sliceTo(&snap.scan.name, 0);
        if (std.mem.startsWith(u8, name, prefix)) return snap.scan;
    }
    return null;
}

/// Name prefix match scoped to a specific map_id. Avoids false matches when a
/// mob with the same name exists on another map.
pub fn scanByNameOnMap(world: []const WorldSnapshot, prefix: []const u8, map_id: u32) ?proto.ScanEntry {
    if (prefix.len == 0) return null;
    for (world) |snap| {
        if (snap.map_id != map_id) continue;
        const name = std.mem.sliceTo(&snap.scan.name, 0);
        if (std.mem.startsWith(u8, name, prefix)) return snap.scan;
    }
    return null;
}

// `UnitReaction(player, target)` hostile range: 1=Hated, 2=Hostile, 3=Unfriendly.
// 0=unknown/no target; 4=Neutral; 5+=Friendly→Exalted.
const unit_reaction_unknown: u32 = 0;
const unit_reaction_hostile_min: u32 = 1;
const unit_reaction_hostile_max: u32 = 3;
const unit_reaction_friendly_min: u32 = 5;

/// Whether the scanned unit may receive hostile actions from a player-controlled bot.
/// Requires reaction in [1..3]; excludes dead (`hp == 0`), 0 (unknown), 4 (neutral),
/// and 5+ (friendly+).
pub fn isHostileAttackTarget(scan: proto.ScanEntry, unit_reaction: u32) bool {
    if (unit_reaction < unit_reaction_hostile_min or unit_reaction > unit_reaction_hostile_max) return false;
    return isAttackableTargetIgnoringReaction(scan);
}

fn isAttackableTargetIgnoringReaction(scan: proto.ScanEntry) bool {
    if (scan.hp == 0) return false;

    const f = scan.unit_flags;
    const f2 = scan.unit_flags_2;
    if (proto.hasUnitFlag(f, .non_attackable)) return false;
    if (proto.hasUnitFlag(f, .immune_to_pc)) return false;
    if (proto.hasUnitFlag(f, .non_attackable_2)) return false;
    if (proto.hasUnitFlag(f, .uninteractible)) return false;
    if (proto.hasUnitFlag(f, .immune)) return false;
    if (proto.hasUnitFlag(f, .player_controlled) and proto.hasUnitFlag(f, .not_attackable_1)) return false;
    if (proto.hasUnitFlag2(f2, .feign_death)) return false;
    return true;
}

/// Whether the target may receive friendly actions (heals, buffs) from a bot.
/// Requires reaction >= 5 (Friendly+); excludes dead (`hp == 0`), uninteractible, feign.
pub fn isFriendlyHealTarget(scan: proto.ScanEntry, unit_reaction: u32) bool {
    if (unit_reaction < unit_reaction_friendly_min) return false;
    if (scan.hp == 0) return false;
    if (proto.hasUnitFlag(scan.unit_flags, .uninteractible)) return false;
    if (proto.hasUnitFlag2(scan.unit_flags_2, .feign_death)) return false;
    return true;
}

/// Returns true if `spell_id` is present in the first `count` aura slots.
pub fn hasCooldown(cooldowns: []const proto.CooldownEntry, count: u32, spell_id: u32) bool {
    const n = @min(count, cooldowns.len);
    for (cooldowns[0..n]) |cd| {
        if (cd.spell_id == spell_id and cd.remaining_ms > 0) return true;
    }
    return false;
}

pub fn hasAura(auras: []const proto.AuraEntry, count: u32, spell_id: u32) bool {
    const n = @min(count, auras.len);
    for (auras[0..n]) |a| {
        if (a.spell_id == spell_id) return true;
    }
    return false;
}

test "isHostileAttackTarget: reaction range" {
    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.hp = 100;
    try std.testing.expect(!isHostileAttackTarget(scan, 0)); // unknown
    try std.testing.expect(isHostileAttackTarget(scan, 1)); // Hated
    try std.testing.expect(isHostileAttackTarget(scan, 2)); // Hostile
    try std.testing.expect(isHostileAttackTarget(scan, 3)); // Unfriendly
    try std.testing.expect(!isHostileAttackTarget(scan, 4)); // Neutral
    try std.testing.expect(!isHostileAttackTarget(scan, 5)); // Friendly
    try std.testing.expect(!isHostileAttackTarget(scan, 8)); // Exalted
}

test "isHostileAttackTarget: unit_flags block attack" {
    const hostile_reaction: u32 = 2;
    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.hp = 100;
    try std.testing.expect(isHostileAttackTarget(scan, hostile_reaction));

    scan.unit_flags = @intFromEnum(proto.UnitFlag.non_attackable);
    try std.testing.expect(!isHostileAttackTarget(scan, hostile_reaction));

    scan.unit_flags = @intFromEnum(proto.UnitFlag.immune_to_pc);
    try std.testing.expect(!isHostileAttackTarget(scan, hostile_reaction));

    scan.unit_flags = @intFromEnum(proto.UnitFlag.player_controlled) | @intFromEnum(proto.UnitFlag.not_attackable_1);
    try std.testing.expect(!isHostileAttackTarget(scan, hostile_reaction));

    scan.unit_flags = @intFromEnum(proto.UnitFlag.player_controlled);
    try std.testing.expect(isHostileAttackTarget(scan, hostile_reaction));

    scan.unit_flags = 0;
    scan.unit_flags_2 = @intFromEnum(proto.UnitFlag2.feign_death);
    try std.testing.expect(!isHostileAttackTarget(scan, hostile_reaction));
}

test "isFriendlyHealTarget: reaction range" {
    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.hp = 100;
    try std.testing.expect(!isFriendlyHealTarget(scan, 0)); // unknown
    try std.testing.expect(!isFriendlyHealTarget(scan, 3)); // Unfriendly
    try std.testing.expect(!isFriendlyHealTarget(scan, 4)); // Neutral
    try std.testing.expect(isFriendlyHealTarget(scan, 5)); // Friendly
    try std.testing.expect(isFriendlyHealTarget(scan, 8)); // Exalted
}

test "isFriendlyHealTarget: feign_death blocks heal" {
    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.hp = 100;
    scan.unit_flags_2 = @intFromEnum(proto.UnitFlag2.feign_death);
    try std.testing.expect(!isFriendlyHealTarget(scan, 5));
}

test "isHostileAttackTarget: zero hp blocks attack" {
    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.hp = 0;
    try std.testing.expect(!isHostileAttackTarget(scan, 2));
    scan.hp = 1;
    try std.testing.expect(isHostileAttackTarget(scan, 2));
}

test "isFriendlyHealTarget: zero hp blocks heal" {
    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.hp = 0;
    try std.testing.expect(!isFriendlyHealTarget(scan, 8));
    scan.hp = 1;
    try std.testing.expect(isFriendlyHealTarget(scan, 8));
}

test "primaryHostileAttackGuid: requires hostile reaction" {
    var st = std.mem.zeroes(proto.State);
    st.target_guid = 99;
    st.target_unit_reaction = 4;
    try std.testing.expect(primaryHostileAttackGuid(st, &.{}) == null);
}

test "primaryHostileAttackGuid: friendly reaction is never rescued by scan" {
    var st = std.mem.zeroes(proto.State);
    st.map_id = 533;
    st.target_guid = 0xabc;
    st.target_unit_reaction = 5;

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 533,
        .last_seen_ts_ns = 0,
    }};

    try std.testing.expect(primaryHostileAttackGuid(st, &world) == null);
}

test "primaryHostileAttackGuid: returns guid when scan validates" {
    var st = std.mem.zeroes(proto.State);
    st.map_id = 533;
    st.target_guid = 0xabc;
    st.target_unit_reaction = 2;

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 533,
        .last_seen_ts_ns = 0,
    }};

    try std.testing.expectEqual(@as(u64, 0xabc), primaryHostileAttackGuid(st, &world).?);
}

test "primaryHostileAttackGuid: falls back when reaction is unknown but scan is attackable" {
    var st = std.mem.zeroes(proto.State);
    st.map_id = 533;
    st.target_guid = 0xabc;
    st.target_unit_reaction = 0;

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 533,
        .last_seen_ts_ns = 0,
    }};

    try std.testing.expectEqual(@as(u64, 0xabc), primaryHostileAttackGuid(st, &world).?);
}
