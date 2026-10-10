-- Mock of common/geometry/vector_2 for the offline harness.

local Vec2 = {}
Vec2.__index = Vec2

local function new(x, y)
    return setmetatable({ x = x or 0, y = y or 0 }, Vec2)
end

function Vec2.__add(a, b) return new(a.x + b.x, a.y + b.y) end
function Vec2.__sub(a, b) return new(a.x - b.x, a.y - b.y) end
function Vec2.__eq(a, b) return a.x == b.x and a.y == b.y end
function Vec2:__tostring() return string.format("vec2(%s,%s)", tostring(self.x), tostring(self.y)) end
function Vec2:length() return math.sqrt(self.x * self.x + self.y * self.y) end
function Vec2:dist_to(o) return math.sqrt((self.x - o.x) ^ 2 + (self.y - o.y) ^ 2) end

return { new = new }
