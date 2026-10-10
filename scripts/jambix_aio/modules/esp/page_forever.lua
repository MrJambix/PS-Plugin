-- Jambix AIO / esp/page_forever -- the Forever ESP's page (1.69.0).
--
-- The user, 2026-10-04: "better customization of Simple and Advanced", and
-- they chose a Style and a grid of what to show. main.lua builds this page in
-- place of the Classic ESP's sections when the client is Forever; the Classic
-- ESP keeps its own page until it moves to the icon card too.
--
-- SIMPLE, always shown:
--   ESP           on, the toggle key, the Style, range, text size
--   In a fight    cast bars, the rings, the lines, threat panel, telegraphs,
--                 alerts
--   Enemies / World / Friends   one switch per category; under World, herbs
--                 and ore only by your skill (1.88.0)
-- QUEST MARKS are the Quests page's since 1.73.0 ("Enable quest ESP"), and
-- show with this page's "Enable ESP" off too, so this page has no quest row.
-- ADVANCED, with "Show advanced settings" on (the Jambix AIO page):
--   What a mark shows   every piece (cfg.ESP_PIECES) with its own switch
--   Look                colour mode, the soft cards, bars, boxes, the
--                       beacons, the mark limit
--   Each category       what its mark shows (everything / icon, name, health
--                       and casts / icon only), its range, its colour
--   Alerts, Telegraphs  the fine tuning
--
-- THE STYLE writes every piece at once. Changing a piece by hand makes it
-- Custom -- but only when the pieces really differ from the Style, so a host
-- that reports the Style's own writes a frame later does not undo it.
--
-- EVERY ID IS THE ONE IT ALWAYS WAS. Widgets are saved by page and id, and
-- this is the same page ("Forever ESP"), so every value set before 1.69.0 is
-- kept; only where a widget sits changed. New ids: esp_style, show_icon,
-- show_title, show_corpse_name, <key>_detail.
--
-- THE NEW LOOK (1.88.0). The user, 2026-10-08: "Take all ESPs and convert it
-- to this!" New ids: esp_shader_look ("Soft cards and bars"), esp_beacons and
-- esp_beacon_from (a pillar over a far rare, boss, quest mark or corpse to
-- loot), gather_skill_only (herbs and ore by your skill). The box style's
-- default is the curtain (cfg.BOX_DEFAULT), and the corners the menu saved
-- as everyone's value move to it once (see THE CURTAIN BOX below). 1.7.6:
-- the corners are the default again (curtains are off by default), so that
-- move no longer runs; main.lua's CURTAINS moves a saved curtain back once.
--
-- HUNTERS (1.7.6). The user, 2026-10-09: "I'd like an ESP on beasts as a
-- Hunter class that shows me the image and name of the ability and rank it
-- is ... give me an option to turn it off too in the esp". New ids:
-- show_pet_skills (the rows under a tameable beast) and pet_skill_guesses
-- (its family's skills nobody has confirmed, with "?"). The section shows
-- for hunters only. See WHAT A BEAST TEACHES in esp/forever.lua.
--
-- SKINNING (1.7.6). The user, 2026-10-10: "I want ESP now to show similar
-- thing for What skinable corpse can give me by % if its multiple items".
-- New id: show_skin_loot, under World. See WHAT SKINNING GIVES in
-- esp/forever.lua.
--
-- PRISTINE (1.7.6). The user, 2026-10-10: "Let's add Mobs that when skined
-- also give pristine cause i dont see any so far". New id: show_pristine,
-- under World. See PRISTINE in esp/forever.lua.
--
-- EXPERIENCE BARS (1.7.6). The user, 2026-10-10: "a moveable EXP Bar that
-- show's Exp/hour counts how much EXP going to get and fills the bar once
-- completed quests are Turned in and one that does the same but for all
-- quests in my Questlog", then "Make it ESP not like a UI", "also more
-- readable". New ids: xpbar_ready, xpbar_log (one bar each), xpbar_move (a
-- handle to drag each by), xpbar_text_size, xpbar_width, xpbar_rate_minutes,
-- the xpbar_reset button. See modules/xpbar.lua.

return function(P, esp, env)
    local ctx, cfg = P.ctx, P.cfg
    local advanced = env.advanced
    local ADV = { visible = advanced }
    local PIECES = cfg.ESP_PIECES
    local CLEAN, CUSTOM = cfg.STYLE_CLEAN, cfg.STYLE_CUSTOM

    -- --- simple -------------------------------------------------------------------

    local main = esp:section("ESP", "eye", { column = "left" })
    main:toggle("enabled", "Enable ESP", true)
    main:label("Quest marks and RestedXP are the Quests page's: they show with")
    main:label("the ESP off too. The toggle key hides everything.")
    main:keybind("toggle_key", "Toggle key", 0x5A, {
        mode = "toggle", modes = { "toggle", "hold" }, default_active = true,
    })
    main:dropdown("esp_style", "Style", cfg.ESP_STYLES, CLEAN)
    main:label("Minimal: icon, name, health. Clean: also level, distance, how it")
    main:label("fights. Detailed: also health numbers, boxes, corpse names.")
    main:slider("max_range", "Range", 20, 200, 150, "yd")
    main:slider("text_size", "Text size", 9, 22, 13, "px")
    main:label("Every piece, and how much each category shows: switch on")
    main:label("Show advanced settings on the Jambix AIO page.")

    local fight = esp:section("In a fight", "swords", { column = "right" })
    fight:toggle("show_cast", "Cast bars (the shield: cannot be interrupted)", true)
    fight:toggle("show_cast_ring", "Ring on the ground filling as a cast runs (purple: kick it)", true)
    fight:toggle("show_aggro", "Ring under anything on you (red) or yours (amber)", true)
    fight:toggle("show_target_line", "Line from anything coming at you", true)
    fight:toggle("alert_panel", "Threat panel", true)
    fight:toggle("tele_on", "Telegraphs: the ground a spell is about to hit", true)
    fight:toggle("alerts_on", "Alerts for dangerous mobs and players", true)
    fight:toggle("alert_sound", "Alert sound", true)

    -- The grid of what to show: each category's own switch, the same ids
    -- the Classic ESP's Categories section declares. Not quest targets: those
    -- are the Quests page's (1.73.0).
    local LABEL = {
        normal = "Normal mobs", corpse = "Corpses to loot or skin",
        friendly_npc = "Town NPCs: vendors, trainers, flight masters",
        object = "Other objects you can use",
    }
    local GRID = {
        { "Enemies", "swords", "left", { "normal", "elite", "rare", "boss", "hostile_player", "critter" } },
        { "World", "leaf", "right", { "corpse", "herb", "ore", "container", "object" } },
        { "Friends", "list", "full", { "friendly_npc", "pet", "party", "friendly_player" } },
    }
    for g = 1, #GRID do
        local row = GRID[g]
        local section = esp:section(row[1], row[2], { column = row[3] })
        for i = 1, #row[4] do
            local c = cfg.CATEGORY_BY_KEY[row[4][i]]
            if c then section:toggle(c.key .. "_on", LABEL[c.key] or c.label, c.on) end
        end
        if row[1] == "World" then
            -- 1.88.0: "Only Show Gatherables that I can Gather with my skills".
            section:toggle("gather_skill_only", "Only herbs and ore I can gather", true)
            section:label("No Herbalism or Mining: not marked. Skill too low:")
            section:label("dimmed, with (Requires Skill N).")
            -- 1.7.6: "What skinable corpse can give me by % if its multiple items".
            section:toggle("show_skin_loot", "Skinnable corpses: what skinning gives, with chances", true)
            section:label("Under the pelt: each item's icon, name and chance, from Classic's")
            section:label("tables. Forever's own creatures show the pelt alone.")
            -- 1.7.6: "Let's add Mobs that when skined also give pristine".
            section:toggle("show_pristine", "Pristine Leather / Hide / Scale: mobs that can give it", true)
            section:label("Under the mob and its corpse when you have Skinning; dimmed above")
            section:label("your skill. Seen in Forever's QuestieDB or your skins; chance unknown.")
        end
    end

    -- 1.7.6: what a tameable beast teaches (HUNTERS above).
    local function hunter()
        local tame = P.tame
        if not (tame and tame.hunter) then return false end
        local ok, yes = pcall(tame.hunter)
        return ok and yes == true
    end
    local hunters = esp:section("Hunters", "paw", { column = "full", visible = hunter })
    hunters:toggle("show_pet_skills", "Abilities a tameable beast teaches: icon, name and rank", true)
    hunters:label("Violet: Petopia lists that beast for it, or you saw it used. 'new' in")
    hunters:label("green: above your pet's rank. Above your level: dimmed, 'tame at N'.")
    hunters:toggle("pet_skill_guesses", "Also its family's abilities nobody has confirmed, with '?'", true)
    hunters:label("Forever's own abilities (Dismember, Savage Rend, Web...) have no known")
    hunters:label("teacher yet: shown dimmed at the rank its level carries.")

    -- 1.7.6: two experience bars you drag about (EXPERIENCE BARS above).
    local xp = esp:section("Experience bars", "activity", { column = "full" })
    xp:toggle("xpbar_ready", "XP bar: what your finished quests give when handed in", true)
    xp:toggle("xpbar_log", "XP bar: what your whole quest log gives", true)
    xp:label("Drawn by the ESP: they hide with it and its toggle key. Purple is your")
    xp:label("experience, gold what your finished quests add, blue the rest of your log.")
    xp:label("Put the cursor on a bar for its quests. '~': an estimate, for Forever's own")
    xp:label("quests, at the usual pay for their level until you hand one in.")
    xp:toggle("xpbar_move", "Move the XP bars: drag the handle above each", false)
    xp:label("Switch it off when they sit where you want them; they stay there.")
    xp:slider("xpbar_text_size", "Text size", 11, 26, 16, "px")
    xp:slider("xpbar_width", "Bar width", 260, 900, 460, "px")
    xp:label("A bar is never narrower than its words need.")
    xp:slider("xpbar_rate_minutes", "XP per hour over the last", 5, 120, 30, "min")
    xp:button("xpbar_reset", "Start XP per hour again", {
        on_click = function() if P.xpbar then P.xpbar.reset() end end,
    })

    -- --- advanced -------------------------------------------------------------------

    local pieces = esp:section("What a mark shows", "widgets", { column = "left", visible = advanced })
    pieces:label("The Style sets these; change one and it reads Custom.")
    for i = 1, #PIECES do
        local p = PIECES[i]
        pieces:toggle(p.id, p.label, p.styles[CLEAN] == true)
    end

    local look = esp:section("Look", "settings", { column = "right", visible = advanced })
    look:dropdown("unit_color_mode", "Colour names by", cfg.COLOR_MODES, cfg.COLOR_MODE_REACTION)
    look:toggle("grey_tapped", "Grey out mobs someone else has tagged", true)
    -- 1.88.0: soft plates and shaded bars; the game's bar texture is only
    -- drawn with them off.
    look:toggle("esp_shader_look", "Soft cards and bars", true)
    look:toggle("game_bars", "Health bars in the game's own texture", true, {
        visible = function() return advanced() and P.opt("esp_shader_look", true) == false end,
    })
    look:toggle("bar_always", "Health bars at full health too", false)
    look:toggle("show_health_exact", "Health numbers as 120/300, not 40%", false)
    look:slider("bar_width", "Health bar width", 24, 120, 54, "px")
    look:slider("bar_height", "Health bar height", 2, 10, 4, "px")
    look:dropdown("box_style", "Box style", cfg.BOX_STYLES, cfg.BOX_DEFAULT or cfg.BOX_CORNERS)
    look:slider("lod_full_range", "Boxes out to", 10, 120, 45, "yd")
    -- 1.7.6: off by default. A beacon is JCore's narrow curtain, and the
    -- user, 2026-10-10: "enemies should not have Curtain up by default".
    look:toggle("esp_beacons", "Beacons over far rares, bosses, quests and loot", false)
    look:slider("esp_beacon_from", "Beacons from", 10, 150, 40, "yd")
    look:slider("esp_max_marks", "Most things marked at once", 0, 300, 60, "")
    look:label("0: no limit. Your target, bosses, rares and quest targets first.")

    local cats = esp:section("Each category", "list", { column = "full", searchable = true, visible = advanced })
    cats:toggle("auto_ranges", "Every category out to the Range above", true)
    cats:label("Off: each category's own range, below.")
    for i = 1, #cfg.CATEGORIES do
        local c = cfg.CATEGORIES[i]
        -- Guide targets need RestedXP, which Forever does not have.
        if c.key ~= "guide" then
            local name = LABEL[c.key] or c.label
            cats:dropdown(c.key .. "_detail", name .. ": shows", cfg.DETAILS, cfg.CATEGORY_DETAIL[c.key] or cfg.DETAIL_FULL)
            cats:slider(c.key .. "_range", name .. ": range", 5, 200, c.range, "yd", {
                visible = function() return advanced() and not P.opt("auto_ranges", true) end,
            })
            cats:color_picker(c.key .. "_color", name .. ": colour",
                { r = c.rgb[1], g = c.rgb[2], b = c.rgb[3], a = 255 })
        end
    end

    local alerts = esp:section("Alerts", "alert", { column = "left", visible = advanced })
    alerts:toggle("alert_players", "Hostile players", true)
    alerts:slider("alert_player_range", "Player alert range", 10, 200, 60, "yd")
    alerts:toggle("alert_elites", "Elites, and mobs above my level", true)
    alerts:slider("alert_elite_range", "Elite alert range", 10, 100, 35, "yd")
    alerts:slider("alert_level_delta", "Levels above mine that count", 0, 15, 2, "lv")
    alerts:toggle("alert_arrows", "Arrows for threats off screen", false)
    alerts:toggle("alert_toast", "Show a notification", false)
    alerts:slider("alert_cooldown", "Re-alert cooldown", 2, 60, 15, "s")

    local tele = esp:section("Telegraphs", "alert", { column = "right", visible = advanced })
    tele:dropdown("tele_who", "Show telegraphs for", cfg.TELE_WHO, 1)
    tele:dropdown("tele_where", "Show telegraphs in", cfg.TELE_WHERE, 1)
    tele:toggle("tele_players", "Hostile players' spells too", true)
    tele:slider("tele_range", "Range", 20, 100, 60, "yd")
    tele:toggle("tele_labels", "Name, what to do and time left", true)
    tele:toggle("tele_alerts", "Alerts at the top of the screen", true)
    tele:toggle("tele_wall", "A wall rising round its edge as it lands", false)
    tele:slider("tele_fill", "Fill strength", 0, 50, 15, "%")
    tele:toggle("tele_missiles", "Where missiles land", true, ADV)
    tele:toggle("tele_linger", "Ground that stays bad (Flamestrike, Consecration)", true, ADV)

    -- --- the style ---------------------------------------------------------------------

    local function piece_value(p)
        local v = esp:get(p.id)
        if v == nil then return p.styles[CLEAN] == true end
        return v == true
    end

    --- Do the pieces read as this style sets them?
    local function matches(style)
        for i = 1, #PIECES do
            local p = PIECES[i]
            if piece_value(p) ~= (p.styles[style] == true) then return false end
        end
        return true
    end

    -- Set while the Style writes its pieces, so a host that reports each
    -- write at once does not read the half-written set as a hand change.
    local applying = false

    local function apply(style)
        applying = true
        for i = 1, #PIECES do
            local p = PIECES[i]
            local want = p.styles[style] == true
            if piece_value(p) ~= want then esp:set(p.id, want) end
        end
        applying = false
        if P.opt_invalidate then P.opt_invalidate() end
    end

    esp:on_change("esp_style", function(new)
        new = tonumber(new)
        if new and new ~= CUSTOM and cfg.ESP_STYLES[new] and not matches(new) then apply(new) end
    end)
    for i = 1, #PIECES do
        esp:on_change(PIECES[i].id, function()
            if applying then return end
            if P.opt_invalidate then P.opt_invalidate() end
            local style = tonumber(esp:get("esp_style")) or CLEAN
            if style ~= CUSTOM and not matches(style) then esp:set("esp_style", CUSTOM) end
        end)
    end

    -- THE ICON CARD ARRIVES (1.69.0), once per page. The menu saved every
    -- default as the player's value, so the one piece whose default changed --
    -- a health number beside the bar said the bar twice -- is moved while it
    -- still holds the old default. Then the Style is set to whichever style the
    -- pieces now read as (Clean for anyone who never touched them), else
    -- Custom. After that every switch is the player's.
    do
        local fixes = ctx.store and ctx.store("migrations") or nil
        local key = "esp_card_1:" .. tostring(esp.page_path or "Forever ESP")
        if fixes and fixes.data[key] ~= true and ctx.after then
            local tries = 0
            local function migrate()
                tries = tries + 1
                if esp:get("esp_style") == nil and tries < 5 then
                    ctx.after(2, migrate)
                    return
                end
                applying = true
                if esp:get("show_health_text") == true then esp:set("show_health_text", false) end
                applying = false
                -- Clean first: it is the default.
                local style = matches(CLEAN) and CLEAN or CUSTOM
                for s = 1, #cfg.ESP_STYLES do
                    if style ~= CUSTOM then break end
                    if s ~= CUSTOM and matches(s) then style = s end
                end
                esp:set("esp_style", style)
                fixes.data[key] = true
                fixes:touch()
                if P.opt_invalidate then P.opt_invalidate() end
                ctx.log.fmt("info", "ESP: the icon card -- style %s", tostring(cfg.ESP_STYLES[style]))
            end
            ctx.after(1, migrate)
        end
    end

    -- THE QUEST ROW LEAVES THIS PAGE (1.73.0), once. Quest marks follow the
    -- Quests page's "Enable quest ESP" alone now, so somebody who had
    -- switched "Quest targets" off here keeps them off: the saved value goes
    -- there. Read once the page's values are in (esp_style is set by then).
    do
        local fixes = ctx.store and ctx.store("migrations") or nil
        local quests_page = env.quests
        local key = "quest_row_1:" .. tostring(esp.page_path or "Forever ESP")
        if fixes and quests_page and fixes.data[key] ~= true and ctx.after then
            local tries = 0
            local function migrate()
                tries = tries + 1
                if esp:get("esp_style") == nil and tries < 5 then
                    ctx.after(2, migrate)
                    return
                end
                if esp:get("quest_on") == false and quests_page:get("questie_on") ~= false then
                    quests_page:set("questie_on", false)
                    ctx.log.info("ESP: quest marks were off on the ESP page; now off on the Quests page")
                end
                fixes.data[key] = true
                fixes:touch()
                if P.opt_invalidate then P.opt_invalidate() end
            end
            ctx.after(1, migrate)
        end
    end

    -- THE CURTAIN BOX (1.88.0), once. The user asked for every ESP in the new
    -- look, boxes as curtains, and the curtain is the default now -- but the
    -- menu saved the old default, the corners, as everyone's value, so it
    -- would never show. The corners move to the curtain once; anyone who
    -- wants them back picks them, and that is kept.
    do
        local fixes = ctx.store and ctx.store("migrations") or nil
        local key = "box_curtain_1:" .. tostring(esp.page_path or "Forever ESP")
        local to = cfg.BOX_DEFAULT
        if fixes and to and to ~= cfg.BOX_CORNERS and fixes.data[key] ~= true and ctx.after then
            local tries = 0
            local function migrate()
                tries = tries + 1
                if esp:get("esp_style") == nil and tries < 5 then
                    ctx.after(2, migrate)
                    return
                end
                if tonumber(esp:get("box_style")) == cfg.BOX_CORNERS then
                    esp:set("box_style", to)
                    ctx.log.fmt("info", "ESP: boxes are curtains now (%s)", tostring(cfg.BOX_STYLES[to]))
                end
                fixes.data[key] = true
                fixes:touch()
                if P.opt_invalidate then P.opt_invalidate() end
            end
            ctx.after(1, migrate)
        end
    end

    return { matches = matches, apply = apply }
end
