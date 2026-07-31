pub fn maxRange(comptime Spells: type, spell_id: u32) ?f32 {
    const decls = @typeInfo(Spells).@"struct".decls;

    inline for (decls) |decl| {
        const spell = @field(Spells, decl.name);
        if (spell.spell_id == spell_id) return spell.range_yards;
    }
    return null;
}

pub fn name(comptime Spells: type, spell_id: u32) ?[]const u8 {
    const decls = @typeInfo(Spells).@"struct".decls;

    inline for (decls) |decl| {
        const spell = @field(Spells, decl.name);
        if (spell.spell_id == spell_id) return spell.name;
    }
    return null;
}

pub fn hasOutOfCombatTag(comptime Spells: type, spell_id: u32) bool {
    const decls = @typeInfo(Spells).@"struct".decls;

    inline for (decls) |decl| {
        const spell = @field(Spells, decl.name);
        if (spell.spell_id == spell_id and spell.out_of_combat) return true;
    }
    return false;
}
