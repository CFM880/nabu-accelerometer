# Source and hardware mapping

## Linux baseline

- Tree: `https://gitlab.postmarketos.org/soc/qualcomm-sm8150/linux.git`
- Commit: `5181e1358ddd6ea8028e841d928942373e6aebc8`
- IIO driver: `drivers/iio/imu/st_lsm6dsx/`
- Binding: `Documentation/devicetree/bindings/iio/imu/st,lsm6dsx.yaml`

The upstream driver already supports `st,lsm6dso`; this project only needs the
nabu SSC bus resources and board description.

## Android evidence

The nabu vendor sensor configuration identifies:

- `bus_type = SPI`
- `bus_instance = 2`
- chip select 0
- maximum clock 9600 kHz
- interrupt pin 132, active high
- identity orientation matrix

Those values come from `lsm6dso_0.json` and `sm8150_lsm6dso_0.json` in the
nabu proprietary vendor tree. The bus number belongs to Qualcomm SEE/SSC,
not the AP QUP namespace.

The downstream SM8150 DTS maps SSC bus 2 to:

- QUPv3 SSC wrapper: `0x26c0000`
- serial engine 2: `0x2688000`, GIC SPI 444
- Sensor Clock Controller: `0x2b10000`
- SLPI TLMM GPIO6–9

Relevant downstream files are:

```text
android_kernel_xiaomi_sm8150/arch/arm64/boot/dts/qcom/sm8150-qupv3.dtsi
android_kernel_xiaomi_sm8150/arch/arm64/boot/dts/qcom/sm8150-slpi-pinctrl.dtsi
android_kernel_xiaomi_sm8150/drivers/clk/qcom/scc-sm8150.c
android_kernel_xiaomi_sm8150/drivers/pinctrl/qcom/pinctrl-slpi.c
```

The sensor power handle maps through the SLPI firmware dependency table to
PM8150 LDO17. Mainline labels that supply `vreg_l17a_3p0` and constrains it to
2.856–3.008 V.

## Results that selected the SSC path

Earlier experiments incorrectly mapped Android bus 2 to AP QUP0 SE2 at
`0x888000`. Enabling that DT node without a driver booted, while binding the
GENI SPI driver locked up at the first SE register read. Runtime PM, clocks and
interconnect setup completed before that read. A global SPI driver blacklist
also disabled the Novatek touchscreen because it uses the same driver.

A selective no-bind test restored both CDSP and touch. Comparison with the
Android DTS then established that the IMU is on SSC SE2 at `0x2688000`.
The apparent `qcom_q6v5_pas 8300000.remoteproc:start timeout` was secondary to
the bad AP MMIO access, not the accelerometer's actual bus.

All AP QUP0 test DTS variants and the temporary in-tree SPI diagnostic patch
have therefore been removed from this project.

## 2026-09-03 runtime and provider results

The `ssc-controller-runtime` image was booted twice. Both boots reached the
real root filesystem, initialized the built-in `g_serial` gadget and entered
systemd. The second boot persisted logs through completion of udev coldplug,
then stopped before either private-driver success message was recorded. There
was no persisted panic, oops or pstore record. This rules out the UKI, root
filesystem and gadget-console setup as the initial failure, but does not yet
distinguish SCC provider registration from assigned-rate or branch-vote access.

The `ssc-controller-runtime` profile is therefore blocked from rebuilding.

The subsequent `ssc-provider` image removed the SE node, assigned rates and all
clock consumers. USB console showed that it completed udev coldplug and reached
normal service startup. At 127.174 seconds the kernel loaded
`nabu_sm8150_ssc`; no provider-success message followed, the USB console stayed
connected but produced no more output, and SSH did not return. This is a hard
lock inside the synchronous provider probe, before `qcom_cc_probe()` returned.
The `ssc-provider` profile is now blocked as well.

## Current validation boundary

Mainline 6.14 lacks SM8150 SCC and SLPI pinctrl drivers. The current active
`ssc-map-only` diagnostic successfully attached the SCC device to LCX and
completed `qcom_cc_map()`. Both probe markers appeared at 5.683 seconds, the
driver bound, login and Wi-Fi came up, and no systemd unit failed. This rules
out power-domain attachment, resource mapping and regmap construction.

The `ssc-empty-provider` stage also passed: all three markers appeared, the
driver bound, and login/network completed. This rules out the reset-controller
and OF provider setup in `qcom_cc_really_probe()`.

SM8150 video and camera clock drivers in the same kernel call
`devm_pm_runtime_enable()` and `pm_runtime_resume_and_get()` before mapping and
register access. The failed SCC provider omitted that sequence; the DT power
domain reference alone did not guarantee LCX was active during probe. The
`ssc-powered-empty-provider` added the runtime-PM resume/put around the already
proven zero-clock provider and passed: LCX resumed, runtime status later
returned to suspended, and the system remained healthy. The next
`ssc-powered-main-rcg` stage registered only the main RCG while LCX was active.
USB console stopped immediately after the pre-registration marker, before the
success marker, on the clock core's first `recalc_rate` MMIO read. No write,
rate change, branch vote or SE device was present.

Downstream Android keeps `clock_scc` disabled and does not enable it in the
nabu board DTS. Its SSC QUP nodes are firmware-facing resources associated with
SLPI. The repeated AP-side hard lock, including after an LCX vote, is therefore
consistent with XPU/firmware ownership rather than an ordinary clock-driver
dependency. All AP SCC MMIO profiles are blocked. The safe default is the
powered zero-clock provider only; functional sensor support must instead use
the existing SM8150 SLPI remoteproc/GLINK/FastRPC path and an SNS userspace or
kernel client. Directly exposing `0x2688000` to `spi-geni-qcom` is no longer a
valid next step.

## SLPI boot-only pivot

The normal nabu root filesystem contains a monolithic Qualcomm DSP6 ELF image
at `qcom/sm8150/xiaomi/nabu/slpi_nb.mbn`. The same system already boots its
modem, CDSP and ADSP `.mbn` images through `qcom_q6v5_pas`, confirming that this
firmware packaging is supported by the running kernel and userspace layout.

The upstream SM8150 device tree already describes `remoteproc_slpi`, including
PAS ID 12, the LCX and LMX power domains, the 20 MiB `slpi_mem` reservation,
SMP2P interrupts, AOSS QMP, GLINK and FastRPC compute contexts. Nabu's board
tree supplies the correct relocated `slpi_mem` range but previously left the
remote processor disabled. The active `slpi-boot-only` diagnostic therefore
changes only `firmware-name` and `status`. It deliberately instantiates neither
the private SCC clock provider nor SSC SE2. Its purpose is to validate firmware
boot and GLINK discovery before any SNS protocol client is added.

The first boot completed PAS authentication, brought up SLPI and enumerated
all three FastRPC compute contexts. The sensor user PD then hit its internal
initialization watchdog every approximately 40 seconds and remoteproc recovered
it. This is not an AP kernel lockup, but the reported `running` state only
describes the interval between recovery attempts.

The extracted Nabu sensor configuration and registry are installed below
`/lib/firmware/hexagonfs/{sensors,socinfo}`. Upstream `tqftpserv` resolves
`/readonly/firmware/image/<file>` relative to each remoteproc firmware's
directory. With the full board-specific firmware name, SLPI therefore looks
below `/lib/firmware/qcom/sm8150/xiaomi/nabu/`, where neither directory was
present. The first filesystem diagnostic adds only relative symlinks for those
two read-only trees and creates `/var/lib/tqftpserv/sensors/registry` for nested
read/write requests. It does not change the firmware image or kernel DT.

That mapping did not alter the approximately 40-second watchdog cycle, and
`tqftpserv` logged no request from SLPI. The separate `IPCRTR` rpmsg channel is
present and bound to `qcom_smd_qrtr`, so QRTR transport is not the missing
piece. The remaining boot-time filesystem path is FastRPC reverse RPC:
`sensor_process` is a static sensors protection domain and needs an AP default
listener for `apps_std` calls. The target has `/dev/fastrpc-sdsp` but initially
had no listener daemon.

The Linux-MSM `hexagonrpc` implementation documents and implements this exact
path. Its virtual root maps `sensors/config`, `sensors/registry`,
`sensors/sns_reg.conf` and `socinfo` to the corresponding Android resources.
Ubuntu 26.04 packages version 0.4.0, but its device wrapper only recognizes
SDM845 as SDSP and otherwise defaults to ADSP. The Nabu override must therefore
select `/dev/fastrpc-sdsp`, DSP name `sdsp`, sensors-PD attach (`-s`) and the
existing `/lib/firmware/hexagonfs` root explicitly.

## SM8150 SDSP FastRPC result

Starting `hexagonrpcd` against SDSP reached the sensors protection domain, but
the first allocation then faulted at IOVA `0x1fffff000` (SID `0x5a1`). The
mainline FastRPC path had mapped only the low 32-bit DMA address and added the
context-bank SID to the address sent to the DSP. Qualcomm's downstream SM8150
SDSP path instead establishes the corresponding high IOVA mapping.

The test kernel now creates that high alias in the existing IOMMU domain for
SM8150 SDSP buffers and removes it when the buffer is freed. The three SLPI
FastRPC context banks are also described as DMA coherent. On hardware, the
workaround marker appeared at 6.99 seconds and the SLPI sensors process plus
`hexagonrpcd` then remained stable beyond five minutes. No further SLPI crash,
IOMMU context fault, or user-PD watchdog was observed. This closes the DSP boot
and reverse-RPC blocker; sensor discovery/data now belongs to the SSC QMI
client layer.

The pinned client diagnostic is upstream `libssc 0.4.4`, downloaded as
`libssc-v0.4.4.tar.gz` with SHA256
`716d6bd6b34d2d753060c6b54c9a87e34fae75b724c763bf9ef487efa3621587`.
It talks to SSC over QRTR/libqmi and deliberately avoids direct AP access to
the sensor bus.

The hardware diagnostic discovered the SSC service on QRTR node 9, resolved
the `accel` SUID, and received continuous three-axis samples at roughly 25 Hz
for 20 seconds. The client disabled the stream cleanly afterwards, while SLPI,
FastRPC, and `hexagonrpcd` remained healthy with zero new crash signatures.

Ubuntu 26.04 ships `iio-sensor-proxy 3.8`, which predates the upstream SSC
backend. Upstream 3.9 adds libssc drivers and permits `AF_QIPCRTR` in the
service sandbox, but intentionally leaves SSC accelerometer discovery behind
a udev opt-in. The Nabu integration builds the 3.9 daemon against the pinned
libssc, installs it under `/usr/local`, and opts only `fastrpc-sdsp` into
`ssc-accel` with the identity orientation from the vendor registry. The
distribution binary remains untouched. On hardware, the service discovered
the device and exported `HasAccelerometer=true` on the system D-Bus.

A subsequent reboot preserved the complete stack: the new boot enabled the
SM8150 SDSP high-IOVA workaround, both daemons started automatically, the udev
device retained `IIO_SENSOR_PROXY_TYPE=ssc-accel`, and D-Bus again exported
`HasAccelerometer=true`. An authorized desktop client then reported the real
orientation sequence `right-up` to `bottom-up` and back to `right-up`, together
with tilt changes. No SLPI crash, IOMMU fault, or user-PD watchdog occurred
during boot, discovery, streaming, or client release.
