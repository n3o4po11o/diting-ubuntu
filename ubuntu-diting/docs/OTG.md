# OTG (USB host mode) on the Xiaomi 12T Pro (diting)

Since kernel r51 (patch 0098) the USB-C port is dual-role: plugging an
OTG adapter switches to host mode automatically, unplugging returns to
the device-mode gadget (NCM + ACM). Runs on the eUSB2 bus: **USB 2.0
high-speed only** - the board does not wire the SuperSpeed lanes to the
connector (the SoC itself supports USB 3; that is a mainboard decision).

Verified devices: USB ethernet (RTL8156B), mass storage, HID.

## USB ethernet (RTL8156B example)

Device package 0.7.27+ lets NetworkManager manage ethernet devices
(bring-up images had `unmanaged-devices=*,except:...` without
`except:type:ethernet`). On older installs, fix it by hand:

```sh
sudo sed -i 's/except:interface-name:usb0/except:interface-name:usb0,except:type:ethernet/' \
	/etc/NetworkManager/conf.d/90-diting-usb0.conf
sudo nmcli connection reload && sudo systemctl restart NetworkManager
```

The RTL8156B wants a firmware patch that the image does not carry
(only Qualcomm firmware packages are preinstalled); without it the link
still comes up. To install it (phone needs any network first):

```sh
curl -fsSL -o /tmp/fw https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/rtl_nic/rtl8156b-2.fw
sudo install -D -m 644 /tmp/fw /lib/firmware/rtl_nic/rtl8156b-2.fw
```

If the interface comes up as `connected (externally)` (the kernel ran
SLAAC while it was still unmanaged) it will not DHCP; give it an
explicit profile once:

```sh
sudo nmcli c add type ethernet ifname enx00e04e3b0040 con-name usb-eth \
	ipv4.method auto ipv6.method auto autoconnect yes
sudo nmcli c up usb-eth
```

After that the adapter is plug-and-play (autoconnect). The interface
name (`enx…`) is derived from the adapter's MAC - adjust for other
adapters.
