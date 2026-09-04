# Nabu accelerometer final implementation

## Hardware ownership

Nabu 的 LSM6DSO 位于 SSC serial engine 2，由 SLPI 固件拥有。最终实现不创建 AP-side
SCC clock provider，也不让 `spi-geni-qcom` 访问 SSC MMIO。

设备树只启用已有的 `remoteproc_slpi`，指定 Nabu SLPI firmware，并给三个 FastRPC
compute context bank 标记 `dma-coherent`：

```dts
&remoteproc_slpi {
    firmware-name = "qcom/sm8150/xiaomi/nabu/slpi_nb.mbn";
    status = "okay";

    glink-edge {
        fastrpc {
            qcom,protection-domain = "tms/servreg", "msm/slpi/root_pd";
        };
    };
};
```

## FastRPC fixes

SM8150 SDSP 把 context-bank SID 放入 DSP 地址高位。补丁为 FastRPC DMA buffer 建立相应
的高 IOVA alias，并在释放 buffer 时撤销映射。

同一补丁为 SM8150 PD mapper 增加 `msm/slpi/root_pd` 和
`msm/slpi/sensor_pd`。FastRPC 订阅 root-PD 状态：

- PD 已为 `UP`：`FASTRPC_IOCTL_INIT_ATTACH_SNS` 立即继续；
- PD 尚未 `UP`：等待 PDR 通知；
- 15 秒仍无通知：返回 `-ETIMEDOUT`；
- SLPI 重启：状态回落并等待下一次 `UP`。

确认日志：

```text
enabling SM8150 SDSP high-IOVA workaround
tracking protection domain msm/slpi/root_pd for tms/servreg
protection domain msm/slpi/root_pd is up
```

## Userspace

`hexagonrpcd` 使用 `/dev/fastrpc-sdsp` 并把 `/lib/firmware/hexagonfs` 提供给 sensors
PD。libssc 0.4.4 通过 QRTR/QMI 读取 SSC 数据。iio-sensor-proxy 3.9 的 SSC backend
向桌面导出加速度计，udev mount matrix 为：

```text
-1,0,0;0,-1,0;0,0,1
```

`nabu-tablet-mode` 只补充缺失的 `SW_TABLET_MODE`，屏幕方向仍由 GNOME/Mutter 根据
SensorProxy 数据决定。

## Production validation

生产 UKI：

```text
path: /dev/sda31:/EFI/ubuntu/6.14.11-nabu-iris-camera1+-build1.efi
SHA256: b0b5078230aa2495d332ecf2ded65f44c46c6ead8fdaf1bea3804417c79ac398
.linux SHA256: 2fef6dfc34df7f96c4e8a63fc18a2b97f649aba85f78948fb3033d2a478c8682
.dtb SHA256: 4efd2f9a316bb81e2e054d72bcfec9d6cd48fe2a8dd4ba5511c07c0c5e239b25
```

验证 boot ID：`1c830a89-178d-4dee-a258-552cd81a8d83`。

- SLPI 在 5.553 秒上线；
- root PD 在 6.189 秒报告 `UP`；
- `hexagonrpcd`、`iio-sensor-proxy` 一次启动成功；
- `HasAccelerometer=true`；
- SLPI crash、watchdog、attach timeout 和 IOMMU fault 为 0；
- 生产 cmdline 的 Iris/Venus 黑名单生效，Camera 正常加载。
