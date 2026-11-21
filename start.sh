
#!/usr/bin/env bash
set -Eeuo pipefail

# Resolve the project root regardless of the current working directory.
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

export DISPLAY=":99"
export MOZ_ENABLE_WAYLAND=0

# Desktop configuration
SCREEN_WIDTH="${SCREEN_WIDTH:-1920}"
SCREEN_HEIGHT="${SCREEN_HEIGHT:-1080}"
SCREEN_DEPTH="${SCREEN_DEPTH:-24}"

# Network configuration
VNC_PORT="${VNC_PORT:-5900}"
WEB_PORT="${WEB_PORT:-8080}"

# Use the existing project directory for Firefox's persistent profile.
PROFILE_DIR="$ROOT_DIR/firefox-profile"
OPENBOX_CONFIG_DIR="$HOME/.config/openbox"

# VNC requires a password.
VNC_PASSWORD="${VNC_PASSWORD:-}"

if [[ ${#VNC_PASSWORD} -ne 8 ]]; then
    echo "ERROR: Set VNC_PASSWORD to exactly 8 characters." >&2
    exit 1
fi

# Create required directories.
mkdir -p "$PROFILE_DIR"
mkdir -p "$OPENBOX_CONFIG_DIR"
mkdir -p "$HOME/.vnc"

# Generate the protected VNC password file.
VNC_PASSWORD_FILE="$HOME/.vnc/passwd"

x11vnc -storepasswd "$VNC_PASSWORD" "$VNC_PASSWORD_FILE" >/dev/null
chmod 600 "$VNC_PASSWORD_FILE"

unset VNC_PASSWORD

# Configure Openbox.
cat > "$OPENBOX_CONFIG_DIR/rc.xml" <<'XML'
<?xml version="1.0"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
    <applications>
        <application class="*">
            <decor>no</decor>
            <maximized>yes</maximized>
        </application>
    </applications>
</openbox_config>
XML

# Track child processes for reliable shutdown.
PIDS=()

cleanup() {
    trap - EXIT INT TERM

    echo "Stopping Firefox desktop..."

    # Stop services in reverse startup order.
    for ((i=${#PIDS[@]}-1; i>=0; i--)); do
        pid="${PIDS[i]}"
        kill -TERM "$pid" 2>/dev/null || true
    done

    pkill -TERM -x firefox 2>/dev/null || true

    for ((i=${#PIDS[@]}-1; i>=0; i--)); do
        pid="${PIDS[i]}"
        wait "$pid" 2>/dev/null || true
    done
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --------------------------------------------------
# 1. Start Xvfb
# --------------------------------------------------

Xvfb "$DISPLAY" \
    -screen 0 "${SCREEN_WIDTH}x${SCREEN_HEIGHT}x${SCREEN_DEPTH}" \
    -nolisten tcp \
    -noreset &

XVFB_PID=$!
PIDS+=("$XVFB_PID")

# Wait until the X server is actually ready.
DISPLAY_READY=0

for _ in {1..50}; do
    if ! kill -0 "$XVFB_PID" 2>/dev/null; then
        echo "ERROR: Xvfb exited unexpectedly." >&2
        exit 1
    fi

    if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
        DISPLAY_READY=1
        break
    fi

    sleep 0.2
done

if [[ "$DISPLAY_READY" -ne 1 ]]; then
    echo "ERROR: Xvfb failed to initialize." >&2
    exit 1
fi

echo "Xvfb ready: $DISPLAY"

# --------------------------------------------------
# 2. Start Openbox
# --------------------------------------------------

openbox --config-file "$OPENBOX_CONFIG_DIR/rc.xml" &

OPENBOX_PID=$!
PIDS+=("$OPENBOX_PID")

sleep 0.5

if ! kill -0 "$OPENBOX_PID" 2>/dev/null; then
    echo "ERROR: Openbox failed to start." >&2
    exit 1
fi

echo "Openbox started."

# --------------------------------------------------
# 3. Start Firefox
# --------------------------------------------------

firefox \
    --no-remote \
    --profile "$PROFILE_DIR" \
    --new-window about:blank &

FIREFOX_PID=$!
PIDS+=("$FIREFOX_PID")

echo "Firefox started."
echo "Profile: $PROFILE_DIR"

# --------------------------------------------------
# 4. Start x11vnc
# --------------------------------------------------

x11vnc \
    -display "$DISPLAY" \
    -localhost \
    -forever \
    -shared \
    -rfbport "$VNC_PORT" \
    -rfbauth "$VNC_PASSWORD_FILE" &

X11VNC_PID=$!
PIDS+=("$X11VNC_PID")

# Wait for the VNC socket to accept connections.
VNC_READY=0

for _ in {1..50}; do
    if ( : > "/dev/tcp/127.0.0.1/${VNC_PORT}" ) 2>/dev/null; then
        VNC_READY=1
        break
    fi

    if ! kill -0 "$X11VNC_PID" 2>/dev/null; then
        echo "ERROR: x11vnc exited unexpectedly." >&2
        exit 1
    fi

    sleep 0.2
done

if [[ "$VNC_READY" -ne 1 ]]; then
    echo "ERROR: VNC server failed to initialize." >&2
    exit 1
fi

echo "VNC server ready on localhost:$VNC_PORT"

# --------------------------------------------------
# 5. Start noVNC
# --------------------------------------------------


# --------------------------------------------------
# 5. Start customized noVNC
# --------------------------------------------------

NOVNC_BIN="$(readlink -f "$(command -v novnc)")"
NOVNC_ROOT="$(dirname "$(dirname "$NOVNC_BIN")")"
NOVNC_SOURCE="$NOVNC_ROOT/share/webapps/novnc"
if [[ ! -f "$NOVNC_SOURCE/vnc.html" ]]; then
    NOVNC_SOURCE="$NOVNC_ROOT/share/novnc"
fi
NOVNC_CUSTOM="$ROOT_DIR/.novnc-custom"

if [[ ! -f "$NOVNC_SOURCE/vnc.html" ]]; then
    echo "ERROR: Could not locate noVNC web files at:"
    echo "$NOVNC_SOURCE"
    exit 1
fi

# Copy installed noVNC files into the writable project directory.
rm -rf "$NOVNC_CUSTOM"
mkdir -p "$NOVNC_CUSTOM"
cp -a "$NOVNC_SOURCE/." "$NOVNC_CUSTOM/"
chmod -R u+w "$NOVNC_CUSTOM"

# Install the keyboard remapper inside noVNC's existing UI module.
UI_JS="$NOVNC_CUSTOM/app/ui.js"
TEMP_JS="$UI_JS.tmp"

if ! awk '
/^export default UI;$/ {
    seen = 1
    print ""
    print "// Custom Alt-to-Ctrl shortcut remapping"
    print "let altShortcutActive = false;"
    print ""
    print "const suppressShortcut = (event) => {"
    print "    event.preventDefault();"
    print "    event.stopPropagation();"
    print "    event.stopImmediatePropagation();"
    print "};"
    print ""
    print "const isEditableTarget = (target) =>"
    print "    target instanceof Element && target.closest("
    print "        \"input, textarea, select, [contenteditable=true]\""
    print "    ) !== null;"
    print ""
    print "window.addEventListener(\"keydown\", (event) => {"
    print "    if (!UI.connected || !UI.rfb) return;"
    print ""
    print "    if (event.key === \"Alt\" && !event.ctrlKey && !event.metaKey) {"
    print "        if (isEditableTarget(event.target)) return;"
    print "        altShortcutActive = true;"
    print "        suppressShortcut(event);"
    print "        if (event.shiftKey) {"
    print "            UI.rfb.sendKey(KeyTable.XK_Shift_L, \"ShiftLeft\", false);"
    print "        }"
    print "        return;"
    print "    }"
    print ""
    print "    if (!altShortcutActive) return;"
    print "    suppressShortcut(event);"
    print ""
    print "    if ([\"Alt\", \"Shift\", \"Control\", \"Meta\"].includes(event.key)) return;"
    print "    if (!event.code || !UI.rfb) return;"
    print ""
    print "    const rfb = UI.rfb;"
    print "    rfb.sendKey(KeyTable.XK_Control_L, \"ControlLeft\", true);"
    print ""
    print "    if (event.shiftKey) {"
    print "        rfb.sendKey(KeyTable.XK_Shift_L, \"ShiftLeft\", true);"
    print "    }"
    print ""
    print "    rfb.sendKey(0, event.code);"
    print ""
    print "    if (event.shiftKey) {"
    print "        rfb.sendKey(KeyTable.XK_Shift_L, \"ShiftLeft\", false);"
    print "    }"
    print ""
    print "    rfb.sendKey(KeyTable.XK_Control_L, \"ControlLeft\", false);"
    print "}, true);"
    print ""
    print "window.addEventListener(\"keyup\", (event) => {"
    print "    if (!altShortcutActive) return;"
    print "    suppressShortcut(event);"
    print "    if (event.key === \"Alt\") altShortcutActive = false;"
    print "}, true);"
    print ""
    print "window.addEventListener(\"blur\", () => {"
    print "    altShortcutActive = false;"
    print "}, true);"
    print ""
}
{ print }
END {
    if (!seen) exit 42
}
' "$UI_JS" > "$TEMP_JS"; then
    echo "ERROR: Could not inject keyboard remapping."
    rm -f "$TEMP_JS"
    exit 1
fi

# Ensure the patch was inserted.
if ! grep -q "Custom Alt-to-Ctrl shortcut remapping" "$TEMP_JS"; then
    echo "ERROR: Keyboard remapping was not installed."
    rm -f "$TEMP_JS"
    exit 1
fi

mv "$TEMP_JS" "$UI_JS"

echo "Custom keyboard remapping installed."

# Launch customized noVNC.
novnc \
    --vnc "127.0.0.1:${VNC_PORT}" \
    --listen "0.0.0.0:${WEB_PORT}" \
    --web "$NOVNC_CUSTOM" &

NOVNC_PID=$!
PIDS+=("$NOVNC_PID")

echo "----------------------------------------"
echo "Firefox desktop is ready."
echo "Open /vnc.html in the Replit webview."
echo "----------------------------------------"

wait "$NOVNC_PID"