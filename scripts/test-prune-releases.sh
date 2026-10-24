#!/bin/bash
# test-prune-releases.sh — 离线验证 prune-releases.py 的决策逻辑（不联网、不做任何写操作）
#
# 为什么要有这个自检：保留策略会**删数据**，一旦模式判断写错就会删掉该留的 Release。
# 这里用固定 fixture + 固定「当前时间」跑决策，断言：
#   - 最新的正式 Release 永不删
#   - 只保留最近 KEEP 个正式 Release
#   - 批次 tag 模式不匹配的（可能是手工发布）一律保留
#   - PR 验证件只删超过保留天数的
#   - draft 永远保留
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/prune-releases.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
check() {
    local desc="$1" status="$2"
    if [ "$status" -eq 0 ]; then
        echo "  ✅ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ❌ $desc"
        FAIL=$((FAIL + 1))
    fi
}

echo "═══════════════════════════════════════════"
echo "  保留策略决策自检（离线）"
echo "═══════════════════════════════════════════"

NOW="2026-10-24T13:00:00Z"

python3 - "$WORK" <<'PY'
import json, sys
from pathlib import Path
work = Path(sys.argv[1])
formal = [
    ("25.12.6-n31339d5-r246", "2026-10-24T12:54:00Z", False, False),
    ("25.12.6-n31339d5-r245", "2026-10-23T12:54:00Z", False, False),
    ("25.12.6-n31339d5-r244", "2026-10-22T12:54:00Z", False, False),
    ("25.12.6-n31339d5-r243", "2026-10-21T12:54:00Z", False, False),
    ("25.12.6-n31339d5-r242", "2026-10-20T12:54:00Z", False, False),
    ("25.12.6-n31339d5-r241", "2026-10-19T12:54:00Z", False, False),
    ("25.12.6-n31339d5", "2026-10-12T12:54:00Z", False, False),      # 非批次 tag：手工/历史
]
prerelease = [
    ("ci-25.12.6-pr19-r247", "2026-10-24T09:00:00Z", True, False),   # 1 天前，保留
    ("ci-25.12.6-pr18-r242", "2026-10-01T09:00:00Z", True, False),   # 23 天前，删
    ("ci-25.12.6-pr17-r241", "2026-09-20T09:00:00Z", True, False),   # 34 天前，删
]
draft = [("25.12.6-draft-tag", "2026-09-01T09:00:00Z", False, True)]

rows = []
for i, (tag, created, pre, dr) in enumerate(formal + prerelease + draft):
    rows.append({"id": 1000 + i, "tag_name": tag, "created_at": created,
                 "draft": dr, "prerelease": pre, "assets": []})
(work / "full.json").write_text(json.dumps(rows), encoding="utf-8")
(work / "only3.json").write_text(json.dumps(rows[:3]), encoding="utf-8")
PY

echo
echo "◆ 场景 1：7 正式 + 3 验证件 + 1 draft，KEEP=5 / 验证件保留 14 天"
OUT1=$(KEEP=5 PRERELEASE_KEEP_DAYS=14 DRY_RUN=true python3 "$SCRIPT" --fixture "$WORK/full.json" --now "$NOW")
echo "$OUT1" | sed 's/^/   /'

echo "$OUT1" | grep -q 'PLAN-KEEP release=25.12.6-n31339d5-r246 reason=latest'
check "最新正式 Release 标记为 latest 且保留" $?

echo "$OUT1" | grep -q 'PLAN-KEEP release=25.12.6-n31339d5 reason=tag-unmatched'
check "非批次 tag（可能是手工发布）保留" $?

echo "$OUT1" | grep -qE 'PLAN-DELETE release=25\.12\.6-n31339d5-r241 .*reason=history-beyond-keep'
check "第 6 个正式 Release 进入删除计划" $?

echo "$OUT1" | grep -qE 'PLAN-DELETE release=ci-25\.12\.6-pr17-r241 .*reason=prerelease-older-14d'
check "超过 14 天的 PR 验证件进入删除计划" $?

echo "$OUT1" | grep -qE 'PLAN-KEEP release=ci-25\.12\.6-pr19-r247 .*reason=prerelease-fresh-14d'
check "14 天内的 PR 验证件保留" $?

echo "$OUT1" | grep -qE 'PLAN-KEEP release=25\.12\.6-draft-tag .*reason=draft'
check "draft 永远保留" $?

[ "$(echo "$OUT1" | grep -c '^PLAN-DELETE')" -eq 3 ]
check "删除计划恰好 3 项（1 正式 + 2 验证件）" $?

echo "$OUT1" | grep -q 'PLAN-DELETE release=25.12.6-n31339d5-r246' && echo "   ❌ 最新 Release 出现在删除计划里" || true
! echo "$OUT1" | grep -q 'PLAN-DELETE release=25.12.6-n31339d5-r246'
check "最新正式 Release 绝不出现在删除计划" $?

echo
echo "◆ 场景 2：只有 3 个正式 Release，KEEP=5 → 不删"
OUT2=$(KEEP=5 DRY_RUN=true python3 "$SCRIPT" --fixture "$WORK/only3.json" --now "$NOW")
echo "$OUT2" | tail -3 | sed 's/^/   /'
[ "$(echo "$OUT2" | grep -c '^PLAN-DELETE')" -eq 0 ]
check "无历史可删（删除计划 0 项）" $?

echo
echo "◆ 场景 3：KEEP=2 → 更激进的保留策略同样只删批次 tag"
OUT3=$(KEEP=2 PRERELEASE_KEEP_DAYS=14 DRY_RUN=true python3 "$SCRIPT" --fixture "$WORK/full.json" --now "$NOW")
# KEEP=2：正式里 r246(latest) 与 r245 保留，r244/r243/r242/r241 共 4 个删；非批次 tag 保留
# 验证件再删 2 个 → 合计 6
[ "$(echo "$OUT3" | grep -c '^PLAN-DELETE')" -eq 6 ]
check "KEEP=2 时删除 6 项（4 正式 + 2 验证件，非批次 tag 仍保留）" $?

echo
echo "═══════════════════════════════════════════"
echo "  结果: $PASS ✅  /  $FAIL ❌"
echo "═══════════════════════════════════════════"
[ "$FAIL" -eq 0 ] || exit 1
echo "🎉 保留策略决策自检全部通过（全部为 dry-run，未触发任何写操作）"