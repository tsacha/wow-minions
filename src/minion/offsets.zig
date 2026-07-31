const build_options = @import("build_options");

const Expansion = @import("build").Expansion;
const win32 = @import("win32");

pub const Offsets = switch (build_options.expansion) {
    .classic => struct {},
    .tbc => struct {},
    .wotlk => struct {
        pub const CLIENT_CONNECTION: usize = 0x00C79CE0;
        pub const LOCAL_GUID: usize = 0x00CA1238;
        // GUID of the player's pet.
        pub const PGUID_PET: usize = 0x00C234D0;
        pub const MAP_ID: usize = 0x00AB63BC;
        pub const LOCAL_TARGET_GUID: usize = 0x00BD07B0;
        pub const COMBO_TARGET_GUID: usize = 0x00BD08A8;
        pub const COMBO_POINTS: usize = 0x00BD084D;
        pub const OBJECT_MANAGER: usize = 0x2ED0;
        pub const FIRST_OBJECT: usize = 0xAC;
        pub const OBJ_TYPE: usize = 0x14;
        pub const OBJ_GUID: usize = 0x30;
        pub const OBJ_NEXT: usize = 0x3C;
        pub const OBJ_UNIT_FIELDS: usize = 0x08;
        pub const UNIT_NAME_PTR: usize = 0x964;
        pub const UNIT_NAME_STR: usize = 0x05C;

        pub const PLAYER_NAME: usize = 0x00C79D18;
        pub const PLAYER_NAME_STORE: usize = 0x00C5D940;
        pub const PLAYER_NAME_MASK_OFF: usize = 0x24;
        pub const PLAYER_NAME_BASE_OFF: usize = 0x1C;
        pub const PLAYER_NAME_NODE_STR: usize = 0x20;
        pub const PLAYER_RUNE_REGEN_1: usize = 0x519;
        pub const RUNE_TYPE_CURRENT: usize = 0x00C24304;
        pub const RUNE_TYPE_BASE: usize = 0x00C24324;
        pub const RUNE_TIMER: usize = 0x00C24364;
        pub const PLAYER_RUNE_RATE_PTR: usize = 0x1008;
        pub const PLAYER_RUNE_RATE_BASE: usize = 0x1214;
        pub const RAID_MEMBER_COUNT: usize = 0x00BEB608;
        pub const PARTY_MEMBER_GUIDS: usize = 0x00BD1948;
        pub const PARTY_MEMBER_GUID_STRIDE: usize = 0x08;
        pub const PARTY_MEMBER_GUID_SLOTS: usize = 4;
        pub const OBJ_X: usize = 0x798;
        pub const OBJ_Y: usize = 0x79C;
        pub const OBJ_Z: usize = 0x7A0;
        pub const OBJ_FACING: usize = 0x7A8;
        // Game Object position: +4 relative to units (CGGameObject_C layout differs from CGUnit_C).
        pub const GO_X: usize = 0x0E8;
        pub const GO_Y: usize = 0x0EC;
        pub const GO_Z: usize = 0x0F0;
        // GO name chain: *(*(obj + GO_NAME_PTR) + GO_NAME_STR)
        pub const GO_NAME_PTR: usize = 0x1A4;
        pub const GO_NAME_STR: usize = 0x90;
        pub const UNIT_HEALTH: usize = 0x60;
        pub const UNIT_POWER: usize = 0x64;
        pub const UNIT_MAX_HEALTH: usize = 0x80;
        pub const UNIT_MAX_POWER: usize = 0x84;
        pub const UNIT_BYTES_0: usize = 0x5C;
        pub const OBJ_SHAPESHIFT_STATE_PTR: usize = 0x0D0;
        pub const OBJ_SHAPESHIFT_FORM_SUPPRESSED: usize = 0x9F4;
        pub const SHAPESHIFT_STATE_FORM_ID: usize = 0x1D3;
        pub const UNIT_LEVEL: usize = 0xD8;
        // Passive hitbox telemetry — descriptor indices 0x41 / 0x42 * 4.
        pub const UNIT_BOUNDING_RADIUS: usize = 0x104;
        pub const UNIT_COMBAT_REACH: usize = 0x108;
        // Descriptor indices ×4 — see OFFSETS_WOTLK.md eUnitFields (0x3B / 0x3C).
        pub const UNIT_FLAGS: usize = 0xEC;
        pub const UNIT_FLAGS_2: usize = 0xF0;
        pub const UNIT_FIELD_TARGET: usize = 0x48;
        pub const UNIT_FIELD_SUMMONEDBY: usize = 0x38;
        pub const UNIT_CHANNEL_OBJECT: usize = 0x50;
        pub const UNIT_CHANNEL_SPELL: usize = 0x58;
        // CGUnit_C::UnitReaction — same as Lua UnitReaction("player","target") for object pointers.
        pub const CG_UNIT_UNIT_REACTION: usize = 0x007251C0;
        pub const CG_UNIT_CALCULATE_THREAT: usize = 0x007374C0;
        // CGUnit_C runtime spell state (3.3.5a 12340)
        pub const OBJ_CASTING_SPELL: usize = 0xA6C;
        pub const OBJ_CAST_START_TIME: usize = 0xA78;
        pub const OBJ_CAST_END_TIME: usize = 0xA7C;
        pub const OBJ_CHANNEL_SPELL: usize = 0xA80;
        pub const OBJ_CHANNEL_START_TIME: usize = 0xA84;
        pub const OBJ_CHANNEL_END_TIME: usize = 0xA88;

        pub const FRAME_SCRIPT_EXECUTE: usize = 0x00819210;
        pub const FRAME_SCRIPT_GET_LOCALIZED_TEXT: usize = 0x00819D40;
        pub const CDATASTORE_GET_BUFFER_PARAMS: usize = 0x0047ADE0;
        pub const SPELL_GET_COOLDOWN_PROXY: usize = 0x00809000;
        pub const SPELL_GET_RANGE: usize = 0x00802C30;
        pub const GET_TALENT_GROUP_STATE: usize = 0x005C6080;
        pub const TALENT_ACTIVE_GROUP: usize = 0x00C20FF4;
        pub const SPELLBOOK_SLOT_MAP: usize = 0x00BE6D88;
        pub const SPELLBOOK_KNOWN_SPELL_COUNT: usize = 0x00BE8D98;
        pub const HAS_SPELL: usize = 0x0053C5B0;
        pub const CAST_SPELL_BY_ID: usize = 0x0080DA80;
        pub const HANDLE_TERRAIN_CLICK: usize = 0x00527830;
        pub const LUA_JUMP_OR_ASCEND_START: usize = 0x005FBF80;
        pub const MOVE_FORWARD_START: usize = 0x005FC200;
        pub const MOVE_FORWARD_STOP: usize = 0x005FC250;
        pub const MOVE_BACKWARD_START: usize = 0x005FC290;
        pub const MOVE_BACKWARD_STOP: usize = 0x005FC2E0;
        pub const STRAFE_LEFT_START: usize = 0x005FC440;
        pub const STRAFE_LEFT_STOP: usize = 0x005FC490;
        pub const STRAFE_RIGHT_START: usize = 0x005FC4D0;
        pub const STRAFE_RIGHT_STOP: usize = 0x005FC520;
        pub const PACKET_SMSG_SPELL_GO: usize = 0x0080FEE0; // shared entry for opcodes 0x131 (spell_start) and 0x132 (spell_go)
        pub const PACKET_SMSG_SPELL_FAILED_OTHER: usize = 0x00806AD0; // opcode 0x2A6
        pub const PACKET_SMSG_SPELL_FAILURE: usize = 0x00809C70; // opcode 0x133
        pub const PACKET_SMSG_SPELLBREAKLOG: usize = 0x006CE2B0;
        pub const PACKET_MSG_CHANNEL_UPDATE: usize = 0x00801DB0;
        pub const AURA_COUNT_1: usize = 0xDD0;
        pub const AURA_TABLE_1: usize = 0xC50;
        pub const AURA_COUNT_2: usize = 0xC54;
        pub const AURA_TABLE_2: usize = 0xC58;
        pub const AURA_STRUCT_SIZE: usize = 0x18;
        pub const AURA_CASTER_GUID: usize = 0x00;
        pub const AURA_SPELL_ID: usize = 0x08;
        pub const AURA_STACKS: usize = 0x0E;
        pub const AURA_END_TIME: usize = 0x14;
        pub const GET_MS_TIME: usize = 0x00B1D618;

        // ─── Shaman totem slot table ──────────────────────────────────────────────
        // Global array of 4 slots (fire=0, earth=1, water=2, air=3), stride 0x20.
        // Source: decompile of lua_GetTotemInfo @ 0x0051D330.
        pub const TOTEM_SLOT_BASE: usize = 0x00BD0B00;
        pub const TOTEM_SLOT_STRIDE: usize = 0x20;
        pub const TOTEM_GUID_LOW: usize = 0x08;      // u32 — both zero = slot empty
        pub const TOTEM_GUID_HIGH: usize = 0x0C;     // u32
        pub const TOTEM_DURATION_MS: usize = 0x14;   // i32 total duration
        pub const TOTEM_START_TIME_MS: usize = 0x18; // u32 cast time (GET_MS_TIME domain)

        /// Client "last hardware action" tick (`GetTickCount()` domain). Glue / login
        /// paths may reject scripted actions if this is stale (build 12340).
        pub const LAST_HARDWARE_ACTION: usize = 0x00B499A4;

        pub const CTM_FUN_PTR: usize = 0x00727400;
        /// `CGPlayer_C::CTMFace` — client click-to-move facing (build 12340 symbol dump).
        pub const CTM_FACE: usize = 0x0072B660;
        pub const CTM_ACTION: usize = 0x00CA11F4;
        pub const CTM_GUID: usize = 0x00CA11F8;
        pub const CTM_POS_X: usize = 0x00CA1264;
        pub const CTM_POS_Y: usize = 0x00CA1268;
        pub const CTM_POS_Z: usize = 0x00CA126C;

        // ─── Spell cooldown table ─────────────────────────────────────────────────────
        // Array at SPELL_COOLDOWN_PTR indexed by spell_id. Each bucket is CD_BUCKET_SIZE
        // bytes; the linked-list head sits at offset CD_BUCKET_HEAD within each bucket.
        // Nodes are CD_NODE_SIZE bytes each, linked via CD_NEXT.
        pub const SPELL_COOLDOWN_PTR: usize = 0x00D3F5AC;
        pub const CD_BUCKET_SIZE: usize = 24;
        pub const CD_BUCKET_HEAD: usize = 0x08;
        pub const CD_NODE_SIZE: usize = 0x30;
        pub const CD_MAX_SPELL_ID: u32 = 80000;
        pub const CD_NEXT: usize = 0x04;
        pub const CD_SPELL_ID: usize = 0x08;
        pub const CD_SPELL_START: usize = 0x10;
        pub const CD_SPELL_DURATION: usize = 0x14;
        pub const CD_CATEGORY: usize = 0x18;
        pub const CD_IS_LOCKED: usize = 0x24;
    },
};
