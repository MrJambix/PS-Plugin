-- Jambix AIO / esp/elements -- the marks themselves, one drawer each.
--
-- An element is a row in cfg.ELEMENTS -- key, label, default, kind, tier --
-- and a drawer here under the same key. The split is deliberate: the menu
-- declares toggles from the config rows without loading this file, and this
-- file cannot invent a mark that has no toggle, because a drawer with no row
-- is never reached.
--
-- Adding a mark is therefore two edits: a row in config, a drawer here.
-- Nothing in the collector changes, and an element that is switched off costs
-- one table lookup per entity rather than a branch inside the walk.
--
-- WHAT A DRAWER GETS
--   e   the entity from collect.lua -- obj, guid, kind, info, name, category,
--       badge, distance, range, dead, lod
--   v   the frame's view: this entity's colour, the text size, the layer for
--       each band, whether these marks may be dropped when over budget, and
--       what the unit is doing, worked out once before any row is drawn:
--         v.detail       P.esp_collect.detail(e) -- may be nil
--         v.cast         the cast to draw, or nil
--         v.victim       "me", "pet", "group", or nil
--         v.status_text  the status line and v.status_color, or nil
--         v.threat_text  the threat row and v.threat_color, or nil
--         v.details_text the level / distance / health line, or nil, and
--         v.details_lead its level when that is drawn in its own colour
--         v.is_target    whether it is the player's selected target
--         v.rows_below   whether the `below` rows go under the feet
-- A row drawer draws at v.anchor.x, v.cursor and moves the cursor on; the
-- same drawer serves above the head and under the feet, because the second
-- pass simply hands it a different anchor. Information rows are pills:
-- seg(text, colour, border) per pill, then pill_row(e, v).
--
-- THE NEW LOOK (1.88.0). The user, 2026-10-08: "Take all ESPs and convert it
-- to this!", choosing "Ground rings, Boxes to curtains, Far things as
-- beacons, Cards and bars, Only Show Gatherables that I can Gather with my
-- skills". Rings on the ground are JCore's shader ring_3d; the box can be a
-- short curtain round the unit (and is by default); a far rare, boss, quest
-- target or loot gets a pillar of light; pills are soft plates and bars
-- shade on a rounded rail while `esp_shader_look` is on. Every one of those
-- calls is asked for before it is used: an older JCore draws as before.

return function(P)
    local ctx, cfg = P.ctx, P.cfg
    local units, draw = P.units, P.draw

    local M = {}

    -- --- shared helpers -----------------------------------------------------

    -- Colours that are not per-category and therefore not in P.category_color.
    -- Built once for the same reason that table is: a colour allocated per
    -- mark per frame is the cost that only shows up with five plugins loaded.
    -- level_color (1.67.0): the level number alone, in the colour its target
    -- frame gives it (cfg.LEVEL_RGB), on anything you can attack.
    local reaction_color, difficulty_color, level_color = {}, {}, {}
    for name, rgb in pairs(cfg.REACTION_RGB) do
        reaction_color[name] = P.color(rgb[1], rgb[2], rgb[3])
    end
    for name, rgb in pairs(cfg.DIFFICULTY_RGB) do
        difficulty_color[name] = P.color(rgb[1], rgb[2], rgb[3])
    end
    for name, rgb in pairs(cfg.LEVEL_RGB) do
        level_color[name] = P.color(rgb[1], rgb[2], rgb[3])
    end

    -- A corpse is no longer friend or foe: its pill says "dead", in grey.
    reaction_color.dead = P.color(cfg.DEAD_RGB[1], cfg.DEAD_RGB[2], cfg.DEAD_RGB[3])

    M.reaction_color = reaction_color
    M.difficulty_color = difficulty_color

    -- The role badge's colours, and the opaque disc the class portrait sits
    -- on. The disc is not the theme backdrop: that one is translucent, and a
    -- portrait ring has to hide the corners of a square icon completely.
    local role_color, role_color_guess = {}, {}
    for name, rgb in pairs(cfg.ROLE_RGB) do
        role_color[name] = P.color(rgb[1], rgb[2], rgb[3])
        role_color_guess[name] = P.color(rgb[1], rgb[2], rgb[3], 165)
    end
    local npc_role_color = {}
    for name, rgb in pairs(cfg.NPC_ROLE_RGB) do
        npc_role_color[name] = P.color(rgb[1], rgb[2], rgb[3])
    end
    -- How it fights: melee, ranged, caster. A guess is drawn at reduced
    -- alpha, the way a guessed player role is.
    local fight_color, fight_color_guess = {}, {}
    for name, rgb in pairs(cfg.FIGHT_RGB) do
        fight_color[name] = P.color(rgb[1], rgb[2], rgb[3])
        fight_color_guess[name] = P.color(rgb[1], rgb[2], rgb[3], 165)
    end
    M.fight_color = fight_color
    M.fight_color_guess = fight_color_guess
    local disc_color = P.color(16, 16, 20, 245)
    local badge_text = P.color(245, 245, 250)

    local cast_color = {}
    for name, rgb in pairs(cfg.CAST_RGB) do
        cast_color[name] = P.color(rgb[1], rgb[2], rgb[3])
    end
    local status_color = {}
    for name, rgb in pairs(cfg.STATUS_RGB) do
        status_color[name] = P.color(rgb[1], rgb[2], rgb[3])
    end
    local tapped_color = P.color(cfg.TAPPED_RGB[1], cfg.TAPPED_RGB[2], cfg.TAPPED_RGB[3])
    local threat_color = {}
    for name, rgb in pairs(cfg.THREAT_RGB) do
        threat_color[name] = P.color(rgb[1], rgb[2], rgb[3])
    end
    local marker_color = {}
    for index, m in pairs(cfg.RAID_MARKERS) do
        marker_color[index] = P.color(m.rgb[1], m.rgb[2], m.rgb[3])
    end

    M.cast_color = cast_color
    M.status_color = status_color
    M.tapped_color = tapped_color
    M.threat_color = threat_color

    -- --- art sources --------------------------------------------------------
    --
    -- Every portrait has a list of places its art can come from, best first:
    -- the game's own archives, read through JCore's casc service; the copy
    -- an installed addon keeps on disk; the same icon by name from the CDN.
    -- Built once; a string concatenation per player per frame is garbage for
    -- nothing.
    --
    -- A cell that is ROUND already -- a role circle, an addon's crest on
    -- transparent corners -- needs no mask ring; a square icon does. The
    -- flag rides with the reference.

    local assets = P.JCore and P.JCore.assets

    --- The addon spells texture coordinates left, right, top, bottom; the
    --- registry wants u0, v0, u1, v1.
    local function to_uv(cells)
        local uv = {}
        for key, c in pairs(cells) do uv[key] = { c[1], c[3], c[2], c[4] } end
        return uv
    end

    --- Registers a sheet as an atlas. Game sheets are registered whenever
    --- the registry exists -- the casc service answers whether the client
    --- can be read -- and addon sheets only when the addon is installed.
    local function register_sheet(name, ref, cells, addon)
        if not assets or not assets.atlas then return nil end
        if addon then
            if not assets.addon_installed then return nil end
            local ok, installed = pcall(assets.addon_installed, addon)
            if not ok or not installed then return nil end
        end
        -- The registry can raise on a client whose archives it cannot read
        -- yet. A sheet that fails to register is a missing icon, not a
        -- reason for the whole plugin to stop loading -- and this runs at
        -- start, before the rotation has loaded.
        local ok, err = pcall(assets.atlas, name, ref, to_uv(cells))
        if not ok then
            if P.log then P.log.fmt("warn", "sheet %s not registered: %s", name, tostring(err)) end
            return nil
        end
        return name
    end

    local game_classes = register_sheet("jambix_game_classes",
        cfg.GAME_CLASS_SHEET.ref, cfg.GAME_CLASS_SHEET.cells, nil)
    local game_roles = register_sheet("jambix_game_roles",
        cfg.GAME_ROLE_SHEET.ref, cfg.GAME_ROLE_SHEET.cells, nil)

    local class_sheet = register_sheet("jambix_classes",
        cfg.CLASS_SHEET.ref, cfg.CLASS_SHEET.cells, cfg.CLASS_SHEET.addon)

    local spec_sheet, spec_sheet_ref = nil, nil
    for i = 1, #cfg.SPEC_SHEETS do
        local sheet = cfg.SPEC_SHEETS[i]
        spec_sheet = register_sheet("jambix_specs", sheet.ref, cfg.SPEC_CELLS, sheet.addon)
        if spec_sheet then spec_sheet_ref = sheet.ref break end
    end

    -- class id -> { { ref, round }, ... }
    local class_art = {}
    for id, name in pairs(P.esp_roles.CLASS_NAME) do
        local list = {}
        if game_classes and cfg.GAME_CLASS_SHEET.cells[name] then
            list[#list + 1] = { "atlas:" .. game_classes .. "/" .. name, false }
        end
        if assets then
            list[#list + 1] = { cfg.game_icon("classicon_" .. name:lower()), false }
        end
        if class_sheet and cfg.CLASS_SHEET.cells[name] then
            list[#list + 1] = { "atlas:" .. class_sheet .. "/" .. name, true }
        end
        list[#list + 1] = { "icon:classicon_" .. name:lower(), false }
        class_art[id] = list
    end

    -- role -> { { ref, round } }: the client's own role circle
    local role_art = {}
    if game_roles then
        for role in pairs(cfg.GAME_ROLE_SHEET.cells) do
            role_art[role] = { { "atlas:" .. game_roles .. "/" .. role, true } }
        end
    end

    -- spec id -> { { ref, round }, ... }: the talent-tab icon, then the sheet
    local spec_art = {}
    for id, slug in pairs(cfg.SPEC_ICON) do
        local list = {}
        if assets then list[#list + 1] = { cfg.game_icon(slug), false } end
        if spec_sheet and cfg.SPEC_CELLS[id] then
            list[#list + 1] = { "atlas:" .. spec_sheet .. "/" .. id, false }
        end
        if #list > 0 then spec_art[id] = list end
    end
    if spec_sheet then
        for id in pairs(cfg.SPEC_CELLS) do
            if not spec_art[id] then spec_art[id] = { { "atlas:" .. spec_sheet .. "/" .. id, false } } end
        end
    end

    -- role, spec -> the badge's sources: the role circle, then the spec icon
    local badge_art = {}
    local function badge_art_for(role, spec)
        local key = (role or "") .. ":" .. tostring(spec or "")
        local list = badge_art[key]
        if list then return list end
        list = {}
        local r = role and role_art[role]
        if r then for i = 1, #r do list[#list + 1] = r[i] end end
        local sp = spec and spec_art[spec]
        if sp then for i = 1, #sp do list[#list + 1] = sp[i] end end
        badge_art[key] = list
        return list
    end

    local creature_art = {}
    for id, slug in pairs(cfg.CREATURE_ICON) do
        local list = {}
        if assets then list[#list + 1] = { cfg.game_icon(slug), false } end
        list[#list + 1] = { "icon:" .. slug, false }
        creature_art[id] = list
    end

    -- index -> { { ref, round } }: the client's own raid icon. Transparent
    -- outside the shape, so it needs no mask -- and nothing behind it either.
    --- One art source, or nil where it cannot load: an addon's file needs
    --- the addon installed. { ref, round, tint = color?, uv = {u0,v0,u1,v1}? }
    local function source(ref, round, addon, tint_rgb, uv)
        if not assets then return nil end
        if addon then
            if type(assets.addon_installed) ~= "function" then return nil end
            local ok, installed = pcall(assets.addon_installed, addon)
            if not ok or not installed then return nil end
        end
        return {
            ref, round == true,
            tint = tint_rgb and P.color(tint_rgb[1], tint_rgb[2], tint_rgb[3]) or nil,
            uv = uv,
        }
    end

    -- A texture drawn upside down: Plater's triangle points the other way
    -- from the game's.
    local FLIP = { 0, 1, 1, 0 }

    -- index -> the client's own raid icon, then Plater's marker shape in the
    -- marker's colour: the game's icon is out of the archives, which the game
    -- itself could not read on 2026-10-01, and the shape is an addon file,
    -- which it could.
    local marker_art = {}
    for index, m in pairs(cfg.RAID_MARKERS) do
        local list = {}
        if assets then list[#list + 1] = { cfg.raid_marker_ref(index), true } end
        local shape = m.shape and source("addon:" .. m.shape, true, m.shape:match("^([^/]+)/"),
            m.rgb, m.flip and FLIP or nil)
        if shape then list[#list + 1] = shape end
        if #list > 0 then marker_art[index] = list end
    end

    M.class_art = class_art
    M.role_art = role_art
    M.spec_art = spec_art
    M.creature_art = creature_art
    M.marker_art = marker_art

    -- The game's own UI art (cfg.GAME_UI_SHEETS, cfg.GAME_UI): cropped
    -- sheets registered as atlases, whole files as they are. Known at load,
    -- so every one is resolved in the archive scan that runs at start.
    -- name or "sheet.cell" -> { { ref, round } }
    local game_ui_art = {}
    for name, sheet in pairs(cfg.GAME_UI_SHEETS) do
        local atlas = register_sheet("jambix_ui_" .. name, sheet.ref, sheet.cells, nil)
        if atlas then
            for cell in pairs(sheet.cells) do
                game_ui_art[name .. "." .. cell] = { { "atlas:" .. atlas .. "/" .. cell, true } }
            end
        end
    end
    if assets then
        for name, ref in pairs(cfg.GAME_UI) do game_ui_art[name] = { { ref, true } } end
    end
    -- Then what stands in where the archives cannot be read: addon files and
    -- web icons, which load in the game (cfg.GAME_UI_FALLBACK).
    for key, list in pairs(cfg.GAME_UI_FALLBACK) do
        local art = game_ui_art[key] or {}
        for i = 1, #list do
            local fb = list[i]
            local entry = source(fb[1], true, fb[2], fb.tint)
            if entry then art[#art + 1] = entry end
        end
        if #art > 0 then game_ui_art[key] = art end
    end

    -- gathering kind -> the profession's icon, the archives first
    local node_art = {}
    for kind, slug in pairs(cfg.NODE_ICON) do
        local list = {}
        if assets then list[#list + 1] = { cfg.game_icon(slug), false } end
        list[#list + 1] = { "icon:" .. slug, false }
        node_art[kind] = list
    end

    M.game_ui_art = game_ui_art
    M.node_art = node_art
    M.badge_art_for = badge_art_for
    M.sheets = {
        game_classes = game_classes and cfg.GAME_CLASS_SHEET.ref or nil,
        game_roles = game_roles and cfg.GAME_ROLE_SHEET.ref or nil,
        classes = class_sheet and cfg.CLASS_SHEET.ref or nil,
        specs = spec_sheet_ref,
    }

    --- Whether an asset can be painted now, has failed for good, or is on
    --- its way. An atlas cell fails when its sheet does.
    ---@return "ready"|"failed"|"loading"
    local function art_state(ref)
        if not assets then return "failed" end
        local ready, entry = assets.request(ref)
        if ready then return "ready" end
        if not entry then return "failed" end
        local base = entry.atlas and assets.get(entry.atlas.ref) or entry
        if not base or base.dead or base.state == "failed" then return "failed" end
        return "loading"
    end

    --- The first source that can be painted now. Answers nil while the best
    --- one is still loading, so a portrait never flips from CDN art to the
    --- sheet a frame later; and nil for good when every source has failed.
    ---@param list table
    ---@return string|nil ref
    ---@return boolean round
    ---@return boolean waiting
    local function pick_art(list)
        if not list then return nil, false, false end
        for i = 1, #list do
            local ref = list[i][1]
            local state = art_state(ref)
            if state == "ready" then return ref, list[i][2] == true, false, list[i] end
            if state == "loading" then return nil, false, true end
        end
        return nil, false, false
    end

    M.pick_art = pick_art

    local INV_SQRT2 = 0.70710678

    -- THE NEW LOOK (1.88.0): its constants, this frame's settings and its
    -- helpers, kept in one table because this function is close to Lua's
    -- limit of 200 locals (eleven to spare after this). Each is explained
    -- where it is used.
    local LOOK = {
        shader = true,              -- `esp_shader_look` (read_settings)
        beacon_from = 40,           -- `esp_beacon_from` (read_settings)
        beacon_el = nil,            -- the show_beacon element, for marks off screen
        beacon_height = 10,
        beacon_category = { rare = true, boss = true, quest = true, guide = true },
        node_dim = 0.55,
        node_grey = P.color(150, 150, 150, 200),
        aggro_inner = 0.86,
        node_ring_inner = 0.72,
        clear = P.color(0, 0, 0, 0),
        white = P.color(255, 255, 255),
        tips = setmetatable({}, { __mode = "k" }),
        quests_only_off = {
            show_cast = true, show_aggro = true, show_target_line = true, show_cast_ring = true,
            show_beacon = true,
        },
    }

    -- A node your skill cannot gather yet (1.88.0, esp/collect.lua sets
    -- e.requires): its whole mark dimmed, the label saying what it asks for.
    -- JCore's with_alpha where it has one; a plain grey otherwise.
    function LOOK.dimmed(col)
        if draw.with_alpha then return draw.with_alpha(col, LOOK.node_dim) end
        return LOOK.node_grey
    end

    --- A node's label: its name, and "(Requires Skill N)" when your skill is
    --- short of it.
    function LOOK.node_text(e)
        local name = e.name
        if not name or name == "" then return nil end
        if e.requires then return name .. " (Requires Skill " .. tostring(e.requires) .. ")" end
        return name
    end

    --- The colour an entity is drawn in.
    ---
    --- A category whose colour MEANS something keeps it -- a rare is gold
    --- because it is a rare. For the plain ones the colour is free to answer
    --- something more useful, and which question it answers is the colour
    --- mode: what its reaction to you is, or how dangerous its level is.
    --- Players keep class colours over all of it when that is switched on.
    ---@param e table
    ---@param v table The frame view, carrying the player's level.
    ---@return color
    local function color_for(e, v)
        local base
        if e.kind ~= "unit" then
            base = P.category_color[e.category] or draw.theme.accent
            if e.requires then return LOOK.dimmed(P.faded(base, e.distance, e.range)) end
            return P.faded(base, e.distance, e.range)
        end

        local info = e.info
        base = P.category_color[e.category] or draw.theme.neutral

        if info and info.is_player then
            if P.opt("class_colors", true) and info.class_id then
                base = P.class_color[info.class_id] or base
            end
            return P.faded(base, e.distance, e.range)
        end

        -- Somebody else's tag outranks every other colour, the rare's gold
        -- and the quest's yellow included: no kill credit and no loot is
        -- the one fact about it that changes whether to bother. The game's
        -- own nameplate turns grey for the same reason.
        if info and info.tapped and not e.dead and P.opt("grey_tapped", true) then
            return P.faded(tapped_color, e.distance, e.range)
        end

        local definition = cfg.CATEGORY_BY_KEY[e.category]
        if definition and definition.plain and info then
            local mode = P.opt("unit_color_mode", cfg.COLOR_MODE_REACTION)
            if mode == cfg.COLOR_MODE_REACTION then
                base = reaction_color[info.reaction or "neutral"] or base
            elseif mode == cfg.COLOR_MODE_DIFFICULTY then
                local band = cfg.difficulty_band(info.level, v.player_level)
                base = difficulty_color[band] or base
            end
        end

        return P.faded(base, e.distance, e.range)
    end

    M.color_for = color_for

    local REACTION_TAG = {
        hostile = "hostile",
        neutral = "neutral",
        friendly = "friendly",
    }

    local MAX_NAME = 26

    --- The first line: what the thing is called, and nothing else.
    local function name_text(e)
        local info = e.info
        if not info or not P.opt("show_name", true) then return nil end
        if info.name == "" then return nil end

        local name = info.name
        if #name > MAX_NAME then name = name:sub(1, MAX_NAME - 1) .. "\226\128\166" end

        -- Why it is marked -- quest, guide, loot, skin -- is no longer a word
        -- glued to the front of the name in the name's colour, where it read
        -- as part of the name. It is a chip of its own: see name_row.
        return name
    end

    --- The second line: everything you look for AFTER the name. Dim, small,
    --- and joined with a thin separator so it reads as one row of facts
    --- rather than four competing labels.
    --- Also returns the level, when it is to be drawn in its own colour.
    local function detail_text(e)
        local info = e.info
        if not info then return nil end

        local parts = {}
        local lead = nil

        -- Not on a corpse (1.67.0): whether it can be skinned is decided
        -- already (esp/collect.lua), and that was all its level said.
        if P.opt("show_level", true) and info.level and info.level > 0 and not e.dead then
            parts[#parts + 1] = info.tag
                and (info.level .. " " .. info.tag)
                or tostring(info.level)
            if info.can_attack then lead = tostring(info.level) end
        end

        if P.opt("show_health_text", true) and not e.dead then
            local fraction = units.health_fraction(e.obj)
            -- A full health bar says "full" already. The number is worth the
            -- space only once something has taken a bite out of it.
            if fraction > 0 and fraction < 0.995 then
                if P.opt("show_health_exact", false) then
                    local ok, health = pcall(e.obj.get_health, e.obj)
                    local ok_max, max_health = pcall(e.obj.get_max_health, e.obj)
                    if ok and ok_max and health and max_health and max_health > 0 then
                        parts[#parts + 1] = string.format("%.0f/%.0f", health, max_health)
                    else
                        parts[#parts + 1] = string.format("%.0f%%", fraction * 100)
                    end
                else
                    parts[#parts + 1] = string.format("%.0f%%", fraction * 100)
                end
            end
        end

        if P.opt("show_distance", true) then
            parts[#parts + 1] = string.format("%.0fy", e.distance)
        end

        -- The reaction word is not here: it is a pill of its own, in its own
        -- colour, beside this one (see show_details).

        -- What a tameable beast teaches (1.72.0, modules/tame.lua): its
        -- family and the ranks its level carries; "?" until seen.
        if P.tame and P.opt("show_tame", true) then
            local collect = P.esp_collect
            local t = P.tame.info(e, collect and collect.now or nil)
            if t then parts[#parts + 1] = t.text end
        end

        if #parts == 0 then return nil end
        return table.concat(parts, "  \194\183  "), lead
    end

    -- --- the target's reach -------------------------------------------------
    --
    -- One line under the selected target: line of sight, and whether it is
    -- inside this class's reach. The reach comes from the catalogue where
    -- the class has one (a hunter's 8-35 band plus Hawk Eye); otherwise it
    -- is melee. Words, not icons, because this is read in the moment nothing
    -- is firing and the question is "why".

    local reach_ok = P.color(105, 200, 115)     -- in sight and in range
    local reach_far = P.color(230, 190, 85)     -- in sight, out of range (or too close)
    local reach_blocked = P.color(225, 85, 75)  -- no line of sight

    --- Is this entity the player's selected target?
    local function is_target(e)
        -- The collection pass asked once this frame; a compare per mark
        -- instead of a call into combat (and the client) per mark.
        local collect = P.esp_collect
        if collect and (collect.now or 0) > 0 then
            return e.guid ~= nil and e.guid == collect.target_guid
        end
        local combat = P.combat
        if not combat or type(combat.target) ~= "function" then return false end
        local ok, target = pcall(combat.target)
        if not ok or not target then return false end
        local a, b = units.guid(target), units.guid(e.obj)
        return a ~= nil and a == b
    end

    --- This class's reach: min, max in yards.
    local function class_reach()
        local catalog = P.catalog
        local data = catalog and type(catalog.current) == "function" and catalog.current() or nil
        local band = data and data.ranges and data.ranges.ranged or nil
        if band then
            local hawk = P.talents and type(P.talents.rank) == "function" and P.talents.rank("Hawk Eye") or 0
            return band.min or 8, (band.max or 35) + 2 * (hawk or 0)
        end
        return 0, 5
    end

    --- Line of sight and reach for the target, as two separate answers so
    --- each gets its own pill and its own colour: "LoS" green next to "Out of
    --- Range" amber says both at once, where one line in one colour had to
    --- pick which to tell you.
    ---@param e table
    ---@return boolean|nil sight Nil when the client cannot be asked.
    ---@return string range "In Range", "Out of Range" or "Too Close".
    local function reach_state(e)
        local player = units.player()
        -- JCore's sight, not the client's is_line_of_sight (1.8.1): this row
        -- asked the native every frame at the target, and on Forever build
        -- 70338 that ray asserts in the client (M2HitTest.cpp) -- three of
        -- the four crashes of 2026-10-11 were rays at the selected target.
        -- geometry.sight is model-free there and shared for a fifth of a
        -- second; nil (unknown) shows no LoS pill.
        local geometry = ctx.geometry
        local sight = nil
        if player and geometry and type(geometry.sight) == "function" then
            local ok, yes = pcall(geometry.sight, player, e.obj)
            if ok and yes ~= nil then sight = yes == true end
        end

        local min, max = class_reach()
        local distance = e.distance or units.distance(e.obj)
        -- A yard of slack: the client measures reach to reach, this is
        -- centre to centre.
        local range
        if distance > max + 1 then range = "Out of Range"
        elseif distance < min then range = "Too Close"
        else range = "In Range" end

        return sight, range
    end

    -- --- what it is doing, and to whom --------------------------------------
    --
    -- Worked out ONCE per entity, before any row is drawn, because the stack
    -- is laid out bottom-up from the head and has to know which of the
    -- conditional rows -- the cast bar, the status line -- will exist.

    -- Spell names never change for an id, so one native call per spell for
    -- the session. `false` remembers an id the client could not name.
    local spell_names = {}

    ---@param id integer|nil
    ---@return string|nil
    local function spell_name(id)
        if type(id) ~= "number" or id <= 0 then return nil end
        local name = spell_names[id]
        if name == nil then
            local ok, value = pcall(function() return core.spell_book.get_spell_name(id) end)
            name = (ok and type(value) == "string" and value ~= "") and value or false
            spell_names[id] = name
        end
        return name or nil
    end

    M.spell_name = spell_name

    -- Party members by guid, rebuilt per frame from the roster the group
    -- service already holds for the tick. guid -> name.
    local group_names = {}

    -- One cast at a time is being laid out, so one table serves every
    -- entity; a fresh table per caster per frame is garbage for nothing.
    local cast_view = {}

    --- The cast to draw, or nil. Times are the cast's own start and end on
    --- the game clock, so the bar moves smoothly between detail reads; a
    --- cast whose end has passed is over, whatever the last read said.
    ---@param d table|nil The entity's detail.
    ---@param now_ms number core.game_time(), read once for the frame.
    ---@return table|nil
    local function cast_state(d, now_ms)
        if not d or not d.casting then return nil end
        now_ms = now_ms or 0

        local start, finish = d.cast_start, d.cast_end
        local timed = type(start) == "number" and type(finish) == "number"
            and start > 0 and finish > start
            and (finish - start) <= cfg.CAST_MAX_SECONDS * 1000
        -- A quarter-second of grace: a far unit's detail can be a moment old,
        -- and a bar that blinks out a frame before it fills looks broken.
        if timed and now_ms > finish + 250 then return nil end

        local c = cast_view
        c.spell_id = d.spell_id
        c.name = spell_name(d.spell_id) or (d.channel and "Channelling" or "Casting")
        c.interruptible = d.interruptible == true
        c.channel = d.channel == true
        if timed then
            local t = (now_ms - start) / (finish - start)
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
            -- A channel drains; a cast fills.
            c.fraction = c.channel and (1 - t) or t
            c.remaining = math.max(0, (finish - now_ms) / 1000)
        else
            -- A cast whose clock makes no sense is still a cast: say what it
            -- is, show it full, and do not invent a countdown.
            c.fraction = 1
            c.remaining = nil
        end
        return c
    end

    -- A spell's own icon, through the asset registry: the icon's name from
    -- its cache (or a lookup), the picture from the web icon cache. The
    -- shared icon helper drew nothing at all in the game on 2026-10-01; the
    -- registry's route had already cached icons there.
    local spell_art = {}

    ---@param id integer|nil
    ---@return table|nil
    local function spell_art_for(id)
        if type(id) ~= "number" or id <= 0 or not assets then return nil end
        local list = spell_art[id]
        if not list then
            list = { { "spell:" .. id, false } }
            spell_art[id] = list
        end
        return list
    end

    M.spell_art_for = spell_art_for

    --- Whose fight this is: "me", "pet", "group", or nil.
    ---@param d table|nil
    ---@return string|nil
    local function victim_of(d)
        if not d then return nil end
        if d.targeting_me then return "me" end
        if d.targeting_pet then return "pet" end
        if d.target_guid and group_names[d.target_guid] then return "group" end
        return nil
    end

    --- One line about what it is doing, coloured by the most urgent thing it
    --- says, or nil when there is nothing worth a row.
    ---
    --- Crowd control comes first even over "on you": a sheeped mob is not
    --- attacking anyone, and the thing to know about it is how long until it
    --- is, and not to hit it before then.
    ---@param e table
    ---@param d table|nil
    ---@return string|nil text
    ---@return table|nil color
    local function status_for(e, d)
        local info = e.info
        if d then
            local control = d.control
            if control and (control.remaining or 0) > 0 then
                -- With the crowd control's own spell icon beside it.
                return string.format("%s %.0fs", spell_name(control.spell_id) or "controlled",
                    control.remaining), status_color.control, nil, control.spell_id
            end
            -- The combat swords go on every line of a unit that is fighting,
            -- not only on a plain "in combat": the mobs you fight show "on
            -- you", and a swords icon that skipped them was almost never seen.
            local swords = d.in_combat and game_ui_art["state.combat"] or nil
            if d.targeting_me then return "on you", status_color.me, swords end
            if d.targeting_pet then return "on your pet", status_color.group, swords end
            local who = d.target_guid and group_names[d.target_guid]
            if who then
                return who ~= "" and ("on " .. who) or "on your group", status_color.group, swords
            end
        end
        if info.tapped then return "tapped", status_color.tapped end
        -- The crossed swords the game shows by your own portrait in combat.
        if d and d.in_combat then return "in combat", status_color.quiet, game_ui_art["state.combat"] end
        if info.mounted then return "mounted", status_color.quiet end
        return nil, nil
    end

    -- --- where you stand on its threat table -------------------------------
    --
    -- JCore's threat service ranks the whole group on every mob in the fight,
    -- the way Tiny Threat ranks it for the target. Reading a board is a table
    -- lookup; the natives were spent by the service, on its own budget.

    local threat_service = ctx.threat

    -- Whether you are the one who is MEANT to hold it. The same three tiers
    -- the role badge uses -- the group role, the spec, a stance or form that
    -- only a tank uses -- so a warrior in Defensive Stance or a druid in
    -- Bear Form is a tank without a setting saying so. An aura read, so it is
    -- remembered for a couple of seconds.
    local tank_check = { at = -math.huge, yes = false, class_id = nil }
    local TANK_EVERY = 2.0

    local function i_am_tank()
        local collect = P.esp_collect
        local now = (collect and (collect.now or 0) > 0) and collect.now or core.time()
        if (now - tank_check.at) < TANK_EVERY then return tank_check.yes end
        tank_check.at = now
        tank_check.yes = false
        local player = units.player()
        if not player or not P.esp_roles then return false end
        if not tank_check.class_id then
            local ok, id = pcall(player.get_class, player)
            if ok and type(id) == "number" then tank_check.class_id = id end
        end
        local ok, role = pcall(P.esp_roles.role, player,
            { is_player = true, class_id = tank_check.class_id })
        tank_check.yes = ok and role == P.esp_roles.TANK
        return tank_check.yes
    end

    local function threat_band(percent)
        if percent >= cfg.THREAT_PULLING then return threat_color.pulling end
        if percent >= cfg.THREAT_CLOSE then return threat_color.close end
        return threat_color.safe
    end

    --- The threat row and its colour, or nil for a mob the group is not
    --- fighting. Solo too: "aggro, #1 of 1" on what is hitting you, and your
    --- rank behind your pet on what it holds.
    ---@param e table
    ---@return string|nil text
    ---@return table|nil color
    local function threat_for(e)
        if not threat_service or not threat_service.get then return nil, nil end
        local board = threat_service.get(e.guid)
        if not board then return nil, nil end
        local me = board.me
        if not me then
            -- In the group's fight, none of it yours yet. Said rather than
            -- left blank: a mob you have not touched is visibly safe, and
            -- who holds it is worth knowing in a pack.
            local tank = board.tank
            local name = tank and tank.name or ""
            if name ~= "" then
                if #name > 14 then name = name:sub(1, 13) .. "\226\128\166" end
                return string.format("threat 0%%  \194\183  tank %s", name), threat_color.safe, board.count
            end
            return "threat 0%", threat_color.safe, board.count
        end

        if me.tanking then
            local text
            if board.next_percent then
                text = string.format("aggro  \194\183  #%d of %d  \194\183  next %.0f%%",
                    me.rank, board.count, board.next_percent)
            else
                text = string.format("aggro  \194\183  #%d of %d", me.rank, board.count)
            end
            -- Holding it is the job for a tank, and the only possibility
            -- solo with no pet. Anyone else holding it -- a mage in a party,
            -- a hunter whose pet should have it -- is the alarm.
            local company = threat_service.company and threat_service.company() or nil
            local alone = company ~= nil and company.players == 0 and not company.pet
            if i_am_tank() or alone then return text, threat_band(board.next_percent or 0), board.count end
            return text, threat_color.pulling, board.count
        end

        return string.format("threat %.0f%%  \194\183  #%d of %d", me.percent, me.rank, board.count),
            threat_band(me.percent), board.count
    end

    M.threat_for = threat_for

    -- --- drawers ------------------------------------------------------------

    local DRAWERS = {}

    -- The stack is drawn top down from one cursor, and each drawer moves the
    -- cursor on by exactly what it used. That is why the elements are ordered
    -- in config the way they are read: name, bar, details, quests.
    local ROW_GAP = 2

    -- The rows that can move under the feet (config `below`), filled once
    -- the drawers are resolved at the bottom of this file. ROWS is in config
    -- order, for the stack above the head; BELOW is in `below` order.
    local ROWS, BELOW = {}, {}
    -- Every resolved element, in config order (filled at the bottom of this
    -- file), and the list drawn under the feet when a nameplate covers the
    -- head: the mark's own rows first, then the information rows.
    local ACTIVE, COVERED = {}, {}
    -- What a mark off screen still draws: the line from an attacker you
    -- cannot see to you, whose near end is on screen. A ring at its feet or
    -- a box round it would be culled anyway. And the pillar of light (1.88.0,
    -- LOOK.beacon_el), which is drawn while its top shows, foot or no foot.
    local OFFSCREEN = {}

    -- The rows that make up the mark above the head, which move under the
    -- feet with everything else while a nameplate covers it.
    local TOP_KEYS = {
        show_raid_marker = true, show_class_icon = true, show_creature_icon = true,
        show_label = true, show_bar = true, show_power = true,
    }

    -- Forward declarations: the frame clock lives on the view (built further
    -- down) and the mana test is needed by the layout above its definition.
    local view_now
    local power_shown
    local quest_line

    -- The rows a crowded block is cut down to. See "declutter".
    local URGENT_ROWS = { show_cast = true, show_reach = true, show_status = true, show_threat = true }

    --- Does this element draw for this entity at this tier?
    --- The toggle is read once a frame into el.on (begin_frame): this runs
    --- for every element of every mark, two or three times over, and a P.opt
    --- for each was thousands of reads a frame for twenty answers.
    local function applies(el, e, tier)
        if not (el.kind == e.kind or el.kind == "any") or tier < el.tier then return false end
        local on = el.on
        if on == nil then on = P.opt(el.key, el.default) end
        return on and true or false
    end

    --- Whether a row survives the cut to what cannot wait -- by what it says,
    --- not only by which row it is. "In combat", "tapped" and "threat 0%" are
    --- status and threat rows too, and in a group pull every mob not on you
    --- said one of them: a cut block was a column of the same grey pill.
    local function is_urgent(el, v)
        local key = el.key
        if key == "show_status" then return v.status_urgent == true end
        if key == "show_threat" then return v.threat_urgent == true end
        return URGENT_ROWS[key] == true
    end

    -- Drawn in the world rather than in the stack: they take no room in it.
    local GROUND_KEYS = {
        show_box = true, show_aggro = true, show_target_line = true, show_tracer = true, node_ring = true,
        show_cast_ring = true, show_beacon = true,
    }
    -- What a crowded stack above the head is cut down to: who it is.
    local TOP_CUT_KEYS = { show_raid_marker = true, show_label = true, node_label = true }

    -- --- pills ----------------------------------------------------------------
    --
    -- THE INFORMATION ROWS ARE PILLS: full-size bright text on a dark rounded
    -- backdrop, bordered in the row's own colour where the colour carries the
    -- answer (red "on you", green "LoS"). Small dim text over bare ground was
    -- seen on 2026-09-30 to be unreadable over the red sand of Durotar -- the
    -- level, distance and line-of-sight rows were there and could not be read.
    -- A backdrop is legible over sand, snow and lava alike.
    --
    -- NOTHING TEXTURED SITS ON A PILL. Textures paint beneath every shape, so
    -- the cast bar's spell icon goes beside its pill, never inside it.
    --
    -- CARDS (1.88.0). With `esp_shader_look` on and a JCore that has
    -- plate_2d, a pill is a soft plate with a soft shadow under it, in the
    -- same colour, rounding and outline. The shadow reaches a few pixels past
    -- the plate and is a shape too, so a pill with an icon beside it, and a
    -- chip, go without one: the icon would sit under it. Off, or on an older
    -- JCore, the two flat rectangles it always was.

    local pill_back = P.color(12, 12, 16, 220)
    local pill_text = P.color(240, 240, 245)
    local PILL_PAD_X, PILL_PAD_Y, PILL_GAP = 6, 2, 4

    --- A pill's or a chip's backdrop, outlined in `border` when there is one.
    ---@param shadow boolean|nil false for none (an icon beside it)
    function LOOK.backdrop(x, y, w, h, border, layer, droppable, shadow)
        if LOOK.shader and draw.plate_2d then
            draw.plate_2d({ x = x, y = y }, w, h, pill_back, {
                rounding = 3, border = border or nil, shadow = shadow,
                layer = layer, droppable = droppable,
            })
            return
        end
        draw.rect_2d({ x = x, y = y }, w, h, pill_back,
            { filled = true, rounding = 3, layer = layer, droppable = droppable })
        if border then
            draw.rect_2d({ x = x, y = y }, w, h, border,
                { thickness = 1.2, rounding = 3, layer = layer, droppable = droppable })
        end
    end

    -- Text width without a native call per string. The rows are rebuilt
    -- every frame -- a distance ticks, a cast counts down -- and measuring
    -- each new string would be a round trip per row per frame, churning the
    -- draw service's measure cache besides. So each GLYPH is measured once
    -- per size, for the session, and a string is the sum of its glyphs: exact
    -- for a font with no kerning, and inside the pill's padding for one with.
    local glyph_w = {}
    local GLYPH = "[\1-\127\194-\244][\128-\191]*"

    ---@param text string
    ---@param size number
    ---@return number
    local function text_width(text, size)
        local measure = draw.measure
        local width = 0
        if not measure then
            for _ in text:gmatch(GLYPH) do width = width + size * 0.5 end
            return width
        end
        local cache = glyph_w[size]
        if not cache then
            cache = {}
            glyph_w[size] = cache
        end
        for ch in text:gmatch(GLYPH) do
            local g = cache[ch]
            if not g then
                g = measure(ch, size) or size * 0.5
                cache[ch] = g
            end
            width = width + g
        end
        return width
    end

    M.text_width = text_width

    -- A row's pills are queued here and drawn together, so they can be
    -- centred as a group. Scratch arrays, reused: a row per mark per frame
    -- would otherwise be a table per mark per frame.
    local seg_text, seg_col, seg_border, seg_w = {}, {}, {}, {}
    local seg_lead, seg_lead_col = {}, {}
    local seg_n = 0

    ---@param text string
    ---@param col table
    ---@param border table|nil Outline colour, or nil for none.
    ---@param lead string|nil The start of `text`, drawn in `lead_col` (a level, 1.67.0).
    ---@param lead_col table|nil
    local function seg(text, col, border, lead, lead_col)
        if lead and lead_col and lead == text then col = lead_col end
        seg_n = seg_n + 1
        seg_text[seg_n], seg_col[seg_n], seg_border[seg_n] = text, col, border or false
        local split = lead and lead_col and #lead < #text and text:sub(1, #lead) == lead
        seg_lead[seg_n], seg_lead_col[seg_n] = split and lead or false, split and lead_col or false
    end

    local function pill_h(v)
        return v.size + PILL_PAD_Y * 2
    end

    --- Draws the queued pills as one row, centred on the anchor, at the
    --- cursor, and moves the cursor past it.
    ---@param icon_beside? boolean An icon goes left of the row: no shadow.
    ---@return number|nil left
    ---@return number width
    ---@return number height
    local function pill_row(e, v, icon_beside)
        local n = seg_n
        seg_n = 0
        if n == 0 or not v.anchor then return nil, 0, 0 end

        local size = v.size
        local h = pill_h(v)
        local total = PILL_GAP * (n - 1)
        for i = 1, n do
            local w = text_width(seg_text[i], size) + PILL_PAD_X * 2
            seg_w[i] = w
            total = total + w
        end

        local left = v.anchor.x - total * 0.5
        local x, y = left, v.cursor
        local layer, droppable = v.overlay_layer, v.droppable
        local shadow = nil
        if icon_beside then shadow = false end
        for i = 1, n do
            local w = seg_w[i]
            LOOK.backdrop(x, y, w, h, seg_border[i], layer, droppable, shadow)
            -- Centred in its pill, so a width estimate a pixel out shows as
            -- padding, never as text running over the edge. A lead and the
            -- rest are each centred in their own share.
            local lead = seg_lead[i]
            if lead then
                local lead_w = text_width(lead, size)
                local rest = seg_text[i]:sub(#lead + 1)
                local rest_w = w - PILL_PAD_X * 2 - lead_w
                draw.unit_label(e.obj, lead, seg_lead_col[i], {
                    at = { x = x + PILL_PAD_X + lead_w * 0.5, y = y + PILL_PAD_Y },
                    layer = layer, size = size, shadow = true, droppable = droppable,
                })
                draw.unit_label(e.obj, rest, seg_col[i], {
                    at = { x = x + PILL_PAD_X + lead_w + rest_w * 0.5, y = y + PILL_PAD_Y },
                    layer = layer, size = size, shadow = true, droppable = droppable,
                })
            else
                draw.unit_label(e.obj, seg_text[i], seg_col[i], {
                    at = { x = x + w * 0.5, y = y + PILL_PAD_Y },
                    layer = layer, size = size, shadow = true, droppable = droppable,
                })
            end
            x = x + w + PILL_GAP
        end

        v.cursor = v.cursor + h + ROW_GAP
        return left, total, h
    end

    -- --- tags ---------------------------------------------------------------
    --
    -- Why a thing is marked, as chips in front of its name: KILL, COLLECT,
    -- USE, PICK UP, TURN IN in quest yellow, GUIDE in RestedXP blue, LOOT in
    -- green, SKIN in brown -- each outlined on its own dark pill, with the
    -- icon its addon uses beside it. See cfg.TAGS.
    --
    -- The icon sits to the LEFT of its chip, never on it: textures paint
    -- beneath every shape, so an icon on the pill's backdrop would vanish.

    local tag_color = {}
    for family, rgb in pairs(cfg.TAG_RGB) do
        tag_color[family] = P.color(rgb[1], rgb[2], rgb[3])
    end

    -- tag -> { { ref, round } }, only the sources that can load here: an
    -- addon's icon is dropped when the addon is not installed, rather than
    -- probed for and failed on.
    local tag_art = {}
    for key, tag in pairs(cfg.TAGS) do
        local list = {}
        for i = 1, #tag.art do
            local ref, addon = tag.art[i][1], tag.art[i][2]
            local usable = assets ~= nil
            if usable and addon then
                usable = type(assets.addon_installed) == "function"
                    and select(2, pcall(assets.addon_installed, addon)) == true
            end
            if usable then list[#list + 1] = { ref, true } end
        end
        tag_art[key] = list
    end

    M.tag_color = tag_color
    M.tag_art = tag_art

    local QUEST_RANK = {}
    for i = 1, #cfg.QUEST_TAG_ORDER do QUEST_RANK[cfg.QUEST_TAG_ORDER[i]] = i end

    --- The one quest chip for a mark: the most pressing thing to do there
    --- across every quest that wants it.
    ---@param entries table[]|nil
    ---@return string
    local function quest_tag(entries)
        local best, best_rank = "quest", QUEST_RANK.quest
        if entries then
            for i = 1, #entries do
                local entry = entries[i]
                local tag = entry.tag
                    or (entry.turn_in and "turn_in")
                    or (entry.pick_up and "pick_up")
                    or "quest"
                local rank = QUEST_RANK[tag] or QUEST_RANK.quest
                if rank < best_rank then best, best_rank = tag, rank end
            end
        end
        return best
    end

    M.quest_tag = quest_tag

    --- Fills v.tags / v.tag_n for an entity: at most two chips.
    local function resolve_tags(e, v)
        local tags, n = v.tags, 0
        if P.opt("show_tags", true) then
            local category = e.category
            if category == "corpse" then
                local loot, skin = e.lootable, e.skinnable
                if not loot and not skin then
                    -- A corpse entity from before the flags existed: its
                    -- badge still says which one it was.
                    skin = e.badge == "[skin]"
                    loot = not skin
                end
                if loot then n = n + 1; tags[n] = "loot" end
                if skin then n = n + 1; tags[n] = "skin" end
            elseif category == "guide" then
                n = n + 1; tags[n] = "guide"
                -- The guide wants it AND a quest does: say what the quest
                -- wants too, because that is what you will be doing.
                if e.quest_entries then n = n + 1; tags[n] = quest_tag(e.quest_entries) end
            elseif category == "quest" then
                n = n + 1; tags[n] = quest_tag(e.quest_entries)
            end
            -- A beast a hunter can tame now (1.72.0, modules/tame.lua).
            if n < 2 and e.kind == "unit" and P.tame and P.opt("show_tame", true) then
                local t = P.tame.info(e, v.now)
                if t and t.can_now then n = n + 1; tags[n] = "tame" end
            end
        end
        v.tag_n = n
    end

    local TAG_GAP, ICON_GAP = 4, 2
    local tag_ref, tag_w = {}, {}

    local function chip_size(v) return math.max(9, v.size - 2) end
    local function chip_h(v) return chip_size(v) + PILL_PAD_Y * 2 end

    -- --- the badge in front of the name ------------------------------------
    --
    -- One picture out of the game's own UI, before the chips and the name,
    -- saying the thing the game itself would show: the target frame's skull
    -- for a boss, a ?? or anything ten levels above you; the nameplate's
    -- gold dragon for an elite; the PvP emblem of a hostile player's faction;
    -- the gathering profession's icon over a node. One at most, danger first.

    --- The badge's art for this mark, or nil.
    local function lead_art_for(e, v)
        if not P.opt("show_badges", true) then return nil end
        if e.kind ~= "unit" then return node_art[e.category] end
        local info = e.info
        if not info or e.dead then return nil end
        local level = type(info.level) == "number" and info.level or 0
        local mine = type(v.player_level) == "number" and v.player_level or 0
        if info.classification == cfg.CLASS_WORLD_BOSS or level < 0
            or (mine > 0 and level >= mine + 10) then
            return game_ui_art.skull
        end
        if info.classification == cfg.CLASS_ELITE or info.classification == cfg.CLASS_RARE_ELITE then
            return game_ui_art["elite.dragon"]
        end
        if info.is_player and info.hostile then
            local side = cfg.RACE_FACTION[info.race_id]
            return side and game_ui_art[side .. ".emblem"] or nil
        end
        return nil
    end

    M.lead_art_for = lead_art_for

    local function lead_size(v) return v.size + 4 end

    --- The name row's height: the name, or the chips or the badge where
    --- they are taller.
    local function name_row_h(v)
        local h = v.size
        if v.tag_n > 0 then h = math.max(h, chip_h(v)) end
        if v.lead_ref then h = math.max(h, lead_size(v)) end
        return h + ROW_GAP
    end

    --- The name row: [icon][CHIP] [icon][CHIP]  Name, centred as one group
    --- on the anchor. With no tags it is the name alone, exactly as before.
    ---@param text string|nil The name, or nil to draw the chips alone.
    local function name_row(e, v, text, col)
        local n = v.tag_n
        local layer, droppable = v.overlay_layer, v.droppable
        local lead = v.lead_ref

        if n == 0 and not lead then
            if not text then return end
            v.name_w = text_width(text, v.size)
            draw.unit_label(e.obj, text, col, {
                at = { x = v.anchor.x, y = v.cursor },
                layer = layer, size = v.size, shadow = true, droppable = droppable,
            })
            v.cursor = v.cursor + v.size + ROW_GAP
            return
        end

        local csize, ch = chip_size(v), chip_h(v)
        local ls = lead and lead_size(v) or 0
        local row_h = math.max(v.size, n > 0 and ch or 0, ls)

        local total = lead and (ls + ICON_GAP + 2) or 0
        for i = 1, n do
            local key = v.tags[i]
            local ref = pick_art(tag_art[key])
            tag_ref[i] = ref or false
            tag_w[i] = text_width(cfg.TAGS[key].word, csize) + PILL_PAD_X * 2
            total = total + (ref and (ch + ICON_GAP) or 0) + tag_w[i]
            if i < n then total = total + TAG_GAP end
        end
        local name_w = text and text_width(text, v.size) or 0
        if text then
            if n > 0 then total = total + TAG_GAP + 2 end
            total = total + name_w
        end

        v.name_w = total
        local x = v.anchor.x - total * 0.5
        local top = v.cursor
        local chip_top = top + (row_h - ch) * 0.5

        -- The badge first, beside everything and on nothing: a texture under
        -- a chip's backdrop would vanish beneath it.
        if lead then
            local entry = v.lead_entry
            draw.image(lead, { x = x, y = top + (row_h - ls) * 0.5 }, ls, ls,
                entry and entry.tint or nil,
                { layer = layer, droppable = droppable, uv = entry and entry.uv or nil })
            x = x + ls + ICON_GAP + 2
        end

        for i = 1, n do
            local tag = cfg.TAGS[v.tags[i]]
            local tcol = tag_color[tag.family]
            if tag_ref[i] then
                draw.image(tag_ref[i], { x = x, y = chip_top }, ch, ch, nil,
                    { layer = layer, droppable = droppable })
                x = x + ch + ICON_GAP
            end
            local w = tag_w[i]
            LOOK.backdrop(x, chip_top, w, ch, tcol, layer, droppable, false)
            draw.unit_label(e.obj, tag.word, tcol, {
                at = { x = x + w * 0.5, y = chip_top + PILL_PAD_Y },
                layer = layer, size = csize, shadow = true, droppable = droppable,
            })
            x = x + w + TAG_GAP
        end

        if text then
            if n > 0 then x = x + 2 end
            draw.unit_label(e.obj, text, col, {
                at = { x = x + name_w * 0.5, y = top + (row_h - v.size) * 0.5 },
                layer = layer, size = v.size, shadow = true, droppable = droppable,
            })
        end
        v.cursor = v.cursor + row_h + ROW_GAP
    end

    -- --- mana ---------------------------------------------------------------
    --
    -- Two native calls a read, so rationed and cached like the detail reads:
    -- a few a frame, each answer kept a third of a second. Only asked of a
    -- unit that can have mana at all -- a player, or an NPC the classifier
    -- found a mana pool on -- and a unit with none is not asked again for a
    -- while.

    local mana_type = (P.enums and P.enums.power_type and P.enums.power_type.MANA) or 0
    local mana_color = P.color(70, 135, 240)
    local power_cache = {}
    local power_reads = 0
    local POWER_TTL, POWER_NONE_TTL, POWER_BUDGET = 0.3, 5.0, 12

    if ctx.on then
        ctx.on("jcore.unit.removed", function(guid) power_cache[guid] = nil end)
        ctx.on("jcore.zone.changed", function() power_cache = {} end)
    end

    --- The unit's mana, { cur, max, frac }, or nil for none.
    local function mana_of(e)
        local info = e.info
        if not info or e.dead or not e.guid then return nil end
        if not info.is_player and info.caster ~= true then return nil end

        local c = power_cache[e.guid]
        local now = view_now()
        if c and (now - c.at) < (c.max > 0 and POWER_TTL or POWER_NONE_TTL) then
            return c.max > 0 and c or nil
        end
        if power_reads <= 0 then return c and c.max > 0 and c or nil end
        power_reads = power_reads - 1

        c = c or {}
        power_cache[e.guid] = c
        local ok, cur = pcall(e.obj.get_power, e.obj, mana_type)
        local ok_max, max = pcall(e.obj.get_max_power, e.obj, mana_type)
        c.at = now
        c.cur = (ok and type(cur) == "number") and cur or 0
        c.max = (ok_max and type(max) == "number") and max or 0
        c.frac = c.max > 0 and math.min(1, math.max(0, c.cur / c.max)) or 0
        return c.max > 0 and c or nil
    end

    local function mana_bar_h()
        return math.max(2, P.opt("bar_height", 4) - 1)
    end

    --- Whether the mana bar draws: like the health bar, when it has
    --- something to say -- not full -- or always, with "even when full".
    power_shown = function(v)
        local p = v.power
        return p ~= nil and (p.frac < 0.995 or P.opt("bar_always", false))
    end

    -- --- nameplates ---------------------------------------------------------
    --
    -- A nameplate addon draws its plate where the game hangs the name, which
    -- is where this stack hangs too. get_nameplate says where the plate is,
    -- so the stack sits ON TOP of it instead of behind it.
    --
    -- Read a few units a frame and kept a fifth of a second -- but kept as an
    -- OFFSET from the head anchor, not as a position, because the plate and
    -- the head move together when the camera does, and the head is projected
    -- fresh every frame.
    --
    -- THE RECTANGLE'S UNITS. The contract says "scaled screen pixels" with a
    -- bottom-left origin. Whether that means pixels or UI units before the
    -- UI scale is not something the stub settles, so both are tried and the
    -- one whose centre lands on the unit's own head is believed.

    local plate_cache = {}
    local plate_reads = 0
    local PLATE_TTL, PLATE_BUDGET = 0.2, 12
    local ui_scale, ui_scale_at = 1, -1e9

    if ctx.on then
        ctx.on("jcore.unit.removed", function(guid) plate_cache[guid] = nil end)
        ctx.on("jcore.zone.changed", function() plate_cache = {} end)
    end

    --- The overlay y of the top of this unit's nameplate, or nil when no
    --- plate is showing.
    --- Diagnostics for the Debug page and the log: what the client answers.
    local plate_diag = { asked = 0, shown = 0, accepted = 0, tokens = 0, logged = false }
    M.plate_diag = plate_diag

    ---@return number|nil top The overlay y of the plate's top edge, when known.
    ---@return boolean up Whether the client says a plate is showing at all.
    local function plate_top(e, anchor)
        local guid = e.guid
        if not guid or not anchor then return nil, false end

        local c = plate_cache[guid]
        local now = view_now()
        if not c or (now - c.at) >= PLATE_TTL then
            if plate_reads <= 0 then
                if not c then return nil, false end
                return c.shown and (anchor.y + c.off) or nil, c.up == true
            end
            plate_reads = plate_reads - 1
            c = c or {}
            plate_cache[guid] = c
            c.at = now
            c.shown = false
            c.up = false

            plate_diag.asked = plate_diag.asked + 1
            local ok, plate = pcall(e.obj.get_nameplate, e.obj)
            if ok and type(plate) == "table" and plate.is_shown then
                c.up = true
                plate_diag.shown = plate_diag.shown + 1
            end
            if ok and type(plate) == "table" and plate.is_shown
                and type(plate.left) == "number" and type(plate.bottom) == "number" then
                local _, screen_h = draw.screen_size()
                local w, h = plate.width or 0, plate.height or 0
                local best_k, best_d = 1, math.abs((plate.left + w * 0.5) - anchor.x)
                if ui_scale > 0 and ui_scale ~= 1 then
                    local d = math.abs((plate.left + w * 0.5) * ui_scale - anchor.x)
                    if d < best_d then best_k, best_d = ui_scale, d end
                end
                -- A plate whose centre is nowhere near the head is not this
                -- unit's, or the arithmetic is wrong: either way, ignore it.
                local accepted = screen_h and screen_h > 0 and best_d <= math.max(40, w * best_k)
                if accepted then
                    c.off = (screen_h - (plate.bottom + h) * best_k) - anchor.y
                    c.shown = true
                    plate_diag.accepted = plate_diag.accepted + 1
                end
                -- Once a session, the raw answer and what was made of it:
                -- the contract leaves the rectangle's units open, and this
                -- line in the log is how a wrong guess gets seen.
                if not plate_diag.logged then
                    plate_diag.logged = true
                    P.log.fmt("info",
                        "nameplate: left %.1f bottom %.1f w %.1f h %.1f, ui scale %.2f, head x %.0f, screen h %.0f -> scale %.2f, off by %.0fpx, %s",
                        plate.left, plate.bottom, w, h, ui_scale, anchor.x, screen_h or 0,
                        best_k, best_d, accepted and "used" or "ignored")
                end
            end
        end
        return c.shown and (anchor.y + c.off) or nil, c.up == true
    end

    -- --- nameplate tokens ---------------------------------------------------
    --
    -- The second way to know a plate is up, independent of get_nameplate:
    -- the client gives every unit with a plate a token, "nameplate1" upward,
    -- and get_object_from_guid resolves a token to its unit. A few tokens a
    -- frame, round-robin, and a unit seen wearing one recently has a plate.

    local PLATE_TOKENS = {}
    for i = 1, 40 do PLATE_TOKENS[i] = "nameplate" .. i end
    local plated = {}
    local plate_scan = 0
    local PLATE_SCAN_PER_FRAME, PLATED_TTL = 5, 0.6
    local plated_pruned_at = -1e9

    if ctx.on then
        ctx.on("jcore.unit.removed", function(guid) plated[guid] = nil end)
        ctx.on("jcore.zone.changed", function() plated = {} end)
    end

    local function scan_plate_tokens(now)
        local om = type(core) == "table" and core.object_manager or nil
        local resolve = om and om.get_object_from_guid
        if type(resolve) ~= "function" then return end
        for _ = 1, PLATE_SCAN_PER_FRAME do
            plate_scan = plate_scan % #PLATE_TOKENS + 1
            local ok, obj = pcall(resolve, PLATE_TOKENS[plate_scan])
            if ok and obj then
                local guid = units.guid(obj)
                if guid then plated[guid] = now end
            end
        end
        if (now - plated_pruned_at) > 2.0 then
            plated_pruned_at = now
            local n = 0
            for guid, at in pairs(plated) do
                if (now - at) > PLATED_TTL then plated[guid] = nil else n = n + 1 end
            end
            plate_diag.tokens = n
        end
    end

    local function has_plate_token(guid)
        local at = guid and plated[guid]
        return at ~= nil and (view_now() - at) < PLATED_TTL
    end

    -- --- layout -------------------------------------------------------------

    --- The raid icon's side, in pixels: a little taller than a name, so it
    --- reads as an icon and not as a letter.
    local function marker_size(v)
        return math.max(12, v.size + 4)
    end

    --- How tall one of the pill rows will be for this entity, or 0 when it
    --- has nothing to say. Each is counted only when it will draw: a mob
    --- that starts casting grows its block by the cast bar and shrinks back
    --- when it stops, which is a movement the eye is meant to catch -- unlike
    --- a gap reserved under every mob in the zone for a cast that never comes.
    local function row_height(key, e, v)
        if key == "show_raid_marker" then
            return (e.info and e.info.marker and not e.dead) and (marker_size(v) + ROW_GAP) or 0
        elseif key == "show_class_icon" then
            local info = e.info
            return (info and info.is_player and info.class_id ~= nil and not e.dead)
                and (P.opt("class_icon_size", 22) + ROW_GAP + 2) or 0
        elseif key == "show_creature_icon" then
            local info = e.info
            return (info and not info.is_player and not e.dead)
                and (P.opt("class_icon_size", 22) + ROW_GAP + 2) or 0
        elseif key == "show_label" then
            -- With a nameplate showing, the plate has the name (v.defer):
            -- the chips stay, the duplicate goes.
            -- name_text, not the raw name: with "Name" switched off the row
            -- reserved its height anyway, a gap above every head.
            return ((not v.defer and name_text(e) ~= nil) or v.tag_n > 0)
                and name_row_h(v) or 0
        elseif key == "show_bar" then
            return (not e.dead and not v.defer) and (P.opt("bar_height", 4) + ROW_GAP + 1) or 0
        elseif key == "show_power" then
            return power_shown(v) and (mana_bar_h() + ROW_GAP + 1) or 0
        elseif key == "node_label" then
            if not e.name or e.name == "" then return 0 end
            local h = name_row_h(v)
            if P.opt("show_distance", true) then h = h + math.max(9, v.size - 3) + ROW_GAP end
            return h
        elseif key == "show_cast" then
            if not v.cast then return 0 end
            return pill_h(v) + 1 + P.opt("bar_height", 4) + ROW_GAP + 1
        elseif key == "show_details" then
            return (v.details_text or v.reaction_word or v.fight_word) and (pill_h(v) + ROW_GAP) or 0
        elseif key == "show_status" then
            return v.status_text and (pill_h(v) + ROW_GAP) or 0
        elseif key == "show_threat" then
            return v.threat_text and (pill_h(v) + ROW_GAP) or 0
        elseif key == "show_reach" then
            return v.is_target and (pill_h(v) + ROW_GAP) or 0
        elseif key == "show_quest_tag" then
            local entries = e.quest_entries
            local lines = (entries and math.min(#entries, 3) or 0) + (e.guide_goal and 1 or 0)
            return lines * (pill_h(v) + ROW_GAP)
        end
        return 0
    end

    --- Whether a row goes under the feet for this entity.
    local function goes_below(el, e, v)
        if e.kind ~= "unit" then return false end
        if v.covered then return el.below ~= nil or TOP_KEYS[el.key] == true end
        return v.rows_below and el.below ~= nil
    end

    --- The rows drawn under the feet, in order.
    local function below_list(v)
        return v.covered and COVERED or BELOW
    end

    --- How tall the stack ABOVE the head is about to be, so it can be placed
    --- above the head rather than growing down across the model.
    ---
    --- Measured from the toggles rather than from what actually drew, because
    --- the rows have to be positioned before any of them runs. The one thing
    --- it cannot know is whether the health bar will find something to say --
    --- a bar is skipped at full health -- so a healthy unit's stack sits a few
    --- pixels higher than it strictly needs to. That is invisible; a stack
    --- that jumped down the moment a mob took a hit would not be.
    ---@param e table
    ---@param v table
    ---@param tier integer
    ---@return number
    --- Whether an element draws in the pass above the head: not one of the
    --- rows under the feet, switched on, and -- when a crowd has cut the
    --- stack (v.top_cut) -- one the cut keeps. Ground marks are never cut.
    local function in_top_pass(el, e, v, tier)
        if goes_below(el, e, v) or not applies(el, e, tier) then return false end
        local cut = v.top_cut
        if not cut or GROUND_KEYS[el.key] then return true end
        return cut == "name" and TOP_CUT_KEYS[el.key] == true
    end

    local function stack_height(e, v, tier)
        local height = 0
        for i = 1, #ACTIVE do
            local el = ACTIVE[i]
            if in_top_pass(el, e, v, tier) then
                height = height + row_height(el.key, e, v)
            end
        end
        return height
    end

    --- How tall the block UNDER THE FEET will be, so it can be kept on
    --- screen when the feet are near the bottom edge.
    local function below_height(e, v, tier)
        local height = 0
        local list = below_list(v)
        for i = 1, #list do
            local el = list[i]
            if applies(el, e, tier) and not (v.compact and not is_urgent(el, v)) then
                height = height + row_height(el.key, e, v)
            end
        end
        return height
    end

    --- Health bar colour: green through amber to red as it empties.
    ---
    --- Deliberately NOT the mark's own colour. The mark's colour answers "what
    --- is this"; a bar that is also that colour answers nothing, and the one
    --- thing a bar is for is showing at a glance that something is nearly
    --- dead.
    local bar_full = P.color(105, 200, 115)
    local bar_mid = P.color(230, 190, 85)
    local bar_low = P.color(225, 85, 75)

    local function health_color(fraction)
        if fraction > 0.6 then return bar_full end
        if fraction > 0.3 then return bar_mid end
        return bar_low
    end

    -- THE CURTAIN BOX (1.88.0, cfg.BOX_CURTAIN, the default): a short
    -- curtain round the unit in its colour, fading to nearly clear at the
    -- top, with a faint sheet between its rings. Sized to the model's reach
    -- like the aggro ring. Without JCore's curtain_3d, the corner brackets.
    -- 1.7.6: the corners are the default again; the curtain is picked.
    function DRAWERS.show_box(e, v)
        local style = P.opt("box_style", cfg.BOX_DEFAULT or cfg.BOX_CORNERS)
        if style == cfg.BOX_CURTAIN and draw.curtain_3d then
            local pos = units.position(e.obj)
            if not pos then return end
            local reach = units.combat_reach and units.combat_reach(e.obj) or 0
            draw.curtain_3d(pos, math.max(0.8, (reach or 0) + 0.2), v.color, {
                to = draw.with_alpha and draw.with_alpha(v.color, 0.15) or v.color,
                height = 2, points = 16, rings = 2, verticals = 4, fill = 0.18, lod = true,
                layer = v.world_layer, droppable = true,
            })
            return
        end
        local opts = { layer = v.units_layer, thickness = 1.3, droppable = v.droppable }
        if style == cfg.BOX_FULL then
            draw.unit_box(e.obj, v.color, opts)
        elseif style == cfg.BOX_3D then
            -- In the world band, not the unit band: its edges are world
            -- lines, and they belong under the labels like a ground ring.
            opts.layer = v.world_layer
            draw.unit_box_3d(e.obj, v.color, opts)
        else
            -- Corner brackets, not a closed rectangle. Thirty closed boxes is
            -- a wall of lines; the corners read as a mark at the same glance
            -- and leave the creature visible inside them.
            draw.unit_box_corners(e.obj, v.color, opts)
        end
    end

    --- The raid icon, at the very top of the stack. The game's own art where
    --- it has loaded, and the marker's name in its colour where it has not
    --- -- "skull" in white says the same thing a moment sooner.
    function DRAWERS.show_raid_marker(e, v)
        local info = e.info
        if not v.anchor or not info or e.dead then return end
        local index = info.marker
        if not index or not cfg.RAID_MARKERS[index] then return end

        local size = marker_size(v)
        local cx, top = v.anchor.x, v.cursor
        local painted = false
        local ref, _, _, entry = pick_art(marker_art[index])
        if ref then
            painted = draw.image(ref, { x = cx - size * 0.5, y = top }, size, size,
                entry and entry.tint or nil,
                { layer = v.overlay_layer, droppable = v.droppable, uv = entry and entry.uv or nil })
        end
        if not painted then
            local small = math.max(9, v.size - 3)
            draw.text_2d({ x = cx, y = top + (size - small) * 0.5 },
                cfg.RAID_MARKERS[index].name, marker_color[index], {
                    layer = v.overlay_layer, size = small, centered = true,
                    shadow = true, droppable = v.droppable,
                })
        end
        v.cursor = v.cursor + size + ROW_GAP
    end

    --- A round portrait with a badge on its rim: a class for a player, a
    --- creature type for anything else.
    ---
    --- HOW A SQUARE ICON BECOMES A CIRCLE. There is no circular clip in the
    --- primitives, and the icon arrives as a JPEG that nothing here can
    --- unpack to mask its pixels. So the circle is built the other way
    --- round: the square icon sized so its corners reach the rim, then an
    --- opaque ring laid over the band between the icon's inscribed circle
    --- and its corners. What shows through is a round window onto the icon;
    --- the coloured rim on top is the portrait frame.
    ---
    --- NOTHING IS PAINTED UNDER THE ICON. The loader draws textures into its
    --- background list and every shape into the list above it, so a disc
    --- submitted before the icon still lands on top of it -- which is how
    --- the first version of this mark shipped as a ring with nothing inside.
    --- The disc exists only for the fallback, when there is no art to hide.
    ---
    --- Until the art has loaded -- the first time an icon is needed, a
    --- download, then a disk cache for ever after -- a disc carries an
    --- initial in the rim colour, so a mark never appears blank. An icon
    --- that FAILS is named in the log once, so a portrait that stays a
    --- letter is a message and not a mystery.
    local icon_failed_logged = {}

    ---@param v table The frame view; the portrait is placed at v.cursor.
    ---@param art table|nil Sources for the art, best first.
    ---@param rim color The frame colour.
    ---@param initial string|nil Shown until the art arrives.
    ---@param badge string|nil Letter on the rim, or nil for no badge.
    ---@param badge_color color|nil
    ---@param badge_art table|nil Sources for a spec icon in place of the letter.
    local function portrait(v, art, rim, initial, badge, badge_color, badge_art)
        local size = P.opt("class_icon_size", 22)
        local r_out = size * 0.5
        -- The largest square whose corners sit on the rim; the rim ring
        -- covers everything outside its inscribed circle.
        local r_in = r_out * INV_SQRT2
        local band = r_out - r_in

        local cx = v.anchor.x
        local cy = v.cursor + r_out + 1
        local center = { x = cx, y = cy }
        local layer = v.overlay_layer
        local droppable = v.droppable

        local ref, round, waiting = pick_art(art)
        local painted = false
        if ref then
            if round then
                -- The crest itself, transparent outside its circle: drawn to
                -- the rim, with nothing to hide.
                painted = draw.image(ref,
                    { x = cx - r_out, y = cy - r_out }, r_out * 2, r_out * 2, nil,
                    { layer = layer, droppable = droppable })
            else
                painted = draw.image(ref,
                    { x = cx - r_in, y = cy - r_in }, r_in * 2, r_in * 2, nil,
                    { layer = layer, droppable = droppable })
            end
        end

        if painted and round then
            -- nothing to mask
        elseif painted then
            -- The stroke is centred on its radius, so a ring at the middle
            -- of the band, one pixel wider than the band, covers exactly the
            -- corners and nothing of the window.
            draw.circle_2d(center, r_in + band * 0.5, disc_color,
                { thickness = band + 1.5, layer = layer, droppable = droppable })
        else
            draw.circle_2d(center, r_out + 1, disc_color,
                { filled = true, layer = layer, droppable = droppable })
            if initial then
                local font = math.max(9, math.floor(size * 0.55))
                draw.text_2d({ x = cx, y = cy - font * 0.5 }, initial, rim, {
                    layer = layer, size = font, centered = true, shadow = true,
                    droppable = droppable,
                })
            end
            if art and not waiting and assets then
                for i = 1, #art do
                    local failed = art[i][1]
                    if not icon_failed_logged[failed] then
                        icon_failed_logged[failed] = true
                        local entry = assets.get(failed)
                        local base = entry and entry.atlas and assets.get(entry.atlas.ref) or entry
                        P.log.fmt("warn", "portrait art %s failed to load: %s",
                            failed, tostring(base and base.err))
                    end
                end
            end
        end

        draw.circle_2d(center, r_out + 0.5, rim,
            { thickness = 2.0, layer = layer, droppable = droppable })

        -- The badge, on the lower-right of the rim, the way the game itself
        -- hangs one on a party portrait: the spec icon inside a ring of the
        -- role colour when the spec sheet is there, a lettered disc when not.
        if badge and P.opt("role_badge", true) then
            local r_badge = math.max(5, size * 0.24)
            local off = r_out * 0.72
            local badge_at = { x = cx + off, y = cy + off }
            local badge_ref, badge_round = pick_art(badge_art)
            local badge_painted = false
            if badge_ref then
                local half = r_badge - 0.5
                badge_painted = draw.image(badge_ref,
                    { x = badge_at.x - half, y = badge_at.y - half }, half * 2, half * 2, nil,
                    { layer = layer, droppable = droppable })
            end
            if badge_painted then
                if not badge_round then
                    -- Round off a square icon the same way as the portrait.
                    local inner = r_badge * INV_SQRT2
                    draw.circle_2d(badge_at, inner + (r_badge - inner) * 0.5, disc_color,
                        { thickness = (r_badge - inner) + 1.5, layer = layer, droppable = droppable })
                end
                draw.circle_2d(badge_at, r_badge + 0.5, badge_color or disc_color,
                    { thickness = 1.5, layer = layer, droppable = droppable })
            else
                draw.circle_2d(badge_at, r_badge + 1, disc_color,
                    { filled = true, layer = layer, droppable = droppable })
                draw.circle_2d(badge_at, r_badge, badge_color or disc_color,
                    { filled = true, layer = layer, droppable = droppable })
                local font = math.max(8, math.floor(r_badge * 1.5))
                draw.text_2d({ x = badge_at.x, y = badge_at.y - font * 0.5 },
                    badge, badge_text, {
                        layer = layer, size = font, centered = true, droppable = droppable,
                    })
            end
        end

        v.cursor = v.cursor + size + ROW_GAP + 2
    end

    --- A player's class, framed in the class colour, badged with the role.
    --- A guessed role is drawn in the same colour at reduced alpha, so a
    --- hybrid in no telling form is visibly less sure than a warrior in
    --- Defensive Stance.
    function DRAWERS.show_class_icon(e, v)
        local info = e.info
        if not v.anchor or not info or not info.is_player or e.dead then return end
        local class_id = info.class_id
        if not class_id then return end

        local name = P.esp_roles.class_name(class_id)
        local role = info.role
        portrait(v,
            class_art[class_id],
            P.class_color[class_id] or v.color,
            name and name:sub(1, 1) or nil,
            role and cfg.ROLE_LETTER[role] or nil,
            role and (info.role_certain and role_color[role] or role_color_guess[role]) or nil,
            role and badge_art_for(role, info.spec) or nil)
    end

    --- A creature's type, framed in the mark's own colour, badged caster
    --- or melee. Corpses get none: what it was is no longer the question.
    function DRAWERS.show_creature_icon(e, v)
        local info = e.info
        if not v.anchor or not info or info.is_player or e.dead then return end

        local kind = info.creature_type
        local type_name = kind and cfg.CREATURE_TYPE_NAME[kind] or nil
        -- The badge says how it fights: M, R or C, faded when it is a guess.
        -- A row classified before the fight module existed falls back to
        -- the old mana-pool answer.
        local letter, badge_col
        local fight = info.fight
        if fight then
            letter = cfg.FIGHT_LETTER[fight]
            badge_col = info.fight_sure == "guess" and fight_color_guess[fight] or fight_color[fight]
        elseif info.caster == true then
            letter, badge_col = cfg.NPC_ROLE_LETTER.caster, npc_role_color.caster
        elseif info.caster == false then
            letter, badge_col = cfg.NPC_ROLE_LETTER.melee, npc_role_color.melee
        end

        portrait(v,
            kind and creature_art[kind] or creature_art[10],
            v.color,
            type_name and type_name:sub(1, 1) or "?",
            letter,
            badge_col)
    end

    function DRAWERS.show_label(e, v)
        if not v.anchor then return end
        local text = (not v.defer) and name_text(e) or nil
        if not text and v.tag_n == 0 then return end
        name_row(e, v, text, v.color)
    end

    -- A bar in the game's own status-bar texture -- the grey gradient every
    -- bar in the client is painted with, tinted to the bar's colour -- with
    -- a dark backing and a thin outline. The backing is a texture too, not a
    -- filled rectangle: textures paint beneath every shape, so a filled
    -- backing would cover the fill. Until the texture has loaded, or with
    -- the option off, it is the flat bar it always was.
    local bar_backing = P.color(22, 22, 26, 235)

    -- BARS (1.88.0). With `esp_shader_look` on and a JCore that has bar_2d,
    -- every bar -- flat or in the game's texture -- is a rounded rail in the
    -- backing's colour and a fill shading from the bar's colour to a quarter
    -- of the way to white. The tip colour is worked out once per colour: the
    -- bars only ever come in a handful.
    function LOOK.bar_tip(col)
        local tip = LOOK.tips[col]
        if tip == nil then
            tip = draw.blend and draw.blend(col, LOOK.white, 0.25) or col
            LOOK.tips[col] = tip
        end
        return tip
    end

    local function bar(e, v, fraction, col, cx, y, width, height)
        if LOOK.shader and draw.bar_2d then
            draw.bar_2d({ x = cx - width * 0.5, y = y }, width, height, fraction or 0, col, {
                to = LOOK.bar_tip(col), bg = bar_backing,
                layer = v.units_layer, droppable = v.droppable,
            })
            return
        end
        local ref = P.opt("game_bars", true) and pick_art(game_ui_art.status_bar) or nil
        if not ref then
            draw.unit_bar(e.obj, fraction, col, {
                at = { x = cx, y = y },
                layer = v.units_layer,
                width = width,
                height = height,
                border = draw.theme.shadow,
                droppable = v.droppable,
            })
            return
        end
        local left = cx - width * 0.5
        local opts = { layer = v.units_layer, droppable = v.droppable }
        draw.image(ref, { x = left, y = y }, width, height, bar_backing, opts)
        local f = math.max(0, math.min(1, fraction or 0))
        if f > 0 then
            -- Cut, not squeezed: a bar a third full shows the left third of
            -- the texture, as the game's own bars do.
            draw.image(ref, { x = left, y = y }, width * f, height, col,
                { layer = v.units_layer, droppable = v.droppable, uv = { 0, 0, f, 1 } })
        end
        draw.rect_2d({ x = left, y = y }, width, height, draw.theme.shadow,
            { thickness = 1.0, layer = v.units_layer, droppable = v.droppable })
    end

    M.bar = bar

    function DRAWERS.show_bar(e, v)
        if not v.anchor or e.dead or v.defer then return end
        local fraction = units.health_fraction(e.obj)
        if fraction <= 0 then return end
        -- A full bar on every mob in the zone is a row of identical green
        -- lines saying nothing. It appears when it has something to say.
        if fraction > 0.995 and not P.opt("bar_always", false) then return end

        local width = P.opt("bar_width", 54)
        local height = P.opt("bar_height", 4)

        bar(e, v, fraction, health_color(fraction), v.anchor.x, v.cursor + 1, width, height)
        v.cursor = v.cursor + height + ROW_GAP + 1
    end

    --- Blue, under the health bar, for anything with a mana pool.
    function DRAWERS.show_power(e, v)
        if not v.anchor or not power_shown(v) then return end
        local height = mana_bar_h()
        bar(e, v, v.power.frac, mana_color, v.anchor.x, v.cursor + 1, P.opt("bar_width", 54), height)
        v.cursor = v.cursor + height + ROW_GAP + 1
    end

    --- A pill and a bar:
    ---
    ---     [icon] ( Frostbolt  1.4 )
    ---            =========-------
    ---
    --- White when it can be interrupted, red when it cannot. The spell icon
    --- sits to the LEFT of the pill, never on it: textures paint beneath
    --- every shape, so an icon on the backdrop would vanish into it.
    function DRAWERS.show_cast(e, v)
        local c = v.cast
        if not v.anchor or not c then return end

        local col = c.interruptible and cast_color.interruptible or cast_color.locked
        local top = v.cursor
        seg(c.remaining and string.format("%s  %.1f", c.name, c.remaining) or c.name, col, col)
        local left, width, h = pill_row(e, v, true)
        if not left then return end

        local at = { x = left - h - 3, y = top }
        local ref = pick_art(spell_art_for(c.spell_id))
        if ref then
            draw.image(ref, at, h, h, nil, { layer = v.overlay_layer, droppable = v.droppable })
        elseif c.spell_id and draw.spell_icon then
            draw.spell_icon(c.spell_id, at, h, nil,
                { layer = v.overlay_layer, droppable = v.droppable })
        end

        -- The bar hangs one pixel under the pill and is at least as wide as
        -- it, so the two read as one block.
        local bar_h = P.opt("bar_height", 4)
        v.cursor = top + h + 1
        bar(e, v, c.fraction, col, v.anchor.x, v.cursor, math.max(P.opt("bar_width", 54), width), bar_h)
        v.cursor = v.cursor + bar_h + ROW_GAP + 1
    end

    --- ( 11 · 42y )  ( neutral ) -- the facts in white, the reaction in its
    --- own colour: green friendly, orange neutral, red hostile.
    function DRAWERS.show_details(e, v)
        local text = v.details_text
        if not v.anchor or (not text and not v.reaction_word) then return end
        -- How it fights first: the one thing on this row that decides how
        -- the pull goes.
        if v.fight_word then seg(v.fight_word, v.fight_color, v.fight_color) end
        if text then
            local lead = v.details_lead
            seg(text, pill_text, nil, lead,
                lead and level_color[cfg.difficulty_band(e.info.level, v.player_level)] or nil)
        end
        if v.reaction_word then
            local col = reaction_color[v.reaction_key] or pill_text
            seg(v.reaction_word, col, col)
        end
        pill_row(e, v)
    end

    --- One pill, with the game's picture of it beside the pill where it has
    --- one: the combat swords, or the crowd control's own spell icon.
    function DRAWERS.show_status(e, v)
        local text = v.status_text
        if not v.anchor or not text then return end
        local col = v.status_color or pill_text
        local top = v.cursor
        seg(text, col, col)
        local left, _, h = pill_row(e, v, v.status_art ~= nil or v.status_spell ~= nil)
        if not left then return end
        local at = { x = left - h - 3, y = top }
        local ref, _, _, entry = pick_art(v.status_art or spell_art_for(v.status_spell))
        if ref then
            draw.image(ref, at, h, h, entry and entry.tint or nil,
                { layer = v.overlay_layer, droppable = v.droppable, uv = entry and entry.uv or nil })
        elseif v.status_spell and draw.spell_icon then
            draw.spell_icon(v.status_spell, at, h, nil,
                { layer = v.overlay_layer, droppable = v.droppable })
        end
    end

    --- "threat 72%, #2 of 5": your percent and rank on its threat table, in
    --- green, amber or red by how close you are to pulling it.
    function DRAWERS.show_threat(e, v)
        local text = v.threat_text
        if not v.anchor or not text then return end
        local col = v.threat_color or pill_text
        seg(text, col, col)
        pill_row(e, v)
    end

    --- The selected target only: [LoS] [Out of Range], each in its own
    --- colour -- green when it is fine, amber out of range or too close, red
    --- with no line of sight.
    function DRAWERS.show_reach(e, v)
        if not v.anchor or not v.is_target then return end
        local sight, range = reach_state(e)
        if sight == true then
            seg("LoS", reach_ok, reach_ok)
        elseif sight == false then
            seg("No LoS", reach_blocked, reach_blocked)
        end
        local col = range == "In Range" and reach_ok or reach_far
        seg(range, col, col)
        pill_row(e, v)
    end

    --- Which quest wants this, and how far along it is.
    ---
    --- One line PER QUEST, because a mob that serves two quests is the exact
    --- case where "[quest]" told you nothing: it is worth killing twice over
    --- and the old mark could not say so. Each line takes that quest's own
    --- colour, which is the same colour as the path drawn to it, so a line on
    --- the ground and a line above a mob are visibly the same quest.
    --- One quest's line: what to do there, and how far along it is.
    quest_line = function(entry)
        local quest = entry.quest
        local text
        if entry.turn_in then
            text = "turn in: " .. quest.name
        elseif entry.pick_up then
            text = "pick up: " .. quest.name
        else
            local objective = entry.objective
            if objective and (objective.need or 0) > 0 and P.opt("quest_show_progress", true) then
                text = string.format("%s  %.0f/%.0f", quest.name, objective.have or 0, objective.need)
            else
                text = quest.name
            end
        end
        if #text > 34 then text = text:sub(1, 33) .. "\226\128\166" end
        return text
    end

    function DRAWERS.show_quest_tag(e, v)
        local entries = e.quest_entries
        if not v.anchor or (not entries and not e.guide_goal) then return end

        -- What the guide wants with it, in the guide's blue, ahead of the
        -- quest lines. The GUIDE chip says THAT RestedXP wants this; this
        -- line is the step's own text, so it says what for.
        local goal = e.guide_goal
        if goal and goal.text then
            local text = goal.text
            if #text > 34 then text = text:sub(1, 33) .. "\226\128\166" end
            seg(text, tag_color.guide, nil)
            pill_row(e, v)
        end
        if not entries then return end

        local shown = math.min(#entries, 3)

        for i = 1, shown do
            local entry = entries[i]
            -- The quest's own colour as text, on the dark pill: the same
            -- colour as the path drawn to it.
            seg(quest_line(entry), P.quests.quest_color(entry.quest), nil)
            pill_row(e, v)
        end
    end

    -- Warnings are never droppable. The draw budget exists to shed the boar
    -- at ninety yards on a heavy frame, not the thing that is hitting you.

    -- The ring's look (1.66.2). The native circle glows inward from its
    -- edge, and its fade says how far: JCore passes 1.0, which spread the
    -- glow over the whole disc, and a pack on you painted the ground solid.
    -- A fast fade keeps the glow on the rim, and the more rings there are
    -- the fainter each is (down to `floor` of one alone). `n` counts this
    -- frame's rings, `last` the frame before's (begin_frame).
    local aggro_ring = { fade = 6.0, alpha = 200, floor = 0.6, stack = 8, n = 0, last = 0, colors = {} }

    -- GROUND RINGS (1.88.0): JCore's shader ring_3d, a thin band full all the
    -- way round, where it has one: soft edges and no glow over the disc, which
    -- is what the fast fade above was keeping off it. The same colours, and
    -- the same "fainter the more there are". LOOK.clear is the empty part of
    -- a full ring, which never shows: with no shader, ring_3d draws it as an
    -- outline under the fill, and a clear one adds nothing.

    --- A ring at the feet of anything that has you targeted.
    function DRAWERS.show_aggro(e, v)
        if v.victim ~= "me" then return end
        local pos = units.position(e.obj)
        if not pos then return end
        -- Sized to the model, so the ring sits round a kodo's feet and not
        -- inside them. Combat reach is read once per tick and kept.
        local reach = units.combat_reach and units.combat_reach(e.obj) or 0
        local radius = math.min(4, math.max(0.9, (reach or 0) + 0.3))
        local ring = aggro_ring
        ring.n = ring.n + 1
        local n = math.min(ring.stack, math.max(ring.last, ring.n))
        local c = ring.colors[n]
        if not c then
            local rgb = cfg.STATUS_RGB.me
            c = P.color(rgb[1], rgb[2], rgb[3],
                math.floor(ring.alpha * math.max(ring.floor, 1 / math.sqrt(n)) + 0.5))
            ring.colors[n] = c
        end
        if draw.ring_3d then
            draw.ring_3d(pos, radius, 1, c, {
                bg = LOOK.clear, inner = LOOK.aggro_inner, outer = 1.0, layer = v.world_layer,
            })
            return
        end
        draw.circle_3d(pos, radius, c, {
            layer = v.world_layer,
            thickness = 2.0,
            fade = ring.fade,
        })
    end

    -- THE CAST RING (1.85.0): JCore 1.11's ring_3d just outside the aggro
    -- ring, filling as the cast runs (a channel empties), from the cast
    -- bar's colour -- white you can kick, red you cannot -- to red.
    local CAST_RING_GAP = 0.35
    local cast_ring_to = P.color(cfg.STATUS_RGB.me[1], cfg.STATUS_RGB.me[2], cfg.STATUS_RGB.me[3])
    local cast_ring_band = P.color(0, 0, 0, 180)

    function DRAWERS.show_cast_ring(e, v)
        local c = v.ring_cast
        if not c or not c.fraction or not draw.ring_3d then return end
        local pos = units.position(e.obj)
        if not pos then return end
        local reach = units.combat_reach and units.combat_reach(e.obj) or 0
        local radius = math.min(4, math.max(0.9, (reach or 0) + 0.3)) + CAST_RING_GAP
        draw.ring_3d(pos, radius, c.fraction, c.interruptible and cast_color.interruptible or cast_color.locked,
            { to = cast_ring_to, bg = cast_ring_band, layer = v.world_layer })
    end

    -- FAR THINGS AS PILLARS (1.88.0): JCore 1.13's beacon_3d on a rare, a
    -- boss, a quest or guide target (the guide outranks the quest for the
    -- category, and is a quest target all the same), or a corpse with loot
    -- on it, once it is further off than `esp_beacon_from` -- in the mark's
    -- colour, ten yards tall. Drawn while its top shows, so a mark off screen
    -- still gets one (draw_entity). Never on a node: modules/beacons.lua
    -- puts the pillars on those.
    function LOOK.wants_beacon(e)
        if e.kind ~= "unit" or (e.distance or 0) <= LOOK.beacon_from then return false end
        if e.dead then return e.category == "corpse" and e.lootable == true end
        return LOOK.beacon_category[e.category] == true
    end

    function DRAWERS.show_beacon(e, v)
        if not draw.beacon_3d or not LOOK.wants_beacon(e) then return end
        local pos = units.position(e.obj)
        if not pos then return end
        draw.beacon_3d(pos, v.color, { height = LOOK.beacon_height, layer = v.world_layer, droppable = v.droppable })
    end

    local geometry = ctx.geometry
    local LINE_LIFT = 1.0

    local function lifted(p)
        local z = (p.z or 0) + LINE_LIFT
        if geometry and geometry.vec then return geometry.vec(p.x, p.y, z) end
        return { x = p.x, y = p.y, z = z }
    end

    --- A line from an attacker to whoever it is after, while it is still on
    --- its way. Red when that is you, amber for your pet or a party member.
    --- Drawn at chest height at both ends, so it clears the ground between
    --- them rather than tunnelling through the first hill.
    function DRAWERS.show_target_line(e, v)
        local victim = v.victim
        if not victim then return end

        local from = units.position(e.obj)
        if not from then return end

        local to
        if victim == "me" then
            to = units.player_position and units.player_position() or nil
        else
            local target = units.by_guid(v.detail.target_guid)
            to = target and units.position(target) or nil
        end
        if not to then return end

        local dx, dy, dz = to.x - from.x, to.y - from.y, to.z - from.z
        local min = cfg.TARGET_LINE_MIN
        if dx * dx + dy * dy + dz * dz < min * min then return end

        draw.line_3d(lifted(from), lifted(to),
            victim == "me" and status_color.me or status_color.group, {
                layer = v.world_layer,
                thickness = 2.0,
            })
    end

    function DRAWERS.show_tracer(e, v)
        local screen = draw.unit_w2s(e.obj)
        if not screen then return end
        local w, h = draw.screen_size()
        draw.line_2d({ x = w * 0.5, y = h }, screen, v.color, {
            layer = v.world_layer,
            thickness = 1.0,
            droppable = v.droppable,
        })
    end

    --- The node's name -- "Mithril Deposit (Requires Skill 175)" when your
    --- skill is short of it (1.88.0), in the mark's dimmed colour -- and its
    --- distance under it.
    function DRAWERS.node_label(e, v)
        if not v.anchor then return end
        local text = LOOK.node_text(e)
        if not text then return end

        name_row(e, v, text, v.color)

        if P.opt("show_distance", true) then
            local size = math.max(9, v.size - 3)
            draw.unit_label(e.obj, string.format("%.0fy", e.distance),
                draw.theme.text_dim, {
                    at = { x = v.anchor.x, y = v.cursor },
                    layer = v.overlay_layer,
                    size = size,
                    shadow = true,
                    droppable = v.droppable,
                })
            v.cursor = v.cursor + size + ROW_GAP
        end
    end

    function DRAWERS.node_ring(e, v)
        local pos = units.position(e.obj)
        if not pos then return end
        if draw.ring_3d then
            draw.ring_3d(pos, 0.7, 1, v.color, {
                bg = LOOK.clear, inner = LOOK.node_ring_inner, outer = 1.0,
                layer = v.world_layer, droppable = v.droppable,
            })
            return
        end
        draw.circle_3d(pos, 0.7, v.color, {
            layer = v.world_layer,
            thickness = 1.5,
            droppable = v.droppable,
        })
    end

    -- --- the resolved list --------------------------------------------------

    -- Tier ranks, so an element is compared against an entity's tier with one
    -- integer comparison rather than a string match per element per unit.
    local TIER = { far = 1, mid = 2, full = 3 }

    -- Built once from the config rows, in config order. A row with no drawer
    -- is announced rather than skipped silently: it means a toggle exists that
    -- does nothing, which is worse than a missing mark.
    for i = 1, #cfg.ELEMENTS do
        local row = cfg.ELEMENTS[i]
        local drawer = DRAWERS[row.key]
        if drawer then
            local element = {
                key = row.key,
                default = row.default,
                kind = row.kind,
                tier = TIER[row.lod] or 1,
                below = row.below,
                draw = drawer,
            }
            ACTIVE[#ACTIVE + 1] = element
            if row.key == "show_target_line" then OFFSCREEN[#OFFSCREEN + 1] = element end
            if row.key == "show_beacon" then LOOK.beacon_el = element end
            if row.below then
                ROWS[#ROWS + 1] = element
                BELOW[#BELOW + 1] = element
            end
        else
            P.log.fmt("error", "ESP element '%s' has a toggle but no drawer", row.key)
        end
    end
    table.sort(BELOW, function(a, b) return a.below < b.below end)
    for i = 1, #ACTIVE do
        if TOP_KEYS[ACTIVE[i].key] then COVERED[#COVERED + 1] = ACTIVE[i] end
    end
    for i = 1, #BELOW do COVERED[#COVERED + 1] = BELOW[i] end

    -- --- drawing ------------------------------------------------------------

    local view = { color = nil, size = 13, droppable = false, tags = {}, tag_n = 0, now = 0 }
    view_now = function() return view.now or 0 end

    -- THE SETTINGS EVERY MARK READS, once a frame (begin_frame). Each mark
    -- read twenty-odd of them for itself, and every element's toggle two or
    -- three times over -- some five thousand settings reads a frame in a
    -- crowd, for the same few dozen answers.
    local S = {}

    -- How this frame's marks were laid out, for the Debug page and the tests:
    -- the whole stack, cut to the name, nothing above the head, off screen.
    local layout = { full = 0, name = 0, hidden = 0, offscreen = 0 }
    function M.layout() return layout end

    local function read_settings()
        for i = 1, #ACTIVE do
            local el = ACTIVE[i]
            el.on = P.opt(el.key, el.default) and true or false
        end
        S.show_cast = P.opt("show_cast", true)
        S.show_status = P.opt("show_status", true)
        S.show_aggro = P.opt("show_aggro", true)
        S.show_cast_ring = P.opt("show_cast_ring", true)
        S.show_beacon = P.opt("show_beacon", false)
        LOOK.beacon_from = tonumber(P.opt("esp_beacon_from", 40)) or 40
        LOOK.shader = P.opt("esp_shader_look", true) and true or false
        S.show_target_line = P.opt("show_target_line", true)
        S.show_threat = P.opt("show_threat", true)
        S.show_details = P.opt("show_details", true)
        S.show_reach = P.opt("show_reach", true)
        S.rows_below = P.opt("esp_rows_below", true)
        S.show_fight_role = P.opt("show_fight_role", true)
        S.show_reaction_tag = P.opt("show_reaction_tag", false)
        S.show_power = P.opt("show_power", true)
        S.show_mana_text = P.opt("show_mana_text", true)
        S.text_size = P.opt("text_size", 13)
        S.label_above_head = P.opt("label_above_head", true)
        S.label_lift = P.opt("label_lift", 10)
        S.plate_mode = P.opt("esp_plate_mode", cfg.PLATE_BELOW)
        S.plate_defer = P.opt("esp_plate_defer", true)
        S.plate_clearance = P.opt("plate_clearance", 4)
        S.declutter = P.opt("esp_declutter", true)
        S.bar_width = P.opt("bar_width", 54)
        S.class_icon_size = P.opt("class_icon_size", 22)
    end
    read_settings()

    -- Under the feet: a few pixels of ground between the model and the
    -- first row, and a margin from the bottom of the screen.
    local BELOW_GAP = 6
    local SCREEN_MARGIN = 8
    local below_anchor = { x = 0, y = 0 }

    -- --- declutter ----------------------------------------------------------
    --
    -- Every block drawn this frame claims its rectangle, and a block under
    -- the feet that would land on one already claimed moves down until it
    -- is clear. Marks are drawn most relevant first (bosses, rares, quest
    -- and guide targets, your target, then the nearest), so the block that
    -- moves is always the less important one. If it would have to move more
    -- than a few rows, it is cut to the rows that cannot wait -- the cast,
    -- line of sight, "on you", threat -- and if even that will not fit, it
    -- is not drawn: a block printed over another one is read as neither.

    local px0, py0, px1, py1 = {}, {}, {}, {}
    local placed_n = 0

    local URGENT = URGENT_ROWS

    local function occupy(x0, y0, x1, y1)
        placed_n = placed_n + 1
        px0[placed_n], py0[placed_n], px1[placed_n], py1[placed_n] = x0, y0, x1, y1
    end

    --- The first y at or below `top` where a block of this size is clear of
    --- everything claimed, or nil when none is within reach.
    local function find_slot(cx, w, top, h, floor_y, max_shift)
        local x0, x1 = cx - w * 0.5 - 2, cx + w * 0.5 + 2
        local y = top
        for _ = 1, 16 do
            local blocked = nil
            for i = 1, placed_n do
                if x0 < px1[i] and x1 > px0[i] and y < py1[i] and (y + h) > py0[i] then
                    if not blocked or py1[i] > blocked then blocked = py1[i] end
                end
            end
            if not blocked then return y end
            y = blocked + 2
            if (y + h) > floor_y or (y - top) > max_shift then return nil end
        end
        return nil
    end

    --- The same search upward, for the stack above a head: the first top at
    --- or above `top` where the block is clear, or nil past `max_shift`.
    local function find_slot_up(cx, w, top, h, max_shift)
        local x0, x1 = cx - w * 0.5 - 2, cx + w * 0.5 + 2
        local y = top
        for _ = 1, 16 do
            local blocked = nil
            for i = 1, placed_n do
                if x0 < px1[i] and x1 > px0[i] and y < py1[i] and (y + h) > py0[i] then
                    if not blocked or py0[i] < blocked then blocked = py0[i] end
                end
            end
            if not blocked then return y end
            y = blocked - 2 - h
            if y < 0 or (top - y) > max_shift then return nil end
        end
        return nil
    end

    local function wider(w, x) if x > w then return x end return w end

    --- The name row's width, chips and all, as name_row will draw it.
    local function label_width(e, v)
        local text = (not v.defer) and name_text(e) or nil
        local w = text and text_width(text, v.size) or 0
        if v.lead_ref then w = w + lead_size(v) + ICON_GAP + 2 end
        local n = v.tag_n
        if n > 0 then
            local csize, ch = chip_size(v), chip_h(v)
            for i = 1, n do
                w = w + text_width(cfg.TAGS[v.tags[i]].word, csize) + PILL_PAD_X * 2
                    + ch + ICON_GAP + TAG_GAP
            end
            if text then w = w + 2 end
        end
        return w
    end

    --- How wide one row will be, from the same strings it will draw.
    --- Glyph-summed, so it costs no native call.
    local function row_width(el, e, v)
        local size, pad2 = v.size, PILL_PAD_X * 2
        local key = el.key
        if key == "show_raid_marker" then
            return (e.info and e.info.marker) and marker_size(v) or 0
        elseif key == "show_class_icon" or key == "show_creature_icon" then
            return S.class_icon_size
        elseif key == "show_label" then
            return label_width(e, v)
        elseif key == "node_label" then
            return text_width(LOOK.node_text(e) or "", size) + 4
        elseif key == "show_bar" or key == "show_power" then
            return S.bar_width
        elseif key == "show_cast" then
            if not v.cast then return 0 end
            return math.max(text_width(v.cast.name .. "  00.0", size) + pad2 + pill_h(v) + 3, S.bar_width)
        elseif key == "show_reach" then
            if not v.is_target then return 0 end
            return text_width("No LoS", size) + text_width("Out of Range", size) + pad2 * 2 + PILL_GAP
        elseif key == "show_status" then
            if not v.status_text then return 0 end
            local icon = (v.status_art or v.status_spell) and (pill_h(v) + 3) * 2 or 0
            return text_width(v.status_text, size) + pad2 + icon
        elseif key == "show_threat" then
            return v.threat_text and (text_width(v.threat_text, size) + pad2) or 0
        elseif key == "show_details" then
            if not (v.details_text or v.reaction_word or v.fight_word) then return 0 end
            local x = v.details_text and (text_width(v.details_text, size) + pad2) or 0
            if v.reaction_word then x = x + text_width(v.reaction_word, size) + pad2 + PILL_GAP end
            if v.fight_word then x = x + text_width(v.fight_word, size) + pad2 + PILL_GAP end
            return x
        elseif key == "show_quest_tag" then
            local w = 0
            local goal = e.guide_goal
            if goal and goal.text then
                w = wider(w, text_width(goal.text:sub(1, 34), size) + pad2)
            end
            local entries = e.quest_entries
            if entries then
                for j = 1, math.min(#entries, 3) do
                    w = wider(w, text_width(quest_line(entries[j]), size) + pad2)
                end
            end
            return w
        end
        return 0
    end

    --- How wide the block under the feet will be.
    local function below_width(e, v, tier)
        local w = 0
        local list = below_list(v)
        for i = 1, #list do
            local el = list[i]
            if applies(el, e, tier) and (not v.compact or is_urgent(el, v)) then
                w = wider(w, row_width(el, e, v))
            end
        end
        return w
    end

    --- How wide the stack above the head will be.
    local function top_width(e, v, tier)
        local w = 0
        for i = 1, #ACTIVE do
            local el = ACTIVE[i]
            if not GROUND_KEYS[el.key] and in_top_pass(el, e, v, tier) then
                w = wider(w, row_width(el, e, v))
            end
        end
        return w
    end

    --- The rows that go under the feet, top down from just below the model.
    ---
    --- Anchored on the unit's own position, the feet, which costs nothing:
    --- the projection is cached for the frame. When the feet are near the
    --- bottom of the screen, or below it, the block is lifted until it fits.
    --- A block that overlaps the model is still read; one below the edge of
    --- the screen is not.
    local function draw_below(e, v, tier)
        local feet = draw.unit_w2s(e.obj)
        local x = feet and feet.x or (v.anchor and v.anchor.x)
        if not x then return end

        local _, screen_h = draw.screen_size()
        local floor_y = (screen_h and screen_h > 0) and (screen_h - SCREEN_MARGIN) or math.huge
        if not feet and floor_y == math.huge then return end

        local declutter = S.declutter

        -- First the whole block; when that will not fit, the urgent rows.
        v.compact = false
        for _ = 1, 2 do
            local height = below_height(e, v, tier)
            if height > 0 then
                local top = feet and (feet.y + BELOW_GAP) or math.huge
                if top + height > floor_y then top = floor_y - height end

                local slot, width = top, 0
                if declutter then
                    -- Three rows of reach for the whole block, six for the
                    -- urgent rows: a cast or "on you" a little way from its
                    -- unit beats no cast at all.
                    local max_shift = (v.compact and 6 or 3) * (pill_h(v) + ROW_GAP)
                    width = below_width(e, v, tier)
                    slot = find_slot(x, width, top, height, floor_y, max_shift)
                end
                if slot then
                    if declutter then
                        occupy(x - width * 0.5, slot, x + width * 0.5, slot + height)
                    end
                    below_anchor.x, below_anchor.y = x, slot
                    v.anchor = below_anchor
                    v.cursor = slot
                    local list = below_list(v)
                    for i = 1, #list do
                        local element = list[i]
                        if applies(element, e, tier) and not (v.compact and not is_urgent(element, v)) then
                            element.draw(e, v)
                        end
                    end
                    v.compact = false
                    return
                end
            end
            if not declutter or v.compact then break end
            v.compact = true
        end
        v.compact = false
    end

    --- Paints every enabled element for one entity.
    ---
    --- ON LAYER BIAS: entities are drawn nearest first, so the draw budget
    --- runs out on the far ones rather than the near ones. That is the
    --- opposite of the order you want to PAINT in, where the nearest mark
    --- should end up on top. Biasing each tier's layer down by a point or two
    --- gets both: submission order stays near-first, paint order comes out
    --- far-first. The bands are a hundred apart, so a bias of two cannot
    --- collide with another plugin's layer.
    ---@param e table
    ---@param rank? integer Its place in this frame's list, 1 the most relevant.
    function M.draw_entity(e, rank)
        local tier = TIER[e.lod] or 3
        -- Your target paints in the nearest band whatever its distance: it is
        -- the mark being read.
        local bias = ((e.prio or 0) >= 1000) and 0 or (tier - 3)
        -- WITHIN A BAND, THE MORE RELEVANT MARK PAINTS LATER, so it ends up on
        -- top. Marks are submitted most relevant first, and in one layer the
        -- first painted is covered by every later one that overlaps it --
        -- which put your target's block under its neighbours'. A fraction of
        -- a layer per rank keeps the bands apart and reverses that.
        local lift = rank and (0.95 - math.min(rank, 900) * 0.001) or 0
        view.units_layer = ctx.LAYER.UNITS + bias + lift
        view.overlay_layer = ctx.LAYER.OVERLAY + bias + lift
        view.world_layer = ctx.LAYER.WORLD + bias + lift
        -- Only the nearest tier is protected. Everything else is the first
        -- thing to go when the frame runs out of budget, which is the whole
        -- point of having tiers.
        view.droppable = e.lod ~= "full"
        view.size = S.text_size
        view.top_cut = nil

        -- THE ANCHOR FIRST. One per entity; the head attachment costs a
        -- native call, so the far tier -- where the model is a few pixels
        -- tall and the difference is invisible -- uses the cheap feet
        -- projection with a fixed lift instead.
        if tier >= 2 and S.label_above_head then
            view.anchor = draw.unit_anchor(e.obj, S.label_lift)
        else
            local screen = draw.unit_w2s(e.obj)
            view.anchor = screen and { x = screen.x, y = screen.y - 14 } or nil
        end

        local info = e.info
        view.detail, view.cast, view.victim, view.ring_cast = nil, nil, nil, nil
        view.status_text, view.status_color = nil, nil
        view.status_art, view.status_spell = nil, nil
        view.threat_text, view.threat_color = nil, nil
        view.status_urgent, view.threat_urgent = false, false

        -- OFF SCREEN, nothing but the line from an attacker to you, whose
        -- near end you can see. Everything else a mark reads -- its detail,
        -- status, threat, art, mana, nameplate -- was read for marks behind
        -- the camera too, and spent the frame's rationed reads on them before
        -- the marks in view got theirs. Its who-is-it-after comes only from
        -- what is free: the enemies service's row, or an earlier read.
        if not view.anchor then
            layout.offscreen = layout.offscreen + 1
            if e.kind == "unit" and info and not e.dead and info.can_attack and S.show_target_line then
                local collect = P.esp_collect
                view.detail = collect and collect.detail(e, true) or nil
                view.victim = victim_of(view.detail)
                if view.victim then
                    for i = 1, #OFFSCREEN do
                        local element = OFFSCREEN[i]
                        if applies(element, e, tier) then element.draw(e, view) end
                    end
                end
            end
            -- A far rare's pillar (1.88.0) stands over the hill its feet are
            -- behind: drawn here too, in its colour, at no read's cost.
            local beacon = LOOK.beacon_el
            if beacon and S.show_beacon and LOOK.wants_beacon(e) and applies(beacon, e, tier) then
                view.color = color_for(e, view)
                beacon.draw(e, view)
            end
            return
        end

        -- What it is doing, read before anything is laid out. Only for what
        -- you can attack -- a friendly guard's cast is not a decision -- and
        -- only when a mark that shows it is on, so switching all four off
        -- costs nothing at all. For a hostile the answer is the enemies
        -- service's row and costs no native call.
        if e.kind == "unit" and info and not e.dead then
            local wants_stack = tier >= 2 and (S.show_cast or S.show_status)
            local wants_ground = S.show_aggro or S.show_target_line or S.show_cast_ring
            if info.can_attack and (wants_stack or wants_ground) then
                local collect = P.esp_collect
                view.detail = collect and collect.detail(e) or nil
                view.victim = victim_of(view.detail)
                local bar = tier >= 2 and S.show_cast
                if bar or S.show_cast_ring then
                    local cast = cast_state(view.detail, view.now_ms)
                    if bar then view.cast = cast end
                    if S.show_cast_ring then view.ring_cast = cast end
                end
            end
            if tier >= 2 and S.show_status then
                view.status_text, view.status_color, view.status_art, view.status_spell =
                    status_for(e, view.detail)
                local c = view.status_color
                view.status_urgent = c ~= nil
                    and (c == status_color.me or c == status_color.group or c == status_color.control)
            end
            -- No native: the board was read by the service on its own clock.
            if tier >= 2 and info.can_attack and S.show_threat then
                local count
                view.threat_text, view.threat_color, count = threat_for(e)
                -- Solo, "aggro, #1 of 1" under "on you" says the same thing
                -- twice; the status row has it.
                if view.threat_text and view.status_text == "on you" and (count or 0) <= 1 then
                    view.threat_text, view.threat_color = nil, nil
                end
                view.threat_urgent = view.threat_color ~= nil and view.threat_color ~= threat_color.safe
            end
        end

        -- The other two conditional rows, worked out once here because both
        -- the layout and the drawer need them: the details line is a string
        -- built per frame, and "is this my target" is a compare.
        view.details_text, view.details_lead, view.is_target = nil, nil, false
        if e.kind == "unit" and tier >= 2 then
            if S.show_details then view.details_text, view.details_lead = detail_text(e) end
            if not e.dead and S.show_reach then view.is_target = is_target(e) end
        end
        view.rows_below = S.rows_below
        -- Why it is marked, as chips for the name row; resolved before the
        -- layout because a chip row is taller than a bare name.
        resolve_tags(e, view)
        -- And the game badge before it, when its art has loaded.
        local lead = lead_art_for(e, view)
        view.lead_ref, view.lead_entry = nil, nil
        if lead then
            local ref, _, _, entry = pick_art(lead)
            view.lead_ref, view.lead_entry = ref, entry
        end

        -- The reaction word, for its own coloured pill beside the details.
        -- How it fights, for the pill at the front of the details row.
        view.fight_word, view.fight_color = nil, nil
        if e.kind == "unit" and tier >= 2 and info and not e.dead and info.fight
            and S.show_details and S.show_fight_role then
            local guess = info.fight_sure == "guess"
            view.fight_word = cfg.FIGHT_WORD[info.fight] .. (guess and "?" or "")
            view.fight_color = guess and fight_color_guess[info.fight] or fight_color[info.fight]
        end

        view.reaction_word, view.reaction_key = nil, nil
        if e.kind == "unit" and tier >= 2 and info and S.show_details then
            if e.dead then
                -- Always, not only with the reaction words on: "dead" is the
                -- one fact about a corpse, and its reaction is not one.
                view.reaction_key, view.reaction_word = "dead", "dead"
            elseif not info.is_player and S.show_reaction_tag then
                view.reaction_key = info.reaction or "neutral"
                view.reaction_word = REACTION_TAG[view.reaction_key]
            end
        end

        -- Mana: a bar under the health bar, and the percentage on the
        -- details pill once some of it is gone.
        view.power = nil
        if e.kind == "unit" and tier >= 2 and (S.show_power or S.show_mana_text) then
            view.power = mana_of(e)
            local p = view.power
            if p and view.details_text and p.frac < 0.995 and S.show_mana_text then
                view.details_text = view.details_text
                    .. string.format("  \194\183  %.0f%% mana", p.frac * 100)
            end
        end
        view.name_w = 0
        view.color = color_for(e, view)

        -- A nameplate where the mark would hang. By default the whole mark
        -- moves under the feet while the plate is up (view.covered); or it
        -- sits on top of the plate, when the plate's rectangle is known. The
        -- name and health bar are left to the plate either way (view.defer).
        view.plate, view.defer, view.covered = false, false, false
        if tier >= 2 and e.kind == "unit" then
            local mode = S.plate_mode
            if mode ~= cfg.PLATE_IGNORE then
                local top, up = plate_top(e, view.anchor)
                if up or top or has_plate_token(e.guid) then
                    view.plate = true
                    view.defer = S.plate_defer
                    if mode == cfg.PLATE_ABOVE and top then
                        local lift_to = top - S.plate_clearance
                        if lift_to < view.anchor.y then
                            view.anchor = { x = view.anchor.x, y = lift_to }
                        end
                    else
                        -- Under the feet: also where "on top" goes when the
                        -- plate is up but its rectangle could not be read.
                        view.covered = true
                    end
                end
            end
        end
        -- The anchor is the BOTTOM of the stack -- just above the head -- and
        -- the rows are laid out upward from there, so the name ends up on top
        -- and nothing is painted across the model.
        local height = stack_height(e, view, tier)
        view.cursor = view.anchor.y - height

        -- THE STACK ABOVE THE HEAD KEEPS CLEAR TOO. Until 1.40 only the
        -- block under the feet looked for room; names, portraits and bars
        -- above neighbouring heads printed over each other. Marks are laid
        -- out most relevant first, so the first to claim a spot keeps it:
        -- a later stack moves up a little, or is cut to its name, or -- when
        -- even the name would land on another -- is not drawn above the head
        -- at all (its rings, lines and the rows under its feet still are).
        if S.declutter and height > 0 then
            local row = pill_h(view) + ROW_GAP
            local x = view.anchor.x
            local w = top_width(e, view, tier)
            local slot = find_slot_up(x, w, view.cursor, height, 2 * row)
            if not slot then
                view.top_cut = "name"
                height = stack_height(e, view, tier)
                if height > 0 then
                    w = top_width(e, view, tier)
                    slot = find_slot_up(x, w, view.anchor.y - height, height, 4 * row)
                end
                if not slot then view.top_cut = "all" end
            end
            if slot then
                local shift = (view.anchor.y - height) - slot
                if shift > 0 then view.anchor = { x = x, y = view.anchor.y - shift } end
                view.cursor = slot
                occupy(x - w * 0.5, slot, x + w * 0.5, slot + height)
            else
                view.cursor = view.anchor.y
            end
        end

        if view.top_cut == "all" then layout.hidden = layout.hidden + 1
        elseif view.top_cut == "name" then layout.name = layout.name + 1
        else layout.full = layout.full + 1 end

        -- No pcall per element on purpose. The scheduler already contains a
        -- failing render job, and the draw service already contains a failing
        -- primitive at flush; a third guard here would cost one pcall per mark
        -- per frame to catch what those two already catch.
        --
        -- Two passes: everything above the head, then the rows that go under
        -- the feet. Ground marks (rings, lines, tracers) are in the first.
        for i = 1, #ACTIVE do
            local element = ACTIVE[i]
            if in_top_pass(element, e, view, tier) then
                element.draw(e, view)
            end
        end

        if (view.rows_below or view.covered) and e.kind == "unit" and tier >= 2 then
            draw_below(e, view, tier)
        end
    end

    --- Per-frame values every element shares, read once rather than once per
    --- entity. The player's level is here because the difficulty colouring
    --- needs it for every mark and it cannot change mid-frame.
    ---@param quests_only? boolean Only quest and guide marks this frame, the
    ---  ESP being off (1.73.0): they leave out the ESP page's fight extras --
    ---  the cast bar, the ring and the line -- and its pillars (1.88.0).
    function M.begin_frame(quests_only)
        read_settings()
        if quests_only then
            S.show_cast, S.show_aggro, S.show_target_line, S.show_cast_ring = false, false, false, false
            S.show_beacon = false
            local off = LOOK.quests_only_off
            for i = 1, #ACTIVE do
                if off[ACTIVE[i].key] then ACTIVE[i].on = false end
            end
        end
        layout.full, layout.name, layout.hidden, layout.offscreen = 0, 0, 0, 0
        local player = units.player()
        -- A number or 0: a failed read used to leave pcall's error MESSAGE
        -- here, and the first comparison against it threw.
        local ok_level, level = false, nil
        if player then ok_level, level = pcall(player.get_level, player) end
        view.player_level = (ok_level and type(level) == "number") and level or 0

        -- Every cast bar on screen is measured against the same instant.
        local ok, now_ms = pcall(function() return core.game_time() end)
        view.now_ms = (ok and type(now_ms) == "number") and now_ms or 0
        local ok_s, now = pcall(function() return core.time() end)
        view.now = (ok_s and type(now) == "number") and now or 0

        placed_n = 0
        aggro_ring.last, aggro_ring.n = aggro_ring.n, 0
        power_reads = POWER_BUDGET
        plate_reads = PLATE_BUDGET
        if P.opt("esp_plate_mode", cfg.PLATE_BELOW) ~= cfg.PLATE_IGNORE then
            scan_plate_tokens(view.now)
        end

        -- The UI scale, once a second: the nameplate rectangle may be in UI
        -- units rather than pixels (see "nameplates").
        if (view.now - ui_scale_at) >= 1.0 then
            ui_scale_at = view.now
            local ok_ui, scale = pcall(function() return core.game_ui.get_effective_scale() end)
            ui_scale = (ok_ui and type(scale) == "number" and scale > 0) and scale or 1
        end

        -- The party, by guid, for "on <name>" and the amber lines. The group
        -- service holds the roster for the tick already; a member out of
        -- object range has no object and cannot be the end of a line anyway.
        for guid in pairs(group_names) do group_names[guid] = nil end
        local group = ctx.group
        if group and group.members
            and (P.opt("show_status", true) or P.opt("show_target_line", true)) then
            local ok_rows, rows = pcall(group.members)
            if ok_rows and type(rows) == "table" then
                for i = 1, #rows do
                    local row = rows[i]
                    local obj = type(row) == "table" and row.object or nil
                    local guid = obj and units.guid(obj) or nil
                    if guid then group_names[guid] = row.name or "" end
                end
            end
        end
    end

    ---@return table[] The elements that resolved to a drawer, in paint order.
    function M.active()
        return ACTIVE
    end

    return M
end
