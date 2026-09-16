# nabu-accelerometer

**English** | [中文](README.zh.md)

The SLPI/SSC sensor solution for the Xiaomi Pad 5 (nabu). The sensors are managed by SLPI/SSC
firmware, and Linux reads data through FastRPC, QRTR/QMI, and libssc without directly accessing the
SSC SPI or Sensor Clock Controller registers.

## Final architecture

```text
LSM6DSO / TCS3701 / AK0991x -> SLPI/SSC firmware -> FastRPC/QRTR -> libssc
                                             -> iio-sensor-proxy -> desktop
```

The kernel patches accomplish two things:

- establish the high IOVA alias the DSP needs for the SM8150 SDSP buffer;
- wait for the SLPI root-PD PDR notification before `FASTRPC_IOCTL_INIT_ATTACH_SNS`.

On a normal boot the root PD is already up, so it does not wait; 15 seconds is only an abnormal
timeout. The production UKI also enables Camera and masks `venus_core` and `qcom_iris` via cmdline.

## Build

The kernel baseline must be `5181e1358ddd6ea8028e841d928942373e6aebc8` and must include the current
Nabu Camera/Iris combined source.

```sh
UKI_STUB=../.nabu-shared-build.mN6hC8/linuxaa64.efi.stub \
  ./scripts/build.sh \
  ../linux \
  ../.nabu-shared-build.mN6hC8/out \
  ../artifacts
```

The final build artifacts are only:

- `nabu-accelerometer-production.efi`;
- `fastrpc.ko`;
- `qcom_pd_mapper.ko`;
- `nabu-tablet-mode`.

Currently verified production UKI:

```text
SHA256: b0b5078230aa2495d332ecf2ded65f44c46c6ead8fdaf1bea3804417c79ac398
```

## Install

The target machine's `/dev/disk/by-partlabel/esp` is partition 31, `/dev/sda31`. The production UKI
is installed to:

```text
/dev/sda31:/EFI/ubuntu/6.14.11-nabu-iris-camera1+-build1.efi
```

After placing the artifacts into the project's `artifacts/`, use the unified command:

```sh
sudo bash scripts/install.sh
```

You can also specify it explicitly:

```sh
sudo bash scripts/install.sh /path/to/artifacts
```

The installer verifies the UKI SHA256, module names, and vermagic, backs up the original default
UKI, and then atomically replaces the default file on partition 31. Reboot after installation.

Two pinned source tarballs are kept in the repository under `third_party/` (see
[SOURCE.md](SOURCE.md) for SHA256). When a rebuild is needed, they are extracted and built inside the
repository at `third_party/build/` (`libssc/`, `iio-sensor-proxy/`), applying
`patches/0002-ssc-light-filter.patch` to iio-sensor-proxy and compiling it, with no external
preparation required; already correctly installed components are reused directly. To use a different
archive, place it in `artifacts/` to override (artifacts take precedence).

`install.sh` (invoked by `nabu-main install` under the unified build) handles the SLPI filesystem,
hexagonrpcd, libssc, iio-sensor-proxy, and the tablet-mode helper.

## Verify

```sh
sudo bash scripts/verify.sh
sudo bash scripts/verify.sh 20   # sample each SSC sensor for an extra 20 seconds
```

A final boot on real hardware should satisfy:

- all four remoteprocs are `running`;
- `hexagonrpcd` and `iio-sensor-proxy` are active with `NRestarts=0`;
- D-Bus returns `HasAccelerometer=true`, `HasAmbientLight=true`, and `HasCompass=true`;
- the log has no SLPI crash, USER-PD watchdog, attach timeout, or IOMMU fault.

The desktop interfaces use the LSM6DSO accelerometer, the TCS3701 ambient light sensor, and a
compass based on the Qualcomm Rotation Vector. The libssc CLI can also read the LSM6DSO gyroscope
and the AK0991x magnetometer directly:

```sh
ssccli --sensor gyroscope --timeout 10
ssccli --sensor magnetometer --timeout 10
ssccli --sensor light --timeout 10
ssccli --sensor compass --timeout 10
```

### Auto-brightness stabilization

The SSC ambient light backend adds a Nabu filter patch: it uses temporal smoothing and ignores
fluctuations within 25% (at least 4 lux) of the already-confirmed target. After both the current
reading and the smoothed value cross the threshold, a normal brighten must persist for 6 seconds and
a dim for 12 seconds; changes of more than twice the value shorten these to 2 seconds and 8 seconds
respectively. Smoothing itself also has latency. After a new target is confirmed, it transitions
stepwise every 250 milliseconds, changing at most 1.5% of the current output per step (at most
0.125 lux in low light) to avoid an abrupt jump after the wait. The first reading is reported
directly, and the state is reset after the sensor is released. A timer ensures SSC sends only one
event when the value changes and can still confirm sustained changes.

This changes the desktop D-Bus `LightLevel`; `ssccli --sensor light` can still read the light data
without this filter. The parameters are intended to reduce flicker under constant lighting, and real
environmental changes take a moment to respond.

An existing installation needs to provide `iio-sensor-proxy-3.9.tar.gz` for a rebuild to enable the
patch. To update only the light proxy without reinstalling the kernel or rebooting:

```sh
sudo sh libexec/install-iio-sensor-proxy-ssc.sh /path/to/iio-sensor-proxy-3.9.tar.gz
```

After the proxy restarts, the current GNOME session may still hold the old connection, so it
receives light values but the backlight no longer follows. Run the following command in the desktop
user's terminal to reconnect the power service (no sudo needed):

```sh
systemctl --user restart org.gnome.SettingsDaemon.Power.target
```

## Rollback

```sh
sudo bash scripts/restore.sh kernel
sudo bash scripts/restore.sh all
```

`kernel` restores only the original UKI; `all` also removes the userspace integration. SLPI
registry/calibration data is always preserved. The files in `libexec/` are internal implementation,
not a user entry point.
