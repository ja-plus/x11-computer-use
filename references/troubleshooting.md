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
