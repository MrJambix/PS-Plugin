return function(rt)
    local M = {}
    function M.go(unit)
        local a = unit:get_health()  -- real
        local b = unit:get_helath()  -- typo
        local c = unit:is_moving()   -- real
        return a, b, c
    end
    return M
end
