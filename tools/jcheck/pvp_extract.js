#!/usr/bin/env node
// PvP spell facts, from the clients' own tables (PvP intelligence, Stage 3).
//
//   node tools/jcheck/pvp_extract.js [--client all|vanilla|forever] [--wow <install>] [--out <file>]
//
// Both clients by default: the AIO reads the running client's half.
//
// The PvP intelligence layer (scripts/jambix_aio/modules/react/intel) needs,
// for the abilities a player throws at you or saves itself with, what the
// client says about them -- never what a guide remembers:
//   SpellCooldowns   RecoveryTime, CategoryRecoveryTime (a shared cooldown:
//                    Freezing and Frost Trap on Forever), StartRecoveryTime
//   SpellCategories  Category (the shared cooldown's id), Mechanic, DispelType,
//                    and on Forever DiminishType (Era's table has no such column)
//   SpellEffect      EffectMechanic, where the category row says none
//   SpellMisc/Range  the minimum and maximum range
//   SpellMisc/Duration  how long it lasts
//   SpellLevels      the level the top rank is learned at
// per class (its own skill lines, as class_names_check.js finds them), and
// the racials. The NAMES below are the only thing typed by hand: the plugin
// already uses every one of them (rules/pvp.lua, catalog/hunter.lua,
// intel/data.lua). A name a client does not have is left out of that
// client's half, and said on the console.
//
// WRITTEN: scripts/jambix_aio/modules/pvp_data.lua, a plain Lua table. Do
// not edit it by hand: run this again after a client patch.
"use strict";
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..");
const cascLib = require("./lib/casc");
const db2 = require("./lib/db2");

const argv = process.argv.slice(2);
const opt = name => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : null; };
const WOW = opt("--wow") || "C:/Program Files (x86)/World of Warcraft";
const OUT = opt("--out") || path.join(ROOT, "scripts", "jambix_aio", "modules", "pvp_data.lua");
const CLIENTS = {
    vanilla: { product: "wow_classic_era" },
    forever: { product: "wow_classic_beta" },
};
const wantClient = (opt("--client") || "all").toLowerCase();

// FileDataIDs, for clients whose root carries no names (Forever's).
const TABLES = {
    SkillLine: 1240935, SkillLineAbility: 1266278, SkillRaceClassInfo: 1240406, SpellName: 1990283,
    SpellLevels: 1140079, SpellCooldowns: 1139924, SpellCategories: 1139939, SpellMisc: 1003144,
    SpellRange: 1146820, SpellDuration: 1137828, SpellEffect: 1140088,
};

const CLASS_NAMES = ["WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT", "SHAMAN", "MAGE",
    "WARLOCK", "MONK", "DRUID"];

// The abilities a PvP decision asks about, per class. Names only; every
// number comes from the tables.
const WANT = {
    WARRIOR: ["Charge", "Intercept", "Berserker Rage", "Recklessness", "Death Wish", "Shield Wall", "Last Stand",
        "Retaliation", "Intimidating Shout", "Concussion Blow", "Disarm", "Pummel", "Shield Bash", "Bloodrage",
        "Hamstring", "Mortal Strike", "Whirlwind", "Sweeping Strikes", "Piercing Howl", "Overpower", "Execute",
        "Taunt", "Mocking Blow", "Shield Block", "Defensive Stance", "Berserker Stance", "Battle Stance"],
    ROGUE: ["Sprint", "Vanish", "Evasion", "Blind", "Kidney Shot", "Gouge", "Kick", "Adrenaline Rush", "Blade Flurry",
        "Cold Blood", "Preparation", "Cheap Shot", "Sap", "Ghostly Strike", "Riposte", "Stealth", "Distract",
        "Premeditation", "Hemorrhage", "Eviscerate", "Sinister Strike", "Backstab", "Ambush", "Rupture",
        "Slice and Dice", "Expose Armor", "Feint", "Shadowstep"],
    MAGE: ["Blink", "Frost Nova", "Counterspell", "Ice Block", "Ice Barrier", "Cold Snap", "Arcane Power",
        "Presence of Mind", "Combustion", "Polymorph", "Evocation", "Cone of Cold", "Blast Wave", "Fire Blast",
        "Frostbolt", "Fireball", "Pyroblast", "Scorch", "Arcane Explosion", "Mana Shield", "Frost Ward", "Fire Ward",
        "Arcane Missiles", "Flamestrike", "Blizzard", "Remove Lesser Curse"],
    WARLOCK: ["Death Coil", "Howl of Terror", "Fear", "Shadowburn", "Conflagrate", "Amplify Curse",
        "Curse of Exhaustion", "Curse of Tongues", "Shadow Bolt", "Immolate", "Corruption", "Curse of Agony",
        "Bane of Agony", "Drain Life", "Drain Mana", "Soul Fire", "Siphon Life", "Life Tap", "Dark Pact",
        "Shadow Ward", "Banish", "Searing Pain", "Hellfire", "Rain of Fire"],
    PRIEST: ["Psychic Scream", "Power Word: Shield", "Fear Ward", "Power Infusion", "Inner Focus", "Silence",
        "Mind Blast", "Desperate Prayer", "Mind Control", "Mind Flay", "Shadow Word: Pain", "Devouring Plague",
        "Vampiric Embrace", "Flash Heal", "Greater Heal", "Renew", "Dispel Magic", "Mana Burn", "Holy Fire",
        "Smite", "Shadowform", "Fade", "Prayer of Healing", "Holy Nova", "Shackle Undead", "Elune's Grace",
        "Starshards", "Feedback", "Touch of Weakness", "Hex of Weakness", "Devouring Plague"],
    PALADIN: ["Hammer of Justice", "Divine Shield", "Divine Protection", "Blessing of Protection", "Blessing of Freedom",
        "Blessing of Sacrifice", "Lay on Hands", "Repentance", "Holy Shock", "Divine Favor", "Consecration",
        "Holy Light", "Flash of Light", "Cleanse", "Purify", "Judgement", "Hammer of Wrath", "Exorcism",
        "Turn Undead", "Seal of Command", "Seal of Righteousness", "Seal of the Crusader", "Blessing of Freedom"],
    DRUID: ["Bash", "Feral Charge", "Barkskin", "Nature's Grasp", "Nature's Swiftness", "Innervate", "Dash",
        "Entangling Roots", "Hibernate", "Prowl", "Rebirth", "Pounce", "Frenzied Regeneration", "Enrage",
        "Challenging Roar", "Swiftmend", "Faerie Fire", "Faerie Fire (Feral)", "Cat Form", "Bear Form",
        "Dire Bear Form", "Travel Form", "Moonkin Form", "Aquatic Form", "Healing Touch", "Regrowth",
        "Rejuvenation", "Moonfire", "Wrath", "Starfire", "Hurricane", "Cyclone", "Maim", "Ravage", "Shred",
        "Claw", "Rake", "Ferocious Bite", "Rip", "Tiger's Fury", "Cower", "Demoralizing Roar", "Growl", "Maul",
        "Swipe", "Abolish Poison", "Remove Curse", "Tranquility", "Soothe Animal"],
    SHAMAN: ["Earthbind Totem", "Grounding Totem", "Tremor Totem", "Frost Shock", "Earth Shock", "Flame Shock",
        "Elemental Mastery", "Nature's Swiftness", "Stoneclaw Totem", "Windfury Totem", "Lightning Bolt",
        "Chain Lightning", "Healing Wave", "Lesser Healing Wave", "Chain Heal", "Purge", "Ghost Wolf",
        "Mana Tide Totem", "Reincarnation", "Fire Nova Totem", "Fire Nova", "Searing Totem",
        "Poison Cleansing Totem", "Stormstrike", "Lightning Shield", "Cure Poison", "Cure Disease"],
    HUNTER: ["Scatter Shot", "Freezing Trap", "Frost Trap", "Immolation Trap", "Explosive Trap", "Concussive Shot",
        "Wing Clip", "Feign Death", "Deterrence", "Intimidation", "Bestial Wrath", "Rapid Fire", "Disengage",
        "Wyvern Sting", "Flare", "Aimed Shot", "Multi-Shot", "Arcane Shot", "Viper Sting", "Serpent Sting",
        "Scorpid Sting", "Scare Beast", "Counterattack", "Summon Hawk", "Strider Kick", "Silencing Shot",
        "Readiness", "Hunter's Mark", "Raptor Strike", "Mongoose Bite", "Distracting Shot", "Tranquilizing Shot",
        "Volley", "Aspect of the Monkey", "Aspect of the Hawk", "Aspect of the Cheetah", "Aspect of the Beast",
        "Mend Pet", "Eyes of the Beast", "Track Hidden", "Lacerate", "Sniper Shot", "Trueshot Aura"],
};
// Racials: every race's own skill line (SkillRaceClassInfo with a RaceMask
// and no ClassMask), by name.
const RACIALS = ["War Stomp", "Will of the Forsaken", "Escape Artist", "Stoneform", "Berserking", "Blood Fury",
    "Perception", "Shadowmeld", "Cannibalize"];
// A warlock's or a hunter's pet, on the "Pet - <family>" lines.
const PETS = ["Spell Lock", "Devour Magic", "Seduction", "Sacrifice", "Suffering", "Torment", "Fire Shield",
    "Lesser Invisibility", "Paranoia", "Growl", "Intimidation", "Dash", "Dive", "Charge", "Screech", "Cower",
    "Bite", "Claw", "Prowl", "Furious Howl", "Thunderstomp", "Scorpid Poison", "Lightning Breath"];

// SpellMechanic ids (SpellMechanic.db2, the same on every Blizzard client).
const MECHANIC = { 1: "charm", 2: "disorient", 3: "disarm", 4: "distract", 5: "fear", 6: "grip", 7: "root",
    8: "slow_attack", 9: "silence", 10: "sleep", 11: "snare", 12: "stun", 13: "freeze", 14: "knockout", 15: "bleed",
    16: "bandage", 17: "polymorph", 18: "banish", 19: "shield", 20: "shackle", 21: "mount", 22: "infected",
    23: "turn", 24: "horror", 25: "invulnerability", 26: "interrupt", 27: "daze", 28: "discovery",
    29: "immune_shield", 30: "sapped", 31: "enraged" };
const DISPEL = { 0: "none", 1: "magic", 2: "curse", 3: "disease", 4: "poison", 5: "stealth", 6: "invisibility",
    7: "all", 9: "enrage" };

function readTables(casc) {
    const T = {};
    for (const [name, fdid] of Object.entries(TABLES)) {
        let bytes;
        try { bytes = casc.read("DBFilesClient/" + name + ".db2"); }
        catch (e) { bytes = casc.read(fdid); }
        T[name] = db2.parse(bytes, db2.loadDbd(path.join(__dirname, "dbd", name + ".dbd")));
    }
    return T;
}

function extract(clientKey) {
    const c = CLIENTS[clientKey];
    const casc = cascLib.open({ wow: WOW, product: c.product });
    const T = readTables(casc);
    const build = (casc.build && casc.build.version) || "?";
    casc.close();

    const N = id => (T.SpellName.byId.get(id) || {}).Name_lang;
    const level = new Map();
    for (const r of T.SpellLevels.rows) if (!level.has(r.SpellID) || !r.DifficultyID) level.set(r.SpellID, r.BaseLevel || r.SpellLevel || 0);
    const cooldown = new Map();
    for (const r of T.SpellCooldowns.rows) if (!cooldown.has(r.SpellID) || !r.DifficultyID) cooldown.set(r.SpellID, r);
    const category = new Map();
    for (const r of T.SpellCategories.rows) if (!category.has(r.SpellID) || !r.DifficultyID) category.set(r.SpellID, r);
    const misc = new Map();
    for (const r of T.SpellMisc.rows) if (!misc.has(r.SpellID) || !r.DifficultyID) misc.set(r.SpellID, r);
    const effectMech = new Map();
    for (const r of T.SpellEffect.rows) {
        if (r.EffectMechanic) effectMech.set(r.SpellID, Math.max(effectMech.get(r.SpellID) || 0, r.EffectMechanic));
    }
    const lines = new Map(T.SkillLine.rows.map(r => [r.ID, r]));

    /** The facts of one spell id. */
    function facts(id) {
        const cd = cooldown.get(id);
        const cat = category.get(id);
        const m = misc.get(id);
        const rg = m && T.SpellRange.byId.get(m.RangeIndex);
        const dur = m && T.SpellDuration.byId.get(m.DurationIndex);
        const mech = (cat && cat.Mechanic) || effectMech.get(id) || 0;
        const out = {
            id,
            level: level.get(id) || 0,
            cd: cd ? Math.max(cd.RecoveryTime || 0, cd.CategoryRecoveryTime || 0) / 1000 : 0,
            cat_cd: cd ? (cd.CategoryRecoveryTime || 0) / 1000 : 0,
            gcd: cd ? (cd.StartRecoveryTime || 0) / 1000 : 0,
            category: cat ? (cat.Category || 0) : 0,
            mechanic: MECHANIC[mech] || (mech ? "mechanic " + mech : "none"),
            dispel: cat ? (DISPEL[cat.DispelType] || "dispel " + cat.DispelType) : "none",
            min: rg ? (rg.RangeMin ? rg.RangeMin[0] : 0) || 0 : 0,
            range: rg ? (rg.RangeMax ? rg.RangeMax[0] : 0) || 0 : 0,
            duration: dur ? (dur.Duration || 0) / 1000 : 0,
            school: m ? (m.SchoolMask || 0) : 0,
        };
        if (cat && cat.DiminishType !== undefined && cat.DiminishType !== null) out.diminish = cat.DiminishType;
        return out;
    }

    const classes = {};
    const missing = [];
    CLASS_NAMES.forEach((cls, i) => {
        const want = WANT[cls];
        if (!want) return;
        const bit = 1 << i;
        const own = new Set();
        for (const r of T.SkillRaceClassInfo.rows) {
            const line = lines.get(r.SkillID);
            if (line && line.CategoryID === 7 && r.ClassMask > 0 && (r.ClassMask & bit)) own.add(r.SkillID);
        }
        const byName = new Map();          // name -> [ids]
        for (const r of T.SkillLineAbility.rows) {
            const mine = own.has(r.SkillLine) ? !r.ClassMask || (r.ClassMask & bit) : r.ClassMask > 0 && (r.ClassMask & bit);
            if (!mine) continue;
            const name = N(r.Spell);
            if (!name) continue;
            if (!byName.has(name)) byName.set(name, []);
            byName.get(name).push(r.Spell);
        }
        const out = {};
        for (const name of new Set(want)) {
            let ids = byName.get(name);
            if (!ids || !ids.length) { missing.push(cls + ": " + name); continue; }
            // Era carries Season of Discovery's rune versions under the same
            // names (ids 400000 and up): the Classic ranks are the ones asked for.
            if (clientKey === "vanilla" && ids.some(id => id < 400000)) ids = ids.filter(id => id < 400000);
            // The top rank: the highest level, then the highest id.
            const ranked = ids.map(facts).sort((a, b) => (b.level - a.level) || (b.id - a.id));
            const top = ranked[0];
            top.ids = ids.slice().sort((a, b) => a - b);
            out[name] = top;
        }
        classes[cls] = out;
    });

    // Racials sit on the races' own lines (SkillLine.CategoryID 9: "Racial -
    // Troll", "Dwarven Racial"); pets' on the "Pet - Felhunter" lines
    // (CategoryID 7, no class). Each group by its lines, by name.
    function group(label, want, lineFilter) {
        const mine = new Set();
        for (const [id, line] of lines) if (lineFilter(line, id)) mine.add(id);
        const byName = new Map();
        for (const r of T.SkillLineAbility.rows) {
            if (!mine.has(r.SkillLine)) continue;
            const name = N(r.Spell);
            if (!name) continue;
            if (!byName.has(name)) byName.set(name, []);
            byName.get(name).push(r.Spell);
        }
        const out = {};
        for (const name of want) {
            const ids = byName.get(name);
            if (!ids || !ids.length) { missing.push(label + ": " + name); continue; }
            const ranked = ids.map(facts).sort((a, b) => (b.level - a.level) || (b.id - a.id));
            const top = ranked[0];
            top.ids = ids.slice().sort((a, b) => a - b);
            out[name] = top;
        }
        return out;
    }
    const raced = new Set(T.SkillRaceClassInfo.rows.filter(r => r.RaceMask > 0).map(r => r.SkillID));
    classes.RACIAL = group("RACIAL", RACIALS, (line, id) => line.CategoryID === 9 || (raced.has(id) && /Racial/.test(line.DisplayName_lang || "")));
    classes.PET = group("PET", PETS, line => /^Pet - /.test(line.DisplayName_lang || ""));

    const hasDiminish = T.SpellCategories.rows.some(r => r.DiminishType !== undefined && r.DiminishType !== null);
    return { build, classes, missing, hasDiminish };
}

function luaStr(s) { return '"' + String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"'; }

function luaRow(f) {
    const parts = [`id = ${f.id}`, `level = ${f.level}`, `cd = ${f.cd}`];
    if (f.cat_cd) parts.push(`cat_cd = ${f.cat_cd}`);
    if (f.category) parts.push(`category = ${f.category}`);
    parts.push(`gcd = ${f.gcd}`);
    parts.push(`mechanic = ${luaStr(f.mechanic)}`);
    if (f.dispel !== "none") parts.push(`dispel = ${luaStr(f.dispel)}`);
    if (f.min) parts.push(`min = ${f.min}`);
    parts.push(`range = ${f.range}`);
    if (f.duration) parts.push(`duration = ${f.duration}`);
    if (f.school) parts.push(`school = ${f.school}`);
    if (f.diminish !== undefined) parts.push(`diminish = ${f.diminish}`);
    parts.push(`ids = { ${f.ids.join(", ")} }`);
    return "{ " + parts.join(", ") + " }";
}

function main() {
    const keys = wantClient === "all" ? Object.keys(CLIENTS) : [wantClient];
    const result = {};
    for (const key of keys) {
        process.stdout.write(`${key} (${CLIENTS[key].product}): reading... `);
        const r = extract(key);
        result[key] = r;
        const n = Object.values(r.classes).reduce((a, c) => a + Object.keys(c).length, 0);
        console.log(`build ${r.build}, ${n} spells, DiminishType ${r.hasDiminish ? "present" : "absent"}`);
        for (const m of r.missing) console.log("  not in this client: " + m);
    }
    let lua = "-- Jambix AIO / pvp_data -- what the clients' own tables say about the\n";
    lua += "-- abilities a PvP decision asks about (tools/jcheck/pvp_extract.js).\n";
    lua += "-- GENERATED: do not edit by hand; run the extractor after a client patch.\n--\n";
    lua += "-- Per client, per class (and RACIAL), by name, the top rank: id, the level\n";
    lua += "-- it is learned at, cd (seconds: RecoveryTime or the category's, whichever\n";
    lua += "-- is longer), cat_cd and category (a cooldown shared with every spell of\n";
    lua += "-- the category), gcd, mechanic (SpellCategories.Mechanic, else the\n";
    lua += "-- effect's), dispel, min and range (yards), duration (seconds), school\n";
    lua += "-- (SpellMisc.SchoolMask), diminish (SpellCategories.DiminishType, Forever\n";
    lua += "-- only: Era's table has no such column), and every rank's id.\n";
    lua += "return {\n";
    for (const key of keys) {
        const r = result[key];
        lua += `    ${key} = {\n        build = ${luaStr(r.build)}, diminish_column = ${r.hasDiminish},\n        classes = {\n`;
        for (const cls of Object.keys(r.classes).sort()) {
            lua += `            ${cls} = {\n`;
            for (const name of Object.keys(r.classes[cls]).sort()) {
                lua += `                [${luaStr(name)}] = ${luaRow(r.classes[cls][name])},\n`;
            }
            lua += "            },\n";
        }
        lua += "        },\n    },\n";
    }
    lua += "}\n";
    fs.writeFileSync(OUT, lua);
    console.log("written " + path.relative(ROOT, OUT) + " (" + lua.split("\n").length + " lines)");
}

main();
