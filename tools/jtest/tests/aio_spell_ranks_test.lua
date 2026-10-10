-- The spellbook's best rank (1.88.1): by level on the lines whose ids do not
-- rise with their levels (modules/rank_order.lua, from the client's tables),
-- by id everywhere else. The user (2026-10-09): "check dumps for updates Ranks
-- on spells for hunters". Battle Shout's rank 1 is 6673, above ranks 2 and 3;
-- Forever's Trueshot Aura ranks at 25 and 32 are above the 40 to 60 ones.

local function assert_eq(got, want, what)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", what, tostring(want), tostring(got)), 2)
    end
end

--- A spellbook over `names` (id -> name) on the client `version` ("Vanilla",
--- "Forever", or nil for none).
local function book_of(version, names)
    local ids = {}
    for id in pairs(names) do ids[#ids + 1] = id end
    table.sort(ids)
    _G.core = {
        time = function() return 100 end,
        spell_book = {
            get_spells = function() return ids end,
            get_spell_name = function(id) return names[id] or "" end,
            is_spell_known = function(id) return names[id] ~= nil end,
        },
    }
    local ctx = {
        on = function() end, every = function() end, emit = function() end,
        spells = { learned = function(id) return names[id] ~= nil, "known" end },
    }
    if version then
        ctx.world = { client = function() return { version = version, forever = version == "Forever" } end }
    end
    local P = { log = { once = function() end, fmt = function() end, info = function() end }, ctx = ctx }
    local book = require("jambix_aio/modules/spellbook")(P)
    book.refresh()
    return book
end

local T = {}

T[#T + 1] = { "Era: Battle Shout, the crusader seal, Hammer of Wrath and Distracting Shot take their best rank, not their highest id", function()
    local book = book_of("Vanilla", {
        [6673] = "Battle Shout", [5242] = "Battle Shout", [6192] = "Battle Shout",
        [21082] = "Seal of the Crusader", [20162] = "Seal of the Crusader", [20305] = "Seal of the Crusader",
        [24275] = "Hammer of Wrath", [24274] = "Hammer of Wrath", [24239] = "Hammer of Wrath",
        [20736] = "Distracting Shot", [14274] = "Distracting Shot",
        [465] = "Devotion Aura", [10290] = "Devotion Aura", [643] = "Devotion Aura", [10291] = "Devotion Aura",
        [1032] = "Devotion Aura",
        -- In id order: unchanged.
        [3044] = "Arcane Shot", [14281] = "Arcane Shot", [14282] = "Arcane Shot",
    })
    assert_eq(book.id("Battle Shout"), 6192, "Battle Shout at 22: rank 3, not rank 1 (6673)")
    assert_eq(book.id("Seal of the Crusader"), 20305, "Seal of the Crusader: rank 3, not rank 1 (21082)")
    assert_eq(book.id("Hammer of Wrath"), 24239, "Hammer of Wrath: rank 3 (60), the lowest id")
    assert_eq(book.id("Distracting Shot"), 14274, "Distracting Shot: rank 2, not rank 1 (20736)")
    assert_eq(book.id("Devotion Aura"), 1032, "Devotion Aura at 40: rank 5, not rank 4 (10291)")
    assert_eq(book.id("Arcane Shot"), 14282, "Arcane Shot: the highest id, as before")
    local ids = book.ids("Battle Shout")
    assert_eq(#ids, 3, "every rank is still kept for the aura checks")
end }

T[#T + 1] = { "Era: Create Healthstone by prefix makes the plain one at 34, not (Lesser)", function()
    local book = book_of("Vanilla", {
        [6201] = "Create Healthstone (Minor)", [6202] = "Create Healthstone (Lesser)", [5699] = "Create Healthstone",
    })
    assert_eq(book.id_prefix("Create Healthstone"), 5699, "level 34's Create Healthstone")
end }

T[#T + 1] = { "Forever: Trueshot Aura's ranks at 25 and 32 rank below 40 to 60; Counterattack's extra id below its trained ranks", function()
    local book = book_of("Forever", {
        [1299346] = "Trueshot Aura", [1299348] = "Trueshot Aura", [19506] = "Trueshot Aura", [20905] = "Trueshot Aura",
        [1242634] = "Counterattack", [20909] = "Counterattack",
        [6201] = "Create Healthstone", [6202] = "Create Healthstone", [5699] = "Create Healthstone",
    })
    assert_eq(book.id("Trueshot Aura"), 20905, "Trueshot Aura at 50: the level 50 rank")
    assert_eq(book.id("Counterattack"), 20909, "Counterattack at 42: rank 2")
    assert_eq(book.id("Create Healthstone"), 5699, "one name on Forever: still the level 34 rank")

    local low = book_of("Forever", { [1299346] = "Trueshot Aura", [1299348] = "Trueshot Aura" })
    assert_eq(low.id("Trueshot Aura"), 1299348, "at 32: the level 32 rank")
end }

T[#T + 1] = { "Forever: the level 19 hunter's book from the dump resolves as before", function()
    -- scripts_data/jcore/jcore.dump.forever.json (2026-10-09), known ranks.
    local book = book_of("Forever", {
        [3044] = "Arcane Shot", [14281] = "Arcane Shot",
        [13165] = "Aspect of the Hawk", [14318] = "Aspect of the Hawk",
        [2973] = "Raptor Strike", [14260] = "Raptor Strike", [14261] = "Raptor Strike",
        [1978] = "Serpent Sting", [13549] = "Serpent Sting", [13550] = "Serpent Sting",
        [13795] = "Immolation Trap", [20736] = "Distracting Shot", [1130] = "Hunter's Mark",
    })
    assert_eq(book.id("Arcane Shot"), 14281, "Arcane Shot rank 2")
    assert_eq(book.id("Aspect of the Hawk"), 14318, "Aspect of the Hawk rank 2")
    assert_eq(book.id("Raptor Strike"), 14261, "Raptor Strike rank 3")
    assert_eq(book.id("Serpent Sting"), 13550, "Serpent Sting rank 3")
    assert_eq(book.id("Immolation Trap"), 13795, "Immolation Trap rank 1")
    assert_eq(book.id("Distracting Shot"), 20736, "Distracting Shot: rank 1 is all there is at 19")
end }

T[#T + 1] = { "any other client, or no client read: the highest id, exactly as before", function()
    local names = { [6673] = "Battle Shout", [5242] = "Battle Shout", [6192] = "Battle Shout" }
    assert_eq(book_of("Tbc", names).id("Battle Shout"), 6673, "TBC has no table: old order")
    assert_eq(book_of(nil, names).id("Battle Shout"), 6673, "no world service: old order")
end }

T[#T + 1] = { "rank_order.lua: both clients, with their builds, and the lines the fixes stand on", function()
    local data = require("jambix_aio/modules/rank_order")
    assert(type(data.vanilla) == "table" and type(data.forever) == "table", "both clients")
    assert(tostring(data.vanilla.build):match("^1%.15%."), "Era build: " .. tostring(data.vanilla.build))
    assert(tostring(data.forever.build):match("^1%.60%."), "Forever build: " .. tostring(data.forever.build))
    assert_eq(data.vanilla.levels[6673], 1, "Era Battle Shout rank 1")
    assert_eq(data.vanilla.levels[6192], 22, "Era Battle Shout rank 3")
    assert_eq(data.forever.levels[1299348], 32, "Forever Trueshot Aura at 32")
    assert_eq(data.forever.levels[20906], 60, "Forever Trueshot Aura at 60")
    assert_eq(data.vanilla.levels[1299348], nil, "Era has no Forever ids")
    for client, c in pairs(data) do
        for id, level in pairs(c.levels) do
            assert(math.type(id) == "integer" and id > 0, client .. ": bad id " .. tostring(id))
            assert(math.type(level) == "integer" and level >= 1 and level <= 60, client .. ": bad level for " .. id)
        end
    end
end }

return T
