# niri-ai — 截图 OCR 与智能翻译 / Screenshot OCR & AI Translation

一个面向 [niri](https://github.com/YaLTeR/niri) 窗口管理器的快捷键工具集：
区域截图 → 百度 OCR，区域截图 → Agnes 大模型翻译，以及选中文本 → Agnes 大模型翻译。
每个结果都会在**浮动弹出窗口**中显示（保留源文本的换行结构），并同时复制到剪贴板。

A hotkey toolkit for the niri compositor: region screenshot → Baidu OCR, region
screenshot → Agnes LLM translation, and selected text → Agnes LLM translation.
Every result appears in a **floating popup** (source line breaks preserved) and
is copied to the clipboard.

---

## 功能 / Features

| 快捷键 / Hotkey | 动作 / Action | 说明 / Description |
| --- | --- | --- |
| `Ctrl+Alt+O` | 区域截图 → 百度 OCR | 识别区域文字，浮窗显示 + 复制剪贴板 |
| `Ctrl+Alt+I` | 区域截图 → Agnes 视觉翻译 | 读取图片文字并翻译，浮窗显示 + 复制剪贴板 |
| `Ctrl+Alt+T` | 选中/复制文本 → Agnes 翻译 | 翻译选中文本（PRIMARY，回退 CLIPBOARD） |

- **浮动弹出窗口** (`niri-ai-popup.py`)：GTK3 + GtkLayerShell 覆盖层，金色/深色主题，
  可拖动，`Esc`/`✕` 关闭，金色「复制」按钮；原文与译文分栏显示且**保留换行结构**。
- 译文同时写入剪贴板（`wl-copy`），方便直接粘贴。
- 若 `notify-send` 无守护进程，通知为 no-op——浮窗是主要的可视反馈。

---

## 依赖 / Requirements

| 依赖 / Dependency | 用途 / Used for | Arch/CachyOS 包 / Package |
| --- | --- | --- |
| `niri` | 合成器 / compositor | `niri` |
| `curl` | API 请求 | `curl` |
| `jq` | 解析 API 响应 | `jq` |
| `base64` | 图片编码（视觉输入） | `coreutils` |
| `wl-copy` / `wl-paste` | 剪贴板 | `wl-clipboard` |
| `notify-send` | 通知（可选） | `libnotify` |
| `python3` + `gi` | 浮窗 | `python`, `python-gobject` |
| GTK3 + GtkLayerShell | 浮窗 | `gtk3`, `gtk-layer-shell` |

---

## 安装 / Install

### 方式一：安装脚本 / One-shot installer

```bash
git clone <this-repo-url> ~/niri-ai
cd ~/niri-ai
./install.sh                # 交互式：缺失 secrets 时提示输入
./install.sh --non-interactive   # 使用 ai-secrets.env.example（之后需手动填写）
./install.sh --config /path/to/niri   # 自定义 niri 配置目录
```

脚本会：

1. 检查依赖（缺失时给出 `pacman` 安装提示）。
2. 复制 `niri-ai-helper.sh` 与 `niri-ai-popup.py` 到 `~/.config/niri/scripts/`。
3. 若 `~/.config/niri/scripts/ai-secrets.env` 不存在则创建（交互输入或从示例复制），
   **权限设为 600**。
4. 向 `~/.config/niri/binds.kdl` 幂等添加三个 `Ctrl+Alt+O/I/T` 绑定（不会重复添加）。
5. `niri validate` 校验并 `load-config-file` 热重载配置。

安装是幂等的：重复运行不会覆盖已有 secrets 或重复添加快捷键。

### 方式二：手动安装 / Manual

```bash
# 1. 复制脚本
mkdir -p ~/.config/niri/scripts
cp niri-ai-helper.sh niri-ai-popup.py ~/.config/niri/scripts/
chmod 755 ~/.config/niri/scripts/niri-ai-helper.sh ~/.config/niri/scripts/niri-ai-popup.py

# 2. 配置 secrets
cp ai-secrets.env.example ~/.config/niri/scripts/ai-secrets.env
chmod 600 ~/.config/niri/scripts/ai-secrets.env
$EDITOR ~/.config/niri/scripts/ai-secrets.env   # 填入真实凭据

# 3. 把以下三行加入 ~/.config/niri/binds.kdl 的 binds { ... } 块内：
#    Ctrl+Alt+O repeat=false cooldown-ms=500 hotkey-overlay-title="Baidu OCR screenshot" { spawn "~/.config/niri/scripts/niri-ai-helper.sh" "ocr"; }
#    Ctrl+Alt+I repeat=false cooldown-ms=500 hotkey-overlay-title="Agnes translate screenshot" { spawn "~/.config/niri/scripts/niri-ai-helper.sh" "shot"; }
#    Ctrl+Alt+T repeat=false cooldown-ms=500 hotkey-overlay-title="Agnes translate selection" { spawn "~/.config/niri/scripts/niri-ai-helper.sh" "sel"; }

# 4. 重载配置
niri msg action load-config-file
```

---

## 配置 / Configuration

凭据与参数在 `~/.config/niri/scripts/ai-secrets.env`：

| 变量 / Variable | 默认 / Default | 说明 / Notes |
| --- | --- | --- |
| `BAIDU_CLIENT_ID` | — | 百度 OCR「API Key / Client ID」 |
| `BAIDU_CLIENT_SECRET` | — | 百度 OCR「Secret Key / Client Secret」 |
| `AGNES_API_KEY` | — | Agnes API 密钥 |
| `AGNES_BASE_URL` | `https://api.agnes-ai.cn/v1` | OpenAI 兼容端点 |
| `AGNES_MODEL` | `agnes-2.5-flash` | 翻译模型 |
| `TARGET_LANG` | `Chinese (Simplified)` | 目标语言（用于提示词） |
| `TARGET_CODE` | `zh-CN` | 目标语言代码 |

> 百度 OCR 令牌有效期 30 天，自动缓存于 `~/.cache/niri-ai/baidu_token.json`。

---

## 使用 / Usage

- 按对应快捷键，拖选屏幕区域（截图类）或选中文本（`Ctrl+Alt+T`）。
- 结果浮窗出现后：
  - 「复制」按钮 → 译文写入剪贴板；
  - `Esc` / `✕` → 关闭浮窗；
  - 拖动标题栏 → 移动浮窗。
- 浮窗定位在指针附近，可拖动；无指针信息时居中。

### 换行保留 / Line breaks

翻译提示词明确要求「保留源文本的换行与段落结构」，浮窗用 `Gtk.TextView` 渲染，
**不会折叠换行**——诗歌、代码、列表等多行内容翻译后保持结构。

---

## 架构 / Architecture

```
niri-ai-helper.sh (bash)                      niri-ai-popup.py (python3/GTK3)
┌──────────────────────────────┐              ┌───────────────────────────────┐
│ ocr  → capture_region        │              │ GtkLayerShell overlay         │
│        → baidu_token/ocr     │── JSON ──▶   │  原文 / 译文 TextView (保留换行) │
│ shot → capture_region        │   (temp)     │  复制 / ✕ / 拖动 / Esc         │
│        → base64 → agnes_chat │              └───────────────────────────────┘
│ sel  → wl-paste PRIMARY      │              (setsid 分离启动，独立于 helper)
│        → agnes_chat          │──▶ wl-copy  剪贴板
└──────────────────────────────┘
```

- `capture_region` 调用 `niri msg action screenshot --path`（交互区域选择器），
  轮询等待文件写入——**截图临时文件放在 `$XDG_RUNTIME_DIR/niri-ai`**（合成器可见），
  不要使用被 bwrap 隔离的 `/tmp`。
- `agnes_chat` 使用 OpenAI 兼容 `/chat/completions`；`shot` 通过 `image_url` base64
  data URL 提供视觉输入。
- 浮窗以 `setsid` 分离启动，快捷键绑定脚本退出后仍存活。

---

## 故障排查 / Troubleshooting

| 症状 / Symptom | 处理 / Fix |
| --- | --- |
| `invalid_client`（百度） | 重新核对 `BAIDU_CLIENT_ID`/`SECRET`；清除 `~/.cache/niri-ai/baidu_token.json` |
| OCR/翻译失败 | 检查网络、`AGNES_API_KEY`、`AGNES_BASE_URL` |
| 浮窗不出现 | 确认 `gtk3`、`gtk-layer-shell` 已装：`python3 -c "import gi; gi.require_version('Gtk','3.0'); gi.require_version('GtkLayerShell','0.1')"` |
| 截图后无结果 | 检查 `wl-copy`/`wl-paste` 与剪贴板；确保 `$XDG_RUNTIME_DIR/niri-ai` 可写 |
| 快捷键无效 | `niri validate` 检查；确认 binds.kdl 被 `config.kdl` 引入并 `load-config-file` |

---

## 文件 / Files

```
niri-ai/
├── README.md                # 本说明 / this document
├── install.sh               # 一键安装（幂等）/ idempotent installer
├── niri-ai-helper.sh        # 主脚本：ocr/shot/sel 子命令
├── niri-ai-popup.py         # 浮动结果窗口 (GTK3 + GtkLayerShell)
└── ai-secrets.env.example   # secrets 模板 / credential template
```

安装后位于 `~/.config/niri/scripts/`，快捷键绑定在 `~/.config/niri/binds.kdl`。
