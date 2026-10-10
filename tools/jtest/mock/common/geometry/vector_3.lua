-- Mock of common/geometry/vector_3 for the offline harness.

local Vec3 = {}
Vec3.__index = Vec3

local function new(x, y, z)
    return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, Vec3)
end

function Vec3.__add(a, b) return new(a.x + b.x, a.y + b.y, a.z + b.z) end
function Vec3.__sub(a, b) return new(a.x - b.x, a.y - b.y, a.z - b.z) end
function Vec3.__eq(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
function Vec3:__tostring() return string.format("vec3(%s,%s,%s)", tostring(self.x), tostring(self.y), tostring(self.z)) end
function Vec3:length() return math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z) end
function Vec3:dist_to(o) return math.sqrt((self.x - o.x) ^ 2 + (self.y - o.y) ^ 2 + (self.z - o.z) ^ 2) end

return { new = new }
