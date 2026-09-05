# nabu-accelerometer

Xiaomi Pad 5（nabu）的 SLPI/SSC 传感器方案。传感器由 SLPI/SSC 固件管理，Linux 通过
FastRPC、QRTR/QMI 和 libssc 读取数据，不直接访问 SSC SPI 或 Sensor Clock
Controller 寄存器。

## 最终架构

```text
LSM6DSO / TCS3701 / AK0991x -> SLPI/SSC firmware -> FastRPC/QRTR -> libssc
                                             -> iio-sensor-proxy -> desktop
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
UKI_STUB=../.nabu-shared-build.mN6hC8/linuxaa64.efi.stub \
  ./scripts/build.sh \
  ../linux \
  ../.nabu-shared-build.mN6hC8/out \
  ../artifacts
```

最终构建产物只有：

- `nabu-accelerometer-production.efi`；
- `fastrpc.ko`；
- `qcom_pd_mapper.ko`；
- `nabu-tablet-mode`。

当前已验证生产 UKI：

```text
SHA256: b0b5078230aa2495d332ecf2ded65f44c46c6ead8fdaf1bea3804417c79ac398
```

## 安装

目标机的 `/dev/disk/by-partlabel/esp` 是第 31 分区 `/dev/sda31`。生产 UKI 安装到：

```text
/dev/sda31:/EFI/ubuntu/6.14.11-nabu-iris-camera1+-build1.efi
```

将产物放进项目的 `artifacts/` 后，使用统一命令：

```sh
sudo bash scripts/install.sh
```

也可以显式指定：

```sh
sudo bash scripts/install.sh /path/to/artifacts
```

安装器会校验 UKI SHA256、模块名称和 vermagic，备份原默认 UKI，再原子替换第 31
分区中的默认文件。安装完成后重启。

首次部署时，把下面两个固定版本源码包也放进 `artifacts/`：

```text
libssc-v0.4.4.tar.gz
iio-sensor-proxy-3.9.tar.gz
```

`install.sh` 会统一处理第 31 分区、内核模块、SLPI 文件系统、hexagonrpcd、libssc、
iio-sensor-proxy 和 tablet-mode helper。已正确安装的 userspace 组件不会要求重复提供
源码包。

## 验证

```sh
sudo bash scripts/verify.sh
sudo bash scripts/verify.sh 20   # 每种 SSC 传感器额外采样 20 秒
```

最终真机启动应满足：

- 四个 remoteproc 都为 `running`；
- `hexagonrpcd` 和 `iio-sensor-proxy` 为 active，`NRestarts=0`；
- D-Bus 返回 `HasAccelerometer=true`、`HasAmbientLight=true` 和
  `HasCompass=true`；
- 日志没有 SLPI crash、USER-PD watchdog、attach timeout 或 IOMMU fault。

桌面接口使用 LSM6DSO 加速度计、TCS3701 环境光传感器和基于 Qualcomm Rotation
Vector 的罗盘。libssc CLI 还可以直接读取 LSM6DSO 陀螺仪和 AK0991x 磁力计：

```sh
ssccli --sensor gyroscope --timeout 10
ssccli --sensor magnetometer --timeout 10
ssccli --sensor light --timeout 10
ssccli --sensor compass --timeout 10
```

## 回滚

```sh
sudo bash scripts/restore.sh kernel
sudo bash scripts/restore.sh all
```

`kernel` 只恢复原 UKI；`all` 同时移除 userspace 集成。SLPI registry/calibration
数据始终保留。`libexec/` 中的文件是内部实现，不是用户入口。
