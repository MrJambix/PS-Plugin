-- Jambix AIO -- world overlay built on JCore.
--
-- Consumes the core's shared object-manager sweep and its layered draw queue.
-- It makes no object-manager calls and no core.graphics calls of its own; see
-- the note at the top of main.lua for why that matters.

local plugin = {}

plugin["name"] = "Jambix AIO"
plugin["version"] = "1.7.6"
plugin["author"] = "jambix"

-- Boolean. The loader type-checks this key and reports a function as though
-- the key were missing entirely.
plugin["load"] = true

return plugin
