-- Builds `broken` BEFORE `cache`, which is the ordering bug the wiring pass
-- exists to catch. `ghost` is never built at all.
local rt = { VERSION = "1", started_at = 0, ready = false }
local function build_module(p) return require(p)(rt) end
rt.util = build_module("lib/util")
rt.broken = build_module("services/broken")
rt.cache = build_module("lib/cache")
