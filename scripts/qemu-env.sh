#!/usr/bin/env bash
# 安装并定位 QEMU / OVMF，导出 QEMU_BIN 与 OVMF_CODE。
#
# 用法：source scripts/qemu-env.sh
#
# 关键点（2026-10-24 事故教训）：
#   1. runner 镜像会清空 apt 索引，必须先 apt-get update，
#      否则 apt-get install 会「找不到包」而失败 —— 之前这一步的 stderr 被
#      2>/dev/null 吞掉，结果三个候选包全静默失败，qemu-smoke-test 直接挂。
#   2. ovmf 与 qemu 分开安装：ovmf 缺失不应该连累 qemu 的安装判定。
#   3. 找不到就是硬失败（假绿比失败危险），但错误信息必须打出来。
set -euo pipefail

echo "🔄 更新 apt 索引（镜像可能已清空索引，不更新必然装不上）"
sudo apt-get update -qq

# ─── ovmf（固件）──────────────────────────────────────────────────────────
if ! sudo apt-get install -y -qq ovmf; then
  echo "⚠️ ovmf 包安装失败，稍后用 dpkg / 全盘搜索兜底"
fi

# ─── qemu（26.04 起包名由 qemu-system-x86-64 改为 qemu-system-x86）─────────
QEMU_PKG=""
for pkg in qemu-system-x86 qemu-system-x86-64 qemu-system; do
  if sudo apt-get install -y -qq "$pkg"; then
    echo "✅ qemu 包: $pkg"
    QEMU_PKG="$pkg"
    break
  fi
  echo "⚠️ $pkg 安装失败，换下一个包名"
done

QEMU_BIN="$(command -v qemu-system-x86_64 || true)"
if [ -z "$QEMU_BIN" ]; then
  QEMU_BIN="$(ls -1 /usr/bin/qemu-system-x86* 2>/dev/null | head -1 || true)"
fi
if [ -z "$QEMU_BIN" ]; then
  echo "❌ 未找到 qemu-system-x86_64（已尝试包：${QEMU_PKG:-无}，以及 /usr/bin/qemu-system-x86*）"
  exit 1
fi

# ─── OVMF 固件定位（6 个常见路径 → dpkg -L → 全盘搜索）────────────────────
OVMF_CODE=""
for f in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
         /usr/share/ovmf/OVMF_CODE_4M.fd /usr/share/ovmf/OVMF_CODE.fd \
         /usr/share/qemu/OVMF_CODE_4M.fd /usr/share/qemu/OVMF_CODE.fd; do
  [ -f "$f" ] && OVMF_CODE="$f" && break
done
if [ -z "$OVMF_CODE" ]; then
  OVMF_CODE="$(dpkg -L ovmf 2>/dev/null | grep -E '/OVMF_CODE[^/]*\.fd$' | head -1 || true)"
fi
if [ -z "$OVMF_CODE" ]; then
  OVMF_CODE="$(sudo find /usr/share -maxdepth 4 -name 'OVMF_CODE*.fd' -type f 2>/dev/null | head -1 || true)"
fi
if [ -z "$OVMF_CODE" ]; then
  echo "❌ 未找到 OVMF 固件：已尝试 /usr/share/{OVMF,ovmf,qemu}、dpkg -L ovmf、全盘搜索"
  echo "   请确认 ovmf 包是否装成功；qemu 烟雾测试不能静默跳过"
  exit 1
fi

export QEMU_BIN OVMF_CODE
echo "✅ QEMU: $QEMU_BIN"
echo "✅ OVMF: $OVMF_CODE"
