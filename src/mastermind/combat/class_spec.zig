const std = @import("std");
const proto = @import("protocol");

pub const Class = enum(u32) {
    warrior = 1,
    paladin = 2,
    hunter = 3,
    rogue = 4,
    priest = 5,
    death_knight = 6,
    shaman = 7,
    mage = 8,
    warlock = 9,
    druid = 11,
};

pub fn classFromState(state: proto.State) ?Class {
    return std.enums.fromInt(Class, state.class);
}

pub const Spec = enum {
    arms,
    fury,
    protection_warrior,
    holy_paladin,
    protection_paladin,
    retribution,
    beast_mastery,
    marksmanship,
    survival,
    assassination,
    combat,
    subtlety,
    discipline,
    holy_priest,
    shadow,
    blood,
    frost_dk,
    unholy,
    elemental,
    enhancement,
    restoration_shaman,
    arcane,
    fire,
    frost_mage,
    affliction,
    demonology,
    destruction,
    balance,
    feral,
    restoration_druid,
    unknown,
};

/// Returns the dominant spec based on talent points (tab with most points wins;
/// ties broken by tab1 > tab2 > tab3).
pub fn primarySpec(class: Class, tp: proto.TalentPoints) Spec {
    const max_pts = @max(@max(tp.tab1, tp.tab2), tp.tab3);
    const dom: u2 = if (tp.tab1 == max_pts) 0 else if (tp.tab2 == max_pts) 1 else 2;
    return switch (class) {
        .warrior => switch (dom) {
            0 => .arms,
            1 => .fury,
            else => .protection_warrior,
        },
        .paladin => switch (dom) {
            0 => .holy_paladin,
            1 => .protection_paladin,
            else => .retribution,
        },
        .hunter => switch (dom) {
            0 => .beast_mastery,
            1 => .marksmanship,
            else => .survival,
        },
        .rogue => switch (dom) {
            0 => .assassination,
            1 => .combat,
            else => .subtlety,
        },
        .priest => switch (dom) {
            0 => .discipline,
            1 => .holy_priest,
            else => .shadow,
        },
        .death_knight => switch (dom) {
            0 => .blood,
            1 => .frost_dk,
            else => .unholy,
        },
        .shaman => switch (dom) {
            0 => .elemental,
            1 => .enhancement,
            else => .restoration_shaman,
        },
        .mage => switch (dom) {
            0 => .arcane,
            1 => .fire,
            else => .frost_mage,
        },
        .warlock => switch (dom) {
            0 => .affliction,
            1 => .demonology,
            else => .destruction,
        },
        .druid => switch (dom) {
            0 => .balance,
            1 => .feral,
            else => .restoration_druid,
        },
    };
}

pub fn specName(spec: Spec) []const u8 {
    return switch (spec) {
        .arms => "Arms",
        .fury => "Fury",
        .protection_warrior, .protection_paladin => "Protection",
        .holy_paladin, .holy_priest => "Holy",
        .retribution => "Retribution",
        .beast_mastery => "Beast Mastery",
        .marksmanship => "Marksmanship",
        .survival => "Survival",
        .assassination => "Assassination",
        .combat => "Combat",
        .subtlety => "Subtlety",
        .discipline => "Discipline",
        .shadow => "Shadow",
        .blood => "Blood",
        .frost_dk, .frost_mage => "Frost",
        .unholy => "Unholy",
        .elemental => "Elemental",
        .enhancement => "Enhancement",
        .restoration_shaman, .restoration_druid => "Restoration",
        .arcane => "Arcane",
        .fire => "Fire",
        .affliction => "Affliction",
        .demonology => "Demonology",
        .destruction => "Destruction",
        .balance => "Balance",
        .feral => "Feral",
        .unknown => "Unknown",
    };
}

pub fn primarySpecFromState(state: proto.State) Spec {
    const cls = classFromState(state) orelse return .unknown;
    if (cls == .druid and state.talent_points.tab1 == 0 and state.talent_points.tab2 == 0 and state.talent_points.tab3 == 0) {
        return .unknown;
    }
    return primarySpec(cls, state.talent_points);
}

test "primarySpec dominant tab" {
    const tp = proto.TalentPoints;
    try std.testing.expectEqual(.arms, primarySpec(.warrior, tp{ .tab1 = 51, .tab2 = 0, .tab3 = 0 }));
    try std.testing.expectEqual(.retribution, primarySpec(.paladin, tp{ .tab1 = 0, .tab2 = 0, .tab3 = 51 }));
    try std.testing.expectEqual(.feral, primarySpec(.druid, tp{ .tab1 = 0, .tab2 = 51, .tab3 = 0 }));
    try std.testing.expectEqual(.discipline, primarySpec(.priest, tp{ .tab1 = 30, .tab2 = 30, .tab3 = 0 }));
}
