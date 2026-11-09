#!/usr/bin/env python3
"""niri-ai-popup.py — Floating result panel for the niri AI helper.

Reads {"title", "source", "result"} from a JSON file (argv[1]) or stdin,
and shows a draggable GtkLayerShell overlay panel that preserves line breaks
in both the source and the translated result. Copy buttons + Esc/close.

Usage: niri-ai-popup.py [result.json]
"""

from __future__ import annotations

import json
import os
import sys

import gi

gi.require_version("Gdk", "3.0")
gi.require_version("Gtk", "3.0")
gi.require_version("GtkLayerShell", "0.1")
from gi.repository import Gdk, GLib, Gtk, GtkLayerShell

PANEL_WIDTH = 480
MAX_HEIGHT = 640
EDGE_MARGIN = 16
GAP = 14
DRAG_THRESHOLD = 4

CSS = """
.ai-popup-panel {
    background-color: #1c1e26;
    border: 1px solid #3a3d4d;
    border-radius: 18px;
    box-shadow: 0 14px 36px rgba(0,0,0,0.42), 0 3px 8px rgba(0,0,0,0.28);
}
.ai-popup-header {
    background: transparent;
    padding: 0 0 0 12px;
    min-height: 34px;
}
.ai-popup-title {
    color: #9aa1b5;
    font-size: 12px;
    font-weight: 600;
    letter-spacing: 0.4px;
}
.ai-popup-section {
    background-color: #23262f;
    border-radius: 14px;
    padding: 8px 8px 8px 10px;
}
.ai-popup-section-label {
    color: #9aa1b5;
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0.5px;
    padding: 0 0 4px 2px;
}
.ai-popup-textview {
    background-color: transparent;
    font-size: 14px;
    color: #e6e9f0;
    padding: 0 4px 2px 2px;
}
.ai-popup-button {
    background-image: none;
    background-color: #2a2e3a;
    border: 1px solid #3a3d4d;
    border-radius: 999px;
    box-shadow: none;
    min-height: 28px;
    min-width: 28px;
    color: #c9cedd;
    padding: 0 10px;
}
.ai-popup-button:hover { background-color: #343948; }
.ai-popup-button:active { background-color: #3e4456; }
.ai-popup-copy {
    background-color: #e6b450;
    color: #1c1e26;
    border: none;
    font-weight: 600;
}
.ai-popup-copy:hover { background-color: #f0c06a; }
"""


def load_data() -> dict:
    data: dict = {}
    path: str | None = None
    if len(sys.argv) > 1 and os.path.isfile(sys.argv[1]):
        path = sys.argv[1]
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    else:
        raw = sys.stdin.read()
        if raw.strip():
            data = json.loads(raw)
    # The helper writes a temp file; remove it once loaded.
    if path:
        try:
            os.unlink(path)
        except OSError:
            pass
    return data


def make_textview(text: str) -> Gtk.TextView:
    view = Gtk.TextView()
    view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
    view.set_editable(False)
    view.set_cursor_visible(False)
    view.set_pixels_above_lines(2)
    view.set_pixels_below_lines(2)
    view.set_left_margin(2)
    view.set_right_margin(4)
    view.get_style_context().add_class("ai-popup-textview")
    # set_text keeps every newline; no markup collapse.
    view.get_buffer().set_text(text)
    return view


class PopupWindow(Gtk.Window):
    def __init__(self, data: dict):
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.data = data
        self.closed = False
        self.dragging = False
        self.pointer_positioned = False
        self.drag_pointer: tuple[int, int] = (0, 0)
        self.drag_margin: tuple[int, int] = (0, 0)

        self.set_app_paintable(True)
        visual = self.get_screen().get_rgba_visual()
        if visual:
            self.set_visual(visual)

        self._load_css()
        GtkLayerShell.init_for_window(self)
        GtkLayerShell.set_layer(self, GtkLayerShell.Layer.OVERLAY)
        GtkLayerShell.set_keyboard_mode(self, GtkLayerShell.KeyboardMode.EXCLUSIVE)
        GtkLayerShell.set_exclusive_zone(self, -1)
        # Anchor top-left so the panel is positioned purely via margins.
        GtkLayerShell.set_anchor(self, GtkLayerShell.Edge.LEFT, True)
        GtkLayerShell.set_anchor(self, GtkLayerShell.Edge.TOP, True)
        GtkLayerShell.set_margin(self, GtkLayerShell.Edge.LEFT, 0)
        GtkLayerShell.set_margin(self, GtkLayerShell.Edge.TOP, 0)

        self.add_events(
            Gdk.EventMask.POINTER_MOTION_MASK
            | Gdk.EventMask.BUTTON_PRESS_MASK
            | Gdk.EventMask.BUTTON_RELEASE_MASK
            | Gdk.EventMask.KEY_PRESS_MASK
        )

        key = Gtk.EventControllerKey.new(self)
        key.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        key.connect("key-pressed", self._on_key_pressed)

        motion = Gtk.EventControllerMotion.new(self)
        motion.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        motion.connect("motion", self._on_motion)
        gesture = Gtk.GestureMultiPress.new(self)
        gesture.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        gesture.set_exclusive(False)
        gesture.connect("pressed", self._on_press)
        gesture.connect("released", self._on_release)

        self._build(data)
        self.show_all()
        GLib.idle_add(self._position_panel)

    # -- layout ------------------------------------------------------------
    def _load_css(self) -> None:
        provider = Gtk.CssProvider()
        provider.load_from_data(CSS.encode("utf-8"))
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

    def _button(self, text: str, tooltip: str, copy: bool = False) -> Gtk.Button:
        btn = Gtk.Button(label=text)
        btn.set_tooltip_text(tooltip)
        btn.set_relief(Gtk.ReliefStyle.NONE)
        if copy:
            btn.get_style_context().add_class("ai-popup-copy")
        else:
            btn.get_style_context().add_class("ai-popup-button")
        return btn

    def _build(self, data: dict) -> None:
        title = data.get("title", "niri-ai")
        source = data.get("source", "")
        result = data.get("result", "")
        source_label = data.get("source_label", "原文")
        result_label = data.get("result_label", "译文")

        panel = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        panel.get_style_context().add_class("ai-popup-panel")
        panel.set_size_request(PANEL_WIDTH, -1)

        # Header: title + copy + close.
        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        header.get_style_context().add_class("ai-popup-header")
        title_label = Gtk.Label(label=title)
        title_label.set_xalign(0.0)
        title_label.get_style_context().add_class("ai-popup-title")
        header.pack_start(title_label, True, True, 0)

        copy_all = self._button("复制", "Copy translation", copy=True)
        copy_all.connect("clicked", lambda *_a: self._copy(result))
        header.pack_end(copy_all, False, False, 0)

        close_btn = self._button("✕", "Close (Esc)", copy=False)
        close_btn.connect("clicked", lambda *_a: self.close())
        header.pack_end(close_btn, False, False, 0)

        panel.pack_start(header, False, False, 0)

        # Source (only when present) and result, both preserving line breaks.
        sections = []
        if source:
            sections.append((source_label or "原文", source))
        sections.append((result_label or "译文", result))

        for label_text, body_text in sections:
            section = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            section.get_style_context().add_class("ai-popup-section")
            label = Gtk.Label(label=label_text)
            label.set_xalign(0.0)
            label.get_style_context().add_class("ai-popup-section-label")
            section.pack_start(label, False, False, 0)

            scroll = Gtk.ScrolledWindow()
            scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
            scroll.set_shadow_type(Gtk.ShadowType.NONE)
            scroll.set_size_request(-1, min(200, MAX_HEIGHT))
            scroll.add(make_textview(body_text))
            section.pack_start(scroll, True, True, 0)
            panel.pack_start(section, True, True, 0)

        self.add(panel)

    # -- copy --------------------------------------------------------------
    def _copy(self, text: str) -> None:
        clipboard = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
        clipboard.set_text(text, -1)
        clipboard.store()

    # -- positioning -------------------------------------------------------
    def _screen_geometry(self) -> tuple[int, int]:
        try:
            display = Gdk.Display.get_default()
            monitor = display.get_primary_monitor() if display else None
            if monitor:
                geo = monitor.get_geometry()
                return geo.width, geo.height
        except Exception:
            pass
        return 2560, 1440

    def _pointer_position(self) -> tuple[int, int] | None:
        try:
            display = Gdk.Display.get_default()
            seat = display.get_default_seat() if display else None
            pointer = seat.get_pointer() if seat else None
            if pointer:
                _screen, x, y = pointer.get_position()
                # Before any real Wayland pointer event, Gdk reports (0, 0);
                # treat that as "unknown" rather than a real top-left corner.
                if x == 0 and y == 0:
                    return None
                return x, y
        except Exception:
            pass
        return None

    def _place(self, margin_left: int, margin_top: int) -> None:
        width, height = self.get_allocated_width(), self.get_allocated_height()
        sw, sh = self._screen_geometry()
        if width <= 0 or height <= 0:
            width, height = PANEL_WIDTH, 320
        ml = max(EDGE_MARGIN, min(margin_left, sw - width - EDGE_MARGIN))
        mt = max(EDGE_MARGIN, min(margin_top, sh - height - EDGE_MARGIN))
        GtkLayerShell.set_margin(self, GtkLayerShell.Edge.LEFT, ml)
        GtkLayerShell.set_margin(self, GtkLayerShell.Edge.TOP, mt)
        self.drag_margin = (ml, mt)

    def _position_panel(self) -> bool:
        width, height = self.get_allocated_width(), self.get_allocated_height()
        sw, sh = self._screen_geometry()
        if width <= 0 or height <= 0:
            width, height = PANEL_WIDTH, 320

        ptr = self._pointer_position()
        if ptr and not self.pointer_positioned:
            px, py = ptr
            self._place(px - PANEL_WIDTH // 2, py + GAP)
            self.pointer_positioned = True
        elif not self.pointer_positioned:
            # Center as a safe fallback until a real pointer event arrives.
            self._place((sw - width) // 2, sh // 4)
        return False

    # -- drag --------------------------------------------------------------
    def _on_press(self, _g, _n, x: float, y: float) -> None:
        self.dragging = True
        self.drag_pointer = (int(x), int(y))

    def _on_release(self, _g, _n, _x: float, _y: float) -> None:
        self.dragging = False

    def _on_motion(self, _g, x: float, y: float) -> None:
        # Reposition near the pointer once, on the first real pointer event.
        if not self.dragging and not self.pointer_positioned:
            ptr = self._pointer_position()
            if ptr:
                px, py = ptr
                self._place(px - PANEL_WIDTH // 2, py + GAP)
                self.pointer_positioned = True
                return
        if not self.dragging:
            return
        dx = int(x) - self.drag_pointer[0]
        dy = int(y) - self.drag_pointer[1]
        if abs(dx) + abs(dy) < DRAG_THRESHOLD:
            return
        self._place(self.drag_margin[0] + dx, self.drag_margin[1] + dy)

    # -- key ---------------------------------------------------------------
    def _on_key_pressed(self, _c, keyval: int, _keycode: int, _state: int) -> bool:
        if keyval in (Gdk.KEY_Escape, Gdk.KEY_Return, Gdk.KEY_KP_Enter):
            self.close()
            return True
        return False

    def close(self) -> bool:
        if self.closed:
            return True
        self.closed = True
        self.destroy()
        return True


def main() -> int:
    data = load_data()
    if not data.get("result"):
        print("niri-ai-popup: no result text", file=sys.stderr)
        return 1
    win = PopupWindow(data)
    win.connect("destroy", lambda *_a: Gtk.main_quit())
    Gtk.main()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
