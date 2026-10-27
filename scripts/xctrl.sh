#!/usr/bin/env bash
# xctrl.sh - X11 input injection & screen capture helper (v1.2.0)
# Wraps xdotool (pointer/keyboard/window) and ImageMagick (import/identify).
#
# Usage: xctrl.sh <command> [args...]
#   check                          Verify X11 session and required tools
#   pos                            Print current pointer position
#   move <x> <y>                   Move pointer (no click)
#   click <x> <y> [button]         Move + click (button: 1=left 2=mid 3=right, default 1)
#   dclick <x> <y>                 Move + double click
#   rclick <x> <y>                 Move + right click
#   drag <x1> <y1> <x2> <y2>       Press at (x1,y1), move, release at (x2,y2)
#   type [--clipboard|--no-clipboard] [--paste-key <combo>] <text>
#                                  Type text; CJK/emoji auto-use clipboard
#   key <combo>                    Send key combo, e.g. "ctrl+c" "alt+F4" "Return"
#   win search <name>              List window ids matching name (id | geometry | title)
#   win activate <id|name>         Activate (focus+raise) a window by id or title
#   win geom <id|name>             Print geometry of a window id
#   shot <out> [--win <id|name>] [--crop <WxH+X+Y>] [--delay <sec>]
#              [--max-width <px>] [--quality <1-100>] [--mark <x,y>]
#                                  Capture screen / window / region; optional downscale
#                                  --mark draws a crosshair at screen (x,y)
#   coord <x> <y> <scale> [off_x off_y]
#                                  Convert image coords to screen coords
#
# Exit codes: 0 ok, 1 usage/action error, 2 environment error, 4 not found.

set -u

cmd="${1:-}"; shift || true
export DISPLAY="${DISPLAY:-:0}"

die() { echo "ERROR: $*" >&2; exit 1; }

need_tool() {
    command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH" >&2; exit 2; }
}

warn_wayland() {
    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        echo "WARN: Wayland session; xdotool only affects XWayland (X11) windows." >&2
    fi
}

require_x11() {
    need_tool xdotool
    if ! xdotool getdisplaygeometry >/dev/null 2>&1; then
        echo "ERROR: cannot talk to X display '${DISPLAY}' (X11 session? correct DISPLAY?)" >&2
        exit 2
    fi
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
    identify -format '%wx%h' "$1" 2>/dev/null
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
  click <x> <y> [button]         Move + click (button: 1=left 2=mid 3=right, default 1)
  dclick <x> <y>                 Move + double click
  rclick <x> <y>                 Move + right click
  drag <x1> <y1> <x2> <y2>       Press at (x1,y1), move, release at (x2,y2)
  type [--clipboard|--no-clipboard] [--paste-key <combo>] <text>
                                 Type text; CJK/emoji auto-use clipboard
  key <combo>                    Send key combo, e.g. "ctrl+c" "alt+F4" "Return"
  win search <name>              List windows matching name (id | geometry | title)
  win activate <id|name>         Activate (focus+raise) a window by id or title
  win geom <id|name>             Print geometry of a window id
  shot <out> [--win <id|name>] [--crop <WxH+X+Y>] [--delay <sec>]
             [--max-width <px>] [--quality <1-100>] [--mark <x,y>]
                                 Capture screen / window / region; optional downscale
                                 --mark draws a crosshair at screen (x,y) for verification
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
        echo "session: ${XDG_SESSION_TYPE:-unknown}  display: ${DISPLAY:-unset}"
        missing=0
        for t in xdotool import identify; do
            if command -v "$t" >/dev/null 2>&1; then
                echo "tool ok : $t ($(command -v "$t"))"
            else
                echo "tool MISSING: $t"
                missing=1
            fi
        done
        for t in convert xclip; do
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
        [ "$missing" -eq 0 ] || exit 2
        ;;

    pos)
        require_x11
        xdotool getmouselocation
        ;;

    move)
        [ $# -ge 2 ] || die "usage: move <x> <y>"
        require_x11
        xdotool mousemove --sync "$1" "$2" || die "mousemove failed at ($1,$2)"
        ;;

    click)
        [ $# -ge 2 ] || die "usage: click <x> <y> [button]"
        btn="${3:-1}"
        case "$btn" in 1|2|3) ;; *) die "button must be 1, 2 or 3" ;; esac
        require_x11
        xdotool mousemove --sync "$1" "$2" || die "mousemove failed at ($1,$2)"
        xdotool click --delay 60 "$btn" || die "click failed at ($1,$2)"
        sleep 0.3
        ;;

    dclick)
        [ $# -ge 2 ] || die "usage: dclick <x> <y>"
        require_x11
        xdotool mousemove --sync "$1" "$2" || die "mousemove failed at ($1,$2)"
        xdotool click --repeat 2 --delay 120 1 || die "double click failed at ($1,$2)"
        sleep 0.3
        ;;

    rclick)
        [ $# -ge 2 ] || die "usage: rclick <x> <y>"
        require_x11
        xdotool mousemove --sync "$1" "$2" || die "mousemove failed at ($1,$2)"
        xdotool click 3 || die "right click failed at ($1,$2)"
        sleep 0.3
        ;;

    drag)
        [ $# -ge 4 ] || die "usage: drag <x1> <y1> <x2> <y2>"
        require_x11
        xdotool mousemove --sync "$1" "$2" || die "mousemove failed at ($1,$2)"
        xdotool mousedown 1 || die "mousedown failed at ($1,$2)"
        xdotool mousemove --sync "$3" "$4" || { xdotool mouseup 1; die "mousemove failed at ($3,$4)"; }
        xdotool mouseup 1 || die "mouseup failed at ($3,$4)"
        sleep 0.3
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

    win)
        sub="${1:-}"; shift || true
        require_x11
        case "$sub" in
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
                xdotool windowactivate --sync "$id" || die "activate failed for window $id"
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
        [ $# -ge 1 ] || die "usage: shot <out> [--win <id|name>] [--crop <WxH+X+Y>] [--delay <sec>] [--max-width <px>] [--quality <1-100>] [--mark <x,y>]"
        out="$1"; shift
        win_id=""; crop=""; delay=0; maxw=0; quality=85; mark=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --win)       [ $# -ge 2 ] || die "--win needs a value";        win_id="$2";  shift 2 ;;
                --crop)      [ $# -ge 2 ] || die "--crop needs a value";       crop="$2";    shift 2 ;;
                --delay)     [ $# -ge 2 ] || die "--delay needs a value";      delay="$2";   shift 2 ;;
                --max-width) [ $# -ge 2 ] || die "--max-width needs a value";  maxw="$2";    shift 2 ;;
                --quality)   [ $# -ge 2 ] || die "--quality needs a value";    quality="$2"; shift 2 ;;
                --mark)      [ $# -ge 2 ] || die "--mark needs a value";       mark="$2";    shift 2 ;;
                *) die "unknown shot option: $1" ;;
            esac
        done
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
        need_tool import
        is_jpeg=0
        case "$out" in *.jpg|*.jpeg|*.JPG|*.JPEG) is_jpeg=1 ;; esac
        capture() {
            if [ "$is_jpeg" -eq 1 ]; then
                import "$@" -quality "$quality" "$out"
            else
                import "$@" "$out"
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

        need_tool identify
        orig=$(img_size "$out")
        [ -n "$orig" ] || die "cannot read image size: $out"

        if [ "$maxw" -gt 0 ] && [ "${orig%x*}" -gt "$maxw" ]; then
            need_tool convert
            tmp="${out}.tmp.$$"
            case "$out" in
                *.jpg|*.jpeg|*.JPG|*.JPEG)
                    convert "$out" -resize "${maxw}x>" -quality "$quality" "$tmp" || { rm -f "$tmp"; die "downscale failed"; } ;;
                *)
                    convert "$out" -resize "${maxw}x>" "$tmp" || { rm -f "$tmp"; die "downscale failed"; } ;;
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

        if [ -n "$mark" ]; then
            need_tool convert
            mx=${mark%,*}; my=${mark#*,}
            ix=$(awk -v x="$mx" -v o="$off_x" -v s="$scale" 'BEGIN { printf "%.0f", (x-o)/s }')
            iy=$(awk -v y="$my" -v o="$off_y" -v s="$scale" 'BEGIN { printf "%.0f", (y-o)/s }')
            if [ "$ix" -lt 0 ] || [ "$iy" -lt 0 ] || [ "$ix" -ge "$fw" ] || [ "$iy" -ge "$fh" ]; then
                die "--mark ($mx,$my) is outside the captured image (${final})"
            fi
            mtmp="${out}.mark.$$"
            if [ "$is_jpeg" -eq 1 ]; then
                convert "$out" -stroke '#ff2222' -strokewidth 2 -fill none \
                    -draw "line $((ix-24)),$iy $((ix+24)),$iy line $ix,$((iy-24)) $ix,$((iy+24)) circle $ix,$iy $((ix+10)),$iy" \
                    -quality "$quality" "$mtmp" || { rm -f "$mtmp"; die "cannot draw mark"; }
            else
                convert "$out" -stroke '#ff2222' -strokewidth 2 -fill none \
                    -draw "line $((ix-24)),$iy $((ix+24)),$iy line $ix,$((iy-24)) $ix,$((iy+24)) circle $ix,$iy $((ix+10)),$iy" \
                    "$mtmp" || { rm -f "$mtmp"; die "cannot draw mark"; }
            fi
            mv -f "$mtmp" "$out" || die "cannot replace $out"
            echo "mark: screen ($mx,$my) -> image ($ix,$iy)"
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
