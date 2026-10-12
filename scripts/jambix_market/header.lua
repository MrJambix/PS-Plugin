-- Jambix Market -- auction house scanner and trader for WoW Forever, on JCore.
--
-- Scans the auction house, works out what things are worth and what sells,
-- finds what is worth buying and posts what you carry. Forever only: on any
-- other client it registers, says so on its page, and does nothing.

local plugin = {}

plugin["name"] = "Jambix Market"
plugin["version"] = "1.2.5"
plugin["author"] = "jambix"

-- Boolean. The loader type-checks this key and reports a function as though
-- the key were missing entirely.
plugin["load"] = true

return plugin
