return function(rt)
    -- factory scope: captures nil, because cache is built after this module
    local cache = rt.cache
    local M = {}
    function M.go()
        local x = rt.ghost.thing()                  -- never built
        local y = core.spell_book.get_spell_nmae(1) -- typo'd core path
        local z = mathh.floor(1.5)                  -- undefined global
        return x, y, z
    end
    return M
end
