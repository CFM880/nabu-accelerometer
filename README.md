# nabu-accelerometer

Xiaomi Pad 5（nabu）的最终加速度计方案。传感器由 SLPI/SSC 固件管理，Linux 通过
FastRPC、QRTR/QMI 和 libssc 读取数据，不直接访问 SSC SPI 或 Sensor Clock
Controller 寄存器。

## 最终架构

```text
LSM6DSO -> SLPI/SSC firmware -> FastRPC/QRTR -> libssc
        -> iio-sensor-proxy -> GNOME/Mutter
```

内核补丁完成两件事：

- 为 SM8150 SDSP buffer 建立 DSP 所需的高 IOVA alias；
- 在 `FASTRPC_IOCTL_INIT_ATTACH_SNS` 前等待 SLPI root-PD 的 PDR 通知。

正常启动时 root PD 已经上线，因此不会等待；15 秒仅为异常超时。生产 UKI 同时启用
Camera，并通过 cmdline 屏蔽 `venus_core` 和 `qcom_iris`。

## 构建

内核基线必须是 `5181e1358ddd6ea8028e841d928942373e6aebc8`，并包含当前 Nabu
Camera/Iris 组合源码。

```sh
./scripts/apply-overlay.sh ../linux

./scripts/build.sh \
  ../linux \
  ../.nabu-shared-build.mN6hC8/out

UKI_STUB=../.nabu-shared-build.mN6hC8/linuxaa64.efi.stub \
  ./scripts/build-production-uki.sh \
  ../linux \
  ../.nabu-shared-build.mN6hC8/out \
  ../.nabu-shared-build.mN6hC8/nabu-accelerometer-production.efi
```

最终构建产物只有：

- `nabu-accelerometer-production.efi`；
- `drivers/misc/fastrpc.ko`；
- `drivers/soc/qcom/qcom_pd_mapper.ko`。

当前已验证生产 UKI：

```text
SHA256: b0b5078230aa2495d332ecf2ded65f44c46c6ead8fdaf1bea3804417c79ac398
```

## 安装

目标机的 `/dev/disk/by-partlabel/esp` 是第 31 分区 `/dev/sda31`。生产 UKI 安装到：

```text
/dev/sda31:/EFI/ubuntu/6.14.11-nabu-iris-camera1+-build1.efi
```

将三个产物放进项目的 `artifacts/` 后，可以使用无参数统一命令：

```sh
sudo bash scripts/install-production-system.sh
```

也可以显式指定：

```sh
sudo bash scripts/install-production-system.sh \
  /path/to/nabu-accelerometer-production.efi \
  /path/to/fastrpc.ko \
  /path/to/qcom_pd_mapper.ko
```

安装器会校验 UKI SHA256、模块名称和 vermagic，备份原默认 UKI，再原子替换第 31
分区中的默认文件。安装完成后重启。

首次部署还需要安装 SLPI 文件系统、libssc、SSC 版 iio-sensor-proxy 和
tablet-mode helper：

```sh
sudo bash scripts/install-slpi-filesystem.sh
sudo bash scripts/install-libssc.sh ./libssc-v0.4.4.tar.gz
sudo bash scripts/install-iio-sensor-proxy-ssc.sh ./iio-sensor-proxy-3.9.tar.gz

./scripts/build-tablet-mode.sh ./nabu-tablet-mode
sudo bash scripts/install-tablet-mode.sh ./nabu-tablet-mode
```

## 验证

```sh
./scripts/test-libssc-accelerometer.sh 20
./scripts/test-iio-sensor-proxy-ssc.sh 20
sudo bash scripts/inspect-default-uki.sh
```

最终真机启动应满足：

- 四个 remoteproc 都为 `running`；
- `hexagonrpcd` 和 `iio-sensor-proxy` 为 active，`NRestarts=0`；
- D-Bus 返回 `HasAccelerometer=true`；
- 日志没有 SLPI crash、USER-PD watchdog、attach timeout 或 IOMMU fault。

## 回滚

```sh
sudo bash scripts/restore-production-uki.sh
sudo bash scripts/remove-tablet-mode.sh
sudo bash scripts/remove-iio-sensor-proxy-ssc.sh
sudo bash scripts/remove-hexagonrpcd-nabu-config.sh
sudo bash scripts/remove-slpi-filesystem.sh
```

回滚脚本只删除本项目识别的文件；SLPI registry/calibration 数据会保留。
