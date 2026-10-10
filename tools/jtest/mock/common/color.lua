-- Mock of the shipped common/color module for the offline harness.
-- A colour is a plain { r, g, b, a } table carrying a metatable, which is
-- what draw.lua and ui.lua test for (getmetatable ~= nil).

local Color = {}
Color.__index = Color

local function new(r, g, b, a)
    return setmetatable({ r = r or 255, g = g or 255, b = b or 255, a = a or 255 }, Color)
end

function Color:get()
    return self.r, self.g, self.b, self.a
end

function Color:__tostring()
    return string.format("color(%d,%d,%d,%d)", self.r, self.g, self.b, self.a)
end

local M = { new = new }

local named = {
    white = { 255, 255, 255 }, black = { 0, 0, 0 }, red = { 255, 0, 0 }, green = { 0, 255, 0 },
    blue = { 0, 0, 255 }, yellow = { 255, 255, 0 }, cyan = { 0, 255, 255 }, magenta = { 255, 0, 255 },
    orange = { 255, 165, 0 }, purple = { 128, 0, 128 }, gray = { 128, 128, 128 }, grey = { 128, 128, 128 },
    pink = { 255, 192, 203 }, brown = { 165, 42, 42 },
}
for name, rgb in pairs(named) do
    M[name] = function(a) return new(rgb[1], rgb[2], rgb[3], a or 255) end
end

-- Any other colour name answers a white with the requested alpha, so a
-- module probing for an exotic name still gets a colour back.
setmetatable(M, {
    __index = function(_, key)
        if type(key) ~= "string" then return nil end
        return function(a) return new(255, 255, 255, a or 255) end
    end,
})

return M
