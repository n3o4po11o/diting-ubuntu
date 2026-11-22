# Always-online mode (no auto-suspend)

The simplest and most reliable way to keep the modem and Wi-Fi
continuously online: **never auto-suspend the system**. This eliminates
the entire class of suspend/resume problems (ModemManager object
teardown, QRTR re-probe races, bearer restoration, Wi-Fi
reconnection) by never triggering them.

## What it does

| Component | Behavior |
| --- | --- |
| Modem | Stays registered, bearer never drops, calls/SMS instant |
| Wi-Fi | Stays connected, power save off for lowest latency |
| Screen | Still turns off after idle (saves power, just no system sleep) |
| Battery | ~3-6%/hour idle vs ~1%/hour with suspend |

## Why gsettings alone is not enough

Three independent suspend sources must all be addressed:

1. **GNOME/Phosh idle timer** (`sleep-inactive-*-timeout`) — the
   desktop session's own idle detection. Set to 0 via gsettings.
2. **`diting-resuspend` service** — re-suspends 20 s after every
   resume when no user input (designed for pocket mode; defeats
   always-online by looping suspend/resume every 30 s). It already
   checks for a logind sleep inhibitor and stays awake when one
   is held.
3. **ADSP charger firmware** — sends a status message every 480 s
   that wakes the CPU from deep sleep, which then triggers
   diting-resuspend to re-suspend. The inhibitor breaks this loop.

The `diting-always-online.service` holds a persistent logind sleep
inhibitor (`--mode=block`), which stops sources 2 and 3. Source 1 is
handled by the gsettings/dconf configuration. `mode=block` only
blocks *idle* suspend — the power menu still works.

## Setup (on the phone)

```sh
# 1. Hold a sleep inhibitor (stops diting-resuspend + ADSP wake loop)
sudo systemctl enable --now diting-always-online.service

# 2. Disable the desktop idle timer
P=$(pgrep -u $USER -f phosh | head -1)
B=$(sudo tr "\0" "\n" < /proc/$P/environ | grep DBUS_SESSION_BUS | cut -d= -f2-)
sudo -u $USER DBUS_SESSION_BUS_ADDRESS="$B" \
    gsettings set org.gnome.settings-daemon.plugins.power \
    sleep-inactive-battery-timeout 0
sudo -u $USER DBUS_SESSION_BUS_ADDRESS="$B" \
    gsettings set org.gnome.settings-daemon.plugins.power \
    sleep-inactive-ac-timeout 0

# 3. Persist across sessions via dconf system defaults
sudo mkdir -p /etc/dconf/profile /etc/dconf/db/local.d
printf "user-db:user\nsystem-db:local\n" | sudo tee /etc/dconf/profile/user
printf "[org/gnome/settings-daemon/plugins/power]\nsleep-inactive-battery-timeout=uint32 0\nsleep-inactive-ac-timeout=uint32 0\nwifi-powersave=0\n" \
    | sudo tee /etc/dconf/db/local.d/00-always-online
sudo dconf update

# 4. Wi-Fi power save off (dconf handles future sessions; immediate:
sudo iw dev wlp1s0 set power_save off
```

## Verify

```sh
# No suspend in the last 5 minutes:
sudo journalctl --since "-5 min" | grep -c "PM: suspend entry"  # → 0

# Sleep inhibitor held:
systemd-inhibit --list | grep block | grep diting

# Both channels online:
nmcli -t device | grep -E "gsm.*connected|wifi.*connected"
```

## Switch back to suspend mode

```sh
sudo systemctl disable --now diting-always-online.service
gsettings set org.gnome.settings-daemon.plugins.power \
    sleep-inactive-battery-timeout 900   # 15 minutes
```

The suspend-safe modem stack (MM diting2 quick hooks +
diting-modem-suspend/resume + watchdog) handles suspend cycles, but
with a recovery gap (~30 s) on each wake and residual instability
with active bearers (~1 in 6).

## The suspend/resume cycle we eliminated

Before always-online mode, the ADSP charger firmware's 480-second
status messages caused this loop (measured: 22 suspend cycles per
hour, each producing ~35 lines of CPU hotplug dmesg):

    ADSP status message → CPU wakes → diting-resuspend starts
    → 20 s no user input → systemctl suspend
    → ADSP status message → CPU wakes → ... (forever)

With the inhibitor, the ADSP message still arrives (the modem needs
it), but diting-resuspend sees the inhibitor and stays awake.

## Related

- MM diting2 patch: keeps modem objects across suspend (packages/
  modemmanager/0002)
- Suspend-safe cellular: device pkg 0.7.30 (diting-modem-suspend/
  resume services)
- Redial watchdog: device pkg (diting-modem-redial, v4 with PDN
  throttle backoff and remoteproc escalation)
- Hardware recovery watchdog: BT controller + USB gadget (0.7.31)
- CN-ADAPTATION.md: full problem history
