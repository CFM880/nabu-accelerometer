# Sources

## Linux

- Tree: `https://gitlab.postmarketos.org/soc/qualcomm-sm8150/linux.git`
- Baseline: `5181e1358ddd6ea8028e841d928942373e6aebc8`
- FastRPC: `drivers/misc/fastrpc.c`
- PD mapper: `drivers/soc/qcom/qcom_pd_mapper.c`
- PDR API: `include/linux/soc/qcom/pdr.h`

## Nabu firmware layout

The installed SLPI image is
`/lib/firmware/qcom/sm8150/xiaomi/nabu/slpi_nb.mbn`. Sensor configuration and
registry files are exposed through `/lib/firmware/hexagonfs` and the FastRPC
reverse listener.

Android vendor sensor configuration identifies the accelerometer and gyroscope
as LSM6DSO on SSC SPI bus instance 2, chip select 0. It also configures an
AK0991x magnetometer and TCS3701 ambient-light sensor. These buses are owned by
SLPI, not an AP QUP controller.

## Userspace

- hexagonrpc: Ubuntu package 0.4.0
- libssc: `https://codeberg.org/DylanVanAssche/libssc`, version 0.4.4
- iio-sensor-proxy: upstream version 3.9 with SSC backend

Pinned archives:

```text
libssc-v0.4.4.tar.gz
SHA256: 716d6bd6b34d2d753060c6b54c9a87e34fae75b724c763bf9ef487efa3621587

iio-sensor-proxy-3.9.tar.gz
SHA256: af5edd307dcfa52dc3a242d13b7cc756e90a71640caf332efbad960e21649ae4
```
