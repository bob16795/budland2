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
package.loaded["colors"] = nil
require("colors")

gaps.setup {inc = 2, toggle = true, value = 8, ratio = 2, outer = 30}
mouse.setup {}

-- fonts
funcs.set_font_pt("CaskaydiaCovePL Nerd Font", 14)

stacks = {a = 1, b = 2, c = 3, d = 4, e = 5}
tags = {session:new_tag("F1"), session:new_tag("F2"), session:new_tag("F3"), session:new_tag("F4")}

abcd_container = session:add_layout("]+>+[")
abcd_left_container = session:add_layout("]+++[")

function setup_abcd(root_container, split)
    local split = split

    bd_container = root_container:add_child(split, 0.0, 1.0, 1.0)
    ac_container = root_container:add_child(0.0, 0.0, split, 1.0)

    b_container = bd_container:add_child(0.0, 0.0, 1.0, 0.4)
    d_container = bd_container:add_child(0.0, 0.4, 1.0, 1.0)

    a_container = ac_container:add_child(0.0, 0.0, 1.0, 0.2)
    c_container = ac_container:add_child(0.0, 0.2, 1.0, 1.0)

    a_container:set_stack(stacks.a)
    b_container:set_stack(stacks.b)
    c_container:set_stack(stacks.c)
    d_container:set_stack(stacks.d)
end

setup_abcd(abcd_container, 0.7)
setup_abcd(abcd_left_container, 0.3)

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
        local size = session:active_monitor():get_size()
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
session:add_bind(super, "Return", funcs.spawn(terminal, {"--class=termA"}))
session:add_bind(super .. "S", "Return", funcs.spawn(terminal, {"--class=termB"}))
session:add_bind(super .. "C", "Return", funcs.spawn(terminal, {"--class=termB"}))
session:add_bind(super, "I", funcs.spawn(terminal, {"--class=htop", "-e", "htop"}))
session:add_bind(super, "M", funcs.spawn(terminal, {"--class=music", "-e", "kew"}))
session:add_bind(super, "R", funcs.spawn(terminal, {"--class=filesD", "-e", "ranger"}))
session:add_bind(super .. "S", "R", funcs.spawn(terminal, {"--class=filesB", "-e", "ranger"}))
session:add_bind(super, "V", funcs.spawn(terminal, {"--class=cava", "-e", "cava"}))

session:add_bind(super .. "S", "S", funcs.spawn("ss.sh", {}))
session:add_bind(super, "W", funcs.spawn("chromium", {}))
session:add_bind(super, "A", funcs.spawn("pavucontrol", {}))

-- launchers
session:add_bind(super, "D", funcs.spawn("bemenu-launcher", {}))
session:add_bind(super .. "S", "D", funcs.spawn("j4-dmenu-desktop", {"--dmenu=menu"}))
session:add_bind(super .. "S", "W", funcs.spawn("bwpcontrol", {"menu"}))
session:add_bind(super, "T", funcs.spawn("mondocontrol", {"menu"}))

-- misc session mgmt
session:add_bind(super, "H", funcs.cycle_layout(1))
session:add_bind(super .. "S", "H", funcs.cycle_layout(-1))
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

local client_rule = function(filter, rule)
    local filter = filter
    local rule = rule
    session:add_rule(filter, function(client)
        if rule.container ~= nil then
            client:set_container(rule.container)
        else
            client:set_floating(true)
        end
        if rule.icon ~= nil then
            client:set_icon(rule.icon)
        end
        if rule.border ~= nil then
            client:set_border(rule.border)
        end
    end)
end

session:add_rule({}, function(client)
    client:set_container(c_container)
    client:set_floating(true)
    client:set_icon("?")
    client:set_border(3)
end)

session:add_bind(super, "P", funcs.reload())
session:add_bind(super, "G", gaps.increase)
session:add_bind(super .. "S", "G", gaps.decrease)
session:add_bind(super .. "S", "V", gaps.toggle)

client_rule({appid = "termA"}, {container = a_container, icon = ""})
client_rule({appid = "termB"}, {container = b_container, icon = ""})
client_rule({appid = "termF"}, {icon = ""})
client_rule({appid = "filesB"}, {container = b_container, icon = ""})
client_rule({appid = "filesD"}, {container = d_container, icon = ""})
client_rule({appid = "music"}, {container = d_container, icon = ""})
client_rule({appid = "discord"}, {container = c_container, icon = "Chat"})
client_rule({appid = "htop"}, {container = c_container, icon = ""})
client_rule({appid = "Sxiv"}, {container = b_container, icon = ""})
client_rule({appid = "imv"}, {container = b_container, icon = ""})
client_rule({appid = "Chromium"}, {container = c_container, icon = ""})
client_rule({appid = "pavucontrol"}, {container = b_container, icon = ""})
client_rule({appid = "neovide"}, {container = c_container, icon = ""})
client_rule({appid = "PrestoEdit"}, {container = c_container, icon = ""})
client_rule({appid = "Code - Insiders"}, {container = c_container, icon = ""})
client_rule({appid = "cava"}, {container = b_container, icon = ""})

session:add_hook("startup", function(startup)
    session:spawn("wlr-randr",
        {"--output", "eDP-1", "--pos", "2560,0", "--output", "DP-4", "--mode", "2560x1080", "--pos", "0,0"})
    session:spawn("swww-daemon", {})
    session:spawn("dunst", {})
    session:spawn("waybar", {})
    session:spawn("blueman-applet", {})
    session:spawn("nm-applet", {})
end)

function reload()
    funcs.reload()()
end
