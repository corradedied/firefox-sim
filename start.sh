
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

NOVNC_BIN="$(command -v novnc || true)"

if [[ -z "$NOVNC_BIN" ]]; then
    echo "ERROR: novnc executable not found."
    exit 1
fi

NOVNC_BIN="$(readlink -f "$NOVNC_BIN")"
NOVNC_ROOT="$(dirname "$(dirname "$NOVNC_BIN")")"

# Locate the installed noVNC web directory.
NOVNC_SOURCE=""

for candidate in \
    "$NOVNC_ROOT/share/webapps/novnc" \
    "$NOVNC_ROOT/share/novnc" \
    "$NOVNC_ROOT/share/noVNC" \
    "$NOVNC_ROOT/share/webapps/noVNC"
do
    if [[ -f "$candidate/vnc.html" && -f "$candidate/app/ui.js" ]]; then
        NOVNC_SOURCE="$candidate"
        break
    fi
done

if [[ -z "$NOVNC_SOURCE" ]]; then
    echo "ERROR: Could not locate noVNC web files."
    echo "Executable: $NOVNC_BIN"
    echo "Package root: $NOVNC_ROOT"
    exit 1
fi

echo "[noVNC] Source: $NOVNC_SOURCE"

# Create a writable customized copy.
NOVNC_CUSTOM="$ROOT_DIR/.novnc-custom"

rm -rf "$NOVNC_CUSTOM"
mkdir -p "$NOVNC_CUSTOM"

cp -a "$NOVNC_SOURCE/." "$NOVNC_CUSTOM/"
chmod -R u+w "$NOVNC_CUSTOM"

# --------------------------------------------------
# Create shortcut remapping module
# --------------------------------------------------

cat > "$NOVNC_CUSTOM/replit-shortcuts.js" <<'JAVASCRIPT'

import UI from "./app/ui.js";

console.info("[Replit Shortcuts] Module loaded.");

const CONTROL = 0xffe3;
const SHIFT = 0xffe1;
const ALT = 0xffe9;

const ALT_CODES = /^(Key[A-Z]|Digit[0-9])$/;

let altActive = false;
let shiftActive = false;

const suppressedCodes = new Set();

function stopEvent(event) {
    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation();
}

function isNoVNCControl(target) {
    if (!(target instanceof Element)) return false;

    return target.closest(
        "#noVNC_control_bar, " +
        "#noVNC_connect_dlg, " +
        "#noVNC_credentials_dlg, " +
        "#noVNC_verify_server_dlg, " +
        "#noVNC_settings, " +
        "#noVNC_clipboard"
    ) !== null;
}

function sendRemappedShortcut(event) {
    const rfb = UI.rfb;

    if (!rfb || !UI.connected || rfb.viewOnly) {
        UI.showStatus("Firefox desktop is unavailable.", "warning");
        return;
    }

    const useShift = event.shiftKey || shiftActive;

    // Linux Firefox natively uses Alt+1 through Alt+9
    // for tab navigation. Other shortcuts use Ctrl.
    const isTabShortcut = /^Digit[1-9]$/.test(event.code);

    let keysym;

    if (/^Key[A-Z]$/.test(event.code)) {
        const letter = event.code.slice(3);

        keysym = (useShift
            ? letter.toUpperCase()
            : letter.toLowerCase()
        ).charCodeAt(0);

    } else if (/^Digit[0-9]$/.test(event.code)) {
        keysym = event.code.slice(5).charCodeAt(0);

    } else {
        return;
    }

    const modifierKeysym = isTabShortcut ? ALT : CONTROL;
    const modifierCode = isTabShortcut ? "AltLeft" : "ControlLeft";

    let modifierPressed = false;
    let shiftPressed = false;

    try {
        rfb.sendKey(modifierKeysym, modifierCode, true);
        modifierPressed = true;

        if (useShift) {
            rfb.sendKey(SHIFT, "ShiftLeft", true);
            shiftPressed = true;
        }

        rfb.sendKey(keysym, event.code, true);
        rfb.sendKey(keysym, event.code, false);

        console.info(
            `[Replit Shortcuts] Alt+${event.code} forwarded as ` +
            `${isTabShortcut ? "Alt" : "Ctrl"}${useShift ? "+Shift" : ""}`
        );

        UI.showStatus(
            isTabShortcut
                ? `Firefox tab ${event.code.slice(5)}`
                : `Firefox shortcut: Ctrl+${event.code.replace("Key", "")}`,
            "normal",
            1000
        );

    } catch (error) {
        console.error("[Replit Shortcuts] Failed:", error);

    } finally {
        if (shiftPressed) {
            rfb.sendKey(SHIFT, "ShiftLeft", false);
        }

        if (modifierPressed) {
            rfb.sendKey(modifierKeysym, modifierCode, false);
        }
    }
}

// --------------------------------------------------
// Capture keyboard shortcuts
// --------------------------------------------------

window.addEventListener("keydown", (event) => {

    const altKey =
        event.code === "AltLeft" ||
        event.code === "AltRight";

    // Capture the physical Alt key.
    if (altKey) {
        if (!UI.connected || !UI.rfb || isNoVNCControl(event.target)) {
            return;
        }

        altActive = true;
        stopEvent(event);
        return;
    }

    if (!altActive) return;

    // Preserve Shift without allowing the host browser
    // to process it independently.
    if (
        event.code === "ShiftLeft" ||
        event.code === "ShiftRight"
    ) {
        shiftActive = true;
        suppressedCodes.add(event.code);
        stopEvent(event);
        return;
    }

    // Only remap letters and number-row keys.
    if (!ALT_CODES.test(event.code)) return;

    if (!UI.connected || !UI.rfb) return;

    stopEvent(event);
    suppressedCodes.add(event.code);

    // Alt+N is intentionally disabled.
    if (event.code === "KeyN") return;

    sendRemappedShortcut(event);

}, true);

// --------------------------------------------------
// Release captured physical keys
// --------------------------------------------------

window.addEventListener("keyup", (event) => {

    if (suppressedCodes.has(event.code)) {
        stopEvent(event);
        suppressedCodes.delete(event.code);

        if (
            event.code === "ShiftLeft" ||
            event.code === "ShiftRight"
        ) {
            shiftActive = false;
        }

        return;
    }

    if (
        event.code === "AltLeft" ||
        event.code === "AltRight"
    ) {
        if (altActive) {
            stopEvent(event);
        }

        altActive = false;
        shiftActive = false;
    }

}, true);

// Reset the remapper when the page loses focus.
window.addEventListener("blur", () => {
    altActive = false;
    shiftActive = false;
    suppressedCodes.clear();
});

console.info("[Replit Shortcuts] Alt-to-Ctrl remapping initialized.");

JAVASCRIPT

# --------------------------------------------------
# Add the module to noVNC's actual entry page
# --------------------------------------------------

VNC_HTML="$NOVNC_CUSTOM/vnc.html"
TEMP_HTML="$VNC_HTML.tmp"

if ! grep -q 'replit-shortcuts.js' "$VNC_HTML"; then

    if ! awk '
        /<\/head>/ && !inserted {
            print "    <script type=\"module\" src=\"./replit-shortcuts.js\"></script>"
            inserted = 1
        }

        { print }

        END {
            if (!inserted) exit 1
        }
    ' "$VNC_HTML" > "$TEMP_HTML"; then

        echo "ERROR: Could not patch noVNC vnc.html."
        rm -f "$TEMP_HTML"
        exit 1
    fi

    mv "$TEMP_HTML" "$VNC_HTML"
fi

# Verify both files exist and the page references the module.
if ! grep -q 'replit-shortcuts.js' "$VNC_HTML"; then
    echo "ERROR: Shortcut module reference missing."
    exit 1
fi

if ! grep -q 'Alt-to-Ctrl remapping initialized' "$NOVNC_CUSTOM/replit-shortcuts.js"; then
    echo "ERROR: Shortcut module verification failed."
    exit 1
fi

echo "[noVNC] Custom keyboard module installed."
echo "[noVNC] Custom web root: $NOVNC_CUSTOM"
echo "[noVNC] Alt-to-Ctrl shortcut remapping enabled."

# --------------------------------------------------
# Start noVNC
# --------------------------------------------------

novnc \
    --vnc "127.0.0.1:${VNC_PORT}" \
    --listen "0.0.0.0:${WEB_PORT}" \
    --web "$NOVNC_CUSTOM" &

NOVNC_PID=$!
PIDS+=("$NOVNC_PID")

echo "----------------------------------------"
echo "Firefox desktop is ready."
echo "Keyboard remapping: Alt -> Ctrl"
echo "Open /vnc.html"
echo "----------------------------------------"

wait "$NOVNC_PID"