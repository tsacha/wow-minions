// Central spell database for all specs and encounters.
// Metadata only — no rotation logic, no conditions.
// Rotations use e.g. `spells.get(49909).spell_id`; registry uses each spec's `data.spells` subset.

const std = @import("std");

pub const Spell = struct {
    spell_id: u32,
    name: []const u8 = "unknown",
    range_yards: f32,
    /// May be cast before combat starts (encounter prep / out-of-combat buffs).
    out_of_combat: bool = false,
    is_channel: bool = false,
    self_aura: bool = false,
};

const Row = struct {
    id: u32,
    name: []const u8,
    range_yards: f32,
    out_of_combat: bool = false,
    is_channel: bool = false,
    self_aura: bool = false,
};

const table = [_]Row{
    // Death Knight — Blood
    .{ .id = 56222, .name = "Dark Command", .range_yards = 30.0 },
    .{ .id = 49576, .name = "Death Grip", .range_yards = 30.0 },
    .{ .id = 49909, .name = "Icy Touch", .range_yards = 20.0 },
    .{ .id = 49921, .name = "Plague Strike", .range_yards = 5.0 },
    .{ .id = 49924, .name = "Death Strike", .range_yards = 5.0 },
    .{ .id = 49930, .name = "Blood Strike", .range_yards = 5.0 },
    .{ .id = 49895, .name = "Death Coil", .range_yards = 30.0 },
    .{ .id = 55095, .name = "Frost Fever", .range_yards = 0.0 },
    .{ .id = 55078, .name = "Blood Plague", .range_yards = 0.0 },
    .{ .id = 49938, .name = "Death and Decay", .range_yards = 30.0 },
    .{ .id = 55271, .name = "Scourge Strike", .range_yards = 5.0 },
    .{ .id = 49941, .name = "Blood Boil", .range_yards = 10.0 },
    .{ .id = 50842, .name = "Pestilence", .range_yards = 10.0 },
    .{ .id = 57623, .name = "Horn of Winter", .range_yards = 0.0, .out_of_combat = true, .self_aura = true },
    .{ .id = 48263, .name = "Frost Presence", .range_yards = 0.0, .out_of_combat = true, .self_aura = true },
    .{ .id = 48266, .name = "Blood Presence", .range_yards = 0.0, .out_of_combat = true, .self_aura = true },
    .{ .id = 48265, .name = "Unholy Presence", .range_yards = 0.0, .out_of_combat = true, .self_aura = true },
    .{ .id = 49206, .name = "Summon Gargoyle", .range_yards = 0.0, .self_aura = true },
    .{ .id = 42650, .name = "Army of the Dead", .range_yards = 0.0, .is_channel = true },
    .{ .id = 45529, .name = "Blood Tap", .range_yards = 0.0, .self_aura = true },
    .{ .id = 63560, .name = "Ghoul Frenzy", .range_yards = 0.0, .self_aura = true },
    // Death Knight — Frost
    .{ .id = 55268, .name = "Frost Strike", .range_yards = 5.0 },
    .{ .id = 51425, .name = "Obliterate", .range_yards = 5.0 },
    .{ .id = 51411, .name = "Howling Blast", .range_yards = 30.0 },
    .{ .id = 51271, .name = "Unbreakable Armor", .range_yards = 0.0, .self_aura = true },
    .{ .id = 49791, .name = "Glacier Rot", .range_yards = 0.0, .self_aura = true },
    .{ .id = 50130, .name = "Tundra Stalker", .range_yards = 0.0, .self_aura = true },
    .{ .id = 59057, .name = "Rime", .range_yards = 0.0, .self_aura = true },
    .{ .id = 51130, .name = "Killing Machine", .range_yards = 0.0, .self_aura = true },
    .{ .id = 54638, .name = "Blood of the North", .range_yards = 0.0, .self_aura = true },
    .{ .id = 49562, .name = "Epidemic", .range_yards = 0.0, .self_aura = true },
    // Paladin — Protection
    .{ .id = 25780, .name = "Righteous Fury", .range_yards = 0.0, .out_of_combat = true, .self_aura = true },
    .{ .id = 25899, .name = "Greater Blessing of Sanctuary", .range_yards = 30.0, .out_of_combat = true },
    .{ .id = 31801, .name = "Seal of Vengeance", .range_yards = 0.0, .out_of_combat = true, .self_aura = true },
    .{ .id = 62124, .name = "Hand of Reckoning", .range_yards = 30.0 },
    .{ .id = 48827, .name = "Avenger's Shield", .range_yards = 30.0 },
    .{ .id = 61411, .name = "Shield of Righteousness", .range_yards = 5.0 },
    .{ .id = 53595, .name = "Hammer of the Righteous", .range_yards = 5.0 },
    .{ .id = 53408, .name = "Judgement of Wisdom", .range_yards = 10.0 },
    .{ .id = 48806, .name = "Hammer of Wrath", .range_yards = 30.0 },
    .{ .id = 48819, .name = "Consecration", .range_yards = 0.0 },
    .{ .id = 54428, .name = "Divine Plea", .range_yards = 0.0 },
    .{ .id = 48952, .name = "Holy Shield", .range_yards = 0.0 },
    // Paladin — Holy
    .{ .id = 53563, .name = "Beacon of Light", .range_yards = 60.0 },
    .{ .id = 48785, .name = "Flash of Light", .range_yards = 40.0 },
    .{ .id = 48782, .name = "Holy Light", .range_yards = 40.0 },
    .{ .id = 53601, .name = "Sacred Shield", .range_yards = 40.0 },
    // Paladin — Greater Blessings (WotLK)
    .{ .id = 25898, .name = "Greater Blessing of Kings", .range_yards = 30.0, .out_of_combat = true },
    .{ .id = 48934, .name = "Greater Blessing of Might", .range_yards = 30.0, .out_of_combat = true },
    .{ .id = 48938, .name = "Greater Blessing of Wisdom", .range_yards = 30.0, .out_of_combat = true },
    // Paladin — Retribution
    .{ .id = 54043, .name = "Retribution Aura", .range_yards = 0.0, .out_of_combat = true, .self_aura = true },
    .{ .id = 35395, .name = "Crusader Strike", .range_yards = 5.0 },
    .{ .id = 53385, .name = "Divine Storm", .range_yards = 0.0 },
    .{ .id = 48801, .name = "Exorcism", .range_yards = 30.0 },
    .{ .id = 48817, .name = "Holy Wrath", .range_yards = 0.0 },
    // Priest
    .{ .id = 15473, .name = "Shadowform", .range_yards = 0.0, .out_of_combat = true, .self_aura = true },
    .{ .id = 48066, .name = "Power Word: Shield", .range_yards = 40.0 },
    .{ .id = 33076, .name = "Prayer of Mending", .range_yards = 40.0 },
    .{ .id = 48071, .name = "Flash Heal", .range_yards = 40.0 },
    .{ .id = 48072, .name = "Greater Heal", .range_yards = 40.0 },
    .{ .id = 48162, .name = "Prayer of Fortitude", .range_yards = 40.0, .out_of_combat = true },
    .{ .id = 48074, .name = "Prayer of Spirit", .range_yards = 40.0, .out_of_combat = true },
    .{ .id = 33206, .name = "Pain Suppression", .range_yards = 40.0 },
    .{ .id = 586, .name = "Fade", .range_yards = 0.0 },
    .{ .id = 48068, .name = "Renew", .range_yards = 40.0 },
    .{ .id = 53007, .name = "Penance", .range_yards = 30.0, .is_channel = true },
    .{ .id = 64843, .name = "Divine Hymn", .range_yards = 40.0, .is_channel = true },
    .{ .id = 48125, .name = "Shadow Word: Pain", .range_yards = 30.0 },
    .{ .id = 48127, .name = "Mind Blast", .range_yards = 30.0 },
    .{ .id = 48168, .name = "Inner Fire", .range_yards = 0.0, .out_of_combat = true, .self_aura = true },
    .{ .id = 58381, .name = "Mind Flay", .range_yards = 20.0, .is_channel = true },
    .{ .id = 48160, .name = "Vampiric Touch", .range_yards = 30.0 },
    .{ .id = 48300, .name = "Devouring Plague", .range_yards = 30.0 },
    // Shaman
    .{ .id = 2825, .name = "Bloodlust", .range_yards = 0.0 },
    .{ .id = 49238, .name = "Lightning Bolt", .range_yards = 30.0 },
    .{ .id = 60043, .name = "Lava Burst", .range_yards = 30.0 },
    .{ .id = 16166, .name = "Elemental Mastery", .range_yards = 0.0, .self_aura = true },
    .{ .id = 59159, .name = "Thunderstorm", .range_yards = 0.0 },
    .{ .id = 66842, .name = "Call of the Elements", .range_yards = 0.0 },
    .{ .id = 37380, .name = "Wrath of Air Totem", .range_yards = 0.0 },
    .{ .id = 3738, .name = "Wrath of Air Totem (legacy)", .range_yards = 0.0 },
    .{ .id = 58643, .name = "Strength of Earth Totem", .range_yards = 0.0 },
    .{ .id = 58656, .name = "Flametongue Totem", .range_yards = 0.0 },
    .{ .id = 58774, .name = "Mana Spring Totem", .range_yards = 0.0 },
    .{ .id = 57960, .name = "Water Shield", .range_yards = 0.0, .self_aura = true },
    .{ .id = 53390, .name = "Tidal Waves", .range_yards = 0.0, .self_aura = true },
    .{ .id = 58704, .name = "Searing Totem", .range_yards = 0.0 },
    .{ .id = 49236, .name = "Frost Shock", .range_yards = 25.0 },
    .{ .id = 61299, .name = "Riptide", .range_yards = 40.0 },
    .{ .id = 49276, .name = "Lesser Healing Wave", .range_yards = 40.0 },
    .{ .id = 49273, .name = "Healing Wave", .range_yards = 40.0 },
    .{ .id = 55459, .name = "Chain Heal", .range_yards = 40.0 },
    .{ .id = 32594, .name = "Earth Shield", .range_yards = 40.0, .out_of_combat = true },
    // Shaman — Enhancement
    .{ .id = 2894, .name = "Fire Elemental Totem", .range_yards = 0.0 },
    .{ .id = 51533, .name = "Feral Spirit", .range_yards = 0.0 },
    .{ .id = 17364, .name = "Stormstrike", .range_yards = 5.0 },
    .{ .id = 30823, .name = "Shamanistic Rage", .range_yards = 0.0, .self_aura = true },
    .{ .id = 49233, .name = "Flame Shock", .range_yards = 20.0 },
    .{ .id = 58734, .name = "Magma Totem", .range_yards = 0.0 },
    .{ .id = 49281, .name = "Lightning Shield", .range_yards = 0.0, .out_of_combat = true, .self_aura = true },
    .{ .id = 49231, .name = "Earth Shock", .range_yards = 20.0 },
    .{ .id = 61657, .name = "Fire Nova", .range_yards = 0.0 },
    .{ .id = 60103, .name = "Lava Lash", .range_yards = 5.0 },
    .{ .id = 53817, .name = "Maelstrom Weapon", .range_yards = 0.0, .self_aura = true },
    // Druid
    .{ .id = 24858, .name = "Moonkin Form", .range_yards = 0.0, .out_of_combat = true, .self_aura = true },
    .{ .id = 48461, .name = "Wrath", .range_yards = 30.0 },
    .{ .id = 48465, .name = "Starfire", .range_yards = 30.0 },
    .{ .id = 27013, .name = "Insect Swarm", .range_yards = 30.0 },
    .{ .id = 770, .name = "Faerie Fire", .range_yards = 30.0 },
    .{ .id = 16857, .name = "Faerie Fire (Feral)", .range_yards = 30.0 },
    .{ .id = 33831, .name = "Force of Nature", .range_yards = 40.0 },
    .{ .id = 48505, .name = "Starfall", .range_yards = 0.0 },
    .{ .id = 48517, .name = "Eclipse (Solar)", .range_yards = 0.0, .self_aura = true },
    .{ .id = 48518, .name = "Eclipse (Lunar)", .range_yards = 0.0, .self_aura = true },
    .{ .id = 48470, .name = "Gift of the Wild", .range_yards = 40.0, .out_of_combat = true },
    .{ .id = 48469, .name = "Mark of the Wild", .range_yards = 40.0, .out_of_combat = true },
    .{ .id = 29166, .name = "Innervate", .range_yards = 40.0 },
    .{ .id = 48477, .name = "Rebirth", .range_yards = 40.0 },
    .{ .id = 50763, .name = "Revive", .range_yards = 40.0 },
    .{ .id = 48447, .name = "Tranquility", .range_yards = 30.0, .is_channel = true },
    .{ .id = 33891, .name = "Tree of Life", .range_yards = 0.0, .out_of_combat = true, .self_aura = true },
    .{ .id = 22812, .name = "Barkskin", .range_yards = 0.0, .self_aura = true },
    .{ .id = 8946, .name = "Cure Poison", .range_yards = 40.0 },
    .{ .id = 2782, .name = "Remove Curse", .range_yards = 40.0 },
    .{ .id = 2893, .name = "Abolish Poison", .range_yards = 40.0 },
    .{ .id = 53307, .name = "Thorns", .range_yards = 40.0, .out_of_combat = true },
    .{ .id = 48441, .name = "Rejuvenation", .range_yards = 40.0 },
    .{ .id = 48443, .name = "Healing Touch", .range_yards = 40.0 },
    .{ .id = 53251, .name = "Wild Growth", .range_yards = 40.0 },
    .{ .id = 33763, .name = "Lifebloom", .range_yards = 40.0 },
    .{ .id = 48438, .name = "Regrowth", .range_yards = 40.0 },
    .{ .id = 50464, .name = "Nourish", .range_yards = 40.0 },
    .{ .id = 18562, .name = "Swiftmend", .range_yards = 40.0 },
    .{ .id = 17116, .name = "Nature's Swiftness", .range_yards = 0.0, .self_aura = true },
    .{ .id = 768, .name = "Cat Form", .range_yards = 0.0, .out_of_combat = true, .self_aura = true },
    .{ .id = 16870, .name = "Clearcasting", .range_yards = 0.0 },
    .{ .id = 48566, .name = "Mangle (Cat)", .range_yards = 5.0 },
    .{ .id = 48572, .name = "Shred", .range_yards = 5.0 },
    .{ .id = 48574, .name = "Rake", .range_yards = 5.0 },
    .{ .id = 49800, .name = "Rip", .range_yards = 5.0 },
    .{ .id = 50213, .name = "Tiger's Fury", .range_yards = 0.0, .self_aura = true },
    .{ .id = 50334, .name = "Berserk", .range_yards = 0.0, .self_aura = true },
    .{ .id = 52610, .name = "Savage Roar", .range_yards = 0.0, .self_aura = true },
    .{ .id = 48575, .name = "Cower", .range_yards = 0.0 },
    // Warrior
    .{ .id = 2457, .name = "Battle Stance", .range_yards = 0.0, .out_of_combat = true, .self_aura = true },
    .{ .id = 47436, .name = "Battle Shout", .range_yards = 0.0, .self_aura = true },
    .{ .id = 47440, .name = "Commanding Shout", .range_yards = 0.0, .self_aura = true },
    .{ .id = 1719, .name = "Recklessness", .range_yards = 0.0, .self_aura = true },
    .{ .id = 7386, .name = "Sunder Armor", .range_yards = 5.0 },
    .{ .id = 47450, .name = "Heroic Strike", .range_yards = 5.0 },
    .{ .id = 47465, .name = "Rend", .range_yards = 5.0 },
    .{ .id = 47471, .name = "Execute", .range_yards = 5.0 },
    .{ .id = 7384, .name = "Overpower", .range_yards = 5.0 },
    .{ .id = 52437, .name = "Sudden Death", .range_yards = 0.0, .self_aura = true },
    .{ .id = 56638, .name = "Taste for Blood", .range_yards = 0.0, .self_aura = true },
    .{ .id = 46924, .name = "Bladestorm", .range_yards = 0.0, .is_channel = true },
    .{ .id = 47486, .name = "Mortal Strike", .range_yards = 5.0 },
    .{ .id = 47475, .name = "Slam", .range_yards = 5.0 },
    // Rogue
    .{ .id = 48666, .name = "Mutilate", .range_yards = 5.0 },
    .{ .id = 57993, .name = "Envenom", .range_yards = 5.0 },
    .{ .id = 6774, .name = "Slice and Dice", .range_yards = 0.0 },
    .{ .id = 51662, .name = "Hunger For Blood", .range_yards = 0.0, .self_aura = true },
    .{ .id = 48672, .name = "Rupture", .range_yards = 5.0 },
    .{ .id = 57934, .name = "Tricks of the Trade", .range_yards = 100.0 },
    // Mage
    .{ .id = 43002, .name = "Arcane Brilliance", .range_yards = 0.0, .out_of_combat = true },
    .{ .id = 42897, .name = "Arcane Blast", .range_yards = 30.0 },
    .{ .id = 42846, .name = "Arcane Missiles", .range_yards = 30.0, .is_channel = true },
    .{ .id = 12042, .name = "Arcane Power", .range_yards = 0.0, .self_aura = true },
    .{ .id = 12051, .name = "Evocation", .range_yards = 0.0, .is_channel = true },
    .{ .id = 12472, .name = "Icy Veins", .range_yards = 0.0, .self_aura = true },
    .{ .id = 55342, .name = "Mirror Image", .range_yards = 0.0, .self_aura = true },
    .{ .id = 43024, .name = "Mage Armor", .range_yards = 0.0, .out_of_combat = true, .self_aura = true },
    // Warlock
    .{ .id = 47893, .name = "Fel Armor", .range_yards = 0.0, .out_of_combat = true, .self_aura = true },
    .{ .id = 688, .name = "Summon Imp", .range_yards = 0.0 },
    .{ .id = 30146, .name = "Summon Felguard", .range_yards = 0.0 },
    .{ .id = 1454, .name = "Life Tap (Rank 1)", .range_yards = 0.0 },
    .{ .id = 57946, .name = "Life Tap", .range_yards = 0.0 },
    .{ .id = 47809, .name = "Shadow Bolt", .range_yards = 30.0 },
    .{ .id = 47813, .name = "Corruption", .range_yards = 30.0 },
    .{ .id = 47811, .name = "Immolate", .range_yards = 30.0 },
    .{ .id = 47841, .name = "Unstable Affliction", .range_yards = 30.0 },
    .{ .id = 59164, .name = "Haunt", .range_yards = 30.0 },
    .{ .id = 47864, .name = "Curse of Agony", .range_yards = 30.0 },
    .{ .id = 30910, .name = "Curse of Doom", .range_yards = 30.0 },
    .{ .id = 29858, .name = "Soulshatter", .range_yards = 0.0 },
    .{ .id = 32231, .name = "Incinerate", .range_yards = 30.0 },
    .{ .id = 6353, .name = "Soul Fire", .range_yards = 30.0 },
    .{ .id = 47241, .name = "Metamorphosis", .range_yards = 0.0, .self_aura = true },
    .{ .id = 47193, .name = "Demonic Empowerment", .range_yards = 100.0 },
    // Hunter
    .{ .id = 5384, .name = "Feign Death", .range_yards = 0.0, .self_aura = true },
    .{ .id = 61006, .name = "Kill Shot", .range_yards = 35.0 },
    .{ .id = 60052, .name = "Explosive Shot", .range_yards = 35.0 },
    .{ .id = 49001, .name = "Serpent Sting", .range_yards = 35.0 },
    .{ .id = 63672, .name = "Black Arrow", .range_yards = 35.0 },
    .{ .id = 49050, .name = "Aimed Shot", .range_yards = 35.0 },
    .{ .id = 49052, .name = "Steady Shot", .range_yards = 35.0 },
    .{ .id = 34477, .name = "Misdirection", .range_yards = 100.0 },
    // Encounter: Thaddius
    .{ .id = 28059, .name = "Positive Charge", .range_yards = 0.0 },
    .{ .id = 28084, .name = "Negative Charge", .range_yards = 0.0 },
};

pub fn get(comptime id: u32) Spell {
    inline for (table) |row| {
        if (row.id == id) {
            return .{
                .spell_id = row.id,
                .name = row.name,
                .range_yards = row.range_yards,
                .out_of_combat = row.out_of_combat,
                .is_channel = row.is_channel,
            };
        }
    }
    @compileError("unknown spell id");
}

pub fn lookup(spell_id: u32) ?Spell {
    for (table) |row| {
        if (row.id == spell_id) {
            return .{
                .spell_id = row.id,
                .name = row.name,
                .range_yards = row.range_yards,
                .out_of_combat = row.out_of_combat,
                .is_channel = row.is_channel,
                .self_aura = row.self_aura,
            };
        }
    }
    return null;
}

pub fn isChannel(spell_id: u32) bool {
    inline for (table) |row| {
        if (row.id == spell_id) return row.is_channel;
    }
    return false;
}

comptime {
    @setEvalBranchQuota(20000);
    for (0..table.len) |i| {
        for (i + 1..table.len) |j| {
            if (table[i].id == table[j].id) @compileError("duplicate spell id in table");
        }
    }
}

test "get: lightning bolt metadata" {
    const s = get(49238);
    try std.testing.expectEqual(@as(u32, 49238), s.spell_id);
    try std.testing.expectEqualStrings("Lightning Bolt", s.name);
    try std.testing.expectEqual(@as(f32, 30.0), s.range_yards);
    try std.testing.expect(!s.out_of_combat);
}

test "get: greater blessing of sanctuary out of combat" {
    const s = get(25899);
    try std.testing.expect(s.out_of_combat);
}

test "get: righteous fury out of combat" {
    const s = get(25780);
    try std.testing.expect(s.out_of_combat);
}
