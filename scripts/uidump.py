#!/usr/bin/env python3
"""uidump.py - inspect the AT-SPI accessibility tree (semantic UI elements).

Usage:
  uidump.py tree [app-name-substring]   Dump element trees of visible windows
  uidump.py find <name-substring>       List elements whose name contains text

Element line format:
  [role] 'name' (x,y) WxH center=(cx,cy)
  [role] 'name' 0x0 center=none     (geometry untrusted — e.g. Qt apps under DDE)
`center=` is appended for machine parsing (used by xctrl.sh ui click);
`center=none` means the bridge reports no usable geometry — do NOT click
blindly, fall back to screenshot + --grid and pick the coordinate visually.

Requirements:
  sudo apt install at-spi2-core
GTK apps usually need: GTK_MODULES=gail:atk-bridge (restart the app).
Qt apps usually need:  QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1 (restart the app).
Run with the SYSTEM python (/usr/bin/python3); venv/bundled pythons often
lack the `gi` bindings.
"""
import sys

try:
    import gi
    gi.require_version('Atspi', '2.0')
    from gi.repository import Atspi
except Exception as e:
    print(f"ERROR: AT-SPI bindings unavailable ({e})", file=sys.stderr)
    print("hint: sudo apt install at-spi2-core, then retry with /usr/bin/python3", file=sys.stderr)
    sys.exit(2)

# Roles we report even without a name (usually actionable or informative)
INTERESTING_ROLES = {
    'push button', 'toggle button', 'check box', 'radio button', 'menu item',
    'check menu item', 'radio menu item', 'text', 'entry', 'password text',
    'combo box', 'list item', 'page tab', 'link', 'slider', 'spin button',
    'table cell', 'tree item', 'status bar', 'menu',
}

# Roles we descend into even when not showing (they may contain visible children)
CONTAINER_ROLES = {
    'application', 'frame', 'dialog', 'window', 'panel', 'root pane',
    'split pane', 'layered pane', 'scroll pane', 'desktop frame',
    'menu bar', 'tool bar', 'page tab list', 'list', 'table', 'tree',
    'tree table', 'combo box', 'menu', 'popup menu', 'menu item',
}


def connect():
    # dbind raises a FATAL g_error (process aborts, uncatchable) when the
    # accessibility bus is missing, so probe the bus via plain DBus first.
    from gi.repository import Gio
    try:
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        bus.call_sync('org.a11y.Bus', '/org/a11y/bus',
                      'org.freedesktop.DBus.Peer', 'Ping', None, None,
                      Gio.DBusCallFlags.NONE, 2000, None)
    except Exception:
        print("ERROR: no accessibility bus on the session bus (org.a11y.Bus missing)", file=sys.stderr)
        print("hint: sudo apt install at-spi2-core, then retry "
              "(if the tree is still empty, restart the target app with "
              "GTK_MODULES=gail:atk-bridge or QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1)",
              file=sys.stderr)
        sys.exit(2)
    try:
        desktop = Atspi.get_desktop(0)
        desktop.get_child_count()
    except Exception as e:
        print(f"ERROR: cannot reach the accessibility bus ({e})", file=sys.stderr)
        print("hint: sudo apt install at-spi2-core, then retry "
              "(if the tree is still empty, restart the target app with "
              "GTK_MODULES=gail:atk-bridge or QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1)",
              file=sys.stderr)
        sys.exit(2)
    return desktop


def element_info(obj):
    try:
        role = obj.get_role_name()
        name = (obj.get_name() or "").strip()
    except Exception:
        return None, None, None
    try:
        ext = obj.get_extents(Atspi.CoordType.SCREEN)
    except Exception:
        ext = None
    return role, name, ext


def is_showing(obj):
    try:
        return obj.get_state_set().contains(Atspi.StateType.SHOWING)
    except Exception:
        return True


def walk(obj, depth, maxd, out, geo_trusted=False):
    """geo_trusted: True when an ancestor frame/window reported valid screen
    extents. Qt bridges (DDE) report 0x0 frames and popup-local widget coords,
    so element extents are only trusted inside a geometrically-valid window."""
    if depth > maxd or obj is None:
        return
    role, name, ext = element_info(obj)
    if role is None:
        return
    showing = is_showing(obj)
    ext_ok = ext is not None and ext.width > 0 and ext.height > 0
    if role in ('frame', 'window', 'dialog') and ext_ok:
        geo_trusted = True
    # Qt bridges (e.g. DDE) often report showing=False even for on-screen
    # widgets, so do NOT gate on state for named elements — record them and
    # let fmt() mark untrusted geometry.
    if name or (showing and role in INTERESTING_ROLES):
        out.append((depth, role, name, ext if (ext_ok and geo_trusted) else None))
    if not showing and role not in CONTAINER_ROLES:
        return
    try:
        n = obj.get_child_count()
    except Exception:
        return
    for i in range(min(n, 300)):
        try:
            walk(obj.get_child_at_index(i), depth + 1, maxd, out, geo_trusted)
        except Exception:
            return


def fmt(ext):
    """Format geometry; ext=None means untrusted/unavailable (do not click)."""
    if ext is None:
        return "0x0 center=none"
    cx = ext.x + ext.width // 2
    cy = ext.y + ext.height // 2
    return f"({ext.x},{ext.y}) {ext.width}x{ext.height} center=({cx},{cy})"


def collect(desktop):
    """Yield (app_name, elements) for every app."""
    for i in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(i)
        try:
            aname = app.get_name() or ""
        except Exception:
            continue
        out = []
        walk(app, 0, 14, out)
        yield aname, out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    mode = sys.argv[1]
    desktop = connect()

    if mode == "tree":
        pattern = sys.argv[2].lower() if len(sys.argv) > 2 else ""
        for aname, out in collect(desktop):
            if pattern and pattern not in aname.lower():
                continue
            print(f"APP: {aname}")
            for depth, role, name, ext in out:
                print(f"{'  ' * min(depth, 10)}[{role}] {name!r} {fmt(ext)}")
        return 0

    if mode == "find":
        if len(sys.argv) < 3:
            print("usage: uidump.py find <name-substring>", file=sys.stderr)
            return 1
        needle = sys.argv[2].lower()
        found = 0
        for _aname, out in collect(desktop):
            for _depth, role, name, ext in out:
                if needle in name.lower():
                    print(f"[{role}] {name!r} {fmt(ext)}")
                    found += 1
        if not found:
            print(f"no accessible element matching '{needle}'", file=sys.stderr)
            return 4
        return 0

    print(f"unknown mode: {mode}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
