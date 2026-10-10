-- LIVE, and only on request: pulls candidate UI art out of the real client's
-- archives and writes each as a PNG under tools/jtest/out/probe/, scaled up so
-- it can be looked at. The point is to SEE a texture -- where an emblem sits
-- in its square, which corner of a sheet holds which icon -- before any mark
-- is built on coordinates guessed from memory.
--
--   JTEST_LIVE=1 JTEST_PROBE=1 node tools/jtest/run.js casc_probe_art
--
-- Paths it cannot find are listed, not failed: finding out which exist is the
-- other half of the point.

if not (jtest.env("JTEST_LIVE") and jtest.env("JTEST_PROBE")) then
    print("    (skipped: set JTEST_LIVE=1 and JTEST_PROBE=1 to extract art for inspection)")
    return {}
end

local mock = require("mock_core")
mock.install()

local WOW = jtest.env("JTEST_WOW") or "C:/Program Files (x86)/World of Warcraft"
local inflate = require("jcore/lib/inflate")
local image = require("jcore/lib/image")
local make_casc = require("jcore/services/casc")

local function real(path) return WOW .. "/" .. tostring(path):gsub("\\", "/") end
core.read_file = function(path) return jtest.read_file(real(path)) end
core.read_file_partial = function(path, offset, size) return jtest.read_partial(real(path), offset, size) end
core.get_file_size = function(path) return jtest.file_size(real(path)) end

local store = { data = {} }
function store:touch() end
local casc = make_casc({
    inflate = inflate,
    storage = { store = function() return store end },
    log = { for_tag = function() return { fmt = function() end } end },
})

local CANDIDATES = (jtest.env("JTEST_PROBE_PATHS") or ""):gsub("%s", "")
local paths = {}
for p in CANDIDATES:gmatch("[^;]+") do paths[#paths + 1] = p end

--- Nearest-neighbour upscale so a 32px icon is big enough to judge.
local function upscale(img, factor)
    if factor <= 1 then return img.rows, img.w, img.h end
    local rows = {}
    for y = 1, img.h do
        local src = img.rows[y]
        local out = {}
        for x = 1, img.w do
            local px = src:sub((x - 1) * 4 + 1, x * 4)
            out[#out + 1] = px:rep(factor)
        end
        local line = table.concat(out)
        for _ = 1, factor do rows[#rows + 1] = line end
    end
    return rows, img.w * factor, img.h * factor
end

local T = {}

T[#T + 1] = { "extract the candidate art", function()
    assert(casc.available(), "archives not readable")
    for i = 1, #paths do casc.want(paths[i]) end
    -- The first read is what runs the root scan; lookup only answers after it.
    casc.read(paths[1], function() end)
    local found, missing = {}, {}
    for i = 1, #paths do
        local p = paths[i]
        if casc.lookup(p) then
            local bytes = casc.read(p)
            local img, err = bytes and image.decode_blp(bytes, { max_dim = 256 })
            if img then
                local factor = math.max(1, math.floor(256 / math.max(img.w, img.h)))
                local rows, w, h = upscale(img, factor)
                local name = p:gsub("^Interface/", ""):gsub("/", "_"):gsub("%.blp$", ".png")
                jtest.write_file("probe/" .. name, image.encode_png(rows, w, h))
                found[#found + 1] = string.format("%s  %dx%d -> probe/%s", p, img.full_w or img.w, img.full_h or img.h, name)
            else
                missing[#missing + 1] = p .. "  (does not decode: " .. tostring(err) .. ")"
            end
        else
            missing[#missing + 1] = p
        end
    end
    print("    found:")
    for i = 1, #found do print("      " .. found[i]) end
    print("    missing:")
    for i = 1, #missing do print("      " .. missing[i]) end
end }

return T
