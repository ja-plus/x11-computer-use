# 排障与已知坑

## 环境

### `check` 报 `cannot talk to X display`

- 确认是 X11 会话：`echo "$XDG_SESSION_TYPE"` 应为 `x11`；`echo "$DISPLAY"` 通常是 `:0`。
- 在 Wayland 会话里，XWayland 的 DISPLAY 可能是 `:1`，先 `ls /tmp/.X11-unix/` 看可用编号。
- SSH 远程时 DISPLAY 不会自动转发，本脚本默认 `:0` 只适用于本机。

### Wayland

xdotool 只能操作 XWayland 窗口。Wayland 原生窗口（如新版文件管理器、终端）看不到、点不到。需要原生 Wayland 控制时，考虑 `ydotool` / `wtype` / compositor 自己的接口；本 skill 不覆盖。

## 截图

### 4K / 多屏下 `shot --win` 失败

`import -window <id>` 在 3840×2160 上可能直接失败或得到全黑图。改用区域截图：

```bash
$S shot /tmp/s.png --crop 1200x800+100+100
```

### 截图是黑的 / 只有桌面背景

- 某些合成器或硬件加速窗口不进入 root 截图，先激活窗口再截。
- 弹窗/动画未完成时加 `--delay 1`。

### 缩放后点击偏了

用了 `--max-width` 就必须换算：`屏幕坐标 = crop_offset + 图片坐标 × scale`。用 `$S coord` 计算，不要手算。

### 多显示器坐标为负

X11 允许负坐标（屏幕在主屏左侧/上方）。`--crop` 的 `+X+Y` 也接受负值，例如 `--crop 800x600-100+0`；`coord` 同样支持负偏移。

### JPEG

输出扩展名决定格式（`.jpg` / `.jpeg`），`--quality` 只对 JPEG 生效（1–100，默认 85）。PNG 无损但 4K 全屏约 3–4 MB。

## 输入

### 文本输入失败或乱码

`type` 检测到中文/emoji 会自动改走剪贴板（`xclip` 或 `xsel`），粘贴后再恢复原剪贴板：

```bash
$S type "中文文本"
# stderr: typed via clipboard (xclip ...); clipboard restored: yes
```

- 终端里 `Ctrl+V` 往往不是粘贴，通常是 `Ctrl+Shift+V`：`$S type --paste-key ctrl+shift+v "文本"`。
- 想强制用 xdotool 逐字符输入：`$S type --no-clipboard "text"`。
- 没有 `xclip`/`xsel` 时会退回 `xdotool type`，中文可能丢失；`sudo apt install xclip` 即可。
- 如果目标窗口不支持粘贴，改用 `--no-clipboard`，或先确认焦点窗口。
- 剪贴板会被临时占用并在粘贴后恢复；如果原剪贴板是图片/文件，恢复后可能只剩文本表示。

### 键名不对

xdotool 使用 X keysym：`Return`（不是 enter）、`Escape`、`Tab`、`space`、`BackSpace`、`super`、`Page_Up`。组合键写作 `ctrl+shift+t`。

### 点击没反应

- 目标窗口可能没有焦点，先 `$S win activate <id|标题>`。
- 慢应用需要额外等待：动作后 `sleep 1` 再截屏确认。
- 坐标落在窗口阴影/圆角上时会被判为桌面，取元素中心。

### 拖拽变成点击

`drag` 内置 `--sync`，但部分应用需要更慢的移动。可在两次 `drag` 失败后改用 `mousedown` → 多次 `move` → `mouseup` 手动组合（脚本未封装时用 xdotool 原生命令）。

### 滚轮不生效

- `scroll` 只支持垂直滚轮（按键 4/5）。需要水平滚动时用 `xdotool click 6/7` 原生命令。
- 目标区域必须是可滚动的内容；指针落在滚动条/工具栏上时滚轮无效。
- 部分应用（如基于 GTK4 的)只认平滑滚筒事件，xdotool 的离散滚轮可能一格跳很多行，先 `scroll <x> <y> 1` 试探。

### click --verify 报 WARN

WARN 表示点击点周边 240×240 像素在点击前后**没有像素变化**，两种可能：

1. 真的点空了（坐标错、窗口在下面、点了装饰区）→ 重新截屏定位再试。
2. 点击只改变焦点/悬停态，视觉上无变化 → 属于正常，重新截屏确认即可，不要盲目重试。

`--verify` 只做局部 diff（约 1 秒内完成），不能替代人工截屏确认，但能低成本拦截"点空"这类最常见失误。

### shot --grid 的标签和网格

- 网格线按**屏幕坐标**对齐（步长默认 200px，太密会自动翻倍），每个交点旁的数字就是屏幕坐标——照着数字报坐标即可，无需再乘 scale。
- crop 截图时标签已包含偏移换算（例如 `--crop ...+100+100` 时第一条线标 300，对应屏幕 x=300）。

### 剪贴板

- `clipboard get` 拿不到内容：剪贴板里是图片/文件/富文本时无纯文本表示；截图工具的"复制到剪贴板"通常可读。
- `clipboard set` 会覆盖原内容且**不自动恢复**（`type` 的剪贴板路径才会恢复）；要保留原值先 `clipboard get` 存下来，用完再 set 回去。

## 序列与等待

### act 宏

- 步骤用 `;` 分隔、参数用空格分隔（`click 960 540`，不是 `click 960,540`）；步骤文本里不能含 `;`。
- 不做 shell 引号解析：`type "hi"` 会连引号一起输入；含空格/引号的文本请单独调用 `type`。
- 某一步失败即停止，报 `act: step N failed`；步骤支持 click/dclick/rclick/move/scroll/type/key/drag/sleep/pos/coord/win/clipboard。

### waitfor

- `waitfor win "<标题>"` 轮询窗口标题，`waitfor change <x> <y>` 轮询该点周边 240×240 像素，默认 10s 超时，`--timeout <sec>` 放在参数前后都可以。
- 点击后用 `waitfor change` 代替 `sleep 1` 猜等待：UI 一更新就返回。注意指针移动本身不改变截图内容（X11 截图不含光标）。

## 语义定位（ui）

- 未装 at-spi2-core 时：`check` 报 `accessibility: off`，`ui` 三条命令 exit 2 并提示安装；其余命令不受影响。
- 装了但树为空/控件少：应用要带 a11y 环境变量启动——GTK 加 `GTK_MODULES=gail:atk-bridge`，Qt 加 `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1`，重启目标应用（已运行的应用不会中途注册）。
- **DDE/Qt 应用（deepin-file-manager、DDE 组件等，2026-10-28 实测）**：控件名齐全但 frame 报 0x0、菜单项坐标是弹层局部值（如 (81,136)），`showing` 恒为 False。uidump 按"祖先 frame 几何有效才信任后代坐标"的信任链处理，这类元素全部输出 `center=none`，`ui click` 会拒绝并提示回退。正确用法是混合模式：`ui find` 拿到有哪些控件（名称即语义线索），`shot --grid` 后按截图坐标点击。
- **GTK/Electron 应用**：几何一般可信，`ui click` 可直接用；Electron 首次需在其设置里开启辅助功能或在启动参数加 `--force-renderer-accessibility`。
- `ui find` 找不到：试试更短的关键词（匹配是子串、大小写不敏感）。

## 权限

- 普通 X11 注入不需要 root。
- 用 `pkexec`/`sudo` 提权时，环境变量（DISPLAY、XAUTHORITY）不会继承，且命令参数必须是绝对路径。
- 需要给其他用户/服务用时，确保其有 Xauthority 访问权限（`xhost` 有安全风险，慎用）。

## 调试

```bash
bash -x scripts/xctrl.sh click 100 200   # 看每条命令
$S check                                  # 工具与显示是否正常
$S pos                                    # 指针实际位置
```
