# nabu-accelerometer

Xiaomi Pad 5（nabu、SM8150）板载 LSM6DSO 的 Linux IIO 直驱项目。

Android 的 `bus_instance = 2` 属于 SSC/SLPI 命名空间，对应 SSC QUPv3
SE2（`0x2688000`）和 SLPI GPIO6–9，并不是 AP QUP0 的 `0x888000`。
此前真机测试已证明访问错误的 AP SE2 会锁死系统，因此相关测试版本均已删除。

2026-09-03 的 runtime 和 provider-only 真机启动都发生了硬锁。USB console
进一步确认 provider-only 能进入 systemd，并在 `127.174s` 加载
`nabu_sm8150_ssc`；之后没有 provider 成功日志、panic 或 oops，USB 连接保持但
不再输出，SSH 也未恢复。该版本没有 assigned rate、clock vote 或 SPI consumer，
所以故障已缩小到 `qcom_cc_probe()` 内的映射/clock 注册路径。

`ssc-map-only`、`ssc-empty-provider` 和 `ssc-powered-empty-provider` 真机测试都已
通过：LCX resume/put、映射和空 provider 注册均正常。但随后只注册 main RCG 的
测试仍在第一次 SCC MMIO read 时硬锁，证明问题不是缺少 runtime-PM，而是 AP
无法直接访问该 SSC 资源。Android DTS 中 `clock_scc` 默认 disabled，nabu 也没有
启用它；板载传感器由 SLPI 固件拥有。所有 SCC MMIO profile 已封锁。目标机现有
`qcom/sm8150/xiaomi/nabu/slpi_nb.mbn`，默认构建现已改为 `slpi-boot-only`：只通过
主线 PAS remoteproc 启动 SLPI，不创建 AP 侧 SCC 或 SSC QUP 设备。安全的
powered-empty-provider 仅保留为已验证边界；SLPI 启动通过后再实现 SNS 消息通道。

## 源码布局

```text
driver/
  scc-provider.c       安全的 powered zero-clock fallback
  runtime-test.c       已冻结的下一阶段（三个 SSC 时钟，不访问 SE MMIO）
  module.c             两个私有 platform driver 的模块入口
  Makefile             外置模块 Kbuild
kernel-overlay/
  arch/.../*.dts[i]    SLPI boot-only、安全 fallback 及已封锁的 MMIO 诊断 DTS
  include/...          私有 SCC clock ID
patches/               基于固定内核提交的 FastRPC SM8150 SDSP 修复
config/                内核 fragment、cmdline 和 UKI SBAT
scripts/               覆盖、编译、打包、安装和检查脚本
userspace/              向 Mutter 提供 Nabu 平板形态的 uinput helper
```

项目不修改内核的 Kconfig、Makefile 或 `spi-geni-qcom.c`。SCC fallback 编译为独立
的 `nabu-sm8150-ssc.ko`；唯一修改主线已有源码的部分是精确绑定内核基线的 FastRPC
补丁，`apply-overlay.sh` 会拒绝覆盖未知的本地 FastRPC 改动。

## 构建

先把新增的 DTS 和 binding 头文件复制到精确内核基线：

```sh
./scripts/apply-overlay.sh ../linux
```

构建私有模块、未修改的上游 SPI 模块和 `slpi-boot-only` 组合 DTB：

```sh
./scripts/build.sh \
  ../linux \
  ../.nabu-shared-build.mN6hC8/out
```

生成固定名称的测试 UKI：

```sh
./scripts/build-test-uki.sh \
  ../linux \
  ../.nabu-shared-build.mN6hC8/out \
  ../.nabu-shared-build.mN6hC8/nabu-accelerometer-test.efi
```

在 x86_64 构建机上需提供 ARM64 systemd-stub；可从目标机同版本 systemd 包复制，
然后显式传入，避免误用宿主架构的 stub：

```sh
UKI_STUB=../.nabu-shared-build.mN6hC8/linuxaa64.efi.stub \
  ./scripts/build-test-uki.sh \
  ../linux ../.nabu-shared-build.mN6hC8/out \
  ../.nabu-shared-build.mN6hC8/nabu-accelerometer-test.efi
```

真机验证完成后，以相同 Image/DTB 和原默认 cmdline 生成生产 UKI：

```sh
UKI_STUB=../.nabu-shared-build.mN6hC8/linuxaa64.efi.stub \
  ./scripts/build-production-uki.sh \
  ../linux ../.nabu-shared-build.mN6hC8/out \
  ../.nabu-shared-build.mN6hC8/nabu-accelerometer-production.efi
```

测试 UKI 内建 CDC ACM gadget，并把 `ttyGS0` 设为内核控制台。它不会依赖
userspace ConfigFS，因此 USB 设备控制器就绪后，主机侧会出现 VID:PID
`0525:a4a7` 的 `/dev/ttyACM*`。cmdline 把 `tty0` 放在最后，使其成为 userspace
主控制台；未连接 USB 主机时启动不会被 `ttyGS0` 的发送缓冲区阻塞。USB console
仍会接收内核日志，连接主机不是启动测试 UKI 的前置条件。

默认测试和生产 UKI 同时使用 `module_blacklist=venus_core,qcom_iris`。目标系统的
`qcom-iris-autoload.service` 会显式加载模块，单独使用 `modprobe.blacklist` 无法
阻止它；当前 Iris 开发驱动在 GNOME 登录时被 `v4l_id`/`gst-plugin-scan` 并发打开
会卡在 `video_cc_mvs0_core_clk`。内核级 blacklist 用于将该问题与传感器验证隔离。

需要同时验证 Camera 和 Iris 时可显式构建高风险测试 profile。Camera DTB/CAMSS 在
默认测试 UKI 中已经启用；该开关只移除 Iris/Venus blacklist。Iris 曾在桌面登录时
造成整机硬锁，因此应先运行 USB console 捕获，并保留原默认启动项用于恢复：

```sh
ENABLE_IRIS=1 UKI_STUB=../.nabu-shared-build.mN6hC8/linuxaa64.efi.stub \
  ./scripts/build-test-uki.sh \
  ../linux ../.nabu-shared-build.mN6hC8/out \
  ../.nabu-shared-build.mN6hC8/nabu-accelerometer-test.efi
```

安装 Iris-enabled profile 时，`install-test-uki.sh` 要求第六个参数为同一构建的
`qcom-iris.ko`；第五个参数始终是带 Nabu SLPI 映射的 `qcom_pd_mapper.ko`。

## 安装

安装脚本原子替换同一个测试 UKI，同时保留安全的私有 SSC fallback 模块，并确保
`spi-geni-qcom.ko` 是当前源码编出的未修改版本、`fastrpc.ko` 带有 SM8150 SDSP
高 IOVA 修复和 SLPI root-PD PDR 启动门控。SLPI DTB 没有 SCC compatible，所以私有模块不会绑定：

```sh
sudo ./scripts/install-test-uki.sh \
  ../.nabu-shared-build.mN6hC8/nabu-accelerometer-test.efi \
  ../.nabu-shared-build.mN6hC8/out/nabu-accelerometer-driver/nabu-sm8150-ssc.ko \
  ../.nabu-shared-build.mN6hC8/out/drivers/spi/spi-geni-qcom.ko \
  ../.nabu-shared-build.mN6hC8/out/drivers/misc/fastrpc.ko \
  ../.nabu-shared-build.mN6hC8/out/drivers/soc/qcom/qcom_pd_mapper.ko
```

默认 UKI 不会修改。测试项仍固定为 `nabu-accelerometer-test.efi`，不会增加编号版本。

完成稳定性、原始采样、桌面方向和冷启动验证后，可把生产 UKI 原子替换到现有默认
路径。Nabu 的 `/dev/disk/by-partlabel/esp` 解析为第 31 分区 `/dev/sda31`，默认 UKI
位于其中的 `EFI/ubuntu/6.14.11-nabu-iris-camera1+-build1.efi`。脚本只接受已知原默认
UKI 的 SHA256，并先在 `/var/lib/nabu-accelerometer` 保存可恢复备份：

```sh
sudo ./scripts/install-production-uki.sh \
  ../.nabu-shared-build.mN6hC8/nabu-accelerometer-production.efi \
  ../.nabu-shared-build.mN6hC8/out/nabu-accelerometer-driver/nabu-sm8150-ssc.ko \
  ../.nabu-shared-build.mN6hC8/out/drivers/spi/spi-geni-qcom.ko \
  ../.nabu-shared-build.mN6hC8/out/drivers/misc/fastrpc.ko \
  ../.nabu-shared-build.mN6hC8/out/drivers/soc/qcom/qcom_pd_mapper.ko
```

也可以使用统一安装入口，同时更新生产 UKI、模块和 `hexagonrpcd` 的事件驱动配置：

```sh
sudo ./scripts/install-production-system.sh \
  ../.nabu-shared-build.mN6hC8/nabu-accelerometer-production.efi \
  ../.nabu-shared-build.mN6hC8/out/nabu-accelerometer-driver/nabu-sm8150-ssc.ko \
  ../.nabu-shared-build.mN6hC8/out/drivers/spi/spi-geni-qcom.ko \
  ../.nabu-shared-build.mN6hC8/out/drivers/misc/fastrpc.ko \
  ../.nabu-shared-build.mN6hC8/out/drivers/soc/qcom/qcom_pd_mapper.ko
```

如需恢复原默认 UKI：

```sh
sudo ./scripts/restore-production-uki.sh
```

## 抓取卡死日志

在另一台 Linux 主机连接 nabu 的 USB-C 口，先运行：

```sh
./scripts/capture-usb-console.sh nabu-ssc-hang.log
```

保持脚本运行，再启动 nabu 的 accelerometer 测试项。脚本会识别
`0525:a4a7`、跨重启自动重连，并持续追加日志。如果普通用户无权读取
`/dev/ttyACM*`，可把用户加入主机的 `dialout` 组，或临时用 `sudo` 运行。

USB gadget console 需要 USB 中断和内核 workqueue 才能发送数据。若 SSC
访问导致互连/SoC 硬锁，通常只能得到锁死前的最后若干行，不能保证产生
Call trace。板载 ramoops/pstore 仍同时保留，恢复启动后也应检查：

```sh
sudo ls -l /sys/fs/pstore
sudo grep -R . /sys/fs/pstore
journalctl -b -1 -k --no-pager
```

## SLPI 实现与验证

DTB 只给现有的 `remoteproc_slpi` 节点设置：

```dts
firmware-name = "qcom/sm8150/xiaomi/nabu/slpi_nb.mbn";
status = "okay";
```

预期出现第四个 remoteproc，名称为 `slpi`、状态为 `running`，内核日志包含
`remote processor slpi is now up`。本阶段不应出现 `nabu-sm8150-scc` 日志，也不会
直接访问 SCC/SSC 寄存器。需要保留完整诊断日志时，仍应在启动前运行
`capture-usb-console.sh`；不抓日志时可不连接 USB，系统会继续正常启动。

SLPI 首次真机启动已证明 PAS、GLINK 和 FastRPC 枚举正常，但 `sensor_process`
每约 40 秒因初始化看门狗崩溃并由 remoteproc 自动恢复。`tqftpserv` 会相对于
remoteproc 固件目录查找 `/readonly/firmware/image/` 下的文件，而提取出的 Nabu
传感器文件位于全局 `hexagonfs` 目录。下一阶段用独立脚本建立只读映射，并准备
嵌套的可写 registry 目录：

```sh
sudo ./scripts/install-slpi-filesystem.sh
```

脚本不会替换固件或 UKI；对应的 `remove-slpi-filesystem.sh` 只删除它创建的两个
符号链接，并保留可能由固件写入的 registry/calibration 数据。

文件映射测试后，SLPI 仍每约 40 秒报 `sensor_process` 初始化 watchdog；同时
`tqftpserv` 没有收到任何文件请求。Nabu 的 sensors PD 还需要 FastRPC 反向隧道，
由 AP 侧为 DSP 提供 `apps_std` 文件访问。Ubuntu 的 `hexagonrpcd` 默认不会把
SM8150 识别为 SDSP，因此使用独立脚本安装软件包并加上 Nabu 专用 systemd override：

```sh
sudo ./scripts/install-hexagonrpcd.sh
```

该配置把 daemon 连接到 `/dev/fastrpc-sdsp`，以 sensors-PD 模式运行，并把已有的
`/lib/firmware/hexagonfs` 作为根目录。内核在首次 FastRPC attach 时等待 SLPI
root-PD 的 PDR 通知，正常情况下立即继续，15 秒只作为异常超时。该配置不修改
内核、UKI 或 SLPI 固件。需要回滚时：

```sh
sudo ./scripts/remove-hexagonrpcd-nabu-config.sh
```

回滚脚本停止并禁用服务，只移除它创建的 override，保留软件包和 registry 数据。

首次 FastRPC attach 暴露了 SM8150 SDSP 特有的 IOVA 问题：DSP 使用 `SID << 32`
的高地址，而主线驱动只建立了低 32 位 IOMMU 映射，导致 `iova=0x1fffff000`
context fault 并再次触发 sensors-PD watchdog。测试内核现在为 SDSP compute context
建立对应的高 IOVA alias，并给三个 context bank 标记 `dma-coherent`。修复后的真机
启动持续运行超过五分钟，`hexagonrpcd` 保持 active，没有再次出现 SLPI crash、
IOMMU fault 或 watchdog。

下一步不再访问 SSC 的 MMIO，而通过 SSC QMI 服务读取传感器。使用固定源码校验和
安装 `libssc 0.4.4`：

```sh
sudo ./scripts/install-libssc.sh ./libssc-v0.4.4.tar.gz
./scripts/test-libssc-accelerometer.sh 20
```

测试时移动或旋转平板；成功时 `ssccli` 会连续输出三轴加速度。这个阶段先验证真实
SSC 数据通路，之后再把同一接口接入桌面方向传感器；目标机现有
`iio-sensor-proxy` 的 systemd sandbox 尚未允许 `AF_QIPCRTR`，不能把它的现状误判
成 SSC 硬件不可用。

Ubuntu 26.04 的 `iio-sensor-proxy 3.8` 尚未包含 SSC backend。项目提供独立安装脚本，
从固定校验和的上游 3.9 源码构建 SSC 版二进制，不覆盖发行版程序；systemd drop-in
只把服务切到 `/usr/local/libexec/iio-sensor-proxy-ssc` 并允许 `AF_QIPCRTR`，Nabu
专用 udev rule 则为 `fastrpc-sdsp` 显式启用实验性的 `ssc-accel`：

```sh
sudo ./scripts/install-iio-sensor-proxy-ssc.sh \
  ./iio-sensor-proxy-3.9.tar.gz
./scripts/test-iio-sensor-proxy-ssc.sh 20
```

真机安装后 system D-Bus 返回 `HasAccelerometer=true`。默认 polkit policy 只允许
active 本地 session claim 传感器，因此 SSH 中运行 `monitor-sensor` 会得到
`Not Authorized`；测试脚本会在已有本地图形登录时通过临时 user unit 自动重试。
真机方向测试实际报告了 `right-up` → `bottom-up` → `right-up` 和多次 tilt 变化，
确认桌面层连续消费 SSC 加速度数据。重启后服务、udev 标记、FastRPC workaround
和 `HasAccelerometer=true` 也全部自动恢复。

Nabu 原厂 registry 的 identity matrix 是传感器坐标约定，不足以直接匹配 Linux
桌面的面板方向。`install-iio-sensor-proxy-ssc.sh` 会直接安装经过真机验证的
`diag(-1,-1,1)` mount matrix，同时反转 X/Y，修正画面固定上下颠倒的问题。

需要回滚桌面集成时：

```sh
sudo ./scripts/remove-iio-sensor-proxy-ssc.sh
```

Nabu 的第二路 USB host 即使没有连接磁吸键盘盖，也会枚举 `3206:3ffc` 并创建
keyboard/mouse/touchpad 输入节点；同时平台没有提供 `SW_TABLET_MODE`。Mutter 因此
保持 `PanelOrientationManaged=false`，虽然 SensorProxy 方向会变化，桌面却不会
旋转。构建并安装明确的 tablet-mode switch：

```sh
./scripts/build-tablet-mode.sh ./nabu-tablet-mode
sudo ./scripts/install-tablet-mode.sh ./nabu-tablet-mode
```

helper 只通过 uinput 上报 tablet-mode switch，不读取传感器、不直接操作显示器。
它启动时先保持 `OFF`，忽略登录界面的 `gnome-shell --mode=gdm`，检测到普通用户的
GNOME Shell 后等待五秒再切换为 `ON`；这样 Mutter 会先完成原生竖屏面板的首次方向
处理，再进入持续自动旋转状态。用户 GNOME Shell 退出时 helper 会回到 `OFF`，所以
重新登录也保持相同顺序。
GNOME/Mutter 仍负责自动旋转。需要回到硬件推断模式时：

```sh
sudo ./scripts/remove-tablet-mode.sh
```

## 安全 fallback 的预期日志

```text
nabu-sm8150-scc 2b10000.clock-controller: powered-empty-provider probe entered; no SCC MMIO access performed
nabu-sm8150-scc 2b10000.clock-controller: resuming SCC LCX power domain
nabu-sm8150-scc 2b10000.clock-controller: SCC LCX power domain resumed; no SCC MMIO access performed
nabu-sm8150-scc 2b10000.clock-controller: mapped SCC register window; registering zero-clock provider
nabu-sm8150-scc 2b10000.clock-controller: registered powered zero-clock SCC provider; clock hardware and MMIO access intentionally skipped
```

该 fallback 不提供 clock，也没有 runtime-test 或 IIO 设备。它只用于保留已验证的
安全边界。`ssc-powered-main-rcg`、旧 full-provider/runtime 和所有 AP QUP0 方案均
已禁止；不能再通过 DT 直连 SSC SE2。当前先验证 SLPI 启动，之后实现传感器消息通道。
硬件依据和阶段边界见 [SOURCE.md](SOURCE.md)。

完整的失败路径、硬锁定位、FastRPC 根因、补丁设计、真机日志证据和最终方向测试见
[DEVELOPMENT.md](DEVELOPMENT.md)。
