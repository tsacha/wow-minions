const proto = @import("protocol");

/// Returns remaining_ms of the first matching aura, or null.
pub fn remainingMs(auras: []const proto.AuraEntry, count: u32, spell_id: u32) ?u32 {
    const n = @min(count, auras.len);
    for (auras[0..n]) |a| {
        if (a.spell_id == spell_id) return a.remaining_ms;
    }
    return null;
}

pub fn remainingMsOnSelf(state: proto.State, spell_id: u32) ?u32 {
    return remainingMs(state.player_auras[0..], state.player_aura_count, spell_id);
}

pub fn remainingMsOnTarget(state: proto.State, spell_id: u32) ?u32 {
    return remainingMs(state.target_auras[0..], state.target_aura_count, spell_id);
}
