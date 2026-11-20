#!/usr/bin/env bash
export DISPLAY=:99

# Cleanly close Firefox when Replit stops the workflow
cleanup() {
  pkill -TERM firefox || true
  sleep 2
}
trap cleanup EXIT SIGINT SIGTERM

# Start virtual screen
Xvfb :99 -screen 0 1920x1080x24 &
sleep 1

# Configure Openbox keybind: Alt+W -> Ctrl+W
mkdir -p ~/.config/openbox
cat << 'EOF' > ~/.config/openbox/rc.xml
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org">
  <keyboard>
    <keybind key="A-w">
      <action name="Execute">
        <command>sh -c "sleep 0.15 && xdotool keyup Alt_L Alt_R && xdotool key --clearmodifiers ctrl+w"</command>
      </action>
    </keybind>
  </keyboard>
</openbox_config>
EOF

# Start lightweight window manager with custom keybind
openbox --config-file ~/.config/openbox/rc.xml &
sleep 1

# Start Firefox maximized
firefox &
sleep 3
wmctrl -r :ACTIVE: -b add,maximized_vert,maximized_horz || true

# Start VNC server and web viewer
x11vnc -display :99 -forever -nopw -shared -rfbport 5900 -clear_mods &
sleep 1
novnc --vnc localhost:5900 --listen 8080
