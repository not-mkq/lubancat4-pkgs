# LubanCat-4 Arch Linux 移植

EmbedFire(野火) LubanCat-4 的包构建与 TF 卡镜像工程。实测板卡 EBF410116 V1R1，RK3588S2，8 GiB LPDDR4X。系统用 ext4 的 `/boot`、Btrfs root 和 extlinux 启动，没有 initramfs。

镜像提供两条内核路线：主线 Linux 和 Rockchip BSP 6.12。启动链是 U-Boot binman 打进一个 Rockchip 启动镜像，里面是 Rockchip 的 DDR training、U-Boot SPL、开源 TF-A BL31 和 U-Boot 本体。DDR training 仍是闭源二进制。

[English version](README.md)

这是板级移植工程，不是 Arch Linux ARM 的官方板卡镜像。

## 板级接口

设备树里写的是 SoC 的 GPIO 名称，与 40-pin 排针编号无关。`GPIO4_A2` 指 GPIO bank 4 的 A 组第 2 位，A/B/C/D 各 8 位。排针的电源、地线和复用关系看对应 revision 的原理图。

| 信号 | DSI0 非 V1 | DSI0 V1 | DSI1 非 V1 | DSI1 V1（实测） |
|---|---|---|---|---|
| 显示路径 | VP2 → DSI0 | 同左 | VP3 → DSI1 | 同左 |
| 面板 reset | GPIO0_B7 | GPIO1_A1 | GPIO0_D3 | GPIO0_D3 |
| 面板电源使能 | GPIO1_D2 | GPIO1_D2 | GPIO1_D3 | GPIO1_D3 |
| 背光 PWM | PWM2/m0 | 同左 | PWM6/m0 | 同左 |
| GT911 总线 | I2C5/m3 | 同左 | I2C6/m3 | 同左 |
| GT911 IRQ | GPIO0_C5 | GPIO0_C5 | GPIO3_C4 | GPIO4_A1 |
| GT911 reset | GPIO0_C0 | GPIO1_A0 | GPIO3_C5 | GPIO4_A2 |

引脚定义在 `pkgs/linux-lubancat4-git/rk3588s-lubancat4-dsi*.dtso`，厂商对应文件在 BSP 包的 `vendor-dts/rockchip/`。GT911 地址 `0x5d`。本仓库实测用的是 EBF410173，7 寸 1024×600，接在 DSI1；其他屏需要自己移植，仓库里已有的材料如下。

### 仓库里已有的屏相关设备树

**mainline（`pkgs/linux-lubancat4-git/`）只有 EBF410173**，四份 overlay 覆盖 DSI0/DSI1 × 板子两个 revision：

| overlay | 用途 |
|---|---|
| `dsi0-ebf410173.dtso` / `-v1.dtso` | DSI0，VP2 |
| `dsi1-ebf410173.dtso` / `-v1.dtso` | DSI1，VP3（实测用的这套） |

**BSP（`pkgs/linux-lubancat4-bsp/vendor-dts/rockchip/`）有五种屏**，每种都有 DSI0 与 DSI1 两份，编译后安装到 `/boot/bsp/overlays/`：

| 屏 | 分辨率 | 驱动 compatible |
|---|---|---|
| EBF410173 | 1024×600 | `embedfire,ebf410173`（mainline 新写的驱动） |
| EBF410125 | 1080×1920 | 厂商 `simple-panel-dsi` |
| EBF410177 | 800×1280 | 厂商 `simple-panel-dsi` |
| S8001280B1060B | 800×1280 | 厂商 `simple-panel-dsi` |
| `generic` | 由 EEPROM 决定 | 厂商自动探测 |

### 用其他屏做什么

**BSP 内核**：直接用 vendor 的 overlay，例如

```sh
lubancat4-overlay -k bsp list
lubancat4-overlay -k bsp clear
lubancat4-overlay -k bsp enable rk3588s-lubancat-4-dsi1-vp3-800x1280-10.1inch-ebf410177-overlay
reboot
```

**mainline**：没有现成材料，需要自己移植。步骤是把厂商那个 `.dtsi` 里的 `panel-init-sequence`、`display-timings`、DSI 参数搬进一份新 overlay，再把 `compatible` 指向一个现有驱动：

- 面板初始化命令能与 `simple-panel` 通用的 `prepare-delay-ms` / `init-delay-ms` 对应时，可以试着用 `panel-simple`；
- 需要逐条发 DCS 命令的屏，参照 `panel-embedfire-ebf410173.c` 写一个新的 panel 驱动；
- 改完用 `check-overlays.py` 跑一遍静态检查，再上板看 `dmesg` 和实际画面。

V1/non-V1 的引脚差异见上表，选错会出现“两个驱动抢同一根线”。

| 其他接口 | 描述 |
|---|---|
| 调试串口 | 1500000 8N1；主线用 ttyS2，BSP 用 ttyFIQ0 |
| TF 卡 | 控制器 fe2c0000.mmc；设备名会变，按 PARTUUID 和介质类型确认 |
| XL9535 扩展 | I2C6，地址 0x21；非 V1 的 IRQ 为 GPIO1_A0，V1 为 GPIO0_C0 |
| XL9535 输入 | 内部 line 3/4/5 是按键，7 是编码器按下，12/13/14 是编码器输入 |
| HDMI | HDMI0；音频要开 overlay 并接显示器 |
| 板载以太网 | GMAC + RTL8211F；联网实测走的是 USB CDC 网卡 |
| 摄像头 | 厂商设备树带多种传感器 overlay，未接摄像头测试 |

V1 与非 V1 的 overlay 对应不同 pinmux，按板子 revision 选。V1 的 dtb 以 `-v1` 结尾。BSP 的 overlay 编译在 vendor 树，主线的是在主线树上编的，两者不通用。
## 软件组成

| 包目录 | 作用 |
|---|---|
| `pkgs/linux-lubancat4-git` | 跟踪主线 Linux，加板级 NPU/RGA 配置、7 个 overlay 和 EBF410173 面板驱动，同时出 headers 包 |
| `pkgs/linux-lubancat4-bsp` | Rockchip develop-6.12 内核，保留厂商 Mali/RKNPU/MPP/RGA 接口；自带 EmbedFire 板级 DTB 和 vendor overlay，装到 `/boot/bsp` |
| `pkgs/uboot-lubancat4` | U-Boot 2026.10、开源 TF-A BL31、binman 启动镜像，附 DDR 和 BL32 二进制输入 |
| `pkgs/lubancat4-board-config` | 网络、串口、fstab/extlinux 模板，以及 overlay/status/flash 工具 |

构建脚本：`00-hostdeps.sh`、`01-build.sh`、`02-repo.sh`、`03-mkimg.sh`。包产物在 `pkg/`，本地 pacman 仓库在 `repo/`，镜像在 `dist/`。

## 两个内核如何共存

镜像默认同时装 `linux-lubancat4-git` 和 `linux-lubancat4-bsp`，两个包各写各的目录：

```text
/boot/Image                 /boot/bsp/Image                 内核
/boot/dtbs/rockchip/        /boot/bsp/dtbs/rockchip/        设备树
/boot/overlays/             /boot/bsp/overlays/             overlay
```

`/boot/extlinux/extlinux.conf` 里每个内核一个 `label`，每段的 `linux`、`fdt`、`fdtoverlays` 只在段内生效。U-Boot 的 extlinux bootmeth 按选中的 label 逐行执行，选 `arch` 就只用主线的 DTB 和 overlay，选 `bsp` 就只用 BSP 的。

BSP 的板级 DTB 来自 EmbedFire 的 vendor 树，由 BSP 包自己编译并安装，与 Rockchip 参考板的 76 个 DTB 放在同一目录下。两段的 `append` 也不同：主线 `console=ttyS2`，BSP `console=ttyFIQ0`。

overlay 开关按 label 分区编辑，清单也分开（`/etc/lubancat4/overlays`、`/etc/lubancat4/overlays-bsp`）：

```sh
lubancat4-overlay list                  # 默认内核
lubancat4-overlay -k bsp list           # BSP
lubancat4-overlay -k bsp enable rk3588s-lubancat-4-dsi1-vp3-1024x600-7inch-ebf410173-overlay
```

`03-mkimg.sh` 在 `/boot/bsp/Image` 和板级 DTB 都存在时追加 BSP 入口，否则只写主线入口。

每个内核包都带一个 pacman install scriptlet：装完把 `default` 改成自己那一项，所以装/卸哪个内核，默认启动就跟到哪个。脚本只改全局那行 `default`，其它行原样保留；`label` 不存在或 `extlinux.conf` 还没生成（pacstrap 阶段）时只打印提示，退出码 0，不会中断事务。




## 构建

```sh
bash scripts/00-hostdeps.sh
bash scripts/01-build.sh
bash scripts/02-repo.sh
sudo bash scripts/03-mkimg.sh <输出路径> <容量>
```

`01-build.sh` 用 `MAKEFLAGS=-j16`，构建前清掉 `pkg/` 和 `pkgs/<包名>/` 里的旧归档与旧签名，保证同名包会重建。DDR training 和 BL32 是 U-Boot 包里带 SHA256 的本地输入，不需要先在主机装固件包。

`03-mkimg.sh` 需要 root、loop 和 mount，在宿主 shell 里跑。写卡前先确认目标设备。

写卡（`/dev/sdX` 换成你的卡，整个设备，不是分区）：

```sh
sudo dd if=dist/<镜像>.img of=/dev/sdX bs=4M conv=fsync status=progress
sync
```

### 根分区扩容

镜像默认 rootfs 为 3072 MiB（`ROOT_MB`），烧到更大卡上时剩余空间是空闲的。



**已烧好的卡在板上在线扩容**

```sh
# /dev/mmcblk1 是 TF 卡，先确认
lsblk -o NAME,SIZE,MODEL
sudo sfdisk --part-size 3:0 --no-tell-kernel /dev/mmcblk1
sudo partprobe /dev/mmcblk1
sudo btrfs filesystem resize max /
df -h /
```

`--part-size 3:0` 只把 3 号分区扩到盘尾；起始扇区和分区 UUID 都保留，`/boot` 和 `/` 的
`PARTUUID=` 引用不受影响。



### 软件源

构建机和成品镜像默认都使用 **USTC 源**（`https://mirrors.ustc.edu.cn/archlinuxarm/`），
第二顺位是 TUNA，最后是 Arch Linux ARM 官方源。顺序写在两个文件里：

| 文件 | 作用位置 |
|---|---|
| `conf/pacman.aarch64.conf.in` | `03-mkimg.sh` 在宿主机跑 `pacstrap` 时用的 pacman 配置 |
| `conf/mirrorlist.lubancat4` | 镜像里的 `/etc/pacman.d/mirrorlist` |

要换源改这两个文件再重建镜像
板上改源直接编辑 `/etc/pacman.d/mirrorlist`（该文件属于镜像，不属于任何包）。

## 使用

把卡插回板子、上电。串口 1500000 8N1，或直接接网线。

### 登录

| 项 | 值 |
|---|---|
| 用户名 | `root` |
| 密码 | `root`（构建时 `LBC_ROOT_PASSWORD` 可改） |

串口在开机日志结束后出现 `lubancat4 login:`。SSH 在板子拿到 DHCP 地址后可用：

```sh
ssh root@<板子 IP>
```

板子的 IP 从路由器 DHCP 列表查，或串口里 `ip -4 addr show`。

### 换 root 密码

```sh
passwd
```

### 关掉 SSH 的 root 密码登录

镜像里装的是 `conf/sshd-lubancat4.conf`，落在 `/etc/ssh/sshd_config.d/10-lubancat4.conf`：

```
PermitRootLogin yes
PasswordAuthentication yes
```

后续为安全考虑可以删掉这个文件重启sshd 



