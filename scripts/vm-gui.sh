#!/bin/bash
# Runs a shell command on the VM inside the GUI launchd domain (gui/501) and waits for it.
# Why: CoreSimulatorService started from an SSH session lives in user/501, and then
# `simctl boot` fails with "Failed to start launchd_sim: could not bind to session" (error 1102).
# Usage (on the VM): ~/drxwnify-ios/scripts/vm-gui.sh '<command>'
# Output of the command is printed; exit code is the command's.
set -u
L=com.drxwnify.guirun
D=/tmp/drx-gui
mkdir -p "$D"
printf '%s\n' "$1" > "$D/cmd.sh"
rm -f "$D/out.log" "$D/rc"
cat > "$D/agent.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$L</string>
<key>ProgramArguments</key><array>
  <string>/bin/bash</string><string>-c</string>
  <string>export PATH="\$HOME/bin:/usr/bin:/bin:/usr/sbin:/sbin"; bash $D/cmd.sh &gt; $D/out.log 2&gt;&amp;1; echo \$? &gt; $D/rc</string>
</array>
<key>RunAtLoad</key><true/>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/$L" 2>/dev/null
launchctl bootstrap "gui/$(id -u)" "$D/agent.plist" || { echo "vm-gui: no GUI session (is the user logged in?)"; exit 99; }
while [ ! -s "$D/rc" ]; do sleep 1; done
launchctl bootout "gui/$(id -u)/$L" 2>/dev/null
cat "$D/out.log"
exit "$(cat "$D/rc")"
