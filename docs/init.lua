-- want gaps plz
gaps = require("conpositor.gaps")
funcs = require("conpositor.funcs")
mouse = require("conpositor.mouse")

-- add this first in case of crash
session:add_bind("AS", "Escape", funcs.quit())

-- some usefull consts
local force_debug = false
local terminal = "kitty"

-- load colorscheme and libraries
require("mondo.colors")

-- setup libraries
gaps.setup { inc = 2, toggle = true, value = 8, ratio = 2, outer = 30 }
mouse.setup {}

-- create my containers
stacks = { a = 1, b = 2, c = 3, d = 4, e = 5 }
tags = { session:new_tag("F1"), session:new_tag("F2"), session:new_tag("F3"), session:new_tag("F4") }

local function setup_abcd(root_container, ab_split, in_ac_split, in_bd_split, flip)
    local ac_split = in_ac_split
    local bd_split = in_bd_split
    if flip then
        ac_split = in_bd_split
        bd_split = in_ac_split
    end

    local bd_container = root_container:add_child(ab_split, 0.0, 1.0, 1.0)
    local ac_container = root_container:add_child(0.0, 0.0, ab_split, 1.0)

    local b_container = bd_container:add_child(0.0, 0.0, 1.0, bd_split)
    local d_container = bd_container:add_child(0.0, bd_split, 1.0, 1.0)

    local a_container = ac_container:add_child(0.0, 0.0, 1.0, ac_split)
    local c_container = ac_container:add_child(0.0, ac_split, 1.0, 1.0)
    if flip then
        a_container:set_stack(stacks.b)
        b_container:set_stack(stacks.a)

        c_container:set_stack(stacks.d)
        d_container:set_stack(stacks.c)
    else
        a_container:set_stack(stacks.a)
        b_container:set_stack(stacks.b)

        c_container:set_stack(stacks.c)
        d_container:set_stack(stacks.d)
    end
end

local default_layout = session:add_layout("+>+")
local center_layout = session:add_layout("+|+")
local lefty_layout = session:add_layout("+<+")
local default_layout_b = session:add_layout("->-")
local center_layout_b = session:add_layout("-|-")
local lefty_layout_b = session:add_layout("-<-")

setup_abcd(default_layout:root(), 0.7, 0.2, 0.4, false)
setup_abcd(center_layout:root(), 0.5, 0.2, 0.4, false)
setup_abcd(lefty_layout:root(), 0.3, 0.2, 0.4, false)

setup_abcd(lefty_layout_b:root(), 0.7, 0.2, 0.4, true)
setup_abcd(center_layout_b:root(), 0.5, 0.2, 0.4, true)
setup_abcd(default_layout_b:root(), 0.3, 0.2, 0.4, true)

local lefty_cycle = {
    { lefty_layout,   center_layout,   default_layout, },  -- normal
    { lefty_layout_b, center_layout_b, default_layout_b, } -- flip
}

local flip_cycle = {
    { lefty_layout,   lefty_layout_b },  -- lefty
    { center_layout,  center_layout_b }, -- center
    { default_layout, default_layout_b } -- default
}

-- functions for debugging
function debug_icon()
    local client = session:active_client()
    if client then
        local old_label = client:get_label() or "No label"
        if old_label:sub(1, 1) == "[" then
            local new = old_label:sub(2)
            new = new:sub(1, string.find(new, "]") - 1)

            if new == "No label" then
                client:set_label(nil)
            else
                client:set_label(new)
            end
        else
            client:set_label(
                "[" .. old_label .. "] title: '" .. client:get_title() .. "' appid: '" .. client:get_appid() .. "'")
        end
    end
end

-- mouse functions
local mouse_client = nil
local mouse_client_position = {}
local mouse_floating = false
mouse_resize = {}
mouse_resize.start = function(client, position)
    mouse_client = client
    mouse_client_position = client:get_position()
end
mouse_resize.move = function(position)
    mouse_client_position.width = position.x - mouse_client_position.x
    mouse_client_position.height = position.y - mouse_client_position.y

    mouse_client:set_position(mouse_client_position)
end

mouse_move = {}
mouse_move.start = function(client, position)
    mouse_client = client
    mouse_floating = client:get_floating()
    if mouse_floating then
        mouse_client_position = client:get_position()
        mouse_client_position.x = mouse_client_position.x - position.x
        mouse_client_position.y = mouse_client_position.y - position.y
    end
end
mouse_move.move = function(position)
    if mouse_floating then
        local pos = {}
        pos.x = mouse_client_position.x + position.x
        pos.y = mouse_client_position.y + position.y
        pos.width = mouse_client_position.width
        pos.height = mouse_client_position.height

        mouse_client:set_position(pos)
    else
        local monitor = session:active_monitor()
        local size = monitor:get_size()
        mouse_client:set_monitor(monitor)
        if position.y - size.y < 0.5 * size.height then
            if position.x - size.x < 0.5 * size.width then
                mouse_client:set_stack(stacks.a)
            else
                mouse_client:set_stack(stacks.b)
            end
        else
            if position.x - size.x < 0.5 * size.width then
                mouse_client:set_stack(stacks.c)
            else
                mouse_client:set_stack(stacks.d)
            end
        end
    end
end

local super = "L"
if force_debug or session.is_debug() then
    super = "A"
end

-- mousebinds
mouse.addBind("resize", mouse_resize)
mouse.addBind("move", mouse_move)

session:add_mouse(super, "Left", mouse.bind("move"))
session:add_mouse(super, "Right", mouse.bind("resize"))

-- programs
session:add_bind(super, "Return", funcs.spawn(terminal, { "--class=termA" }))
session:add_bind(super .. "S", "Return", funcs.spawn(terminal, { "--class=termB" }))
session:add_bind(super .. "C", "Return", funcs.spawn(terminal, { "--class=termB" }))
session:add_bind(super, "I", funcs.spawn(terminal, { "--class=htop", "-e", "htop" }))
session:add_bind(super, "M", funcs.spawn(terminal, { "--class=music", "-e", "kew" }))
session:add_bind(super, "R", funcs.spawn(terminal, { "--class=filesD", "-e", "ranger" }))
session:add_bind(super .. "S", "R", funcs.spawn(terminal, { "--class=filesB", "-e", "ranger" }))
session:add_bind(super, "V", funcs.spawn(terminal, { "--class=cava", "-e", "cava" }))

session:add_bind(super .. "S", "S", funcs.spawn("ss.sh", {}))
session:add_bind(super, "W", funcs.spawn("vivaldi", { "--ozone-platform=wayland" }))
session:add_bind(super, "A", funcs.spawn("pavucontrol", {}))

-- launchers
session:add_bind(super, "D", funcs.spawn("bemenu-launcher", {}))
session:add_bind(super .. "S", "D", funcs.spawn("j4-dmenu-desktop", { "--dmenu=menu" }))
session:add_bind(super .. "S", "W", funcs.spawn("bwpcontrol", { "menu" }))
session:add_bind(super, "T", funcs.spawn("mondocontrol", { "menu" }))

-- misc session mgmt
session:add_bind(super, "H", funcs.cycle_layout(1, lefty_cycle))
session:add_bind(super .. "S", "H", funcs.cycle_layout(1, flip_cycle))
session:add_bind(super, "Tab", funcs.cycle_focus(1))
session:add_bind(super .. "S", "Tab", funcs.cycle_focus(-1))
session:add_bind(super, "Space", funcs.toggle_floating())
session:add_bind(super .. "S", "Escape", funcs.quit())
session:add_bind(super, "Q", funcs.kill_client())

-- tags
for idx, tag in pairs(tags) do
    session:add_bind(super, "F" .. idx, funcs.set_monitor_tag(tag))
    session:add_bind(super .. "S", "F" .. idx, funcs.set_client_tag(tag))
end

-- stacks
for name, stack in pairs(stacks) do
    session:add_bind(super .. "S", "" .. stack, funcs.set_client_stack(stack))
end

-- debug tools
session:add_bind(super .. "S", "L", debug_icon)

session:add_bind(super, "P", funcs.reload())
session:add_bind(super, "G", gaps.increase)
session:add_bind(super .. "S", "G", gaps.decrease)
session:add_bind(super .. "S", "V", gaps.toggle)

local icon_module = Module.new(function(client)
    return client:get_icon() or "?"
end)

local title_module = Module.new(function(client)
    return client:get_label() or client:get_title() or "?"
end)

-- default rule
session:add_rule({}, function(client)
    client:set_stack(stacks.c)
    client:set_floating(true)
    client:set_icon("?")
    client:set_border(3)
    client:set_modules({
        left = { icon_module },
        center = { title_module },
        right = { icon_module }
    })
end)

local client_rule = function(filter, rule)
    local filter = filter
    local rule = rule
    session:add_rule(filter, function(client)
        if rule.stack ~= nil then
            client:set_stack(rule.stack)
        else
            client:set_floating(true)
        end
        if rule.icon ~= nil then
            client:set_icon(rule.icon)
        end
        if rule.title ~= nil then
            client:set_label(rule.title)
        end
        if rule.border ~= nil then
            client:set_border(rule.border)
        end
    end)
end

-- some client rules
client_rule({ appid = "termA" }, { stack = stacks.a, icon = "" })
client_rule({ appid = "termB" }, { stack = stacks.b, icon = "" })
client_rule({ appid = "termF" }, { icon = "" })
client_rule({ appid = "filesB" }, { stack = stacks.b, icon = "", title = "Files" })
client_rule({ appid = "filesD" }, { stack = stacks.d, icon = "", title = "Files" })
client_rule({ appid = "music" }, { stack = stacks.d, icon = "", title = "Music" })
client_rule({ appid = "discord" }, { stack = stacks.c, icon = "Discord", title = "Chat" })
client_rule({ appid = "htop" }, { stack = stacks.c, icon = "", title = "Tasks" })
client_rule({ appid = "Sxiv" }, { stack = stacks.b, icon = "", title = "Image" })
client_rule({ appid = "imv" }, { stack = stacks.b, icon = "", title = "Image" })
client_rule({ appid = "Chromium" }, { stack = stacks.c, icon = "" })
client_rule({ appid = "vivaldi-stable" }, { stack = stacks.c, icon = "" })
client_rule({ appid = "pavucontrol" }, { stack = stacks.b, icon = "", title = "Volume" })
client_rule({ appid = "neovide" }, { stack = stacks.c, icon = "" })
client_rule({ appid = "PrestoEdit" }, { stack = stacks.c, icon = "" })
client_rule({ appid = "code-insiders" }, { stack = stacks.c, icon = "" })
client_rule({ appid = "cava" }, { stack = stacks.b, icon = "", title = "Vis" })
client_rule({ appid = "SandEEE" }, { stack = stacks.c })
client_rule({ appid = "steam" }, { stack = stacks.c })

session:add_hook("startup", function(startup)
    session:spawn("wlr-randr",
        { "--output", "eDP-1", "--pos", "2560,0", "--output", "DP-4", "--mode", "2560x1080", "--pos", "0,0",
            "--preferred" })
    session:spawn("swww-daemon", {})
    session:spawn("dunst", {})
    session:spawn("waybar", {})
    session:spawn("blueman-applet", {})
    session:spawn("nm-applet", {})
    session:spawn("/usr/lib/gsd-xsettings", {})
end)

session:add_hook("add_monitor", function(monitor)
    monitor:set_layout(default_layout)
end)

function reload_colors()
    package.loaded["mondo.colors"] = nil
    require("mondo.colors")
end
