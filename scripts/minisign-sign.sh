#!/bin/bash
# minisign-sign.sh — 对 sha256sums 文件进行 minisign 兼容签名
# 用法: bash scripts/minisign-sign.sh <sha256sums文件路径>
# 依赖: python3 + pynacl（CI 里 pip install pynacl）
#
# ── 为什么不用 apt 的 minisign 二进制 ──────────────────────────────────
# GitHub Secrets 里存的是 32 字节 hex seed + 8 字节 keyid，不是 minisign
# 的加密 seckey 文件。要喂给官方二进制必须先重新封装成 seckey 容器
# （Ed + kdf_alg + cksum_alg + salt + opslimit + memlimit + keyid + key + cksum），
# 该容器格式无稳定公开文档，猜错就签出废签名。直接用 Ed25519 + blake2b
# 复刻签名语义更可靠，前提是格式必须逐字节正确。
#
# ── 2026-10-24 修复的严重 bug ─────────────────────────────────────────
# 旧实现产出的 .minisig **无法被 minisign 验证**：线上 Release
# 25.12.6-n31339d5 的签名实测 `minisign -V` 直接报
#   "base64 conversion failed - was an actual signature given?"
# 三个错误叠加：
#   1. 签名 blob 缺 2 字节算法前缀 → 72 字节，minisign 要求 74 字节
#      （'ED' 2 + keyid 8 + sig 64）
#   2. 前缀位置错放了裸 keyid；minisign 默认 prehashed 模式，
#      前缀必须是 'ED'（对 blake2b-512(data) 签名），'Ed' 才是对原文直接签
#   3. 全局签名既搞错拼接顺序又带上了 "trusted comment: " 前缀；
#      正确做法是 sign(sig || comment纯文本)
#
# 下面实现已用真实 minisign 0.12 二进制双向验证：
#   签名 → `minisign -V` 通过；篡改一个字节 → 验签失败。
#
# ── sha256sums 按发布清单裁剪 ─────────────────────────────────────────
# 签名前先裁剪 sha256sums，只保留 release-assets.txt 里的文件（外加清掉
# 自引用行）：发布什么就签什么。未发布产物的行会让用户跑 `sha256sum -c`
# 时看到永远无法消除的 "FAILED open or read" 误报。
set -euo pipefail

SHA256SUMS="${1:-sha256sums}"
OUT_DIR="$(dirname "$SHA256SUMS")"
OUTPUT="${OUT_DIR}/sha256sums.minisig"

# 发布产物清单（单一真源，仓库根目录的 release-assets.txt）。
# 签名前用它裁剪 sha256sums，只保留真正会随 Release / Artifact 发布的文件。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLISHED_FILE="${MINISIGN_PUBLISHED_ASSETS:-${SCRIPT_DIR}/../release-assets.txt}"

if [ ! -f "$SHA256SUMS" ]; then
    echo "❌ 文件不存在: $SHA256SUMS"
    exit 1
fi

SK_HEX="${MINISIGN_SECRET_KEY:-}"
KEY_ID_HEX="${MINISIGN_KEY_ID:-}"

if [ -z "$SK_HEX" ] || [ -z "$KEY_ID_HEX" ]; then
    echo "❌ 缺少环境变量: MINISIGN_SECRET_KEY / MINISIGN_KEY_ID"
    exit 1
fi

# 公钥用于自校验：seed 派生出的公钥必须与仓库里的 minisign.pub 一致，
# 否则签出来的东西谁也验不过（这类错只有到用户手上才会暴露）
PUB_FILE="${MINISIGN_PUB_FILE:-.github/minisign.pub}"

export MINISIGN_SHA256SUMS="$SHA256SUMS"
export MINISIGN_OUTPUT="$OUTPUT"
export MINISIGN_PUB_FILE="$PUB_FILE"
export MINISIGN_PUBLISHED_ASSETS="$PUBLISHED_FILE"

python3 - <<'PY'
import base64
import hashlib
import os
import sys

from nacl.signing import SigningKey

sums_path = os.environ["MINISIGN_SHA256SUMS"]
out_path = os.environ["MINISIGN_OUTPUT"]
pub_path = os.environ["MINISIGN_PUB_FILE"]

COMMENT = "sha256sums signed by Oasisic-OpenWrt CI"

try:
    seed = bytes.fromhex(os.environ["MINISIGN_SECRET_KEY"].strip())
    key_id = bytes.fromhex(os.environ["MINISIGN_KEY_ID"].strip())
except ValueError as exc:
    sys.exit(f"❌ MINISIGN_SECRET_KEY / MINISIGN_KEY_ID 不是合法 hex: {exc}")

if len(seed) != 32:
    sys.exit(f"❌ MINISIGN_SECRET_KEY 必须是 32 字节 hex seed，实际 {len(seed)} 字节")
if len(key_id) != 8:
    sys.exit(f"❌ MINISIGN_KEY_ID 必须是 8 字节 hex，实际 {len(key_id)} 字节")

sk = SigningKey(seed)
pub = bytes(sk.verify_key)

# ── 公钥自校验 ────────────────────────────────────────────────────────
if os.path.isfile(pub_path):
    lines = [l for l in open(pub_path, encoding="utf-8").read().splitlines() if l.strip()]
    try:
        pub_blob = base64.b64decode(lines[-1])
    except Exception as exc:
        sys.exit(f"❌ 无法解析公钥文件 {pub_path}: {exc}")
    if len(pub_blob) < 42:
        sys.exit(f"❌ 公钥文件 {pub_path} 长度异常: {len(pub_blob)}")
    pub_keyid, pub_key = pub_blob[2:10], pub_blob[10:42]
    if pub_key != pub:
        sys.exit(
            "❌ MINISIGN_SECRET_KEY 派生出的公钥与 "
            f"{pub_path} 不一致\n   派生: {pub.hex()}\n   仓库: {pub_key.hex()}\n"
            "   这样签出来的固件没有人能验证，先修 Secrets 再发版"
        )
    if pub_keyid != key_id:
        sys.exit(
            f"❌ MINISIGN_KEY_ID 与 {pub_path} 不一致\n"
            f"   配置: {key_id.hex()}\n   仓库: {pub_keyid.hex()}"
        )
    print(f"✅ 公钥自校验通过（keyid {key_id.hex()}）")
else:
    print(f"⚠️  未找到公钥文件 {pub_path}，跳过自校验")

# ── 裁剪 sha256sums：先清自引用，再只留发布清单内的文件 ────────────────
# 必须在「计算 digest 之前」做，否则签的是旧内容。
#
# (1) 自引用行（*sha256sums.minisig）
#     OpenWrt 生成 sha256sums 时会把目录里已有的 sha256sums.minisig 也收录进去。
#     用了源码树缓存时，那个 minisig 是上一轮构建的残留，我们随后覆盖它，
#     于是这一行的哈希必然对不上 → 用户跑 `sha256sum -c` 会看到
#     "sha256sums.minisig: FAILED"，误以为文件被篡改。
#     而且这是自引用：签名不能包含自己的哈希，永远不可能自洽。
#     官方 OpenWrt 发布物里也没有这一行（实测官方 sha256sums 0 条 minisig）。
#
# (2) 未发布产物的行（ext4 变体 / kernel.bin / rootfs.tar.gz / buildinfo …）
#     OpenWrt 对整个 bin/targets/x86/64/ 目录生成校验和，但 Release 只发
#     release-assets.txt 里那些文件。剩下的行用户永远比对不了（下载不到），
#     跑 `sha256sum -c` 一样是 "FAILED open or read" 误报。
#     所以签名前按发布清单裁剪：发什么，签什么，其余一律不进 sha256sums。
sums_lines = open(sums_path, encoding="utf-8").read().splitlines(keepends=True)


def entry_name(line):
    """从 'hash *name' / 'hash  name' 提取文件名（去掉 binary 模式的 *）。"""
    parts = line.split(None, 1)
    return parts[1].strip().lstrip("*").strip() if len(parts) > 1 else ""


published_path = os.environ.get("MINISIGN_PUBLISHED_ASSETS", "")
allow_missing_list = os.environ.get("MINISIGN_ALLOW_NO_PUBLISHED_LIST", "0") == "1"

published = None
if os.path.isfile(published_path):
    published = {
        os.path.basename(l.strip())
        for l in open(published_path, encoding="utf-8")
        if l.strip() and not l.strip().startswith("#")
    }
    if not published:
        sys.exit(f"❌ 发布清单 {published_path} 里没有任何有效条目")
elif allow_missing_list:
    # 只在离线调试时显式允许；CI 里禁止静默降级
    print(f"⚠️  未找到发布清单 {published_path}，按 MINISIGN_ALLOW_NO_PUBLISHED_LIST=1 跳过裁剪")
else:
    sys.exit(
        f"❌ 未找到发布清单 {published_path}\n"
        "   sha256sums 必须按发布清单裁剪，否则用户校验会看到指向未发布产物的 FAILED。\n"
        "   离线调试确需跳过时，显式设置 MINISIGN_ALLOW_NO_PUBLISHED_LIST=1。"
    )

kept = []
dropped_self = 0
dropped_unpublished = 0
for line in sums_lines:
    if not line.strip():
        kept.append(line)
        continue
    name = entry_name(line)
    if name == "sha256sums.minisig":
        dropped_self += 1
        continue
    if published is not None and os.path.basename(name) not in published:
        dropped_unpublished += 1
        continue
    kept.append(line)

if len(kept) != len(sums_lines):
    with open(sums_path, "w", encoding="utf-8") as fh:
        fh.writelines(kept)
    if dropped_self:
        print(f"🧹 已从 sha256sums 移除 {dropped_self} 行自引用（*sha256sums.minisig）")
    if dropped_unpublished:
        print(f"🧹 已移除 {dropped_unpublished} 行未发布产物（不在 release-assets.txt 内）")
    print(f"📄 sha256sums 现为 {len(kept)} 行，全部可随 Release 下载比对")
else:
    print(f"📄 sha256sums 已是 {len(kept)} 行，无需裁剪")

# 清单里有、但 OpenWrt 没生成校验和的条目（例如 feeds.conf.default）只是提示
if published is not None:
    in_sums = {os.path.basename(entry_name(l)) for l in kept if l.strip()}
    not_checksummed = sorted(n for n in published if n not in in_sums and not n.endswith("sha256sums.minisig"))
    if not_checksummed:
        print(f"ℹ️  以下发布项不在 sha256sums 内（OpenWrt 未对其生成校验和）：{', '.join(not_checksummed)}")

# ── 签名 ──────────────────────────────────────────────────────────────
# minisign 默认走 prehashed 模式：先 blake2b-512(文件内容)，再对摘要做 Ed25519
digest = hashlib.blake2b(open(sums_path, "rb").read(), digest_size=64).digest()
sig = sk.sign(digest).signature

# 签名 blob = 算法标识 'ED' + keyid + 64 字节签名 = 74 字节
# 'ED' = prehashed（blake2b-512），'Ed' = 对原文直接签
sig_blob = b"ED" + key_id + sig

# 全局签名：对「签名 + trusted comment 纯文本」签名（不含 "trusted comment: " 前缀）
global_sig = sk.sign(sig + COMMENT.encode()).signature

out = (
    "untrusted comment: signature from minisign secret key\n"
    + base64.b64encode(sig_blob).decode()
    + "\n"
    + "trusted comment: "
    + COMMENT
    + "\n"
    + base64.b64encode(global_sig).decode()
    + "\n"
)
with open(out_path, "w", encoding="utf-8") as fh:
    fh.write(out)

print(f"✅ 签名完成: {out_path}")
print(f"   签名大小: {os.path.getsize(out_path)} bytes")
PY

# 清除敏感环境变量（安全）
unset MINISIGN_SECRET_KEY MINISIGN_KEY_ID
echo "🔒 已清除密钥环境变量"
