const std = @import("std");
const scene = @import("scene.zig");
const types = @import("types");
const nav = @import("nav");

const max_entities = scene.max_entities;
const max_routes = types.max_bots;
const slot_count = 2;

pub const RouteSnapshot = nav.RouteSnapshot;
pub const combat_order_history_len = 4;
pub const combat_order_label_len = 512;

pub const bot_intent_label_len = 48;

pub const BotIntentEntry = struct {
    bot_id: [32]u8 = std.mem.zeroes([32]u8),
    label: [bot_intent_label_len]u8 = std.mem.zeroes([bot_intent_label_len]u8),
};

pub const CombatStatus = struct {
    orders_planned: u16 = 0,
    orders_accepted: u16 = 0,
    orders_dropped: u16 = 0,
    order_label_count: u8 = 0,
    order_labels: [combat_order_history_len][combat_order_label_len]u8 = .{std.mem.zeroes([combat_order_label_len]u8)} ** combat_order_history_len,
    bot_intent_count: u8 = 0,
    bot_intents: [types.max_bots]BotIntentEntry = .{BotIntentEntry{}} ** types.max_bots,
};

pub const Snapshot = struct {
    entities: []const scene.Entity,
    routes: []const RouteSnapshot,
    combat: CombatStatus,
};

const Slot = struct {
    entities: [max_entities]scene.Entity,
    entities_len: usize,
    routes: [max_routes]RouteSnapshot,
    routes_len: usize,
    combat: CombatStatus,
};

pub const Publisher = struct {
    slots: []Slot,
    read_index: std.atomic.Value(usize),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Publisher {
        const slots = try allocator.alloc(Slot, slot_count);
        for (slots) |*slot| {
            slot.* = .{
                .entities = undefined,
                .entities_len = 0,
                .routes = undefined,
                .routes_len = 0,
                .combat = .{},
            };
        }
        return .{
            .slots = slots,
            .read_index = .init(0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Publisher) void {
        self.allocator.free(self.slots);
    }

    pub fn publish(self: *Publisher, entities: []const scene.Entity, routes: []const RouteSnapshot, combat: CombatStatus) void {
        const current_read = self.read_index.load(.acquire);
        const write_index: usize = if (current_read == 0) 1 else 0;
        const entities_n = @min(entities.len, max_entities);
        const routes_n = @min(routes.len, max_routes);
        const slot = &self.slots[write_index];

        @memcpy(slot.entities[0..entities_n], entities[0..entities_n]);
        @memcpy(slot.routes[0..routes_n], routes[0..routes_n]);
        slot.entities_len = entities_n;
        slot.routes_len = routes_n;
        slot.combat = combat;
        self.read_index.store(write_index, .release);
    }

    pub fn read(self: *const Publisher) Snapshot {
        const index = self.read_index.load(.acquire);
        const slot = &self.slots[index];
        return .{
            .entities = slot.entities[0..slot.entities_len],
            .routes = slot.routes[0..slot.routes_len],
            .combat = slot.combat,
        };
    }
};
