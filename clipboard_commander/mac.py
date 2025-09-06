import sys
from typing import Callable, Optional

if sys.platform != "darwin":
    raise SystemExit("mac.py is macOS-only")

import ctypes
from ctypes import c_bool, c_int, c_ulong, c_void_p
import ctypes.util
import subprocess

from Quartz import (
    CFMachPortCreateRunLoopSource,
    CFRunLoopAddSource,
    CFRunLoopGetCurrent,
    CGEventCreateKeyboardEvent,
    CGEventGetFlags,
    CGEventGetIntegerValueField,
    CGEventPost,
    CGEventTapCreate,
    CGEventTapEnable,
    kCFRunLoopCommonModes,
    kCGEventFlagMaskCommand,
    kCGEventFlagMaskShift,
    kCGEventKeyDown,
    kCGEventKeyUp,
    kCGHeadInsertEventTap,
    kCGHIDEventTap,
    kCGKeyboardEventKeycode,
    kCGSessionEventTap,
)

K_V = 0x09  # virtual keycode for 'V'


def send_cmd_v():
    down = CGEventCreateKeyboardEvent(None, K_V, True)
    up = CGEventCreateKeyboardEvent(None, K_V, False)
    from Quartz import CGEventSetFlags

    CGEventSetFlags(down, kCGEventFlagMaskCommand)
    CGEventSetFlags(up, kCGEventFlagMaskCommand)
    CGEventPost(kCGHIDEventTap, down)
    CGEventPost(kCGHIDEventTap, up)


class HotkeyTap:
    """Low-level event tap to detect and swallow Cmd+Shift+V without system beep."""

    def __init__(self, callback: Callable[[], None]):
        self._callback = callback
        self._tap = None
        self._source = None
        self._enabled = False
        self._objc = ctypes.cdll.LoadLibrary(ctypes.util.find_library("objc"))
        self._CFRunLoopGetCurrent = CFRunLoopGetCurrent

    def start(self) -> bool:
        if self._enabled:
            return True

        @ctypes.CFUNCTYPE(c_void_p, c_void_p, c_int, c_void_p, c_void_p)
        def _handler(proxy, type_, event, refcon):
            try:
                if type_ == kCGEventKeyDown:
                    flags = CGEventGetFlags(event)
                    keycode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode)
                    cmd = bool(flags & kCGEventFlagMaskCommand)
                    shift = bool(flags & kCGEventFlagMaskShift)
                    if cmd and shift and keycode == K_V:
                        # swallow and trigger
                        self._callback()
                        return None
            except Exception:
                pass
            return event

        self._handler = _handler
        self._tap = CGEventTapCreate(
            kCGSessionEventTap,
            kCGHeadInsertEventTap,
            0,
            (1 << kCGEventKeyDown) | (1 << kCGEventKeyUp),
            self._handler,
            None,
        )
        if not self._tap:
            return False
        # Ensure the tap is enabled
        CGEventTapEnable(self._tap, True)
        self._source = CFMachPortCreateRunLoopSource(None, self._tap, 0)
        CFRunLoopAddSource(self._CFRunLoopGetCurrent(), self._source, kCFRunLoopCommonModes)
        self._enabled = True
        return True

    def stop(self):
        # Rely on process exit to remove tap; PyObjC handles cleanup
        self._enabled = False


def has_accessibility_permission() -> bool:
    try:
        app_services = ctypes.cdll.LoadLibrary(ctypes.util.find_library("ApplicationServices"))
        try:
            AXIsProcessTrusted = app_services.AXIsProcessTrusted
            AXIsProcessTrusted.restype = c_bool
            AXIsProcessTrusted.argtypes = []
            return bool(AXIsProcessTrusted())
        except AttributeError:
            AXIsProcessTrustedWithOptions = app_services.AXIsProcessTrustedWithOptions
            AXIsProcessTrustedWithOptions.restype = c_bool
            AXIsProcessTrustedWithOptions.argtypes = [c_void_p]
            return bool(AXIsProcessTrustedWithOptions(None))
    except Exception:
        return False


def request_accessibility_permission(open_settings: bool = True) -> bool:
    ok = has_accessibility_permission()
    if not ok and open_settings:
        try:
            subprocess.run(
                [
                    "open",
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                ],
                check=False,
            )
        except Exception:
            pass
    return ok


def set_app_accessory_policy():
    # Hide Dock icon and keep only status bar presence
    objc = ctypes.cdll.LoadLibrary(ctypes.util.find_library("objc"))
    sel_registerName = objc.sel_registerName
    sel_registerName.restype = c_void_p
    sel_registerName.argtypes = [ctypes.c_char_p]
    objc_getClass = objc.objc_getClass
    objc_getClass.restype = c_void_p
    objc_getClass.argtypes = [ctypes.c_char_p]
    objc_msgSend = objc.objc_msgSend

    NSApplication = objc_getClass(b"NSApplication")
    sharedApp_sel = sel_registerName(b"sharedApplication")
    objc_msgSend.restype = c_void_p
    objc_msgSend.argtypes = [c_void_p, c_void_p]
    NSApp = objc_msgSend(NSApplication, sharedApp_sel)
    setActivationPolicy_sel = sel_registerName(b"setActivationPolicy:")
    objc_msgSend.restype = None
    objc_msgSend.argtypes = [c_void_p, c_void_p, c_int]
    # NSApplicationActivationPolicyAccessory = 1
    objc_msgSend(NSApp, setActivationPolicy_sel, 1)


def window_join_all_spaces_and_raise(qwidget):
    # Apply NSWindow behaviors for overlay on fullscreen apps
    from ctypes import c_void_p
    import ctypes.util

    objc = ctypes.cdll.LoadLibrary(ctypes.util.find_library("objc"))
    sel_registerName = objc.sel_registerName
    sel_registerName.restype = c_void_p
    sel_registerName.argtypes = [ctypes.c_char_p]
    objc_msgSend = objc.objc_msgSend

    CB_CanJoinAllSpaces = 1 << 0
    CB_Transient = 1 << 3
    CB_FullScreenAux = 1 << 8
    behavior = CB_CanJoinAllSpaces | CB_Transient | CB_FullScreenAux

    nsview = c_void_p(int(qwidget.winId()))
    sel_window = sel_registerName(b"window")
    objc_msgSend.restype = c_void_p
    objc_msgSend.argtypes = [c_void_p, c_void_p]
    nswindow = objc_msgSend(nsview, sel_window)
    if not nswindow:
        return

    sel_setBehavior = sel_registerName(b"setCollectionBehavior:")
    objc_msgSend.restype = None
    objc_msgSend.argtypes = [c_void_p, c_void_p, c_ulong]
    objc_msgSend(nswindow, sel_setBehavior, c_ulong(behavior))

    sel_setHOD = sel_registerName(b"setHidesOnDeactivate:")
    objc_msgSend.restype = None
    objc_msgSend.argtypes = [c_void_p, c_void_p, c_bool]
    objc_msgSend(nswindow, sel_setHOD, c_bool(False))

    app_services = ctypes.cdll.LoadLibrary(ctypes.util.find_library("ApplicationServices"))
    CGWindowLevelForKey = app_services.CGWindowLevelForKey
    CGWindowLevelForKey.restype = c_int
    CGWindowLevelForKey.argtypes = [c_int]
    kCGPopUpMenuWindowLevelKey = 101
    level = CGWindowLevelForKey(kCGPopUpMenuWindowLevelKey)
    sel_setLevel = sel_registerName(b"setLevel:")
    objc_msgSend.restype = None
    objc_msgSend.argtypes = [c_void_p, c_void_p, c_int]
    objc_msgSend(nswindow, sel_setLevel, c_int(level))

    sel_orderFrontRegardless = sel_registerName(b"orderFrontRegardless")
    objc_msgSend.restype = None
    objc_msgSend.argtypes = [c_void_p, c_void_p]
    objc_msgSend(nswindow, sel_orderFrontRegardless)
