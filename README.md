# colorfan — custom fan curve for the Colorful X17 Pro

Goal: fans sit quiet under load ramp and reach **100 % duty at 70 °C**, not at 50 °C.

## Why `pwmconfig` / `fancontrol` can never work on this machine

Measured on BK-X17PRO, kernel `7.3.0-9-generic`:

| check | result |
|---|---|
| `for d in /sys/class/hwmon/*; do ls $d; done` | all 8 devices (coretemp, acpitz, nvme ×2, iwlwifi, BAT0, AC, ucsi) expose only `temp*/power/curr/in` — **zero `pwm*`, zero `fan*`** |
| `grep -c pwm /sys/class/hwmon/*/` | nothing; hence `pwmconfig` → *"There are no pwm-capable sensor modules installed"* and `/etc/fancontrol` is never created, so `fancontrol.service` stays skipped on `ConditionFileNotEmpty` |
| `sensors-detect` | `Found unknown chip with ID 0x5570` at `0x2e/0x2f` = the ITE IT5570 embedded controller. No in-tree driver; `CONFIG_SENSORS_IT5571`/`CLEVO` symbols do not exist in this kernel config at all. `it87.ko` is present but does **not** support 0x5570 — force-binding it can lock up the EC |
| `ls /sys/class/thermal/cooling_device*/type` | only `Processor`, `PCIe_Port_Link_Speed_*`, `intel_powerclamp`, `TCC Offset`. There is **no Fan cooling device**, so kernel thermal can throttle the CPU but can never spin a fan |
| `cat /sys/bus/platform/devices/CLV0001:00/path` | `\_SB_.DCHU` — and `CLV0002:00` → `\_SB_.DCHP`, both unclaimed by any driver |
| `lspci`, DMI | `COLORFUL` / `X17 Pro`, BIOS `INSYDE Corp. 1.07.08TOYC1`, RTX 3080 Ti Laptop. This is a **Clevo/Tongfang barebone**, so the fans hang off the EC, not off motherboard PWM circuitry |

The EC runs its own firmware curve and that curve is not editable. Getting 70 °C → full speed therefore means **taking over duty control from userspace**, which is exactly what the `ubuntu-fan.service` on this box is *not* (that unit is the LXC **network** fan, `/usr/lib/ubuntu-fan/fan-net`).

## The interface that does reach the fans

`PNP0C14:02` on this machine resolves to `\_SB_.WMI_`, GUID `ABBC0F6D-8EA1-11D1-00A0-C90629100000`, `object_id = BB` → the Clevo WMI method `WMBB`, driven through `acpi_call` (`/proc/acpi/call`).

| `Arg1` | `Arg2` | effect |
|---|---|---|
| `0x0c` | `0x0` | read EC telemetry (CPU RPM, GPU RPM, current duty) |
| `0x68` | `0xNNNNNNNN` | set duty directly, **one byte per channel 1-4**, 0-255 |
| `0x69` | `0x0000000f` | hand channels 1-4 back to the EC auto curve (the rollback switch) |
| `0x79` | `0x01000000` / `0x01000001` | EC fan mode preset: auto / max |

Byte layout, as upstream documents it: CPU RPM = `data[2]<<8 | data[3]`, GPU1 = `data[4]<<8 | data[5]`, duty at `data[16]`/`data[19]` (0-indexed), and
`rpm = round((60 / (0.00005565217391304348 * raw)) * 2)`. Note upstream records that these reads are *not* purely passive (they trigger EC register writes), so `colorfan daemon` never polls RPM — it only reads `coretemp` and writes duty when the target changes or once per `REASSERT_S`.

**Reply shape verified on this BIOS (2026-10-26).** `acpi_call` answers `0x0c` with **comma-separated hex text inside braces plus one trailing NUL** (253 bytes, ≈42 values), not the 256-byte raw buffer upstream describes — which is why an early version logged `warning: command substitution: ignored null byte in input`. The captured head decoded to bytes 1-5 = `00 00 01 7e 05`, so bytes 3/4 = 382 → **~5644 rpm** while the EC had control, matching an audible fan: `CPU_RPM_BYTES="3 4"` is real here. Bytes 5/6 and the duty positions 17/20 come from the same upstream layout but are **not yet confirmed on this firmware** — `sudo colorfan probe` prints every parsed value so they can be pinned.

## Instructions

All steps as root. `proxy.sh` prefixes the network commands on this box.

### 1. Install `acpi_call`

```bash
sudo proxy.sh apt-get install -y acpi-call-dkms dkms acpica-tools jq lm-sensors
sudo modprobe acpi_call
echo acpi_call | sudo tee /etc/modules-load.d/colorfan.conf
ls -l /proc/acpi/call          # must exist
```

Prerequisites verified already: SecureBoot **disabled** (so an unsigned DKMS module loads), `linux-headers-7.3.0-9-generic` installed. Not verified: that `acpi-call-dkms` 1.2.2 builds against a 7.3 kernel — check `dkms status` and `modprobe acpi_call` output after step 1.

### 2. Confirm the method name in your DSDT before writing anything

```bash
cd /tmp && sudo acpidump -b && sudo iasl -d dsdt.dat
sudo grep -n -E 'Name \(_HID.*CLV000|Device \(DCHU|Device \(DCHP|Method \(WMBB' dsdt.dsl
```

The `Method (WMBB` line's enclosing device gives the real namespace path. Upstream calls it as `\_SB.WMI.WMBB`; on this box the node renders as `\_SB_.WMI_`, so if step 3 errors, set the other spelling in `/etc/colorfan.conf`:

```bash
FAN_METHOD='\_SB.WMI.WMBB'      # default
FAN_METHOD='\_SB_.WMI_.WMBB'    # if the first returns AE_NOT_FOUND
```

Hand-check it before using any script:

```bash
echo '\_SB.WMI.WMBB 0x0 0x0c 0x0' | sudo tee /proc/acpi/call && sudo cat /proc/acpi/call
```

A buffer of hex bytes came back → the path is right. `AE_NOT_FOUND`/`NULL` → fix `FAN_METHOD`.

### 3. Install and probe colorfan

```bash
cd /home/brucekomike/Workspace/probe/colorfan
sudo ./install.sh
sudo colorfan probe && sudo colorfan status
```

### 4. Prove control with a one-shot, then roll back

```bash
sudo colorfan set 100     # fans should spool up immediately
sudo colorfan auto        # back to the EC firmware curve
```

If `set 100` changes nothing audible, the EC is ignoring `0x68` for your channel map — try the mode preset instead (`sudo colorfan mode max`), and check whether your chassis answers on a different channel byte.

### 5. Calibrate duty → RPM (pick real curve points)

```bash
sudo colorfan calibrate
```

Prints RPM at 0/25/50/75/100 % duty and restores auto on Ctrl-C. Duty is linear electrical, not linear in RPM or noise, so this is what tells you where "audibly full" actually sits.

### 6. Set the curve to hit full speed at 70 °C

`/etc/colorfan.conf` ships with:

```
CPU_CURVE='40:30 55:45 62:60 66:80 70:100'
```

`degC:percent`, linearly interpolated, clamped at both ends — 57 °C (what `sensors` reads on this box right now) sits at ~49 % duty, and 70 °C is the ceiling at 100 %. Raise/lower the intermediate points to taste; leave the last point at `70:100` to keep the requested behaviour. `EMERG_C=90` forces 100 % independent of the curve.

### 7. Run it as a service

```bash
sudo systemctl enable --now colorfan
journalctl -t colorfan -f
```

The daemon writes duty only when it changes, re-asserts every 60 s (the EC reverts to its own curve across S3 resume, so a wake-up re-applies within a poll cycle), limits each step to `STEP_MAX` to stop flutter, holds a raised duty for `HOLD_DOWN_S` before backing off, and calls `0x69 0x0f` on `EXIT`/`INT`/`TERM` plus `ExecStopPost` in the unit so a crash or `systemctl stop` always leaves the fans on the EC curve.

### 8. Back out

```bash
sudo systemctl disable --now colorfan   # unit's ExecStopPost reverts to EC auto
sudo colorfan auto                      # belt and braces
sudo colorfan mode auto
```

## Files

| file | role |
|---|---|
| `colorfan` | CLI + daemon; talks to the EC through `/proc/acpi/call`, reads temp from `sensors -j` |
| `colorfan.conf` | curve and timing knobs → `/etc/colorfan.conf` |
| `colorfan.service` | systemd unit, reverts to EC control on stop |
| `install.sh` | deps, `modules-load.d`, file install, first probe |

## Temperature sources used

- CPU: `sensors -j | jq -r '."coretemp-isa-0000"."Package id 0".temp1_input'` — verified on this box (note the key is `temp1_input`, not `input`).
- GPU: `nvidia-smi --query-gpu=temperature.gpu` — verified, returned 36. The dGPU fan is on the EC too: `nvidia-smi` exposes **no** `fan_speed` field and there is no hwmon dir under `0000:01:00.0`, so `nvidia-settings`/`xrandr`-style GPU fan control is not available here.

## What is verified vs not

Verified by measurement on this machine: no PWM/fan in sysfs, no fan cooling device, the ITE 0x5570 chip, the `CLV0001/CLV0002` DCHU/DCHP nodes, `\_SB_.WMI_` + GUID `ABBC0F6D`/`object_id BB`, SecureBoot off, headers installed, package temp at 57 °C, apt candidates for `acpi-call-dkms`/`acpica-tools`.

Not verified (needs root plus a loaded `acpi_call`, i.e. steps 1-3): that `WMBB` answers on this BIOS revision, the exact channel→fan map (2 or 4 channels), the RPM formula on this chassis, and whether `0x79` presets exist on the 1.07.08TOYC1 firmware. `colorfan` is built so each of those fails loudly instead of silently pinning a fan at 0.

If you want `/etc/fancontrol` itself (rather than this daemon), the missing piece is a kernel shim: a ~200-line DKMS hwmon module whose `pwm1`/`fan1_input` are backed by `WMBB 0x68`/`0x0c`, registered as a `thermal_cooling_device`. Your kernel already ships in-tree precedents of exactly that shape (`yogafan.ko`, `surface_fan.ko`, `gpd-fan.ko`, `lenovo-ec-sensors.ko`, `lattepanda-sigma-ec.ko` in `/lib/modules/$(uname -r)/kernel/drivers/hwmon/`). With such a module loaded, `pwmconfig` would stop complaining and stock `fancontrol` would work.

## Sources

https://github.com/samoylenkodmitry/clevo-thermald
https://github.com/samoylenkodmitry/clevo-thermald/blob/main/docs/REVERSE-ENGINEERING.md
https://www.nite07.com/en/posts/linux-clevo-drivers/
https://github.com/topics/clevo
https://github.com/agramian/clevo-fan-control
https://github.com/lm-sensors/lm-sensors/issues/400
https://github.com/frankcrawford/it87/issues/49
https://github.com/passiveEndeavour/it5570-fan
https://aur.archlinux.org/packages/clevo-drivers-dkms-git
https://wiki.archlinux.org/title/Fan_speed_control
