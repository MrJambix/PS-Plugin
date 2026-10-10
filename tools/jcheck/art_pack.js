#!/usr/bin/env node
// The ESP's art pack: the game's own icons, cut out of the client's archives
// OFFLINE and shipped inside the plugin as one atlas.
//
//   node tools/jcheck/art_pack.js [--wow <install>] [--product wow_classic_era]
//                                 [--out <lua file>] [--preview <png>]
//
// WHY IT SHIPS INSIDE THE PLUGIN
// The loader cannot read the game's archives in the game (its file sandbox is
// the client folder; see scripts_data/jcore/jcore.casc.json), and art cut into
// scripts_data on this machine never reaches the players the plugin is given
// to. So the icons are packed here into one PNG atlas, written as base64 into
// scripts/jambix_aio/modules/esp/art_pack.lua, and the plugin writes that PNG
// into scripts_data on first load (modules/esp/art.lua) and draws its cells.
//
// WHAT IS IN IT (ENTRIES below): the cursor icons the game shows for what you
// do with a thing (attack, loot, skin, use, quest ! and ?), the minimap
// tracking icons for town services, the nameplate's elite and rare dragons and
// the target frame's skull, the class crests, creature-type icons, weapon
// icons for how a mob fights, the combat swords, the uninterruptible-cast
// shield, raid markers, faction emblems, role circles and the status-bar
// texture. Every source path was looked at before it went in.
//
// PET ABILITIES (AIO 1.7.6): the game's own icon of every skill a beast can
// teach, as the cell "pet.<FileDataID>", for the hunter's rows under a
// tameable beast. The icons are the client's (SpellMisc.SpellIconFileDataID,
// written into modules/beasts_data.lua by beasts_extract.js): each hunter
// family's own skills and Cower, on either client, cut by FileDataID. Not
// Petopia's icon names: its Bite is the druid's Ferocious Bite, not the pet's
// own. An icon the main product lacks is taken from --alt-product: Era has
// no Trickster's Dance (Forever's fox).
//
// SKINNING (AIO 1.7.6): the icon of every item skinning gives, as the cell
// "item.<item id>", for the rows under a skinnable corpse. The icons are the
// client's (Item.db2 IconFileDataID, written into modules/skinning_data.lua by
// skinning_extract.js), cut by FileDataID.
//
// Cells are 32 px with a 2 px gutter filled by extruding each cell's edge, so
// bilinear sampling at a cell's border never picks up its neighbour. The Lua
// module gives each cell as u0, v0, u1, v1 fractions (JCore's atlas format).
"use strict";
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const casc = require("./lib/casc");
const { decode } = require("./lib/blp");
const { encode } = require("./lib/png");

const ROOT = path.resolve(__dirname, "..", "..");
const args = process.argv.slice(2);
function arg(name, fallback) {
    const i = args.indexOf(name);
    return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
}
const WOW = arg("--wow", "C:/Program Files (x86)/World of Warcraft");
const PRODUCT = arg("--product", "wow_classic_era");
const ALT_PRODUCT = arg("--alt-product", "wow_classic_beta");
const BEASTS = arg("--beasts", path.join(ROOT, "scripts/jambix_aio/modules/beasts_data.lua"));
const SKINNING = arg("--skinning", path.join(ROOT, "scripts/jambix_aio/modules/skinning_data.lua"));
const OUT = arg("--out", path.join(ROOT, "scripts/jambix_aio/modules/esp/art_pack.lua"));
const PREVIEW = arg("--preview", path.join(ROOT, "tools/jtest/out/art_pack_preview.png"));

const CELL = 32, GUTTER = 2, PITCH = CELL + GUTTER * 2, COLS = 8;

// The client's class crest sheet, 64 px cells (cfg.GAME_CLASS_SHEET).
const CLASSES = "Interface/Glues/CharacterCreate/UI-CharacterCreate-Classes.blp";
const CLASS_CELLS = {
    1: [0, 0.25, 0, 0.25], 8: [0.25, 0.49609375, 0, 0.25], 4: [0.49609375, 0.7421875, 0, 0.25],
    11: [0.7421875, 0.98828125, 0, 0.25], 3: [0, 0.25, 0.25, 0.5], 7: [0.25, 0.49609375, 0.25, 0.5],
    5: [0.49609375, 0.7421875, 0.25, 0.5], 9: [0.7421875, 0.98828125, 0.25, 0.5], 2: [0, 0.25, 0.5, 0.75],
};
// get_creature_type ids -> the most recognisable icon of the family
// (cfg.CREATURE_ICON).
const CREATURES = {
    1: "Ability_Hunter_Pet_Wolf", 2: "INV_Misc_Head_Dragon_01", 3: "Spell_Shadow_SummonFelHunter",
    4: "Spell_Frost_SummonWaterElemental", 5: "Ability_Warrior_TitansGrip", 6: "Spell_Shadow_RaiseDead",
    7: "INV_Misc_Head_Human_01", 8: "INV_Pet_RatCage", 9: "INV_Misc_EngGizmos_27", 10: "INV_Misc_QuestionMark",
    11: "Spell_Nature_StrengthOfEarthTotem02", 12: "INV_Box_PetCarrier_01", 13: "Spell_Shadow_PlagueCloud",
    14: "INV_Box_PetCarrier_01", 15: "INV_Misc_Slime_01",
};
const RAID = "Interface/TargetingFrame/UI-RaidTargetingIcons.blp";
const ROLES = "Interface/LFGFrame/UI-LFG-ICON-PORTRAITROLES.blp";

// mode: "cursor" (32 px; `tip` masks the pointer's gold corner), "icon" (an
// Interface/Icons square, its dark border trimmed as the game's own frames
// trim it), "ui" (any texture, cropped, fitted).
const ENTRIES = [
    // What to do with it: the cursor the game shows over it.
    { key: "kill", path: "Interface/Cursor/Attack.blp", mode: "cursor" },
    { key: "loot", path: "Interface/Cursor/LootAll.blp", mode: "cursor", tip: true },
    { key: "skin", path: "Interface/Cursor/Skin.blp", mode: "cursor", tip: true },
    { key: "use", path: "Interface/Cursor/Interact.blp", mode: "cursor", tip: true },
    { key: "quest_pickup", path: "Interface/Cursor/Quest.blp", mode: "cursor", tip: true },
    { key: "quest_turnin", path: "Interface/Cursor/QuestTurnIn.blp", mode: "cursor", tip: true },
    { key: "quest_none", path: "Interface/Cursor/UnableQuest.blp", mode: "cursor", tip: true },
    { key: "speak", path: "Interface/Cursor/Speak.blp", mode: "cursor", tip: true },
    { key: "mine", path: "Interface/Cursor/Mine.blp", mode: "cursor", tip: true },
    { key: "gather_herb", path: "Interface/Cursor/Gatherherbs.blp", mode: "cursor", tip: true },
    { key: "lock", path: "Interface/Cursor/PickLock.blp", mode: "cursor", tip: true },
    // What a node is: the gathering profession's own icons.
    { key: "node.herb", path: "Interface/Icons/INV_Misc_Flower_02.blp", mode: "icon" },
    { key: "node.ore", path: "Interface/Icons/Trade_Mining.blp", mode: "icon" },
    { key: "node.container", path: "Interface/Icons/INV_Box_02.blp", mode: "icon" },
    { key: "node.object", path: "Interface/Cursor/Interact.blp", mode: "cursor", tip: true },
    // Rank: the target frame's dragon ring round the portrait (gold elite,
    // silver rare, dark silver rare elite) and its skull. The nameplate's own
    // dragon is a thin curl that reads as nothing at 16 px.
    { key: "elite", path: "Interface/TargetingFrame/UI-TargetingFrame-Elite.blp", mode: "ui", crop: [0.58, 0.96, 0, 0.78] },
    { key: "rare", path: "Interface/TargetingFrame/UI-TargetingFrame-Rare.blp", mode: "ui", crop: [0.58, 0.96, 0, 0.78] },
    { key: "rare_elite", path: "Interface/TargetingFrame/UI-TargetingFrame-Rare-Elite.blp", mode: "ui", crop: [0.58, 0.96, 0, 0.78] },
    { key: "boss", path: "Interface/TargetingFrame/UI-TargetingFrame-Skull.blp", mode: "ui" },
    // How it fights.
    { key: "fight.melee", path: "Interface/Icons/INV_Sword_04.blp", mode: "icon" },
    { key: "fight.ranged", path: "Interface/Icons/INV_Weapon_Bow_07.blp", mode: "icon" },
    { key: "fight.caster", path: "Interface/Icons/INV_Staff_13.blp", mode: "icon" },
    // State.
    { key: "combat", path: "Interface/CharacterFrame/UI-StateIcon.blp", mode: "ui", crop: [0.5, 1, 0, 0.5] },
    { key: "resting", path: "Interface/CharacterFrame/UI-StateIcon.blp", mode: "ui", crop: [0, 0.5, 0, 0.5] },
    { key: "shield", path: "Interface/CastingBar/UI-CastingBar-Arena-Shield.blp", mode: "ui" },
    // Town services, as the minimap's tracking menu shows them.
    { key: "service.vendor", path: "Interface/Cursor/Buy.blp", mode: "cursor", tip: true },
    { key: "service.repair", path: "Interface/Minimap/Tracking/Repair.blp", mode: "ui" },
    { key: "service.flight", path: "Interface/Minimap/Tracking/FlightMaster.blp", mode: "ui" },
    { key: "service.inn", path: "Interface/Minimap/Tracking/Innkeeper.blp", mode: "ui" },
    { key: "service.bank", path: "Interface/Minimap/Tracking/Banker.blp", mode: "ui" },
    { key: "service.trainer", path: "Interface/Minimap/Tracking/Class.blp", mode: "ui" },
    { key: "service.profession", path: "Interface/Minimap/Tracking/Profession.blp", mode: "ui" },
    { key: "service.stable", path: "Interface/Minimap/Tracking/StableMaster.blp", mode: "ui" },
    { key: "service.auction", path: "Interface/Minimap/Tracking/Auctioneer.blp", mode: "ui" },
    { key: "service.food", path: "Interface/Minimap/Tracking/Food.blp", mode: "ui" },
    { key: "service.reagents", path: "Interface/Minimap/Tracking/Reagents.blp", mode: "ui" },
    { key: "service.ammo", path: "Interface/Minimap/Tracking/Ammunition.blp", mode: "ui" },
    { key: "service.poisons", path: "Interface/Minimap/Tracking/Poisons.blp", mode: "ui" },
    { key: "service.battlemaster", path: "Interface/Minimap/Tracking/BattleMaster.blp", mode: "ui" },
    { key: "service.mail", path: "Interface/Minimap/Tracking/Mailbox.blp", mode: "ui" },
    { key: "service.spirit", path: "Interface/RaidFrame/Raid-Icon-Rez.blp", mode: "ui" },
    // Factions and roles, for players.
    { key: "faction.horde", path: "Interface/TargetingFrame/UI-PVP-Horde.blp", mode: "ui", crop: [0, 0.625, 0, 0.625] },
    { key: "faction.alliance", path: "Interface/TargetingFrame/UI-PVP-Alliance.blp", mode: "ui", crop: [0, 0.625, 0, 0.625] },
    { key: "role.tank", path: ROLES, mode: "ui", crop: [0, 19 / 64, 22 / 64, 41 / 64] },
    { key: "role.healer", path: ROLES, mode: "ui", crop: [20 / 64, 39 / 64, 1 / 64, 20 / 64] },
    { key: "role.dps", path: ROLES, mode: "ui", crop: [20 / 64, 39 / 64, 22 / 64, 41 / 64] },
];
for (const [id, c] of Object.entries(CLASS_CELLS)) {
    ENTRIES.push({ key: "class." + id, path: CLASSES, mode: "ui", crop: c });
}
for (const [id, slug] of Object.entries(CREATURES)) {
    ENTRIES.push({ key: "creature." + id, path: "Interface/Icons/" + slug + ".blp", mode: "icon" });
}
const RAID_ORDER = [[0, 0], [1, 0], [2, 0], [3, 0], [0, 1], [1, 1], [2, 1], [3, 1]];
RAID_ORDER.forEach(([cx, cy], i) => {
    ENTRIES.push({ key: "raid." + (i + 1), path: RAID, mode: "ui", crop: [cx / 4, (cx + 1) / 4, cy / 4, (cy + 1) / 4] });
});
// What a beast teaches: the game's icon of each hunter family's own skills
// and Cower, on either client, by FileDataID (see PET ABILITIES).
{
    const src = fs.existsSync(BEASTS) ? fs.readFileSync(BEASTS, "utf8") : "";
    const icons = new Set();
    // One part per client: "    forever = {", "    vanilla = {".
    for (const part of src.split(/\n    (?=\w+ = \{\n        build = )/)) {
        const own = new Set(["Cower"]);
        for (const m of part.matchAll(/hunter = true,\n\s*name = "[^"]*",\n\s*own = \{([^}]*)\}/g)) {
            for (const n of m[1].matchAll(/"([^"]+)"/g)) own.add(n[1]);
        }
        for (const m of part.matchAll(/\n            (?:\["([^"]+)"\]|(\w+)) = \{\n([\s\S]*?)\n            \},/g)) {
            const icon = m[3].match(/\n                icon = (\d+),/);
            if (own.has(m[1] || m[2]) && icon && !/\n                trainer = true,/.test(m[3])) icons.add(Number(icon[1]));
        }
    }
    if (!icons.size) console.log(`  no pet ability icons: ${path.relative(ROOT, BEASTS)} missing, or has no icons`);
    for (const fdid of [...icons].sort((a, b) => a - b)) {
        ENTRIES.push({ key: "pet." + fdid, path: fdid, mode: "icon", alt: true });
    }
}
// What skinning gives: each item's own icon (see SKINNING).
{
    const src = fs.existsSync(SKINNING) ? fs.readFileSync(SKINNING, "utf8") : "";
    const at = src.indexOf("\n    items = {"), end = src.indexOf("\n    },", at);
    const items = at < 0 ? [] : [...src.slice(at, end).matchAll(/\n        \[(\d+)\] = \{[^\n]*\bicon = (\d+) \}/g)]
        .map(m => [Number(m[1]), Number(m[2])]).sort((a, b) => a[0] - b[0]);
    if (!items.length) console.log(`  no skinning item icons: ${path.relative(ROOT, SKINNING)} missing, or has no icons`);
    for (const [id, fdid] of items) ENTRIES.push({ key: "item." + id, path: fdid, mode: "icon", alt: true });
}
// Not a cell: its own strip under the cells, stretched by the bars.
const BAR = { key: "statusbar", path: "Interface/TargetingFrame/UI-StatusBar.blp" };

// --- pixels ------------------------------------------------------------------

/** A sub-rectangle as a new { w, h, rgba }. crop = [l, r, t, b] fractions. */
function cropImage(img, crop) {
    if (!crop) return img;
    const x0 = Math.round(crop[0] * img.w), x1 = Math.round(crop[1] * img.w);
    const y0 = Math.round(crop[2] * img.h), y1 = Math.round(crop[3] * img.h);
    const w = x1 - x0, h = y1 - y0, rgba = Buffer.alloc(w * h * 4);
    for (let y = 0; y < h; y++) img.rgba.copy(rgba, y * w * 4, ((y0 + y) * img.w + x0) * 4, ((y0 + y) * img.w + x1) * 4);
    return { w, h, rgba };
}

/** Area-average resample, premultiplied, to dw x dh. */
function resample(img, dw, dh) {
    if (img.w === dw && img.h === dh) return img;
    const out = Buffer.alloc(dw * dh * 4);
    const sx = img.w / dw, sy = img.h / dh;
    for (let dy = 0; dy < dh; dy++) {
        const fy0 = dy * sy, fy1 = (dy + 1) * sy;
        for (let dx = 0; dx < dw; dx++) {
            const fx0 = dx * sx, fx1 = (dx + 1) * sx;
            let r = 0, g = 0, b = 0, a = 0, wsum = 0;
            for (let y = Math.floor(fy0); y < Math.ceil(fy1); y++) {
                const wy = Math.min(fy1, y + 1) - Math.max(fy0, y);
                for (let x = Math.floor(fx0); x < Math.ceil(fx1); x++) {
                    const wx = Math.min(fx1, x + 1) - Math.max(fx0, x);
                    const k = wx * wy, o = (y * img.w + x) * 4, al = img.rgba[o + 3] / 255;
                    r += img.rgba[o] * al * k; g += img.rgba[o + 1] * al * k; b += img.rgba[o + 2] * al * k;
                    a += al * k; wsum += k;
                }
            }
            const o = (dy * dw + dx) * 4;
            if (a > 0) {
                out[o] = Math.round(r / a); out[o + 1] = Math.round(g / a); out[o + 2] = Math.round(b / a);
            }
            out[o + 3] = Math.round(255 * a / wsum);
        }
    }
    return { w: dw, h: dh, rgba: out };
}

/** The bounding box of the pixels that show. */
function bbox(img) {
    let x0 = img.w, y0 = img.h, x1 = -1, y1 = -1;
    for (let y = 0; y < img.h; y++) for (let x = 0; x < img.w; x++) {
        if (img.rgba[(y * img.w + x) * 4 + 3] > 8) {
            if (x < x0) x0 = x; if (x > x1) x1 = x;
            if (y < y0) y0 = y; if (y > y1) y1 = y;
        }
    }
    return x1 < 0 ? null : { x0, y0, x1, y1 };
}

/** Fits an image inside CELL x CELL keeping its aspect, centred. */
function fit(img) {
    const k = Math.min(CELL / img.w, CELL / img.h);
    const w = Math.max(1, Math.round(img.w * k)), h = Math.max(1, Math.round(img.h * k));
    const small = resample(img, w, h);
    const out = Buffer.alloc(CELL * CELL * 4);
    const ox = Math.floor((CELL - w) / 2), oy = Math.floor((CELL - h) / 2);
    for (let y = 0; y < h; y++) small.rgba.copy(out, ((oy + y) * CELL + ox) * 4, y * w * 4, (y + 1) * w * 4);
    return { w: CELL, h: CELL, rgba: out };
}

function cell(store, e) {
    let img = decode(store.read(e.path));
    return shape(img, e);
}

function shape(img, e) {
    if (e.mode === "cursor") {
        if (e.tip) {
            // The pointer's gold corner: everything on or above the diagonal
            // x + y = 12 of a 32 px cursor (looked at on every one of them).
            for (let y = 0; y < 13; y++) for (let x = 0; x + y <= 12; x++) img.rgba[(y * img.w + x) * 4 + 3] = 0;
        }
        const b = bbox(img);
        if (!b) throw new Error("nothing left after the tip");
        img = cropImage(img, [b.x0 / img.w, (b.x1 + 1) / img.w, b.y0 / img.h, (b.y1 + 1) / img.h]);
        return fit(img);
    }
    if (e.mode === "icon") return resample(cropImage(img, [0.07, 0.93, 0.07, 0.93]), CELL, CELL);
    img = cropImage(img, e.crop);
    // To what shows: the combat swords fill a fifth of their sheet cell.
    const b = bbox(img);
    if (!b) throw new Error("empty");
    return fit(cropImage(img, [b.x0 / img.w, (b.x1 + 1) / img.w, b.y0 / img.h, (b.y1 + 1) / img.h]));
}

// --- the atlas -----------------------------------------------------------------

function main() {
    const store = casc.open({ wow: WOW, product: PRODUCT });
    let alt = null;
    const altUsed = [];
    const cells = [];
    for (const e of ENTRIES) {
        try {
            cells.push({ key: e.key, img: cell(store, e), from: e.path });
        } catch (err) {
            if (e.alt && ALT_PRODUCT && ALT_PRODUCT !== PRODUCT) {
                try {
                    alt = alt || casc.open({ wow: WOW, product: ALT_PRODUCT });
                    cells.push({ key: e.key, img: cell(alt, e), from: e.path });
                    altUsed.push(e.key);
                    continue;
                } catch (err2) {
                    err = err2;
                }
            }
            console.log(`  skipped ${e.key} (${e.path}): ${err.message}`);
        }
    }
    if (altUsed.length) console.log(`  from ${ALT_PRODUCT}: ${altUsed.join(", ")}`);
    const bar = decode(store.read(BAR.path));

    const rows = Math.ceil(cells.length / COLS);
    const W = COLS * PITCH;
    const barY = rows * PITCH + GUTTER;
    const H = barY + bar.h + GUTTER;
    const atlas = Buffer.alloc(W * H * 4);
    const put = (x, y, r, g, b, a) => { const o = (y * W + x) * 4; atlas[o] = r; atlas[o + 1] = g; atlas[o + 2] = b; atlas[o + 3] = a; };
    /** Blits img at (x, y) and extrudes its edge GUTTER pixels outward. */
    function blit(img, x, y) {
        for (let yy = -GUTTER; yy < img.h + GUTTER; yy++) {
            const sy = Math.min(img.h - 1, Math.max(0, yy));
            for (let xx = -GUTTER; xx < img.w + GUTTER; xx++) {
                const sx = Math.min(img.w - 1, Math.max(0, xx));
                const o = (sy * img.w + sx) * 4;
                put(x + xx, y + yy, img.rgba[o], img.rgba[o + 1], img.rgba[o + 2], img.rgba[o + 3]);
            }
        }
    }
    const uv = {};
    cells.forEach((c, i) => {
        const x = (i % COLS) * PITCH + GUTTER, y = Math.floor(i / COLS) * PITCH + GUTTER;
        blit(c.img, x, y);
        uv[c.key] = [x / W, y / H, (x + CELL) / W, (y + CELL) / H];
    });
    blit(bar, GUTTER, barY);
    uv[BAR.key] = [GUTTER / W, barY / H, (GUTTER + bar.w) / W, (barY + bar.h) / H];

    const png = encode(W, H, atlas);
    const version = crypto.createHash("sha1").update(png).digest("hex").slice(0, 8);
    const b64 = png.toString("base64");
    const lines = [];
    for (let i = 0; i < b64.length; i += 100) lines.push(b64.slice(i, i + 100));
    const num = v => Number(v.toFixed(6)).toString();
    const keys = Object.keys(uv).sort();
    const lua = [
        "-- Jambix AIO / esp/art_pack -- GENERATED by tools/jcheck/art_pack.js; do not edit.",
        "--",
        `-- The game's own icons, cut out of ${store.build.product} ${store.build.version} offline and`,
        "-- packed into one PNG atlas, carried here as base64 so every copy of the plugin",
        "-- has them (the loader cannot read the archives in the game). modules/esp/art.lua",
        "-- writes the PNG into scripts_data and registers the cells below with JCore.",
        ...(altUsed.length ? [`-- From ${alt.build.product} ${alt.build.version}, which ${store.build.product} lacks: ${altUsed.join(", ")}.`] : []),
        "-- Cells are u0, v0, u1, v1 fractions of the atlas.",
        "",
        "return {",
        `    version = "${version}",`,
        `    w = ${W}, h = ${H}, cell = ${CELL},`,
        "    cells = {",
        ...keys.map(k => `        ["${k}"] = { ${uv[k].map(num).join(", ")} },`),
        "    },",
        "    png = [[",
        ...lines,
        "]],",
        "}",
        "",
    ].join("\n");
    fs.writeFileSync(OUT, lua);

    // A look at it: three times the size, on a checkerboard.
    const S = 3, PW = W * S, PH = H * S, prev = Buffer.alloc(PW * PH * 4);
    for (let y = 0; y < PH; y++) for (let x = 0; x < PW; x++) {
        const o = (y * PW + x) * 4, so = (Math.floor(y / S) * W + Math.floor(x / S)) * 4;
        const bg = ((x >> 4) + (y >> 4)) & 1 ? 70 : 100, a = atlas[so + 3] / 255;
        for (let k = 0; k < 3; k++) prev[o + k] = Math.round(atlas[so + k] * a + bg * (1 - a));
        prev[o + 3] = 255;
    }
    fs.mkdirSync(path.dirname(PREVIEW), { recursive: true });
    fs.writeFileSync(PREVIEW, encode(PW, PH, prev));
    console.log(`art pack ${version}: ${cells.length} cells + status bar, ${W}x${H}, png ${png.length} bytes, lua ${lua.length} bytes`);
    console.log(`  -> ${path.relative(ROOT, OUT)}`);
    console.log(`  preview ${path.relative(ROOT, PREVIEW)}`);
}

main();
