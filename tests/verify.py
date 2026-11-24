#!/usr/bin/env python3
"""端到端验证 contextmenu_native。

验证内容：
  1. mpv 能加载脚本且无 Lua 错误
  2. 触发后 menu-data 属性被填充为预期的节点结构
  3. context-menu 命令弹出原生 Win32 菜单窗口（类名 #32768）
  4. 菜单可关闭，mpv 不崩溃

用法：
    python tests/verify.py
环境变量：
    MPV_EXE   mpv 可执行文件路径（默认 E:/Misc/Apps/mpv/mpv.exe）
"""

import ctypes
import json
import os
import subprocess
import sys
import tempfile
import time
import wave

from ctypes import wintypes as wt

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT_DIR = os.path.join(ROOT, "scripts", "contextmenu_native")
MPV_EXE = os.environ.get("MPV_EXE", r"E:\Misc\Apps\mpv\mpv.exe")

failures = []


def check(name, ok, detail=""):
    print(("PASS  " if ok else "FAIL  ") + name + (("  " + detail) if detail else ""))
    if not ok:
        failures.append(name)


def make_wav(path):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(8000)
        w.writeframes(b"\x00\x00" * 8000 * 3)


class IPC:
    def __init__(self, path):
        self.f = open(path, "r+b", buffering=0)

    def cmd(self, *args):
        self.f.write((json.dumps({"command": list(args)}) + "\n").encode())
        return json.loads(self.f.readline().decode())

    def send(self, *args):
        self.f.write((json.dumps({"command": list(args)}) + "\n").encode())


def windows_of(pid, class_name=None):
    user32 = ctypes.windll.user32
    found = []
    proc = ctypes.WINFUNCTYPE(ctypes.c_bool, wt.HWND, wt.LPARAM)

    def cb(hwnd, _):
        cls = ctypes.create_unicode_buffer(256)
        user32.GetClassNameW(hwnd, cls, 256)
        if not user32.IsWindowVisible(hwnd):
            return True
        owner = wt.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == pid and (class_name is None or cls.value == class_name):
            found.append(hwnd)
        return True

    user32.EnumWindows(proc(cb), 0)
    return found


def move_cursor_into(hwnd):
    """mpv 的 mp_win32_menu_show 要求鼠标在窗口客户区内，否则直接返回。"""
    user32 = ctypes.windll.user32
    rect = wt.RECT()
    user32.GetClientRect(hwnd, ctypes.byref(rect))
    pt = wt.POINT((rect.right - rect.left) // 2, (rect.bottom - rect.top) // 2)
    user32.ClientToScreen(hwnd, ctypes.byref(pt))
    user32.SetCursorPos(pt.x, pt.y)
    time.sleep(0.2)
    return pt


def post_escape(hwnd):
    user32 = ctypes.windll.user32
    user32.PostMessageW(hwnd, 0x0100, 0x1B, 0x00010001)
    time.sleep(0.05)
    user32.PostMessageW(hwnd, 0x0101, 0x1B, 0xC0010001)


def walk(nodes, path=""):
    """展开 menu-data，返回 (类型集合, 标题列表)。"""
    kinds, titles = set(), []
    for node in nodes or []:
        kind = node.get("type", "item")
        kinds.add(kind)
        titles.append(node.get("title") or "")
        if kind == "submenu":
            sub_kinds, sub_titles = walk(node.get("submenu"), path + "/" + (node.get("title") or "?"))
            kinds |= sub_kinds
            titles += sub_titles
    return kinds, titles


def main():
    if not os.path.isfile(MPV_EXE):
        print("找不到 mpv: " + MPV_EXE)
        return 2
    if not os.path.isfile(os.path.join(SCRIPT_DIR, "main.lua")):
        print("找不到脚本: " + SCRIPT_DIR)
        return 2

    tmp = tempfile.mkdtemp(prefix="ctxnative-")
    wav = os.path.join(tmp, "t.wav")
    log = os.path.join(tmp, "mpv.log")
    make_wav(wav)

    pipe_name = "ctxnative-test-%d" % os.getpid()
    pipe_path = "\\\\.\\pipe\\" + pipe_name

    proc = subprocess.Popen(
        [
            MPV_EXE, "--no-config", "--ao=null", "--force-window=yes",
            "--loop-file=inf",
            "--input-ipc-server=" + pipe_path,
            "--log-file=" + log,
            "--msg-level=all=v",
            "--script=" + SCRIPT_DIR,
            wav,
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    ipc = None
    try:
        for _ in range(60):
            try:
                ipc = IPC(pipe_path)
                break
            except OSError:
                time.sleep(0.25)
        check("IPC 连接", ipc is not None)
        if ipc is None:
            return 1

        time.sleep(1.5)

        main_windows = windows_of(proc.pid)
        check("mpv 主窗口存在", len(main_windows) > 0, str(main_windows))
        if main_windows:
            move_cursor_into(main_windows[0])

        # 走脚本自己的触发路径（构建 menu-data 并调用 context-menu）
        resp = ipc.cmd("script-message-to", "contextmenu_native", "show")
        check("触发 show", resp.get("error") == "success", json.dumps(resp, ensure_ascii=False))
        time.sleep(0.8)

        data = ipc.cmd("get_property", "menu-data").get("data")
        check("menu-data 已填充", isinstance(data, list) and len(data) > 0,
              "顶层条目 %s" % (len(data) if isinstance(data, list) else "nil"))

        kinds, titles = walk(data)
        check("含子菜单", "submenu" in kinds)
        check("含分隔线", "separator" in kinds)
        check("含退出项", any("退出 mpv" in t for t in titles))
        check("含动态列表（播放列表）", any("播放列表" in t for t in titles))
        check("含滤镜子菜单", any("滤镜" in t for t in titles))

        # 检查是否有 checked 状态节点（播放/暂停等）
        checked = []

        def scan(nodes):
            for n in nodes or []:
                if "checked" in (n.get("state") or []):
                    checked.append(n.get("title"))
                if n.get("type") == "submenu":
                    scan(n.get("submenu"))

        scan(data)
        check("含勾选状态节点", len(checked) > 0, "例如: %s" % (checked[:3],))

        def has_shortcut(nodes):
            for n in nodes or []:
                if "shortcut" in n:
                    return True
                if n.get("type") == "submenu" and has_shortcut(n.get("submenu")):
                    return True
            return False

        check("菜单项无快捷键文本", not has_shortcut(data))

        ipc.send("context-menu")
        time.sleep(1.2)
        menus = windows_of(proc.pid, "#32768")
        check("原生菜单窗口出现", len(menus) > 0, "#32768 数量 %d" % len(menus))
        if not menus:
            # 首次 show 应已弹出；再显式触发一次以区分“脚本未弹”与“命令未弹”
            ipc.send("context-menu")
            time.sleep(1.0)
            menus = windows_of(proc.pid, "#32768")
            check("原生菜单窗口出现（核心命令直触发）", len(menus) > 0)

        for hwnd in menus:
            post_escape(hwnd)
        time.sleep(0.8)

        check("菜单已关闭", len(windows_of(proc.pid, "#32768")) == 0)

        log_text = ""
        if os.path.isfile(log):
            with open(log, "r", encoding="utf-8", errors="replace") as f:
                log_text = f.read()
        check("无 Lua 错误", "Lua error" not in log_text and "[contextmenu_native] 构建菜单失败" not in log_text)
        check("脚本已加载", "contextmenu_native" in log_text)
        check("脚本未自行绑定按键", "input_contextmenu_native" not in log_text)

        ipc.send("quit")
        time.sleep(0.5)
    finally:
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)

    print()
    if failures:
        print("失败 %d 项: %s" % (len(failures), ", ".join(failures)))
        return 1
    print("全部通过")
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.exit(main())
