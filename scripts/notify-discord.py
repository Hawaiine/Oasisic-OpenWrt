#!/usr/bin/env python3
"""Oasisic-OpenWrt → Discord 🖥️・固件发布 通知

优先用 Discord Components V2（Container / TextDisplay / Section / 链接按钮）发送，
服务端不接受（400/403）时自动回退到旧 embed 结构，保证通知不丢。
"""
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

API = "https://discord.com/api/v10"
UA = "Oasisic-OpenWrt-CI/2.0 (+https://github.com/Hawaiine/Oasisic-OpenWrt)"
BJ_TZ = timezone(timedelta(hours=8))

# Oasisic 品牌蓝；V2 容器左侧强调色 / embed 回退色一致
ACCENT = 0x58B4FF
LOGO = "https://raw.githubusercontent.com/openwrt/branding/master/logo/openwrt_logo_square_blue_and_dark_blue.png"

channel_id = os.environ.get("DISCORD_CHANNEL_ID", "1524181167270531303")
token = os.environ.get("DISCORD_TOKEN", "")
if not token:
    print("❌ DISCORD_TOKEN 未设置", file=sys.stderr)
    sys.exit(1)

owrt = os.environ.get("OWRT_VER", "?")
# 上游 tag 带 v（v25.12.6），而本仓 tag / Release 名 / 资产名都用不带 v 的 25.12.6；
# 卡片上与后者对齐，避免同一页出现两种写法
owrt = owrt[1:] if owrt.startswith("v") else owrt
nikki = os.environ.get("NIKKI_VER", "?")
# Nikki（luci-app-nikki）与 mihomo 核心是两个包、两个版本号，卡片上必须分开写
mihomo = os.environ.get("MIHOMO_VER", "").strip()
kernel = os.environ.get("KERNEL_VER", "")
root_pass = os.environ.get("ROOT_PASS", "")
tag = os.environ.get("TAG", "?")
release_url = os.environ.get("RELEASE_URL", "#")
build_time = os.environ.get("BUILD_TIME", "").strip()
if not build_time or "$(" in build_time:
    build_time = datetime.now(BJ_TZ).strftime("%Y-%m-%d %H:%M:%S")

# 副标题：版本号带标签（OpenWrt / Nikki / mihomo / 内核），避免裸数字分不清哪家版本
subtitle_bits = []
if owrt and owrt != "?":
    subtitle_bits.append(f"OpenWrt {owrt}")
if nikki and nikki != "?":
    subtitle_bits.append(f"Nikki {nikki}")
if mihomo and mihomo != "?":
    subtitle_bits.append(f"mihomo-meta {mihomo}")
if kernel and kernel != "?":
    subtitle_bits.append(f"内核 {kernel}")
subtitle_bits.append("x86/64")
SUBTITLE = " · ".join(subtitle_bits)

TITLE = "## 🏝️ Oasisic OpenWrt 固件已发布"


# ─────────────────────────── Components V2 卡片 ───────────────────────────
def build_v2() -> dict:
    children = [
        {
            "type": 9,
            "components": [{"type": 10, "content": f"{TITLE}\n-# {SUBTITLE}"}],
            "accessory": {"type": 11, "media": {"url": LOGO}},
        },
        {"type": 14, "divider": True, "spacing": 1},
        {
            "type": 10,
            "content": (
                "### 📦 下载\n"
                "`openwrt-x86-64-generic-squashfs-combined-efi.img.gz` 推荐 · PVE UEFI\n"
                "`openwrt-x86-64-generic-squashfs-combined.img.gz` 传统 BIOS\n"
                "`openwrt-x86-64-generic-image-efi.iso` / `openwrt-x86-64-generic-image.iso` ISO 镜像"
            ),
        },
        {
            "type": 10,
            "content": (
                "### 🔒 校验下载\n"
                "`sha256sum -c --ignore-missing sha256sums`\n"
                "`minisign -V -m sha256sums -x sha256sums.minisig -p minisign.pub`\n"
                "-# 校验和只收录本次发布内的文件（未发布产物不进清单），不会再报无从比对的 FAILED"
            ),
        },
        {
            "type": 10,
            "content": (
                "### 🔑 首次登录\n"
                f"用户 `root` · 密码 ||`{root_pass or '（见 Release 正文）'}`||\n"
                "开机走 DHCP，IP 到主路由查看，首次访问自动进设置向导"
            ),
        },
        {"type": 14, "divider": True, "spacing": 1},
        {
            "type": 1,
            "components": [
                {"type": 2, "style": 5, "label": "前往 Release 下载", "url": release_url}
            ],
        },
        {
            "type": 10,
            "content": (
                f"-# 🏷️ {tag}\n"
                f"-# ⏱ {build_time} 北京时间\n"
                "-# 🏝️ Oasisic-OpenWrt 自动构建"
            ),
        },
    ]

    return {"flags": 32768, "components": [{"type": 17, "accent_color": ACCENT, "components": children}]}


# ────────────────────────────── embed 回退 ──────────────────────────────
def build_embed() -> dict:
    fields = [
        {"name": "🏗️ **OpenWrt**", "value": f"`{owrt}`", "inline": True},
        {"name": "📡 **Nikki**", "value": f"`{nikki}`", "inline": True},
    ]
    if mihomo and mihomo != "?":
        fields.append({"name": "🐱 **mihomo-meta**", "value": f"`{mihomo}`", "inline": True})
    if kernel and kernel != "?":
        fields.append({"name": "🐧 **Kernel**", "value": f"`{kernel}`", "inline": True})
    fields += [
        {"name": "🏷️ **版本标签**", "value": f"`{tag}`", "inline": True},
        {"name": "📦 **下载链接**", "value": f"[🔗 前往 Release 页面]({release_url})", "inline": False},
        {
            "name": "🔒 **校验**",
            "value": "`sha256sum -c --ignore-missing sha256sums`\n"
                     "`minisign -V -m sha256sums -x sha256sums.minisig -p minisign.pub`",
            "inline": False,
        },
        {"name": "⏱ **编译完成**", "value": f"{build_time} 北京时间", "inline": False},
    ]
    return {
        "embeds": [
            {
                "title": "🏝️ **Oasisic OpenWrt 固件已发布**",
                "color": ACCENT,
                "thumbnail": {"url": LOGO},
                "fields": fields,
                "footer": {
                    "text": "Oasisic-OpenWrt · 自动构建",
                    "icon_url": "https://avatars.githubusercontent.com/u/152380613?v=4",
                },
                "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            }
        ]
    }


def post(payload: dict) -> tuple[int, dict]:
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
    print(f"✅ Discord 通知发送成功（Components V2） message_id={result['id']}")
    sys.exit(0)

print(f"⚠️ V2 发送被拒（{status}: {result.get('message', '')}），回退 embed", file=sys.stderr)
status2, result2 = post(build_embed())
if status2 in (200, 201) and result2.get("id"):
    print(f"✅ Discord 通知发送成功（embed 回退） message_id={result2['id']}")
    sys.exit(0)

print(f"❌ Discord 拒绝: {status2} {result2.get('message', '')}", file=sys.stderr)
sys.exit(1)
