# 第三方组件

BiliNext 源码采用 GNU General Public License version 3（GPL-3.0-only），完整正文见 LICENSE。

## mpv / libmpv

Homebrew 分发版动态链接用户通过 Homebrew 安装的 libmpv，不在 BiliNext ZIP 中附带 mpv、FFmpeg 或它们的运行库。mpv 及其依赖仍遵循各自许可证；依赖由 Homebrew 独立安装和更新。

- mpv 源码与许可证说明：https://github.com/mpv-player/mpv
- mpv Copyright：https://github.com/mpv-player/mpv/blob/master/Copyright
- Homebrew mpv 构建配方与源码地址：https://formulae.brew.sh/formula/mpv
- FFmpeg 许可证说明：https://ffmpeg.org/legal.html

本地开发的内嵌运行库打包方式不用于 Homebrew Release；若另行分发含运行库的独立包，需随包整理实际所用构建的完整许可证和对应源码。

## 本机官方播放器

可选官方播放器代码从用户本机已安装的哔哩哔哩客户端只读加载，不包含在 BiliNext 的源码或发行包中，其权利属于原权利人。
