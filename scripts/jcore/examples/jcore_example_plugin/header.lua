-- Example consumer. Lives under jcore/examples/ so the loader does not pick it
-- up as a package; copy the folder up to scripts/ to actually run it.

local plugin = {}

plugin["name"] = "JCore Example"
plugin["version"] = "1.0.0"
plugin["author"] = "jambix"

-- Boolean, not a function. See the note in jcore/header.lua.
plugin["load"] = true

return plugin
