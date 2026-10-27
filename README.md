# x11-input-control

一个遵循 [Agent Skills 规范](https://agentskills.io) 的 X11 桌面控制 skill：用 `xdotool` 注入鼠标/键盘事件，用 ImageMagick `import` 截屏。适用于 Claude Code、Codex、Cursor、OpenCode 等支持 `SKILL.md` 的 agent。

> **平台要求：仅适用于 X11 会话。** 不支持 Wayland 原生窗口；在 Wayland 会话中只能操作 XWayland 应用（X11 程序）。
>
> **注意：鼠标操作会占用用户的真实鼠标/光标。** `move`、`click`、`dclick`、`rclick`、`drag` 会把系统指针移动到目标坐标，操作期间用户无法正常使用鼠标；本 skill 没有独立的“后台光标”。键盘输入同样会进入当前焦点窗口。

## 特性

- **零编译、零 Python 依赖**：纯 bash 脚本，只依赖 `xdotool` 和 ImageMagick
- **截图**：全屏 / 指定窗口 / 区域裁剪，支持缩小（`--max-width`）与 JPEG 质量控制
- **鼠标**：移动、单击、双击、右键、拖拽（会占用用户的真实光标），支持按键编号
- **键盘**：组合键（`ctrl+c`、`alt+F4`、`super`）与文本输入；中文/emoji 自动走剪贴板并恢复原剪贴板
- **窗口**：按标题搜索、激活、查询几何
- **坐标换算**：`coord` 把缩放后的截图坐标换算回屏幕坐标
- **坐标复核**：`shot --mark x,y` 在截图上画红十字，点击前确认目标
- **只读自检**：`selftest.sh` 不发任何鼠标/键盘事件

## 依赖

- Linux **X11** 会话（Wayland 下仅能操作 XWayland 窗口）
- [`xdotool`](https://github.com/jordansissel/xdotool)
- ImageMagick：`import`、`identify`（缩放与 `--mark` 需要 `convert`）
- `xclip` 或 `xsel`（可选，中文等非 ASCII 输入用；没有时退回 `xdotool type`）

```bash
# Debian / Deepin / Ubuntu
sudo apt install xdotool imagemagick xclip
```

## 安装

**方式一：skills CLI（发布到 GitHub 后）**

```bash
npx skills add <owner>/x11-input-control --skill x11-input-control -g
```

**方式二：手动 clone（通用）**

```bash
git clone <repo-url> ~/.claude/skills/x11-input-control
```

其他 agent 同理：把仓库放进该 agent 的 skills 目录即可，**目录名必须是 `x11-input-control`**（与 `SKILL.md` 的 `name` 一致）。项目级安装可放到 `.claude/skills/x11-input-control`。

## 快速开始

```bash
./scripts/xctrl.sh check                 # 环境探测
./scripts/xctrl.sh shot /tmp/screen.png  # 截屏
./scripts/xctrl.sh click 100 200         # 左键点击
./scripts/xctrl.sh key ctrl+c            # 组合键
./scripts/xctrl.sh type "中文输入"        # 非 ASCII 自动用剪贴板
./scripts/xctrl.sh shot /tmp/check.png --mark 1600,900  # 画十字复核坐标
./scripts/xctrl.sh win search "文件管理"  # 找窗口
```

## 截图与坐标

默认截图使用原生分辨率，图片坐标就是屏幕坐标。使用 `--max-width` 缩小截图后，必须换算坐标：

```bash
$ ./scripts/xctrl.sh shot /tmp/s.png --max-width 1920
saved: /tmp/s.png
image: 1920x1080  screen: 3840x2160  scale: 2.000

$ ./scripts/xctrl.sh coord 800 450 2.0
1600 900
```

`--crop` 截图会额外输出 `crop offset`，屏幕坐标 = 偏移 + 图片坐标 × scale，用 `coord` 的第 4、5 个参数传入偏移。

点击前不确定坐标时，用 `--mark` 在截图上画红十字：

```bash
./scripts/xctrl.sh shot /tmp/check.png --mark 1600,900
```

截图上的十字中心就是 `click 1600 900` 会命中的位置。

## 目录结构

```
x11-input-control/
├── SKILL.md                  # skill 入口（frontmatter + 指令）
├── scripts/
│   ├── xctrl.sh              # 核心脚本
│   └── selftest.sh           # 非破坏性自检
├── references/
│   └── troubleshooting.md    # 排障与已知坑
├── README.md
└── LICENSE
```

## 自检

```bash
./scripts/selftest.sh
```

只做环境检查、截一张测试图并校验尺寸/缩放，**不移动鼠标、不按键**。

## 安全约定

- 未经用户明确要求，不主动移动指针、不点击、不截屏
- 鼠标操作会占用用户真实光标，执行前先告知用户并征得同意
- 点击前先截屏确认目标坐标，不确定时用 `--mark` 画十字复核
- 删除、发送、支付等操作先向用户确认
- 每次操作后截屏验证

## 已知限制

- 纯坐标操作，无 GUI 语义（不识别按钮，只认像素）
- 仅 X11；Wayland 原生窗口不可控
- 非 ASCII 输入依赖 `xclip`/`xsel` 和焦点窗口；终端里粘贴键通常是 `ctrl+shift+v`（见 `references/troubleshooting.md`）
- 4K 屏上截单窗口可能失败，建议 `--crop`

## License

[MIT](LICENSE)
