/**
 * Decode Wowhead WotLK gear planner URLs (path after gear-planner/class/race/).
 * Binary payload is URL-safe base64; format matches WH.Wow.GearPlannerWrath (build/parse).
 *
 * CLI: `.additem <id> <qty>` for gear + gems, then:
 *   - inscription scrolls (`data/enchant-spell-to-scroll-item.json`: Skillet/wago + e.g. Hodir 59934–59941, Gladiator 62384→44957),
 *   - craft spells (JSON): `.learn` + reagent `.additem` (`data/engineering-enchant-spells.json`;
 *     overrides scroll when both exist),
 *   - remaining enchants → `# ...` lines.
 * Flags: `--json`, `--no-enchant-scrolls`, `--no-engineering`.
 */

const path = typeof require !== "undefined" ? require("path") : null;

const COMMON_BLOCK = `# Common
.level 79
.additem 51809 4
.modify money 10000000000
.learn 54197
.learn 34091
.additem 45693
.additem 45589

.modify rep 1156 43999

.learn 4036
.learn 4037
.learn 4038
.learn 12656
.learn 30350
.learn 51306
.setskill 202 450
.additem 6219

.additem 41611

.maxskill`;

function loadEnchantSpellToScrollMap() {
  if (typeof require === "undefined" || !path) return {};
  try {
    return require(path.join(__dirname, "data", "enchant-spell-to-scroll-item.json"));
  } catch {
    return {};
  }
}

function loadEngineeringEnchantMap() {
  if (typeof require === "undefined" || !path) return {};
  try {
    return require(path.join(__dirname, "data", "engineering-enchant-spells.json"));
  } catch {
    return {};
  }
}

function decodeWowheadWotlkGearPlanner(pathOrUrl) {
  const ENCHANT_FLAG = 128;
  const RAND_FLAG = 64;

  let pathStr = String(pathOrUrl);
  if (pathStr.includes("://")) {
    try {
      pathStr = new URL(pathStr).pathname;
    } catch {
      /* ignore */
    }
  }
  pathStr = pathStr.replace(/^\/+|\/+$/g, "");
  const segs = pathStr.split("/");
  const iGp = segs.indexOf("gear-planner");
  const tail = iGp >= 0 ? segs.slice(iGp + 1).join("/") : pathStr;

  const m = /^([a-z-]+)\/([a-z-]+)(?:\/([a-zA-Z0-9+/_-]+))?$/.exec(tail);
  if (!m) throw new Error("Expected gear-planner/<class>/<race>[/<payload>]");

  const [, classSlug, raceSlug, b64] = m;
const state = {
  classSlug,
  raceSlug,
  version: null,
  genderId: null,
  level: null,
  talentHash: "",
  slots: {},
};
  if (!b64) return state;

  const normalized = b64.replace(/-/g, "+").replace(/_/g, "/");
  const bytes =
    typeof Buffer !== "undefined"
      ? [...Buffer.from(normalized, "base64")]
      : (() => {
          const bin = atob(normalized);
          const out = [];
          for (let k = 0; k < bin.length; k++) out.push(bin.charCodeAt(k));
          return out;
        })();

  const q = [...bytes];
let ver = q.shift();
  state.version = ver;
  if (ver > 6) return state;

  if (ver > 4) state.genderId = q.shift();
  if (ver > 0) state.level = q.shift();

  if (ver > 1) {
    const nBytes = q.shift();
    const talentBytes = q.splice(0, nBytes);
    const nibbles = [];
    for (const b of talentBytes) nibbles.push(b >> 4, b & 15);
    let trees = 0;
    for (let j = 0; j < nibbles.length && trees < 3; j++) {
      if (nibbles[j] === 15) {
        state.talentHash += "-";
        trees++;
      } else state.talentHash += String(nibbles[j]);
    }
    state.talentHash = state.talentHash.replace(/-+$/, "");
    if (ver >= 4) {
      let ext = q.shift();
      if (ext > 0) {
        state.talentHash += "_";
        while (ext-- > 0) state.talentHash += String.fromCharCode(q.shift());
      }
    }
  }

  // Parse slots. Wowhead stores 6 glyphs (3 major + 3 minor) as 12 bytes (2 bytes each) at the end.
  // Stop parsing slots if only 12 bytes remain, so we don't consume glyph data.
  while (q.length >= 3) {
    let slotByte = q.shift();
    let gemNibble = 0;
    let item = 0;
    if (ver >= 3) {
      const mid = q.shift();
      gemNibble = (mid & 224) >> 5;
      item |= (mid & 31) << 16;
    }
    item |= q.shift() << 8;
    item |= q.shift();

    const hasEnch = (slotByte & ENCHANT_FLAG) !== 0;
    const hasRand = (slotByte & RAND_FLAG) !== 0;
    const slot = slotByte & ~ENCHANT_FLAG & ~RAND_FLAG;

    state.slots[slot] = { item };
    if (hasEnch) {
      let en = 0;
      if (ver >= 6) en |= q.shift() << 16;
      en |= q.shift() << 8;
      en |= q.shift();
      state.slots[slot].enchant = en;
    }
    if (hasRand) {
      let r = q.shift() << 8;
      r |= q.shift();
      if (r & 32768) r -= 65536;
      state.slots[slot].randomEnchant = r;
    }
    let gemsLeft = gemNibble;
    while (gemsLeft-- > 0) {
      let b0 = q.shift();
      const sock = (b0 & 224) >> 5;
      let gemId = 0;
      gemId |= (b0 & 31) << 16;
      gemId |= q.shift() << 8;
      gemId |= q.shift();
      state.slots[slot].gems ??= {};
      state.slots[slot].gems[sock] = gemId;
    }
  }

  return state;
}

function gearItemIds(state) {
  return Object.values(state.slots)
    .map((s) => s.item)
    .filter(Boolean)
    .sort((a, b) => a - b);
}

function allItemIds(state) {
  const set = new Set();
  for (const s of Object.values(state.slots)) {
    if (s.item) set.add(s.item);
    if (s.gems) for (const g of Object.values(s.gems)) set.add(g);
  }
  return [...set].sort((a, b) => a - b);
}

function itemIdCounts(state) {
  const m = new Map();
  for (const s of Object.values(state.slots)) {
    if (s.item) m.set(s.item, (m.get(s.item) || 0) + 1);
    if (s.gems) for (const g of Object.values(s.gems)) m.set(g, (m.get(g) || 0) + 1);
  }
  return [...m.entries()].sort((a, b) => a[0] - b[0]);
}

function gearItemCounts(state) {
  const m = new Map();
  for (const s of Object.values(state.slots)) {
    if (s.item) m.set(s.item, (m.get(s.item) || 0) + 1);
  }
  return [...m.entries()].sort((a, b) => a[0] - b[0]);
}

function gemItemCounts(state) {
  const m = new Map();
  for (const s of Object.values(state.slots)) {
    if (s.gems) for (const g of Object.values(s.gems)) m.set(g, (m.get(g) || 0) + 1);
  }
  return [...m.entries()].sort((a, b) => a[0] - b[0]);
}

function formatAdditemLines(state) {
  const sections = [];

  const gear = gearItemCounts(state);
  if (gear.length) {
    sections.push("# Gear items\n" + gear.map(([id, qty]) => `.additem ${id} ${qty}`).join("\n"));
  }

  const gems = gemItemCounts(state);
  if (gems.length) {
    sections.push("# Gems\n" + gems.map(([id, qty]) => `.additem ${id} ${qty}`).join("\n"));
  }

  return sections.join("\n\n");
}

/**
 * @returns {{
 *   scrollCounts: [number, number][],
 *   engineeringCounts: Map<number, number>,
 *   unmapped: { slot: number, spellId: number }[],
 * }}
 */
function partitionSlotEnchants(state, scrollMap, engMap) {
  const sm = scrollMap || loadEnchantSpellToScrollMap();
  const em = engMap || loadEngineeringEnchantMap();
  const scrollIdQty = new Map();
  const engineeringSpellQty = new Map();
  const unmapped = [];
  for (const [slotStr, s] of Object.entries(state.slots)) {
    if (s.enchant == null || s.enchant === 0) continue;
    const spellId = s.enchant;
    const slot = parseInt(slotStr, 10);
    const craft = em[String(spellId)] ?? em[spellId];
    if (craft && typeof craft === "object" && Array.isArray(craft.reagents)) {
      engineeringSpellQty.set(
        spellId,
        (engineeringSpellQty.get(spellId) || 0) + 1,
      );
      continue;
    }
    const scrollId = sm[String(spellId)] ?? sm[spellId];
    if (scrollId) {
      scrollIdQty.set(scrollId, (scrollIdQty.get(scrollId) || 0) + 1);
      continue;
    }
    unmapped.push({ slot, spellId });
  }
  return {
    scrollCounts: [...scrollIdQty.entries()].sort((a, b) => a[0] - b[0]),
    engineeringCounts: engineeringSpellQty,
    unmapped,
  };
}

function enchantScrollCounts(state, map) {
  const p = partitionSlotEnchants(state, map);
  return { counts: p.scrollCounts, unmapped: p.unmapped };
}

function formatEngineeringFromPartition(p, engMap) {
  const em = engMap || loadEngineeringEnchantMap();
  const lines = [];
  const spellIds = [...p.engineeringCounts.keys()].sort((a, b) => a - b);
  for (const spellId of spellIds) {
    const mult = p.engineeringCounts.get(spellId) || 1;
    const def = em[String(spellId)] ?? em[spellId];
    if (!def || !Array.isArray(def.reagents)) continue;
    const learn = def.learnSpellId ?? spellId;
    const label = def.label || `Spell ${spellId}`;
    lines.push(`# Craft: ${label} (spell ${spellId})`);
    lines.push(`.learn ${learn}`);
    for (const pair of def.reagents) {
      const itemId = pair[0];
      const qty = pair[1];
      lines.push(`.additem ${itemId} ${qty * mult}`);
    }
  }
  return lines.join("\n");
}

function formatEngineeringGmLines(state, engMap) {
  const em = engMap || loadEngineeringEnchantMap();
  const p = partitionSlotEnchants(state, undefined, em);
  return formatEngineeringFromPartition(p, em);
}

function formatUnmappedEnchantLines(state, scrollMap, engMap) {
  const p = partitionSlotEnchants(state, scrollMap, engMap);
  return p.unmapped
    .map(
      (u) =>
        `# No scroll / craft-table entry for enchant spell ${u.spellId} (slot ${u.slot})`,
    )
    .join("\n");
}

function formatEnchantScrollAdditemLines(state, scrollMap, engMap, noEngineering) {
  const sm = scrollMap || loadEnchantSpellToScrollMap();
  const em = engMap || loadEngineeringEnchantMap();
  const p = partitionSlotEnchants(state, sm, em);
  const parts = [];
  if (p.scrollCounts.length) {
    const lines = [
      "# Enchant scrolls (inscription / tradeable items; spell→item from Skillet/wago table)",
    ];
    for (const [id, qty] of p.scrollCounts) lines.push(`.additem ${id} ${qty}`);
    parts.push(lines.join("\n"));
  }
  if (!noEngineering) {
    const eng = formatEngineeringFromPartition(p, em);
    if (eng) parts.push(eng);
  }
  if (p.unmapped.length) {
    parts.push(
      p.unmapped
        .map(
          (u) =>
            `# No scroll / craft-table entry for enchant spell ${u.spellId} (slot ${u.slot})`,
        )
        .join("\n"),
    );
  }
  return parts.join("\n\n");
}

if (typeof module !== "undefined" && module.exports) {
module.exports = {
  decodeWowheadWotlkGearPlanner,
  gearItemIds,
  allItemIds,
  itemIdCounts,
  gearItemCounts,
  gemItemCounts,
  formatAdditemLines,
    loadEnchantSpellToScrollMap,
    loadEngineeringEnchantMap,
    partitionSlotEnchants,
    enchantScrollCounts,
    formatEngineeringFromPartition,
    formatEngineeringGmLines,
    formatUnmappedEnchantLines,
    formatEnchantScrollAdditemLines,
  };
}

if (typeof require !== "undefined" && require.main === module) {
  const argv = process.argv.slice(2);
  const wantJson = argv.includes("--json");
  const skipScrolls = argv.includes("--no-enchant-scrolls");
  const noEngineering = argv.includes("--no-engineering");
  const url = argv.find((a) => !a.startsWith("-")) || "";
  if (!url) {
    console.error(
      "Usage: node decode-wowhead-wotlk-gear-planner.js <url-or-path> [--json] [--no-enchant-scrolls] [--no-engineering]",
    );
    process.exit(1);
  }
  const st = decodeWowheadWotlkGearPlanner(url);
  if (wantJson) {
    console.log(JSON.stringify(st, null, 2));
  } else {
    console.log(COMMON_BLOCK);
    console.log(formatAdditemLines(st));
  }
  if (!skipScrolls) {
    const scrollBlock = formatEnchantScrollAdditemLines(
      st,
      undefined,
      undefined,
      noEngineering,
    );
    if (scrollBlock) {
      console.log("");
      console.log(scrollBlock);
    }
  }
}
