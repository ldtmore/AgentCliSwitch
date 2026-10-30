#!/usr/bin/env bash
# CI 编码守护: 校验各脚本的 BOM 构形 / 换行符 / 纯 ASCII / config JSON 语法
# 规约依据（编码 × 消费路径矩阵）:
#   - 本地 -File / dot-source 的 .ps1 必须带 BOM（PS5.1 无 BOM 按 ANSI 误读中文）
#   - irm|iex 的远程引导必须无 BOM（U+FEFF 粘住首行 token 破坏 iex 解析）
#   - .sh / .mjs / .json 必须无 BOM + 无 CRLF（node JSON.parse 不剥 BOM；bash 把 \r 混入命令）
#   - uninstall-remote.ps1 额外纯 ASCII（对 HTTP charset 与控制台代码页零依赖）
set -u
cd "$(dirname "$0")/../.."
fail=0

# --- 带 BOM 的 .ps1 ---
for f in install.ps1 uninstall.ps1 src/acs-menu.ps1; do
    if ! head -c 3 "$f" | od -An -tx1 | tr -d ' \n' | grep -q '^efbbbf$'; then
        echo "✘ $f 缺少 UTF-8 BOM（PS5.1 本地执行需 BOM）"
        fail=1
    fi
done

# --- 无 BOM 的远程引导 ---
for f in install-remote.ps1 uninstall-remote.ps1; do
    if [ ! -f "$f" ]; then
        echo "✘ 缺少 $f"
        fail=1
        continue
    fi
    if head -c 3 "$f" | od -An -tx1 | tr -d ' \n' | grep -q '^efbbbf$'; then
        echo "✘ $f 不得带 BOM（irm|iex 场景 BOM 破坏 iex 解析）"
        fail=1
    fi
done

# --- 远程卸载引导纯 ASCII（[:print:][:space:] 在 C locale 下即 ASCII 可打印 + 空白） ---
if LC_ALL=C grep -q '[^[:print:][:space:]]' uninstall-remote.ps1; then
    echo "✘ uninstall-remote.ps1 应为纯 ASCII"
    fail=1
fi

# --- .sh/.mjs/.json: 无 BOM + 无 CRLF ---
while IFS= read -r -d '' f; do
    if head -c 3 "$f" | od -An -tx1 | tr -d ' \n' | grep -q '^efbbbf$'; then
        echo "✘ $f 不得带 BOM（node JSON.parse / bash 不剥 BOM）"
        fail=1
    fi
    if LC_ALL=C grep -q "$(printf '\r')" "$f"; then
        echo "✘ $f 含 CRLF（bash 会把 \\r 混入命令）"
        fail=1
    fi
done < <(find src config -type f \( -name '*.sh' -o -name '*.mjs' -o -name '*.json' \) -print0)

# --- config JSON 语法（知识库损坏 = 三端全挂；读取链剥 BOM 以容错） ---
for f in config/clis.json config/suppliers.template.json; do
    if ! node -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8').replace(/^\uFEFF/,''))" "$f"; then
        echo "✘ $f 不是合法 JSON"
        fail=1
    fi
done

if [ "$fail" -eq 0 ]; then echo "✔ 编码规约全部通过"; fi
exit $fail
