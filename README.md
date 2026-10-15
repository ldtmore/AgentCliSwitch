# AgentCliSwitch（acs）

**终端里一条命令，切换任意 Agent CLI 的供应商。**

在 Claude Code、Codex、Gemini CLI、Qwen Code、CodeBuddy Code、Kimi Code、iFlow CLI、OpenCode、Crush 等
主流终端 Agent 工具之间，统一管理 API 供应商（官方 / 智谱 GLM / DeepSeek / Kimi / 各类中转站），
一条命令切换，退出自动还原，多窗口并行互不踩踏。

> **状态：v0.4.0**（Windows 三端可用：PowerShell 7 / PowerShell 5.1 / Git Bash）
> 设计前身：[ClaudeCliSupplierSwitch](https://github.com/ldtmore/ClaudeCliSupplierSwitch)
> （ccs，仅支持 Claude Code 的单 CLI 版本），acs 是它的多 CLI 泛化重写。

## 快速上手

**远程一键安装**（PowerShell 中执行；Git Bash / cmd 里可先输 `powershell` 进入）：

```powershell
irm https://raw.githubusercontent.com/ldtmore/AgentCliSwitch/main/install.ps1 | iex
```

**或本地安装**（克隆 / 下载本仓库后，在仓库目录内执行）：

```powershell
./install.ps1
```

安装是幂等的，重复运行安全。装好后：

```powershell
# 1. 新开一个终端
# 2. 添加供应商（向导：选预设 → 填 Key 即完成）
acs add

# 3. 开始切换
acs                # 交互菜单：↑↓ 选择，回车 = 上次组合
acs claude         # 直接进入 Claude Code 的供应商菜单
acs claude glmb    # 直达启动（供应商名支持唯一前缀）
```

## 核心理念

- ✅ **进程级环境变量注入**：供应商配置只注入当前 shell 进程，不碰全局配置
- ✅ **退出自动还原**：会话结束（含 Ctrl+C）自动清理全部临时环境变量
- ✅ **多窗口并行**：不同终端标签页同时跑不同供应商/账号，互不干扰
- ✅ **零依赖零常驻**：纯 PowerShell + Bash 脚本，无安装包、无后台进程、可审计
- ✅ **数据与逻辑分离**：脚本不硬编码任何供应商，加账号 = 改一份 JSON
- ✅ **免手编配置**：`acs add` 内置供应商预设 + 剪贴板导入 + ccs 迁移，手编 JSON 只是高级选项

## 交互与命令

菜单交互：**↑↓ 移动高亮、Enter 确认、输入序号/名字直达、Esc 返回上级**；列表序号从 1 开始，
供应商菜单中 `0` 固定为官方通道（official）。非交互环境（管道/重定向）或设置 `ACS_NO_ARROW=1`
时自动降级为纯行输入。终端内随时 `acs help` 查看全部命令。

| 命令 | 行为 |
|---|---|
| `acs` | 交互菜单：选 CLI → 选供应商，回车 = 上次组合 |
| `acs <cli>` | 直接进入该 CLI 的供应商菜单 |
| `acs <cli> <供应商>` | 直达启动，如 `acs claude glmb` |
| `acs add [cli]` | 添加供应商向导；`-paste` 从剪贴板导入环境变量块 |
| `acs edit <cli> <供应商>` | 编辑条目（回车保留原值） |
| `acs remove <cli> <供应商>` | 删除条目（L2 CLI 联动更新预置） |
| `acs import [ccs\|capture]` | 从 ccs 迁移 / 捕获 Claude 现有配置 |
| `acs recheck <cli> <供应商>` | 重新探测端点协议兼容性 |
| `acs preset [cli]` | 重新生成 hybrid CLI 的配置预置段 |
| `acs list [cli]` | 列出供应商配置（脱敏） |
| `acs status` | 三端挂载体检 + 各 CLI 状态总览 |

## 供应商模型组（v0.4）

一个供应商通常不止一个模型。添加/编辑供应商时可配置**主力 + 快速**两个模型，acs 按各 CLI
的机制落到正确位置，会话内照常使用 `/model` 切换：

- **Claude Code**：主力 → `ANTHROPIC_DEFAULT_OPUS/SONNET`，快速 → `ANTHROPIC_DEFAULT_HAIKU`；
  同时注入 `ANTHROPIC_MODEL` 保证每次启动回到主力（其优先级高于 `/model` 写入全局配置的保存值）
- **OpenCode / Crush**：provider 下写入多模型候选（`models` map / 数组），默认指向主力
  （Crush 同步 `models.large/small`）
- **Codex 等其余 CLI**：暂为单默认模型（各 CLI 会话内切换机制在持续调研核实中）

## 支持矩阵

| 梯队 | CLI | 接入方式 | 状态 |
|---|---|---|---|
| L1 纯环境变量 | Claude Code | `ANTHROPIC_*` | ✅ 已验证（ccs 继承） |
| L1 纯环境变量 | Gemini CLI | `GEMINI_API_KEY` + `GOOGLE_GEMINI_BASE_URL`（env 自动切认证类型） | 📋 已核实（源码级） |
| L1 纯环境变量 | Qwen Code | `OPENAI_API_KEY` + `OPENAI_BASE_URL` | 📋 已核实（官方文档） |
| L1 纯环境变量 | CodeBuddy Code | `CODEBUDDY_API_KEY` + `CODEBUDDY_BASE_URL` | 📋 已核实（官方文档） |
| L1 纯环境变量 | iFlow CLI | `IFLOW_API_KEY` + `IFLOW_BASE_URL` | 📋 已核实（官方文档） |
| L1 纯环境变量 | Kimi Code | `KIMI_MODEL_*`（内存合成临时供应商，免配置） | 📋 已核实（官方文档） |
| L2 混合方案 | Codex | TOML marker 预置 + `env_key` + `codex --profile` | ✅ 已实现 |
| L2 混合方案 | OpenCode | JSON 命名空间预置 + `{env:VAR}` + `opencode -m` | ✅ 已实现 |
| L2 混合方案 | Crush | JSON 预置（`$VAR` 展开）+ 默认模型段落盘同步 | ✅ 已实现（多窗口并行受限） |

L2 说明：预置只写 base_url 与密钥变量指针（不含密钥），密钥本体仍只在 suppliers.json
与进程环境变量中。各 CLI 接入方式均经官方文档 / 源码级核实。

## 与现有方案的差异化

| 对比对象 | 缺什么 | acs 补什么 |
|---|---|---|
| cc-switch 生态（桌面版 14 万星 / CLI 版 5 千星） | 改全局配置文件，同一时刻全局只有一个供应商生效；不支持国产 CLI | 进程级并行多账号；国产 CLI 全覆盖（CodeBuddy / Kimi / Qwen / iFlow） |
| ccs（本项目前身） | 仅支持 Claude Code | 多 CLI 统一菜单、统一配置格式 |

## 目录结构

| 路径 | 说明 |
|---|---|
| `src/acs-menu.ps1` / `src/acs-menu.sh` | 双端主脚本（交互菜单、适配器、预置器） |
| `src/acs-proxy.mjs` | Codex 本地协议翻译代理（Responses → Chat Completions，随会话启动/自动退出） |
| `config/clis.json` | CLI 知识库（随 acs 分发，用户一般不改） |
| `config/suppliers.template.json` | 用户数据模板（首次安装生成 suppliers.json） |
| `install.ps1` / `uninstall.ps1` | 幂等安装 / 卸载（卸载默认保留用户数据） |

## 安全

- `suppliers.json` 内是明文 API Key：文档警示不提交 git、不外发截图；`.gitignore` 防御性排除
- `acs list` / `acs status` 默认脱敏（只显示 Key 指纹）
- L2 预置块不含密钥，配置文件可以正常纳入用户自己的同步/备份

## 卸载

终端内执行（移除三端挂载与 `~\.acs\` 全部数据，**含 API Key、不可恢复**，需 y/N 确认）：

```powershell
acs uninstall
```

或使用独立卸载脚本（默认**保留** suppliers.json 供应商数据，`-Purge` 才连数据一起删）：

```powershell
# 本地仓库
./uninstall.ps1

# 远程
irm https://raw.githubusercontent.com/ldtmore/AgentCliSwitch/main/uninstall.ps1 | iex
```

卸载后当前已开终端里的 `acs` 命令仍可用至窗口关闭，新开终端即完全还原。

## License

MIT
