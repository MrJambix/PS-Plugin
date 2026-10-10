return function(rt)
    local M = {}
    function M.oops()
        if true then
            return 1
    end          -- the `if` is never closed
    return M
end
