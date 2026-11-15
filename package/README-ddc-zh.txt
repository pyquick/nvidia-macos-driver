GeekAudio NullMoth 2.9 · 外接屏亮度

本覆盖包以作者的官方 v2.9 驱动为底包。外接屏亮度走作者的 DDC/CI 通道，
在 macOS 显示器设置中调节。NVRM 和 NVAccel 的 GPU 监控使用作者实现。
上一版 fork 的视频和 IOSurface 适配继续随包提供。

已在 Intel macOS 26.7.3（25G416）、RTX 3080 上验证原生亮度调节：
HKC T2751U（DisplayPort）和 Redmi 215 NF（HDMI）均可调节并读回硬件亮度。

安装

1. 下载本页覆盖包和 SHA256SUMS.txt，并在下载目录核对：
   shasum -a 256 -c SHA256SUMS.txt
2. 下载官方归档：
   https://github.com/nullmoth/nvidia-macos-driver/releases/download/v2.9/nullmoth-nvidia-2.9.tar.gz
3. 解压覆盖包，在解压后的目录运行（需要 Python 3）：
   python3 assemble.py /路径/nullmoth-nvidia-2.9.tar.gz /路径/geekaudio-2.9-installer
4. 进入生成的安装目录，运行 sudo ./install.sh，保留安装器打印的回滚备份。
5. 在现有 OpenCore boot-args 中加入 nvrmfbddc=1。若使用过上一套方案，
   删除旧的 nvddcci=1，以及 Kernel/Add 中的 DisplayBrightness.kext 条目和对应
   EFI/OC/Kexts 文件。保留原有显卡和 Lilu 配置。保存后重启。

NullMoth 组件按原许可证发行，仅限非商业用途。
