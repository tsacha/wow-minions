//! Lowest-priority layer: specialization rotation (builder/spender, dots, etc.).
//! Only runs when encounter and role layers did not emit an action.
//!
//! Per-spec routines for the roster live in `combat/specs/*.zig` (see assets/setup.md).

const registry_mod = @import("registry");
const world_memory_mod = @import("../world/memory.zig");
const class_spec = @import("class_spec.zig");
const context = @import("context.zig");
const spec_registry = @import("specs/spec_registry.zig");
const Action = @import("action.zig").Action;

const BotSnapshot = registry_mod.BotSnapshot;
const CombatContext = context.CombatContext;
const WorldSnapshot = world_memory_mod.WorldSnapshot;

pub fn planSpecRoutineWithContext(ctx: *const CombatContext) Action {
    const meta = spec_registry.meta(ctx.spec);
    if (meta.plan_with_context) |plan| return plan(ctx);
    const plan = meta.plan orelse return .none;
    return plan(ctx.bot, ctx.world);
}

pub fn planSpecRoutine(
    bot: BotSnapshot,
    world: []const WorldSnapshot,
    spec: class_spec.Spec,
) Action {
    const meta = spec_registry.meta(spec);
    const plan = meta.plan orelse return .none;
    return plan(bot, world);
}
