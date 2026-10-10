-- On request only: decodes texture files from the installed addons and
-- writes each as a scaled-up PNG under tools/jtest/out/probe/, so a stand-in
-- for the game's own art can be looked at before a mark uses it.
--
--   JTEST_PROBE=1 JTEST_FILES="Plater/media/x_64.tga;Questie/Icons/icon_horde.tga"
--   node tools/jtest/run.js addon_art_probe
--
-- Paths are relative to the client's Interface/AddOns folder.

if not jtest.env("JTEST_PROBE") then
    print("    (skipped: set JTEST_PROBE=1 and JTEST_FILES to decode addon textures)")
    return {}
end

local image = require("jcore/lib/image")
local ADDONS = (jtest.env("JTEST_WOW") or "C:/Program Files (x86)/World of Warcraft")
    .. "/" .. (jtest.env("JTEST_PRODUCT") or "_classic_era_") .. "/Interface/AddOns/"

local files = {}
for p in (jtest.env("JTEST_FILES") or ""):gmatch("[^;]+") do files[#files + 1] = p end

local function upscale(img, factor)
    if factor <= 1 then return img.rows, img.w, img.h end
    local rows = {}
    for y = 1, img.h do
        local src, out = img.rows[y], {}
        for x = 1, img.w do out[#out + 1] = src:sub((x - 1) * 4 + 1, x * 4):rep(factor) end
        local line = table.concat(out)
        for _ = 1, factor do rows[#rows + 1] = line end
    end
    return rows, img.w * factor, img.h * factor
end

local T = {}

T[#T + 1] = { "decode the addon textures", function()
    for i = 1, #files do
        local rel = files[i]
        local size = jtest.file_size(ADDONS .. rel)
        if size <= 0 then
            print("      missing: " .. rel)
        else
            local bytes = jtest.read_partial(ADDONS .. rel, 0, size)
            local img, err
            if rel:lower():find("%.tga$") then
                img, err = image.decode_tga(bytes)
            else
                img, err = image.decode_blp(bytes, { max_dim = 256 })
            end
            if not img then
                print("      undecodable: " .. rel .. " (" .. tostring(err) .. ")")
            else
                local factor = math.max(1, math.floor(256 / math.max(img.w, img.h)))
                local rows, w, h = upscale(img, factor)
                local name = rel:gsub("/", "_"):gsub("%.%w+$", ".png")
                jtest.write_file("probe/addon_" .. name, image.encode_png(rows, w, h))
                print(string.format("      %s  %dx%d -> probe/addon_%s", rel, img.w, img.h, name))
            end
        end
    end
end }

return T
