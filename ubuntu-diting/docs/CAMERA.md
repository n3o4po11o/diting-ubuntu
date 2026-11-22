# Camera status and roadmap on the Xiaomi 12T Pro (diting, CN)

## Hardware (CN unit, measured)

| Camera | Sensor | Driver | camregs | Status |
| --- | --- | --- | --- | --- |
| Wide (main) | Samsung **S5KHM6** | none | ✅ built by firmware extraction | ❌ needs a new driver |
| Ultra-wide | Sony **S5K4H7** | ✅ `s5k4h7` (mainline) | ✅ built by firmware extraction | ✅ should work |
| Front | Sony **IMX596** | none | not extracted | ❌ needs a driver |
| Macro | GalaxyCore **GC02M1** | none | not extracted | ❌ needs a driver |

The CN and EEA units carry different wide camera sensors: EEA has the
S5KHP1, CN has the S5KHM6 (kernel r52 disables the s5khp1 DT node on
CN; the firmware extraction builds `s5khm6-wide.camregs` from the CN
vendor's chromatix module, not `s5khp1-wide.camregs`).

## What works now

- **Ultra-wide (S5K4H7)**: driver + camregs + CSIPHY + ISP are all in
  place. Test with GNOME Snapshot (`snap install snapshot --classic`)
  or `libcamera-hello`. If it appears but the image is wrong, the
  register tables may need tuning (they come from the vendor's
  chromatix binary, converted by `chromatix-to-camregs.py`).
- **Video decode/encode**: independent of cameras; the IRIS2 codec
  works.

## HM6 (wide) driver roadmap

The S5KHM6 driver does not exist in mainline. To write one:

1. **Reference drivers**: `drivers/media/i2c/s5khp1/` (this kernel,
   patch 0068+) and `s5kjn1/` (mainline) are the closest Samsung
   sensors with camregs-style register tables.
2. **Register tables**: already built — `/usr/lib/firmware/qcom/
   sm8475/xiaomi/diting/s5khm6-wide.camregs` (from
   `com.qti.sensormodule.diting_sunny_s5khm6_wide.bin` via
   `chromatix-to-camregs.py`; includes init, 4 resolution modes with
   DSI DSC commands).
3. **DT node**: replace the disabled `camera@10` (s5khp1) with a
   `samsung,s5khm6` node at the same I2C address (0x10), same MCLK,
   reset GPIO, supplies and CSIPHY endpoint. The link frequencies
   are in the camregs mode tables.
4. **Actuator**: the wide lens has an actuator (`cam_wide_lens`,
   AK7314). The driver needs to expose the V4L2 focus controls; the
   register values are in the DT node.
5. **Flash**: not wired on this unit.

Estimated effort: 2-3 days for basic capture (no autofocus, one
mode), another 2-3 for full resolution switching and focus.

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
