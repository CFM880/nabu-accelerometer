# Nabu 加速度计开发与调试记录

## 1. 目标与环境

- 设备：Xiaomi Pad 5，代号 `nabu`，SoC 为 Qualcomm SM8150。
- 传感器：ST LSM6DSO，加速度计与陀螺仪组合器件。
- 内核基线：`5181e1358ddd6ea8028e841d928942373e6aebc8`。
- 测试内核 release：`6.14.11-nabu-iris-camera1+`。
- 目标机：Xiaomi Pad 5（nabu）测试机。
- 调试日期：2026-09-03。

目标不是简单地让内核出现一个设备节点，而是在不造成 AP 总线访问硬锁的前提下，
让桌面通过标准 `net.hadess.SensorProxy` D-Bus API 获得方向数据，并验证重启后自动
恢复。

所有可能触发硬锁的启动都先在主机运行：

```sh
./scripts/capture-usb-console.sh /tmp/nabu-slpi-fastrpc-iova-v1-usb.log
```

测试 UKI 固定为 `EFI/ubuntu/nabu-accelerometer-test.efi`，不覆盖正常启动项；USB
CDC ACM 控制台使用 VID:PID `0525:a4a7`，脚本在重启断开后会自动重连。

## 2. 最初的错误方向：把 SSC bus 2 当成 AP QUP0

Android sensor JSON 给出的关键参数为：

- `bus_type = 1`，即 SPI；
- `bus_instance = 2`；
- chip select 0；
- 最大总线速率 9600 kHz；
- interrupt pin 132；
- orientation 为 `+x, +y, +z`。

最初把 `bus_instance = 2` 解释成 AP QUP0 SE2，即 `0x888000`。只在 DT 中启用节点
而不绑定驱动时可以启动；`spi-geni-qcom` 一旦完成 runtime PM、clock 和 interconnect
准备并进行第一次 SE 寄存器读取，整机立即硬锁。该实验同时说明：

1. 表面上的 CDSP timeout 是错误 MMIO 访问造成的次生现象；
2. 不能通过延时、assigned clock 或简单的 driver blacklist 修复；
3. 全局 blacklist `spi-geni-qcom` 还会误伤同一驱动承载的 Novatek 触摸屏。

因此所有 AP QUP0 方案均被永久封锁。

## 3. 找到真实硬件归属：SSC/SLPI

对照 Qualcomm downstream SM8150 DTS 后确认，Android 的 bus 2 属于 SSC/SLPI
命名空间：

- SSC QUPv3 wrapper：`0x26c0000`；
- SSC SE2：`0x2688000`；
- Sensor Clock Controller：`0x2b10000`；
- SLPI GPIO6–9；
- sensor rail 通过固件依赖映射到 PM8150 LDO17。

随后把测试拆成多个只做一件事的 profile，以确定 AP 能安全访问到哪一层：

| Profile | 操作 | 真机结果 |
| --- | --- | --- |
| `ssc-map-only` | LCX resume，加上映射，不读寄存器 | 通过 |
| `ssc-empty-provider` | 注册零时钟 provider | 通过 |
| `ssc-powered-empty-provider` | runtime PM 下注册零时钟 provider | 通过 |
| `ssc-powered-main-rcg` | 只注册 main RCG | 第一次 SCC MMIO read 硬锁 |
| `ssc-provider` | 同步进入真实 `qcom_cc_probe()` | 加载后无返回，硬锁 |
| `ssc-controller-runtime` | SCC + controller runtime | 硬锁 |

`ssc-provider` 的 USB 日志显示系统已进入 userspace，并在约 127.174 秒加载私有模块；
provider 成功标记没有出现，USB 仍连接但不再有任何输出，SSH 也不恢复。随后
`ssc-powered-main-rcg` 又把边界缩小到第一次 clock core `recalc_rate` 读取。

结论：LCX、映射和 provider 框架本身没有问题；AP 不能直接访问 SSC 的 clock/SE
资源。Android 板级 DTS 也保持 `clock_scc` disabled。该资源由 hypervisor/SLPI
固件拥有，正确实现必须使用 SLPI Sensor Core，而不是主线 LSM6DSO SPI 直驱。

## 4. 转向 SLPI boot-only

安全 DT profile 只修改现有 `remoteproc_slpi`：

```dts
&remoteproc_slpi {
    firmware-name = "qcom/sm8150/xiaomi/nabu/slpi_nb.mbn";
    status = "okay";
};
```

它不创建 AP SCC 或 SSC QUP 设备。首次启动完成 PAS authentication、GLINK 和三个
FastRPC compute context 枚举，但 `sensor_process` 每约 40 秒触发 user-PD watchdog，
remoteproc 随后恢复。

先后补充了：

- `/lib/firmware/qcom/sm8150/xiaomi/nabu/sensors` 到全局 HexagonFS 的只读映射；
- `socinfo` 映射；
- `/var/lib/tqftpserv/sensors/registry` 可写目录；
- Ubuntu `hexagonrpcd 0.4.0-1`；
- Nabu systemd override，强制使用 `/dev/fastrpc-sdsp`、DSP `sdsp`、sensors-PD
  attach 和 `/lib/firmware/hexagonfs`。

文件映射本身没有改变 40 秒 watchdog；启动 FastRPC reverse listener 后，初始化
向前推进并暴露出真正的内核错误。

## 5. FastRPC 高 IOVA 根因与修复

第一次 `hexagonrpcd` attach 的关键错误为：

```text
iova=0x1fffff000
SID=0x5a1
Unhandled context fault
```

主线 FastRPC 先通过 DMA API 建立低 32 位 IOVA 映射，然后只在发给 DSP 的地址上加
`sid << 32`。SM8150 SDSP 因此访问高地址 `0x1fffff000`，但 IOMMU domain 中只有对应
的低地址映射，最终 context fault，sensors-PD 再次 watchdog。

项目补丁 `patches/0001-fastrpc-sm8150-sdsp-high-iova.patch` 做了以下修改：

1. 只对 `domain_id == SDSP_DOMAIN_ID` 且 machine compatible 为 `qcom,sm8150` 的
   channel 启用 workaround，避免影响 ADSP/CDSP 和其他 SoC；
2. 保留 DMA API 建立的低 IOVA；
3. 用 `iommu_iova_to_phys()` 逐页解析原映射；
4. 在同一 domain 的 `low_iova + (sid << 32)` 位置逐页调用 `iommu_map()`；
5. 把高 alias 地址发送给 DSP；
6. 在 `fastrpc_buf_free()` 中先 `iommu_unmap()` alias，再释放原 DMA buffer；
7. 映射失败时回滚已映射页，并返回错误，不留下半映射状态。

DT 同时给 SLPI 的三个 FastRPC compute context bank 添加 `dma-coherent`，使 alias
映射带上正确的 `IOMMU_CACHE` 属性。启动日志中的确认标记是：

```text
enabling SM8150 SDSP high-IOVA workaround
```

修复后第一次启动的 boot ID 为
`e0355edf-dcae-41c4-9906-958f20cb7344`。SLPI 与 `hexagonrpcd` 连续稳定超过 20
分钟，以下错误计数保持为 0：

- `crash detected in slpi`；
- `Unhandled context fault`；
- `USER-PD DOG`。

## 6. SSC 数据验证

Ubuntu 26.04 仓库没有 `libssc` 包，因此固定使用上游 `libssc 0.4.4`：

```text
archive: libssc-v0.4.4.tar.gz
SHA256: 716d6bd6b34d2d753060c6b54c9a87e34fae75b724c763bf9ef487efa3621587
```

`ssccli` 成功完成：

1. 找到 QRTR node 9 上的 SSC QMI service；
2. 找到 `registry` service；
3. 解析 `accel` SUID；
4. 打开 continuous stream；
5. 连续 20 秒输出约 25 Hz 三轴样本；
6. 正常发送 disable request 并释放 client。

静止倾斜状态下的代表样本为：

```text
X=-7.575850 Y=-0.484802 Z=6.325287 m/s²
```

三轴合加速度接近重力加速度，且旋转设备时数值随姿态变化。采样后 SLPI 错误计数
仍为 0。

## 7. 桌面集成

Ubuntu 的 `iio-sensor-proxy 3.8` 不包含 SSC backend。上游 3.9 首次加入 libssc
driver，但默认只为 SSC light/compass 添加 udev 类型，加速度计仍是实验性 opt-in。

本项目采用不覆盖发行版文件的方式：

- `/usr/local/libexec/iio-sensor-proxy-ssc`：从固定的 3.9 源码构建，并链接
  `libssc.so.2`；
- `/etc/systemd/system/iio-sensor-proxy.service.d/nabu-ssc.conf`：切换 ExecStart，
  增加 `AF_QIPCRTR`，并排序在 `hexagonrpcd` 之后；
- `/etc/udev/rules.d/90-nabu-ssc-accelerometer.rules`：只给
  `fastrpc-sdsp*` 增加 `ssc-accel`，并应用 vendor registry 的 identity matrix。

初次从 SSH 执行 `monitor-sensor` 得到 `Not Authorized`。这不是驱动错误，而是
polkit 的 `claim-sensor` policy 只允许 active local session。测试脚本现在会在已有
本地图形登录时通过临时 systemd user unit 重试。

最终测试实际观察到：

```text
Has accelerometer (orientation: right-up, tilt: tilted-up)
Accelerometer orientation changed: bottom-up
Tilt changed: vertical
Accelerometer orientation changed: right-up
```

因此数据已经从 LSM6DSO 经 SSC firmware、QRTR/QMI、libssc 到达桌面 D-Bus API。

## 8. 重启持久化验证

第二次验证 boot ID 为 `20bba3d7-223d-4095-a5d7-5516857e71bf`。冷启动后自动满足：

- FastRPC workaround 标记出现；
- `hexagonrpcd.service` active；
- `iio-sensor-proxy.service` active，ExecStart 指向 `/usr/local` SSC 版；
- udev 属性为 `IIO_SENSOR_PROXY_TYPE=ssc-accel`；
- system D-Bus 为 `HasAccelerometer=true`；
- SLPI/IOMMU/watchdog 错误计数为 0；
- USB console 跨重启完整重连。

至此测试 UKI 路径的功能与稳定性验证完成。

## 9. GNOME 自动旋转测试暴露的 Iris 卡死

启用 GNOME 自动旋转后的一次重启在图形会话初始化期间再次硬锁。此次提前运行的
`capture-usb-console.sh` 保留了完整故障现场：SLPI 在 `123.912s` 正常启动，FastRPC
在 `124.558s` 启用 SM8150 SDSP 高 IOVA workaround，没有出现 sensors-PD watchdog、
IOMMU context fault 或加速度计错误。真正的最后执行路径来自发行版的
`qcom-iris-autoload.service`、`v4l_id` 和 `gst-plugin-scan` 并发打开视频节点：

```text
video_cc_mvs0_core_clk status stuck at 'off'
iris_prepare_enable_clock
iris_vpu_power_on_hw
iris_core_init
iris_open
v4l2_open
```

`qcom_iris` 随后不断重新分配 HFI queue 并重试上电，USB 输出停止于 `147.504s`，
SSH 也无法连接。原有 `modprobe.blacklist=qcom_iris` 只能阻止基于 alias 的自动加载，
不能阻止 systemd 服务显式执行 modprobe。为隔离这项工作树中尚未稳定的视频驱动，
所有诊断和生产 cmdline 额外加入内核级：

```text
module_blacklist=venus_core,qcom_iris
```

该参数由内核模块加载器强制执行，即使服务显式请求也会拒绝载入。这次卡死与屏幕
旋转动作没有因果关系；动作发生在用户看到桌面时，而根因是登录期间的多媒体插件
扫描并发打开 Iris V4L2 设备。

修正版测试 UKI 的 SHA256 为
`96ad6411f7eda9ea649863144cf4bcd3c53b435997baa2d6f0827d79034753cb`。
真机重启 boot ID `a98a6533-9684-4a1f-911c-7c29916a6182` 验证结果：

- `/proc/cmdline` 同时包含 modprobe 和内核级 module blacklist；
- `qcom_iris` 不在 `/proc/modules` 中；
- `qcom-iris-autoload.service` 的显式 modprobe 被内核以
  `Operation not permitted` 拒绝；
- SLPI、modem、CDSP、ADSP 全部为 running；
- `hexagonrpcd` 和 `iio-sensor-proxy` active；
- Iris power、IOMMU context fault 和 sensors-PD watchdog 错误计数为 0。

活动图形会话中的 20 秒测试收到：

```text
Accelerometer orientation changed: bottom-up
Accelerometer orientation changed: left-up
```

GNOME 的 `orientation-lock=false`，但用户现场确认桌面没有跟随旋转。进一步同步采样
发现 SensorProxy 在测试程序退出后停留于缓存的 `left-up`，而内置 `DSI-1` 的逻辑
显示 transform 始终为 `3`；因此该 transform 是原有固定面板方向，不能作为自动旋转
成功的证据。

Mutter 50 上游 `update_panel_orientation_managed()` 要求以下三个条件同时成立：

```text
clutter_seat_get_touch_mode(seat)
meta_orientation_manager_has_accelerometer(orientation_manager)
meta_monitor_manager_get_builtin_monitor(manager)
```

真机 D-Bus 读数为 `PanelOrientationManaged=false`。用户确认没有连接磁吸键盘盖，
但专用的第二路 USB host 仍在每次启动时枚举固定 VID:PID `3206:3ffc`，并创建：

```text
Xiaomi Pad Keyboard  ID_INPUT_KEYBOARD=1
Xiaomi Pad Mouse     ID_INPUT_MOUSE=1
Xiaomi Pad           ID_INPUT_TOUCHPAD=1
```

把 `/sys/bus/usb/devices/1-1/authorized` 临时设为 0 后，这三个 input 节点全部消失；
重新登录时 GNOME Shell 也正确打开了 `NVTCapacitiveTouchScreen` 的 `event3`，但
`PanelOrientationManaged` 仍为 false。Mutter 的 touch-mode 实现没有 tablet-mode
switch 时会以 `!has_pointer` 推断状态；Nabu 没有向 Linux 提供真实的
`SW_TABLET_MODE`，仅靠枚举/移除键盘控制器不能形成可靠的产品状态。

项目因此增加 `nabu-tablet-mode` 小型 uinput helper，以固定的
`SW_TABLET_MODE=ON` 明确表达本机当前是纯平板形态。它不读取传感器，也不直接修改
显示配置；Mutter 仍负责 claim SensorProxy、方向策略以及 KMS transform。对应的
systemd 服务在 display manager 前启动，可通过 `remove-tablet-mode.sh` 完整回滚。

首次真机安装后验证：

```text
nabu-tablet-mode.service: enabled, active
Nabu Tablet Mode Switch: SW_TABLET_MODE=ON
PanelOrientationManaged: true
```

随后 20 秒同步采样证明 SensorProxy 方向与 Mutter 的内置显示 transform 同步变化：

```text
right-up  transform=3
bottom-up transform=2
right-up  transform=3
normal    transform=0
left-up   transform=1
bottom-up transform=2
```

至此 GNOME 自动旋转的数据和显示两端均已验证。现场照片随后显示：平板处于正常
竖放姿态时，GNOME 已切换为竖屏，但整个画面上下颠倒；同时 SensorProxy 报告
`bottom-up`。这把剩余问题限定为固定 180 度坐标偏差，而不是 GNOME policy 或
tablet-mode 状态错误。

原始 udev 规则照搬 vendor registry 的 identity orientation。但该矩阵描述 SSC
传感器坐标约定，不能直接补偿 Linux 内置面板的机身方向。修正规则改用：

```text
-1,0,0;0,-1,0;0,0,1
```

即同时反转 X/Y、保留 Z，相当于绕屏幕法线旋转 180 度。专用
`install-orientation-matrix.sh` 只接受项目早期 identity 规则的已知 SHA256 或已经
修正的规则，然后 reload udev 并重启 SensorProxy；不修改内核、UKI 或启动项。

矩阵安装后的活动用户采样把同一竖放姿态从 `bottom-up` 修正为 `normal`，证明矩阵
本身正确。但完整重启暴露了 Mutter 原生竖屏初始化的时序边界：早期 helper 在
display manager 之前就固定上报 `SW_TABLET_MODE=ON`；Mutter 收到首次方向后进入
`handle_initial_orientation_change()`，该路径会再次 inhibit tracking，而
`PanelOrientationManaged` 此时已经是 true，不会发生 false→true 状态转换来解除
inhibit。结果 SensorProxy 保持 `undefined`，显示沿用启动瞬间的 transform。

最终 helper 因此在创建设备时先上报 `OFF`，监测普通用户的 `gnome-shell` 进程，
并明确忽略登录界面的 `gnome-shell --mode=gdm`（GDM 在本机使用的动态 UID 也大于
1000）。真正的用户 Shell 连续存在五秒后才上报 `ON`。这样首次方向事件先走完并
inhibit，随后 tablet-mode 的 false→true 转换调用 `uninhibit_tracking()`，SSC
数据流转为持续模式；GNOME Shell 退出时 helper 回到 `OFF`，覆盖重新登录场景。
仍需安装该时序修正版并做四方向及再次重启验证。

完整 USB 现场保存在构建机：

```text
/tmp/nabu-gnome-autorotate-hang-20260903.log
```

## 10. 其他已知但无关的日志

- `hexagonrpcd` 启动时尝试以写模式打开 `temp.json`。上游 daemon 的 virtual FS
  当前只支持只读打开；这些日志只在启动时出现，没有循环占用 CPU，也没有再触发
  watchdog。
- SSC firmware 返回的 mount-matrix attribute 全 0，`libssc` 会回退到 identity；
  Nabu udev rule 在首次验证时也指定 vendor JSON 中的 identity orientation。现场
  画面证明 Linux 面板坐标仍差 180 度，因此最终规则使用 `diag(-1,-1,1)` 校正。
- 更早 USB 日志中的 `qcom_iris` video clock warning 来自工作树原有的相机/Iris
  开发。本项目没有修改 Iris 源码，但现在通过 UKI cmdline 强制隔离该模块，避免它
  干扰加速度计的稳定性验证。

## 11. 生产推广与回滚

生产 UKI 使用与通过测试完全相同的 `Image` 和 SLPI DTB，但恢复原默认 cmdline，
去掉 `ttyGS0`、`loglevel=8` 等 USB 调试参数，并保留内核级 Iris/Venus 黑名单。
安装器只原子替换既有默认文件
`EFI/ubuntu/6.14.11-nabu-iris-camera1+-build1.efi`，并要求它的 SHA256 与已知原始
镜像一致。

最终生产 UKI 为：

```text
nabu-accelerometer-production.efi
SHA256: 04b6a1418e1f503969786ff32536119081e87b624fb5125cb86e452b84a7dbf0
```

重新提取校验表明其中 `.linux` section 与已验证 Image 的 SHA256
`c641ef8f...` 完全相同，`.dtb` section 与已验证 SLPI DTB 的 SHA256
`5eb25653...` 完全相同。

替换前，原 UKI 会备份到：

```text
/var/lib/nabu-accelerometer/6.14.11-nabu-iris-camera1+-build1.efi.pre-accelerometer
```

`restore-production-uki.sh` 只接受该校验通过的备份，并拒绝覆盖未知 UKI。测试入口
`nabu-accelerometer-test.efi` 始终保留，可用于恢复或继续抓取 USB 日志。

## 11. 关键文件

- `patches/0001-fastrpc-sm8150-sdsp-high-iova.patch`：FastRPC 根因修复；
- `kernel-overlay/.../sm8150-xiaomi-nabu-accelerometer-slpi-boot-only.dtsi`：SLPI
  firmware 与 coherent compute context；
- `scripts/capture-usb-console.sh`：跨重启 USB 日志；
- `scripts/install-slpi-filesystem.sh`：HexagonFS 映射；
- `scripts/install-hexagonrpcd.sh`：SDSP reverse listener；
- `scripts/install-libssc.sh`、`test-libssc-accelerometer.sh`：SSC 原始数据；
- `scripts/install-iio-sensor-proxy-ssc.sh`：桌面集成；
- `scripts/build-production-uki.sh`、`install-production-uki.sh`：默认启动推广；
- `scripts/restore-production-uki.sh`：默认 UKI 回滚。

## 12. 外部依据

- libssc 文档：<https://libssc.dylanvanassche.be/docs/>
- libssc 源码：<https://codeberg.org/DylanVanAssche/libssc>
- iio-sensor-proxy：<https://gitlab.freedesktop.org/hadess/iio-sensor-proxy>
- Linux-MSM hexagonrpc：<https://github.com/linux-msm/hexagonrpc>
- Qualcomm FastRPC daemon 文档：
  <https://github.com/qualcomm/fastrpc/blob/development/Docs/daemons.md>
