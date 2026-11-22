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

## Setup (on the phone)

```sh
# Disable auto-suspend (current session + dconf defaults for all future
# sessions)
P=$(pgrep -u $USER -f phosh | head -1)
B=$(sudo tr "\0" "\n" < /proc/$P/environ | grep DBUS_SESSION_BUS | cut -d= -f2-)

sudo -u $USER DBUS_SESSION_BUS_ADDRESS="$B" \
    gsettings set org.gnome.settings-daemon.plugins.power \
    sleep-inactive-battery-timeout 0
sudo -u $USER DBUS_SESSION_BUS_ADDRESS="$B" \
    gsettings set org.gnome.settings-daemon.plugins.power \
    sleep-inactive-ac-timeout 0

# Persist across sessions via dconf system defaults
sudo mkdir -p /etc/dconf/profile /etc/dconf/db/local.d
printf "user-db:user\nsystem-db:local\n" | sudo tee /etc/dconf/profile/user
printf "[org/gnome/settings-daemon/plugins/power]\nsleep-inactive-battery-timeout=uint32 0\nsleep-inactive-ac-timeout=uint32 0\n" \
    | sudo tee /etc/dconf/db/local.d/00-always-online
sudo dconf update

# Disable Wi-Fi power save (reduces latency, must be reapplied at boot)
# The dconf wifi-powersave=0 entry handles it via the settings daemon.
# For immediate effect:
sudo iw dev wlp1s0 set power_save off
```

## Manual suspend still works

`systemctl suspend` from the terminal or the power menu still suspends
normally. Only the *automatic* idle suspend is disabled.

## When to use suspend mode instead

If battery life matters more than continuous connectivity, re-enable:

```sh
gsettings set org.gnome.settings-daemon.plugins.power \
    sleep-inactive-battery-timeout 900   # 15 minutes
```

The suspend-safe modem stack (MM diting2 quick hooks +
diting-modem-suspend/resume + watchdog) handles suspend cycles, but
with a small recovery gap (~30s) on each wake and residual instability
with active bearers (~1 in 6). Always-online mode has zero gaps.

## Related

- MM diting2 patch: keeps modem objects across suspend (packages/
  modemmanager/0002)
- Suspend-safe cellular: device pkg 0.7.30 (diting-modem-suspend/
  resume services)
- Redial watchdog: device pkg (diting-modem-redial, v4 with PDN
  throttle backoff and remoteproc escalation)
- CN-ADAPTATION.md: full problem history
