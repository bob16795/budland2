local M = {}

local function pt(pixels)
    return pixels * 1.3333
end

function M.set_font_pt(name, size)
    session:set_font(name, pt(size))
end

function M.reload()
    return function()
        package.loaded["init"] = nil
        require("init")
    end
end

function M.set_client_border(size)
    local size = size
    return function()
        local client = session:active_client()
        if client then
            client:set_border(size)
        end
    end
end

function M.toggle_floating(size)
    return function()
        local client = session:active_client()
        if client then
            client:set_floating(not client:get_floating())
        end
    end
end

function M.kill_client(tag)
    return function()
        local client = session:active_client()
        if client then
            client:close()
        end
    end
end

function M.set_monitor_tag(tag)
    local tag = tag
    return function()
        local monitor = session:active_monitor()
        if monitor then
            monitor:set_tag(tag)
        end
    end
end

function M.set_client_tag(tag)
    local tag = tag
    return function()
        local client = session:active_client()
        if client then
            client:set_tag(tag)
        end
    end
end

function M.set_client_stack(stack)
    local stack = stack
    return function()
        local client = session:active_client()
        if client then
            client:set_stack(stack)
        end
    end
end

function M.cycle_layout(direction)
    local direction = direction
    return function()
        local monitor = session:active_monitor()
        if monitor then
            local layout = monitor:get_layout()
            monitor:set_layout(layout + direction)
        end
    end
end

function M.cycle_focus(direction)
    local direction = direction
    return function()
        session:cycle_focus(direction)
    end
end

function M.spawn(program, args)
    local program = program
    local args = args
    return function()
        session:spawn(program, args)
    end
end

function M.quit()
    return function()
        session:quit(program, args)
    end
end

return M
