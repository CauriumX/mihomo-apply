#!/usr/bin/env bash
# ============================================================================
# tags-audit.sh — 审计已发布的 tag，列出超出保留策略的版本
#
# 这是**只读**工具：不删除、不修改任何 tag。
#
# 为什么不自动删：
#   tag 一旦发布就进了 jsDelivr 的永久缓存，删掉 tag 会让已分发出去的
#   URL 直接 404 —— 而订阅这份模板的客户端是靠 URL 拉配置的，404 意味着
#   客户端拿不到新配置。清理必须由人判断「这个版本确认没人还在用」。
#
#   工具只负责把「谁超期了」摆清楚，按下删除键的始终是人。
#
# 保留策略（见 README「版本保留」一节）：
#   1. 最近 N 个版本                       （默认 N=10）
#   2. 所有 minor 的最新补丁版             （v0.1.x 保留其中最高者）
#   任意一条命中即保留，两条都不命中才算「超出策略」。
#
# 用法：
#   bash tags-audit.sh                 # 审计当前仓库
#   bash tags-audit.sh --keep 5        # 改保留数量
#   bash tags-audit.sh --repo OWNER/REPO
#
# 退出码：
#   0 全部在保留范围内
#   1 存在超出策略的 tag（仅提示，不代表出错）
#   2 环境问题（无 gh 凭证、仓库不可达等）
# ============================================================================
set -euo pipefail

REPO="${GITHUB_REPOSITORY:-CauriumX/mihomo-apply}"
KEEP=10

while [ $# -gt 0 ]; do
    case "$1" in
        --keep)
            if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
                echo "错误：--keep 需要一个数字" >&2
                exit 2
            fi
            KEEP="$2"; shift 2 ;;
        --repo)
            if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
                echo "错误：--repo 需要一个 OWNER/REPO" >&2
                exit 2
            fi
            REPO="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

if ! [[ "$KEEP" =~ ^[0-9]+$ ]] || [ "$KEEP" -lt 1 ]; then
    echo "错误：--keep 必须是正整数，实际 '$KEEP'" >&2
    exit 2
fi

command -v gh >/dev/null 2>&1 || { echo "错误：需要 gh CLI" >&2; exit 2; }
gh auth status >/dev/null 2>&1 || { echo "错误：gh 未登录" >&2; exit 2; }

# 取全部 tag 名。只认 vX.Y.Z，忽略其它形态（防止把人工 tag 算进来）。
tags=$(gh api "repos/$REPO/tags?per_page=100" --paginate -q '.[].name' 2>/dev/null || true)
if [ -z "$tags" ]; then
    echo "错误：读不到 $REPO 的 tag（仓库不可达或无权限）" >&2
    exit 2
fi

python3 - "$REPO" "$KEEP" <<PY
import re, sys

repo, keep = sys.argv[1], int(sys.argv[2])
tags = """$tags""".split()

# 只处理 vX.Y.Z
parsed = []
for t in tags:
    m = re.fullmatch(r'v(\d+)\.(\d+)\.(\d+)', t)
    if not m:
        continue
    parsed.append((tuple(int(x) for x in m.groups()), t))

if not parsed:
    print(f"  {repo}: 没有形如 vX.Y.Z 的 tag")
    sys.exit(0)

# 新到旧
parsed.sort(reverse=True)

# 策略 1：最近 keep 个
by_recency = {t for _, t in parsed[:keep]}

# 策略 2：每个 minor 的最高补丁版
best_per_minor = {}
for ver, t in parsed:
    minor = ver[:2]
    if minor not in best_per_minor:
        best_per_minor[minor] = t
by_minor = set(best_per_minor.values())

kept = by_recency | by_minor
stale = [(v, t) for v, t in parsed if t not in kept]

print(f"仓库: {repo}")
print(f"tag 总数: {len(parsed)}   保留策略: 最近 {keep} 个 + 每个 minor 最新")
print()
print(f"  保留 {len(kept)} 个")
for v, t in sorted(parsed, reverse=True):
    if t in kept:
        why = []
        if t in by_recency:
            why.append(f"最近 {keep} 个")
        if t in by_minor:
            why.append(f"v{v[0]}.{v[1]}.x 最新")
        print(f"    ✓ {t}  ({' / '.join(why)})")

if stale:
    print()
    print(f"  超出策略 {len(stale)} 个")
    for v, t in sorted(stale, reverse=True):
        print(f"    · {t}")
    print()
    print("  这些 tag 仍可从 jsDelivr 访问，删除前请先确认没有客户端还锁在上面：")
    print(f"    https://cdn.jsdelivr.net/gh/{repo}@<tag>/template.yaml")
    sys.exit(1)

print()
print("  全部在保留范围内")
sys.exit(0)
PY
