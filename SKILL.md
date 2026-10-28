---
name: x11-computer-use
description: "X11 桌面鼠标键盘注入与截屏控制。通过 xdotool 控制指针移动/点击/拖拽/滚轮/键盘输入，通过 ImageMagick import 截取全屏/窗口/区域；支持坐标网格复核（--grid）、点击像素验证（--verify）、双输出截图（--dual）、条件等待（waitfor）、宏序列（act）、剪贴板读写、AT-SPI 语义控件树（ui tree/find/click）。当用户要求操作 GUI、点击界面元素、自动化桌面操作、截屏查看屏幕内容、移动鼠标、滚动页面、模拟键盘按键时使用。Trigger words: 控制鼠标、点击、点一下、拖拽、滚动、滚轮、模拟按键、输入文字到窗口、截屏、看屏幕、GUI automation, click, move mouse, scroll, screenshot, xdotool."
license: MIT
compatibility: Linux X11 会话（Wayland 下仅对 XWayland 窗口生效）；需要 xdotool 与 ImageMagick 6/7（import/identify 或 magick）；剪贴板读写需 xclip 或 xsel；ui 子命令需 at-spi2-core（缺失时优雅报错）；已在 Deepin 25、3840×2160 实测。
metadata:
  author: ja-plus
  version: 1.5.0
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

1. 截屏看清屏幕：`<skill>/scripts/xctrl.sh shot /tmp/screen.png --dual /tmp/screen_view.jpg --dual-width 1280`——**一条命令同时产出原生 PNG（点击换算用）和缩小 JPG（看图用）**，输出里的 `view-scale` 用于换算视图坐标
2. 用图片查看工具打开截图，定位目标元素坐标。**坐标拿不准时重截一张加 `--grid`**：网格标签就是屏幕坐标，按刻度报坐标能显著减小误差
3. **有 AT-SPI 时优先语义定位**：`ui find "<按钮文字>"` 直接拿到控件中心坐标（需 `sudo apt install at-spi2-core`，见 `ui` 命令），比看图估坐标准
4. 执行动作，多步操作合并成一条 `act` 宏：`act "click 960 540 ; sleep 0.5 ; type hi ; key Return"`
5. 验证结果：`click --verify` 自动对比点击点周边像素；等 UI 响应用 `waitfor change <x> <y>` / `waitfor win "<标题>"` 代替盲目 sleep；最后再截屏确认

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
$S click <x> <y> --verify     # 点击并对比点击点周边像素；无变化输出 WARN
$S dclick <x> <y>             # 双击
$S rclick <x> <y>             # 右键
$S drag <x1> <y1> <x2> <y2>   # 拖拽
$S scroll <x> <y> <clicks>    # 移动+滚轮；正数向下滚，负数向上滚
$S act "click 960 540 ; sleep 0.5 ; key Return"   # 宏：一条命令跑多步
$S type "<text>"              # 向焦点窗口输入文本；非 ASCII 自动走剪贴板
$S type --paste-key ctrl+shift+v "<text>"  # 终端里粘贴键通常是 ctrl+shift+v
$S key ctrl+c                 # 按键组合（ctrl+c / Return / alt+F4 / super）
$S clipboard get              # 读剪贴板文本（精确拿取 GUI 里的文本内容）
$S clipboard set "<text>"     # 写剪贴板；省略参数时从 stdin 读
$S waitfor win "<标题>"        # 阻塞等待匹配窗口出现（默认 10s 超时）
$S waitfor change <x> <y>     # 阻塞等待 (x,y) 附近像素变化（等 UI 响应）
$S ui tree                    # AT-SPI 语义控件树（角色/名称/坐标）
$S ui find "<按钮文字>"        # 按名称找控件，输出 center=(x,y)
$S ui click "<按钮文字>"       # 语义点击第一个匹配控件的中心
$S win search "<标题关键词>"    # 列出匹配窗口：id | 几何 | 标题
$S win list                   # 列出所有可见窗口（最上层在前）
$S win activate <id|标题>      # 激活（聚焦+置顶）窗口
$S win geom <id|标题>          # 查询窗口几何
$S shot /tmp/out.png          # 全屏截图（原生分辨率）
$S shot /tmp/out.png --win <id|标题>          # 截单个窗口
$S shot /tmp/out.png --crop 800x600+100+100   # 截区域
$S shot /tmp/out.png --delay 2                # 延迟 2 秒再截（等动画/弹窗）
$S shot /tmp/out.png --max-width 1920         # 缩小截图（记得换算坐标）
$S shot /tmp/out.png --dual /tmp/v.jpg        # 一次截屏额外产缩小 JPG（省一半时间）
$S shot /tmp/out.png --grid 200               # 叠加坐标网格（标签=屏幕坐标）
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
- **盲点复核**：不确定坐标时先 `shot --mark <x>,<y>`，截图上的红十字就是即将点击的位置；或用 `--grid` 直接按刻度读坐标。
- **`--verify` 的 WARN 不一定是点空**：只改变焦点/悬停态的点击不会产生像素变化；看到 WARN 先重新截屏确认，不要盲目重试。
- **`clipboard get` 只返回文本**：剪贴板里是图片/文件时读不到内容。
- **网格标签即屏幕坐标**：`--grid` 画在截图上的数字已经是屏幕坐标系（含 crop 偏移换算），照着报坐标即可，不需要再乘 scale。
- **`act` 宏不做 shell 引号解析**：步骤按空白切分，`type` 的文本不能带空格或引号（引号会被原样输入）；含空格/分号的文本请单独调用 `type`。
- **`ui` 语义树需要 at-spi2-core**：未安装时报错并提示；`check` 会报告 `accessibility: ok/off`。GTK 应用可能还需 `GTK_MODULES=gail:atk-bridge`、Qt 应用需 `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1` 并重启应用才暴露控件树。
- **DDE/Qt 应用的几何不可信（实测）**：Qt bridge 能给出控件名（`ui find` 有用），但窗口 frame 报 0x0、菜单项坐标是弹层局部值——`uidump` 会把这类元素标为 `center=none`，`ui click` 拒绝执行并提示回退。工作流：`ui find` 拿控件清单 → `shot --grid` 视觉定位 → 坐标点击。GTK/Electron 应用几何通常可信，`ui click` 可直接用。
- **`--dual` 的 `view-scale`**：view 图上的坐标 × view-scale（crop 时再加偏移）= 屏幕坐标，与主图 `scale` 的换算方式相同。

更多排障细节见 `references/troubleshooting.md`。

## 局限（须如实告知用户）

- 纯坐标盲操作，无 GUI 语义——不认识按钮，只认识像素坐标。
- 仅 X11 可用；Wayland 下只影响 XWayland 应用。
- 无法读取屏幕上控件的语义（无 Accessibility API），坐标依赖截图推断。
