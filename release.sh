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
        --rules-dir|--template-dir)
            # 缺值时直接报 $2: unbound variable（set -u 下），提示不明。
            if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
                echo "错误：$1 需要一个值" >&2
                exit 2
            fi
            case "$1" in
                --rules-dir)    RULES_DIR="$2" ;;
                --template-dir) TEMPLATE_DIR="$2" ;;
            esac
            shift 2
            ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 前置检查
# ---------------------------------------------------------------------------
log "检查输入"

[ -d "$RULES_DIR/ruleset" ] || { bad "找不到 $RULES_DIR/ruleset"; exit 1; }
[ -f "$TEMPLATE_DIR/templates/mihomo.yaml" ] || { bad "找不到模板源"; exit 1; }

# 版本由 git tag 表达，目录不重复版本号。
# 已发布版本不可变由 git tag 保证 —— tag 一旦打过就不能改内容，
# 所以这里不需要拦「工作区有上一版产物」。CI 里 checkout 出来的
# 本来就是上一版，拦它等于永远发不了新版本。
#
# 真正要防的是「重复发同一个版本」：tag 已存在则不覆盖。
tag_exists() {
    local v="$1"
    # 本地有 tag
    if git rev-parse -q --verify "refs/tags/$v" >/dev/null 2>&1; then
        return 0
    fi
    # CI 浅克隆拿不到 tag，问远端
    if command -v gh >/dev/null 2>&1; then
        if gh api "repos/${GITHUB_REPOSITORY:-CauriumX/mihomo-apply}/git/refs/tags/$v" \
                >/dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

if tag_exists "$VERSION"; then
    # 幂等重跑：tag 已存在时不再直接拒绝，而是把判断推到 MANIFEST 生成之后 ——
    # 内容一致就允许重跑（发布成功、但后续 CDN 校验因传播延迟失败的场景），
    # 内容不一致仍然硬失败（已发布版本不可变）。
    IDEMPOTENT_CHECK=0
    REMOTE_MANIFEST="$(mktemp)"
    fetched=0

    # 先试本地 tag（开发机、fetch-depth: 0 的 CI 都有）
    if git show "$VERSION:MANIFEST.json" > "$REMOTE_MANIFEST" 2>/dev/null \
            && [ -s "$REMOTE_MANIFEST" ]; then
        fetched=1
    fi

    # 再试 API（浅克隆拿不到 tag，且需要 GH_TOKEN）
    if [ "$fetched" = 0 ] && command -v gh >/dev/null 2>&1; then
        if gh api "repos/${GITHUB_REPOSITORY:-CauriumX/mihomo-apply}/contents/MANIFEST.json?ref=$VERSION" \
                -H "Accept: application/vnd.github.raw" > "$REMOTE_MANIFEST" 2>/dev/null \
                && [ -s "$REMOTE_MANIFEST" ]; then
            fetched=1
        fi
    fi

    if [ "$fetched" = 1 ]; then
        IDEMPOTENT_CHECK=1
        warn "$VERSION 的 tag 已存在；生成后比对内容，一致则按幂等重跑继续"
    else
        bad "$VERSION 的 tag 已存在，且取不到它的 MANIFEST.json。请换新版本号"
        rm -f "$REMOTE_MANIFEST"
        exit 1
    fi
else
    IDEMPOTENT_CHECK=0
    REMOTE_MANIFEST=""
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
# 去注释：published 的 template.yaml 必须是干净的
#
# 源模板（mihomo-template）保留完整注释，那是给人的说明书；但分发出去的
# 那份每 27% 是注释，客户端只需要语义。注释里还写着内部 URL、决策背景、
# 待办事项 —— 这些不该随订阅发到每个使用者手上。
#
# 宁可用「剥后重新解析、与剥前深度相等」做硬断言，也不相信手写的正则：
# `#` 在双引号里是数据（"114.114.114.114#DIRECT"），裸 sed 会把 DNS
# 策略截断成 "114.114.114.114，而 YAML 依然合法 —— 静默的分流故障。
# ---------------------------------------------------------------------------
log "去注释（保留 3 行来源头）"

python3 - "template.yaml" "$VERSION" <<'PY'
import sys, yaml

path, version = sys.argv[1:3]
text = open(path, encoding='utf-8').read()


def strip_comments(src: str):
    out = []
    for line in src.splitlines():
        s = line.lstrip()
        if s.startswith('#'):
            continue                      # 整行注释
        res = []
        quote = None
        prev = ''
        for ch in line:
            if quote:
                res.append(ch)
                if ch == quote and prev != '\\':
                    quote = None
            else:
                if ch in ('"', "'"):
                    quote = ch
                    res.append(ch)
                elif ch == '#' and (not res or res[-1] in ' \t'):
                    break                 # 行尾注释（前面有空白才算）
                else:
                    res.append(ch)
            prev = ch
        cleaned = ''.join(res).rstrip()
        if cleaned.strip():
            out.append(cleaned)
    return '\n'.join(out) + '\n'

before = yaml.safe_load(text)
clean = strip_comments(text)
after = yaml.safe_load(clean)

# 硬断言：语义必须完全一致。块标量不存在，所以逐行剥离是安全的；
# 一旦将来引入多行字符串，这里会立刻报错而不是静默切开。
if before != after:
    sys.exit('去注释改变了配置语义 —— 拒绝发布（检查是否有块标量或多行字符串）')

header = (
    '# generated — do not edit\n'
    f'# version: {version} · rules: mihomo-apply@@{version}\n'
    '# annotated source: {{SECRET_m7bwenyy}}/mihomo-template → templates/mihomo.yaml\n'
)
open(path, 'w', encoding='utf-8', newline='\n').write(header + clean)

removed = len(text) - len(clean)
print(f'  {len(text)} → {len(clean) + len(header)} B（去掉 {removed} B 注释），语义断言相等')
PY

ok "template.yaml 已去注释"

# ---------------------------------------------------------------------------
# 排版：分发包是给人看的配置，不是一堆相连的行
#
# 参考 上游 B（Sakura）的订阅模板：顶部全局标量块紧凑，之后每个顶层段之间
# 空一行；proxy-groups 每个组、rule-providers 每个 provider 之间也空一行。
# 670 行一个空行都没有时，找“某个 provider 的 interval 在哪”只能靠搜。
#
# 只动空行与行尾空白，不重排顺序、不改引号 —— 并在此重新断言解析相等。
# ---------------------------------------------------------------------------
log "排版"

python3 - "template.yaml" <<'PY'
import re, sys, yaml

path = sys.argv[1]
text = open(path, encoding='utf-8').read()
lines = text.splitlines()

GLOBAL_BLOCK = {'port', 'socks-port', 'mixed-port', 'allow-lan', 'bind-address',
                'mode', 'log-level', 'ipv6', 'find-process-mode',
                'external-controller', 'profile', 'unified-delay',
                'tcp-concurrent', 'global-ua'}

TOP = re.compile(r'^([A-Za-z_][A-Za-z0-9_-]*):')
PROV = re.compile(r'^  ([A-Za-z0-9_.-]+):$')
GRP = re.compile(r'^  - name:')

out = []
section = None

SECTION_HEADER = re.compile(r'^[A-Za-z_][A-Za-z0-9_-]*:$')


def blank():
    # 段头与第一个条目之间不留空行（rule-providers: 紧接 AD-Site:），
    # 与 Sakura 的订阅模板一致；只在条目之间留。
    if not out or out[-1] == '' or SECTION_HEADER.match(out[-1]):
        return
    out.append('')

for line in lines:
    line = line.rstrip()
    if line == '':
        continue                        # 空行统一重建

    t = TOP.match(line)
    if t:
        key = t.group(1)
        # 顶部全局标量块内部不插空行（参考 Sakura）
        if key not in GLOBAL_BLOCK:
            blank()
        section = key
        out.append(line)
        continue

    if section == 'rule-providers' and PROV.match(line):
        blank()
    elif section == 'proxy-groups' and GRP.match(line):
        blank()

    out.append(line)

# 头部 3 行来源头与第一个键之间也空一行
if out and out[0].startswith('#'):
    i = 0
    while i < len(out) and out[i].startswith('#'):
        i += 1
    out.insert(i, '')

formatted = '\n'.join(out).rstrip('\n') + '\n'

if yaml.safe_load(text) != yaml.safe_load(formatted):
    sys.exit('排版改变了配置语义 —— 拒绝发布')

open(path, 'w', encoding='utf-8', newline='\n').write(formatted)
print(f'  {len(lines)} 行 → {len(out)} 行（插入空行分段），语义断言相等')
PY

ok "template.yaml 已排版"

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

# 只登记订阅实际引用的产物。
# 排除 .git / .github / 脚本 / 文档 / 图片 —— 它们不是发布内容，
# 混进来会让 MANIFEST 随每次提交变化，失去「产物指纹」的意义。
#
# 这份名单必须与 .github/workflows/ci.yml 的「MANIFEST matches files」
# 步骤保持一致：两边各写一份，一边加了另一边没加，校验就会红。
# README.zh-CN.md 与 assets/ 就是因为只加到了仓库、没加到这里而失败过。
SKIP_DIRS = {'.git', '.github', 'assets'}
SKIP_FILES = {'MANIFEST.json', 'LICENSE', 'README.md', 'README.zh-CN.md',
              'release.sh', 'tags-audit.sh', 'VERSION', '.gitignore'}

artifacts = {}
for p in sorted(ver_dir.rglob('*')):
    if not p.is_file():
        continue
    rel = str(p.relative_to(ver_dir))
    if rel in SKIP_FILES:
        continue
    if any(part in SKIP_DIRS for part in p.relative_to(ver_dir).parts):
        continue
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

# 幂等重跑的最终裁定：内容必须与本版本已发布的完全一致
if [ "${IDEMPOTENT_CHECK:-0}" = "1" ]; then
    if python3 - "$REMOTE_MANIFEST" MANIFEST.json <<'PY'
import json, sys
try:
    a = json.load(open(sys.argv[1], encoding='utf-8'))
    b = json.load(open(sys.argv[2], encoding='utf-8'))
except Exception as e:
    sys.exit(f'MANIFEST 解析失败: {e}')
sys.exit(0 if (a.get('version') == b.get('version')
               and a.get('artifacts') == b.get('artifacts')) else 1)
PY
    then
        ok "与已发布的 $VERSION 内容一致 —— 幂等重跑，继续（跳过重复发布）"
    else
        bad "内容与已发布的 $VERSION 不一致。已发布版本不可变，请换新版本号"
        rm -f "$REMOTE_MANIFEST"
        exit 1
    fi
    rm -f "$REMOTE_MANIFEST"
fi

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
