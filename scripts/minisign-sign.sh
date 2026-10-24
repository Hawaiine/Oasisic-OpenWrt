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
set -euo pipefail

SHA256SUMS="${1:-sha256sums}"
OUT_DIR="$(dirname "$SHA256SUMS")"
OUTPUT="${OUT_DIR}/sha256sums.minisig"

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
