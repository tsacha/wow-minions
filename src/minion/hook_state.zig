const std = @import("std");
const types = @import("types.zig");
const offsets = @import("offsets.zig");
const ctm = @import("ctm.zig");
const world = @import("world.zig");
const log_mod = @import("log.zig");
const gameplay_log = @import("gameplay_log.zig");
const proto = @import("protocol");

const Offsets = offsets.Offsets;

const cooldown_list_count: u32 = 2;
const max_known_spell_count: u32 = 5000;
const max_tracked_cooldown_spells: usize = 4096;
const tracked_spell_refresh_ms: u32 = 2000;
const max_valid_spell_range_yards: f32 = 200.0;
const threat_refresh_interval_ms: u32 = 250;

const spell_get_cooldown_proxy: types.SpellGetCooldownProxyFn = @ptrFromInt(Offsets.SPELL_GET_COOLDOWN_PROXY);
const spell_get_range: types.SpellGetRangeFn = @ptrFromInt(Offsets.SPELL_GET_RANGE);
const has_spell: types.HasSpellFn = @ptrFromInt(Offsets.HAS_SPELL);
const calculate_threat: types.CalculateThreatFn = @ptrFromInt(Offsets.CG_UNIT_CALCULATE_THREAT);

const CooldownSample = struct { remaining_ms: u32, duration_ms: u32 };

const ThreatCache = struct {
    target_guid: u64 = 0,
    refreshed: bool = false,
    last_refresh_ms: u32 = 0,
    count: u32 = 0,
    entries: [types.max_target_threats]types.ThreatEntry = std.mem.zeroes([types.max_target_threats]types.ThreatEntry),

    fn valid(self: ThreatCache, target_guid: u64, now_ms: u32) bool {
        return self.target_guid == target_guid and
            self.refreshed and
            now_ms -% self.last_refresh_ms < threat_refresh_interval_ms;
    }
};

pub var spell_range_log_enabled: bool = false;
pub var pet_guid_log_enabled: bool = false;

var tracked_cooldown_spell_ids: [max_tracked_cooldown_spells]u32 = std.mem.zeroes([max_tracked_cooldown_spells]u32);
var tracked_cooldown_spell_count: u32 = 0;
var tracked_cooldown_spell_last_refresh_ms: u32 = 0;
var spell_range_cache: [types.max_spell_ranges]types.SpellRangeEntry = std.mem.zeroes([types.max_spell_ranges]types.SpellRangeEntry);
var spell_range_cache_count: u32 = 0;
var spell_range_cache_last_refresh_ms: u32 = 0;
var threat_cache: ThreatCache = .{};

pub fn build(obj: u32, talent_cache: proto.TalentPoints) ?types.State {
    const now = world.readMsTime();

    const pos = world.readPlayerPosition(obj) orelse return null;
    const guid = world.readLocalPlayerGuid() orelse return null;
    const stats = world.readUnitStats(obj) orelse std.mem.zeroes(types.UnitStats);
    const ctm_state = ctm.readCtmState();
    const obj_mgr = world.world_object_manager.load(.acquire);
    const target_guid = world.readLocalTargetGuid() orelse 0;
    const target_unit_reaction: u32 = blk: {
        if (target_guid == 0 or obj_mgr == 0) break :blk 0;
        const tgt = world.findObjectByGuid(obj_mgr, target_guid) orelse break :blk 0;
        break :blk world.readUnitReaction(obj, tgt) orelse 0;
    };
    var player_auras = std.mem.zeroes([types.max_auras]types.AuraEntry);
    const player_aura_count = world.readAuras(obj, &player_auras);

    var target_auras = std.mem.zeroes([types.max_auras]types.AuraEntry);
    const target_aura_count = readTargetAuras(obj_mgr, target_guid, &target_auras);

    var target_threats = std.mem.zeroes([types.max_target_threats]types.ThreatEntry);
    const target_threat_count = readTargetThreatTable(obj_mgr, target_guid, now, &target_threats);
    const target_threat_len: usize = @intCast(target_threat_count);
    const threat_on_target = threatFromEntries(target_threats[0..target_threat_len], guid);
    const pet_guid = readPetGuid();
    if (pet_guid_log_enabled) {
        log_mod.debug("[pet] guid=0x{x} owner=0x{x}\n", .{ pet_guid orelse 0, guid });
    }

    var rune_regen_ms = std.mem.zeroes([6]u32);
    _ = world.readRuneRegenMs(obj, &rune_regen_ms);
    var rune_types = std.mem.zeroes([6]u32);
    _ = world.readRuneTypes(obj, &rune_types);

    refreshTrackedCooldownSpellIds(now);
    const tracked_count: usize = @intCast(tracked_cooldown_spell_count);
    const tracked_spell_ids = tracked_cooldown_spell_ids[0..tracked_count];

    var cooldowns = std.mem.zeroes([types.max_cooldowns]types.CooldownEntry);
    const cooldown_count = readCooldownsProxy(&cooldowns, tracked_spell_ids, now);
    refreshSpellRangeCache(obj, tracked_spell_ids, now);

    var player_name = std.mem.zeroes([32]u8);
    world.readLocalPlayerName(&player_name);

    const group_state = world.readGroupState();

    const state: types.State = .{
        .guid = guid,
        .world_ready = 1,
        .map_id = world.readMapId(),
        .x = pos.x,
        .y = pos.y,
        .z = pos.z,
        .orientation = world.readPlayerFacing(obj),
        .hp = stats.hp,
        .hp_max = stats.hp_max,
        .level = stats.level,
        .power = stats.power,
        .power_max = stats.power_max,
        .active_power_type = stats.active_power_type,
        .active_power = stats.active_power,
        .active_power_max = stats.active_power_max,
        .shapeshift_form = world.readShapeshiftForm(obj) orelse 0,
        .is_casting = world.readIsCasting(obj) orelse 0,
        .is_channeling = world.readIsChanneling(obj) orelse 0,
        .casting_spell_id = world.readCastingSpellId(obj) orelse 0,
        .channel_spell_id = world.readChannelSpellId(obj) orelse 0,
        .cast_start_time_ms = world.readCastStartTime(obj) orelse 0,
        .cast_end_time_ms = world.readCastEndTime(obj) orelse 0,
        .channel_start_time_ms = world.readChannelStartTime(obj) orelse 0,
        .channel_end_time_ms = world.readChannelEndTime(obj) orelse 0,
        .unit_flags = world.readUnitFlags(obj) orelse 0,
        .unit_flags_2 = world.readUnitFlags2(obj) orelse 0,
        .ctm_action = ctm_state.action,
        .ctm_x = ctm_state.x,
        .ctm_y = ctm_state.y,
        .ctm_z = ctm_state.z,
        .ctm_guid = ctm_state.guid,
        .target_guid = target_guid,
        .target_unit_reaction = target_unit_reaction,
        .combo_points = world.readComboPoints(),
        .combo_target_guid = world.readComboTargetGuid(),
        .channel_target_guid = world.readChannelTargetGuid(obj) orelse 0,
        .pet_guid = pet_guid orelse 0,
        .game_time_ms = now,
        .player_aura_count = player_aura_count,
        .player_auras = player_auras,
        .target_aura_count = target_aura_count,
        .target_auras = target_auras,
        .rune_regen_ms = rune_regen_ms,
        .rune_types = rune_types,
        .cooldown_count = cooldown_count,
        .cooldowns = cooldowns,
        .spell_range_count = spell_range_cache_count,
        .spell_ranges = spell_range_cache,
        .target_threat_count = target_threat_count,
        .target_threats = target_threats,
        .threat_on_target = threat_on_target,
        .class = world.readClass(obj) orelse 0,
        .bot_id = types.bot_id,
        .player_name = player_name,
        .glue_screen = 0,
        .talent_points = talent_cache,
        .group_size = group_state.group_size,
        .is_in_raid = group_state.is_in_raid,
        .combat_reach = world.readCombatReach(obj) orelse 0,
        .bounding_radius = world.readBoundingRadius(obj) orelse 0,
        .totems = world.readTotemSlots(obj, now),
    };

    gameplay_log.tick(state, obj_mgr, target_guid, guid, now);

    return state;
}

pub fn buildUnready() types.State {
    var s = std.mem.zeroes(types.State);
    s.bot_id = types.bot_id;
    s.world_ready = 0;
    return s;
}

fn calculateThreatOnTargetObj(target_obj: u32, unit_guid: u64) u32 {
    if (target_obj == 0 or unit_guid == 0) return 0;

    var status: u8 = 0;
    var status_secondary: u8 = 0;
    var percent: f32 = 0;
    var raw_threat: u32 = 0;
    if (!calculate_threat(target_obj, &unit_guid, &status, &status_secondary, &percent, &raw_threat)) return 0;
    return raw_threat;
}

fn appendThreatEntry(out: *[types.max_target_threats]types.ThreatEntry, count: *u32, unit_guid: u64, threat: u32) void {
    if (unit_guid == 0 or threat == 0) return;
    const n: usize = @intCast(count.*);
    if (n >= out.len) return;
    for (out[0..n]) |entry| {
        if (entry.unit_guid == unit_guid) return;
    }
    out[n] = .{ .unit_guid = unit_guid, .threat = threat };
    count.* += 1;
}

fn threatFromEntries(entries: []const types.ThreatEntry, unit_guid: u64) u32 {
    if (unit_guid == 0) return 0;
    var best: u32 = 0;
    for (entries) |entry| {
        if (entry.unit_guid != unit_guid) continue;
        if (entry.threat > best) best = entry.threat;
    }
    return best;
}

fn refreshTargetThreatTable(obj_mgr: u32, target_guid: u64, now_ms: u32, out: *[types.max_target_threats]types.ThreatEntry) u32 {
    if (obj_mgr == 0 or target_guid == 0) return 0;
    const target_obj = world.findObjectByGuid(obj_mgr, target_guid) orelse return 0;
    const obj_type = world.readObject(u16, target_obj + Offsets.OBJ_TYPE) orelse return 0;
    if (obj_type != 3) return 0;

    var count: u32 = 0;
    const local_guid = world.readLocalPlayerGuid() orelse 0;
    appendThreatEntry(out, &count, local_guid, calculateThreatOnTargetObj(target_obj, local_guid));

    var it = world.ObjectIterator.init(obj_mgr);
    while (it.next()) |ref| {
        if (count >= out.len) break;
        if (ref.obj_type != 4) continue;

        const guid = world.readObject(u64, ref.ptr + Offsets.OBJ_GUID) orelse continue;
        const threat = calculateThreatOnTargetObj(target_obj, guid);
        appendThreatEntry(out, &count, guid, threat);
    }

    threat_cache = .{
        .target_guid = target_guid,
        .refreshed = true,
        .last_refresh_ms = now_ms,
        .count = count,
        .entries = out.*,
    };
    return count;
}

fn readTargetThreatTable(obj_mgr: u32, target_guid: u64, now_ms: u32, out: *[types.max_target_threats]types.ThreatEntry) u32 {
    if (threat_cache.valid(target_guid, now_ms)) {
        out.* = threat_cache.entries;
        return threat_cache.count;
    }
    return refreshTargetThreatTable(obj_mgr, target_guid, now_ms, out);
}

fn readTargetAuras(obj_mgr: u32, target_guid: u64, out: []types.AuraEntry) u32 {
    if (obj_mgr == 0 or target_guid == 0) return 0;
    const target_obj = world.findObjectByGuid(obj_mgr, target_guid) orelse return 0;
    return world.readAuras(target_obj, out);
}

fn refreshTrackedCooldownSpellIds(now: u32) void {
    const tracked_spell_cap: u32 = @intCast(tracked_cooldown_spell_ids.len);

    if (tracked_cooldown_spell_count != 0 and
        now -% tracked_cooldown_spell_last_refresh_ms < tracked_spell_refresh_ms)
        return;

    const known_spell_count = world.readObject(u32, Offsets.SPELLBOOK_KNOWN_SPELL_COUNT) orelse {
        tracked_cooldown_spell_count = 0;
        tracked_cooldown_spell_last_refresh_ms = now;
        return;
    };
    if (known_spell_count == 0 or known_spell_count > max_known_spell_count) {
        tracked_cooldown_spell_count = 0;
        tracked_cooldown_spell_last_refresh_ms = now;
        return;
    }

    var n: u32 = 0;
    var i: u32 = 0;
    while (i < known_spell_count and n < tracked_spell_cap) : (i += 1) {
        const spell_id_addr = Offsets.SPELLBOOK_SLOT_MAP + @as(usize, i) * @sizeOf(u32);
        const spell_id = world.readObject(u32, spell_id_addr) orelse continue;
        if (spell_id == 0) continue;
        tracked_cooldown_spell_ids[n] = spell_id;
        n += 1;
    }

    tracked_cooldown_spell_count = n;
    tracked_cooldown_spell_last_refresh_ms = now;
}

fn readCooldownRemainingMs(now: u32, start_ms: u32, duration_ms: u32, enabled: u32) u32 {
    if (duration_ms == 0) return 0;

    if (enabled == 0) return duration_ms;

    if (now > start_ms) {
        const end_ms = start_ms +% duration_ms;
        return if (now < end_ms) end_ms -% now else 0;
    }

    return start_ms -% now +% duration_ms;
}

fn readCooldownFromList(spell_id: u32, cooldown_list_idx: u32, now: u32) ?CooldownSample {
    var start_ms: u32 = 0;
    var duration_ms: u32 = 0;
    var enabled: u32 = 1;

    _ = spell_get_cooldown_proxy(spell_id, cooldown_list_idx, &duration_ms, &start_ms, &enabled);
    const remaining_ms = readCooldownRemainingMs(now, start_ms, duration_ms, enabled);
    if (remaining_ms == 0) return null;

    return .{ .remaining_ms = remaining_ms, .duration_ms = duration_ms };
}

fn readCooldownsProxy(out: []types.CooldownEntry, spell_ids: []const u32, now: u32) u32 {
    const cap: u32 = @intCast(out.len);
    var n: u32 = 0;

    for (spell_ids) |spell_id| {
        if (n >= cap) break;
        if (spell_id == 0) continue;

        var best_remaining_ms: u32 = 0;
        var best_duration_ms: u32 = 0;

        var cooldown_list_idx: u32 = 0;
        while (cooldown_list_idx < cooldown_list_count) : (cooldown_list_idx += 1) {
            const sample = readCooldownFromList(spell_id, cooldown_list_idx, now) orelse continue;
            if (sample.remaining_ms <= best_remaining_ms) continue;

            best_remaining_ms = sample.remaining_ms;
            best_duration_ms = sample.duration_ms;
        }

        if (best_remaining_ms == 0) continue;

        out[n] = .{
            .spell_id = spell_id,
            .category = 0,
            .remaining_ms = best_remaining_ms,
            .duration_ms = best_duration_ms,
        };
        n += 1;
    }

    return n;
}

fn upsertSpellRange(out: []types.SpellRangeEntry, count: *u32, spell_id: u32, max_range_yards: f32) void {
    if (!std.math.isFinite(max_range_yards)) return;
    if (spell_id == 0 or max_range_yards <= 0 or max_range_yards > max_valid_spell_range_yards) return;

    const current: usize = @intCast(count.*);
    for (out[0..current]) |*entry| {
        if (entry.spell_id != spell_id) continue;
        entry.max_range_yards = max_range_yards;
        return;
    }

    if (current >= out.len) return;
    out[current] = .{ .spell_id = spell_id, .max_range_yards = max_range_yards };
    count.* += 1;
}

fn readSpellRangesFromClient(out: []types.SpellRangeEntry, player_obj: u32, spell_ids: []const u32) u32 {
    var count: u32 = 0;

    if (player_obj == 0) return 0;

    for (spell_ids) |spell_id| {
        if (count >= out.len) break;
        if (spell_id == 0 or !has_spell(spell_id)) continue;

        var min_range_yards: f32 = 0;
        var max_range_yards: f32 = 0;
        spell_get_range(player_obj, spell_id, &min_range_yards, &max_range_yards, 0);
        upsertSpellRange(out, &count, spell_id, max_range_yards);
    }

    return count;
}

fn refreshSpellRangeCache(player_obj: u32, spell_ids: []const u32, now: u32) void {
    if (spell_range_cache_count != 0 and
        now -% spell_range_cache_last_refresh_ms < tracked_spell_refresh_ms)
        return;

    spell_range_cache = std.mem.zeroes([types.max_spell_ranges]types.SpellRangeEntry);
    spell_range_cache_count = readSpellRangesFromClient(&spell_range_cache, player_obj, spell_ids);
    spell_range_cache_last_refresh_ms = now;

    if (spell_range_log_enabled) {
        const sample_count = @min(spell_range_cache_count, 8);
        var buf: [256]u8 = undefined;
        var len: usize = 0;
        for (spell_range_cache[0..sample_count], 0..) |entry, i| {
            const sep = if (i == 0) "" else " ";
            const written = std.fmt.bufPrint(buf[len..], "{s}{}:{d:.1}", .{ sep, entry.spell_id, entry.max_range_yards }) catch break;
            len += written.len;
        }
        log_mod.info("[range] refresh known={} ranges={} sample={s}\n", .{
            tracked_cooldown_spell_count,
            spell_range_cache_count,
            buf[0..len],
        });
    }
}

fn readPetGuid() ?u64 {
    return world.readObject(u64, offsets.Offsets.PGUID_PET);
}
