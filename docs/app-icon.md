# 应用图标

图标源文件为 `Resources/AppIcon.icon`，使用 Apple Icon Composer 打开编辑。
保留轻截的绿色、四角取景框与中心圆点，拆为独立的 Viewfinder 和 Capture Point
图层组；渐变底色、边缘高光、阴影、透明材质以及深色和单色外观由系统合成。
SVG 使用闭合填充轮廓，避免玻璃渲染将开放描边的端点连接起来。

在 Icon Composer 工具栏选择 **Design Generation 26** 检查 macOS 26 效果。
新版 Icon Composer 可能默认预览下一代效果，这个预览选项不保存在图标文档中。
运行 `python3 scripts/render_icon.py` 可明确使用第 26 代渲染器，导出浅色、深色、
单色和 32 px 小图标预览到 `dist/qa/icon-composer`。

所有可运行应用仍通过 `./scripts/build.sh` 构建。构建使用 Xcode 26 或更新版本的
`actool` 将 `.icon` 编译为 `Assets.car` 和旧版系统使用的 `AppIcon.icns`，并将工具
输出的图标元数据合并到应用 Info.plist。原生资源保留独立图层及各外观；不要用
单张 PNG 或手工绘制的 ICNS 替换。资源编译完成后才执行原有固定身份签名与安装。
