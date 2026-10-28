#!/usr/bin/env bash
# xctrl.sh - X11 input injection & screen capture helper (v1.5.0)
# Wraps xdotool (pointer/keyboard/window) and ImageMagick (import/identify).
#
# Usage: xctrl.sh <command> [args...]
#   check                          Verify X11 session and required tools
#   pos                            Print current pointer position
#   move <x> <y>                   Move pointer (no click)
#   click <x> <y> [button] [--verify]
#                                  Move + click (button: 1=left 2=mid 3=right).
#                                  --verify diffs the screen before/after the
#                                  click and warns when nothing changed nearby
#   dclick <x> <y>                 Move + double click
#   rclick <x> <y>                 Move + right click
#   drag <x1> <y1> <x2> <y2>       Press at (x1,y1), move, release at (x2,y2)
#   scroll <x> <y> <clicks>        Move + wheel scroll; positive = down, negative = up
#   act "<cmd> ; <cmd> ; ..."      Run several xctrl commands in one round-trip.
#                                  Steps: click/dclick/rclick/move/scroll/type/
#                                  key/drag/sleep/pos/coord/win/clipboard.
#                                  Stops at first failure; ';' inside quoted
#                                  text is not supported.
#   type [--clipboard|--no-clipboard] [--paste-key <combo>] <text>
#                                  Type text; CJK/emoji auto-use clipboard
#   key <combo>                    Send key combo, e.g. "ctrl+c" "alt+F4" "Return"
#   clipboard get|set [text]       Read/write the X CLIPBOARD selection
#                                  (set without text reads stdin)
#   waitfor win <title> [--timeout <sec>]
#                                  Block until a window matching <title> appears
#   waitfor change <x> <y> [--timeout <sec>]
#                                  Block until pixels change near (x,y)
#   ui tree                        Dump AT-SPI accessibility tree (semantic
#                                  elements with names/roles/coords)
#   ui find <text>                 Find elements whose name contains <text>
#   ui click <text>                Click the first matching element's center.
#                                  Requires at-spi2-core (sudo apt install
#                                  at-spi2-core); degrades with a clear error
#   win search <name>              List window ids matching name (id | geometry | title)
#   win list                       List all visible windows (topmost first)
#   win activate <id|name>         Activate (focus+raise) a window by id or title
#   win geom <id|name>             Print geometry of a window id
#   shot <out> [--win <id|name>] [--crop <WxH+X+Y>] [--delay <sec>]
#              [--max-width <px>] [--quality <1-100>] [--mark <x,y>]
#              [--grid [step]] [--dual <path>] [--dual-width <px>]
#                                  Capture screen / window / region; optional
#                                  downscale. --grid overlays a coordinate grid
#                                  labeled in screen coords (step in screen px,
#                                  default 200; auto-coarsens when too dense)
#                                  --dual additionally writes a downscaled JPEG
#                                  preview (default width 1280) in one capture
#                                  --mark draws a crosshair at screen (x,y)
#   coord <x> <y> <scale> [off_x off_y]
#                                  Convert image coords to screen coords
#
# Exit codes: 0 ok, 1 usage/action error, 2 environment error, 4 not found.

set -u

cmd="${1:-}"; shift || true
export DISPLAY="${DISPLAY:-:0}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

need_tool() {
    command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH" >&2; exit 2; }
}

# ImageMagick 6 ships import/identify/convert; ImageMagick 7 ships `magick`.
IM_MODE=""
if command -v import >/dev/null 2>&1 && command -v identify >/dev/null 2>&1; then
    IM_MODE="im6"
elif command -v magick >/dev/null 2>&1; then
    IM_MODE="im7"
fi

im_import() {
    if [ "$IM_MODE" = "im6" ]; then import "$@"; else magick import "$@"; fi
}

im_identify() {
    if [ "$IM_MODE" = "im6" ]; then identify "$@"; else magick identify "$@"; fi
}

im_convert() {
    if [ "$IM_MODE" = "im6" ]; then convert "$@"; else magick "$@"; fi
}

im_compare() {
    if [ "$IM_MODE" = "im6" ]; then compare "$@"; else magick compare "$@"; fi
}

warn_wayland() {
    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
        echo "WARN: Wayland session; xdotool/import only cover XWayland (X11) windows; native Wayland content may be missing." >&2
    fi
}

require_x11() {
    need_tool xdotool
    if ! xdotool getdisplaygeometry >/dev/null 2>&1; then
        echo "ERROR: cannot talk to X display '${DISPLAY}' (X11 session? correct DISPLAY?)" >&2
        exit 2
    fi
}

# Warp the pointer to (x,y), waiting until it arrives.
# xdotool mousemove --sync polls ~15s when the pointer is ALREADY at the
# target (no motion event is generated to wait for), so short-circuit that
# case by checking the current position first.
warp() {
    eval "$(xdotool getmouselocation --shell 2>/dev/null)" || true
    if [ "${X:-}" = "$1" ] && [ "${Y:-}" = "$2" ]; then
        return 0
    fi
    xdotool mousemove --sync "$1" "$2"
}

screen_geometry() {
    xdotool getdisplaygeometry 2>/dev/null | awk 'NF>=2 {print $1"x"$2}'
}

resolve_win_id() {
    # accept numeric id directly, otherwise search by title (first match)
    case "$1" in
        ''|*[!0-9]*) xdotool search --name "$1" 2>/dev/null | head -n 1 ;;
        *) echo "$1" ;;
    esac
}

img_size() {
    # $1: image path -> "WxH" (empty when unreadable)
    im_identify -format '%wx%h' "$1" 2>/dev/null
}

is_uint() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# Paste text through the X clipboard, then restore the previous clipboard.
# Needed for CJK/emoji, which xdotool type cannot reliably synthesize.
paste_text() {
    ptext="$1"
    pastekey="${2:-ctrl+v}"

    clipper=""
    if command -v xclip >/dev/null 2>&1; then
        clipper="xclip"
    elif command -v xsel >/dev/null 2>&1; then
        clipper="xsel"
    fi
    if [ -z "$clipper" ]; then
        echo "WARN: xclip/xsel not found; non-ASCII text may be dropped by xdotool." >&2
        xdotool type --delay 30 -- "$ptext" || die "typing failed"
        return 0
    fi

    oldfile=$(mktemp)
    had=0
    if [ "$clipper" = "xclip" ]; then
        timeout 1 xclip -selection clipboard -o >"$oldfile" 2>/dev/null && had=1
        printf '%s' "$ptext" | xclip -selection clipboard >/dev/null 2>&1 || { rm -f "$oldfile"; die "cannot write clipboard"; }
    else
        timeout 1 xsel --clipboard --output >"$oldfile" 2>/dev/null && had=1
        printf '%s' "$ptext" | xsel --clipboard --input >/dev/null 2>&1 || { rm -f "$oldfile"; die "cannot write clipboard"; }
    fi

    sleep 0.15
    if ! xdotool key --clearmodifiers -- "$pastekey"; then
        rm -f "$oldfile"
        die "paste key '$pastekey' failed (try --paste-key ctrl+shift+v for terminals)"
    fi
    sleep 0.3

    if [ "$had" -eq 1 ]; then
        if [ "$clipper" = "xclip" ]; then
            xclip -selection clipboard <"$oldfile" >/dev/null 2>&1 || true
        else
            xsel --clipboard --input <"$oldfile" >/dev/null 2>&1 || true
        fi
    else
        if [ "$clipper" = "xclip" ]; then
            printf '' | xclip -selection clipboard >/dev/null 2>&1 || true
        else
            printf '' | xsel --clipboard --input >/dev/null 2>&1 || true
        fi
    fi
    rm -f "$oldfile"
    echo "typed via clipboard ($clipper, paste key '$pastekey'); clipboard restored: $([ "$had" -eq 1 ] && echo yes || echo cleared)" >&2
}

usage() {
    cat <<'EOF'
Usage: xctrl.sh <command> [args...]
  check                          Verify X11 session and required tools
  pos                            Print current pointer position
  move <x> <y>                   Move pointer (no click)
  click <x> <y> [button] [--verify]
                                 Move + click; --verify diffs screen around the
                                 click point before/after and warns on no change
  dclick <x> <y>                 Move + double click
  rclick <x> <y>                 Move + right click
  drag <x1> <y1> <x2> <y2>       Press at (x1,y1), move, release at (x2,y2)
  scroll <x> <y> <clicks>        Move + wheel scroll (positive=down, negative=up)
  type [--clipboard|--no-clipboard] [--paste-key <combo>] <text>
                                 Type text; CJK/emoji auto-use clipboard
  key <combo>                    Send key combo, e.g. "ctrl+c" "alt+F4" "Return"
  clipboard get|set [text]       Read/write the X CLIPBOARD selection
  waitfor win <title> [--timeout <sec>]
                                 Block until a window matching <title> appears
  waitfor change <x> <y> [--timeout <sec>]
                                 Block until pixels change near (x,y)
  ui tree|find <text>|click <text>
                                 AT-SPI semantic tree / find / click (needs
                                 at-spi2-core; graceful error if missing)
  win search <name>              List windows matching name (id | geometry | title)
  win list                       List all visible windows (topmost first)
  win activate <id|name>         Activate (focus+raise) a window by id or title
  win geom <id|name>             Print geometry of a window id
  shot <out> [--win <id|name>] [--crop <WxH+X+Y>] [--delay <sec>]
             [--max-width <px>] [--quality <1-100>] [--mark <x,y>]
             [--grid [step]] [--dual <path>] [--dual-width <px>]
                                 Capture screen / window / region; optional downscale.
                                 --grid overlays a coordinate grid labeled in screen
                                 coords (default step 200, auto-coarsens when dense).
                                 --dual also writes a downscaled JPEG preview
                                 --mark draws a crosshair at screen (x,y) for verification
  act "<cmd> ; <cmd> ; ..."      Run several xctrl commands in one round-trip
                                 (steps: click/dclick/rclick/move/scroll/type/key/
                                 drag/sleep/pos/coord/win/clipboard; stops at
                                 first failure; no ';' inside quoted text)
  coord <x> <y> <scale> [off_x off_y]
                                 Convert image coords to screen coords
EOF
}

# --- help ---------------------------------------------------------------
case "$cmd" in
    ""|help|-h|--help)
        usage
        exit 0
        ;;
esac

warn_wayland

case "$cmd" in
    check)
        echo "session: ${XDG_SESSION_TYPE:-unknown}  desktop: ${XDG_CURRENT_DESKTOP:-unknown}  display: ${DISPLAY:-unset}"
        missing=0
        if command -v xdotool >/dev/null 2>&1; then
            echo "tool ok : xdotool ($(command -v xdotool))"
        else
            echo "tool MISSING: xdotool"
            missing=1
        fi
        if [ -n "$IM_MODE" ]; then
            echo "imagemagick: $IM_MODE"
        else
            echo "tool MISSING: ImageMagick (import/identify, or magick)"
            missing=1
        fi
        for t in xclip xsel; do
            if command -v "$t" >/dev/null 2>&1; then
                echo "tool opt: $t ($(command -v "$t"))"
            fi
        done
        geom=$(screen_geometry)
        if [ -n "$geom" ]; then
            echo "screen: $geom  ($DISPLAY reachable)"
        else
            echo "ERROR: cannot talk to X display '${DISPLAY}' (is it X11? is DISPLAY correct?)"
            missing=1
        fi
        # semantic features (ui tree/find/click) need the AT-SPI bus
        a11y="unknown"
        if [ -x /usr/bin/python3 ]; then
            a11y=$(/usr/bin/python3 -c '
from gi.repository import Gio
try:
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    bus.call_sync("org.a11y.Bus", "/org/a11y/bus", "org.freedesktop.DBus.Peer",
                  "Ping", None, None, Gio.DBusCallFlags.NONE, 2000, None)
    print("ok")
except Exception:
    print("off")
' 2>/dev/null || echo "unknown")
        fi
        case "$a11y" in
            ok)
                echo "accessibility: ok  (ui tree/find/click available)" ;;
            off)
                echo "accessibility: off (ui commands unavailable; enable with: sudo apt install at-spi2-core; other commands unaffected)" ;;
            *)
                echo "accessibility: unknown (/usr/bin/python3 with gi bindings not found; ui commands may not work)" ;;
        esac
        [ "$missing" -eq 0 ] || exit 2
        ;;

    pos)
        require_x11
        xdotool getmouselocation
        ;;

    move)
        [ $# -ge 2 ] || die "usage: move <x> <y>"
        require_x11
        warp "$1" "$2" || die "mousemove failed at ($1,$2)"
        ;;

    click)
        pargs=(); verify=0
        while [ $# -gt 0 ]; do
            case "$1" in
                --verify) verify=1; shift ;;
                *) pargs+=("$1"); shift ;;
            esac
        done
        [ ${#pargs[@]} -ge 2 ] || die "usage: click <x> <y> [button] [--verify]"
        x="${pargs[0]}"; y="${pargs[1]}"; btn="${pargs[2]:-1}"
        case "$btn" in 1|2|3) ;; *) die "button must be 1, 2 or 3" ;; esac
        require_x11
        if [ "$verify" -eq 1 ]; then
            # Only capture a small region around the click point: full-screen
            # 4K captures twice would make --verify take >15s.
            sg=$(screen_geometry); sw=${sg%x*}; sh=${sg#*x}
            rw=240; rh=240
            rx=$(( x - rw / 2 )); ry=$(( y - rh / 2 ))
            [ "$rx" -lt 0 ] && rx=0
            [ "$ry" -lt 0 ] && ry=0
            if [ -n "$sw" ] && [ $(( rx + rw )) -gt "$sw" ]; then rx=$(( sw - rw )); fi
            if [ -n "$sh" ] && [ $(( ry + rh )) -gt "$sh" ]; then ry=$(( sh - rh )); fi
            [ "$rx" -lt 0 ] && rx=0
            [ "$ry" -lt 0 ] && ry=0
            bf=$(mktemp /tmp/xctrl_vfy_b_XXXXXX.png)
            im_import -window root -crop "${rw}x${rh}+${rx}+${ry}" "$bf" \
                || { rm -f "$bf"; die "verify: before-capture failed"; }
        fi
        warp "$x" "$y" || die "mousemove failed at ($x,$y)"
        xdotool click --delay 60 "$btn" || die "click failed at ($x,$y)"
        if [ "$verify" -eq 1 ]; then
            sleep 0.5
            af=$(mktemp /tmp/xctrl_vfy_a_XXXXXX.png)
            im_import -window root -crop "${rw}x${rh}+${rx}+${ry}" "$af" \
                || { rm -f "$bf" "$af"; die "verify: after-capture failed"; }
            ae=$(im_compare -metric AE "$bf" "$af" null: 2>&1 || true)
            rm -f "$bf" "$af"
            # compare may print scientific notation for large counts (e.g. 2.02e+08)
            raw="${ae%% *}"
            if printf '%s' "$raw" | LC_ALL=C grep -qE '^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$'; then
                ae_num=$(awk -v v="$raw" 'BEGIN { printf "%d", v + 0 }')
                case "$ae_num" in
                    0)
                        echo "WARN verify: NO pixel change near ($x,$y) — click may have missed; re-screenshot to confirm" >&2 ;;
                    *)
                        echo "verify: ok — $ae_num px changed near ($x,$y)" ;;
                esac
            else
                echo "verify: inconclusive near ($x,$y) (compare: $ae) — take a screenshot to confirm"
            fi
        else
            sleep 0.3
        fi
        ;;

    dclick)
        [ $# -ge 2 ] || die "usage: dclick <x> <y>"
        require_x11
        warp "$1" "$2" || die "mousemove failed at ($1,$2)"
        xdotool click --repeat 2 --delay 120 1 || die "double click failed at ($1,$2)"
        sleep 0.3
        ;;

    rclick)
        [ $# -ge 2 ] || die "usage: rclick <x> <y>"
        require_x11
        warp "$1" "$2" || die "mousemove failed at ($1,$2)"
        xdotool click 3 || die "right click failed at ($1,$2)"
        sleep 0.3
        ;;

    drag)
        [ $# -ge 4 ] || die "usage: drag <x1> <y1> <x2> <y2>"
        require_x11
        warp "$1" "$2" || die "mousemove failed at ($1,$2)"
        xdotool mousedown 1 || die "mousedown failed at ($1,$2)"
        warp "$3" "$4" || { xdotool mouseup 1; die "mousemove failed at ($3,$4)"; }
        xdotool mouseup 1 || die "mouseup failed at ($3,$4)"
        sleep 0.3
        ;;

    scroll)
        [ $# -ge 3 ] || die "usage: scroll <x> <y> <clicks>  (positive=wheel down, negative=wheel up)"
        [[ "$3" =~ ^-?[0-9]+$ ]] || die "clicks must be a signed integer"
        [ "$3" -ne 0 ] || die "clicks must not be 0"
        require_x11
        warp "$1" "$2" || die "mousemove failed at ($1,$2)"
        if [ "$3" -gt 0 ]; then
            xdotool click --repeat "$3" --delay 60 5 || die "scroll down failed at ($1,$2)"
        else
            n=$(( 0 - $3 ))
            xdotool click --repeat "$n" --delay 60 4 || die "scroll up failed at ($1,$2)"
        fi
        sleep 0.2
        ;;

    act)
        [ $# -ge 1 ] || die 'usage: act "<cmd> [args] ; <cmd> [args] ; ..."  (steps: click/dclick/rclick/move/scroll/type/key/drag/sleep; ";" inside quoted text is not supported)'
        stepno=0
        rest="$1"
        while [ -n "$rest" ]; do
            step="${rest%%;*}"
            if [ "$step" = "$rest" ]; then rest=""; else rest="${rest#*;}"; fi
            # trim leading/trailing whitespace
            step="${step#"${step%%[![:space:]]*}"}"
            step="${step%"${step##*[![:space:]]}"}"
            [ -n "$step" ] || continue
            stepno=$(( stepno + 1 ))
            # Split with read (no eval, no globbing): text containing $(...) or
            # backticks is passed through literally and can never be executed.
            read -r -a sargv <<< "$step"
            [ "${#sargv[@]}" -gt 0 ] || continue
            scmd="${sargv[0]}"
            case "$scmd" in
                sleep)
                    sleep "${sargv[1]:-1}" || die "act: step $stepno (sleep) failed"
                    ;;
                click|dclick|rclick|move|scroll|type|key|drag|pos|coord|win|clipboard)
                    "$0" "$scmd" "${sargv[@]:1}" || die "act: step $stepno failed: $step"
                    ;;
                *)
                    die "act: unknown step command '$scmd' (step $stepno: $step)"
                    ;;
            esac
        done
        echo "act: done ($stepno step(s))"
        ;;

    waitfor)
        mode="${1:-}"; shift || true
        wtimeout=10
        pargs=()
        while [ $# -gt 0 ]; do
            case "$1" in
                --timeout) [ $# -ge 2 ] || die "--timeout needs a value"; wtimeout="$2"; shift 2 ;;
                *) pargs+=("$1"); shift ;;
            esac
        done
        case "$wtimeout" in ''|*[!0-9.]*) die "--timeout must be a number" ;; esac
        # deadline arithmetic needs integers: round fractional timeouts up
        wtimeout=$(awk -v t="$wtimeout" 'BEGIN { printf "%d", (t == int(t)) ? t : int(t) + 1 }')
        require_x11
        deadline=$(( $(date +%s) + wtimeout ))
        case "$mode" in
            win)
                [ ${#pargs[@]} -ge 1 ] || die "usage: waitfor win <title> [--timeout <sec>]"
                title="${pargs[0]}"
                while :; do
                    hit=$(xdotool search --name "$title" 2>/dev/null | head -n 1 || true)
                    if [ -n "$hit" ]; then
                        echo "matched: window $hit ($(xdotool getwindowname "$hit" 2>/dev/null))"
                        exit 0
                    fi
                    [ "$(date +%s)" -lt "$deadline" ] || { echo "ERROR: timeout after ${wtimeout}s waiting for window '$title'" >&2; exit 1; }
                    sleep 0.3
                done
                ;;
            change)
                [ ${#pargs[@]} -ge 2 ] || die "usage: waitfor change <x> <y> [--timeout <sec>]"
                x="${pargs[0]}"; y="${pargs[1]}"
                sg=$(screen_geometry); sw=${sg%x*}; sh=${sg#*x}
                rw=240; rh=240
                rx=$(( x - rw / 2 )); ry=$(( y - rh / 2 ))
                [ "$rx" -lt 0 ] && rx=0
                [ "$ry" -lt 0 ] && ry=0
                if [ -n "$sw" ] && [ $(( rx + rw )) -gt "$sw" ]; then rx=$(( sw - rw )); fi
                if [ -n "$sh" ] && [ $(( ry + rh )) -gt "$sh" ]; then ry=$(( sh - rh )); fi
                [ "$rx" -lt 0 ] && rx=0
                [ "$ry" -lt 0 ] && ry=0
                base=$(mktemp /tmp/xctrl_wf_b_XXXXXX.png)
                im_import -window root -crop "${rw}x${rh}+${rx}+${ry}" "$base" \
                    || { rm -f "$base"; die "waitfor: baseline capture failed"; }
                cur=$(mktemp /tmp/xctrl_wf_c_XXXXXX.png)
                while :; do
                    im_import -window root -crop "${rw}x${rh}+${rx}+${ry}" "$cur" \
                        || { rm -f "$base" "$cur"; die "waitfor: capture failed"; }
                    ae=$(im_compare -metric AE "$base" "$cur" null: 2>&1 || true)
                    raw="${ae%% *}"
                    if printf '%s' "$raw" | LC_ALL=C grep -qE '^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$'; then
                        ae_num=$(awk -v v="$raw" 'BEGIN { printf "%d", v + 0 }')
                        if [ "$ae_num" -gt 0 ]; then
                            rm -f "$base" "$cur"
                            echo "changed: $ae_num px near ($x,$y)"
                            exit 0
                        fi
                    fi
                    [ "$(date +%s)" -lt "$deadline" ] || { rm -f "$base" "$cur"; echo "ERROR: timeout after ${wtimeout}s waiting for change near ($x,$y)" >&2; exit 1; }
                    sleep 0.3
                done
                ;;
            *)
                die "usage: waitfor win <title> | waitfor change <x> <y> [--timeout <sec>]" ;;
        esac
        ;;

    type)
        use_clip="auto"; paste_key="ctrl+v"
        while [ $# -gt 0 ]; do
            case "$1" in
                --clipboard) use_clip=1; shift ;;
                --no-clipboard) use_clip=0; shift ;;
                --paste-key)
                    [ $# -ge 2 ] || die "--paste-key needs a value"
                    paste_key="$2"; shift 2 ;;
                --) shift; break ;;
                -*) die "unknown type option: $1" ;;
                *) break ;;
            esac
        done
        [ $# -ge 1 ] || die "usage: type [--clipboard] [--paste-key <combo>] <text>"
        text="$1"
        require_x11
        if [ "$use_clip" = "auto" ]; then
            if printf '%s' "$text" | LC_ALL=C grep -q '[^ -~]'; then
                use_clip=1
            else
                use_clip=0
            fi
        fi
        if [ "$use_clip" = "1" ]; then
            paste_text "$text" "$paste_key"
        else
            xdotool type --delay 30 -- "$text" || die "typing failed (focused window? non-ASCII text is not always supported)"
        fi
        ;;

    key)
        [ $# -ge 1 ] || die "usage: key <combo>  e.g. ctrl+c / Return / alt+F4"
        require_x11
        xdotool key --delay 60 -- "$1" || die "key '$1' failed (use X keysym names: Return, Escape, Tab, super ...)"
        sleep 0.2
        ;;

    clipboard)
        sub="${1:-}"; shift || true
        clipper=""
        if command -v xclip >/dev/null 2>&1; then
            clipper="xclip"
        elif command -v xsel >/dev/null 2>&1; then
            clipper="xsel"
        else
            die "need xclip or xsel (sudo apt install xclip)"
        fi
        case "$sub" in
            get)
                if [ "$clipper" = "xclip" ]; then
                    timeout 2 xclip -selection clipboard -o 2>/dev/null || die "cannot read clipboard (empty or non-text owner?)"
                else
                    timeout 2 xsel --clipboard --output 2>/dev/null || die "cannot read clipboard (empty or non-text owner?)"
                fi
                ;;
            set)
                if [ "$clipper" = "xclip" ]; then
                    if [ $# -ge 1 ]; then printf '%s' "$1" | xclip -selection clipboard -i >/dev/null 2>&1; else xclip -selection clipboard -i >/dev/null 2>&1; fi \
                        || die "cannot write clipboard"
                else
                    if [ $# -ge 1 ]; then printf '%s' "$1" | xsel --clipboard --input >/dev/null 2>&1; else xsel --clipboard --input >/dev/null 2>&1; fi \
                        || die "cannot write clipboard"
                fi
                echo "clipboard set ($clipper)"
                ;;
            *) die "usage: clipboard get | clipboard set [text]  (set without text reads stdin)" ;;
        esac
        ;;

    ui)
        sub="${1:-}"; shift || true
        uidump="$SKILL_DIR/scripts/uidump.py"
        [ -f "$uidump" ] || die "uidump.py not found next to xctrl.sh"
        need_tool /usr/bin/python3
        case "$sub" in
            tree)
                exec /usr/bin/python3 "$uidump" tree "$@"
                ;;
            find)
                [ $# -ge 1 ] || die "usage: ui find <name-substring>"
                exec /usr/bin/python3 "$uidump" find "$1"
                ;;
            click)
                [ $# -ge 1 ] || die "usage: ui click <name-substring>"
                require_x11
                found=$(/usr/bin/python3 "$uidump" find "$1" 2>&1) || true
                first=$(printf '%s\n' "$found" | grep -m1 'center=(-\{0,1\}[0-9]') || true
                if [ -n "$first" ]; then
                    cx=$(printf '%s' "$first" | sed -n 's/.*center=(\(-\{0,1\}[0-9]*\),\(-\{0,1\}[0-9]*\)).*/\1/p')
                    cy=$(printf '%s' "$first" | sed -n 's/.*center=(\(-\{0,1\}[0-9]*\),\(-\{0,1\}[0-9]*\)).*/\2/p')
                    [ -n "$cx" ] && [ -n "$cy" ] || die "ui click: cannot parse center from: $first"
                    echo "ui click: '$1' -> ($cx,$cy) $first"
                    warp "$cx" "$cy" || die "mousemove failed at ($cx,$cy)"
                    xdotool click --delay 60 1 || die "click failed at ($cx,$cy)"
                    sleep 0.3
                elif printf '%s\n' "$found" | grep -q 'center=none'; then
                    names=$(printf '%s\n' "$found" | head -3 | tr '\n' ' ' | cut -c1-200)
                    die "ui click: matched '$1' but the app reports no trustworthy geometry (Qt/DDE limitation). Locate visually instead: shot --grid + click by coordinate. Matches: $names"
                else
                    die "ui click: no accessible element matching '$1' (see: ui find)"
                fi
                ;;
            *) die "usage: ui tree | ui find <text> | ui click <text>" ;;
        esac
        ;;

    win)
        sub="${1:-}"; shift || true
        require_x11
        case "$sub" in
            list)
                ids=$(xdotool search --onlyvisible --name '' 2>/dev/null || true)
                [ -n "$ids" ] || { echo "no visible windows" >&2; exit 4; }
                for id in $ids; do
                    geom=$(xdotool getwindowgeometry "$id" 2>/dev/null | tr '\n' ' ')
                    name=$(xdotool getwindowname "$id" 2>/dev/null || true)
                    echo "$id | $geom| $name"
                done
                ;;
            search)
                [ $# -ge 1 ] || die "usage: win search <name>"
                ids=$(xdotool search --name "$1" 2>/dev/null || true)
                [ -n "$ids" ] || { echo "no window matched: $1" >&2; exit 4; }
                for id in $ids; do
                    geom=$(xdotool getwindowgeometry "$id" 2>/dev/null | tr '\n' ' ')
                    name=$(xdotool getwindowname "$id" 2>/dev/null || true)
                    echo "$id | $geom| $name"
                done
                ;;
            activate)
                [ $# -ge 1 ] || die "usage: win activate <id|name>"
                id=$(resolve_win_id "$1")
                [ -n "$id" ] || { echo "ERROR: no window matched '$1'" >&2; exit 4; }
                if ! xdotool windowactivate --sync "$id" 2>/dev/null; then
                    # Some WMs lack EWMH _NET_ACTIVE_WINDOW; fall back to focus+raise.
                    xdotool windowfocus "$id" 2>/dev/null && xdotool windowraise "$id" 2>/dev/null \
                        || die "activate failed for window $id"
                fi
                echo "activated $id ($(xdotool getwindowname "$id" 2>/dev/null))"
                ;;
            geom)
                [ $# -ge 1 ] || die "usage: win geom <id|name>"
                id=$(resolve_win_id "$1")
                [ -n "$id" ] || { echo "ERROR: no window matched '$1'" >&2; exit 4; }
                xdotool getwindowgeometry "$id"
                ;;
            *) die "usage: win search|activate|geom ..." ;;
        esac
        ;;

    shot)
        [ $# -ge 1 ] || die "usage: shot <out> [--win <id|name>] [--crop <WxH+X+Y>] [--delay <sec>] [--max-width <px>] [--quality <1-100>] [--mark <x,y>] [--grid [step]]"
        out="$1"; shift
        win_id=""; crop=""; delay=0; maxw=0; quality=85; mark=""; grid=0; dual=""; dualw=1280
        while [ $# -gt 0 ]; do
            case "$1" in
                --win)       [ $# -ge 2 ] || die "--win needs a value";        win_id="$2";  shift 2 ;;
                --crop)      [ $# -ge 2 ] || die "--crop needs a value";       crop="$2";    shift 2 ;;
                --delay)     [ $# -ge 2 ] || die "--delay needs a value";      delay="$2";   shift 2 ;;
                --max-width) [ $# -ge 2 ] || die "--max-width needs a value";  maxw="$2";    shift 2 ;;
                --quality)   [ $# -ge 2 ] || die "--quality needs a value";    quality="$2"; shift 2 ;;
                --mark)      [ $# -ge 2 ] || die "--mark needs a value";       mark="$2";    shift 2 ;;
                --dual)      [ $# -ge 2 ] || die "--dual needs a value";       dual="$2";    shift 2 ;;
                --dual-width)
                             [ $# -ge 2 ] || die "--dual-width needs a value"; dualw="$2";   shift 2 ;;
                --grid)
                    grid=200
                    shift
                    if [ $# -gt 0 ] && [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]; then grid="$1"; shift; fi ;;
                *) die "unknown shot option: $1" ;;
            esac
        done
        is_uint "$maxw" || die "--max-width must be an integer"
        is_uint "$dualw" || die "--dual-width must be an integer"
        [ -z "$dual" ] || mkdir -p "$(dirname "$dual")"
        is_uint "$delay" || die "--delay must be a number of seconds"
        is_uint "$maxw" || die "--max-width must be an integer"
        is_uint "$quality" || die "--quality must be an integer (1-100)"
        [ "$quality" -ge 1 ] && [ "$quality" -le 100 ] || die "--quality must be 1-100"
        if [ -n "$mark" ]; then
            [[ "$mark" =~ ^-?[0-9]+,-?[0-9]+$ ]] || die "--mark must be <screen_x>,<screen_y>"
            [ -z "$win_id" ] || die "--mark is not supported with --win (use full-screen or --crop)"
            if [ -n "$crop" ]; then
                [[ "$crop" =~ ^[0-9]+x[0-9]+[+-][0-9]+[+-][0-9]+$ ]] || die "--mark with --crop needs an explicit +X+Y offset"
            fi
        fi

        [ "$delay" -gt 0 ] && sleep "$delay"
        mkdir -p "$(dirname "$out")"
        [ -n "$IM_MODE" ] || die "ImageMagick not found (need import/identify or magick)"
        is_jpeg=0
        case "$out" in *.jpg|*.jpeg|*.JPG|*.JPEG) is_jpeg=1 ;; esac
        capture() {
            if [ "$is_jpeg" -eq 1 ]; then
                im_import "$@" -quality "$quality" "$out"
            else
                im_import "$@" "$out"
            fi
        }

        if [ -n "$win_id" ]; then
            wid=$(resolve_win_id "$win_id")
            [ -n "$wid" ] || { echo "ERROR: no window matched '$win_id'" >&2; exit 4; }
            capture -window "$wid" || die "window capture failed (4K screens: use --crop instead)"
        elif [ -n "$crop" ]; then
            # root capture + crop: reliable on 4K/multi-monitor where
            # per-window capture may fail
            capture -window root -crop "$crop" || die "cropped capture failed"
        else
            capture -window root || die "screen capture failed"
        fi
        [ -s "$out" ] || die "capture produced no data: $out"

        orig=$(img_size "$out")
        [ -n "$orig" ] || die "cannot read image size: $out"

        if [ "$maxw" -gt 0 ] && [ "${orig%x*}" -gt "$maxw" ]; then
            tmp="${out}.tmp.$$"
            case "$out" in
                *.jpg|*.jpeg|*.JPG|*.JPEG)
                    im_convert "$out" -resize "${maxw}x>" -quality "$quality" "$tmp" || { rm -f "$tmp"; die "downscale failed"; } ;;
                *)
                    im_convert "$out" -resize "${maxw}x>" "$tmp" || { rm -f "$tmp"; die "downscale failed"; } ;;
            esac
            mv -f "$tmp" "$out" || die "cannot replace $out"
        fi

        final=$(img_size "$out")
        [ -n "$final" ] || die "cannot read image size: $out"
        fw=${final%x*}; fh=${final#*x}
        off_x=0; off_y=0

        if [ -n "$crop" ]; then
            base_w=${crop%%x*}
            ox=""; oy=""
            if [[ "$crop" =~ ^[0-9]+x[0-9]+([+-][0-9]+)([+-][0-9]+)$ ]]; then
                ox=${BASH_REMATCH[1]}; oy=${BASH_REMATCH[2]}
                off_x=${ox#+}; off_y=${oy#+}
            fi
            if is_uint "$base_w" && [ "$fw" -gt 0 ]; then
                scale=$(awk -v b="$base_w" -v i="$fw" 'BEGIN { printf "%.3f", b/i }')
            else
                scale="1.000"
            fi
            echo "saved: $out"
            echo "image: $final  crop: $crop  scale: $scale"
            if [ -n "$ox" ]; then
                echo "crop offset: ${ox}${oy}  (screen = offset + image_coord * scale)"
            fi
        elif [ -n "$win_id" ]; then
            base_w=${orig%x*}
            if is_uint "$base_w" && [ "$fw" -gt 0 ]; then
                scale=$(awk -v b="$base_w" -v i="$fw" 'BEGIN { printf "%.3f", b/i }')
            else
                scale="1.000"
            fi
            echo "saved: $out"
            echo "image: $final  window: $wid  scale: $scale (coords relative to window)"
        else
            sg=$(screen_geometry)
            sw=${sg%x*}; shgt=${sg#*x}
            if [ -n "$sw" ] && [ "$fw" -gt 0 ]; then
                scale=$(awk -v s="$sw" -v i="$fw" 'BEGIN { printf "%.3f", s/i }')
            else
                scale="1.000"
            fi
            echo "saved: $out"
            echo "image: $final  screen: ${sw:-?}x${shgt:-?}  scale: $scale"
        fi

        if [ "$grid" -gt 0 ]; then
            # coarsen the step until the grid stays readable (<= ~80 lines total)
            while :; do
                nv=$(awk -v f="$fw" -v s="$scale" -v g="$grid" 'BEGIN { printf "%d", int(f * s / g) + 1 }')
                nh=$(awk -v f="$fh" -v s="$scale" -v g="$grid" 'BEGIN { printf "%d", int(f * s / g) + 1 }')
                [ $(( nv + nh )) -le 80 ] && break
                grid=$(( grid * 2 ))
            done
            lines=$(awk -v fw="$fw" -v fh="$fh" -v ox="$off_x" -v oy="$off_y" \
                         -v g="$grid" -v s="$scale" 'BEGIN {
                step = g / s;
                for (i = 0; ; i++) {
                    ix = i * step; if (ix > fw) break;
                    printf "V %.0f %d\n", ix, ox + ix * s;
                }
                for (i = 0; ; i++) {
                    iy = i * step; if (iy > fh) break;
                    printf "H %.0f %d\n", iy, oy + iy * s;
                }
            }')
            gargs=(-stroke 'rgba(0,229,255,0.55)' -strokewidth 1 -fill none)
            while read -r kind a b; do
                [ -n "$kind" ] || continue
                if [ "$kind" = "V" ]; then
                    gargs+=(-draw "line $a,0 $a,$fh")
                else
                    gargs+=(-draw "line 0,$a $fw,$a")
                fi
            done <<< "$lines"
            gargs+=(-fill 'rgba(0,229,255,0.95)' -undercolor 'rgba(0,0,0,0.55)' -pointsize 13)
            while read -r kind a b; do
                [ -n "$kind" ] || continue
                if [ "$kind" = "V" ]; then
                    gargs+=(-annotate "+$(( a + 3 ))+15" "$b")
                else
                    gargs+=(-annotate "+2+$(( a + 14 ))" "$b")
                fi
            done <<< "$lines"
            gtmp="${out}.grid.$$"
            # +repage first: cropped captures keep virtual-page geometry
            # (+X+Y offset), and -annotate positions relative to the PAGE,
            # not the image — labels would land outside the canvas otherwise.
            if [ "$is_jpeg" -eq 1 ]; then
                im_convert "$out" +repage "${gargs[@]}" -quality "$quality" "$gtmp" || { rm -f "$gtmp"; die "grid draw failed"; }
            else
                im_convert "$out" +repage "${gargs[@]}" "$gtmp" || { rm -f "$gtmp"; die "grid draw failed"; }
            fi
            mv -f "$gtmp" "$out" || die "cannot replace $out"
            echo "grid: step ${grid}px (labels are screen coords)"
        fi

        if [ -n "$mark" ]; then
            [ -n "$IM_MODE" ] || die "ImageMagick not found (need import/identify or magick)"
            mx=${mark%,*}; my=${mark#*,}
            ix=$(awk -v x="$mx" -v o="$off_x" -v s="$scale" 'BEGIN { printf "%.0f", (x-o)/s }')
            iy=$(awk -v y="$my" -v o="$off_y" -v s="$scale" 'BEGIN { printf "%.0f", (y-o)/s }')
            if [ "$ix" -lt 0 ] || [ "$iy" -lt 0 ] || [ "$ix" -ge "$fw" ] || [ "$iy" -ge "$fh" ]; then
                die "--mark ($mx,$my) is outside the captured image (${final})"
            fi
            mtmp="${out}.mark.$$"
            if [ "$is_jpeg" -eq 1 ]; then
                im_convert "$out" -stroke '#ff2222' -strokewidth 2 -fill none \
                    -draw "line $((ix-24)),$iy $((ix+24)),$iy line $ix,$((iy-24)) $ix,$((iy+24)) circle $ix,$iy $((ix+10)),$iy" \
                    -quality "$quality" "$mtmp" || { rm -f "$mtmp"; die "cannot draw mark"; }
            else
                im_convert "$out" -stroke '#ff2222' -strokewidth 2 -fill none \
                    -draw "line $((ix-24)),$iy $((ix+24)),$iy line $ix,$((iy-24)) $ix,$((iy+24)) circle $ix,$iy $((ix+10)),$iy" \
                    "$mtmp" || { rm -f "$mtmp"; die "cannot draw mark"; }
            fi
            mv -f "$mtmp" "$out" || die "cannot replace $out"
            echo "mark: screen ($mx,$my) -> image ($ix,$iy)"
        fi

        if [ -n "$dual" ]; then
            dtmp="${dual}.tmp.$$"
            case "$dual" in
                *.jpg|*.jpeg|*.JPG|*.JPEG)
                    im_convert "$out" -resize "${dualw}x>" -quality "$quality" "$dtmp" || { rm -f "$dtmp"; die "dual preview failed"; } ;;
                *)
                    im_convert "$out" -resize "${dualw}x>" "$dtmp" || { rm -f "$dtmp"; die "dual preview failed"; } ;;
            esac
            mv -f "$dtmp" "$dual" || die "cannot replace $dual"
            dfinal=$(img_size "$dual")
            dfw=${dfinal%x*}
            # view-scale maps dual-image coords to SCREEN coords (not main-image coords)
            if [ -n "$crop" ]; then
                bw=${crop%%x*}
            elif [ -n "$win_id" ]; then
                bw=${orig%x*}
            else
                sg=$(screen_geometry); bw=${sg%x*}
            fi
            if [ -n "$bw" ] && [ "$dfw" -gt 0 ]; then
                dscale=$(awk -v w="$bw" -v i="$dfw" 'BEGIN { printf "%.3f", w / i }')
            else
                dscale="1.000"
            fi
            echo "dual: $dual  image: $dfinal  view-scale: $dscale (coords on the dual image; screen = offset + coord * view_scale)"
        fi

        if awk -v s="$scale" 'BEGIN { exit !(s > 1.001) }'; then
            echo "hint: multiply image coords by scale before clicking (or use: $0 coord <x> <y> $scale)"
        fi
        ;;

    coord)
        [ $# -ge 3 ] || die "usage: coord <img_x> <img_y> <scale> [offset_x offset_y]"
        awk -v x="$1" -v y="$2" -v s="$3" -v ox="${4:-0}" -v oy="${5:-0}" \
            'BEGIN { printf "%d %d\n", ox + x*s, oy + y*s }'
        ;;

    *)
        echo "unknown command: $cmd (run with no args for help)" >&2
        exit 1
        ;;
esac
