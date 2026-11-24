--[[
    contextmenu_native —— 基于 mpv 原生菜单 API 的上下文菜单。

    依赖 mpv >= 0.42：
      - menu-data 属性（menu definition data）
      - context-menu 命令（Windows 上由 w32 VO 用 CreatePopupMenu/TrackPopupMenuEx 渲染）

    与 contextmenu_gui 的区别：不启动任何子进程，不需要 tclsh/Tk。

    菜单定义见同目录 contextmenu_native_menu.lua。
    条目格式与 contextmenu_gui 兼容：
        {类型, 标签, 加速键(仅显示), 命令, 状态, 是否禁用}
    类型：cascade / command / check / radio / separator
    命令可以写字符串，也可以写函数（会自动转成脚本消息回调）。
--]]

local mp = require "mp"
local options = require "mp.options"

-- 读取选项。滤镜/着色器字段与 contextmenu_gui.conf 保持一致，
-- 便于直接把旧配置内容复制过来。
local opt = {
    bind_key = "MBTN_MID",
    bind_key_loaded = "",
}

for i = 1, 10 do
    local k = string.format("%02d", i)
    opt["filter" .. k .. "B"] = ""
    opt["filter" .. k .. "D"] = ""
    opt["filter" .. k .. "G"] = "no"
    opt["shader" .. k .. "B"] = ""
    opt["shader" .. k .. "D"] = ""
    opt["shader" .. k .. "G"] = "no"
end

options.read_options(opt, "contextmenu_native")

local SCRIPT_NAME = mp.get_script_name()
local menu = require "contextmenu_native_menu"

-- 函数型命令通过 script-message 回调执行，无法直接放进 menu-data。
local invoke_handlers = {}

local function to_command(cmd)
    if type(cmd) == "function" then
        local id = tostring(#invoke_handlers + 1)
        invoke_handlers[id] = cmd
        return "script-message-to " .. SCRIPT_NAME .. " invoke " .. id
    end
    return cmd
end

mp.register_script_message("invoke", function(id)
    local fn = invoke_handlers[id]
    if fn then fn() end
end)

-- 状态/标签允许是函数，在每次构建菜单时求值，等价于原实现的动态状态。
local function eval(v)
    if type(v) == "function" then return v() end
    return v
end

-- 把内部菜单表转换成 mpv 的 menu-data 节点结构。
local function build(list)
    local out = {}

    for _, item in ipairs(list) do
        local kind = item[1]

        if kind == "separator" then
            out[#out + 1] = { type = "separator" }
        elseif kind == "cascade" then
            local sub = menu.defs[item[3]]
            if sub and #sub > 0 then
                out[#out + 1] = {
                    type = "submenu",
                    title = eval(item[2]),
                    shortcut = eval(item[3]) or "",
                    submenu = build(sub),
                }
            end
        else
            local state = {}

            if eval(item[5]) == true then
                state[#state + 1] = "checked"
            end
            if eval(item[6]) == true then
                state[#state + 1] = "disabled"
            end

            out[#out + 1] = {
                title = eval(item[2]) or "",
                -- command 必须存在；空命令的条目在 mpv 里会被当作子菜单，
                -- 所以这里保证至少是 "ignore"。
                cmd = to_command(item[4]) or "ignore",
                shortcut = eval(item[3]) or "",
                state = state,
            }
        end
    end

    return out
end

local function show()
    menu.refresh(opt)

    local ok, err = pcall(function()
        mp.set_property_native("menu-data", build(menu.defs.context_menu))
        mp.command("context-menu")
    end)

    if not ok then
        mp.msg.error("构建菜单失败: " .. tostring(err))
        mp.osd_message("contextmenu_native: " .. tostring(err), 3)
    end
end

-- 供菜单模块在 G=yes 的条目执行后重新弹出菜单使用。
menu.show_hook = show

mp.register_script_message("show", show)

if opt.bind_key ~= "" then
    mp.add_key_binding(opt.bind_key, "show", show)
end
if opt.bind_key_loaded ~= "" then
    mp.add_key_binding(opt.bind_key_loaded, "show-loaded", show, { repeatable = false })
end

mp.register_event("file-loaded", function()
    menu.loaded = true
    menu.refresh(opt)
end)

mp.register_event("end-file", function()
    menu.loaded = false
    menu.refresh(opt)
end)

menu.refresh(opt)
