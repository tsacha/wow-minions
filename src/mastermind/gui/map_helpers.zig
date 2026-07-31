//! Pure helpers used by `map.zig`. Name lookups, scene queries, and small
//! drawing primitives — pulled out so the main View struct stays focused on
//! input handling and high-level drawing.

const std = @import("std");
const ray = @import("ray");
const proto = @import("protocol");
const gui_command = @import("gui_command");
const scene = @import("scene.zig");

const object_fallback_color = ray.Color{ .r = 160, .g = 160, .b = 160, .a = 255 };
const bot_fallback_color = ray.Color{ .r = 180, .g = 180, .b = 180, .a = 255 };
const pet_color = ray.Color{ .r = 80, .g = 220, .b = 120, .a = 255 };
const dead_color = ray.Color{ .r = 80, .g = 60, .b = 60, .a = 255 };
const reaction_hostile_color = ray.Color{ .r = 235, .g = 60, .b = 55, .a = 255 };
const reaction_neutral_color = ray.Color{ .r = 225, .g = 185, .b = 70, .a = 255 };
const reaction_friendly_color = ray.Color{ .r = 70, .g = 205, .b = 105, .a = 255 };
const reaction_unknown_unit_color = ray.Color{ .r = 145, .g = 150, .b = 160, .a = 255 };
pub const panel_bar_border = ray.Color{ .r = 80, .g = 80, .b = 100, .a = 255 };

pub fn containsU32(slice: []const u32, value: u32) bool {
    for (slice) |v| {
        if (v == value) return true;
    }
    return false;
}

pub fn insertionSortU32(slice: []u32) void {
    var i: usize = 1;
    while (i < slice.len) : (i += 1) {
        const key = slice[i];
        var j: usize = i;
        while (j > 0 and slice[j - 1] > key) : (j -= 1) {
            slice[j] = slice[j - 1];
        }
        slice[j] = key;
    }
}

pub fn findBotByBotId(entities: []const scene.Entity, bot_id: gui_command.BotId) ?proto.State {
    for (entities) |e| {
        if (e.data != .bot) continue;
        if (std.mem.eql(u8, &e.data.bot.bot_id, &bot_id)) return e.data.bot;
    }
    return null;
}

pub fn entityGuid(entity: *const scene.Entity) u64 {
    return switch (entity.data) {
        .bot => |b| b.guid,
        .object => |o| o.guid,
    };
}

pub fn isEntityBot(entities: []const scene.Entity, guid: u64) bool {
    for (entities) |e| {
        if (e.data == .bot and e.data.bot.guid == guid) return true;
    }
    return false;
}

pub fn findEntity(entities: []const scene.Entity, guid: u64) ?scene.Entity {
    for (entities) |e| {
        if (entityGuid(&e) == guid) return e;
    }
    return null;
}

pub fn maxThreatOnTarget(entities: []const scene.Entity, target_guid: u64) u32 {
    if (target_guid == 0) return 0;
    var max: u32 = 0;
    for (entities) |e| {
        if (e.data != .bot) continue;
        const b = e.data.bot;
        if (b.target_guid != target_guid) continue;
        const threat = threatForGuidOnTarget(entities, target_guid, b.guid);
        if (threat > max) max = threat;
    }
    return max;
}

pub fn threatForGuidOnTarget(entities: []const scene.Entity, target_guid: u64, unit_guid: u64) u32 {
    if (target_guid == 0 or unit_guid == 0) return 0;
    var best: u32 = 0;
    for (entities) |e| {
        if (e.data != .bot) continue;
        const b = e.data.bot;
        if (b.target_guid != target_guid) continue;
        const n = @min(b.target_threat_count, b.target_threats.len);
        for (b.target_threats[0..n]) |entry| {
            if (entry.unit_guid != unit_guid) continue;
            if (entry.threat > best) best = entry.threat;
        }
        if (b.guid == unit_guid and b.threat_on_target > best) best = b.threat_on_target;
    }
    return best;
}

pub const AggroEntry = struct {
    unit_guid: u64,
    threat: u32,
};

fn upsertAggroEntry(out: *[proto.max_target_threats]AggroEntry, count: *usize, unit_guid: u64, threat: u32) void {
    if (unit_guid == 0 or threat == 0) return;
    for (out[0..count.*]) |*entry| {
        if (entry.unit_guid != unit_guid) continue;
        if (threat > entry.threat) entry.threat = threat;
        return;
    }
    if (count.* == out.len) return;
    out[count.*] = .{ .unit_guid = unit_guid, .threat = threat };
    count.* += 1;
}

fn sortAggroEntries(entries: []AggroEntry) void {
    var i: usize = 1;
    while (i < entries.len) : (i += 1) {
        const key = entries[i];
        var j: usize = i;
        while (j > 0 and entries[j - 1].threat < key.threat) : (j -= 1) {
            entries[j] = entries[j - 1];
        }
        entries[j] = key;
    }
}

pub fn collectAggroTable(entities: []const scene.Entity, target_guid: u64, out: *[proto.max_target_threats]AggroEntry) []const AggroEntry {
    if (target_guid == 0) return out[0..0];

    var count: usize = 0;
    for (entities) |e| {
        if (e.data != .bot) continue;
        const bot = e.data.bot;
        if (bot.target_guid != target_guid) continue;

        const n = @min(bot.target_threat_count, bot.target_threats.len);
        for (bot.target_threats[0..n]) |entry| {
            upsertAggroEntry(out, &count, entry.unit_guid, entry.threat);
        }
        upsertAggroEntry(out, &count, bot.guid, bot.threat_on_target);
    }

    sortAggroEntries(out[0..count]);
    return out[0..count];
}

pub fn findTargetName(entities: []const scene.Entity, target_guid: u64) []const u8 {
    if (target_guid == 0) return "-";
    for (entities) |*e| {
        if (entityGuid(e) == target_guid) return e.nameSlice();
    }
    return "?";
}

pub fn findPetOwnerName(entities: []const scene.Entity, pet_guid: u64) []const u8 {
    if (pet_guid == 0) return "-";
    for (entities) |e| {
        if (e.data != .bot) continue;
        if (e.data.bot.pet_guid != pet_guid) continue;
        return e.nameSlice();
    }
    return "?";
}

pub fn findBotPetName(entities: []const scene.Entity, bot_guid: u64) []const u8 {
    if (bot_guid == 0) return "-";
    for (entities) |e| {
        if (e.data != .bot) continue;
        if (e.data.bot.guid != bot_guid) continue;
        if (e.data.bot.pet_guid == 0) return "-";
        return findTargetName(entities, e.data.bot.pet_guid);
    }
    return "?";
}

pub fn findTargetUnitFlags(entities: []const scene.Entity, target_guid: u64) ?struct { f: u32, f2: u32 } {
    if (target_guid == 0) return null;
    const ent = findEntity(entities, target_guid) orelse return null;
    return switch (ent.data) {
        .bot => |b| .{ .f = b.unit_flags, .f2 = b.unit_flags_2 },
        .object => |o| .{ .f = o.unit_flags, .f2 = o.unit_flags_2 },
    };
}

pub fn appendUnitFlagNames(fbuf: *[256]u8, fl: *usize, flags: u32, flags2: u32) void {
    fl.* = 0;
    if (proto.hasUnitFlag(flags, .server_controlled)) appendFlag(fbuf, fl, "SrvCtrl");
    if (proto.hasUnitFlag(flags, .non_attackable)) appendFlag(fbuf, fl, "NoAttack");
    if (proto.hasUnitFlag(flags, .remove_client_ctrl)) appendFlag(fbuf, fl, "NoCtrl");
    if (proto.hasUnitFlag(flags, .player_controlled)) appendFlag(fbuf, fl, "PlayerCtrl");
    if (proto.hasUnitFlag(flags, .pvp_enabling)) appendFlag(fbuf, fl, "PvP");
    if (proto.hasUnitFlag(flags, .silenced)) appendFlag(fbuf, fl, "Silenced");
    if (proto.hasUnitFlag(flags, .pacified)) appendFlag(fbuf, fl, "Pacified");
    if (proto.hasUnitFlag(flags, .stunned)) appendFlag(fbuf, fl, "Stunned");
    if (proto.hasUnitFlag(flags, .in_combat)) appendFlag(fbuf, fl, "Combat");
    if (proto.hasUnitFlag(flags, .on_taxi)) appendFlag(fbuf, fl, "Taxi");
    if (proto.hasUnitFlag(flags, .disarmed)) appendFlag(fbuf, fl, "Disarmed");
    if (proto.hasUnitFlag(flags, .confused)) appendFlag(fbuf, fl, "Confused");
    if (proto.hasUnitFlag(flags, .fleeing)) appendFlag(fbuf, fl, "Fleeing");
    if (proto.hasUnitFlag(flags, .skinnable)) appendFlag(fbuf, fl, "Skinnable");
    if (proto.hasUnitFlag(flags, .mounted)) appendFlag(fbuf, fl, "Mounted");
    if (proto.hasUnitFlag2(flags2, .feign_death)) appendFlag(fbuf, fl, "Feign");
    if (proto.hasUnitFlag2(flags2, .hide_body)) appendFlag(fbuf, fl, "HideBody");
    if (proto.hasUnitFlag2(flags2, .mirror_image)) appendFlag(fbuf, fl, "MirrorImg");
}

pub fn findGameTime(entities: []const scene.Entity) u32 {
    for (entities) |e| {
        if (e.data == .bot) return e.data.bot.game_time_ms;
    }
    return 0;
}

pub fn className(class_id: u32) []const u8 {
    return switch (class_id) {
        1 => "Warrior",
        2 => "Paladin",
        3 => "Hunter",
        4 => "Rogue",
        5 => "Priest",
        6 => "Death Knight",
        7 => "Shaman",
        8 => "Mage",
        9 => "Warlock",
        11 => "Druid",
        else => "?",
    };
}

/// Labels for `State.target_unit_reaction` — same integer as Lua `UnitReaction(unit, otherUnit)` when defined.
/// Primary scale is 1–7 (hostility toward the other unit); 8 is used when reputation applies (Exalted).
/// 0 is sent when there is no target or the value is unavailable (API would return nil).
pub fn unitReactionStandingName(reaction: u32) []const u8 {
    return switch (reaction) {
        0 => "—",
        1 => "Exceptionally hostile",
        2 => "Very hostile",
        3 => "Hostile",
        4 => "Neutral",
        5 => "Friendly",
        6 => "Very friendly",
        7 => "Exceptionally friendly",
        8 => "Exalted",
        else => "?",
    };
}

pub fn groupKindName(is_in_raid: u32) []const u8 {
    return if (is_in_raid == 1) "raid" else "party";
}

pub fn shapeshiftFormName(class_id: u32, form: u32) []const u8 {
    if (form == 0) return "Humanoid";
    return switch (class_id) {
        1 => switch (form) {
            17 => "Battle Stance",
            18 => "Defensive Stance",
            19 => "Berserker Stance",
            else => "?",
        },
        11 => switch (form) {
            1 => "Cat",
            2 => "Tree",
            3 => "Travel",
            4 => "Aquatic",
            5, 8 => "Bear",
            27, 29 => "Flight",
            31...35 => "Moonkin",
            else => "?",
        },
        7 => switch (form) {
            16 => "Ghost Wolf",
            else => "?",
        },
        4 => switch (form) {
            30 => "Stealth",
            else => "?",
        },
        else => "?",
    };
}

pub fn objTypeName(obj_type: u16) []const u8 {
    return switch (obj_type) {
        1 => "Object",
        2 => "Item",
        3 => "NPC",
        4 => "Player",
        5 => "GameObject",
        6 => "DynObject",
        7 => "Corpse",
        else => "?",
    };
}

pub fn ctmActionName(action: u32) []const u8 {
    const a = std.enums.fromInt(proto.CtmAction, action) orelse return "?";
    return switch (a) {
        .move => "Move",
        .interact_npc => "Interact NPC",
        .loot => "Loot",
        .interact_obj => "Interact Obj",
        .skin => "Skin",
        .attack_pos => "Attack Pos",
        .attack => "Attack",
        .idle => "Idle",
    };
}

pub fn powerTypeName(power_type: u32) []const u8 {
    return switch (power_type) {
        0 => "Mana",
        1 => "Rage",
        2 => "Focus",
        3 => "Energy",
        4 => "Happiness",
        6 => "Runic Power",
        else => "Power",
    };
}

pub fn pointInRectInt(p: ray.Vector2, rx: c_int, ry: c_int, rw: c_int, rh: c_int) bool {
    const x0: f32 = @floatFromInt(rx);
    const y0: f32 = @floatFromInt(ry);
    const x1: f32 = @floatFromInt(rx + rw);
    const y1: f32 = @floatFromInt(ry + rh);
    return p.x >= x0 and p.x < x1 and p.y >= y0 and p.y < y1;
}

pub fn drawBar(x: c_int, y: c_int, w: c_int, h: c_int, current: u32, max_val: u32, fg: ray.Color, bg: ray.Color) void {
    ray.DrawRectangle(x, y, w, h, bg);
    if (max_val > 0) {
        const fill_w: c_int = @intFromFloat(@as(f32, @floatFromInt(current)) / @as(f32, @floatFromInt(max_val)) * @as(f32, @floatFromInt(w)));
        const clamped_w = @min(fill_w, w);
        if (clamped_w > 0) {
            ray.DrawRectangle(x, y, clamped_w, h, fg);
        }
    }
    ray.DrawRectangleLines(x, y, w, h, panel_bar_border);
}

pub fn appendFlag(buf: *[256]u8, pos: *usize, name: []const u8) void {
    if (pos.* > 0) {
        buf[pos.*] = ',';
        pos.* += 1;
        buf[pos.*] = ' ';
        pos.* += 1;
    }
    @memcpy(buf[pos.*..][0..name.len], name);
    pos.* += name.len;
}

pub fn entityColor(entities: []const scene.Entity, entity: scene.Entity) ray.Color {
    const dead = switch (entity.data) {
        .bot => |b| b.hp == 0,
        .object => |o| (o.obj_type == 3 or o.obj_type == 4) and o.hp == 0,
    };
    if (dead) return dead_color;
    if (isPetEntity(entities, entity)) return pet_color;
    return switch (entity.data) {
        .bot => |b| classColor(b.class),
        .object => |o| scannedObjectColor(o),
    };
}

fn scannedObjectColor(scan: proto.ScanEntry) ray.Color {
    if (scan.obj_type == 3 or scan.obj_type == 4) {
        return reactionColor(scan.unit_reaction);
    }
    return objectTypeColor(scan.obj_type);
}

pub fn reactionColor(reaction: u32) ray.Color {
    return switch (reaction) {
        1...2 => reaction_hostile_color,
        3 => reaction_neutral_color,
        4...8 => reaction_friendly_color,
        else => reaction_unknown_unit_color,
    };
}

fn isPetEntity(entities: []const scene.Entity, entity: scene.Entity) bool {
    const guid = entityGuid(&entity);
    if (guid == 0) return false;
    for (entities) |e| {
        if (e.data != .bot) continue;
        if (e.data.bot.pet_guid == guid) return true;
    }
    return false;
}

pub fn classColor(class_id: u32) ray.Color {
    return switch (class_id) {
        // Warrior
        1 => ray.Color{ .r = 198, .g = 155, .b = 58, .a = 255 },
        // Paladin
        2 => ray.Color{ .r = 245, .g = 140, .b = 186, .a = 255 },
        // Hunter
        3 => ray.Color{ .r = 171, .g = 212, .b = 115, .a = 255 },
        // Rogue
        4 => ray.Color{ .r = 255, .g = 245, .b = 105, .a = 255 },
        // Priest
        5 => ray.Color{ .r = 255, .g = 255, .b = 255, .a = 255 },
        // Death Knight
        6 => ray.Color{ .r = 196, .g = 31, .b = 59, .a = 255 },
        // Shaman
        7 => ray.Color{ .r = 0, .g = 112, .b = 222, .a = 255 },
        // Mage
        8 => ray.Color{ .r = 105, .g = 204, .b = 240, .a = 255 },
        // Warlock
        9 => ray.Color{ .r = 148, .g = 130, .b = 201, .a = 255 },
        // Druid
        10 => ray.Color{ .r = 255, .g = 125, .b = 10, .a = 255 },
        else => bot_fallback_color,
    };
}

pub fn objectTypeColor(type_id: u32) ray.Color {
    return switch (type_id) {
        // Object (containers, etc.)
        1 => ray.Color{ .r = 180, .g = 180, .b = 180, .a = 255 },
        // Item
        2 => ray.Color{ .r = 180, .g = 180, .b = 180, .a = 255 },
        // Unit (NPC)
        3 => ray.Color{ .r = 220, .g = 60, .b = 60, .a = 255 },
        // Player
        4 => ray.Color{ .r = 100, .g = 180, .b = 255, .a = 255 },
        // GameObject
        5 => ray.Color{ .r = 105, .g = 125, .b = 130, .a = 255 },
        // DynamicObject
        6 => ray.Color{ .r = 255, .g = 160, .b = 50, .a = 255 },
        // Corpse
        7 => ray.Color{ .r = 120, .g = 120, .b = 120, .a = 255 },
        else => object_fallback_color,
    };
}

test "shapeshift form name maps real druid forms" {
    try std.testing.expectEqualStrings("Humanoid", shapeshiftFormName(11, 0));
    try std.testing.expectEqualStrings("Moonkin", shapeshiftFormName(11, 31));
    try std.testing.expectEqualStrings("Cat", shapeshiftFormName(11, 1));
}
