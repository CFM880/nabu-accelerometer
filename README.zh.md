# nabu-accelerometer

[English](README.md) | **中文**

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

正常启动时 root PD 已经上线，因此不会等待；15 秒仅为异常超时。生产 UKI 由
`nabu-main` 统一构建，同时启用 Camera 与 Iris，只通过 cmdline 屏蔽 `venus_core`
（mainline Venus）；`qcom_iris` 正常加载，传感器与视频解码在统一生产内核上已验证
可以共存。仓库内遗留的独立 sensor UKI 构建/安装脚本（`scripts/build.sh`、
`libexec/*production-uki*` 等）会被 `nabu-main` 取代，仅作历史参考。

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
`nabu-main` 的 build 钩子（`scripts/nabu-build.sh` → `libexec/build-userspace.sh`）
在 `make build` 时把它们编译到 `out/userspace/root`，并给 iio-sensor-proxy 打上
`patches/0002-ssc-light-filter.patch` 与 `patches/0003-ssc-gyroscope-magnetometer.patch`。
生成的 `ssccli`、`libssc.so.2`、`iio-sensor-proxy-ssc` 以及生成的
`net.hadess.SensorProxy.conf` 在 manifest 的 `[artifacts]` 里声明，由 `nabu-main` 收集。
构建是交叉感知的：当内核工具链的目标与构建主机不同时，会自动生成 meson cross file。

`make install` 不再编译任何东西：`scripts/nabu-install.sh` 安装 SLPI 文件系统、
hexagonrpcd（发行版软件包）、**预编译好**的 libssc 与 iio-sensor-proxy，以及
tablet-mode helper，然后配置 systemd/udev。

## 验证

```sh
sudo bash scripts/verify.sh
sudo bash scripts/verify.sh 20   # 每种 SSC 传感器额外采样 20 秒
```

最终真机启动应满足：

- 四个 remoteproc 都为 `running`；
- `hexagonrpcd` 和 `iio-sensor-proxy` 为 active，`NRestarts=0`；
- D-Bus 返回 `HasAccelerometer=true`、`HasAmbientLight=true`、`HasCompass=true`、
  `HasGyroscope=true` 和 `HasMagnetometer=true`；
- 日志没有 SLPI crash、USER-PD watchdog、attach timeout 或 IOMMU fault。

桌面接口使用 LSM6DSO 加速度计、TCS3701 环境光传感器和基于 Qualcomm Rotation
Vector 的罗盘。LSM6DSO 陀螺仪和 AK0991x 原始磁力计另外通过独立的 D-Bus 接口导出：

```text
net.hadess.SensorProxy.Gyroscope    /net/hadess/SensorProxy/Gyroscope
net.hadess.SensorProxy.Magnetometer /net/hadess/SensorProxy/Magnetometer
```

各自提供 `HasGyroscope`/`HasMagnetometer`、`(ddd)` 类型的
`GyroscopeReadings`/`MagnetometerReadings`（分别为 rad/s 与 µT，取自固件原始值）
以及 `Claim`/`Release` 方法，复用与罗盘相同的 claim/引用计数模型。陀螺仪最高约
26 Hz，其 D-Bus 更新被合并为最多每 20 ms 一次。libssc CLI 仍可直接读取两者：

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

只更新光感代理、无需重装内核或重启机器：先构建，再安装预编译二进制：

```sh
sudo sh libexec/install-iio-sensor-proxy-ssc.sh \
  out/userspace/root/usr/local/libexec/iio-sensor-proxy \
  out/userspace/root/usr/local/share/dbus-1/system.d/net.hadess.SensorProxy.conf
```

代理重启后，当前 GNOME 会话可能仍保留旧连接，导致收到光感值但背光不再跟随。
在桌面用户的终端执行下列命令，重新连接电源服务（无需 sudo）：

```sh
systemctl --user restart org.gnome.SettingsDaemon.Power.target
```

### 固定曲线自动亮度（`nabu-autobrightness`）

GNOME 48 没有 lux→背光表：gsd 以“上次手动亮度”为基准做相对缩放，明暗大幅变化后
基准会漂移，亮度回不到之前的值；普通室内光照下也明显偏暗。

`nabu-autobrightness` 是随图形会话启动的用户服务里的小型 GIO 守护进程，用来恢复
Android 的行为：

- 自己 claim 环境光传感器（iio-sensor-proxy 只在有客户端 claim 时才打开它），并每
  30 秒重新 claim——挂起/唤醒后传感器恢复钩子会重启代理，claim 会丢；
- 用固定表把 `LightLevel` 映射为亮度，在 log(lux) 上插值：0 lux→8%、20→38%、
  50→50%、300→72%、3000+→100%；
- 通过 `org.gnome.SettingsDaemon.Power.Screen` 的 `Brightness` 生效，因此 OSD、
  滑块和持久化都正常；从面板实际亮度开始，以约 50%/s 过渡；
- 关闭 gsd 自带的自动亮度（`config/00-nabu-desktop` 里 `ambient-enabled=false`），
  否则两者会互相覆盖。

手动拖动滑块会被尊重：只有“会话刚刚有输入”（Mutter IdleMonitor 空闲时间 < 2 秒）时的
亮度变化才视为用户意图，并保留到曲线本身移动 5 个百分点（即光照确实变化）为止；
而无人操作时出现的变化（gsd 恢复旧值、其它客户端写背光）会被撤销并拉回曲线，
避免屏幕停在没人要的亮度上（每 2 秒校验一次，且只在没有过渡进行时校验：gsd 的
`Brightness` 在过渡中会滞后数十步，绝不能拿来当斜坡起点）。

`config/50-nabu-autobrightness.rules` 让这个用户服务能 claim 传感器：
iio-sensor-proxy 默认只允许“活跃会话”执行 `net.hadess.SensorProxy.claim-sensor`。

修改曲线只需改 `userspace/nabu-autobrightness.c` 里的表，再用
`libexec/install-autobrightness.sh` 重装（`make install` 也会做）；
unit 放在 `/etc/systemd/user/`，并软链接进 `graphical-session.target.wants`。

## 回滚

```sh
sudo bash scripts/restore.sh kernel
sudo bash scripts/restore.sh all
```

`kernel` 只恢复原 UKI；`all` 同时移除 userspace 集成。SLPI registry/calibration
数据始终保留。`libexec/` 中的文件是内部实现，不是用户入口。
