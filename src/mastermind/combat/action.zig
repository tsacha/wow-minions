const proto = @import("protocol");

pub const default_jump_near_tolerance_yards: f32 = 1.0;

/// Arrival radius carried with a move action so the confirm-layer liveness guard
/// uses the same tolerance the dispatch layer applied when it emitted the move
/// (see `intent.MovingTo.arrival_yards` / `intent.Stacking.tolerance`, both 3.0).
/// A move whose destination the bot is already within this radius of is complete,
/// not pending — otherwise the engine issues no motion and the move re-dispatches
/// forever (Thaddius first-shift polarity deadlock).
pub const default_move_arrival_yards: f32 = 3.0;

pub const Action = union(enum) {
    none,
    cast: u32,
    /// Instant spell (no cast time): dispatched and advances in the same tick
    /// without waiting for is_casting. Use in plan sequences alongside move_to_nb.
    cast_instant: u32,
    cast_target: struct {
        spell_id: u32,
        target_guid: u64,
    },
    /// Instant targeted spell: sends CAST_SPELL_GUID but advances in the same tick
    /// without waiting for is_casting. Use for instant-cast spells with a target.
    cast_target_instant: struct {
        spell_id: u32,
        target_guid: u64,
    },
    cast_ground: struct {
        spell_id: u32,
        x: f32,
        y: f32,
        z: f32,
    },
    attack: u64,
    target_guid: u64,
    start_attack,
    stop_attack,
    stop_cast,
    ctm_stop,
    clear_target,
    /// World radians; minion calls `CGPlayer_C::CTMFace` on the render thread.
    set_facing_rad: f32,
    interact: u64,
    move_to: struct {
        x: f32,
        y: f32,
        z: f32,
        arrival_yards: f32 = default_move_arrival_yards,
    },
    move_to_nb: struct {
        x: f32,
        y: f32,
        z: f32,
        arrival_yards: f32 = default_move_arrival_yards,
    },
    jump,
    walk: struct {
        direction: proto.WalkDir,
        duration_ms: u32,
    },
    jump_near_xy: struct {
        x: f32,
        y: f32,
        tolerance_yards: f32 = default_jump_near_tolerance_yards,
    },
    use_inventory_item: u8,
    /// Apply a weapon poison (item ID) to main hand / off-hand.
    apply_poison: u32,
};
