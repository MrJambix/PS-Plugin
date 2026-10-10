-- Jambix Debug -- the developer's tools for JCore and Jambix AIO.
--
-- Not shipped to users. JCore and Jambix AIO run the same without this
-- folder; with it they gain the API recorder, the Dump page, the loot study
-- and the AIO's Debug page. See main.lua.

local plugin = {}

plugin["name"] = "Jambix Debug"
plugin["version"] = "1.0.0"
plugin["author"] = "jambix"

-- Boolean. The loader type-checks this key and reports a function as though
-- the key were missing entirely.
plugin["load"] = true

return plugin
