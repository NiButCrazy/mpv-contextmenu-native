--[[
    contextmenu_native —— 基于 mpv 原生菜单 API 的上下文菜单。

    作者：NiButCrazy
    仓库：https://github.com/NiButCrazy/mpv-contextmenu-native

    依赖 mpv >= 0.42：
      - menu-data 属性（menu definition data）
      - context-menu 命令（Windows 上由 w32 VO 用 CreatePopupMenu/TrackPopupMenuEx 渲染）

    与 contextmenu_gui 的区别：不启动任何子进程，不需要 tclsh/Tk。

    对照参考（上游 contextmenu_gui 源码）：
        https://github.com/A-Archives-and-Forks/MPV_lazy/tree/main/portable_config/scripts/contextmenu_gui

    菜单定义见同目录 contextmenu_native_menu.lua。
    条目格式与 contextmenu_gui 兼容：
        {类型, 标签, 加速键(仅显示), 命令, 状态, 是否禁用}
    类型：cascade / command / check / radio / separator
    命令可以写字符串，也可以写函数（会自动转成脚本消息回调）。
--]]

local mp = require "mp"
local options = require "mp.options"
local utils = require "mp.utils"

-- 加载文件夹时收录的扩展名
local MEDIA_EXT = {
    -- 视频
    mkv = true, mp4 = true, m4v = true, avi = true, mov = true, wmv = true,
    flv = true, webm = true, ts = true, m2ts = true, mpg = true, mpeg = true,
    ogv = true, rmvb = true, rm = true, asf = true, ["3gp"] = true, ["3g2"] = true,
    vob = true, y4m = true, amv = true, f4v = true,
    -- 音频
    mp3 = true, flac = true, wav = true, m4a = true, aac = true, ogg = true,
    opus = true, wma = true, ape = true, alac = true, aiff = true, tta = true,
    tak = true, dsf = true, wv = true, oga = true, ogm = true,
}

-- 读取选项。滤镜/着色器字段与 contextmenu_gui.conf 保持一致，
-- 便于直接把旧配置内容复制过来。
local opt = {
    -- 是否在菜单项右侧显示快捷键文本，由用户在 conf 里决定
    show_shortcut = false,
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
                state = state,
            }

            -- 只有普通条目有加速键；子菜单的第三字段是子菜单名，不能显示。
            if opt.show_shortcut then
                local accel = eval(item[3])
                if accel and accel ~= "" then
                    out[#out].shortcut = accel
                end
            end
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

-- 播放/暂停。在 keep-open 停到结尾（eof-reached）时从头重新播放。
-- 不主动绑定按键；需要时在 input.conf 里写：
--   SPACE   script-message-to contextmenu_native play-pause
local function play_pause()
    if mp.get_property_native("eof-reached") then
        mp.commandv("seek", 0, "absolute-percent")
        mp.commandv("set", "pause", "no")
    else
        mp.commandv("cycle", "pause")
    end
end

mp.register_script_message("play-pause", play_pause)

-- 供菜单模块调用
menu.play_pause = play_pause

-- 弹出文件夹选择框，取消返回 nil
local function pick_folder()
    local res = utils.subprocess({
        args = {'powershell', '-NoProfile', '-Command', [[& {
            Trap { Write-Error -ErrorRecord $_; Exit 1 }
            Add-Type -AssemblyName System.Windows.Forms
            Add-Type -AssemblyName System.Drawing
            $u8 = [System.Text.Encoding]::UTF8
            $out = [Console]::OpenStandardOutput()
            # 无 owner 的对话框在 mpv 子进程里会被创建在窗口后面，用置顶的隐藏窗体做 owner
            $owner = New-Object System.Windows.Forms.Form
            $owner.TopMost = $true
            $owner.ShowInTaskbar = $false
            $owner.FormBorderStyle = 'None'
            $owner.StartPosition = 'Manual'
            $owner.Size = New-Object System.Drawing.Size(1, 1)
            $owner.Location = New-Object System.Drawing.Point(-2000, -2000)
            $owner.Show()
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = "选择文件夹"
            $dlg.ShowNewFolderButton = $false
            If ($dlg.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) {
                $b = $u8.GetBytes($dlg.SelectedPath)
                $out.Write($b, 0, $b.Length)
            }
            $owner.Close()
        }]]},
        cancellable = false,
    })
    if not res or res.status ~= 0 then return nil end
    local path = (res.stdout or ""):match("^%s*(.-)%s*$")
    if path == "" then return nil end
    return path
end

-- 把文件夹里的音视频加入播放列表。path 为空时弹出选择框。
-- 也可以用脚本消息直接指定目录：
--   script-message-to contextmenu_native load-folder "D:\Videos"
local function load_folder(path)
    if not path or path == "" then
        path = pick_folder()
    end
    if not path then return end

    local entries = utils.readdir(path, "files")
    if not entries then
        mp.osd_message("无法读取文件夹：" .. path, 3)
        return
    end

    local files = {}
    for _, name in ipairs(entries) do
        local ext = name:match("%.([^%.]+)$")
        if ext and MEDIA_EXT[ext:lower()] then
            files[#files + 1] = utils.join_path(path, name)
        end
    end
    table.sort(files)

    if #files == 0 then
        mp.osd_message("文件夹里没有可识别的音视频文件", 3)
        return
    end

    for i, file in ipairs(files) do
        mp.commandv("loadfile", file, i == 1 and "replace" or "append")
    end
    mp.osd_message(("已加载 %d 个文件"):format(#files), 2)
end

mp.register_script_message("load-folder", load_folder)
menu.load_folder = load_folder

-- 供菜单模块在 G=yes 的条目执行后重新弹出菜单使用。
menu.show_hook = show

mp.register_script_message("show", show)

mp.register_event("file-loaded", function()
    menu.loaded = true
    menu.refresh(opt)
end)

mp.register_event("end-file", function()
    menu.loaded = false
    menu.refresh(opt)
end)

menu.refresh(opt)
