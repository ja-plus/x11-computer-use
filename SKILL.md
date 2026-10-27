---
name: x11-computer-use
description: "X11 桌面鼠标键盘注入与截屏控制。通过 xdotool 控制指针移动/点击/拖拽/键盘输入，通过 ImageMagick import 截取全屏/窗口/区域。当用户要求操作 GUI、点击界面元素、自动化桌面操作、截屏查看屏幕内容、移动鼠标、模拟键盘按键时使用。Trigger words: 控制鼠标、点击、点一下、拖拽、模拟按键、输入文字到窗口、截屏、看屏幕、GUI automation, click, move mouse, screenshot, xdotool."
license: MIT
compatibility: Linux X11 会话（Wayland 下仅对 XWayland 窗口生效）；需要 xdotool 与 ImageMagick 6/7（import/identify 或 magick）；已在 Deepin 25、3840×2160 实测。
metadata:
  author: ja-plus
  version: 1.3.0
---

# X11 Computer Use

在 Linux X11 桌面上通过 shell 控制鼠标、键盘和截屏。核心脚本是 `<skill>/scripts/xctrl.sh`，封装了 xdotool 与 ImageMagick `import`。

下文 `<skill>` 指本 SKILL.md 所在的 skill 目录，所有相对路径都从该目录解析。

## 前置检查

首次使用前跑一次环境探测：

```bash
<skill>/scripts/xctrl.sh check
```

正常输出包含 `session: x11`、`tool ok : xdotool`、`imagemagick: im6`（或 `im7`）、`screen: 3840x2160`。若是 Wayland 会话，注入与截图都只覆盖 XWayland 窗口，须提前告知用户。

可选：跑一次不产生鼠标动作的自检（会截一张图到临时目录后删除）：

```bash
<skill>/scripts/selftest.sh
```

## 使用约定（重要）

- **未经用户明确要求，不主动移动指针、不点击、不截屏。**
- **会占用真实鼠标**：`move`/`click`/`drag` 移动的就是用户当前光标，操作期间用户无法正常用鼠标；键盘输入进入当前焦点窗口。执行前先告知用户。
- 点击前必须先截屏（或用 `win search` 拿窗口几何）确认目标坐标；纯坐标盲点不可靠。
- 涉及删除、发送、支付等破坏性/外发性操作的点击，先向用户确认再执行。
- 每次操作后用截屏验证结果，不要假设点击生效。
- 脚本失败会返回非零并打印 `ERROR:`；看到错误不要重试同样的坐标，先重新截屏定位。

## 标准工作流

1. 截屏看清屏幕：`<skill>/scripts/xctrl.sh shot /tmp/screen.png`
2. 用图片查看工具打开截图，定位目标元素坐标
3. 需要时用 `win search` / `win geom` 交叉验证窗口位置；仍不确定就用 `shot --mark <x>,<y>` 在截图上画十字复核
4. 执行动作：`<skill>/scripts/xctrl.sh click <x> <y>`
5. 再次截屏验证结果

若第 1 步用了 `--max-width`（缩小截图），**必须先换算坐标**：把截图上量到的坐标乘以输出里的 `scale`，再用 `coord` 命令算一遍，见下节。

## 截图与坐标（重要）

`shot` 默认按原生分辨率截取，图片坐标 = 屏幕坐标，可直接点击。

为了让视觉输入更省 token，可以缩小截图：

```bash
$S shot /tmp/s.png --max-width 1920
# saved: /tmp/s.png
# image: 1920x1080  screen: 3840x2160  scale: 2.000
```

此时截图上量到的 `(800, 450)` 对应屏幕 `(1600, 900)`，用脚本换算：

```bash
$S coord 800 450 2.0          # -> 1600 900
```

`--crop` 截图时，输出会带 `crop offset: +X+Y`，屏幕坐标 = `(X,Y) + 图片坐标 * scale`，用第 4、5 个参数传偏移：

```bash
$S coord 100 80 2.0 100 100   # -> 300 260
```

截图格式由扩展名决定（`.png` / `.jpg`）；JPEG 可用 `--quality 80` 控制质量。**不要用缩小后的截图坐标直接 click。**

## 命令速查

```bash
S=<skill>/scripts/xctrl.sh

$S check                      # 环境探测（X11/工具/分辨率）
$S pos                        # 当前指针位置
$S move <x> <y>               # 移动指针（不点击）
$S click <x> <y> [button]     # 移动+点击；button 1=左 2=中 3=右
$S dclick <x> <y>             # 双击
$S rclick <x> <y>             # 右键
$S drag <x1> <y1> <x2> <y2>   # 拖拽
$S type "<text>"              # 向焦点窗口输入文本；非 ASCII 自动走剪贴板
$S type --paste-key ctrl+shift+v "<text>"  # 终端里粘贴键通常是 ctrl+shift+v
$S key ctrl+c                 # 按键组合（ctrl+c / Return / alt+F4 / super）
$S win search "<标题关键词>"    # 列出匹配窗口：id | 几何 | 标题
$S win activate <id|标题>      # 激活（聚焦+置顶）窗口
$S win geom <id|标题>          # 查询窗口几何
$S shot /tmp/out.png          # 全屏截图（原生分辨率）
$S shot /tmp/out.png --win <id|标题>          # 截单个窗口
$S shot /tmp/out.png --crop 800x600+100+100   # 截区域
$S shot /tmp/out.png --delay 2                # 延迟 2 秒再截（等动画/弹窗）
$S shot /tmp/out.png --max-width 1920         # 缩小截图（记得换算坐标）
$S shot /tmp/out.jpg --quality 80             # JPEG + 质量
$S shot /tmp/out.png --mark 1600,900           # 画十字复核目标坐标
$S coord <img_x> <img_y> <scale> [off_x off_y] # 图片坐标 -> 屏幕坐标
```

## 已知坑

- **4K 屏（3840×2160）**：截单窗口 `import -window <id>` 可能失败；区域截图走 `--crop`（root + crop）最稳。
- **缩放后坐标**：用了 `--max-width` 就必须乘 `scale`，否则点击会落在屏幕左上方一半的位置。
- **pkexec/相对路径**：用 pkexec 提权时命令参数必须用绝对路径。
- **键名**：xdotool 用 X keysym 名（Return、Escape、Tab、space、super 等），不是 "enter"。
- **输入延迟**：脚本已内置 move→click 同步与 0.2–0.3s 间歇；对慢响应的窗口，动作后额外 `sleep` 再截屏。
- **非 ASCII 文本**：`type` 检测到中文/emoji 会自动改用剪贴板并恢复原剪贴板；终端里粘贴键通常是 `ctrl+shift+v`，用 `--paste-key` 指定。
- **盲点复核**：不确定坐标时先 `shot --mark <x>,<y>`，截图上的红十字就是即将点击的位置。

更多排障细节见 `references/troubleshooting.md`。

## 局限（须如实告知用户）

- 纯坐标盲操作，无 GUI 语义——不认识按钮，只认识像素坐标。
- 仅 X11 可用；Wayland 下只影响 XWayland 应用。
- 无法读取屏幕上控件的语义（无 Accessibility API），坐标依赖截图推断。
