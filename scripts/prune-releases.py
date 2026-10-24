#!/usr/bin/env python3
"""prune-releases.py — 清理历史 Release / tag，避免「批次 tag」无限累积。

背景：release tag 现在形如 `{OpenWrt版本}-n{Nikki短SHA}-r{构建号}`，每次重建都会新增一个
Release（每个约 340MB）。没有保留策略的话，按每天一次定时算，一个月就是 ~30 个 / ~10GB。

策略（环境变量可覆盖，默认值即为线上策略）：
  KEEP                   保留最近多少个「正式 Release」（默认 5；最新那个永远保留）
  PRERELEASE_KEEP_DAYS   PR 验证件（prerelease）保留天数（默认 14）
  DRY_RUN                true 只打印计划，不删除（默认 true）

安全护栏（fail-closed，宁可不删）：
  - draft 永不删
  - 正式 Release 中最新的那个永不删（make_latest 指向它）
  - tag 名不符合构建批次模式（`*-n<7位hex>-r<数字>`）的 Release 一律跳过：
    那可能是手工发布，删了会丢人工 tag
  - 删除后逐个回读确认（Release 404 / tag 404），有任一未删掉则退出码非 0

用法：
  python3 scripts/prune-releases.py                 # 按环境变量执行（默认 dry-run）
  DRY_RUN=false KEEP=5 python3 scripts/prune-releases.py
  python3 scripts/prune-releases.py --fixture f.json --dry-run   # 离线决策测试
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_KEEP = 5
DEFAULT_PRERELEASE_KEEP_DAYS = 14

# 正式批次 tag：任意前缀 + -n<7位hex> + -r<数字>
BUILD_TAG_RE = re.compile(r"^.+-n[0-9a-f]{7,}-r[0-9]+$")
# PR 验证件 tag：ci-<版本>-pr<号>-r<号>
PRERELEASE_TAG_RE = re.compile(r"^ci-.+-pr[0-9]+-r[0-9]+$")


def api(path: str, method: str = "GET", token: str = "", repo: str = ""):
    url = f"https://api.github.com/repos/{repo}{path}" if repo else f"https://api.github.com{path}"
    req = urllib.request.Request(url, method=method)
    req.add_header("User-Agent", "oasisic-prune-releases/1.0")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/vnd.github+json")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw.decode() or "{}") if raw else {})
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        return exc.code, (json.loads(raw.decode() or "{}") if raw else {})


def load_releases_from_api(token: str, repo: str) -> list[dict]:
    out, page = [], 1
    while True:
        st, batch = api(f"/releases?per_page=100&page={page}", token=token, repo=repo)
        if st != 200:
            sys.exit(f"❌ 拉取 releases 失败：HTTP {st} {batch}")
        if not batch:
            return out
        out.extend(batch)
        if len(batch) < 100:
            return out
        page += 1


def parse_time(value: str) -> dt.datetime:
    return dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)


def decide(releases: list[dict], keep: int, prerelease_days: int, now: dt.datetime):
    """返回 (keep_list, delete_list)，元素为 (release_dict, reason, delete_tag: bool)。"""
    formal = [r for r in releases if not r.get("draft") and not r.get("prerelease")]
    prerelease = [r for r in releases if not r.get("draft") and r.get("prerelease")]
    drafts = [r for r in releases if r.get("draft")]

    formal.sort(key=lambda r: parse_time(r["created_at"]), reverse=True)
    prerelease.sort(key=lambda r: parse_time(r["created_at"]), reverse=True)

    keep_list, delete_list = [], []

    for idx, r in enumerate(formal):
        tag = r.get("tag_name", "")
        if idx == 0:
            keep_list.append((r, "latest", False))          # 最新的正式 Release 永不删
        elif idx < keep:
            keep_list.append((r, f"newest-{keep}", False))
        elif not BUILD_TAG_RE.match(tag):
            keep_list.append((r, "tag-unmatched", False))   # 非批次 tag：宁可不删
        else:
            delete_list.append((r, "history-beyond-keep", True))

    cutoff = now - dt.timedelta(days=prerelease_days)
    for r in prerelease:
        tag = r.get("tag_name", "")
        if parse_time(r["created_at"]) >= cutoff:
            keep_list.append((r, f"prerelease-fresh-{prerelease_days}d", False))
        elif not PRERELEASE_TAG_RE.match(tag):
            keep_list.append((r, "tag-unmatched", False))
        else:
            delete_list.append((r, f"prerelease-older-{prerelease_days}d", True))

    for r in drafts:
        keep_list.append((r, "draft", False))

    return keep_list, delete_list


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fixture", help="离线模式：读取一份 releases 列表 JSON（不做任何写操作）")
    ap.add_argument("--dry-run", action="store_true", help="只打印计划")
    ap.add_argument("--now", help="离线模式下的当前时间（ISO8601，默认真实当前时间）")
    args = ap.parse_args()

    keep = int(os.environ.get("KEEP", DEFAULT_KEEP))
    prerelease_days = int(os.environ.get("PRERELEASE_KEEP_DAYS", DEFAULT_PRERELEASE_KEEP_DAYS))
    env_dry = os.environ.get("DRY_RUN", "true").strip().lower() in ("1", "true", "yes")
    dry_run = args.dry_run or env_dry or bool(args.fixture)
    token = os.environ.get("GH_TOKEN", "") or os.environ.get("GITHUB_TOKEN", "")
    repo = os.environ.get("REPO", os.environ.get("GITHUB_REPOSITORY", ""))

    if args.fixture:
        releases = json.loads(Path(args.fixture).read_text(encoding="utf-8"))
    else:
        if not token or not repo:
            sys.exit("❌ 缺少 GH_TOKEN / REPO 环境变量")
        releases = load_releases_from_api(token, repo)

    now = parse_time(args.now) if args.now else dt.datetime.now(dt.timezone.utc)
    keep_list, delete_list = decide(releases, keep, prerelease_days, now)

    print(f"🧮 策略：正式 Release 保留最近 {keep} 个 · PR 验证件保留 {prerelease_days} 天 · "
          f"模式 {'DRY-RUN' if dry_run else 'EXECUTE'}")
    print(f"📚 当前共 {len(releases)} 个 Release（正式 {sum(1 for r in releases if not r['draft'] and not r['prerelease'])} / "
          f"验证件 {sum(1 for r in releases if r['prerelease'] and not r['draft'])} / draft {sum(1 for r in releases if r['draft'])}）")
    for r, reason, _ in keep_list:
        print(f"PLAN-KEEP release={r['tag_name']} reason={reason}")
    for r, reason, del_tag in delete_list:
        print(f"PLAN-DELETE release={r['tag_name']} tag={'yes' if del_tag else 'no'} reason={reason}")

    if dry_run:
        print(f"🟡 DRY-RUN：计划删除 {len(delete_list)} 个，未执行任何写操作")
        return 0

    if not delete_list:
        print("✅ 无需清理")
        return 0

    failures = []
    for r, reason, del_tag in delete_list:
        tag = r["tag_name"]
        st, _ = api(f"/releases/{r['id']}", method="DELETE", token=token, repo=repo)
        st2, _ = api(f"/releases/{r['id']}", token=token, repo=repo)
        ok_release = st2 == 404
        print(f"🗑 Release {tag}: DELETE HTTP {st} → 回读 {st2} {'✅' if ok_release else '❌ 仍存在'}")
        if not ok_release:
            failures.append(f"release {tag}")
        if del_tag:
            st3, _ = api(f"/git/refs/tags/{tag}", method="DELETE", token=token, repo=repo)
            st4, _ = api(f"/git/refs/tags/{tag}", token=token, repo=repo)
            ok_tag = st4 == 404
            print(f"🏷  tag {tag}: DELETE HTTP {st3} → 回读 {st4} {'✅' if ok_tag else '❌ 仍存在'}")
            if not ok_tag:
                failures.append(f"tag {tag}")

    print(f"📊 删除 {len(delete_list)} 个，失败 {len(failures)}")
    if failures:
        print("❌ 未清理干净：" + ", ".join(failures))
        return 1
    print("✅ 清理完成且全部回读确认")
    return 0


if __name__ == "__main__":
    sys.exit(main())