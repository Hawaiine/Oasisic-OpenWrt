#!/bin/bash
# test-minisign-sign.sh — 自检 minisign-sign.sh 产出的签名是不是真的能被 minisign 验证
#
# 背景：2026-10-24 发现线上 Release 的 sha256sums.minisig 是废签名，
# `minisign -V` 直接报 "base64 conversion failed"——因为旧脚本既漏了
# 2 字节算法前缀，又把全局签名的拼接顺序搞错了。这种错 CI 一路绿灯，
# 只有用户下载后才会发现。所以这里加一道「签名必须真的能验」的自检。
#
# 用法: bash scripts/test-minisign-sign.sh
# 依赖: python3 + pynacl；能联网时额外用官方 minisign 二进制双向验证
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGNER="${REPO_ROOT}/scripts/minisign-sign.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "═══════════════════════════════════════════"
echo "  minisign 签名自检"
echo "═══════════════════════════════════════════"

# ─── 1. 造一套临时密钥（不碰真实 Secrets）──────────────────────────────
read -r SEED KID PUB_B64 <<<"$(python3 - <<'PY'
import base64, os
from nacl.signing import SigningKey
seed = os.urandom(32)
key_id = os.urandom(8)
pub = bytes(SigningKey(seed).verify_key)
print(seed.hex(), key_id.hex(), base64.b64encode(b"Ed" + key_id + pub).decode())
PY
)"

mkdir -p "$WORK/.github"
printf 'untrusted comment: minisign public key for self-test\n%s\n' "$PUB_B64" \
  > "$WORK/.github/minisign.pub"
printf 'abc123  test.img.gz\ndef456  test.iso\n' > "$WORK/sha256sums"

echo "◆ 临时密钥已生成（keyid ${KID}）"

# ─── 2. 用被测脚本签名 ─────────────────────────────────────────────────
if ! MINISIGN_SECRET_KEY="$SEED" \
     MINISIGN_KEY_ID="$KID" \
     MINISIGN_PUB_FILE="$WORK/.github/minisign.pub" \
     bash "$SIGNER" "$WORK/sha256sums" >"$WORK/sign.log" 2>&1; then
  echo "❌ 签名脚本执行失败"
  cat "$WORK/sign.log"
  exit 1
fi
sed 's/^/   /' "$WORK/sign.log"
echo "◆ 签名文件已产出"

# ─── 3. 格式断言（不依赖外部二进制）────────────────────────────────────
echo "◆ 格式断言"
python3 - "$WORK" <<'PY'
import base64, hashlib, sys
from nacl.signing import VerifyKey

work = sys.argv[1]
pub_blob = base64.b64decode(
    [l for l in open(f"{work}/.github/minisign.pub").read().splitlines() if l.strip()][-1]
)
key_id, pub = pub_blob[2:10], pub_blob[10:42]
vk = VerifyKey(pub)

lines = open(f"{work}/sha256sums.minisig").read().splitlines()
assert len(lines) == 4, f"签名文件应为 4 行，实际 {len(lines)}"
assert lines[0].startswith("untrusted comment: "), "第 1 行必须是 untrusted comment"
assert lines[2].startswith("trusted comment: "), "第 3 行必须是 trusted comment"

blob = base64.b64decode(lines[1])
assert len(blob) == 74, f"签名 blob 应为 74 字节（2 alg + 8 keyid + 64 sig），实际 {len(blob)}"
assert blob[:2] == b"ED", f"算法前缀应为 'ED'（prehashed），实际 {blob[:2]!r}"
assert blob[2:10] == key_id, "签名里的 keyid 与公钥不一致"

digest = hashlib.blake2b(open(f"{work}/sha256sums", "rb").read(), digest_size=64).digest()
vk.verify(digest, blob[10:])
print("   ✅ 主签名：74 字节 / 'ED' 前缀 / 对 blake2b-512 签名 → 验证通过")

comment = lines[2].split(": ", 1)[1]
vk.verify(blob[10:] + comment.encode(), base64.b64decode(lines[3]))
print("   ✅ 全局签名：sign(sig || trusted_comment) → 验证通过")
PY

# ─── 4. 篡改必须被发现 ────────────────────────────────────────────────
echo "◆ 负向测试：篡改内容后验签必须失败"
python3 - "$WORK" <<'PY'
import base64, hashlib, sys
from nacl.exceptions import BadSignatureError
from nacl.signing import VerifyKey

work = sys.argv[1]
pub = base64.b64decode(
    [l for l in open(f"{work}/.github/minisign.pub").read().splitlines() if l.strip()][-1]
)[10:42]
blob = base64.b64decode(open(f"{work}/sha256sums.minisig").read().splitlines()[1])
tampered = open(f"{work}/sha256sums", "rb").read() + b"evil  x\n"
digest = hashlib.blake2b(tampered, digest_size=64).digest()
try:
    VerifyKey(pub).verify(digest, blob[10:])
except BadSignatureError:
    print("   ✅ 篡改后验签失败（符合预期）")
else:
    sys.exit("   ❌ 篡改后验签竟然通过了——签名没覆盖内容！")
PY

# ─── 5. 有官方二进制就用它再验一遍（黄金标准）──────────────────────────
echo "◆ 官方 minisign 二进制交叉验证"
MSIG_BIN=""
if command -v minisign >/dev/null 2>&1; then
  MSIG_BIN="$(command -v minisign)"
elif curl -fsSL --retry 3 --retry-delay 2 --max-time 90 -o "$WORK/minisign.tar.gz" \
     https://github.com/jedisct1/minisign/releases/download/0.12/minisign-0.12-linux.tar.gz 2>/dev/null; then
  tar xzf "$WORK/minisign.tar.gz" -C "$WORK" 2>/dev/null || true
  [ -x "$WORK/minisign-linux/x86_64/minisign" ] && MSIG_BIN="$WORK/minisign-linux/x86_64/minisign"
fi

if [ -z "$MSIG_BIN" ]; then
  # 拿不到官方二进制就只做了格式断言——这正是「静默降级」，不能默认放过
  if [ "${MINISIGN_ALLOW_NO_BINARY:-0}" = "1" ]; then
    echo "   ⚠️  拿不到官方二进制，按 MINISIGN_ALLOW_NO_BINARY=1 仅做格式断言"
  else
    echo "   ❌ 拿不到官方 minisign 二进制，无法做黄金标准验签"
    echo "      离线环境请显式设置 MINISIGN_ALLOW_NO_BINARY=1 再跑"
    exit 1
  fi
else
  "$MSIG_BIN" -V -m "$WORK/sha256sums" -x "$WORK/sha256sums.minisig" \
    -p "$WORK/.github/minisign.pub" | sed 's/^/   /'
  echo "   ✅ 官方 minisign 验签通过"

  # 反向：官方二进制也必须判篡改失败
  cp "$WORK/sha256sums" "$WORK/tampered"
  echo 'evil  x' >> "$WORK/tampered"
  if "$MSIG_BIN" -V -m "$WORK/tampered" -x "$WORK/sha256sums.minisig" \
       -p "$WORK/.github/minisign.pub" >/dev/null 2>&1; then
    echo "   ❌ 官方二进制对篡改内容竟然验签通过"
    exit 1
  fi
  echo "   ✅ 官方二进制正确拒绝篡改内容"
fi

echo ""
echo "🎉 minisign 签名自检全部通过"
