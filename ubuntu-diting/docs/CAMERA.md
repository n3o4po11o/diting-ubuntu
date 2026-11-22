# Camera status and roadmap on the Xiaomi 12T Pro (diting, CN)

## Hardware (CN unit, measured)

| Camera | Sensor | Driver | camregs | Status |
| --- | --- | --- | --- | --- |
| Wide (main) | Samsung **S5KHM6** | ✅ `s5khm6` (patches 0100-0102) | ✅ built by firmware extraction | 🔶 built, needs on-device verification |
| Ultra-wide | Sony **S5K4H7** | ✅ `s5k4h7` (mainline) | ✅ built by firmware extraction | ✅ should work |
| Front | Sony **IMX596** | none | not extracted | ❌ needs a driver |
| Macro | GalaxyCore **GC02M1** | none | not extracted | ❌ needs a driver |

The CN and EEA units carry different wide camera sensors: EEA has the
S5KHP1 (Semco module, AK7314 actuator), CN has the S5KHM6 (Sunny
module, DW9800V actuator). Since kernel r53 the `camera@10` node is a
`samsung,s5khm6` (the firmware extraction builds `s5khm6-wide.camregs`
from the CN vendor's chromatix module either way).

## What works now

- **Ultra-wide (S5K4H7)**: driver + camregs + CSIPHY + ISP are all in
  place. Test with GNOME Snapshot (`snap install snapshot --classic`)
  or `libcamera-hello`. If it appears but the image is wrong, the
  register tables may need tuning (they come from the vendor's
  chromatix binary, converted by `chromatix-to-camregs.py`).
- **Video decode/encode**: independent of cameras; the IRIS2 codec
  works.

## HM6 (wide) driver — written, verification pending

The `s5khm6` driver (kernel patches 0100-0102) is a sibling of the
s5khp1 one: register tables from
`/usr/lib/firmware/qcom/sm8475/xiaomi/diting/s5khm6-wide.camregs`
(init + 8 mode tables; the driver exposes 6 of them).

Facts baked into the driver, cross-checked against the CN module
binary (`com.qti.sensormodule.diting_sunny_s5khm6_wide.bin`) and the
Motorola `mot_vicky_s5khm6` MTK driver (same Samsung reference
settings):

- **Chip id**: `0x1ad6` (the module bin's sensorDriverData carries
  0x1ad6/0xffff; Motorola's `MOT_VICKY_S5KHM6_SENSOR_ID`).
- **Power-up order** (module bin powerSetting): WL2866D AVDD2 → AVDD1
  → AVDD 2.9 V → DVDD 1.1 V → reset release → MCLK 19.2 MHz — the
  order the s5khp1 driver already implements.
- **One PLL setup for every mode** (0x0300-0x0312 identical in all 8
  mode tables), so a single link frequency and pixel clock; frame
  rates change only via HTS/VTS. Pixel clock 1639.995 MHz
  (Motorola's driver hardcodes the same pclk; its 0x0306/0x0304 =
  239/4 vs our 224/3 differs exactly by the 24/19.2 MCLK ratio).
  Link frequency 1195.83 MHz = pixel clock × 7/96 (the same relation
  the s5khp1 module data carries; symbol rate 2391.66 Msym/s, in the
  CSIPHY 2.5G bucket).
- **Modes**: 12000x9000@8, 4000x3000@30 (3×3 Nonacell binning),
  4000x2252@60, 1920x1080@120, 1920x1080@240, 1280x720@360.
- **Register map**: CCS-like as the HP1 (16-bit regs; exposure 0x0202,
  gain 0x0204, VTS 0x0340, HTS 0x0342); the control registers are
  reachable on page 0x4000 (0xfcfc), which the mode tables switch to
  at their end — same as the HP1 driver's explicit page write.
- **Actuator**: DW9800V at 0x0c (`diting_sunny_s5khm6_dw9800v_wide_
actuator`) — **driven since kernel r54** (patches 0103/0104): a variant
  of the dw9807-vcm driver (same position registers 0x03/0x04 and
  control 0x02; no usable status register; supplies from the WL2866D
  outputs; init = control-register power cycle → SAC2 mode with the
  module timing 0x06=0x80/0x07=0x62, from the Motorola DW9800V driver).
  `focus_absolute` 0..1023 verified on the phone; libcamera drives the
  real contrast autofocus through the sensor's `lens-focus` phandle.
- **EEPROM**: GT24P128E at 0x51 (24c128-compatible, covered by the
  existing eeprom@51 node).

## Video recording performance

Recording stutters because the whole imaging path is software: the
libcamera simple pipeline debayers and runs 3A on the CPU, and the
video encode is software too (only the Iris **decoder** has a driver;
the Venus encoder of SM8475 would need the qcom-venus driver at the
same MMIO the Iris driver occupies). Sensor-side timing is not the
limit (1080p120 works). Fixing recording properly means a hardware ISP
or at least a hardware encoder — both are separate projects.

If the first captures fail, check `dmesg` for the chip id the probe
reads (the driver logs it on mismatch) and for CSIPHY C-PHY errors;
the Bayer order (GRBG assumed, as the HP1) and the default readout
orientation may need a flip.

## IMX596 (front) and GC02M1 (macro) roadmap

1. **IMX596**: Sony front sensor. The vendor module exists in the
   CN ROM (`com.qti.sensormodule.diting_sunny_imx596_front.bin`) —
   extract camregs the same way. Write a driver based on
   `imx219`/`imx290` (mainline Sony sensors).
2. **GC02M1**: GalaxyCore macro sensor. The vendor module is
   `com.qti.sensormodule.diting_ofilm_gc02m1_macro.bin`. Write a
   driver based on `gc2145` or `ov5640` (simple 2-lane MIPI sensors).
3. Both need: DT nodes on their CSIPHY lanes, I2C addresses from
   the vendor DT, camregs from the firmware extraction.

## Pipeline architecture (for reference)

```
sensor (I2C) → CSIPHY (C-PHY 3-lane) → CSID → ISP (qcom_camss)
                 ↑                        ↑
            camregs (register tables)   VFE (video front end)
```

The ISP (`qcom_camss`, patch 0058+) and both CSIPHY instances are
already enabled. Adding a camera only needs the sensor driver + DT
node + camregs firmware file.
