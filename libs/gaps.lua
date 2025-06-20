local M = {}

local function update_gaps()
    local set_gaps_value = 0
    if M.gaps_toggle then
        set_gaps_value = M.gaps_value
    end

    local monitor = session:active_monitor()
    if monitor then
        monitor:set_inner_gaps(set_gaps_value)
        monitor:set_outer_gaps(set_gaps_value * M.gaps_ratio + M.gaps_outer)
    end
end

function M.toggle()
    M.gaps_toggle = not M.gaps_toggle

    update_gaps()
end

function M.get()
    return M.gaps_value
end

function M.set(value)
    M.gaps_value = value
    if M.gaps_value < 0 then
        M.gaps_value = 0
    end

    update_gaps()
end

function M.increase()
    M.set(M.gaps_value + M.gaps_inc)
end

function M.decrease()
    M.set(M.gaps_value - M.gaps_inc)
end

function M.setup(config)
    if M.init then
        return
    end

    M.gaps_inc = config.inc or 0
    M.gaps_toggle = config.toggle or false
    M.gaps_value = config.value or 20
    M.gaps_ratio = config.ratio or 1.0
    M.gaps_outer = config.outer or 0.0
    M.init = true

    session:add_hook("add_monitor", function(monitor)
        local set_gaps_value = 0
        if M.gaps_toggle then
            set_gaps_value = M.gaps_value
        end

        monitor:set_inner_gaps(set_gaps_value)
        monitor:set_outer_gaps(set_gaps_value * M.gaps_ratio + M.gaps_outer)
    end)

    update_gaps()
end

return M
