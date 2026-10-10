-- LIVE: the casc service against a real WoW install, reading the client's
-- own archives through the same sandboxed calls the game hands the loader
-- (whole-file reads, byte-range reads, file sizes). Opt-in, because it needs
-- the game installed and a root scan takes a while under fengari:
--
--   set JTEST_LIVE=1              (PowerShell: $env:JTEST_LIVE = "1")
--   set JTEST_WOW=C:/Program Files (x86)/World of Warcraft   (the default)
--   node tools/jtest/run.js casc_live
--
-- It asks for every image the portraits use, in one scan, and reports which
-- ones this client build has. Extracted files land in tools/jtest/out/casc/.

if not jtest.env("JTEST_LIVE") then
    print("    (skipped: set JTEST_LIVE=1 to read a real WoW install)")
    return {}
end

local mock = require("mock_core")
mock.install()

local WOW = jtest.env("JTEST_WOW") or "C:/Program Files (x86)/World of Warcraft"
if jtest.file_size(WOW .. "/.build.info") == 0 then
    error("no .build.info under " .. WOW .. "; set JTEST_WOW")
end

local inflate = require("jcore/lib/inflate")
local image = require("jcore/lib/image")
local make_casc = require("jcore/services/casc")
local cfg = require("jambix_aio/modules/config")

-- The loader's three file natives, pointed at the real folder.
local function real(path) return WOW .. "/" .. tostring(path):gsub("\\", "/") end
core.read_file = function(path)
    local bytes = jtest.read_file(real(path))
    return bytes
end
core.read_file_partial = function(path, offset, size)
    return jtest.read_partial(real(path), offset, size)
end
core.get_file_size = function(path) return jtest.file_size(real(path)) end

local logged = {}
local store = { data = {} }
function store:touch() end
local casc = make_casc({
    inflate = inflate,
    storage = { store = function() return store end },
    log = { for_tag = function()
        return { fmt = function(level, f, ...)
            local line = level .. ": " .. string.format(f, ...)
            logged[#logged + 1] = line
            print("    [casc] " .. line)
        end }
    end },
})

local function strip(ref) return (ref:gsub("^game:", "")) end

-- Everything the portraits can ask the archives for.
local wanted, seen = {}, {}
local function want(path, why)
    if seen[path] then return end
    seen[path] = true
    wanted[#wanted + 1] = { path = path, why = why }
end
want(strip(cfg.GAME_CLASS_SHEET.ref), "class sheet")
want(strip(cfg.GAME_ROLE_SHEET.ref), "role circles")
for name in pairs(cfg.CLASS_RGB) do
    want(strip(cfg.game_icon("classicon_" .. name:lower())), "class icon " .. name)
end
for spec, slug in pairs(cfg.SPEC_ICON) do want(strip(cfg.game_icon(slug)), "spec " .. spec) end
for id, slug in pairs(cfg.CREATURE_ICON) do want(strip(cfg.game_icon(slug)), "creature type " .. id) end
for index in pairs(cfg.RAID_MARKERS) do want(strip(cfg.raid_marker_ref(index)), "raid marker " .. index) end
for key, tag in pairs(cfg.TAGS) do
    for i = 1, #tag.art do
        local ref = tag.art[i][1]
        if ref:find("^game:") then want(strip(ref), "tag " .. key) end
    end
end
for name, sheet in pairs(cfg.GAME_UI_SHEETS) do want(strip(sheet.ref), "ui sheet " .. name) end
for name, ref in pairs(cfg.GAME_UI) do want(strip(ref), "ui " .. name) end
for kind, slug in pairs(cfg.NODE_ICON) do want(strip(cfg.game_icon(slug)), "node " .. kind) end
table.sort(wanted, function(a, b) return a.path < b.path end)

local T = {}

T[#T + 1] = { "the client's build is found", function()
    local ok, why = casc.available()
    assert(ok, tostring(why))
    local b = casc.build()
    print(string.format("    product %s, version %s, build key %s", b.product, b.version, b.key))
end }

T[#T + 1] = { "one root scan resolves every portrait image", function()
    for i = 1, #wanted do casc.want(wanted[i].path) end
    local t0 = jtest.clock()
    local steps = 0
    local first, err = casc.read(wanted[1].path, function() steps = steps + 1 end)
    local secs = jtest.clock() - t0
    assert(first, "first read: " .. tostring(err))
    local s = casc.stats()
    print(string.format("    root v%s, %d blocks, scan + first read %.1fs under fengari, %d yields",
        tostring(s.root_version), s.root_blocks or 0, secs, steps))
    assert(s.scans == 1, "one scan, got " .. s.scans)
    assert(s.known + s.missing == #wanted, string.format("every path answered: %d known + %d missing of %d",
        s.known, s.missing, #wanted))
end }

T[#T + 1] = { "every resolved image extracts and decodes", function()
    local have, missing = {}, {}
    for i = 1, #wanted do
        local w = wanted[i]
        local entry = casc.lookup(w.path)
        if entry then
            local bytes, err = casc.read(w.path)
            assert(bytes, w.path .. ": " .. tostring(err))
            assert(bytes:sub(1, 4) == "BLP2", w.path .. " is not a BLP2")
            local img, derr = image.decode_blp(bytes, { max_dim = 64 })
            assert(img, w.path .. " does not decode: " .. tostring(derr))
            jtest.write_file("casc/" .. w.path:match("([^/]+)$"), bytes)
            have[#have + 1] = string.format("%s (%dx%d, fdid %d)", w.path:match("([^/]+)$"), img.full_w or img.w,
                img.full_h or img.h, entry.fdid)
        else
            missing[#missing + 1] = w.path:match("([^/]+)$") .. " [" .. w.why .. "]"
        end
    end
    print(string.format("    %d image(s) in this build:", #have))
    for i = 1, #have do print("      " .. have[i]) end
    print(string.format("    %d not in this build (the portrait falls through for these):", #missing))
    for i = 1, #missing do print("      " .. missing[i]) end
    assert(casc.stats().scans == 1, "no second scan")
end }

T[#T + 1] = { "the sheets the portraits draw from are there", function()
    assert(casc.lookup(strip(cfg.GAME_CLASS_SHEET.ref)), "class sheet missing from this build")
    assert(casc.lookup(strip(cfg.GAME_ROLE_SHEET.ref)), "role circle sheet missing from this build")
    local classic = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
    for i = 1, #classic do
        assert(casc.lookup(strip(cfg.game_icon("classicon_" .. classic[i]:lower()))),
            "classicon for " .. classic[i] .. " missing")
    end
end }

T[#T + 1] = { "the eight raid marker icons are there", function()
    for index in pairs(cfg.RAID_MARKERS) do
        assert(casc.lookup(strip(cfg.raid_marker_ref(index))),
            "raid marker " .. index .. " (" .. cfg.RAID_MARKERS[index].name .. ") missing")
    end
end }

T[#T + 1] = { "every tag chip's icon is there: game icons in the archives, addon icons on disk", function()
    local product = jtest.env("JTEST_PRODUCT") or "_classic_era_"
    local found, missing = {}, {}
    for key, tag in pairs(cfg.TAGS) do
        for i = 1, #tag.art do
            local ref, addon = tag.art[i][1], tag.art[i][2]
            if ref:find("^game:") then
                if casc.lookup(strip(ref)) then found[#found + 1] = key .. " " .. ref
                else missing[#missing + 1] = key .. " " .. ref end
            elseif ref:find("^addon:") then
                local path = WOW .. "/" .. product .. "/Interface/AddOns/" .. ref:gsub("^addon:", "")
                local size = jtest.file_size(path)
                if size > 0 then
                    local bytes = jtest.read_partial(path, 0, size)
                    local img, err = image.decode_blp(bytes, { max_dim = 64 })
                    assert(img, ref .. " does not decode: " .. tostring(err))
                    found[#found + 1] = string.format("%s %s (%dx%d)", key, ref, img.full_w or img.w, img.full_h or img.h)
                else
                    missing[#missing + 1] = key .. " " .. ref .. " (" .. addon .. " not installed?)"
                end
            end
        end
    end
    print("    tag icons found:")
    for i = 1, #found do print("      " .. found[i]) end
    print("    tag icons missing:")
    for i = 1, #missing do print("      " .. missing[i]) end
    assert(#missing == 0, #missing .. " tag icon(s) missing")
end }

T[#T + 1] = { "the game's own UI art the marks use is all there", function()
    local missing = {}
    for name, sheet in pairs(cfg.GAME_UI_SHEETS) do
        if not casc.lookup(strip(sheet.ref)) then missing[#missing + 1] = "sheet " .. name end
    end
    for name, ref in pairs(cfg.GAME_UI) do
        if not casc.lookup(strip(ref)) then missing[#missing + 1] = name end
    end
    for kind, slug in pairs(cfg.NODE_ICON) do
        if not casc.lookup(strip(cfg.game_icon(slug))) then missing[#missing + 1] = "node " .. kind end
    end
    assert(#missing == 0, "missing: " .. table.concat(missing, ", "))
end }

return T
