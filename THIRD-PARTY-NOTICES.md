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

## Bilibili NEXT 参考实现

本轮客户端授权、下载恢复与交互改进参考了 [wzk112/Bilibili-NEXT](https://github.com/wzk112/Bilibili-NEXT/tree/3b7582c42c0695e5f8da1255d506f3802e2ed417) 的公开实现与协议说明，按 BiliNext 的 libmpv、共享账号和标签生命周期重新实现。参考版本采用 MIT 许可证，保留其声明如下：

```text
MIT License

Copyright (c) 2026 Bilibili NEXT contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
