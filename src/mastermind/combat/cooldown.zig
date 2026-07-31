const proto = @import("protocol");

/// True when `spell_id` has no active cooldown entry (ready to cast).
pub fn spellReady(state: proto.State, spell_id: u32) bool {
    const n = @min(state.cooldown_count, state.cooldowns.len);
    for (state.cooldowns[0..n]) |cd| {
        if (cd.spell_id == spell_id and cd.remaining_ms > 0) return false;
    }
    return true;
}

/// True when a Death Knight rune of `rune_type` (or Death rune) is ready.
/// rune_regen_ms == 0 means ready; any nonzero value is a future regen timestamp.
pub fn runeReady(state: proto.State, rune_type: u32) bool {
    const rune_type_death: u32 = 4;
    for (state.rune_types, 0..) |slot_type, i| {
        if (slot_type != rune_type and slot_type != rune_type_death) continue;
        const regen = state.rune_regen_ms[i];
        if (regen == 0 or regen <= state.game_time_ms) return true;
    }
    return false;
}

/// Returns current mana as a percentage [0..100], or null if the bot uses a
/// different power resource.
pub fn manaPct(state: proto.State) ?u32 {
    const mana_power_type: u32 = 0;
    if (state.active_power_type != mana_power_type) return null;
    if (state.active_power_max == 0) return null;
    return @intCast((state.active_power * 100) / state.active_power_max);
}
