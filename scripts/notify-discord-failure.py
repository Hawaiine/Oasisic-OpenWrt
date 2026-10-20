#!/usr/bin/env python3
"""Oasisic-OpenWrt 构建失败通知 → Discord（Components V2，失败走 embed 回退）

用到的环境变量（workflow 注入）：
  DISCORD_TOKEN        bot token
  DISCORD_CHANNEL_ID   目标频道（默认 🖥️・固件发布）
  RUN_ID / RUN_URL     本次 Actions run
  EVENT_NAME           触发事件（schedule / workflow_dispatch / pull_request）
  REF_NAME             分支名
  PR_NUMBER            PR 号（非 PR 为空）
  OWRT_VER / NIKKI_REF / NIKKI_SHORT   版本信息（可能为空）
  GITHUB_REPOSITORY    owner/repo
  GH_TOKEN             用来查 jobs API，列失败任务
"""
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

API = "https://discord.com/api/v10"
GH = "https://api.github.com"
UA = "Oasisic-OpenWrt-CI/2.0 (+https://github.com/Hawaiine/Oasisic-OpenWrt)"
BJ_TZ = timezone(timedelta(hours=8))
ACCENT = 0xED4245  # 失败红

channel_id = os.environ.get("DISCORD_CHANNEL_ID", "1524181167270531303")
token = os.environ.get("DISCORD_TOKEN", "").strip()
repo = os.environ.get("GITHUB_REPOSITORY", "Hawaiine/Oasisic-OpenWrt")
run_id = os.environ.get("RUN_ID", "").strip()
run_url = os.environ.get("RUN_URL", "").strip()
event = os.environ.get("EVENT_NAME", "").strip()
ref = os.environ.get("REF_NAME", "").strip()
pr = os.environ.get("PR_NUMBER", "").strip()
owrt = os.environ.get("OWRT_VER", "").strip()
nikki_ref = os.environ.get("NIKKI_REF", "").strip()
nikki_short = os.environ.get("NIKKI_SHORT", "").strip()
gh_token = os.environ.get("GH_TOKEN", "").strip()
build_time = datetime.now(BJ_TZ).strftime("%Y-%m-%d %H:%M:%S")

if not token:
    print("❌ DISCORD_TOKEN 未设置", file=sys.stderr)
    sys.exit(1)


def gh_get(path: str):
    req = urllib.request.Request(f"{GH}{path}")
    req.add_header("Authorization", f"Bearer {gh_token}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", UA)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:  # noqa: S310
            return json.loads(r.read().decode("utf-8", "replace") or "{}")
    except Exception as exc:  # noqa: BLE001
        print(f"⚠️ 查询 jobs 失败：{exc}", file=sys.stderr)
        return {}


# ── 收集失败任务 / 失败步骤 ──────────────────────────────────────────────
failed = []
run_number = ""
if run_id and gh_token:
    meta = gh_get(f"/repos/{repo}/actions/runs/{run_id}")
    run_number = str(meta.get("run_number") or "")
    data = gh_get(f"/repos/{repo}/actions/runs/{run_id}/jobs?per_page=50")
    for job in data.get("jobs", []):
        if job.get("conclusion") != "failure":
            continue
        steps = [s.get("name", "?") for s in job.get("steps", []) if s.get("conclusion") == "failure"]
        failed.append((job.get("name", "?"), steps))

if failed:
    fail_lines = []
    for name, steps in failed:
        step_txt = "、".join(steps) if steps else "（未定位到具体步骤）"
        fail_lines.append(f"**{name}** → {step_txt}")
    fail_text = "\n".join(fail_lines)
else:
    fail_text = "未能从 API 取到失败明细，请点下方按钮看日志"

trigger = {
    "schedule": "定时任务",
    "workflow_dispatch": "手动触发",
    "pull_request": f"PR #{pr}" if pr else "PR",
}.get(event, event or "未知")

version_txt = owrt or ""
if nikki_short:
    version_txt = f"{version_txt} · Nikki {nikki_short}" + (f"（ref: {nikki_ref}）" if nikki_ref else "")
elif nikki_ref:
    version_txt = f"{version_txt} · Nikki {nikki_ref}"
info = f"**触发** {trigger}\n**分支** `{ref or '-'}`\n" + (f"**版本** {version_txt}\n" if version_txt else "")


def build_v2() -> dict:
    children = [
        {"type": 10, "content": "## ❌ Oasisic OpenWrt 构建失败"},
        {"type": 14, "divider": True, "spacing": 1},
        {"type": 10, "content": info.strip()},
        {"type": 14, "divider": True, "spacing": 1},
        {"type": 10, "content": f"### 🔍 失败位置\n{fail_text}"},
        {"type": 14, "divider": True, "spacing": 1},
        {
            "type": 1,
            "components": [{"type": 2, "style": 5, "label": "查看运行日志", "url": run_url or f"https://github.com/{repo}/actions"}],
        },
        {"type": 10, "content": f"-# run #{run_number or run_id or '-'} · ⏱ {build_time} 北京时间\n-# 🏝️ Oasisic-OpenWrt 自动构建"},
    ]
    return {"flags": 32768, "components": [{"type": 17, "accent_color": ACCENT, "components": children}]}


def build_embed() -> dict:
    return {
        "embeds": [
            {
                "title": "❌ Oasisic OpenWrt 构建失败",
                "color": ACCENT,
                "description": f"{info}\n\n**失败位置**\n{fail_text}",
                "url": run_url or f"https://github.com/{repo}/actions",
                "footer": {"text": f"run #{run_number or run_id or '-'} · Oasisic-OpenWrt 自动构建"},
                "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            }
        ]
    }


def post(payload: dict):
    req = urllib.request.Request(
        f"{API}/channels/{channel_id}/messages",
        data=json.dumps(payload).encode("utf-8"),
        method="POST",
    )
    req.add_header("Authorization", f"Bot {token}")
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", UA)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:  # noqa: S310
            return resp.status, json.loads(resp.read().decode("utf-8", "replace") or "{}")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        try:
            return exc.code, json.loads(body or "{}")
        except json.JSONDecodeError:
            return exc.code, {"message": body[:300]}
    except urllib.error.URLError as exc:
        return 0, {"message": str(exc)}


status, result = post(build_v2())
if status in (200, 201) and result.get("id"):
    print(f"✅ 失败通知已发送（Components V2） message_id={result['id']}")
    sys.exit(0)

print(f"⚠️ V2 被拒（{status}: {result.get('message', '')}），回退 embed", file=sys.stderr)
status2, result2 = post(build_embed())
if status2 in (200, 201) and result2.get("id"):
    print(f"✅ 失败通知已发送（embed） message_id={result2['id']}")
    sys.exit(0)

print(f"❌ Discord 拒绝: {status2} {result2.get('message', '')}", file=sys.stderr)
sys.exit(1)
