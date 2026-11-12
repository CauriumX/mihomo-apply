#!/usr/bin/env bash
# ============================================================================
# release.sh — 发布一个版本
#
# 把 mihomo-rules 的产物 + mihomo-template 的模板源，渲染成一个不可变版本目录：
#
#   v0.1.0/
#     site/*.mrs          19 个域名规则集
#     geoip/*.mrs         3 个 IP 规则集
#     Crypto.mrs
#     PayPal.txt
#     PayPal-Phish.txt
#     template.yaml       渲染后的模板（URL 已指向 v0.1.0）
#     MANIFEST.json       所有产物的 sha256
#   latest -> v0.1.0
#   VERSION
#
# 用法：
#   bash release.sh <version> [--rules-dir DIR] [--template-dir DIR]
#
# 例：
#   bash release.sh v0.1.0
#   bash release.sh v0.1.0 --rules-dir ../mihomo-rules --template-dir ../mihomo-template
#
# 环境变量：
#   RULES_DIR       mihomo-rules 仓库路径（默认 ../mihomo-rules）
#   TEMPLATE_DIR    mihomo-template 仓库路径（默认 ../mihomo-template）
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "用法: bash release.sh <version> [--rules-dir DIR] [--template-dir DIR]" >&2
    exit 2
fi

# 版本号格式：vX.Y.Z
if ! [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "错误：版本号必须形如 v0.1.0，实际 '$VERSION'" >&2
    exit 2
fi

shift
RULES_DIR="${RULES_DIR:-../mihomo-rules}"
TEMPLATE_DIR="${TEMPLATE_DIR:-../mihomo-template}"

while [ $# -gt 0 ]; do
    case "$1" in
        --rules-dir)    RULES_DIR="$2"; shift 2 ;;
        --template-dir) TEMPLATE_DIR="$2"; shift 2 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 前置检查
# ---------------------------------------------------------------------------
log "检查输入"

[ -d "$RULES_DIR/ruleset" ] || { bad "找不到 $RULES_DIR/ruleset"; exit 1; }
[ -f "$TEMPLATE_DIR/templates/mihomo.yaml" ] || { bad "找不到模板源"; exit 1; }

# 版本由 git tag 表达，目录不重复版本号。
# 已发布版本不可变：如果当前工作区已有产物且 VERSION 不同，要求先清理。
if [ -f VERSION ] && [ "$(cat VERSION)" != "$VERSION" ]; then
    bad "工作区已有 $(cat VERSION) 的产物，发新版本前先切回干净状态"
    exit 1
fi

local_site=$(find "$RULES_DIR/ruleset/site" -name '*.mrs' 2>/dev/null | wc -l)
local_geoip=$(find "$RULES_DIR/ruleset/geoip" -name '*.mrs' 2>/dev/null | wc -l)
ok "规则集：$local_site 个域名 + $local_geoip 个 IP"
ok "模板源：$TEMPLATE_DIR/templates/mihomo.yaml"

# ---------------------------------------------------------------------------
# 组装版本目录
# ---------------------------------------------------------------------------
log "组装 $VERSION"

# 清理上一版产物（保留脚本与文档）
rm -rf site geoip
rm -f Crypto.mrs PayPal.mrs PayPal-Phish.txt template.yaml MANIFEST.json

mkdir -p site geoip

cp "$RULES_DIR"/ruleset/site/*.mrs site/
cp "$RULES_DIR"/ruleset/geoip/*.mrs geoip/
cp "$RULES_DIR"/ruleset/Crypto.mrs .
cp "$RULES_DIR"/ruleset/PayPal.mrs .
cp "$RULES_DIR"/ruleset/PayPal-Phish.txt .

ok "产物已复制（$(find . -maxdepth 2 -name '*.mrs' | wc -l) 个 .mrs）"

# ---------------------------------------------------------------------------
# 渲染模板：{{RULES_VERSION}} → 实际 tag
# ---------------------------------------------------------------------------
log "渲染模板"

python3 - "$TEMPLATE_DIR/templates/mihomo.yaml" "template.yaml" "$VERSION" <<'PY'
import re, sys

src_path, out_path, version = sys.argv[1:4]

src = open(src_path, encoding='utf-8').read()

if '{{RULES_VERSION}}' not in src:
    sys.exit('模板里没有 {{RULES_VERSION}} 占位符')

n = src.count('{{RULES_VERSION}}')
rendered = src.replace('{{RULES_VERSION}}', version)

# 渲染后不应残留任何占位符
leftover = re.findall(r'\{\{[A-Z_]+\}\}', rendered)
if leftover:
    sys.exit(f'渲染后仍有未替换的占位符: {set(leftover)}')

open(out_path, 'w', encoding='utf-8', newline='\n').write(rendered)
print(f'  替换 {n} 处 {{{{RULES_VERSION}}}} → {version}')
PY

ok "模板已渲染"

# ---------------------------------------------------------------------------
# 校验渲染结果
# ---------------------------------------------------------------------------
log "校验渲染结果"

python3 - "template.yaml" "$VERSION" <<'PY'
import re, sys, yaml

tpl_path, version = sys.argv[1:3]
d = yaml.safe_load(open(tpl_path, encoding='utf-8'))

# 1. 结构完整
for key in ('proxy-groups', 'rules', 'rule-providers'):
    assert key in d, f'缺顶层键 {key}'

# 2. 所有 provider URL 指向本版本
bad = []
for k, v in d['rule-providers'].items():
    url = v['url']
    # URL 形如 .../mihomo-apply@v0.1.0/site/X.mrs 或 .../mihomo-apply@v0.1.0/Crypto.txt
    if f'mihomo-apply@{version}/' not in url:
        bad.append((k, url))
if bad:
    for k, u in bad:
        print(f'  {k}: {u}', file=sys.stderr)
    sys.exit('有 provider 未指向本版本')

# 3. rules 引用的组都存在
groups = {g['name'] for g in d['proxy-groups']}
builtin = {'DIRECT', 'REJECT', 'REJECT-DROP', 'PASS'}
provs = set(d['rule-providers'])
missing = set()
for r in d['rules']:
    p = [x.strip() for x in r.split(',')]
    t = p[0].upper()
    if t == 'RULE-SET':
        assert p[1] in provs, f'未定义的 provider: {p[1]}'
        if p[2] not in groups and p[2] not in builtin:
            missing.add(p[2])
    elif t == 'MATCH':
        if p[1] not in groups and p[1] not in builtin:
            missing.add(p[1])
assert not missing, f'未定义的组: {sorted(missing)}'

print(f'  {len(d["proxy-groups"])} 组 / {len(d["rule-providers"])} provider / {len(d["rules"])} 规则')
print(f'  全部 provider 指向 {version}')
PY

ok "校验通过"

# ---------------------------------------------------------------------------
# 生成 MANIFEST
# ---------------------------------------------------------------------------
log "生成 MANIFEST"

python3 - "." "$VERSION" <<'PY'
import hashlib, json, sys
from datetime import datetime, timezone
from pathlib import Path

ver_dir = Path(sys.argv[1])
version = sys.argv[2]

def sha256(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()

artifacts = {}
for p in sorted(ver_dir.rglob('*')):
    if not p.is_file() or p.name == 'MANIFEST.json':
        continue
    rel = str(p.relative_to(ver_dir))
    artifacts[rel] = {
        'sha256': sha256(p),
        'bytes': p.stat().st_size,
    }

manifest = {
    'version': version,
    'publishedAt': datetime.now(timezone.utc).isoformat(),
    'artifacts': artifacts,
}

(ver_dir / 'MANIFEST.json').write_text(
    json.dumps(manifest, indent=2, ensure_ascii=False) + '\n',
    encoding='utf-8')

print(f'  {len(artifacts)} 个文件')
PY

ok "MANIFEST 已生成"

# ---------------------------------------------------------------------------
# 更新 latest 与 VERSION
# ---------------------------------------------------------------------------
log "更新 latest 与 VERSION"

printf '%s\n' "$VERSION" > VERSION

ok "VERSION = $VERSION"

# ---------------------------------------------------------------------------
# 摘要
# ---------------------------------------------------------------------------
echo ""
log "发布摘要"
echo ""
printf '  %-28s %10s\n' "文件" "大小"
printf '  %s\n' "$(printf '%.0s-' {1..40})"
find . -maxdepth 2 -type f -not -path "./.git/*" | sort | while read -r f; do
    rel="${f#./}"
    sz=$(stat -c%s "$f")
    if [ "$sz" -ge 1048576 ]; then
        printf '  %-28s %9.1f MB\n' "$rel" "$(echo "scale=1; $sz/1048576" | bc)"
    else
        printf '  %-28s %9.1f KB\n' "$rel" "$(echo "scale=1; $sz/1024" | bc)"
    fi
done

echo ""
echo "  下一步："
echo "    git add -A && git commit -m 'release: $VERSION'"
echo "    git tag $VERSION"
echo "    git push origin main --tags"
