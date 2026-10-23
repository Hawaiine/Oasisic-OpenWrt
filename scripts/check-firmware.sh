#!/bin/bash
# =============================================================
# Oasisic OpenWrt — 固件完整性自检脚本
# 双层验证: APK/IPK 检查（信息级）+ squashfs 解压检查（信息级）
# 注意：所有检查均为信息级，不阻断构建（固件镜像独立于包位置）
# 用法: bash scripts/check-firmware.sh <build-dir>
# =============================================================
set -e

BUILD_DIR="${1:-openwrt}"
TARGET_DIR="${BUILD_DIR}/bin/targets/x86/64"
PKG_DIR="${BUILD_DIR}/bin/packages/x86_64"

PASS=0
FAIL=0
WARN=0

check() {
    local desc="$1"
    local mode="${3:-fail}"
    if [ "$2" -eq 0 ]; then
        echo "  ✅ $desc"
        PASS=$((PASS + 1))
    elif [ "$mode" = "warn" ]; then
        echo "  ⚠️  $desc"
        WARN=$((WARN + 1))
    else
        echo "  ❌ $desc"
        FAIL=$((FAIL + 1))
    fi
}

echo "═══════════════════════════════════════════"
echo "  固件完整性自检"
echo "═══════════════════════════════════════════"
echo ""

# ─── Tier 1: APK/IPK 检查（信息级）────────────────
echo "◆ Tier 1: APK 完整性检查（信息级）"

# 1.1 搜索 luci-base APK（OpenWrt 25.12+ 用 .apk，旧版用 .ipk）
LUCI_APK=$(find "${PKG_DIR}" -name "luci-base*.apk" -o -name "luci-base_*.ipk" 2>/dev/null | head -1)
check "luci-base 包存在" $([ -n "$LUCI_APK" ]; echo $?)

# 1.1a APK 迁移期检查：确认包格式一致性（25.12 应全为 .apk 或全为 .ipk）
echo "  --- APK 迁移期检查 ---"
APK_COUNT=$(find "${PKG_DIR}" -name "*.apk" -type f 2>/dev/null | wc -l)
IPK_COUNT=$(find "${PKG_DIR}" -name "*.ipk" -type f 2>/dev/null | wc -l)
if [ "$APK_COUNT" -gt 0 ] && [ "$IPK_COUNT" -gt 0 ]; then
  echo "  ⚠️  混用包格式: ${APK_COUNT} 个 .apk + ${IPK_COUNT} 个 .ipk（可能引发依赖解析问题）"
  WARN=$((WARN + 1))
elif [ "$APK_COUNT" -gt 0 ]; then
  echo "  ✅ 纯 APK 格式: ${APK_COUNT} 个包（25.12 标准）"
  PASS=$((PASS + 1))
else
  echo "  ✅ 纯 IPK 格式: ${IPK_COUNT} 个包（旧版兼容）"
  PASS=$((PASS + 1))
fi

# 1.1b 检查 APK INDEX 存在（APK 仓库数据库完整性）
if [ "$APK_COUNT" -gt 0 ]; then
  APK_INDEX=$(find "${PKG_DIR}" -name "APKINDEX.tar.gz" -type f 2>/dev/null | head -1)
  if [ -n "$APK_INDEX" ]; then
    # 验证 APKINDEX 可解压
    if tar -tzf "$APK_INDEX" >/dev/null 2>&1; then
      echo "  ✅ APKINDEX.tar.gz 存在且可解压"
      PASS=$((PASS + 1))
    else
      echo "  ⚠️  APKINDEX.tar.gz 损坏（无法解压）"
      WARN=$((WARN + 1))
    fi
  else
    echo "  ⚠️  APKINDEX.tar.gz 不存在（APK 仓库无数据库）"
    WARN=$((WARN + 1))
  fi
fi

if [ -n "$LUCI_APK" ]; then
    TMPDIR=$(mktemp -d)

    # 兼容两种包格式：APK (tar.gz + tar.gz 拼接) 和 IPK (ar + tar.gz)
    case "$LUCI_APK" in
        *.apk)
            # APK 格式: control.tar.gz (gzip) + data.tar.gz (gzip) 拼接
            python3 -c "
import gzip, tarfile, io, os, sys

apk_path = '$LUCI_APK'
out_dir = '$TMPDIR'

with open(apk_path, 'rb') as f:
    raw = f.read()

pos = 0
n = 0
while pos < len(raw):
    if raw[pos:pos+2] != b'\\x1f\\x8b':
        break
    # 解压当前 gzip 流
    with gzip.GzipFile(fileobj=io.BytesIO(raw[pos:])) as gz:
        tar_data = gz.read()
    # 提取 tar 内容
    tmp_tar = os.path.join(out_dir, f'.stream_{n}.tar')
    with open(tmp_tar, 'wb') as tf:
        tf.write(tar_data)
    with tarfile.open(tmp_tar) as tf:
        tf.extractall(path=out_dir)
    os.unlink(tmp_tar)
    # 找下一个 gzip 流
    next_gz = raw.find(b'\\x1f\\x8b', pos + 20)
    if next_gz == -1:
        n += 1
        break
    pos = next_gz
    n += 1
print(f'  解压 {n+1} 个 gzip 流')
" 2>/dev/null || true
            ;;
        *.ipk)
            (cd "$TMPDIR" && ar x "$LUCI_APK" 2>/dev/null && tar -xzf data.tar.gz 2>/dev/null) || true
            ;;
    esac

    # 1.2 检查 etc/config/luci 中有 resourcebase
    if [ -f "$TMPDIR/etc/config/luci" ]; then
        HAS_RB=$(grep -c 'resourcebase' "$TMPDIR/etc/config/luci" 2>/dev/null || echo 0)
        check "luci config: resourcebase 存在" $([ "$HAS_RB" -gt 0 ]; echo $?)
        HAS_UBUS=$(grep -c 'ubuspath' "$TMPDIR/etc/config/luci" 2>/dev/null || echo 0)
        check "luci config: ubuspath 存在" $([ "$HAS_UBUS" -gt 0 ]; echo $?)
    else
        echo "  ⚠️  未找到 /etc/config/luci（可能 embedded 而非包内）"
    fi

    # 1.3 检查静态资源（信息级，包结构因版本而异）
    for JS in "luci.js" "cbi.js"; do
        JS_PATH=$(find "$TMPDIR" -name "$JS" -type f 2>/dev/null | head -1)
        if [ -n "$JS_PATH" ] && [ -s "$JS_PATH" ]; then
            echo "  ✅ $JS 存在且非空（$(wc -c < "$JS_PATH") bytes）"
            PASS=$((PASS + 1))
        else
            echo "  ⚠️  $JS 不在 luci-base 包内（可能在其他 luci 子包中）"
            WARN=$((WARN + 1))
        fi
    done

    rm -rf "$TMPDIR"
fi

echo ""

# ─── Tier 2: 固件 squashfs 提取检查（信息级）───
echo "◆ Tier 2: 固件 squashfs 检查（信息级）"

# 多固件文件名匹配：find 搜索所有 .img.gz 和 .img 文件
FIRMWARE=""
for pattern in "*squashfs-combined*.img.gz" "*squashfs-combined*.img" "*.img.gz" "*.img"; do
    FOUND=$(find "${TARGET_DIR}" -maxdepth 1 -name "$pattern" -type f 2>/dev/null | head -1)
    if [ -n "$FOUND" ]; then
        FIRMWARE="$FOUND"
        break
    fi
done

if [ -f "$FIRMWARE" ]; then
    echo "  📦 固件: $(basename "$FIRMWARE") ($(du -h "$FIRMWARE" | cut -f1))"

    TMP_IMG=""
    # 解压
    if echo "$FIRMWARE" | grep -q '\.gz$'; then
        TMP_IMG=$(mktemp /tmp/oasisic-check.XXXXXX.img)
        gunzip -c "$FIRMWARE" > "$TMP_IMG" 2>/dev/null || true
        IMG="$TMP_IMG"
    else
        IMG="$FIRMWARE"
    fi

    if [ -f "$IMG" ]; then
        # 方法 1: fdisk 检测 Linux 分区偏移
        OFFSET=""
        FDISK_OUT=$(fdisk -l "$IMG" 2>/dev/null || true)
        if [ -n "$FDISK_OUT" ]; then
            OFFSET=$(echo "$FDISK_OUT" | grep -i 'linux' | head -1 | awk '{print $2}' 2>/dev/null)
            if [ -n "$OFFSET" ]; then
                OFFSET=$((OFFSET * 512))
            fi
        fi

        # 方法 2: hsqs magic 字节搜索（双保险）
        if [ -z "$OFFSET" ] || [ "$OFFSET" -le 0 ] 2>/dev/null; then
            OFFSET=$(python3 -c "
import re
with open('$IMG','rb') as f:
    data=f.read()
    m=re.search(b'hsqs', data)
    if m: print(m.start()-4)
    else: print('')" 2>/dev/null || echo "")
        fi

        if [ -n "$OFFSET" ] && [ "$OFFSET" -gt 0 ] 2>/dev/null; then
            TMP2=$(mktemp -d)
            unsquashfs -o "$OFFSET" -d "$TMP2" "$IMG" >/dev/null 2>&1 || true

            # 检查 LuCI 关键文件（信息级，用 WARN 计数器）
            # OpenWrt 25.12 的 LuCI 路径可能有变化，搜多个可能路径
            for CHK in "www/cgi-bin/luci" "www/luci-static/resources/luci.js" "etc/config/luci" "usr/share/ucode/luci/"; do
                check "固件: $CHK 存在" $([ -f "$TMP2/$CHK" ] || [ -d "$TMP2/$CHK" ]; echo $?) warn
            done

            # 检查 99-custom 脚本内容（语言注册 + 诊断地址 + 清理确认）
            CUSTOM_SCRIPT="$TMP2/etc/uci-defaults/99-custom"
            if [ -f "$CUSTOM_SCRIPT" ]; then
                for DIAG_KEY in "luci.diag.dns='119.29.29.29'" "luci.diag.ping='119.29.29.29'" "luci.diag.route='119.29.29.29'"; do
                    check "99-custom: 包含 $DIAG_KEY" $(grep -cq "$DIAG_KEY" "$CUSTOM_SCRIPT"; echo $?)
                done
                check "99-custom: 已清理 luci.title.title（不存在）" $(! grep -cq "luci.title.title" "$CUSTOM_SCRIPT"; echo $?) warn
            else
                echo "  ⚠️  99-custom 脚本不在固件中（可能被其他 uci-defaults 脚本替代）"
                WARN=$((WARN + 1))
            fi

            rm -rf "$TMP2"
        else
            echo "  ⚠️  无法确定 squashfs 分区偏移"
        fi

        # 清理临时解压文件
        if [ -n "$TMP_IMG" ] && [ -f "$TMP_IMG" ]; then
            rm -f "$TMP_IMG"
        fi
    fi
else
    echo "  ⚠️  固件镜像未找到（搜索路径: ${TARGET_DIR}）"
fi

echo ""
echo "═══════════════════════════════════════════"
echo "  结果: $PASS ✅  /  $FAIL ❌  /  $WARN ⚠️"
echo "═══════════════════════════════════════════"

# 所有检查均为信息级，不阻断构建
echo "ℹ️  所有检查均为信息级，不阻断构建"
exit 0