-- JCore - shared runtime other plugins talk to.
--
-- This is a LIBRARY package. It owns no gameplay behaviour of its own: it boots
-- a runtime, publishes it as `_G.JCore` (and as a `require`-able module), and
-- every other plugin registers against it.
--
-- LOAD ORDER
-- The loader gives no way to force a library ahead of its consumers, so do not
-- rely on one. Consumers guard against a nil `_G.JCore` and start when it
-- appears; see examples/jcore_example_plugin/main.lua for the bootstrap that
-- makes a plugin load-order independent.

local plugin = {}

plugin["name"] = "JCore"
plugin["version"] = "1.7.9"
plugin["author"] = "jambix"

-- Must be a BOOLEAN. The loader reads this key by type, and a function here is
-- rejected with "table returned by header.lua doesn't contain a key named:
-- load" -- which reads like the key is missing rather than the wrong type.
plugin["load"] = true

return plugin
