function pt(pixels)
    return pixels * 1.3333
end

session:set_font("CaskaydiaCovePL Nerd Font", pt(12))

a_container = Container.new(0.0, 0.0, 1.0, 0.2)
b_container = Container.new(0.0, 0.0, 1.0, 0.4)
c_container = Container.new(0.0, 0.2, 1.0, 1.0)
d_container = Container.new(0.0, 0.4, 1.0, 1.0)

floating_container = Container.new(0.2, 0.2, 0.8, 0.8)

root_containers = {a_container, b_container, c_container, d_container, floating_container}
for idx, container in pairs(root_containers) do
    container:set_stack(idx)
end

ac_container = Container.new(0.0, 0.0, 0.7, 1.0)
ac_container:add_child(a_container)
ac_container:add_child(c_container)

bd_container = Container.new(0.7, 0.0, 1.0, 1.0)
bd_container:add_child(b_container)
bd_container:add_child(d_container)

abcd_container = Container.new(0, 0, 1, 1)
abcd_container:add_child(ac_container)
abcd_container:add_child(bd_container)

abcdf_container = Container.new(0, 0, 1, 1)
abcdf_container:add_child(abcd_container)
abcdf_container:add_child(floating_container)

session:add_layout(Layout.new("]+>+[", abcd_container))
session:add_layout(Layout.new("]+++[", abcdf_container))

tags = {session:new_tag("F1"), session:new_tag("F2"), session:new_tag("F3"), session:new_tag("F4")}

local super = "L"
if session.is_debug() then
    super = "A"
end

function set_border(size)
    local client = session:active_client()
    if client then
        client:set_border(size)
    end
end

function set_active_tag(tag)
    local monitor = session:active_monitor()
    if monitor then
        monitor:set_tag(tag)
    end
end

function set_client_tag(tag)
    local client = session:active_client()
    if client then
        client:set_tag(tag)
    end
end

for idx, tag in pairs(tags) do
    session:add_bind(super, "F" .. idx, function()
        set_active_tag(tag)
    end)
    session:add_bind(super .. "S", "F" .. idx, function()
        set_client_tag(tag)
    end)
end

for idx, container in pairs(root_containers) do
    session:add_bind(super .. "S", "" .. idx, function()
        local client = session:active_client()
        if client then
            client:set_container(container)
        end
    end)
end

local bind_spawn = function(mods, key, program, args)
    session:add_bind(mods, key, function()
        Session.spawn(program, args)
    end)
end

bind_spawn(super, "Return", "alacritty", {"--class=termA"})
bind_spawn(super .. "S", "Return", "alacritty", {"--class=termB"})
bind_spawn(super .. "C", "Return", "alacritty", {"--class=termB"})
bind_spawn(super, "I", "alacritty", {"--class=htop", "-ehtop"})
bind_spawn(super, "M", "alacritty", {"--class=music", "-encmpcpp"})
bind_spawn(super, "R", "alacritty", {"--class=filesD", "-eranger"})
bind_spawn(super .. "S", "R", "alacritty", {"--class=filesB", "-eranger"})
bind_spawn(super .. "S", "S", "swww-daemon", {})
bind_spawn(super, "W", "chromium", {})
bind_spawn(super, "A", "pavucontrol", {})
bind_spawn(super, "C", "neovide", {})

-- launchers
bind_spawn(super, "D", "bemenu-launcher", {})
bind_spawn(super .. "S", "D", "j4-dmenu-desktop", {"--dmenu=menu"})
bind_spawn(super .. "S", "W", "bwpcontrol", {"menu"})
bind_spawn(super, "T", "mondocontrol", {"menu"})

session:add_bind(super, "H", function()
    local monitor = session:active_monitor()
    if monitor then
        local layout = monitor:get_layout()
        monitor:set_layout(layout + 1)
    end
end)

session:add_bind(super .. "S", "H", function()
    local monitor = session:active_monitor()
    if monitor then
        local layout = monitor:get_layout()
        monitor:set_layout(layout - 1)
    end
end)

session:add_bind(super .. "S", "Escape", function()
    session:quit(1)
end)

session:add_bind(super, "Tab", function()
    session:cycle_focus(1)
end)

session:add_bind(super .. "S", "Tab", function()
    session:cycle_focus(-1)
end)

session:add_bind(super, "Space", function()
    local client = session:active_client()
    if client then
        client:set_floating(not client:get_floating())
    end
end)

session:add_bind(super, "Q", function()
    local client = session:active_client()
    if client then
        client:close()
    end
end)

local client_rule = function(filter, rule)
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

client_rule({}, {icon = "", border = 2})

client_rule({appid = "termA"}, {container = a_container, icon = ""})
client_rule({appid = "termB"}, {container = b_container, icon = ""})
client_rule({appid = "termF"}, {icon = ""})
client_rule({appid = "filesB"}, {container = b_container, icon = ""})
client_rule({appid = "filesD"}, {container = d_container, icon = ""})
client_rule({appid = "music"}, {container = c_container, icon = ""})
client_rule({appid = "discord"}, {container = c_container, icon = "Chat"})
client_rule({appid = "htop"}, {container = c_container, icon = ""})
client_rule({appid = "Sxiv"}, {container = b_container, icon = ""})
client_rule({appid = "imv"}, {container = b_container, icon = ""})
client_rule({appid = "Chromium"}, {container = c_container, icon = ""})
client_rule({appid = "pavucontrol"}, {container = b_container, icon = ""})
client_rule({appid = "neovide"}, {container = c_container, icon = ""})
client_rule({appid = "PrestoEdit"}, {container = c_container, icon = ""})
client_rule({appid = "Code - Insiders"}, {container = c_container, icon = ""})
client_rule({appid = "cava"}, {container = d_container, icon = ""})

session:add_hook("startup", function()
    Session.spawn("wlr-randr",
        {"--output", "eDP-1", "--pos", "2560,0", "--output", "DP-4", "--mode", "2560x1080", "--pos", "0,0"})

    Session.spawn("swww-daemon", {})
    Session.spawn("dunst", {})
    Session.spawn("waybar", {})
    Session.spawn("blueman-applet", {})
    Session.spawn("nm-applet", {})
end)

session:add_bind(super, "F", function()
    Session.spawn("wlr-randr",
        {"--output", "eDP-1", "--pos", "2560,0", "--output", "DP-4", "--mode", "2560x1080", "--pos", "0,0"})
end)
