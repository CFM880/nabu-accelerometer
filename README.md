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

两个固定版本源码包已随仓库保存在 `third_party/`（SHA256 见 [SOURCE.md](SOURCE.md)）。
需要重编时会在仓库内 `third_party/build/`（`libssc/`、`iio-sensor-proxy/`）解压构建，
给 iio-sensor-proxy 打上 `patches/0002-ssc-light-filter.patch` 并编译，无需再从外部
准备；已正确安装的组件会直接复用。若要用别的归档，可放进 `artifacts/` 覆盖
（artifacts 优先）。

`install.sh`（统一构建下由 `nabu-main install` 调用）会处理 SLPI 文件系统、
hexagonrpcd、libssc、iio-sensor-proxy 和 tablet-mode helper。

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

### 自动亮度防抖

SSC 环境光后端加入 Nabu 滤波补丁：使用时间平滑，忽略相对已确认目标不超过
25%（至少 4 lux）的波动。当前读数和平滑值都越过阈值后，普通调亮需持续 6 秒，
调暗需持续 12 秒；超过两倍的变化分别缩短为 2 秒和 8 秒。平滑本身也有延迟。
确认新目标后，每 250 毫秒逐步过渡，每步最多改变当前输出的 1.5%
（低照度下最多 0.125 lux），避免等待后突然跳变。首次读数直接上报，释放传感器后重置状态。
定时器保证 SSC 仅在数值变化时发送一次事件，也能完成持续变化确认。

这会改变桌面 D-Bus 的 `LightLevel`；`ssccli --sensor light` 仍可读取未经过此
滤波的光感数据。参数旨在减少恒定照明下的忽明忽暗，实际环境变化需要稍等才能响应。

已有安装需提供 `iio-sensor-proxy-3.9.tar.gz` 重新构建才能启用补丁。只更新光感
代理、无需重装内核或重启机器：

```sh
sudo sh libexec/install-iio-sensor-proxy-ssc.sh /path/to/iio-sensor-proxy-3.9.tar.gz
```

代理重启后，当前 GNOME 会话可能仍保留旧连接，导致收到光感值但背光不再跟随。
在桌面用户的终端执行下列命令，重新连接电源服务（无需 sudo）：

```sh
systemctl --user restart org.gnome.SettingsDaemon.Power.target
```

## 回滚

```sh
sudo bash scripts/restore.sh kernel
sudo bash scripts/restore.sh all
```

`kernel` 只恢复原 UKI；`all` 同时移除 userspace 集成。SLPI registry/calibration
数据始终保留。`libexec/` 中的文件是内部实现，不是用户入口。
