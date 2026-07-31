//! Generic combat role vocabulary and follow-store helpers.
//! Encounter scripts own explicit fight movement; role.zig stays generic.

const std = @import("std");
const registry_mod = @import("registry");
const types = @import("types");
const class_spec = @import("class_spec.zig");
const spec_registry = @import("specs/spec_registry.zig");

const BotSnapshot = registry_mod.BotSnapshot;
const BotId = types.BotId;

pub const CombatRole = enum {
    tank,
    healer,
    melee_dps,
    ranged_dps,
};

pub const RangeProfile = enum {
    melee,
    ranged,
    caster,
};

pub fn roleForSpec(spec: class_spec.Spec) CombatRole {
    return spec_registry.meta(spec).role;
}

pub fn profileForSpec(spec: class_spec.Spec) RangeProfile {
    return spec_registry.meta(spec).profile;
}

pub fn roleForBot(bot: BotSnapshot) CombatRole {
    return roleForSpec(class_spec.primarySpecFromState(bot.state));
}

pub const PositionOverride = struct {
    x: f32,
    y: f32,
    z: f32,
    arrival_yards: f32 = 1.5,
    // When true, role proposer skips back-arc placement once the bot is inside
    // arrival_yards. The override is the final word on where to stand; the bot
    // holds position and only auto-attacks (engine handles target facing).
    // Use for encounters where the intended stance is "stay here" rather than
    // "stay near here while still back-arc-ing the target".
    authoritative: bool = false,
};

pub const FollowEntry = struct {
    bot_id: BotId,
    target_guid: u64,
    last_ctm_x: f32,
    last_ctm_y: f32,
    position_override: ?PositionOverride = null,
    attack_started: bool = false,
};

pub const FollowStore = struct {
    entries: [types.max_bots]?FollowEntry = .{null} ** types.max_bots,

    pub fn get(self: *FollowStore, bot_id: BotId) ?*FollowEntry {
        for (&self.entries) |*slot| {
            if (slot.*) |*e| {
                if (std.mem.eql(u8, &e.bot_id, &bot_id)) return e;
            }
        }
        return null;
    }

    pub fn getOrCreate(self: *FollowStore, bot_id: BotId) ?*FollowEntry {
        if (self.get(bot_id)) |e| return e;
        for (&self.entries) |*slot| {
            if (slot.* == null) {
                slot.* = .{ .bot_id = bot_id, .target_guid = 0, .last_ctm_x = 0, .last_ctm_y = 0 };
                return &slot.*.?;
            }
        }
        return null;
    }

    pub fn remove(self: *FollowStore, bot_id: BotId) void {
        for (&self.entries) |*slot| {
            if (slot.*) |e| {
                if (std.mem.eql(u8, &e.bot_id, &bot_id)) {
                    slot.* = null;
                    return;
                }
            }
        }
    }

    pub fn setPosition(self: *FollowStore, bot_id: BotId, pos: PositionOverride) void {
        const entry = self.getOrCreate(bot_id) orelse return;
        entry.position_override = pos;
    }

    pub fn clearPosition(self: *FollowStore, bot_id: BotId) void {
        if (self.get(bot_id)) |entry| entry.position_override = null;
    }
};
