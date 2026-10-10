-- Minimal stand-in for scripts/.api/core.lua, just enough to exercise the
-- core-path pass. Only the namespaces the fixture touches need to be here.
---@class core
core = {}

function core.spell_book.get_spell_name(spell_id) end
function core.spell_book.get_spell_cooldown(spell_id) end
function core.object_manager.get_local_player() end
