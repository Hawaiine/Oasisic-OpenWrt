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

# 裁剪清单用仓库里真实的那份（单一真源），保证测试与 CI 跑的是同一份列表
cp "$REPO_ROOT/release-assets.txt" "$WORK/.github/release-assets.txt"

# 假 sha256sums 里故意混入两类「永远不可能自洽」的行，模拟真实构建目录：
#   1. 对 sha256sums.minisig 自身的引用（用源码树缓存时 OpenWrt 会把上一轮
#      残留 minisig 的哈希写进来，我们随后覆盖该文件 → 该行必然对不上）
#   2. 未发布产物（ext4 变体这类 Release 里根本没有的文件），用户比对不了
# 不处理的话用户 `sha256sum -c` 会看到 "FAILED open or read"，
# 误以为文件被篡改。裁剪后只应剩发布清单内的行。
printf 'abc123  openwrt-x86-64-generic-squashfs-combined-efi.img.gz\n' > "$WORK/sha256sums"
printf 'def456  openwrt-x86-64-generic-image-efi.iso\n' >> "$WORK/sha256sums"
printf 'feed99  openwrt-x86-64-generic-ext4-combined-efi.img.gz\n' >> "$WORK/sha256sums"
printf 'beef77  openwrt-x86-64-generic-kernel.bin\n' >> "$WORK/sha256sums"
printf 'deadbeef  *sha256sums.minisig\n' >> "$WORK/sha256sums"

echo "◆ 临时密钥已生成（keyid ${KID}）"

# ─── 2. 用被测脚本签名 ─────────────────────────────────────────────────
if ! MINISIGN_SECRET_KEY="$SEED" \
     MINISIGN_KEY_ID="$KID" \
     MINISIGN_PUB_FILE="$WORK/.github/minisign.pub" \
     MINISIGN_PUBLISHED_ASSETS="$WORK/.github/release-assets.txt" \
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

# sha256sums 里既不能有对本签名的自引用行，也不能有未发布产物的行：
# 两种都会让用户 `sha256sum -c` 报永远无法消除的 FAILED（文件下载不到 / 签名自引用）
sums_text = open(f"{work}/sha256sums").read()
assert "sha256sums.minisig" not in sums_text, (
    "sha256sums 里仍有 *sha256sums.minisig 自引用行——用户校验时会误报文件被篡改"
)
assert "ext4-combined-efi.img.gz" not in sums_text, (
    "sha256sums 里仍有未发布产物（ext4 变体）的行——用户下载不到，校验必报 FAILED open or read"
)
assert "kernel.bin" not in sums_text, (
    "sha256sums 里仍有未发布产物（kernel.bin）的行——用户下载不到，校验必报 FAILED open or read"
)
for name in (
    "openwrt-x86-64-generic-squashfs-combined-efi.img.gz",
    "openwrt-x86-64-generic-image-efi.iso",
):
    assert name in sums_text, f"裁剪过度：发布清单内的 {name} 被误删了"
print("   ✅ 裁剪正确：自引用行与未发布产物行已移除，发布内文件保留")

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

# ─── 4.5 缺发布清单必须硬失败（禁止静默降级）───────────────────────────
# 拿不到 release-assets.txt 时如果「跳过裁剪照签」，线上又会回到
# 「17 行 / 16 行里 9 行指向不存在的文件」的老样子——这类降级必须红。
echo "◆ 负向测试：拿不到发布清单必须硬失败，不得静默跳过裁剪"
cp "$WORK/sha256sums" "$WORK/sums.bak"
printf 'evil11  openwrt-x86-64-generic-ext4-combined.img.gz\n' >> "$WORK/sha256sums"
if MINISIGN_SECRET_KEY="$SEED" \
   MINISIGN_KEY_ID="$KID" \
   MINISIGN_PUB_FILE="$WORK/.github/minisign.pub" \
   MINISIGN_PUBLISHED_ASSETS="$WORK/does-not-exist.txt" \
   bash "$SIGNER" "$WORK/sha256sums" >"$WORK/sign-nolist.log" 2>&1; then
  echo "   ❌ 缺发布清单竟然签成功了（静默降级）"
  exit 1
fi
grep -q "未找到发布清单" "$WORK/sign-nolist.log" || {
  echo "   ❌ 失败原因不是缺发布清单："
  cat "$WORK/sign-nolist.log"
  exit 1
}
grep -q "ext4-combined.img.gz" "$WORK/sha256sums" || {
  echo "   ❌ 硬失败时 sha256sums 已被改动（应先失败再动手）"
  exit 1
}
echo "   ✅ 缺发布清单 → 硬失败，且未改动 sha256sums"
cp "$WORK/sums.bak" "$WORK/sha256sums"

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
