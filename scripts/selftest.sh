#!/usr/bin/env bash
# selftest.sh - non-destructive smoke test for xctrl.sh.
# Sends NO mouse or keyboard events; screenshots + clipboard round-trip only.

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$DIR/xctrl.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }

# 1. help
if "$S" >/dev/null 2>&1; then ok "help exits 0"; else bad "help exits 0"; fi

# 2. unknown command must fail
if "$S" no-such-command >/dev/null 2>&1; then bad "unknown command exits non-zero"; else ok "unknown command exits non-zero"; fi

# 3. missing argument must fail
if "$S" click 100 >/dev/null 2>&1; then bad "missing argument exits non-zero"; else ok "missing argument exits non-zero"; fi

# 4. environment check
if out=$("$S" check 2>&1); then
    ok "check exits 0"
    case "$out" in
        *"tool ok : xdotool"*) ok "xdotool detected" ;;
        *) bad "xdotool detected" ;;
    esac
    case "$out" in
        *"imagemagick: im6"*|*"imagemagick: im7"*) ok "ImageMagick detected" ;;
        *) bad "ImageMagick detected" ;;
    esac
else
    bad "check exits 0 (no X11 display or missing tools)"
    printf '%s\n' "$out" | sed 's/^/     /'
fi

# 5. pointer position (read-only)
if "$S" pos 2>/dev/null | grep -q 'window:'; then ok "pos returns X/Y/window"; else bad "pos returns X/Y/window"; fi

# 6. screenshot at native size
if "$S" shot "$TMP/full.png" >/dev/null 2>&1 && [ -s "$TMP/full.png" ]; then
    ok "screenshot (native)"
    if command -v identify >/dev/null 2>&1; then
        dims=$(identify -format '%wx%h' "$TMP/full.png")
        ok "native size $dims"
    fi
else
    bad "screenshot (native)"
fi

# 7. downscaled screenshot + scale output
if out=$("$S" shot "$TMP/small.png" --max-width 640 2>&1); then
    w=$(identify -format '%w' "$TMP/small.png" 2>/dev/null || echo 0)
    if [ "$w" -le 640 ] && [ "$w" -gt 0 ]; then ok "downscale to ${w}px"; else bad "downscale to <=640px (got $w)"; fi
    case "$out" in
        *scale:*) ok "scale reported" ;;
        *) bad "scale reported" ;;
    esac
else
    bad "downscale screenshot"
    printf '%s\n' "$out" | sed 's/^/     /'
fi

# 8. coord conversion
if [ "$("$S" coord 800 450 2.0)" = "1600 900" ]; then ok "coord 800,450 x2 -> 1600,900"; else bad "coord conversion"; fi
if [ "$("$S" coord 100 80 2.0 960 540)" = "1160 700" ]; then ok "coord with offset"; else bad "coord with offset"; fi

# 9. crosshair mark
if out=$("$S" shot "$TMP/mark.png" --mark 100,100 2>&1) && printf '%s' "$out" | grep -q 'mark: screen (100,100)'; then
    ok "mark crosshair"
else
    bad "mark crosshair"
fi
if "$S" shot "$TMP/badmark.png" --mark 99999,99999 >/dev/null 2>&1; then
    bad "out-of-bounds mark rejected"
else
    ok "out-of-bounds mark rejected"
fi

# 10. coordinate grid overlay
if out=$("$S" shot "$TMP/grid.png" --crop 1200x800+100+100 --grid 200 2>&1) \
        && printf '%s' "$out" | grep -q 'grid: step' \
        && [ -s "$TMP/grid.png" ]; then
    ok "grid overlay"
else
    bad "grid overlay"
fi

# 11. scroll argument validation (no pointer movement happens)
if "$S" scroll 100 100 abc >/dev/null 2>&1; then bad "scroll rejects non-integer clicks"; else ok "scroll rejects non-integer clicks"; fi
if "$S" scroll 100 100 0 >/dev/null 2>&1; then bad "scroll rejects 0 clicks"; else ok "scroll rejects 0 clicks"; fi
if "$S" scroll 100 100 >/dev/null 2>&1; then bad "scroll requires 3 args"; else ok "scroll requires 3 args"; fi

# 12. clipboard roundtrip (previous content restored afterwards)
if command -v xclip >/dev/null 2>&1 || command -v xsel >/dev/null 2>&1; then
    oldclip=$("$S" clipboard get 2>/dev/null || true)
    if "$S" clipboard set "xctrl-selftest" >/dev/null 2>&1 \
            && [ "$("$S" clipboard get 2>/dev/null)" = "xctrl-selftest" ]; then
        ok "clipboard set/get"
    else
        bad "clipboard set/get"
    fi
    if [ -n "$oldclip" ]; then
        printf '%s' "$oldclip" | "$S" clipboard set >/dev/null 2>&1 || true
    else
        # restore "no clipboard text" as closely as X11 allows
        "$S" clipboard set "" >/dev/null 2>&1 || true
    fi
else
    ok "clipboard set/get (skipped: no xclip/xsel)"
fi

# 13. act round-trip (read-only steps only: pos/coord)
if "$S" act "pos ; coord 10 20 2" >/dev/null 2>&1; then
    ok "act executes steps"
else
    bad "act executes steps"
fi
if "$S" act "bogus-cmd 1" >/dev/null 2>&1; then
    bad "act rejects unknown step"
else
    ok "act rejects unknown step"
fi

# 14. waitfor timeout honored (--timeout placed after the positional arg)
if "$S" waitfor win "xctrl-selftest-no-such-window" --timeout 1 >/dev/null 2>&1; then
    bad "waitfor timeout exits non-zero"
else
    ok "waitfor timeout exits non-zero"
fi

# 15. win list (exit 4 is fine: "no visible windows")
rc=0
"$S" win list >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ] || [ "$rc" -eq 4 ]; then
    ok "win list runs"
else
    bad "win list runs (rc=$rc)"
fi

# 16. dual-output screenshot (one capture, two files)
if out=$("$S" shot "$TMP/d1.png" --dual "$TMP/d2.jpg" --dual-width 640 2>&1) \
        && [ -s "$TMP/d1.png" ] && [ -s "$TMP/d2.jpg" ] \
        && printf '%s' "$out" | grep -q 'view-scale:'; then
    ok "shot --dual"
else
    bad "shot --dual"
fi

# 17. ui degrades gracefully when the accessibility bus is absent
if out=$("$S" ui find xctrl-selftest-nonexistent 2>&1); then
    ok "ui find ran (accessibility bus present)"
else
    case "$out" in
        *"accessibility bus"*|*"no accessible element"*) ok "ui degrades gracefully" ;;
        *) bad "ui degrades gracefully" ;;
    esac
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
