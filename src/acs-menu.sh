#!/usr/bin/env bash
# ============================================================================
#  acs-menu.sh - AgentCliSwitch 多 CLI 多供应商切换菜单（Git Bash / mintty）
#  数据文件: ~/.acs/clis.json（CLI 知识库） + ~/.acs/suppliers.json（用户供应商）
#  解析方式: 通过 node 解析标准 JSON（JSON.stringify 写回时中文保持原样）
#  原理: 进程级 export 注入 + unset 退出还原（继承 ccs 生产验证方案）
# ============================================================================

_ACS_VERSION="v0.4.1"
_ACS_DIR="$HOME/.acs"
_ACS_CLIS="$_ACS_DIR/clis.json"
_ACS_DATA="$_ACS_DIR/suppliers.json"
_ACS_LAST="$_ACS_DIR/.last"

# ----------------------------------------------------------------------------
# node 解析辅助
# ----------------------------------------------------------------------------

# 列出 suppliers.json 里配置过的 CLI（每行一个），过滤 _ 开头元数据键
_acs_active_clis() {
    [ -f "$_ACS_DATA" ] || { echo "  ✘ 找不到供应商配置 ~/.acs/suppliers.json（先运行 acs add）" >&2; return 1; }
    command -v node >/dev/null 2>&1 || { echo "  ✘ 需要 node 解析 JSON（请检查 node 安装）" >&2; return 1; }
    node -e '
      const fs = require("fs");
      let j;
      try { j = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); }
      catch (e) { console.error("  ✘ suppliers.json 解析失败: " + e.message); process.exit(1); }
      for (const k of Object.keys(j)) {
        if (k.startsWith("_")) continue;
        const g = j[k];
        if (g && typeof g === "object" && Object.keys(g).length > 0) console.log(k);
      }
    ' "$_ACS_DATA"
}

# 列出某 CLI 组的供应商（key<TAB>desc，official 固定排最前）；$1=cliId
_acs_entries() {
    node -e '
      const fs = require("fs");
      let j;
      try { j = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); }
      catch (e) { console.error("  ✘ suppliers.json 解析失败: " + e.message); process.exit(1); }
      const cli = process.argv[2];
      const g = j[cli];
      if (!g || typeof g !== "object") { console.error("  ✘ 组 " + cli + " 不存在或为空"); process.exit(1); }
      const clean = s => String(s).replace(/[\t\r\n]+/g, " ");
      const out = [];
      if (Object.prototype.hasOwnProperty.call(g, "official"))
        out.push("official\t" + clean((g.official && g.official.desc) || ""));
      for (const k of Object.keys(g)) {
        if (k === "official") continue;
        const e = (g[k] && typeof g[k] === "object" && typeof g[k].desc === "string") ? clean(g[k].desc) : "";
        out.push(clean(k) + "\t" + e);
      }
      if (out.length === 0) { console.error("  ✘ 组 " + cli + " 里没有任何供应商条目"); process.exit(1); }
      console.log(out.join("\n"));
    ' "$_ACS_DATA" "$1"
}

# 输出某 CLI 组出现过的全部 env 变量名（每行一个，动态扩充清理范围）；$1=cliId
_acs_env_names() {
    node -e '
      const fs = require("fs");
      try {
        const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        const g = j[process.argv[2]] || {};
        const names = new Set();
        for (const k of Object.keys(g)) {
          const e = g[k];
          if (e && typeof e === "object" && e.env)
            for (const f of Object.keys(e.env)) names.add(f);
        }
        console.log([...names].join("\n"));
      } catch (e) {}
    ' "$_ACS_DATA" "$1" 2>/dev/null
}

# 输出某供应商的全部 env 对（NUL 分隔 name\0value\0）；$1=cliId $2=provider
_acs_env_pairs() {
    node -e '
      const fs = require("fs");
      try {
        const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        const g = j[process.argv[2]] || {};
        const want = String(process.argv[3]).toLowerCase();
        let e = {};
        for (const k of Object.keys(g)) {
          if (k.toLowerCase() === want) { e = (g[k] && g[k].env) || {}; break; }
        }
        const chunks = [];
        for (const f of Object.keys(e)) chunks.push(f + "\0" + String(e[f]));
        process.stdout.write(chunks.join("\0") + (chunks.length ? "\0" : ""));
      } catch (e) {}
    ' "$_ACS_DATA" "$1" "$2" 2>/dev/null
}

# 输出某 CLI 的预设列表（US(\x1f) 分隔：id desc baseUrl model noBaseUrl protocol envJSON modelFast；\x1f 防空字段塌缩）；$1=cliId
_acs_presets() {
    node -e '
      const fs = require("fs");
      try {
        const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        const d = j[process.argv[2]];
        const ps = (d && d.presets) || {};
        for (const k of Object.keys(ps)) {
          const p = ps[k];
          console.log([k, p.desc || "", p.baseUrl || "", p.model || "", p.noBaseUrl ? "1" : "", p.protocol || "", JSON.stringify(p.env || {}), p.modelFast || ""].join("\u001f"));
        }
      } catch (e) {}
    ' "$_ACS_CLIS" "$1" 2>/dev/null
}

# 写入供应商条目（经环境变量传值，避免特殊字符破坏命令行）；使用 ACS_ADD_* 变量
_acs_write_entry() {
    ACS_ADD_DATA="$_ACS_DATA" node -e '
      const fs = require("fs");
      const env = process.env;
      let j = {};
      try { j = JSON.parse(fs.readFileSync(env.ACS_ADD_DATA, "utf8")); } catch (e) {}
      const cli = env.ACS_ADD_CLI, id = env.ACS_ADD_ID;
      j[cli] = j[cli] && typeof j[cli] === "object" ? j[cli] : {};
      j[cli][id] = JSON.parse(env.ACS_ADD_ENTRY);
      fs.writeFileSync(env.ACS_ADD_DATA, JSON.stringify(j, null, 2) + "\n", "utf8");
    '
}

# ----------------------------------------------------------------------------
# L2 混合适配器：配置预置器（一次性生成，不含密钥；密钥走环境变量注入）
# ----------------------------------------------------------------------------

# Codex 预置（profile v2 机制）：每条目生成独立文件 ~/.codex/acs_<id>.config.toml，
# 并清理主 config.toml 中 legacy 的 acs marker 块；$1=cliId
_acs_preset_toml() {
    node -e '
      const fs = require("fs"), path = require("path"), os = require("os");
      const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const s = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
      const d = j[process.argv[2]];
      const g = s[process.argv[2]] || {};
      const codexDir = path.join(os.homedir(), ".codex");
      // 1. 清理主 config.toml 里的 legacy acs marker 块
      const mainCfg = path.join(codexDir, "config.toml");
      try {
        let raw = fs.readFileSync(mainCfg, "utf8");
        if (raw.includes("# >>> acs managed (do not edit) >>>")) {
          raw = raw.replace(/# >>> acs managed \(do not edit\) >>>[\s\S]*?# <<< acs <<<\n?/, "");
          fs.writeFileSync(mainCfg, raw, "utf8");
        }
      } catch (e) {}
      // 2. 每条目写独立 profile 文件（顶层键 + model_providers 表，加载时叠加在 config.toml 之上）
      let n = 0;
      for (const k of Object.keys(g)) {
        const e = g[k];
        if (!e || typeof e !== "object" || !e.preset) continue;
        const acsId = "acs_" + k;
        const keyVar = String(d.keyEnvPrefix || "").toUpperCase() + "_" + k.toUpperCase() + "_KEY";
        const wire = e.preset.wireApi || d.wireApiDefault || "responses";
        const esc = v => String(v ?? "").replace(/\\/g, "\\\\").replace(/"/g, "\\\"");
        const content = [
          "model = \"" + esc(e.preset.model) + "\"",
          "model_provider = \"" + acsId + "\"",
          "",
          "[model_providers." + acsId + "]",
          "name = \"" + esc(e.desc || "") + "\"",
          "base_url = \"" + esc(e.preset.baseUrl) + "\"",
          "env_key = \"" + keyVar + "\"",
          "wire_api = \"" + wire + "\""
        ].join("\n") + "\n";
        fs.writeFileSync(path.join(codexDir, acsId + ".config.toml"), content, "utf8");
        n++;
      }
      if (n === 0) { console.error("  ⚠ 无 hybrid 型供应商，跳过预置"); process.exit(1); }
      // 3. 清理已删除条目的残留 profile 文件
      try {
        const ids = Object.keys(g);
        for (const f of fs.readdirSync(codexDir)) {
          const m = f.match(/^acs_(.+)\.config\.toml$/);
          if (m && !ids.includes(m[1])) fs.unlinkSync(path.join(codexDir, f));
        }
      } catch (e) {}
    ' "$_ACS_CLIS" "$1" "$_ACS_DATA"
}

# OpenCode 预置：opencode.json 的 provider.acs_*（JSON 命名空间合并）；$1=cliId
_acs_preset_opencode() {
    node -e '
      const fs = require("fs"), path = require("path"), os = require("os");
      const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const s = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
      const d = j[process.argv[2]];
      const g = s[process.argv[2]] || {};
      const cfgPath = String(d.configFile).replace(/^~\//, os.homedir() + "/");
      let obj = {};
      try { obj = JSON.parse(fs.readFileSync(cfgPath, "utf8")); } catch (e) {}
      if (typeof obj !== "object" || obj === null || Array.isArray(obj)) { console.error("  ✘ 配置文件不是 JSON 对象，拒绝写入: " + cfgPath); process.exit(1); }
      if (!obj.provider || typeof obj.provider !== "object") obj.provider = {};
      for (const k of Object.keys(obj.provider)) { if (k.startsWith("acs_")) delete obj.provider[k]; }
      let n = 0;
      for (const k of Object.keys(g)) {
        const e = g[k];
        if (!e || typeof e !== "object" || !e.preset) continue;
        const keyVar = String(d.keyEnvPrefix || "").toUpperCase() + "_" + k.toUpperCase() + "_KEY";
        const npm = e.preset.protocol === "anthropic" ? "@ai-sdk/anthropic" : "@ai-sdk/openai-compatible";
        const models = { [e.preset.model]: { name: e.preset.model } };
        if (e.preset.modelFast) models[e.preset.modelFast] = { name: e.preset.modelFast };
        obj.provider["acs_" + k] = {
          npm: npm, name: e.desc || k,
          options: { baseURL: e.preset.baseUrl, apiKey: "{env:" + keyVar + "}" },
          models: models
        };
        n++;
      }
      if (n === 0) { console.error("  ⚠ 无 hybrid 型供应商，跳过预置"); process.exit(1); }
      fs.mkdirSync(path.dirname(cfgPath), { recursive: true });
      fs.writeFileSync(cfgPath, JSON.stringify(obj, null, 2) + "\n", "utf8");
    ' "$_ACS_CLIS" "$1" "$_ACS_DATA"
}

# Crush 预置：providers.acs_*（$VAR 展开）+ models.large 默认段；$1=cliId
_acs_preset_crush() {
    node -e '
      const fs = require("fs"), path = require("path"), os = require("os");
      const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const s = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
      const d = j[process.argv[2]];
      const g = s[process.argv[2]] || {};
      const cfgPath = String(d.configFile).replace(/^~\//, os.homedir() + "/");
      let obj = {};
      try { obj = JSON.parse(fs.readFileSync(cfgPath, "utf8")); } catch (e) {}
      if (typeof obj !== "object" || obj === null || Array.isArray(obj)) { console.error("  ✘ 配置文件不是 JSON 对象，拒绝写入: " + cfgPath); process.exit(1); }
      if (!obj.providers || typeof obj.providers !== "object") obj.providers = {};
      for (const k of Object.keys(obj.providers)) { if (k.startsWith("acs_")) delete obj.providers[k]; }
      let first = null;
      for (const k of Object.keys(g)) {
        const e = g[k];
        if (!e || typeof e !== "object" || !e.preset) continue;
        const keyVar = String(d.keyEnvPrefix || "").toUpperCase() + "_" + k.toUpperCase() + "_KEY";
        const urlVar = keyVar.replace(/_KEY$/, "_URL");
        if (!first) first = { id: k, model: e.preset.model, fast: e.preset.modelFast || "" };
        const models = [{ id: e.preset.model, name: e.preset.model }];
        if (e.preset.modelFast) models.push({ id: e.preset.modelFast, name: e.preset.modelFast });
        obj.providers["acs_" + k] = {
          name: e.desc || k, type: e.preset.protocol || "openai",
          base_url: "$" + urlVar, api_key: "$" + keyVar,
          models: models
        };
      }
      if (!first) { console.error("  ⚠ 无 hybrid 型供应商，跳过预置"); process.exit(1); }
      const modelsDef = { large: { model: first.model, provider: "acs_" + first.id } };
      if (first.fast) modelsDef.small = { model: first.fast, provider: "acs_" + first.id };
      obj.models = modelsDef;
      fs.mkdirSync(path.dirname(cfgPath), { recursive: true });
      fs.writeFileSync(cfgPath, JSON.stringify(obj, null, 2) + "\n", "utf8");
    ' "$_ACS_CLIS" "$1" "$_ACS_DATA"
}

# 预置器总入口；$1=cliId
_acs_preset() {
    local cli="$1" fmt
    fmt=$(_acs_cli_field "$cli" configFormat)
    case "$fmt" in
        toml) _acs_preset_toml "$cli" ;;
        json)
            case "$cli" in
                opencode) _acs_preset_opencode "$cli" ;;
                crush)    _acs_preset_crush "$cli" ;;
                *) printf '  \e[31m✘ 未知的 json 型 CLI: %s\e[0m\n' "$cli"; return 1 ;;
            esac ;;
        *) printf '  \e[31m✘ 未知配置格式: %s\e[0m\n' "$fmt"; return 1 ;;
    esac
    [ $? -eq 0 ] && printf '  \e[32m✔ 已预置 %s → %s\e[0m\n' "$cli" "$(_acs_cli_field "$cli" configFile)"
}

# Crush 启动前同步默认模型段（models.large 指向选中条目主力，带快速模型时同步 small）；$1=条目id $2=model $3=fast(可选)
_acs_crush_model() {
    node -e '
      const fs = require("fs"), os = require("os");
      const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const d = j.crush;
      if (!d) process.exit(0);
      const cfgPath = String(d.configFile).replace(/^~\//, os.homedir() + "/");
      let obj = {};
      try { obj = JSON.parse(fs.readFileSync(cfgPath, "utf8")); } catch (e) { process.exit(0); }
      if (!obj.models) process.exit(0);
      const models = { large: { model: process.argv[2], provider: "acs_" + process.argv[3] } };
      if (process.argv[4]) models.small = { model: process.argv[4], provider: "acs_" + process.argv[3] };
      obj.models = models;
      fs.writeFileSync(cfgPath, JSON.stringify(obj, null, 2) + "\n", "utf8");
    ' "$_ACS_CLIS" "$2" "$1" "${3:-}" 2>/dev/null
}

# 读取条目 preset 段的某个字段；$1=cliId $2=provider $3=字段名（有 preset 输出值，否则输出空）
_acs_preset_field() {
    node -e '
      const fs = require("fs");
      try {
        const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        const g = j[process.argv[2]] || {};
        const want = String(process.argv[3]).toLowerCase();
        for (const k of Object.keys(g)) {
          if (k.toLowerCase() === want) {
            const p = (g[k] && g[k].preset) || {};
            console.log(String(p[process.argv[4]] ?? ""));
            break;
          }
        }
      } catch (e) {}
    ' "$_ACS_DATA" "$1" "$2" "$3" 2>/dev/null
}

# ----------------------------------------------------------------------------
# 渲染辅助 v2（统一标题 46 显示列；CJK 宽度由 node 精确计算）
# ----------------------------------------------------------------------------

# 用 node 计算显示宽度（CJK/全角按 2 列）；$1=文本
_acs_disp_width() {
    node -e '
      let w = 0;
      for (const ch of String(process.argv[1] ?? "")) {
        const c = ch.codePointAt(0);
        w += ((c>=0x1100&&c<=0x115F)||(c>=0x2E80&&c<=0x303E)||(c>=0x3041&&c<=0x33FF)||(c>=0x3400&&c<=0x4DBF)||
              (c>=0x4E00&&c<=0x9FFF)||(c>=0xA000&&c<=0xA4CF)||(c>=0xAC00&&c<=0xD7A3)||(c>=0xF900&&c<=0xFAFF)||
              (c>=0xFE30&&c<=0xFE4F)||(c>=0xFF00&&c<=0xFF60)||(c>=0xFFE0&&c<=0xFFE6)||(c>=0x1F300&&c<=0x1FAFF)||
              (c>=0x20000)) ? 2 : 1;
      }
      console.log(w);
    ' "$1" 2>/dev/null
}

# 菜单条目一次成型：取条目 + key 列宽 + desc 按 CJK 显示宽度截断（原 entries+menu_rows 两次 node 合并）
# $1=cliId $2=终端宽度；输出：首行=keyw，其后每行 key US 截断desc US 完整desc（US=\x1f）
_acs_menu_entries() {
    ACS_DATA="$_ACS_DATA" ACS_CLI="$1" ACS_TW="${2:-100}" node -e '
      const fs = require("fs");
      const width = s => { let w = 0; for (const ch of s) { const c = ch.codePointAt(0);
        w += ((c>=0x1100&&c<=0x115F)||(c>=0x2E80&&c<=0x303E)||(c>=0x3041&&c<=0x33FF)||(c>=0x3400&&c<=0x4DBF)||
              (c>=0x4E00&&c<=0x9FFF)||(c>=0xA000&&c<=0xA4CF)||(c>=0xAC00&&c<=0xD7A3)||(c>=0xF900&&c<=0xFAFF)||
              (c>=0xFE30&&c<=0xFE4F)||(c>=0xFF00&&c<=0xFF60)||(c>=0xFFE0&&c<=0xFFE6)||(c>=0x1F300&&c<=0x1FAFF)||
              (c>=0x20000)) ? 2 : 1; } return w; };
      const fit = (s, m) => {
        if (m < 2 || width(s) <= m) return s;
        let cut = [...s].slice(0, Math.max(0, m)).join("");
        while (cut.length && width(cut) > m - 2) cut = cut.slice(0, -1);
        return cut + "…";
      };
      let g = {};
      try {
        const j = JSON.parse(fs.readFileSync(process.env.ACS_DATA, "utf8"));
        g = j[process.env.ACS_CLI] || {};
      } catch (e) {}
      const clean = s => String(s).replace(/[\t\r\n\x1f]+/g, " ");
      const rows = [];
      if (Object.prototype.hasOwnProperty.call(g, "official"))
        rows.push(["official", clean((g.official && g.official.desc) || "")]);
      for (const k of Object.keys(g)) {
        if (k === "official") continue;
        const e = (g[k] && typeof g[k] === "object" && typeof g[k].desc === "string") ? clean(g[k].desc) : "";
        rows.push([clean(k), e]);
      }
      if (rows.length === 0) process.exit(0);
      let mw = 10;
      for (const [k] of rows) mw = Math.max(mw, Math.min(14, k.length + 1));
      console.log(String(mw));
      const max = parseInt(process.env.ACS_TW || "100", 10) - mw - 17;
      for (const [k, d] of rows) process.stdout.write(k + "\x1f" + fit(d, max) + "\x1f" + d + "\n");
    '
}

# 统一标题行：  ── 标题 ─────（总显示宽 46 列）+ 可选暗色后缀；$1=标题 $2=后缀(可选) $3=颜色码(默认36青)
_acs_header() {
    local title="$1" suffix="$2" color="${3:-36}" used dash dashstr i
    used=$(( 5 + $(_acs_disp_width "$title") + 1 ))
    dash=$(( 46 - used )); [ "$dash" -lt 3 ] && dash=3
    dashstr=""
    for ((i = 0; i < dash; i++)); do dashstr="${dashstr}─"; done
    printf '  \e[%sm── %s %s\e[0m' "$color" "$title" "$dashstr"
    [ -n "$suffix" ] && printf ' \e[2m%s\e[0m' "$suffix"
    printf '\n'
}

# 向导必填字段输入：空值/校验失败只重问当前字段，不丢弃向导已录入内容（Ctrl+C 退出向导）
# $1=提示(不含▸) $2=可选ERE校验 $3=校验失败提示；提示走 stderr，值走 stdout
_acs_read_required() {
    local prompt="$1" pattern="$2" errmsg="$3" v
    while :; do
        printf '  \e[33m%s ▸ \e[0m' "$prompt" >&2
        IFS= read -r v || { printf '\n' >&2; return 1; }
        if [ -z "$v" ]; then printf '  \e[31m✘ 不能为空，请重新输入（Ctrl+C 退出向导）\e[0m\n' >&2; continue; fi
        if [ -n "$pattern" ] && ! [[ "$v" =~ $pattern ]]; then
            printf '  \e[31m✘ %s，请重新输入\e[0m\n' "${errmsg:-格式不正确}" >&2
            continue
        fi
        printf '%s' "$v"
        return 0
    done
}

# ----------------------------------------------------------------------------
# CLI 元数据批量化（一次 node 调用载入全表，之后 _acs_cli_field 零进程开销）
# ----------------------------------------------------------------------------

# 输出全部 CLI 元数据（US(\x1f) 分隔：id name cmd adapter launchStyle probePath configFormat configFile keyEnvPrefix keyEnv baseUrlEnv modelEnv multiModel baseEnvKeys）
# 用 \x1f 而非 \t：bash read 会把连续 IFS 空白符（含 Tab）塌缩为一个分隔符，空字段会错位
_acs_cli_meta() {
    node -e '
      const fs = require("fs");
      try {
        const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        const F = ["name","cmd","adapter","launchStyle","probePath","configFormat","configFile","keyEnvPrefix","keyEnv","baseUrlEnv","modelEnv","multiModel"];
        for (const k of Object.keys(j)) {
          if (k.startsWith("_")) continue;
          const d = j[k];
          if (!d || typeof d !== "object") continue;
          const row = [k].concat(F.map(f => String(d[f] ?? ""))).concat([(d.baseEnvKeys || []).join(" ")]);
          console.log(row.map(s => s.replace(/[\t\r\n\x1f]+/g, " ")).join("\u001f"));
        }
      } catch (e) {}
    ' "$_ACS_CLIS" 2>/dev/null
}

declare -A _ACS_M_NAME=() _ACS_M_CMD=() _ACS_M_ADAPTER=() _ACS_M_STYLE=() _ACS_M_PROBE=() _ACS_M_FMT=() _ACS_M_CFG=() _ACS_M_PREFIX=() _ACS_M_KEYENV=() _ACS_M_URLENV=() _ACS_M_MODELENV=() _ACS_M_MULTIMODEL=() _ACS_M_BASEKEYS=()
_ACS_M_LOADED=0

# 把元数据表载入关联数组（进程内仅加载一次；US 分隔防 Tab 塌缩）
_acs_load_meta() {
    local id n c a st pr cf cf2 kp ke ue me mm bk
    while IFS=$'\x1f' read -r id n c a st pr cf cf2 kp ke ue me mm bk; do
        [ -z "$id" ] && continue
        _ACS_M_NAME[$id]="$n"; _ACS_M_CMD[$id]="$c"; _ACS_M_ADAPTER[$id]="$a"
        _ACS_M_STYLE[$id]="$st"; _ACS_M_PROBE[$id]="$pr"; _ACS_M_FMT[$id]="$cf"
        _ACS_M_CFG[$id]="$cf2"; _ACS_M_PREFIX[$id]="$kp"; _ACS_M_KEYENV[$id]="$ke"
        _ACS_M_URLENV[$id]="$ue"; _ACS_M_MODELENV[$id]="$me"; _ACS_M_MULTIMODEL[$id]="$mm"
        _ACS_M_BASEKEYS[$id]="$bk"
    done < <(_acs_cli_meta)
    _ACS_M_LOADED=1
}

# 取 CLI 定义字段（带进程内缓存）；$1=cliId $2=字段名
_acs_cli_field() {
    [ "$_ACS_M_LOADED" = 1 ] || _acs_load_meta
    local id="$1" f="$2"
    case "$f" in
        name)         printf '%s' "${_ACS_M_NAME[$id]:-}" ;;
        cmd)          printf '%s' "${_ACS_M_CMD[$id]:-}" ;;
        adapter)      printf '%s' "${_ACS_M_ADAPTER[$id]:-}" ;;
        launchStyle)  printf '%s' "${_ACS_M_STYLE[$id]:-}" ;;
        probePath)    printf '%s' "${_ACS_M_PROBE[$id]:-}" ;;
        configFormat) printf '%s' "${_ACS_M_FMT[$id]:-}" ;;
        configFile)   printf '%s' "${_ACS_M_CFG[$id]:-}" ;;
        keyEnvPrefix) printf '%s' "${_ACS_M_PREFIX[$id]:-}" ;;
        keyEnv)       printf '%s' "${_ACS_M_KEYENV[$id]:-}" ;;
        baseUrlEnv)   printf '%s' "${_ACS_M_URLENV[$id]:-}" ;;
        modelEnv)     printf '%s' "${_ACS_M_MODELENV[$id]:-}" ;;
        multiModel)   printf '%s' "${_ACS_M_MULTIMODEL[$id]:-}" ;;
        baseEnvKeys)  printf '%s' "${_ACS_M_BASEKEYS[$id]:-}" ;;
    esac
}

# ----------------------------------------------------------------------------
# 名称查找与渲染辅助（沿用 ccs）
# ----------------------------------------------------------------------------

# 在 entries 输出($1)中大小写不敏感查找 $2，输出标准 key；找不到返回非 0
_acs_find_key() {
    local k d want="${2,,}"
    while IFS=$'\t' read -r k d; do
        [ -z "$k" ] && continue
        if [ "${k,,}" = "$want" ]; then printf '%s' "$k"; return 0; fi
    done <<< "$1"
    return 1
}

# 输错名字时的前缀建议
_acs_suggest() {
    local k d input="$2"
    while IFS=$'\t' read -r k d; do
        [ -z "$k" ] && continue
        if [[ "$k" == "$input"* || "$input" == "$k"* ]]; then printf '%s' "$k"; return 0; fi
    done <<< "$1"
    return 1
}

# 前缀匹配：输出所有以 $2 开头（不分大小写）的 key（空格分隔）
_acs_prefix_matches() {
    local k d want="${2,,}" out=""
    while IFS=$'\t' read -r k d; do
        [ -z "$k" ] && continue
        if [[ "${k,,}" == "$want"* ]]; then out="$out $k"; fi
    done <<< "$1"
    printf '%s' "${out# }"
}

# key 列自适应宽度（10~14）
_acs_key_width() {
    local w=10 k l _d
    while IFS=$'\t' read -r k _d; do
        [ -z "$k" ] && continue
        l=$(( ${#k} + 1 )); [ "$l" -gt 14 ] && l=14
        [ "$l" -gt "$w" ] && w=$l
    done <<< "$1"
    printf '%s' "$w"
}

# 清理 = clis.json 的 baseEnvKeys ∪ suppliers.json 该组全部 env 变量名；$1=cliId
_acs_clear_env() {
    local v
    for v in $(_acs_cli_field "$1" baseEnvKeys); do unset "$v" 2>/dev/null; done
    while IFS= read -r v; do [ -n "$v" ] && unset "$v" 2>/dev/null; done < <(_acs_env_names "$1")
}

# 画一行供应商。信息层级：desc 显示名为主信息（默认亮色），key 为次要（暗色），序号黄色锚点
# $1=idx $2=idxw $3=key $4=desc $5=last(1/0) $6=keyw $7=note $8=高亮(1/0，方向键模式用，可选)
_acs_row() {
    local mark="" note=""
    [ "$5" = "1" ] && mark=$'  \e[32m● 上次\e[0m'
    [ -n "$7" ] && note=$'  \e[2m'"$7"$'\e[0m'
    if [ "$8" = "1" ]; then
        printf ' \e[33m▸\e[0m \e[33m[%*d]\e[0m \e[36m%-*s\e[0m  \e[36m%s\e[0m%s%s\n' "$2" "$1" "$6" "$3" "$4" "$note" "$mark"
    else
        printf '   \e[33m[%*d]\e[0m \e[2m%-*s\e[0m  %s%s%s\n' "$2" "$1" "$6" "$3" "$4" "$note" "$mark"
    fi
}

# ----------------------------------------------------------------------------
# 通用选择器（方向键高亮 + 行输入混合；非 TTY / ACS_NO_ARROW / 屏幕过小时自动降级）
# ----------------------------------------------------------------------------

# 方向键可用性：非 TTY 或显式关闭时退回行输入
_acs_arrow_ok() {
    [ -n "${ACS_NO_ARROW:-}" ] && return 1
    [ -t 0 ] && [ -t 1 ]
}

# 读一个按键；stdout 输出: up/down/enter/esc/bs/tab/char:<字符>/eof
_acs_read_key() {
    local k k2
    IFS= read -rsn1 k || { printf 'eof'; return; }
    case "$k" in
        '') printf 'enter' ;;
        $'\x1b')
            if IFS= read -rsn1 -t 0.05 k2 2>/dev/null && [ "$k2" = '[' ]; then
                IFS= read -rsn1 -t 0.05 k2 2>/dev/null || { printf 'esc'; return; }
                case "$k2" in
                    A) printf 'up' ;;
                    B) printf 'down' ;;
                    *) printf 'esc' ;;
                esac
            else
                printf 'esc'
            fi ;;
        $'\x7f'|$'\x08') printf 'bs' ;;
        $'\t') printf 'tab' ;;
        *) printf 'char:%s' "$k" ;;
    esac
}

# 通用单选器：绘制行区 + 分隔线 + 提示行 + 交互（渲染走 /dev/tty，返回值走 stdout 供 $() 捕获）
# $1=提示词 $2=hint(方向键模式) $3=行数据(key US desc截断 US note US last 多行；US=\x1f 防 Tab 塌缩) $4=keyw $5=初始高亮
# $6=解析函数名（$1=输入文本；stdout 输出 "ok\t<值>" 或 "err\t<消息>"） $7=LastMark $8=hint(行输入降级模式,可选)
# $9=序号显示基数（默认 0；列表从 1 编号时传 1；供应商菜单固定 0 = 官方通道）
# 返回: 高亮行 key（Enter）/ 解析值 / __ESC__（Esc）/ __EOF__（Ctrl+C/输入结束）
_acs_select() {
    local prompt="$1" hint="$2" rows_s="$3" keyw="$4" init="$5" parsefn="$6" lastmark="$7" hintinput="$8" base="${9:-0}"
    local disp
    # 显示设备探测：/dev/tty 须能真实打开（无控制终端时退回 stderr）
    if { : > /dev/tty; } 2>/dev/null; then disp=/dev/tty; else disp=/dev/stderr; fi
    local -a rkey=() rdesc=() rnote=() rlast=()
    local n=0 rk rd rn rl
    while IFS=$'\x1f' read -r rk rd rn rl; do
        [ -z "$rk" ] && continue
        rkey[$n]="$rk"; rdesc[$n]="$rd"; rnote[$n]="$rn"; rlast[$n]="$rl"
        n=$((n + 1))
    done <<< "$rows_s"
    [ "$n" -gt 0 ] || return 1
    [ -n "$init" ] || init=0
    [ "$init" -ge "$n" ] && init=0
    local idxw=1
    local maxl=$(( base + n - 1 ))
    [ "$maxl" -ge 10 ] && idxw=2
    [ "$maxl" -ge 100 ] && idxw=3

    # 行打印；$1=序号 $2=高亮序号（显示序号 = base + 数组下标；lbl 须在 i 赋值后单独计算，
    # 同一条 local 里 $((base+i)) 会取到外层作用域的旧 i）
    _acs_sel_row() {
        local i="$1" hi="$2" mark="" note="" lbl
        lbl=$(( base + i ))
        [ "${rlast[$i]}" = "1" ] && mark=$'  \e[32m● 上次\e[0m'
        [ -n "${rnote[$i]}" ] && note=$'  \e[2m'"${rnote[$i]}"$'\e[0m'
        if [ "$i" = "$hi" ]; then
            printf ' \e[33m▸\e[0m \e[33m[%*d]\e[0m \e[36m%-*s\e[0m  \e[36m%s\e[0m%s%s\n' "$idxw" "$lbl" "$keyw" "${rkey[$i]}" "${rdesc[$i]}" "$note" "$mark" > "$disp"
        else
            printf '   \e[33m[%*d]\e[0m \e[2m%-*s\e[0m  %s%s%s\n' "$idxw" "$lbl" "$keyw" "${rkey[$i]}" "${rdesc[$i]}" "$note" "$mark" > "$disp"
        fi
    }
    # 提示行
    _acs_sel_prompt() {
        printf '  \e[33m%s \e[0m' "$prompt" > "$disp"
        [ -n "$lastmark" ] && printf '\e[2m%s \e[0m' "$lastmark" > "$disp"
        printf '\e[33m▸ \e[0m' > "$disp"
    }
    # 重绘行区并落回提示行（光标当前须在提示行行首；渲染期间隐藏光标防窜动）
    _acs_sel_redraw() {
        printf '\e[?25l' > "$disp"
        printf '\r\e[%dA' $(( n + 2 )) > "$disp"
        local j
        for ((j = 0; j < n; j++)); do _acs_sel_row "$j" "$hi"; done
        printf '\r\e[2B\e[0K' > "$disp"
        _acs_sel_prompt
        printf '\e[?25h' > "$disp"
    }
    # 差分重绘：↑↓ 移动时只有新旧两行变化，仅重画这两行 + 提示行（相对移动；写入量从整表降到两行）
    _acs_sel_diff() {
        local oldhi="$1" newhi="$2"
        printf '\e[?25l' > "$disp"
        printf '\r\e[%dA' $(( n + 2 - oldhi )) > "$disp"
        _acs_sel_row "$oldhi" "$newhi"
        if [ "$newhi" -gt "$oldhi" ]; then
            printf '\e[%dB' $(( newhi - oldhi - 1 )) > "$disp"
        elif [ "$newhi" -lt "$oldhi" ]; then
            printf '\e[%dA' $(( oldhi - newhi - 1 )) > "$disp"
        fi
        _acs_sel_row "$newhi" "$newhi"
        printf '\r\e[%dB' $(( n + 1 - newhi )) > "$disp"
        _acs_sel_prompt
        printf '\e[?25h' > "$disp"
    }

    local arrow=1
    _acs_arrow_ok || arrow=0
    [ "$arrow" = 1 ] && [ $(( n + 5 )) -ge ${LINES:-24} ] && arrow=0

    # —— 行输入降级模式（行为与旧版一致：画行区 → 旧行输入提示 → 逐行交互）——
    if [ "$arrow" = 0 ]; then
        local text r j
        for ((j = 0; j < n; j++)); do _acs_sel_row "$j" "-1"; done
        printf '\n  \e[2m%s\e[0m\n' "${hintinput:-$hint}" > "$disp"
        while :; do
            _acs_sel_prompt
            IFS= read -r text || { printf '\n' > "$disp"; printf '__EOF__'; return 0; }
            r=$("$parsefn" "$text")
            case "$r" in
                "ok"$'\t'*)  printf '%s' "${r#ok$'\t'}"; return 0 ;;
                "err"$'\t'*) printf '  \e[31m✘ %s\e[0m\n' "${r#err$'\t'}" > "$disp" ;;
            esac
        done
    fi

    # —— 方向键模式 ——
    local hi=$init j r text keyact buf oh
    for ((j = 0; j < n; j++)); do _acs_sel_row "$j" "$hi"; done
    printf '\n  \e[2m%s\e[0m\n' "$hint" > "$disp"
    # 保证提示行下方留有 1 行错误行：下移一行再回升（贴屏底时借此滚动一行），防止交互中滚动使相对重绘错位
    printf '\n\e[1A' > "$disp"
    _acs_sel_prompt
    while :; do
        keyact=$(_acs_read_key)
        case "$keyact" in
            up)    oh=$hi; hi=$(( (hi + n - 1) % n )); _acs_sel_diff "$oh" "$hi" ;;
            down)  oh=$hi; hi=$(( (hi + 1) % n )); _acs_sel_diff "$oh" "$hi" ;;
            enter) printf '\n' > "$disp"; printf '%s' "${rkey[$hi]}"; return 0 ;;
            esc)   printf '\n' > "$disp"; printf '__ESC__'; return 0 ;;
            eof)   printf '\n' > "$disp"; printf '__EOF__'; return 0 ;;
            bs|tab) : ;;
            char:*)
                # 可打印字符进入行输入（readline 预填该字符，继续输入后回车提交）
                buf="${keyact#char:}"
                IFS= read -e -r -i "$buf" text || { printf '\n' > "$disp"; printf '__EOF__'; return 0; }
                r=$("$parsefn" "$text")
                case "$r" in
                    "ok"$'\t'*)
                        printf '%s' "${r#ok$'\t'}"
                        return 0
                        ;;
                    "err"$'\t'*)
                        # 错误行显示在提示行下方（保留可见），光标回到提示行重画
                        printf '\r  \e[31m✘ %s\e[0m\e[0K\r\e[1A\e[0K' "${r#err$'\t'}" > "$disp"
                        _acs_sel_redraw
                        ;;
                    *)
                        printf '\r  \e[31m✘ 解析异常\e[0m\e[0K\r\e[1A\e[0K' > "$disp"
                        _acs_sel_redraw
                        ;;
                esac
                ;;
        esac
    done
}

# claude 官方登录检测：已登录输出邮箱，未登录返回非 0
_acs_official_login() {
    [ -f "$HOME/.claude.json" ] || return 1
    node -e '
      const fs = require("fs");
      try {
        const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        if (j.oauthAccount && j.oauthAccount.emailAddress) { console.log(j.oauthAccount.emailAddress); process.exit(0); }
      } catch (e) {}
      process.exit(1);
    ' "$HOME/.claude.json" 2>/dev/null
}

# acs help：命令一览（按用途分组；左列显示宽度对齐由 node 一次完成，避免逐行起进程）
_acs_help() {
    echo
    _acs_header "acs ${_ACS_VERSION} · 命令一览"
    echo
    printf '  用法: acs [命令 | CLI名] [供应商] [CLI参数…]   名称支持唯一前缀直达\n'
    node -e '
      const width = s => { let w = 0; for (const ch of s) { const c = ch.codePointAt(0);
        w += ((c>=0x1100&&c<=0x115F)||(c>=0x2E80&&c<=0x303E)||(c>=0x3041&&c<=0x33FF)||(c>=0x3400&&c<=0x4DBF)||
              (c>=0x4E00&&c<=0x9FFF)||(c>=0xA000&&c<=0xA4CF)||(c>=0xAC00&&c<=0xD7A3)||(c>=0xF900&&c<=0xFAFF)||
              (c>=0xFE30&&c<=0xFE4F)||(c>=0xFF00&&c<=0xFF60)||(c>=0xFFE0&&c<=0xFFE6)||(c>=0x1F300&&c<=0x1FAFF)||
              (c>=0x20000)) ? 2 : 1; } return w; };
      const groups = [
        ["切换", [
          ["acs", "交互菜单：选 CLI → 选供应商，回车 = 上次组合"],
          ["acs <cli>", "直接进入该 CLI 的供应商菜单"],
          ["acs <cli> <供应商>", "直达启动，如 acs claude glmb"]
        ]],
        ["配置", [
          ["acs add [cli]", "添加供应商向导；-paste 从剪贴板导入环境变量块"],
          ["acs edit <cli> <供应商>", "编辑条目（回车保留原值）"],
          ["acs remove <cli> <供应商>", "删除条目（L2 CLI 联动更新预置）"],
          ["acs import [ccs|capture]", "从 ccs 迁移 / 捕获 Claude 现有配置"],
          ["acs preset [cli]", "重新生成 hybrid CLI 的配置预置段"],
          ["acs recheck <cli> <供应商>", "重新探测端点协议兼容性"]
        ]],
        ["诊断", [
          ["acs list [cli]", "列出供应商配置（脱敏）"],
          ["acs status", "三端挂载体检 + 各 CLI 状态总览"],
          ["acs uninstall", "完全卸载（移除挂载与全部数据）"],
          ["acs help / version", "本帮助 / 版本号"]
        ]]
      ];
      for (const [name, items] of groups) {
        console.log("");
        console.log("  \x1b[36m" + name + "\x1b[0m");
        for (const [cmd, desc] of items) {
          // 目标 30 列须大于最长命令（acs recheck <cli> <供应商> = 27 显示列），否则补格触下限导致右列错位
          let pad = 30 - width(cmd); if (pad < 2) pad = 2;
          console.log("    " + cmd + " ".repeat(pad) + "  " + desc);
        }
      }
    '
    echo
    printf '  \e[2m提示: 菜单内 ↑↓ 选择、Enter 确认、输入序号/名字直达、Esc 返回上级；\e[0m\n'
    printf '  \e[2m      列表序号从 1 开始，供应商菜单中 0 固定为官方通道（official）\e[0m\n'
    printf '  \e[2m提示: 不想使用方向键可设 ACS_NO_ARROW=1（写入 .bashrc）\e[0m\n'
    echo
}

# ----------------------------------------------------------------------------
# 剪贴板解析 / acs import（v0.3）
# ----------------------------------------------------------------------------

# 解析环境变量赋值文本（stdin）→ 输出 NUL 分隔 k\0v 序列
# 支持：export K=V / set K=V / $env:K = "V" / K=V；自动去包裹引号
_acs_parse_env_text() {
    local line t k v
    while IFS= read -r line; do
        t="${line#"${line%%[![:space:]]*}"}"
        case "$t" in
            export\ *) t="${t#export }" ;;
            set\ *)    t="${t#set }" ;;
        esac
        t="${t#\$env:}"
        if [[ "$t" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            k="${BASH_REMATCH[1]}"
            v="${BASH_REMATCH[2]}"
            v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
            [ -n "$k" ] && printf '%s\0%s\0' "$k" "$v"
        fi
    done
}

# clis.json 全部 CLI id（每行一个，过滤 _ 开头元数据）
_acs_all_clis() {
    node -e '
      const fs = require("fs");
      try {
        const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        for (const k of Object.keys(j)) if (!k.startsWith("_")) console.log(k);
      } catch (e) {}
    ' "$_ACS_CLIS" 2>/dev/null
}

# adapter=hybrid 的 CLI id（每行一个）
_acs_hybrid_clis() {
    node -e '
      const fs = require("fs");
      try {
        const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        for (const k of Object.keys(j)) {
          if (!k.startsWith("_") && j[k].adapter === "hybrid") console.log(k);
        }
      } catch (e) {}
    ' "$_ACS_CLIS" 2>/dev/null
}

# 某 CLI 的 hybrid 条目数（带 preset 段的条目）；$1=cliId
_acs_hybrid_entry_count() {
    node -e '
      const fs = require("fs");
      try {
        const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        const g = j[process.argv[2]] || {};
        let n = 0;
        for (const k of Object.keys(g)) {
          if (g[k] && typeof g[k] === "object" && g[k].preset) n++;
        }
        console.log(n);
      } catch (e) { console.log(0); }
    ' "$_ACS_DATA" "$1" 2>/dev/null
}

# acs import：ccs 迁移 + Claude Code 现有配置捕获；$1 = ccs | capture | 空（全部）
_acs_import() {
    local what="${1:-}"
    echo
    _acs_header 'acs import'
    if [ -z "$what" ] || [ "$what" = "ccs" ]; then
        node -e '
          const fs = require("fs"), os = require("os"), path = require("path");
          const ccs = path.join(os.homedir(), ".claude", "suppliers.json");
          const acs = path.join(os.homedir(), ".acs", "suppliers.json");
          if (!fs.existsSync(ccs)) { console.log("  \u2718 未找到 ccs 配置 ~/.claude/suppliers.json（未装过 ccs 则无需迁移）"); process.exit(0); }
          let c, a = {};
          try { c = JSON.parse(fs.readFileSync(ccs, "utf8")); } catch (e) { console.log("  \u2718 ccs 配置解析失败"); process.exit(1); }
          try { a = JSON.parse(fs.readFileSync(acs, "utf8")); } catch (e) {}
          if (!a.claude || typeof a.claude !== "object") a.claude = {};
          let n = 0, skip = 0;
          for (const k of Object.keys(c)) {
            if (k === "official" || !c[k] || typeof c[k] !== "object") continue;
            if (a.claude[k]) { skip++; continue; }
            const env = {};
            let desc = "";
            for (const f of Object.keys(c[k])) {
              if (f === "desc") desc = String(c[k][f]);
              else if (f.startsWith("env:")) env[f.slice(4)] = String(c[k][f]);
            }
            a.claude[k] = { desc: desc, env: env };
            n++;
          }
          fs.writeFileSync(acs, JSON.stringify(a, null, 2) + "\n", "utf8");
          console.log("  \u2714 ccs 迁移完成：导入 " + n + " 条，跳过已存在 " + skip + " 条");
        '
    fi
    if [ -z "$what" ] || [ "$what" = "capture" ]; then
        node -e '
          const fs = require("fs"), os = require("os"), path = require("path");
          const sf = path.join(os.homedir(), ".claude", "settings.json");
          if (!fs.existsSync(sf)) { console.log("  \u2718 未找到 ~/.claude/settings.json（Claude Code 尚未配置过）"); process.exit(0); }
          let url = "", tok = "";
          try {
            const j = JSON.parse(fs.readFileSync(sf, "utf8"));
            if (j.env) {
              url = String(j.env.ANTHROPIC_BASE_URL || "");
              tok = String(j.env.ANTHROPIC_AUTH_TOKEN || j.env.ANTHROPIC_API_KEY || "");
            }
          } catch (e) {}
          if (!url && !tok) { console.log("  \u2718 settings.json 无 ANTHROPIC_* 供应商配置，无需捕获"); process.exit(0); }
          const acs = path.join(os.homedir(), ".acs", "suppliers.json");
          let a = {};
          try { a = JSON.parse(fs.readFileSync(acs, "utf8")); } catch (e) {}
          if (!a.claude || typeof a.claude !== "object") a.claude = {};
          if (a.claude.imported) { console.log("  \u26a0 条目 imported 已存在，跳过"); process.exit(0); }
          const env = {};
          if (url) env.ANTHROPIC_BASE_URL = url;
          if (tok) env.ANTHROPIC_AUTH_TOKEN = tok;
          const host = url ? url.replace(/^https?:\/\//, "").split("/")[0] : "官方";
          a.claude.imported = { desc: "迁移自 settings.json · " + host, env: env };
          fs.writeFileSync(acs, JSON.stringify(a, null, 2) + "\n", "utf8");
          console.log("  \u2714 已捕获为 claude/imported");
        '
    fi
    echo
}

# ----------------------------------------------------------------------------
# acs add 供应商添加向导（L1 纯环境变量 + L2 hybrid；-paste 走剪贴板导入）
# ----------------------------------------------------------------------------
_acs_add() {
    local cli="$1" paste="$2" ids=() choice n i
    # 剪贴板导入分支：解析 export 块 / $env: 块 / .env 内容直接入库（仅 L1 型 CLI）
    if [ -n "$paste" ]; then
        [ -n "$cli" ] || { printf '  \e[33m用法: acs add <cli> -paste（如 acs add claude -paste）\e[0m\n'; return 1; }
        [ -n "$(_acs_cli_field "$cli" baseEnvKeys)" ] || { printf '  \e[31m✘ 剪贴板导入仅支持纯环境变量型 CLI；hybrid 型请走 acs add 向导\e[0m\n'; return 1; }
        local text pairs npairs id2 desc2 entryjson
        text=$(powershell.exe -NoProfile -Command "Get-Clipboard" 2>/dev/null | tr -d '\r')
        [ -n "$text" ] || { printf '  \e[31m✘ 剪贴板为空，请先复制 export 块 / $env: 块 / .env 内容\e[0m\n'; return 1; }
        pairs=$(printf '%s\n' "$text" | _acs_parse_env_text)
        [ -n "$pairs" ] || { printf '  \e[31m✘ 剪贴板内容里没有解析到任何 KEY=VALUE 赋值\e[0m\n'; return 1; }
        npairs=$(( $(printf '%s' "$pairs" | tr -cd '\0' | wc -c) / 2 ))
        printf '  \e[32m✔ 解析到 %d 个变量\e[0m\n' "$npairs"
        printf '  \e[33m供应商 ID（英文短名）▸ \e[0m'; IFS= read -r id2
        [ -n "$id2" ] || { printf '  \e[2m已取消。\e[0m\n'; return 0; }
        printf '  \e[33m显示名 ▸ \e[0m'; IFS= read -r desc2
        [ -n "$desc2" ] || desc2="$id2"
        entryjson=$(ACS_PAIRS="$pairs" ACS_DESC="$desc2" node -e '
          const parts = process.env.ACS_PAIRS.split("\0");
          const env = {};
          for (let i = 0; i + 1 < parts.length; i += 2) env[parts[i]] = parts[i + 1];
          console.log(JSON.stringify({ desc: process.env.ACS_DESC, env: env }));
        ')
        ACS_ADD_CLI="$cli" ACS_ADD_ID="$id2" ACS_ADD_ENTRY="$entryjson" _acs_write_entry || {
            printf '  \e[31m✘ 写入失败\e[0m\n'; return 1; }
        printf '  \e[32m✔ 已导入 %s/%s（%d 个变量）\e[0m\n' "$cli" "$id2" "$npairs"
        return 0
    fi
    # 第一步：确定 CLI（方向键选择器 + 未安装标注；避免为未安装的 CLI 走完向导才发现装不了）
    if [ -z "$cli" ]; then
        mapfile -t ids < <(_acs_all_clis)
        [ "${#ids[@]}" -gt 0 ] || { printf '  \e[31m✘ clis.json 不可用\e[0m\n'; return 1; }
        local rows3="" note3 cname3 ccmd3 c3 l3 keyw3=10 picked3
        for c3 in "${ids[@]}"; do
            note3=""
            ccmd3=$(_acs_cli_field "$c3" cmd)
            command -v "$ccmd3" >/dev/null 2>&1 || note3="未安装"
            cname3=$(_acs_cli_field "$c3" name)
            rows3="${rows3}${c3}"$'\x1f'"${cname3}"$'\x1f'"${note3}"$'\x1f'"0"$'\n'
            l3=$(( ${#c3} + 1 )); [ "$l3" -gt 14 ] && l3=14
            [ "$l3" -gt "$keyw3" ] && keyw3=$l3
        done
        # 解析：精确 id > 序号（add 场景无单键命令；序号从 1 起；行输入回车 = 取消）
        _addcli_parse() {
            local t="$1" c4
            if [ -n "$t" ]; then
                for c4 in "${ids[@]}"; do [ "${c4,,}" = "${t,,}" ] && { printf 'ok\t%s\n' "$c4"; return 0; }; done
                if [[ "$t" =~ ^[0-9]{1,2}$ ]]; then
                    if [ $((10#$t)) -ge 1 ] && [ $((10#$t)) -le "${#ids[@]}" ]; then
                        printf 'ok\t%s\n' "${ids[$((10#$t - 1))]}"; return 0
                    fi
                    printf 'err\t序号超出范围: %s（有效范围 1-%d）\n' "$t" "${#ids[@]}"
                    return 0
                fi
                printf 'err\t未知 CLI: %s\n' "$t"
                return 0
            fi
            printf 'ok\tcancel\n'
        }
        echo
        _acs_header 'acs add · 选择 Agent CLI'
        echo
        picked3=$(_acs_select '选择 CLI' '↑↓ 移动 · Enter 确认 · 输入序号/名字直达 · Esc 取消' "$rows3" "$keyw3" 0 _addcli_parse "" '输入序号或名字直达（回车取消）' 1)
        if [ "$picked3" = "__ESC__" ] || [ "$picked3" = "__EOF__" ] || [ -z "$picked3" ] || [ "$picked3" = "cancel" ]; then
            printf '  \e[2m已取消。\e[0m\n'
            return 0
        fi
        cli="$picked3"
    fi
    # 第二步：选预设（方向键选择器；warn 提示作行尾暗色备注，不进入显示名）
    local presets pline
    presets=$(_acs_presets "$cli")
    [ -n "$presets" ] || { printf '  \e[31m✘ 该 CLI 没有内置预设，请手编 suppliers.json\e[0m\n'; return 1; }
    local rows4="" pw pid pd purl pm pnb pproto penv pmf n4=0 keyw4=10 l4 p4 picked4
    local pids4=()
    while IFS=$'\x1f' read -r pid pd purl pm pnb pproto penv pmf; do
        [ -z "$pid" ] && continue
        pw=$(node -e '
          const fs = require("fs");
          try {
            const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
            const ps = (j[process.argv[2]] || {}).presets || {};
            console.log(String((ps[process.argv[3]] || {}).warn || ""));
          } catch (e) {}
        ' "$_ACS_CLIS" "$cli" "$pid" 2>/dev/null)
        rows4="${rows4}${pid}"$'\x1f'"${pd}"$'\x1f'"${pw}"$'\x1f'"0"$'\n'
        pids4+=("$pid")
        l4=$(( ${#pid} + 1 )); [ "$l4" -gt 14 ] && l4=14
        [ "$l4" -gt "$keyw4" ] && keyw4=$l4
        n4=$((n4 + 1))
    done <<< "$presets"
    # 解析：精确预设 id > 序号（序号从 1 起；行输入回车 = 取消）
    _preset_parse() {
        local t="$1" p5
        if [ -n "$t" ]; then
            for p5 in "${pids4[@]}"; do [ "${p5,,}" = "${t,,}" ] && { printf 'ok\t%s\n' "$p5"; return 0; }; done
            if [[ "$t" =~ ^[0-9]{1,2}$ ]]; then
                if [ $((10#$t)) -ge 1 ] && [ $((10#$t)) -le "$n4" ]; then
                    printf 'ok\t%s\n' "${pids4[$((10#$t - 1))]}"; return 0
                fi
                printf 'err\t序号超出范围: %s（有效范围 1-%d）\n' "$t" "$n4"
                return 0
            fi
            printf 'err\t未知预设: %s\n' "$t"
            return 0
        fi
        printf 'ok\tcancel\n'
    }
    echo
    _acs_header "选择 $(_acs_cli_field "$cli" name) 的供应商预设" "($cli)"
    echo
    picked4=$(_acs_select '选择预设' '↑↓ 移动 · Enter 确认 · 输入序号/名字直达 · Esc 取消' "$rows4" "$keyw4" 0 _preset_parse "" '输入序号或名字直达（回车取消）' 1)
    if [ "$picked4" = "__ESC__" ] || [ "$picked4" = "__EOF__" ] || [ -z "$picked4" ] || [ "$picked4" = "cancel" ]; then
        printf '  \e[2m已取消。\e[0m\n'
        return 0
    fi
    # 重新展开选中预设的完整字段（US 分隔防塌缩）
    local p_id="" p_desc="" p_url="" p_model="" p_nobase="" p_proto="" p_envjson="{}" p_modelFast=""
    while IFS=$'\x1f' read -r pid pd purl pm pnb pproto penv pmf; do
        [ -z "$pid" ] && continue
        if [ "$pid" = "$picked4" ]; then
            p_id="$pid"; p_desc="$pd"; p_url="$purl"; p_model="$pm"; p_nobase="$pnb"; p_proto="$pproto"; p_envjson="$penv"; p_modelFast="$pmf"
            break
        fi
    done <<< "$presets"
    [ -n "$p_id" ] || { printf '  \e[2m已取消。\e[0m\n'; return 0; }

    # 第三步：条目 ID / 显示名 / 端点 / Key / 模型（必填字段循环重试：输错只重问当前字段，Ctrl+C 退出向导）
    local id desc b key m
    id=$(_acs_read_required '供应商 ID（英文短名，如 glmb / ds2）' '^[a-zA-Z0-9_-]+$' 'ID 只能含字母/数字/下划线/中划线') || return 0
    # 显示名默认自动生成「厂商 · 账号」格式，回车即得规范名
    local suggest="$p_desc"
    [ -n "$p_desc" ] && [ "$p_desc" != "$id" ] && suggest="$p_desc · $id" || suggest="$id"
    printf '  \e[33m显示名 [%s] ▸ \e[0m' "$suggest"; IFS= read -r desc
    [ -n "$desc" ] || desc="$suggest"
    local keyEnv urlEnv modelEnv adapter entryjson
    adapter=$(_acs_cli_field "$cli" adapter)
    keyEnv=$(_acs_cli_field "$cli" keyEnv); urlEnv=$(_acs_cli_field "$cli" baseUrlEnv); modelEnv=$(_acs_cli_field "$cli" modelEnv)

    # 询问 API 端点（预设带出可改；noBaseUrl 型跳过）
    b=""
    if [ -n "$p_url" ] && [ "$p_nobase" != "1" ]; then
        printf '  \e[33mAPI 端点 [%s] ▸ \e[0m' "$p_url"; IFS= read -r b
        [ -n "$b" ] || b="$p_url"
    elif [ "$p_nobase" != "1" ]; then
        b=$(_acs_read_required 'API 端点') || return 0
    fi
    # 询问模型（预设带出可改；hybrid 必填；claude 走模型组两问——主力/快速）
    m="$p_model"
    local mmain=""
    if [ "$cli" = "claude" ] && [ "$adapter" = "env" ]; then
        # claude 模型组（M-A）：主力 → OPUS/SONNET 槽位 + ANTHROPIC_MODEL，快速 → HAIKU（回车 = 同主力）
        local pson
        pson=$(ACS_PENV="$p_envjson" node -e '
          try { console.log(String(JSON.parse(process.env.ACS_PENV).ANTHROPIC_DEFAULT_SONNET_MODEL || "")); } catch (e) {}
        ')
        if [ -n "$m" ] || [ -n "$pson" ]; then
            local msug="$m"
            [ -n "$msug" ] || msug="$pson"
            printf '  \e[33m主力模型 [%s] ▸ \e[0m' "$msug"; IFS= read -r mmain
            [ -n "$mmain" ] || mmain="$msug"
        else
            printf '  \e[33m主力模型（回车跳过）▸ \e[0m'; IFS= read -r mmain
        fi
    elif [ -n "$p_model" ]; then
        printf '  \e[33m默认模型 [%s] ▸ \e[0m' "$p_model"; IFS= read -r m
        [ -n "$m" ] || m="$p_model"
    elif [ "$adapter" = "hybrid" ]; then
        m=$(_acs_read_required '模型名') || return 0
    fi
    # 询问 Key（必填）
    local keyVar="$keyEnv"
    if [ "$adapter" = "hybrid" ]; then
        keyVar="$(_acs_cli_field "$cli" keyEnvPrefix | tr '[:lower:]' '[:upper:]')_$(printf '%s' "$id" | tr '[:lower:]' '[:upper:]')_KEY"
    fi
    key=$(_acs_read_required "API Key（$keyVar）") || return 0

    # 协议兼容性探测（probePath 的 CLI 才触发，当前仅 codex）：录入时点告知并引导
    local mode="direct" probePath probe
    probePath=$(_acs_cli_field "$cli" probePath)
    while [ -n "$probePath" ]; do
        printf '  \e[2m⋯ 正在检测端点协议兼容性...\e[0m\n'
        probe=$(_acs_probe_endpoint "$b" "$probePath" "$key")
        if [ "$probe" = "ok" ]; then
            mode="direct"
            printf '  \e[32m✔ 端点协议兼容，直连模式\e[0m\n'
            break
        fi
        if [ "$probe" = "unsupported" ]; then
            printf '  \e[33m✘ 该端点未实现 %s 要求的 %s 接口（404）\e[0m\n' "$(_acs_cli_field "$cli" name)" "$probePath"
            printf '  \e[33m? 处理方式 [1]启用翻译代理(推荐) [2]重新输入端点 [3]仍保存此端点 ▸ \e[0m'; IFS= read -r choice
            if [ "$choice" = "1" ]; then
                mode="proxy"
                printf '  \e[32m✔ 代理模式：启动时自动拉起翻译代理，随会话退出关闭\e[0m\n'
                break
            fi
            if [ "$choice" = "3" ]; then
                mode="direct"
                printf '  \e[33m⚠ 已保存，但该端点不可用于 %s\e[0m\n' "$(_acs_cli_field "$cli" name)"
                break
            fi
            printf '  \e[33mAPI 端点 ▸ \e[0m'; IFS= read -r b
            [ -n "$b" ] || continue
            continue
        fi
        if [ "$probe" = "auth" ]; then
            printf '  \e[33m⚠ Key 校验未通过（401/403），请确认 Key；供应商仍将保存\e[0m\n'
            mode="direct"; break
        fi
        printf '  \e[33m? 探测未完成（网络原因），仍要保存吗? [y/N] ▸ \e[0m'; IFS= read -r choice
        if [ "${choice,,}" = "y" ]; then mode="direct"; break; fi
        printf '  \e[2m已取消。\e[0m\n'
        return 0
    done

    # 快速模型（M-B，multiModel CLI 如 opencode/crush）：写入 preset.modelFast，预置器生成多模型候选
    local mfast=""
    if [ "$(_acs_cli_field "$cli" multiModel)" = "true" ]; then
        if [ -n "$p_modelFast" ]; then
            printf '  \e[33m快速模型 [%s] ▸ \e[0m' "$p_modelFast"; IFS= read -r mfast
            [ -n "$mfast" ] || mfast="$p_modelFast"
        else
            printf '  \e[33m快速模型（可选，回车跳过）▸ \e[0m'; IFS= read -r mfast
        fi
    fi

    # 组装条目 JSON（L1 = env 组；L2 = env 密钥 + preset 元数据段）
    if [ "$adapter" = "hybrid" ]; then
        # 先构造骨架（desc/key 占位空串），再经环境变量安全注入敏感值
        entryjson=$(ACS_BASE="$b" ACS_MODEL="$m" ACS_MFAST="$mfast" ACS_PROTO="${p_proto:-openai}" ACS_WIRE="$(_acs_cli_field "$cli" wireApiDefault)" ACS_KEYVAR="$keyVar" ACS_URLVAR="${keyVar%_KEY}_URL" ACS_MODE="$mode" node -e '
          const env = process.env;
          const e = {};
          if (env.ACS_URLVAR && env.ACS_URLVAR !== env.ACS_KEYVAR) e[env.ACS_URLVAR] = env.ACS_BASE;
          const preset = { baseUrl: env.ACS_BASE, model: env.ACS_MODEL, protocol: env.ACS_PROTO, mode: env.ACS_MODE || "direct" };
          if (env.ACS_WIRE) preset.wireApi = env.ACS_WIRE;
          if (env.ACS_MFAST) preset.modelFast = env.ACS_MFAST;
          console.log(JSON.stringify({ desc: "", env: e, preset: preset }));
        ')
        entryjson=$(ACS_DESC="$desc" ACS_KEY="$key" ACS_PRESET="$entryjson" node -e '
          const p = JSON.parse(process.env.ACS_PRESET);
          p.desc = process.env.ACS_DESC;
          const kv = Object.keys(p.env).find(k => k.endsWith("_KEY"));
          p.env[kv] = process.env.ACS_KEY;
          console.log(JSON.stringify(p));
        ')
    else
        local envjson="$p_envjson"
        if [ -n "$b" ] && [ "$p_nobase" != "1" ]; then
            envjson=$(ACS_E="$envjson" ACS_K="$urlEnv" ACS_V="$b" node -e '
              const e = JSON.parse(process.env.ACS_E); e[process.env.ACS_K] = process.env.ACS_V;
              console.log(JSON.stringify(e)); ')
        fi
        envjson=$(ACS_E="$envjson" ACS_K="$keyEnv" ACS_V="$key" node -e '
          const e = JSON.parse(process.env.ACS_E); e[process.env.ACS_K] = process.env.ACS_V;
          console.log(JSON.stringify(e)); ')
        if [ -n "$p_model" ]; then
            envjson=$(ACS_E="$envjson" ACS_K="$modelEnv" ACS_V="$m" node -e '
              const e = JSON.parse(process.env.ACS_E); e[process.env.ACS_K] = process.env.ACS_V;
              console.log(JSON.stringify(e)); ')
        fi
        # claude 模型组槽位写入（覆盖 preset.env 同名键）
        if [ -n "$mmain" ]; then
            local mfast
            printf '  \e[33m快速模型（回车 = 同主力）▸ \e[0m'; IFS= read -r mfast
            [ -n "$mfast" ] || mfast="$mmain"
            envjson=$(ACS_E="$envjson" ACS_M="$mmain" ACS_F="$mfast" node -e '
              const e = JSON.parse(process.env.ACS_E);
              e.ANTHROPIC_MODEL = process.env.ACS_M;
              e.ANTHROPIC_DEFAULT_OPUS_MODEL = process.env.ACS_M;
              e.ANTHROPIC_DEFAULT_SONNET_MODEL = process.env.ACS_M;
              e.ANTHROPIC_DEFAULT_HAIKU_MODEL = process.env.ACS_F;
              console.log(JSON.stringify(e));
            ')
        fi
        entryjson=$(ACS_DESC="$desc" ACS_E="$envjson" node -e '
          console.log(JSON.stringify({ desc: process.env.ACS_DESC, env: JSON.parse(process.env.ACS_E) }));
        ')
    fi

    # 重复 Key 检测（写入前，排除本条目槽位）：同一把 Key 已存在其他条目时提醒，不阻断
    local duphits
    duphits=$(ACS_DATA="$_ACS_DATA" ACS_CLI="$cli" ACS_ID="$id" ACS_KV="$key" node -e '
      const fs = require("fs");
      try {
        const j = JSON.parse(fs.readFileSync(process.env.ACS_DATA, "utf8"));
        const kv = String(process.env.ACS_KV || "");
        const hits = [];
        if (kv.length >= 10) {
          for (const c of Object.keys(j)) {
            const g = j[c];
            if (!g || typeof g !== "object") continue;
            for (const k of Object.keys(g)) {
              if (c === process.env.ACS_CLI && k.toLowerCase() === process.env.ACS_ID.toLowerCase()) continue;
              const e = g[k];
              if (!e || typeof e !== "object" || !e.env) continue;
              for (const f of Object.keys(e.env)) {
                if (String(e.env[f]) === kv) { hits.push(c + "/" + k); break; }
              }
            }
          }
        }
        console.log([...new Set(hits)].join(" "));
      } catch (e) {}
    ')
    [ -n "$duphits" ] && printf '  \e[33m⚠ 该 Key 与已有条目重复: %s（如非有意请检查）\e[0m\n' "$duphits"

    # 第四步：写入（覆盖前确认；hybrid 联动预置器）
    ACS_ADD_CLI="$cli" ACS_ADD_ID="$id" ACS_ADD_ENTRY="$entryjson" _acs_write_entry || {
        printf '  \e[31m✘ 写入失败\e[0m\n'; return 1; }
    printf '  \e[32m✔ 已写入 %s · 组 %s · 供应商 %s（%s）\e[0m\n' "$_ACS_DATA" "$cli" "$id" "$desc"
    if [ "$adapter" = "hybrid" ]; then _acs_preset "$cli"; fi
}

# ----------------------------------------------------------------------------
# acs edit / acs remove
# ----------------------------------------------------------------------------

# 编辑条目：逐项询问，回车保留原值；hybrid 条目改后联动预置器；$1=cliId $2=provider
_acs_edit() {
    local cli="$1" prov="$2" entryjson
    [ -z "$cli" ] || [ -z "$prov" ] && { printf '  \e[33m用法: acs edit <cli> <provider>\e[0m\n'; return 1; }
    entryjson=$(node -e '
      const fs = require("fs");
      try {
        const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        const g = j[process.argv[2]] || {};
        for (const k of Object.keys(g)) {
          if (k.toLowerCase() === process.argv[3].toLowerCase()) {
            console.log(JSON.stringify({ id: k, entry: g[k] })); break;
          }
        }
      } catch (e) {}
    ' "$_ACS_DATA" "$cli" "$prov" 2>/dev/null)
    [ -n "$entryjson" ] || { printf '  \e[31m✘ 供应商不存在: %s/%s\e[0m\n' "$cli" "$prov"; return 1; }
    local cur desc key baseUrl model v
    cur=$(ACS_E="$entryjson" node -e 'console.log(String(JSON.parse(process.env.ACS_E).entry.desc || ""))')
    printf '  \e[33m显示名 [%s] ▸ \e[0m' "$cur"; IFS= read -r v; desc="${v:-$cur}"
    # key（L1: keyEnv；L2: *_KEY 结尾变量）
    local keyEnv adapter keyVar
    adapter=$(_acs_cli_field "$cli" adapter)
    keyEnv=$(_acs_cli_field "$cli" keyEnv)
    keyVar=$(ACS_E="$entryjson" node -e '
      const e = JSON.parse(process.env.ACS_E).entry.env || {};
      console.log(Object.keys(e).find(k => k.endsWith("_KEY")) || "");
    ')
    [ -n "$keyVar" ] || keyVar="$keyEnv"
    cur=$(ACS_E="$entryjson" ACS_K="$keyVar" node -e 'console.log(String((JSON.parse(process.env.ACS_E).entry.env || {})[process.env.ACS_K] || ""))')
    printf '  \e[33mAPI Key [%s…%s] ▸ \e[0m' "${cur:0:6}" "${cur: -4}"; IFS= read -r v
    key="${v:-$cur}"
    # baseUrl / model（L2 的 preset 段；L1 的 env）
    local entryOut
    if [ "$adapter" = "hybrid" ]; then
        cur=$(ACS_E="$entryjson" node -e 'console.log(String(JSON.parse(process.env.ACS_E).entry.preset?.baseUrl || ""))')
        printf '  \e[33mAPI 端点 [%s] ▸ \e[0m' "$cur"; IFS= read -r v; baseUrl="${v:-$cur}"
        cur=$(ACS_E="$entryjson" node -e 'console.log(String(JSON.parse(process.env.ACS_E).entry.preset?.model || ""))')
        printf '  \e[33m默认模型 [%s] ▸ \e[0m' "$cur"; IFS= read -r v; model="${v:-$cur}"
        # 快速模型（M-B）：multiModel CLI 可改；留空保留原值
        local mfast
        mfast=$(ACS_E="$entryjson" node -e 'console.log(String(JSON.parse(process.env.ACS_E).entry.preset?.modelFast || ""))')
        if [ -n "$mfast" ]; then
            printf '  \e[33m快速模型 [%s] ▸ \e[0m' "$mfast"; IFS= read -r v
            [ -n "$v" ] && mfast="$v"
        elif [ "$(_acs_cli_field "$cli" multiModel)" = "true" ]; then
            printf '  \e[33m快速模型（可选，回车跳过）▸ \e[0m'; IFS= read -r v
            [ -n "$v" ] && mfast="$v"
        fi
        entryOut=$(ACS_E="$entryjson" ACS_D="$desc" ACS_K="$keyVar" ACS_KEY="$key" ACS_B="$baseUrl" ACS_M="$model" ACS_MF="${mfast:-}" node -e '
          const x = JSON.parse(process.env.ACS_E);
          x.entry.desc = process.env.ACS_D;
          x.entry.env[process.env.ACS_K] = process.env.ACS_KEY;
          x.entry.preset.baseUrl = process.env.ACS_B;
          x.entry.preset.model = process.env.ACS_M;
          if (process.env.ACS_MF) x.entry.preset.modelFast = process.env.ACS_MF;
          console.log(JSON.stringify(x.entry));
        ')
    else
        cur=$(ACS_E="$entryjson" ACS_K="$keyEnv" node -e '
          const x = JSON.parse(process.env.ACS_E);
          console.log(String((x.entry.env || {})[process.env.ACS_K] || ""));
        ')
        printf '  \e[33mAPI Key [%s…%s] ▸ \e[0m' "${cur:0:6}" "${cur: -4}"; IFS= read -r v
        key="${v:-$cur}"
        local urlEnv modelEnv url model2 gmain gfast
        urlEnv=$(_acs_cli_field "$cli" baseUrlEnv); modelEnv=$(_acs_cli_field "$cli" modelEnv)
        cur=$(ACS_E="$entryjson" ACS_K="$urlEnv" node -e 'console.log(String((JSON.parse(process.env.ACS_E).entry.env || {})[process.env.ACS_K] || ""))')
        [ -n "$cur" ] && { printf '  \e[33mAPI 端点 [%s] ▸ \e[0m' "$cur"; IFS= read -r v; url="${v:-$cur}"; }
        if [ "$cli" != "claude" ]; then
            cur=$(ACS_E="$entryjson" ACS_K="$modelEnv" node -e 'console.log(String((JSON.parse(process.env.ACS_E).entry.env || {})[process.env.ACS_K] || ""))')
            [ -n "$cur" ] && { printf '  \e[33m默认模型 [%s] ▸ \e[0m' "$cur"; IFS= read -r v; model2="${v:-$cur}"; }
        else
            # claude 模型组（M-A）：主力改动同步三槽位 + ANTHROPIC_MODEL；快速模型可改
            gmain=$(ACS_E="$entryjson" node -e '
              try {
                const e = JSON.parse(process.env.ACS_E).entry.env || {};
                console.log(String(e.ANTHROPIC_MODEL || e.ANTHROPIC_DEFAULT_SONNET_MODEL || ""));
              } catch (x) {}
            ')
            if [ -n "$gmain" ]; then
                printf '  \e[33m主力模型 [%s] ▸ \e[0m' "$gmain"; IFS= read -r v
                [ -n "$v" ] && gmain="$v"
                gfast=$(ACS_E="$entryjson" node -e '
                  try { console.log(String((JSON.parse(process.env.ACS_E).entry.env || {}).ANTHROPIC_DEFAULT_HAIKU_MODEL || "")); } catch (x) {}
                ')
                if [ -n "$gfast" ]; then
                    printf '  \e[33m快速模型 [%s] ▸ \e[0m' "$gfast"; IFS= read -r v
                    [ -n "$v" ] && gfast="$v"
                else
                    printf '  \e[33m快速模型（回车跳过）▸ \e[0m'; IFS= read -r v
                    [ -n "$v" ] && gfast="$v"
                fi
            fi
        fi
        entryOut=$(ACS_E="$entryjson" ACS_D="$desc" ACS_KE="$keyEnv" ACS_KEY="$key" ACS_UE="$urlEnv" ACS_U="${url:-}" ACS_ME="$modelEnv" ACS_M="${model2:-}" ACS_GM="${gmain:-}" ACS_GF="${gfast:-}" node -e '
          const x = JSON.parse(process.env.ACS_E);
          x.entry.desc = process.env.ACS_D;
          if (x.entry.env) {
            x.entry.env[process.env.ACS_KE] = process.env.ACS_KEY;
            if (process.env.ACS_U && process.env.ACS_UE in x.entry.env) x.entry.env[process.env.ACS_UE] = process.env.ACS_U;
            if (process.env.ACS_M && process.env.ACS_ME in x.entry.env) x.entry.env[process.env.ACS_ME] = process.env.ACS_M;
            if (process.env.ACS_GM) {
              x.entry.env.ANTHROPIC_MODEL = process.env.ACS_GM;
              x.entry.env.ANTHROPIC_DEFAULT_OPUS_MODEL = process.env.ACS_GM;
              x.entry.env.ANTHROPIC_DEFAULT_SONNET_MODEL = process.env.ACS_GM;
            }
            if (process.env.ACS_GF) x.entry.env.ANTHROPIC_DEFAULT_HAIKU_MODEL = process.env.ACS_GF;
          }
          console.log(JSON.stringify(x.entry));
        ')
    fi
    local realId
    realId=$(ACS_E="$entryjson" node -e 'console.log(JSON.parse(process.env.ACS_E).id)')
    ACS_ADD_CLI="$cli" ACS_ADD_ID="$realId" ACS_ADD_ENTRY="$entryOut" _acs_write_entry || {
        printf '  \e[31m✘ 写入失败\e[0m\n'; return 1; }
    printf '  \e[32m✔ 已更新 %s/%s\e[0m\n' "$cli" "$realId"
    [ "$adapter" = "hybrid" ] && _acs_preset "$cli"
    return 0
}

# 删除条目：official 不可删；hybrid 条目删后联动预置器；$1=cliId $2=provider
_acs_remove() {
    local cli="$1" prov="$2" sure
    [ -z "$cli" ] || [ -z "$prov" ] && { printf '  \e[33m用法: acs remove <cli> <provider>\e[0m\n'; return 1; }
    [ "${prov,,}" = "official" ] && { printf '  \e[31m✘ official 官方入口不可删除\e[0m\n'; return 1; }
    printf '  \e[33m⚠ 确认删除 %s/%s? (y/N) ▸ \e[0m' "$cli" "$prov"; IFS= read -r sure
    [ "${sure,,}" = "y" ] || { printf '  \e[2m已取消。\e[0m\n'; return 0; }
    ACS_DATA="$_ACS_DATA" node -e '
      const fs = require("fs");
      const env = process.env;
      let j = {};
      try { j = JSON.parse(fs.readFileSync(env.ACS_DATA, "utf8")); } catch (e) { process.exit(1); }
      const g = j[env.ACS_CLI];
      if (!g) process.exit(1);
      for (const k of Object.keys(g)) {
        if (k.toLowerCase() === env.ACS_PROV.toLowerCase()) { delete g[k]; break; }
      }
      fs.writeFileSync(env.ACS_DATA, JSON.stringify(j, null, 2) + "\n", "utf8");
    ' || { printf '  \e[31m✘ 删除失败\e[0m\n'; return 1; }
    ACS_CLI="$cli" ACS_PROV="$prov" node -e '
      const fs = require("os"), f = require("fs");
      const p = require("path").join(fs.homedir(), ".acs", ".last");
      try {
        const c = fs.readFileSync(p, "utf8");
        if (c.startsWith(process.env.ACS_CLI + "\t" + process.env.ACS_PROV + "\t")) fs.unlinkSync(p);
      } catch (e) {}
    ' 2>/dev/null
    printf '  \e[32m✔ 已删除 %s/%s\e[0m\n' "$cli" "$prov"
    local adapter
    adapter=$(_acs_cli_field "$cli" adapter)
    [ "$adapter" = "hybrid" ] && _acs_preset "$cli"
    return 0
}

# 判断条目是否有 env 变量（输出 1/0；避免 command substitution 捕获 NUL 的警告）；$1=cliId $2=provider
_acs_entry_has_env() {
    node -e '
      const fs = require("fs");
      try {
        const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        const g = j[process.argv[2]] || {};
        const want = String(process.argv[3]).toLowerCase();
        for (const k of Object.keys(g)) {
          if (k.toLowerCase() === want) {
            const e = (g[k] && g[k].env) || {};
            console.log(Object.keys(e).length > 0 ? "1" : "0");
            process.exit(0);
          }
        }
      } catch (e) {}
      console.log("0");
    ' "$_ACS_DATA" "$1" "$2" 2>/dev/null
}

# 交互删除（菜单 d 键）：列出全部条目，输入序号 → 二次确认 → 移除（official 不可删）；$1=cliId $2=entries
_acs_remove_interactive() {
    local cli="$1" list="$2" pick target idx key desc mark sure tdesc
    echo
    _acs_header "删除 $cli 供应商" "" 33
    echo
    idx=0
    while IFS=$'\t' read -r key desc; do
        [ -z "$key" ] && continue
        mark=""
        [ "$key" = "official" ] && mark="不可删"
        _acs_row "$idx" 1 "$key" "$desc" 0 10 "$mark"
        idx=$((idx + 1))
    done <<< "$list"
    echo
    printf '  \e[33m输入要删除的序号（回车取消）▸ \e[0m'; IFS= read -r pick
    [ -n "$pick" ] || { printf '  \e[2m已取消。\e[0m\n'; return 0; }
    if ! [[ "$pick" =~ ^[0-9]{1,3}$ ]]; then
        printf '  \e[31m✘ 无效序号: %s\e[0m\n' "$pick"
        return 1
    fi
    target=$(printf '%s\n' "$list" | sed -n "$((10#$pick + 1))p" | cut -f1)
    [ -n "$target" ] || { printf '  \e[31m✘ 无效序号: %s\e[0m\n' "$pick"; return 1; }
    if [ "$target" = "official" ]; then
        printf '  \e[31m✘ official 官方入口不可删除\e[0m\n'
        return 1
    fi
    # 二次确认：Key 是手工录入的资产，误删可能无法恢复
    tdesc=$(printf '%s\n' "$list" | awk -F'\t' -v k="$target" '$1==k{print $2; exit}')
    printf '  \e[33m⚠ 将删除 %s/%s（%s），此操作不可撤销\e[0m\n' "$cli" "$target" "$tdesc"
    printf '  \e[33m确认删除? (y/N) ▸ \e[0m'; IFS= read -r sure
    [ "${sure,,}" = "y" ] || { printf '  \e[2m已取消。\e[0m\n'; return 0; }
    ACS_DATA="$_ACS_DATA" node -e '
      const fs = require("fs");
      const env = process.env;
      let j = {};
      try { j = JSON.parse(fs.readFileSync(env.ACS_DATA, "utf8")); } catch (e) { process.exit(1); }
      const g = j[env.ACS_CLI];
      if (!g) process.exit(1);
      for (const k of Object.keys(g)) {
        if (k.toLowerCase() === env.ACS_PROV.toLowerCase()) { delete g[k]; break; }
      }
      fs.writeFileSync(env.ACS_DATA, JSON.stringify(j, null, 2) + "\n", "utf8");
    ' || { printf '  \e[31m✘ 删除失败\e[0m\n'; return 1; }
    ACS_CLI="$cli" ACS_PROV="$target" node -e '
      const fs = require("fs"), os = require("os");
      const p = require("path").join(os.homedir(), ".acs", ".last");
      try {
        const c = fs.readFileSync(p, "utf8");
        if (c.startsWith(process.env.ACS_CLI + "\t" + process.env.ACS_PROV + "\t")) fs.unlinkSync(p);
      } catch (e) {}
    ' 2>/dev/null
    printf '  \e[32m✔ 已删除 %s/%s\e[0m\n' "$cli" "$target"
    local adapter
    adapter=$(_acs_cli_field "$cli" adapter)
    [ "$adapter" = "hybrid" ] && _acs_preset "$cli"
    return 0
}

# 探测端点协议支持；输出 ok/unsupported/auth/unreachable/unknown
# 状态码语义: 2xx 与 400/405/422=路由存在; 404=不支持; 401/403=Key校验失败; 000=网络不通
_acs_probe_endpoint() {
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -X POST \
        -H "Authorization: Bearer $3" -H "Content-Type: application/json" \
        -d '{"model":"acs-probe","input":"ping","stream":false}' \
        "${1%/}$2" 2>/dev/null)
    case "$code" in
        200|201|400|405|422) printf 'ok' ;;
        404) printf 'unsupported' ;;
        401|403) printf 'auth' ;;
        000) printf 'unreachable' ;;
        *) printf 'unknown' ;;
    esac
}

# 更新条目 preset 段的单个字段（附带 probedAt 时间戳）；$1=cliId $2=provider $3=字段 $4=值
_acs_set_preset_field() {
    ACS_DATA="$_ACS_DATA" node -e '
      const fs = require("fs"), env = process.env;
      try {
        const j = JSON.parse(fs.readFileSync(env.ACS_DATA, "utf8"));
        const g = j[env.ACS_CLI] || {};
        for (const k of Object.keys(g)) {
          if (k.toLowerCase() === env.ACS_PROV.toLowerCase()) {
            g[k].preset = g[k].preset || {};
            g[k].preset[env.ACS_F] = env.ACS_V;
            const d = new Date();
            g[k].preset.probedAt = d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0") + " " + String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0");
            fs.writeFileSync(env.ACS_DATA, JSON.stringify(j, null, 2) + "\n", "utf8");
            process.exit(0);
          }
        }
      } catch (e) {}
      process.exit(1);
    ' "$1" "$2" "$3" "$4"
}

# acs recheck <cli> <provider>：重新探测并更新条目的代理模式
_acs_recheck() {
    local cli="$1" prov="$2" probePath key baseUrl probe mode choice
    [ -z "$cli" ] || [ -z "$prov" ] && { printf '  \e[33m用法: acs recheck <cli> <provider>\e[0m\n'; return 1; }
    probePath=$(_acs_cli_field "$cli" probePath)
    [ -z "$probePath" ] && { printf '  %s 无需协议探测\n' "$cli"; return 0; }
    baseUrl=$(_acs_preset_field "$cli" "$prov" baseUrl)
    [ -z "$baseUrl" ] && { printf '  \e[31m✘ 仅 hybrid 型供应商需要探测\e[0m\n'; return 1; }
    key=$(ACS_DATA="$_ACS_DATA" node -e '
      const fs = require("fs");
      try {
        const j = JSON.parse(fs.readFileSync(process.env.ACS_DATA, "utf8"));
        const g = j[process.argv[1]] || {};
        for (const k of Object.keys(g)) {
          if (k.toLowerCase() === process.argv[2].toLowerCase()) {
            const e = (g[k] && g[k].env) || {};
            for (const f of Object.keys(e)) {
              if (f.endsWith("_KEY")) { console.log(e[f]); process.exit(0); }
            }
          }
        }
      } catch (x) {}
      process.exit(0);
    ' "$cli" "$prov")
    printf '  \e[2m⋯ 正在探测...\e[0m\n'
    probe=$(_acs_probe_endpoint "$baseUrl" "$probePath" "$key")
    mode=$(_acs_preset_field "$cli" "$prov" mode); [ -n "$mode" ] || mode="direct"
    if [ "$probe" = "ok" ]; then
        printf '  \e[32m✔ 端点支持所需协议（直连）\e[0m\n'
        _acs_set_preset_field "$cli" "$prov" "mode" "direct"
    elif [ "$probe" = "unsupported" ]; then
        printf '  \e[33m✘ 端点不支持 %s 要求的 %s 接口（404）\e[0m\n' "$(_acs_cli_field "$cli" name)" "$probePath"
        if [ "$mode" = "proxy" ]; then
            printf '  \e[2m当前已是代理模式，启动时将自动翻译协议\e[0m\n'
        else
            printf '  \e[33m? 切换为本地翻译代理模式? [Y/n] ▸ \e[0m'; IFS= read -r choice
            if [ "${choice,,}" != "n" ]; then
                _acs_set_preset_field "$cli" "$prov" "mode" "proxy"
                printf '  \e[32m✔ 已切换为代理模式\e[0m\n'
            fi
        fi
    elif [ "$probe" = "auth" ]; then
        printf '  \e[33m⚠ Key 校验失败（401/403），请检查 Key 后重试\e[0m\n'
    else
        printf '  \e[33m⚠ 探测未完成（%s），供应商保持 %s 模式\e[0m\n' "$probe" "$mode"
    fi
    return 0
}

# ----------------------------------------------------------------------------
# acs list / acs status
# ----------------------------------------------------------------------------
_acs_list() {
    local cli="$1" active k
    echo
    if [ -n "$cli" ]; then
        local list
        list=$(_acs_entries "$cli") || return 1
        _acs_header "$(_acs_cli_field "$cli" name) 供应商列表" "($cli)"
        echo
        local idx=0 w2 key desc
        w2=$(_acs_key_width "$list")
        while IFS=$'\t' read -r key desc; do
            [ -z "$key" ] && continue
            _acs_row "$idx" 1 "$key" "$desc" 0 "$w2" ""
            idx=$((idx + 1))
        done <<< "$list"
        echo
        printf '  \e[2m✔ %d 项 · %s\e[0m\n' "$(printf '%s\n' "$list" | wc -l)" "$_ACS_DATA"
        echo
        return 0
    fi
    _acs_header 'acs 供应商总览'
    echo
    active=$(_acs_active_clis) || return 1
    while IFS= read -r cli; do
        [ -z "$cli" ] && continue
        printf '  %s \e[2m(%s)\e[0m\n' "$cli" "$(_acs_cli_field "$cli" name)"
        while IFS=$'\t' read -r k d; do
            [ -z "$k" ] && continue
            printf '    %s \e[2m%s\e[0m\n' "$k" "$d"
        done < <(_acs_entries "$cli")
    done <<< "$active"
    echo
    printf '  \e[2m✔ 配置正常 · %s\e[0m\n' "$_ACS_DATA"
    echo
}

# 判断某 CLI 组内是否存在带 env 的实际条目（输出 1/0）；$1=cliId
_acs_group_has_real() {
    ACS_DATA="$_ACS_DATA" ACS_CLI="$1" node -e '
      const fs = require("fs");
      try {
        const j = JSON.parse(fs.readFileSync(process.env.ACS_DATA, "utf8"));
        const g = j[process.env.ACS_CLI] || {};
        for (const k of Object.keys(g)) {
          const e = g[k];
          if (e && typeof e === "object" && e.env && Object.keys(e.env).length > 0) { console.log("1"); process.exit(0); }
        }
      } catch (e) {}
      console.log("0");
    ' 2>/dev/null
}

_acs_status() {
    local active cli k d fp host2 keyEnv urlEnv tok
    local full lastCli lastProv lastTime=""
    echo
    _acs_header 'acs 状态'
    echo
    # 上次使用（cli<TAB>provider<TAB>时间）
    lastCli=""; lastProv=""
    if [ -f "$_ACS_LAST" ]; then
        full="$( < "$_ACS_LAST" )"
        lastCli="${full%%$'\t'*}"
        local tail="${full#*$'\t'}"
        lastProv="${tail%%$'\t'*}"
        [[ "$full" == *$'\t'* ]] && lastTime="${full##*$'\t'}"
    fi
    if [ -n "$lastCli" ]; then
        printf '  上次使用  : %s / %s%s\n' "$lastCli" "$lastProv" "$([ -n "$lastTime" ] && printf ' · %s' "$lastTime")"
    else
        printf '  \e[2m上次使用  : （无记录）\e[0m\n'
    fi
    # 三端挂载检测（Documents 可能被 OneDrive 重定向）
    local doc="" c ps7="✘" ps5="✘" bsh="✘"
    for c in "$USERPROFILE/Documents" "$USERPROFILE/OneDrive/Documents" "$USERPROFILE/OneDrive/文档"; do
        [ -d "$c" ] && doc="$c" && break
    done
    [ -n "$doc" ] || doc="$USERPROFILE/Documents"
    grep -qs "acs-menu.ps1" "$doc/PowerShell/Microsoft.PowerShell_profile.ps1" 2>/dev/null && ps7="✔"
    grep -qs "acs-menu.ps1" "$doc/WindowsPowerShell/Microsoft.PowerShell_profile.ps1" 2>/dev/null && ps5="✔"
    grep -qs "acs-menu.sh" "$HOME/.bashrc" 2>/dev/null && bsh="✔"
    printf '  菜单挂载  : %s · PS7 %s · PS5.1 %s · Git Bash %s\n' "$_ACS_VERSION" "$ps7" "$ps5" "$bsh"
    echo
    # CLI（已安装逐行列出，hybrid 预置状态并入本行；未安装合并为一行——消除独立的"预置状态"段）
    # 注意：计数表命名避开本函数既有的 cnt 局部变量
    printf '  \e[36mCLI\e[0m\n'
    local notinst="" oid pk pv pcfg hcnt inCfg cfgPath2
    local -A pcnt=()
    _acs_load_meta
    while IFS=$'\x1f' read -r pk pv; do
        [ -n "$pk" ] && pcnt[$pk]="$pv"
    done < <(ACS_DATA="$_ACS_DATA" node -e '
      const fs = require("fs");
      try {
        const j = JSON.parse(fs.readFileSync(process.env.ACS_DATA, "utf8"));
        for (const k of Object.keys(j)) {
          if (k.startsWith("_") || !j[k] || typeof j[k] !== "object") continue;
          console.log(k + "\x1f" + Object.keys(j[k]).length);
        }
      } catch (e) {}
    ')
    for oid in $(printf '%s\n' "${!_ACS_M_NAME[@]}" | sort); do
        if ! command -v "${_ACS_M_CMD[$oid]}" >/dev/null 2>&1; then
            notinst="${notinst:+$notinst · }$oid"
            continue
        fi
        pv="${pcnt[$oid]:-0}"
        pcfg="未配置"
        [ "$pv" -gt 0 ] 2>/dev/null && pcfg="$pv 个供应商"
        printf '    %-11s %s · %s' "$oid" "${_ACS_M_NAME[$oid]}" "$pcfg"
        # hybrid 条目预置状态并入概览行（未安装的 hybrid 不占行：未装则预置无意义）
        if [ "${_ACS_M_ADAPTER[$oid]}" = "hybrid" ] && [ "$pv" -gt 0 ] 2>/dev/null; then
            hcnt=$(_acs_hybrid_entry_count "$oid")
            if [ "$oid" = "codex" ]; then
                inCfg=$(ls "$HOME/.codex/"acs_*.config.toml 2>/dev/null | wc -l)
            else
                cfgPath2=$(_acs_cli_field "$oid" configFile); cfgPath2="${cfgPath2/#\~/$HOME}"
                inCfg=0
                [ -f "$cfgPath2" ] && inCfg=$(grep -oE 'acs_[A-Za-z0-9_-]+' "$cfgPath2" 2>/dev/null | wc -l)
            fi
            if [ "$hcnt" -gt 0 ] && [ "$inCfg" -eq 0 ]; then
                printf ' · \e[33m⚠ %d 个未预置\e[0m' "$hcnt"
            elif [ "$hcnt" -gt 0 ]; then
                printf ' \e[2m· 预置已同步\e[0m'
            fi
        fi
        printf '\n'
    done
    [ -n "$notinst" ] && printf '    \e[2m未安装    %s\e[0m\n' "$notinst"
    echo
    # 各 CLI 概览 + 明细 + 重复 Key 检测（跨 CLI；明细按 CLI 分组小标题 + 条目缩进）
    printf '  \e[36m供应商明细\e[0m\n'
    local -A seen=()
    local dups="" onlyoff="" hasreal
    active=$(_acs_active_clis) || return 1
    while IFS= read -r cli; do
        [ -z "$cli" ] && continue
        local list w2
        list=$(_acs_entries "$cli") || continue
        w2=$(_acs_key_width "$list")
        keyEnv=$(_acs_cli_field "$cli" keyEnv)
        urlEnv=$(_acs_cli_field "$cli" baseUrlEnv)
        # 组内全部为官方入口（env 全空）时整组并入汇总行，明细不再逐行展开
        hasreal=$(_acs_group_has_real "$cli")
        if [ "$hasreal" != "1" ]; then
            onlyoff="${onlyoff:+$onlyoff · }$cli"
            continue
        fi
        printf '    %s' "$cli"
        [ -n "${_ACS_M_NAME[$cli]:-}" ] && printf ' \e[2m%s\e[0m' "${_ACS_M_NAME[$cli]}"
        printf '\n'
        while IFS=$'\t' read -r k d; do
            [ -z "$k" ] && continue
            # 指纹/端点一次 node 取回（hybrid 走 *_KEY 变量 + preset.baseUrl，L1 走 keyEnv/baseUrlEnv）
            local tok url tokurl
            tokurl=$(ACS_DATA="$_ACS_DATA" ACS_CLI="$cli" ACS_ENTRY="$k" ACS_K="$keyEnv" ACS_U="$urlEnv" ACS_HYB="$([ "${_ACS_M_ADAPTER[$cli]:-}" = "hybrid" ] && echo 1 || echo 0)" node -e '
              const fs = require("fs");
              try {
                const j = JSON.parse(fs.readFileSync(process.env.ACS_DATA, "utf8"));
                const g = j[process.env.ACS_CLI] || {};
                for (const kk of Object.keys(g)) {
                  if (kk.toLowerCase() === process.env.ACS_ENTRY.toLowerCase()) {
                    const e = g[kk] || {};
                    const env = e.env || {};
                    let tok = "", url = "";
                    if (process.env.ACS_HYB === "1") {
                      for (const f of Object.keys(env)) { if (f.endsWith("_KEY")) { tok = String(env[f]); break; } }
                      url = String((e.preset && e.preset.baseUrl) || "");
                    } else {
                      tok = String(env[process.env.ACS_K] || "");
                      url = String(env[process.env.ACS_U] || "");
                    }
                    process.stdout.write(tok + "\x1f" + url);
                    break;
                  }
                }
              } catch (e) {}
            ' 2>/dev/null)
            tok="${tokurl%%$'\x1f'*}"
            url="${tokurl#*$'\x1f'}"
            if [ -z "$tok" ] && [ -z "$url" ]; then
                printf '      %-*s  OAuth 官方入口\n' "$w2" "$k"
                continue
            fi
            fp="无 Key"
            if [ -n "$tok" ]; then
                if [ "${#tok}" -ge 10 ]; then fp="${tok:0:6}…${tok: -4}"; else fp="Key 过短"; fi
                if [ -n "${seen[$tok]+x}" ]; then
                    dups="${dups:+$dups；}${cli}/${k} 与 ${seen[$tok]}"
                else
                    seen["$tok"]="${cli}/${k}"
                fi
            fi
            host2="$url"
            [[ "$url" =~ ^[a-zA-Z]+://([^/]+) ]] && host2="${BASH_REMATCH[1]}"
            printf '      %-*s %s  → %s\n' "$w2" "$k" "$fp" "$host2"
        done <<< "$list"
    done <<< "$active"
    [ -n "$onlyoff" ] && printf '    \e[2m仅官方入口  %s\e[0m\n' "$onlyoff"
    # 体检结论独立成段，与明细分离
    echo
    printf '  \e[36m体检\e[0m\n'
    if [ -n "$dups" ]; then
        printf '    \e[33m⚠ Key 重复: %s（如非有意，请检查 suppliers.json）\e[0m\n' "$dups"
    else
        printf '    \e[2m✔ 无重复 Key\e[0m\n'
    fi
    # 当前 shell 环境残留检测（手动 export 过或上次异常退出时会干扰 official 入口）
    local leftover="" ac av
    while IFS= read -r ac; do
        [ -z "$ac" ] && continue
        for av in $(_acs_cli_field "$ac" baseEnvKeys); do
            [ -n "${!av+x}" ] && leftover="${leftover:+$leftover、}${ac}/${av}"
        done
    done < <(_acs_all_clis)
    if [ -n "$leftover" ]; then
        printf '    \e[33m⚠ 当前 shell 存在供应商变量残留: %s（acs 拉起时会自动清理；official 入口不受影响）\e[0m\n' "$leftover"
    else
        printf '    \e[2m✔ 当前环境无供应商变量残留\e[0m\n'
    fi
    echo
}

# ----------------------------------------------------------------------------
# 卸载
# ----------------------------------------------------------------------------

# 从单个配置文件移除 acs 挂载块（与 uninstall.ps1 相同 marker）；$1=文件路径
_acs_uninstall_mount() {
    local p="$1"
    [ -f "$p" ] || return 0
    grep -qs '# >>> acs (AgentCliSwitch) >>>' "$p" || return 0
    sed -i '/# >>> acs (AgentCliSwitch) >>>/,/# <<< acs <<</d' "$p"
    printf '  \e[32m✔ 已移除挂载: %s\e[0m\n' "$p"
}

# acs uninstall：完全卸载（移除三端挂载 + ~/.acs 全部数据，回归安装前状态；需确认）
_acs_uninstall() {
    local count=0
    count=$(ACS_DATA="$_ACS_DATA" node -e '
      const fs = require("fs");
      try {
        const j = JSON.parse(fs.readFileSync(process.env.ACS_DATA, "utf8"));
        let n = 0;
        for (const k of Object.keys(j)) {
          if (k.startsWith("_") || !j[k] || typeof j[k] !== "object") continue;
          n += Object.keys(j[k]).length;
        }
        console.log(n);
      } catch (e) { console.log(0); }
    ')
    echo
    _acs_header 'acs 完全卸载' '' 33
    echo
    printf '  将移除：\n'
    printf '    · 三端挂载（PS7 / PS5.1 / Git Bash Profile 中的 acs 挂载块）\n'
    printf '    · 程序文件与全部数据 %s\n' "$_ACS_DIR"
    printf '    \e[33m· suppliers.json 的全部数据（当前 %s 个供应商，含明文 API Key，删除后不可恢复）\e[0m\n' "$count"
    printf '  如需保留供应商配置，请先自行备份该文件后再卸载\n'
    echo
    local r
    printf '  \e[33m确认完全卸载? (y/N) ▸ \e[0m'; IFS= read -r r
    [ "${r,,}" = "y" ] || { printf '  \e[2m已取消。\e[0m\n'; return 0; }
    # 1. 移除三端挂载块（Documents 可能被 OneDrive 重定向）
    local doc="" c
    for c in "$USERPROFILE/Documents" "$USERPROFILE/OneDrive/Documents" "$USERPROFILE/OneDrive/文档"; do
        [ -d "$c" ] && doc="$c" && break
    done
    [ -n "$doc" ] || doc="$USERPROFILE/Documents"
    _acs_uninstall_mount "$doc/PowerShell/Microsoft.PowerShell_profile.ps1"
    _acs_uninstall_mount "$doc/WindowsPowerShell/Microsoft.PowerShell_profile.ps1"
    _acs_uninstall_mount "$HOME/.bashrc"
    # 2. 删除程序文件与全部数据（脚本本体亦在其中，bash 已加载进内存，删除安全）
    if [ -d "$_ACS_DIR" ]; then
        rm -rf "$_ACS_DIR"
        printf '  \e[32m✔ 已删除 %s\e[0m\n' "$_ACS_DIR"
    fi
    echo
    printf '  \e[32m✔ 卸载完成。\e[0m\n'
    printf '  \e[2m当前终端的 acs 命令仍可用至窗口关闭，新开终端即完全还原。\e[0m\n'
    return 0
}

# ----------------------------------------------------------------------------
# 主入口 acs
# ----------------------------------------------------------------------------
acs() {
    local subcmd="${1-}"
    case "${subcmd,,}" in
        add|-a|--add)       _acs_add "$2" "$3"; return $? ;;
        edit|-e|--edit)     _acs_edit "$2" "$3"; return $? ;;
        remove|rm|-r|--remove) _acs_remove "$2" "$3"; return $? ;;
        import|-i|--import) _acs_import "$2"; return $? ;;
        recheck|--recheck)  _acs_recheck "$2" "$3"; return $? ;;
        preset|-p|--preset) _acs_preset "${2:-}"; return $? ;;
        list|-l|--list)     _acs_list "$2"; return $? ;;
        status|-s|--status) _acs_status; return $? ;;
        help|-h|--help)     _acs_help; return 0 ;;
        version|-v|--version) printf '  acs %s\n' "$_ACS_VERSION"; return 0 ;;
        uninstall|--uninstall) _acs_uninstall; return 0 ;;
    esac

    # 空状态引导：还没有配置文件时直接询问是否进入添加向导
    if [ ! -f "$_ACS_DATA" ]; then
        printf '  \e[33m⚠ 还没有任何供应商配置\e[0m\n'
        local r0
        printf '  \e[33m现在就添加供应商吗? (Y/n) ▸ \e[0m'
        IFS= read -r r0 || { echo; return 1; }
        if [ "${r0,,}" != "n" ]; then _acs_add; return $?; fi
        return 1
    fi
    local active cliId="" sel="" lastCli="" lastProv="" full tail
    active=$(_acs_active_clis) || return 1

    # 上次使用记录（cli<TAB>provider<TAB>时间）
    if [ -f "$_ACS_LAST" ]; then
        full="$( < "$_ACS_LAST" )"
        lastCli="${full%%$'\t'*}"
        tail="${full#*$'\t'}"
        lastProv="${tail%%$'\t'*}"
    fi

    # 解析第一个参数：CLI（精确/唯一前缀）
    local rest=() first found pm pc choice list p
    if [ $# -gt 0 ]; then
        first="$1"
        found=$(printf '%s\n' "$active" | while IFS= read -r c; do [ "${c,,}" = "${first,,}" ] && printf '%s' "$c" && break; done)
        if [ -z "$found" ]; then
            pm=$(printf '%s\n' "$active" | while IFS= read -r c; do [[ "${c,,}" == "${first,,}"* ]] && printf '%s ' "$c"; done)
            pc=$(printf '%s' "$pm" | wc -w)
            if [ "$pc" -eq 1 ]; then found="${pm// /}"; found="${found//$'\n'/}"
            elif [ "$pc" -gt 1 ]; then
                printf '  \e[31m✘ %d 个 CLI 前缀匹配: %s\e[0m\n' "$pc" "$pm"
                return 1
            fi
        fi
        if [ -n "$found" ]; then
            cliId="$found"
            shift
            rest=("$@")
        else
            printf '  \e[31m✘ 未配置或未知 CLI: %s（运行 acs help 查看全部命令）\e[0m\n' "$first"
            return 1
        fi
    fi

    # 主流程外层循环：供应商菜单按 b 返回 CLI 选择，重新走一遍
    local goBack=0 backFromProvider=0
    while :; do
    # 无参数：CLI 选择菜单（仅一个已配置组时直接进入；b 返回后强制弹菜单）
    if [ -z "$cliId" ]; then
        local total
        total=$(printf '%s\n' "$active" | wc -l)
        if [ -z "$active" ]; then
            # 空状态引导：直接询问是否进入添加向导
            printf '  \e[33m⚠ suppliers.json 里还没有任何供应商\e[0m\n'
            local r0
            printf '  \e[33m现在就添加供应商吗? (Y/n) ▸ \e[0m'
            IFS= read -r r0 || { echo; return 1; }
            if [ "${r0,,}" != "n" ]; then _acs_add; return $?; fi
            return 0
        fi
        if [ "$total" -eq 1 ] && [ "$backFromProvider" != 1 ]; then
            cliId="$active"
        else
            # 行数据：未安装的 CLI 行尾暗色标注
            local rows="" idx=0 c note cname init=0
            while IFS= read -r c; do
                [ -z "$c" ] && continue
                note=""
                command -v "$(_acs_cli_field "$c" cmd)" >/dev/null 2>&1 || note="未安装"
                cname=$(_acs_cli_field "$c" name)
                rows="${rows}${c}"$'\x1f'"${cname}"$'\x1f'"${note}"$'\x1f'"$([ "$c" = "$lastCli" ] && echo 1 || echo 0)"$'\n'
                idx=$((idx + 1))
            done <<< "$active"
            if [ -n "$lastCli" ] && printf '%s\n' "$active" | grep -qx "$lastCli"; then
                init=$(printf '%s\n' "$active" | awk -v k="$lastCli" '$1==k{print NR-1; exit}')
            fi
            # 解析：精确命中 > 单键命令 > 序号（消除单字母歧义；序号从 1 起，0 保留给供应商菜单官方通道）
            _cli_parse() {
                local t="$1" found c5
                if [ -n "$t" ]; then
                    found=$(printf '%s\n' "$active" | while IFS= read -r c5; do [ "${c5,,}" = "${t,,}" ] && printf '%s' "$c5" && break; done)
                    [ -n "$found" ] && { printf 'ok\t%s\n' "$found"; return 0; }
                    case "$t" in
                        a|A) printf 'ok\tadd\n'; return 0 ;;
                        q|Q) printf 'ok\tquit\n'; return 0 ;;
                    esac
                    if [[ "$t" =~ ^[0-9]{1,2}$ ]]; then
                        if [ $((10#$t)) -ge 1 ] && [ $((10#$t)) -le "$idx" ]; then
                            printf 'ok\t%s\n' "$(printf '%s\n' "$active" | sed -n "$((10#$t))p")"; return 0
                        fi
                        printf 'err\t序号超出范围: %s（有效范围 1-%d）\n' "$t" "$idx"
                        return 0
                    fi
                    printf 'err\t未配置或未知 CLI: %s\n' "$t"
                    return 0
                fi
                if [ -n "$lastCli" ] && printf '%s\n' "$active" | grep -qx "$lastCli"; then
                    printf 'ok\t%s\n' "$lastCli"; return 0
                fi
                printf 'err\t还没有使用记录，请输入序号或名字，或用方向键选择\n'
            }
            echo
            _acs_header 'acs 选择 Agent CLI'
            echo
            local lastmark="" picked
            if [ -n "$lastCli" ] && printf '%s\n' "$active" | grep -qx "$lastCli"; then
                lastmark="[上次 $((init + 1)) ${lastCli}]"
            fi
            picked=$(_acs_select '选择 CLI' '↑↓ 移动 · Enter 确认 · 输入序号/名字直达 · a 添加供应商 · Esc 退出' \
                "$rows" 12 "$init" _cli_parse "$lastmark" '回车 = 上次使用 · 序号或名字直达 · a 添加 · q 退出' 1)
            case "$picked" in
                __ESC__|__EOF__|quit) printf '  \e[2m已取消。\e[0m\n'; return 0 ;;
                add) _acs_add; return $? ;;
                *) cliId="$picked" ;;
            esac
        fi
    fi

    # 供应商列表与选择
    list=$(_acs_entries "$cliId") || return 1
    local lastHere=""
    if [ "${lastCli,,}" = "${cliId,,}" ] && [ -n "$lastProv" ]; then
        lastHere=$(_acs_find_key "$list" "$lastProv")
    fi

    # rest 首元素若匹配供应商（精确/唯一前缀）则直达
    if [ ${#rest[@]} -gt 0 ] && [[ "${rest[0]}" != -* ]] && ! [[ "${rest[0]}" =~ ^[0-9]+$ ]]; then
        p="${rest[0]}"
        found=$(_acs_find_key "$list" "$p")
        if [ -z "$found" ]; then
            pm=$(_acs_prefix_matches "$list" "$p")
            pc=$(printf '%s' "$pm" | wc -w)
            if [ "$pc" -eq 1 ]; then found="$pm"
            elif [ "$pc" -gt 1 ]; then
                printf '  \e[31m✘ %d 个供应商前缀匹配: %s\e[0m\n' "$pc" "$pm"
                return 1
            fi
        fi
        if [ -n "$found" ]; then
            sel="$found"
            rest=("${rest[@]:1}")
        elif [ "${p,,}" = "add" ]; then
            _acs_add "$cliId"; return $?
        fi
    fi

    # 供应商交互菜单（方向键/输入混合选择器；删除后重建行数据重选）
    if [ -z "$sel" ]; then
        local total pfx lidx
        while :; do
            # 行数据：一次 node 完成"取条目 + key 列宽 + CJK 截断"（首行=keyw）
            # 同时重建 $list（key<TAB>完整desc，供解析函数/删除/启动说明使用）
            local keyw=10 first=1 rows2="" rk rd rdf note rl init=0 tw
            local -a m_keys=() m_trunc=() m_full=()
            tw=${COLUMNS:-100}
            list=""
            while IFS=$'\x1f' read -r rk rd rdf; do
                if [ "$first" = 1 ]; then keyw="$rk"; first=0; continue; fi
                [ -z "$rk" ] && continue
                m_keys+=("$rk"); m_trunc+=("$rd"); m_full+=("$rdf")
            done < <(_acs_menu_entries "$cliId" "$tw")
            if [ "${#m_keys[@]}" -eq 0 ]; then
                printf '  \e[33m（%s 已无供应商，可用 acs add %s 重新添加）\e[0m\n' "$cliId" "$cliId"
                return 1
            fi
            local mi
            for ((mi = 0; mi < ${#m_keys[@]}; mi++)); do
                list="${list}${m_keys[$mi]}"$'\t'"${m_full[$mi]}"$'\n'
            done
            total=${#m_keys[@]}
            lastHere=""
            if [ "${lastCli,,}" = "${cliId,,}" ] && [ -n "$lastProv" ]; then
                lastHere=$(_acs_find_key "$list" "$lastProv")
            fi
            rows2=""
            for ((mi = 0; mi < ${#m_keys[@]}; mi++)); do
                note=""
                if [ "${m_keys[$mi]}" = "official" ] && [ "$cliId" = "claude" ]; then
                    _acs_official_login >/dev/null 2>&1 || note="未登录"
                fi
                rl=0
                [ -n "$lastHere" ] && [ "${m_keys[$mi]}" = "$lastHere" ] && rl=1
                rows2="${rows2}${m_keys[$mi]}"$'\x1f'"${m_trunc[$mi]}"$'\x1f'"${note}"$'\x1f'"${rl}"$'\n'
            done
            lidx=-1
            [ -n "$lastHere" ] && lidx=$(printf '%s\n' "$list" | awk -F'\t' -v k="$lastHere" '$1==k{print NR-1; exit}')
            [ "$lidx" -ge 0 ] && init=$lidx
            pfx=""
            [ "$lidx" -ge 0 ] && pfx="[上次 ${lidx} ${lastHere}]"
            # 解析：精确命中 > 单键命令 > 序号/唯一前缀（消除单字母歧义）
            _sup_parse() {
                local t="$1" found pm pc sug
                if [ -n "$t" ]; then
                    found=$(_acs_find_key "$list" "$t")
                    [ -n "$found" ] && { printf 'ok\t%s\n' "$found"; return 0; }
                    case "$t" in
                        a|A) printf 'ok\tadd\n'; return 0 ;;
                        b|B) printf 'ok\tback\n'; return 0 ;;
                        d|D) printf 'ok\tdel\n'; return 0 ;;
                        q|Q) printf 'ok\tquit\n'; return 0 ;;
                    esac
                    if [[ "$t" =~ ^[0-9]{1,3}$ ]]; then
                        if [ $((10#$t)) -lt "$total" ]; then
                            printf 'ok\t%s\n' "$(printf '%s\n' "$list" | sed -n "$((10#$t + 1))p" | cut -f1)"
                            return 0
                        fi
                        printf 'err\t序号超出范围: %s（有效范围 0-%d，0 = 官方通道）\n' "$t" $((total - 1))
                        return 0
                    fi
                    pm=$(_acs_prefix_matches "$list" "$t")
                    pc=$(printf '%s' "$pm" | wc -w)
                    if [ "$pc" -eq 1 ]; then printf 'ok\t%s\n' "$pm"; return 0; fi
                    if [ "$pc" -gt 1 ]; then printf 'err\t%d 个前缀匹配: %s（请输入更多字符）\n' "$pc" "$pm"; return 0; fi
                    sug=$(_acs_suggest "$list" "$t")
                    if [ -n "$sug" ]; then printf 'err\t未知供应商: %s（是不是想输 %s?）\n' "$t" "$sug"
                    else printf 'err\t未知供应商: %s\n' "$t"; fi
                    return 0
                fi
                if [ -n "$lastHere" ]; then printf 'ok\t%s\n' "$lastHere"; return 0; fi
                printf 'err\t还没有使用记录，请输入序号或名字，或用方向键选择\n'
            }
            echo
            _acs_header "$(_acs_cli_field "$cliId" name) 供应商选择" "($cliId)"
            echo
            local hintinput='输入序号或名字直达 · a 添加 · d 删除 · b 返回 · q 退出'
            [ -n "$lastHere" ] && hintinput='回车 = 上次使用 · 序号或名字直达 · a 添加 · d 删除 · b 返回 · q 退出'
            local picked
            picked=$(_acs_select '选择' '↑↓ 移动 · Enter 确认 · 输入序号/名字直达 · a 添加 · d 删除 · Esc 返回' \
                "$rows2" "$keyw" "$init" _sup_parse "$pfx" "$hintinput")
            case "$picked" in
                __ESC__|back)
                    goBack=1
                    break
                    ;;
                __EOF__|quit)
                    printf '  \e[2m已取消。\e[0m\n'
                    return 0
                    ;;
                add) _acs_add "$cliId"; return $? ;;
                del)
                    # d 删除：交互移除（含二次确认）后重选（列表重建由循环顶部完成）
                    _acs_remove_interactive "$cliId" "$list" || true
                    continue
                    ;;
                "") return 0 ;;
                *) sel="$picked" ;;
            esac
            [ -n "$sel" ] && break
        done
    fi

    if [ "$goBack" = 1 ]; then
        goBack=0; backFromProvider=1
        cliId=""; sel=""
        rest=()
        active=$(_acs_active_clis) || return 1
        if [ -z "$active" ]; then
            # b 返回后所有组已空：走空状态引导
            printf '  \e[33m⚠ suppliers.json 里还没有任何供应商\e[0m\n'
            local r0
            printf '  \e[33m现在就添加供应商吗? (Y/n) ▸ \e[0m'
            IFS= read -r r0 || { echo; return 1; }
            if [ "${r0,,}" != "n" ]; then _acs_add; return $?; fi
            return 0
        fi
        continue
    fi
    break
    done

    # 命令存在性检查
    local cmd
    cmd=$(_acs_cli_field "$cliId" cmd)
    command -v "$cmd" >/dev/null 2>&1 || {
        printf '  \e[31m✘ 找不到 %s 命令，请先安装\e[0m\n' "$cmd"
        return 1
    }

    # 记录上次使用
    printf '%s\t%s\t%s\n' "$cliId" "$sel" "$(date '+%Y-%m-%d %H:%M')" > "$_ACS_LAST" 2>/dev/null

    local desc name value
    desc=$(printf '%s\n' "$list" | awk -F'\t' -v k="$sel" '$1==k{print $2; exit}')
    desc=${desc:-$sel}

    if [ "$(_acs_entry_has_env "$cliId" "$sel")" = "0" ]; then
        # official 型条目：清理后拉起，回落 CLI 自身登录态
        _acs_clear_env "$cliId"
        if [ "$cliId" = "claude" ]; then
            _acs_official_login >/dev/null 2>&1 || \
                printf '  \e[33m⚠ 未检测到官方登录，首次将进入登录流程（浏览器 OAuth，只需完成一次）\e[0m\n'
        fi
        printf '  \e[36m▶ 正在启动官方 %s ...\e[0m\n' "$(_acs_cli_field "$cliId" name)"
        command "$cmd" ${rest[@]+"${rest[@]}"}
        printf '\n  \e[2m✔ 会话结束。\e[0m\n'
        # 会话结束引导：教育直达用法，减少下次再走菜单
        printf '  \e[2m下次直达: acs %s %s\e[0m\n' "$cliId" "$sel"
        return 0
    fi

    # 注入 env → 拉起 → unset 还原
    local -a setvars=()
    _acs_clear_env "$cliId"
    while IFS= read -r -d '' name && IFS= read -r -d '' value; do
        export "$name=$value"
        setvars+=("$name")
    done < <(_acs_env_pairs "$cliId" "$sel")

    # hybrid 适配器：构造启动参数 + 代理模式 + 预置缺失检测 + crush 默认模型同步
    local -a launch=()
    local adapter pmodel acsId cfgPath cfgRaw style pmode proxyPid="" portFile="" port i
    adapter=$(_acs_cli_field "$cliId" adapter)
    if [ "$adapter" = "hybrid" ]; then
        pmodel=$(_acs_preset_field "$cliId" "$sel" model)
        if [ -n "$pmodel" ]; then
            acsId="acs_$sel"
            style=$(_acs_cli_field "$cliId" launchStyle)
            pmode=$(_acs_preset_field "$cliId" "$sel" mode)
            if [ "$pmode" = "proxy" ]; then
                # 代理模式：拉起本地翻译代理，base_url 用 -c 命令行覆盖指向代理
                command -v node >/dev/null 2>&1 || {
                    printf '  \e[31m✘ 代理模式需要 node（≥18），请先安装或 acs edit 改用直连端点\e[0m\n'
                    for v in ${setvars[@]+"${setvars[@]}"}; do unset "$v"; done
                    return 1
                }
                portFile="$(mktemp -u "${TMPDIR:-/tmp}/acs-proxy-XXXXXX.port")"
                node "$HOME/.acs/acs-proxy.mjs" --port 0 --upstream "$(_acs_preset_field "$cliId" "$sel" baseUrl)" --ppid $$ --portfile "$portFile" &
                proxyPid=$!
                port=""
                for i in $(seq 1 25); do
                    sleep 0.2
                    [ -f "$portFile" ] && { port="$( < "$portFile" )"; [ -n "$port" ] && break; }
                done
                if [ -z "$port" ]; then
                    printf '  \e[31m✘ 翻译代理启动失败（ACS_PROXY_DEBUG=1 可排查），或 acs edit 改用直连端点\e[0m\n'
                    kill $proxyPid 2>/dev/null
                    for v in ${setvars[@]+"${setvars[@]}"}; do unset "$v"; done
                    return 1
                fi
                printf '  \e[2m⚙ 翻译代理 127.0.0.1:%s（随 Codex 退出自动关闭）\e[0m\n' "$port"
                launch=(-c "model_providers.$acsId.base_url=http://127.0.0.1:$port")
            fi
            case "$style" in
                profile)  launch=(--profile "$acsId" ${launch[@]+"${launch[@]}"}) ;;
                modelArg) launch=(-m "$acsId/$pmodel" ${launch[@]+"${launch[@]}"}) ;;
                envOnly)  [ "$cliId" = "crush" ] && _acs_crush_model "$sel" "$pmodel" "$(_acs_preset_field "$cliId" "$sel" modelFast)" ;;
            esac
            # 预置存在性检测：codex 检查独立 profile 文件；其余检查配置文件中的 acs_ 段
            local needPreset=1
            if [ "$cliId" = "codex" ]; then
                [ -f "$HOME/.codex/$acsId.config.toml" ] && needPreset=0
            else
                cfgPath=$(_acs_cli_field "$cliId" configFile)
                cfgPath="${cfgPath/#\~/$HOME}"
                cfgRaw=""
                [ -f "$cfgPath" ] && cfgRaw="$( < "$cfgPath" )"
                [[ "$cfgRaw" == *"acs_$sel"* ]] && needPreset=0
            fi
            if [ "$needPreset" = "1" ]; then
                printf '  \e[33m⚠ 配置文件缺少预置段，请先运行: acs preset %s\e[0m\n' "$cliId"
                [ -n "$proxyPid" ] && kill $proxyPid 2>/dev/null
                [ -n "$portFile" ] && rm -f "$portFile"
                for v in ${setvars[@]+"${setvars[@]}"}; do unset "$v"; done
                return 1
            fi
        fi
    fi

    printf '  \e[36m▶ 正在以 %s（%s）启动 %s ...\e[0m\n' "$sel" "$desc" "$(_acs_cli_field "$cliId" name)"
    command "$cmd" ${launch[@]+"${launch[@]}"} ${rest[@]+"${rest[@]}"}
    [ -n "$proxyPid" ] && kill $proxyPid 2>/dev/null
    [ -n "$portFile" ] && rm -f "$portFile"
    for v in ${setvars[@]+"${setvars[@]}"}; do unset "$v"; done
    printf '\n  \e[2m✔ 会话结束，已清理临时环境变量。\e[0m\n'
    # 会话结束引导：教育直达用法，减少下次再走菜单
    printf '  \e[2m下次直达: acs %s %s\e[0m\n' "$cliId" "$sel"
}

# Tab 补全: 第 1 参数=子命令+CLI 名；子命令的第二参数=CLI 名；edit/remove/recheck 的第三参数=供应商
_acs_complete() {
    local w1="${COMP_WORDS[1]-}" keys
    if [ "${COMP_CWORD}" -eq 1 ]; then
        keys="$(_acs_active_clis 2>/dev/null | tr '\n' ' ')add edit remove import recheck preset list status help version uninstall "
        COMPREPLY=($(compgen -W "$keys" -- "${COMP_WORDS[COMP_CWORD]}"))
    elif [ "${COMP_CWORD}" -eq 2 ]; then
        case "$w1" in
            add|edit|remove|recheck|list|preset)
                keys="$(_acs_active_clis 2>/dev/null | tr '\n' ' ')" ;;
            *)
                keys="$(_acs_entries "$w1" 2>/dev/null | cut -f1 | tr '\n' ' ')" ;;
        esac
        COMPREPLY=($(compgen -W "$keys" -- "${COMP_WORDS[COMP_CWORD]}"))
    elif [ "${COMP_CWORD}" -eq 3 ]; then
        case "$w1" in
            edit|remove|recheck)
                keys="$(_acs_entries "${COMP_WORDS[2]}" 2>/dev/null | cut -f1 | tr '\n' ' ')"
                COMPREPLY=($(compgen -W "$keys" -- "${COMP_WORDS[COMP_CWORD]}")) ;;
        esac
    fi
    return 0
}
complete -F _acs_complete acs 2>/dev/null
