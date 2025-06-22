local M = {}

function M.addBind(name, bind)
    M.binds[name] = bind
end

function M.bind(name)
    return function(client, position)
        M.current_bind = M.binds[name]

        if M.current_bind.start then
            M.current_bind.start(client, position)
        end
    end
end

local function move_mouse(move_data)
    if M.current_bind == nil then
        return false
    end

    if M.current_bind.move then
        M.current_bind.move(move_data)
    end

    return true
end

local function release_mouse()
    if M.current_bind == nil then
        return
    end

    if M.current_bind.release then
        M.current_bind.release()
    end

    M.current_bind = nil

    return true
end

function M.setup(config)
    session:add_hook("mouse_move", move_mouse)
    session:add_hook("mouse_release", release_mouse)

    M.binds = M.binds or {}
    M.current_bind = M.current_bind or nil
end

return M
