#!/bin/bash
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
    echo "Run this as your normal user, not root. It will sudo internally where needed."
    exit 1
fi

TARGET_USER="$(whoami)"
SCRIPT_PATH="/usr/local/bin/hp-mute-led.sh"
SUDOERS_PATH="/etc/sudoers.d/hp-mute-led"
USER_SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_PATH="$USER_SERVICE_DIR/hp-mute-led.service"

echo "== 1. Installing dependencies (alsa-tools for hda-verb) =="
sudo apt update
sudo apt install -y alsa-tools alsa-utils

echo "== 2. Detecting ALC245 (or matching) codec card =="
CARD=$(grep -l "ALC245" /proc/asound/card*/codec#0 2>/dev/null | head -1 | grep -oP 'card\K[0-9]+' || true)

if [[ -z "$CARD" ]]; then
    echo "Could not auto-detect an ALC245 codec."
    echo "Cards present:"
    cat /proc/asound/cards
    read -rp "Enter the card number to use manually: " CARD
fi

DEV="/dev/snd/hwC${CARD}D0"
if [[ ! -e "$DEV" ]]; then
    echo "ERROR: $DEV does not exist. Aborting — check card number."
    exit 1
fi
echo "Using device: $DEV"

echo "== 3. Verifying COEF-bit mute LED control works on this hardware =="
echo "About to flash the mute LED ON for 1 second as a test."
sudo hda-verb "$DEV" 0x20 0x500 0x0B >/dev/null
sudo hda-verb "$DEV" 0x20 0x400 0x7778 >/dev/null
sleep 1
sudo hda-verb "$DEV" 0x20 0x500 0x0B >/dev/null
sudo hda-verb "$DEV" 0x20 0x400 0x7774 >/dev/null
read -rp "Did the mute LED flash on and then off? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" ]]; then
    echo "COEF values 0x7778 (on) / 0x7774 (off) at index 0x0B didn't work on your hardware."
    echo "This script is tuned for HP OMEN 16 (subsystem 103c:8a44, ALC245)."
    echo "Check https://github.com/Vilez0/hp-muteled or the MuteLED wiki for alternate verb sets before continuing."
    exit 1
fi

echo "== 4. Writing sync script to $SCRIPT_PATH =="
sudo tee "$SCRIPT_PATH" >/dev/null <<EOF
#!/bin/bash
DEV="$DEV"

sync_led() {
    local state
    state=\$(pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null | grep -o "yes")
    sudo /usr/bin/hda-verb "\$DEV" 0x20 0x500 0x0B >/dev/null 2>&1
    if [[ "\$state" == "yes" ]]; then
        sudo /usr/bin/hda-verb "\$DEV" 0x20 0x400 0x7778 >/dev/null 2>&1
    else
        sudo /usr/bin/hda-verb "\$DEV" 0x20 0x400 0x7774 >/dev/null 2>&1
    fi
}

sync_led
pactl subscribe 2>/dev/null | grep --line-buffered -i "sink-mute-changed\|on sink" | while read -r _; do
    sync_led
done
EOF
sudo chmod +x "$SCRIPT_PATH"

echo "== 5. Adding passwordless sudo rule scoped to hda-verb only =="
echo "${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/hda-verb" | sudo tee "$SUDOERS_PATH" >/dev/null
sudo chmod 440 "$SUDOERS_PATH"
sudo visudo -c -f "$SUDOERS_PATH"

echo "== 6. Installing as a user-level systemd service =="
mkdir -p "$USER_SERVICE_DIR"
cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Sync HP Omen mute LED with PipeWire mute state
After=pipewire.service

[Service]
ExecStart=$SCRIPT_PATH
Restart=on-failure

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now hp-mute-led.service

echo "== Done. Toggle mute now and check the LED. =="
echo "Logs: journalctl --user -u hp-mute-led.service -f"
