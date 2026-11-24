--[[
    contextmenu_native 的菜单定义。

    条目格式（与 contextmenu_gui 保持兼容）：
        {类型, 标签, 加速键, 命令, 状态, 是否禁用}

    类型：
        cascade    子菜单，第三个字段是子菜单名
        command    普通条目
        check      勾选条目，状态为 true 时显示勾选
        radio      与 check 表现一致（原生菜单只有 checked 状态）
        separator  分隔线，只写 {"separator"}

    标签、加速键、状态、禁用都可以写成函数，每次打开菜单时求值，
    因此动态内容（播放列表、轨道、章节）无需额外机制。
--]]

local mp = require "mp"

local M = {
    defs = {},
    loaded = false,
    show_hook = nil,
}

local CASCADE = "cascade"
local COMMAND = "command"
local CHECK = "check"
local SEP = {"separator"}

local function prop(name)
    return mp.get_property_native(name)
end

-- 播放列表：当前项勾选
local function playlist_items()
    local out = {}

    for i, entry in ipairs(prop("playlist") or {}) do
        local title = entry.title or entry.filename or ("#" .. i)
        local cmd = "playlist-play-index " .. (i - 1)

        if entry.playing then
            out[#out + 1] = {CHECK, title, "", cmd, true, false}
        else
            out[#out + 1] = {COMMAND, title, "", cmd, "", false}
        end
    end

    if #out == 0 then
        out[1] = {COMMAND, "播放列表为空", "", "ignore", "", true}
    end

    return out
end

-- 轨道：kind = audio/sub/video，propname = aid/sid/vid
local function track_items(kind, propname)
    local out = {}

    for _, track in ipairs(prop("track-list") or {}) do
        if track.type == kind then
            local desc = track.title or track.lang or track.codec or ("#" .. track.id)
            local cmd = "set " .. propname .. " " .. (track.selected and "no" or track.id)

            if track.selected then
                out[#out + 1] = {CHECK, "● " .. desc, "", cmd, true, false}
            else
                out[#out + 1] = {COMMAND, "○ " .. desc, "", cmd, "", false}
            end
        end
    end

    if #out == 0 then
        out[1] = {COMMAND, "（无）", "", "ignore", "", true}
    end

    return out
end

local function chapter_items()
    local out = {}
    local current = prop("chapter")
    if current == nil then current = -1 end

    for i, chapter in ipairs(prop("chapter-list") or {}) do
        local label = mp.format_time(chapter.time)
        if chapter.title and chapter.title ~= "" then
            label = label .. "  " .. chapter.title
        end

        local cmd = "set chapter " .. (i - 1)

        if current == i - 1 then
            out[#out + 1] = {CHECK, label, "", cmd, true, false}
        else
            out[#out + 1] = {COMMAND, label, "", cmd, "", false}
        end
    end

    if #out == 0 then
        out[1] = {COMMAND, "（无章节）", "", "ignore", "", true}
    end

    return out
end

-- 滤镜/着色器：读取 filter01..10 / shader01..10
local function configured_items(opt, prefix)
    local out = {}

    for i = 1, 10 do
        local k = string.format("%02d", i)
        local label = opt[prefix .. k .. "B"]
        local cmd = opt[prefix .. k .. "D"]

        if label and label ~= "" and cmd and cmd ~= "" then
            -- G=yes 表示执行后重新弹出菜单。原生菜单无法回到子菜单，
            -- 因此重开时回到顶层。
            if opt[prefix .. k .. "G"] == "yes" then
                local command = cmd
                cmd = function()
                    mp.command(command)
                    if M.show_hook then mp.add_timeout(0.05, M.show_hook) end
                end
            end

            out[#out + 1] = {COMMAND, label, "", cmd, "", false}
        end
    end

    if #out == 0 then
        out[1] = {COMMAND, "（未配置）", "", "ignore", "", true}
    end

    return out
end

function M.refresh(opt)
    opt = opt or {}
    local defs = {}

    if M.loaded then
        defs.context_menu = {
            {CASCADE, "加载", "open_menu"},
            {CASCADE, "文件", "file_menu"},
            {CASCADE, "导航", "navi_menu"},
            SEP,
            {CASCADE, "画面", "output_menu"},
            {CASCADE, "视频", "video_menu"},
            {CASCADE, "音频", "audio_menu"},
            {CASCADE, "字幕", "subtitle_menu"},
            SEP,
            {CASCADE, "滤镜", "filter_menu"},
            {CASCADE, "着色器", "shader_menu"},
            SEP,
            {CASCADE, "其它", "etc_menu"},
            {CASCADE, "关于", "about_menu"},
            SEP,
            {COMMAND, "退出 mpv", "", "quit"},
        }
    else
        defs.context_menu = {
            {CASCADE, "加载", "open_menu"},
            SEP,
            {CASCADE, "画面", "output_menu"},
            SEP,
            {CASCADE, "其它", "etc_menu"},
            {CASCADE, "关于", "about_menu"},
            SEP,
            {COMMAND, "退出 mpv", "", "quit"},
        }
    end

    defs.open_menu = {
        {COMMAND, "打开文件…（需 load_plus）", "", "script-binding load_plus/import_files", "", true},
        {COMMAND, "打开地址…（需 load_plus）", "", "script-binding load_plus/import_url", "", true},
        SEP,
        {CASCADE, "播放列表", "playlist_menu"},
        {COMMAND, "上一个文件", "", "playlist-prev", "", false},
        {COMMAND, "下一个文件", "", "playlist-next", "", false},
        {CHECK, "列表循环", "", "cycle-values loop-playlist inf no",
         function() return mp.get_property("loop-playlist") ~= "no" end, false},
        {CHECK, "随机播放", "", "cycle shuffle",
         function() return prop("shuffle") end, false},
    }

    defs.file_menu = {
        {CHECK, "播放/暂停", "space", "cycle pause", function() return prop("pause") end, false},
        {COMMAND, "停止", "", "stop", "", false},
        SEP,
        {CHECK, "显示进度条", "", "cycle-values osd-level 3 1",
         function() return mp.get_property("osd-level") == "3" end, false},
        SEP,
        {COMMAND, "截图（含字幕）", "s", "screenshot", "", false},
        {COMMAND, "截图（不含字幕）", "S", "screenshot subtitles", "", false},
        SEP,
        {COMMAND, "退出并保存进度", "", "quit-watch-later", "", false},
    }

    defs.navi_menu = {
        {CASCADE, "章节", "chapter_menu"},
        {COMMAND, "上一个章节", "PageUp", "add chapter -1", "", false},
        {COMMAND, "下一个章节", "PageDown", "add chapter 1", "", false},
        SEP,
        {COMMAND, "后退 10 秒", "Left", "seek -10", "", false},
        {COMMAND, "前进 10 秒", "Right", "seek 10", "", false},
        {COMMAND, "后退 60 秒", "Shift+Left", "seek -60", "", false},
        {COMMAND, "前进 60 秒", "Shift+Right", "seek 60", "", false},
    }

    defs.output_menu = {
        {CHECK, "窗口置顶", "T", "cycle ontop", function() return prop("ontop") end, false},
        {CHECK, "窗口边框", "", "cycle border", function() return not prop("border") end, false},
        {CHECK, "全屏", "f", "cycle fullscreen", function() return prop("fullscreen") end, false},
        SEP,
        {CHECK, "保持窗口比例", "", "cycle keepaspect",
         function() return prop("keepaspect") end, false},
        {COMMAND, "按窗口大小裁剪（panscan 1）", "", "set panscan 1", "", false},
        {COMMAND, "重置裁剪", "", "set panscan 0", "", false},
    }

    defs.video_menu = {
        {CASCADE, "视频轨", "video_track_menu"},
        SEP,
        {COMMAND, "旋转 90°", "", "cycle-values video-rotate 90 180 270 0", "", false},
        {COMMAND, "重置旋转", "", "set video-rotate 0", "", false},
        SEP,
        {COMMAND, "放大", "", "add video-zoom 0.1", "", false},
        {COMMAND, "缩小", "", "add video-zoom -0.1", "", false},
        {COMMAND, "重置缩放", "", "set video-zoom 0", "", false},
    }

    defs.audio_menu = {
        {CASCADE, "音轨", "audio_track_menu"},
        SEP,
        {CHECK, "静音", "m", "cycle mute", function() return prop("mute") end, false},
        {COMMAND, "音量 +5", "", "add volume 5", "", false},
        {COMMAND, "音量 -5", "", "add volume -5", "", false},
        SEP,
        {COMMAND, "音频延迟 +0.1s", "", "add audio-delay 0.1", "", false},
        {COMMAND, "音频延迟 -0.1s", "", "add audio-delay -0.1", "", false},
    }

    defs.subtitle_menu = {
        {CASCADE, "字幕轨", "sub_track_menu"},
        SEP,
        {CHECK, "显示字幕", "v", "cycle sub-visibility",
         function() return prop("sub-visibility") end, false},
        {COMMAND, "字幕延迟 +0.1s", "", "add sub-delay 0.1", "", false},
        {COMMAND, "字幕延迟 -0.1s", "", "add sub-delay -0.1", "", false},
        SEP,
        {COMMAND, "加载字幕文件…（需 load_plus）", "",
         "script-binding load_plus/import_sub", "", true},
    }

    defs.filter_menu = configured_items(opt, "filter")
    defs.shader_menu = configured_items(opt, "shader")

    defs.etc_menu = {
        {COMMAND, "状态信息（开/关）", "i", "script-binding stats/display-stats-toggle", "", false},
        {COMMAND, "状态信息-概览", "", "script-binding stats/display-page-1-toggle", "", false},
        {COMMAND, "状态信息-帧计时", "", "script-binding stats/display-page-2-toggle", "", false},
        SEP,
        {COMMAND, "控制台", "`", "script-binding console/enable", "", false},
        SEP,
        {CASCADE, "快捷键", "binding_menu"},
    }

    defs.about_menu = {
        {COMMAND, prop("mpv-version") or "mpv", "", "ignore", "", true},
        {COMMAND, "ffmpeg " .. (prop("ffmpeg-version") or ""), "", "ignore", "", true},
        {COMMAND, "libass " .. (prop("libass-version") or ""), "", "ignore", "", true},
        SEP,
        {COMMAND, "contextmenu_native · 原生 menu-data 菜单", "", "ignore", "", true},
    }

    -- 动态子菜单每次打开时重新生成
    defs.playlist_menu = playlist_items()
    defs.chapter_menu = chapter_items()
    defs.audio_track_menu = track_items("audio", "aid")
    defs.video_track_menu = track_items("video", "vid")
    defs.sub_track_menu = track_items("sub", "sid")
    defs.binding_menu = {
        {COMMAND, "按 i 查看完整快捷键列表", "", "script-binding stats/display-page-4-toggle", "", false},
    }

    M.defs = defs
end

return M
