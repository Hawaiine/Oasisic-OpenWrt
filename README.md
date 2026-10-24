# 🏝️ Oasisic OpenWrt

> 全自动 OpenWrt 固件构建 · 源码编译 Nikki · PVE 开箱即用

[![build](https://github.com/Hawaiine/Oasisic-OpenWrt/actions/workflows/openwrt-auto-build.yml/badge.svg)](https://github.com/Hawaiine/Oasisic-OpenWrt/actions/workflows/openwrt-auto-build.yml)
[![release](https://img.shields.io/github/v/release/Hawaiine/Oasisic-OpenWrt?logo=github&label=release)](https://github.com/Hawaiine/Oasisic-OpenWrt/releases)
[![last commit](https://img.shields.io/github/last-commit/Hawaiine/Oasisic-OpenWrt/main?logo=git&label=last%20commit)](https://github.com/Hawaiine/Oasisic-OpenWrt/commits/main)
[![OpenWrt](https://img.shields.io/github/v/release/openwrt/openwrt?logo=openwrt&label=OpenWrt&color=00b4ff)](https://openwrt.org)
[![Nikki](https://img.shields.io/github/v/release/nikkinikki-org/OpenWrt-nikki?logo=go&label=Nikki&color=ff6600)](https://github.com/nikkinikki-org/OpenWrt-nikki)
[![PVE](https://img.shields.io/badge/PVE-ready-570c2e?logo=proxmox)](https://www.proxmox.com)
[![License](https://img.shields.io/badge/license-GPLv2-blue)](LICENSE)
[![Platform](https://img.shields.io/badge/x86__64-squashfs-ff69b4)](https://downloads.openwrt.org/releases/targets/x86/64/)

---

## 📖 目录

- [📖 目录](#-目录)
- [⚡ 快速上手](#-快速上手)
- [📋 项目简介](#-项目简介)
- [✨ 特性一览](#-特性一览)
- [🧭 设置向导（首次启动）](#-设置向导首次启动)
- [🏗️ 编译流水线](#️-编译流水线)
- [📂 项目结构](#-项目结构)
- [🚦 构建策略：自动 vs 手动](#-构建策略自动-vs-手动)
- [🚀 手动构建（workflow_dispatch）](#-手动构建workflow_dispatch)
- [🧪 PR 验证（先 PR 后合并）](#-pr-验证先-pr-后合并)
- [🔑 Secrets 与签名](#-secrets-与签名)
- [🖥️ PVE 导入](#️-pve-导入)
- [🛡️ 安全与源](#️-安全与源)
- [❓ 常见问题（FAQ）](#-常见问题faq)
- [🔧 排错](#-排错)
- [📌 相关项目](#-相关项目)
- [📜 版本与发布](#-版本与发布)
- [📜 许可证](#-许可证)

---

## ⚡ 快速上手

**只想用固件 —— 3 步**

1. **下载**：到 [Releases](https://github.com/Hawaiine/Oasisic-OpenWrt/releases) 取最新的 `*-squashfs-combined-efi.img.gz`（PVE / UEFI 推荐；传统 BIOS 用 `*-squashfs-combined.img.gz`）。**若 Releases 为空**，说明产物已清理，按下面的「想自己编译」跑一次即可生成
2. **导入 PVE**：复制 [🖥️ PVE 导入](#️-pve-导入) 里的命令块执行即可
3. **首次配置**：首次启动是 DHCP 客户端 —— 到主路由的 DHCP 列表找主机名 `Oasisic-OpenWrt`，浏览器打开它的 IP，按向导设置静态 IP 和管理员密码；root 密码以对应 Release 正文为准

**想自己编译**：Actions → `openwrt-auto-build` → **Run workflow**；当前版本已构建过时需勾选 **`force_build`**，否则会因为「版本未变化」直接跳过。参数与示例见 [🚀 手动构建](#-手动构建workflow_dispatch)。

⏱ 耗时参考：冷构建约 90–115 分钟；命中缓存约 40–70 分钟（GitHub 免费 runner，2 核 4 线程）。

---

## 📋 项目简介

**Oasisic OpenWrt** 是一套面向 x86_64 / PVE 的 OpenWrt 固件自动编译系统：从官方 SDK 全量编译，经 feeds 源码集成 Nikki（mihomo），构建后经 QEMU 烟雾测试，再发布 GitHub Release 并做 minisign 签名。

| | |
|---|---|
| 🏝️ **项目** | Oasisic OpenWrt |
| 📡 **流水线** | lint → check-upstream → build → qemu-smoke-test → release / ci-prerelease → persist-last-build（失败自动发红卡） |
| 🎯 **上游跟踪** | OpenWrt 最新 Release Tag；Nikki 默认同最新 Release Tag，手动可覆盖为分支 / Commit |
| ⏱ **耗时参考** | 冷构建约 90–115 分钟；缓存命中约 40–70 分钟（GitHub 免费 runner） |
| 📦 **产物** | squashfs 镜像 · ISO · sha256sums · minisig · feeds.conf.default · manifest |

---

## ✨ 特性一览

| 类别 | 说明 |
|------|------|
| 🏗️ 全量 SDK | 从 OpenWrt 源码编译，Nikki / mihomo-meta / luci-app-nikki 由 feeds 源码集成 |
| 🔄 定时 + 手动 | 每天 UTC 06:00（北京 14:00）检测上游，GitHub 排队常延到北京 18:00–22:30；Actions 可手动 `force_build` / `nikki_ref` / `runner_image` |
| 📌 Nikki 钉定 | 解析 Tag/分支/短 SHA → 完整 40 位 SHA；feeds 使用 `url^SHA`（Commit）或 `url;Tag/分支` |
| 🏷️ Release 命名 | `{OpenWrt版本}-n{Nikki短SHA}`（如 `25.12.6-n31339d5`），同版本不同 Nikki 提交可共存 |
| 🧪 QEMU 门禁 | 启动固件，检查 LuCI 返回 200 与 JS 资源非 gzip；qemu/OVMF 缺失直接失败（不再“绿着跳过”） |
| 🔬 PR 验证 | 改 workflow / scripts / files 的 PR 自动跑 lint；打 `ci:full-build` 标签跑全量编译，产物走 `ci-*` prerelease |
| 🔔 通知 | 成功/失败都发 Discord 卡片（Components V2）；失败卡片直接列出失败任务与失败步骤 |
| 💓 保活 | `keepalive.yml` 每周提交一次心跳，防 60 天无活动被 GitHub 停用 schedule |
| 🔏 minisign | 对 `sha256sums` 签名，Release 附带 `sha256sums.minisig`（公钥见 `.github/minisign.pub`） |
| 🖥️ PVE | qemu-ga + virtio 驱动；默认 LAN DHCP，无硬编码局域网 IP |
| 🧭 首次向导 | 纯 HTML/CSS/JS + CGI；完成后自禁用 |
| 🈴 中文 LuCI | `99-custom` 注册 `luci.languages.zh_cn`（规避 openwrt#16987） |
| 🌐 诊断默认 | DNSPod `119.29.29.29` |
| 🧹 维护任务 | `cleanup-actions.yml` 每 3 天清理过期失败 run / 旧 cache |

---

## 🧭 设置向导（首次启动）

### 流程

```
开机 → 99-custom 创建 /etc/.oasisic-firstboot
     → 访问设备 IP → index.html 检测标记
     → 进入 setup.html 配置网络 / 密码（可跳过）
     → CGI 写 uci、清标记、重启服务
     → 之后进入 LuCI
```

### 关键文件

| 路径 | 说明 |
|------|------|
| `files/www/index.html` | 入口检测 |
| `files/www/setup.html` | 设置向导页 |
| `files/www/cgi-bin/setup` | 配置写入 |
| `files/www/cgi-bin/check-firstboot` | 首次启动状态查询 |
| `files/www/cgi-bin/setup-rollback` | 有时限回滚入口 |
| `files/etc/uci-defaults/99-custom` | 语言 / 诊断 / 网络默认 |
| `files/usr/lib/oasisic/firstboot.sh` | 首次启动状态机 |
| `files/usr/lib/oasisic/setup-rollback.sh` | 回滚逻辑（约 30 分钟有效） |

### 安全要点

- 无外部 CDN 依赖
- 仅首次启动标记存在时可写配置
- 完成后 CGI 自禁用（`chmod 000`）
- IPv4 / 端口 / 密码长度校验
- 支持跳过：只清标记、不改网络

### LuCI 中文注册

全新固件上 `luci.languages` 可能不存在，`99-custom` 会执行：

```sh
uci set luci.languages='internal'
uci set luci.languages.zh_cn='简体中文 (Simplified Chinese)'
uci set luci.main.lang='zh_cn'
```

使用 `zh_cn`（下划线）与 LuCI 翻译宏一致；相关上游问题见 [openwrt#16987](https://bugs.openwrt.org/index.php?do=details&task_id=16987)。

诊断地址默认：

```sh
uci set luci.diag.dns='119.29.29.29'
uci set luci.diag.ping='119.29.29.29'
uci set luci.diag.route='119.29.29.29'
```

---

## 🏗️ 编译流水线

### 九个任务（正式构建与 PR 验证共用一条流水线）

```text
lint ─ qemu-env ─ check-upstream ─ build ─ qemu-smoke-test ─┬─ release ── persist-last-build（仅 main）
                        │                                    ├─ ci-prerelease（仅 PR）
                        │                                    └─ notify-failure（任一步失败）
```

| 任务 | 作用 | 何时运行 |
|------|------|----------|
| `lint` | `bash -n` / `py_compile` / workflow YAML / feeds 分隔符契约 | 所有 PR 与手动触发 |
| `qemu-env` | 在 runner 上真装一遍 QEMU/OVMF 并打印版本（镜像/包名漂移早暴露） | 总是（约 1.5 分钟） |
| `check-upstream` | 解析 OpenWrt latest tag、Nikki ref → 完整 SHA；与 `last_build_version` 比对 | 总是 |
| `build` | 三层缓存 → feeds → `.config` → 编译 → 签名 → 上传 Artifact | 有新版本 / `force_build` / PR 打 `ci:full-build` |
| `qemu-smoke-test` | QEMU 起固件，LuCI 返回 200 + JS 非 gzip | 同 `build` |
| `release` | GitHub Release + Discord 成功卡片 | 仅 `main` |
| `ci-prerelease` | 发 `ci-*` prerelease 直链，便于刷机测试 | 仅 PR |
| `notify-failure` | 任一任务失败时发红色失败卡片（失败任务 + 失败步骤 + 日志链接） | 任一任务失败 |
| `persist-last-build` | 回写 `last_build_version`（commit 带 `[skip ci]`） | 仅 `main` |

**通知**：成功/失败卡片都发到 Discord「🖥️・固件发布」频道。失败卡片会列出失败任务与失败步骤，并附「查看运行日志」按钮；缺 `DISCORD_BOT_TOKEN` 时通知步骤跳过，不影响构建本身。

### 运行环境

- Runner 固定 **`ubuntu-26.04`**（`ubuntu-latest` 在 2026-10-19→11-19 迁移窗口内会随机漂移，不用它）
- 如需对比验证另一镜像：手动触发时填 `runner_image`（如 `ubuntu-24.04`），不改代码
- 26.04 差异：`qemu-system-x86-64` 包已删除（用 `qemu-system-x86`）、`libncurses5-dev` 已无正式包（用 `libncurses-dev`）
- ⚠️ **新镜像出厂会清空 apt 索引**：任何 `apt-get install` 前必须先 `sudo apt-get update -qq`，
  否则会「找不到包」而静默失败（2026-10-24 就在这里挂了 21 秒）。安装/定位逻辑统一收在
  `scripts/qemu-env.sh`，错误全部可见；`qemu-env` 任务每次流水线都跑，镜像或包名一变几分钟内就红

### 缓存 Key（摘要）

| 缓存 | Key 要点 |
|------|----------|
| ccache | OpenWrt 版本 + **runner 镜像** + `gen-config.sh` hash |
| 源码树 | OpenWrt 版本 + **runner 镜像** + `gen-config.sh` hash（**不做跨镜像前缀回退**） |
| dl / feeds | OpenWrt 版本 + **Nikki 完整 SHA** + `gen-config.sh` hash |

> 源码树缓存里含 `staging_dir/host` 等构建态，跨镜像复用会让 `make` 误判“工具已编好”，
> 报 `staging_dir/host/bin/python3: No such file or directory`。恢复缓存后脚本会自检，
> 不可用则自动清空 `staging_dir/host`、`build_dir/host`、`tmp/stamp` 重建。

清理缓存或删除 `last_build_version` 后，下一次为冷构建（更慢，结果更“干净”）。

### Feeds 语法（重要）

OpenWrt `scripts/feeds`：

| 写法 | 含义 |
|------|------|
| `url;Tag或分支` | `git clone --depth 1 --branch …` |
| `url^完整Commit` | clone 后 fetch/checkout 该 Commit |

本仓库 CI 在解析出 40 位 SHA 后生成：

```text
src-git nikki https://github.com/nikkinikki-org/OpenWrt-nikki.git^<40位SHA>
```

Tag/分支调试仍可用 `;v1.26.2` / `;main`。  
**不要**把完整 SHA 写成 `;SHA`（会报 `Remote branch … not found`）。

---

## 📂 项目结构

```
Oasisic-OpenWrt/
├── .github/
│   ├── workflows/
│   │   ├── openwrt-auto-build.yml   # 主构建流水线（正式 + PR 验证）
│   │   ├── keepalive.yml            # 每周心跳，防 60 天无活动被停用
│   │   └── cleanup-actions.yml      # 定时清理失败 run / 旧 cache
│   ├── keepalive                      # 每周心跳时间戳（首次运行后生成）
│   └── minisign.pub
├── files/                           # 注入 rootfs 的文件
│   ├── etc/config/                  # network / firewall / system / dhcp
│   ├── etc/uci-defaults/99-custom
│   ├── etc/shadow                   # CI 运行时写入随机 root 哈希
│   ├── usr/lib/oasisic/
│   └── www/                         # 向导 + CGI
├── scripts/
│   ├── gen-config.sh
│   ├── gen-feeds-conf.sh
│   ├── check-firmware.sh
│   ├── check-docs-consistency.sh
│   ├── minisign-sign.sh
│   ├── notify-discord.py            # 成功卡片（Components V2）
│   └── notify-discord-failure.py    # 失败卡片（失败任务 + 失败步骤）
├── feeds.conf                       # 仅本地参考；CI 一律用 gen-feeds-conf.sh 生成，勿照此改
├── last_build_version               # 去重键（构建后由 persist-last-build 提交更新）
├── LICENSE                          # GPLv2
└── README.md
```

`last_build_version`：去重键，格式 `<OpenWrt tag>_nikki-<完整 SHA>`。构建成功后由 `persist-last-build` 提交更新（commit 带 `[skip ci]`）；删除该文件可强制下次按“无历史版本”重新构建。

默认分支为 **`main`**。请勿长期保留与 main 分叉的临时修复分支。

---

## 🚦 构建策略：自动 vs 手动

自动与手动**不是两套固件树**；差别几乎只在 **Nikki 用默认 Tag 还是你 pin 的 ref**。

| 触发方式 | OpenWrt | Nikki | 说明 |
|----------|---------|-------|------|
| **定时自动**（cron UTC 06:00 / 北京 14:00，实际常延后到北京 18:00–22:30） | 始终 `openwrt/openwrt` 的 **`releases/latest`** | **`OpenWrt-nikki` 的 `releases/latest` Tag** | `nikki_ref` 输入为空；再解析成完整 SHA，feeds 写 `url^完整SHA` |
| **手动 · `nikki_ref` 留空** | 同上，**仍是 latest Tag** | 同上，**与定时相同** | 适合「策略不变，只想再跑一遍」 |
| **手动 · 填写 `nikki_ref`** | 同上，**仍是 latest Tag** | **你填的 Tag / 分支 / Commit** | 例如 `v1.26.2`、`main`、`31339d5` |
| **`force_build=true`** | 不改变选版 | 不改变选版 | 只强制编译，忽略「版本没变就跳过」 |
| **PR 触发**（改 workflow / scripts / files） | 同上，**仍是 latest Tag** | 同上 | 默认只跑 `lint`；打 `ci:full-build` 标签才全量编译，产物走 prerelease |

补充（容易误解的点）：

1. **OpenWrt 目前没有手动版本参数**：定时和手动都跟官方 **最新 Release Tag**；不能在 Actions UI 里改 OpenWrt 版本（除非以后加 input）。
2. **Nikki 仅有新 Commit、尚未发新 Tag 时**：定时 **不会** 自动带上该 Commit；要吃到它，必须 **手动** 填 `nikki_ref`（并常勾 `force_build`）。
3. **包管理器里显示的 Nikki 版本号** 仍可能是 Tag 名（如 1.26.2）；以 Release 正文的 **Nikki ref** 和产物里 `feeds.conf.default` 的 `^完整SHA` 为准。
4. **是否真的开编**：还看仓库里是否有 `last_build_version`、是否与  
   `{OpenWrtTag}_nikki-{完整SHA}` 相同；相同且未 force 则会跳过。

---

## 🚀 手动构建（workflow_dispatch）

入口：[Actions → openwrt-auto-build → Run workflow](https://github.com/Hawaiine/Oasisic-OpenWrt/actions/workflows/openwrt-auto-build.yml)

| 参数 | 类型 | 默认 | 含义 |
|------|------|------|------|
| `force_build` | 布尔勾选 | false | 跳过版本比对，强制全量编译 |
| `nikki_ref` | 字符串 | 空 | 空 = 最新 Nikki Tag（与定时相同）；可填 Tag / 分支 / 短或完整 SHA |
| `runner_image` | 字符串 | 空 | 空 = 仓库变量 `RUNNER_IMAGE`，再空 = `ubuntu-26.04`；可填 `ubuntu-24.04` 做对比验证 |

**`nikki_ref` 规范**

- 留空 → 最新 Release Tag（与定时相同，例如 `v1.26.2`）
- Tag → `v1.26.2`
- 分支 → `main`
- Commit → 7 位短 SHA（如 `31339d5`）或 40 位完整 SHA（界面可短，CI 解析为完整 SHA 再写 feeds）

**示例**

| 目的 | force_build | nikki_ref | 实际编到的版本（逻辑） |
|------|-------------|-----------|------------------------|
| 钉死某 Commit 验证 | true | `31339d5` | OpenWrt = latest Tag；Nikki = 该 Commit |
| 跟踪 Nikki main | true | `main` | OpenWrt = latest Tag；Nikki = main HEAD |
| 与定时相同策略手动重跑 | 按需 | 留空 | OpenWrt + Nikki 均为各自 latest Tag |
| 强制重编当前 latest（清缓存后等） | true | 留空 | 同上，但不因 last_build 相同而跳过 |

成功后：

1. [Releases](https://github.com/Hawaiine/Oasisic-OpenWrt/releases) 下载产物  
2. 标签形如 `25.12.6-n31339d5`（`{OpenWrt 版本}-n{Nikki 短 SHA}`）  
3. 正文含 root 随机密码、Nikki 提交（ref）、内核版本  
4. 可选出现/更新 `last_build_version`（`persist-last-build` 依赖 token 可推 main）

---

## 🧪 PR 验证（先 PR 后合并）

改 `.github/workflows/**`、`scripts/**`、`files/**`、`feeds.conf` 的 PR 会自动跑验证：

| 层级 | 触发条件 | 内容 | 耗时 |
|------|----------|------|------|
| 静态检查 | 自动 | `lint`（bash/py/YAML + feeds 分隔符契约） | 2–3 分钟 |
| 全量构建 | PR 打上 `ci:full-build` 标签 | `build` + `qemu-smoke-test` + `ci-prerelease` | 冷 90–115 分钟 |

**产物怎么拿**

- Actions Artifact：`oasisic-openwrt-<版本>-pr<PR号>`（如 `oasisic-openwrt-25.12.6-pr5`）
- 直链 prerelease：`ci-<版本>-pr<PR号>-r<run号>`，如 `ci-25.12.6-pr5-r211`，免登录下载，不会顶掉 latest

**两条铁律**

1. PR 构建**永远不会**发正式 Release
2. PR 构建**永远不会**回写 `last_build_version`

> 打标签不会自动触发新 run：要么推一个 commit，要么 Actions → Run workflow，`ref` 选 PR 分支。

---

## 🔑 Secrets 与签名

| Secret | 用途 |
|--------|------|
| `DISCORD_BOT_TOKEN` | 发布通知（可选，缺则通知步骤失败但不影响你本地使用固件逻辑） |
| `MINISIGN_SECRET_KEY` | 签名私钥（hex） |
| `MINISIGN_KEY_ID` | 密钥 ID（hex） |
| `MINISIGN_PASSWORD` | 私钥密码 |
| `GITHUB_TOKEN` | GitHub 自动提供，无需手工配置；`persist-last-build` 用它提交去重键 |

签名文件 `sha256sums.minisig` 随 Release 一并发布；公钥见 [`.github/minisign.pub`](.github/minisign.pub)。

---

## 🖥️ PVE 导入

```bash
# 下载 Release 中的 EFI 镜像并解压
gunzip openwrt-x86-64-generic-squashfs-combined-efi.img.gz

qm create 100 --name "Oasisic-OpenWrt" --ostype l26 \
  --machine q35 --bios ovmf --cores 2 --memory 1024 \
  --net0 virtio,bridge=vmbr0

qm importdisk 100 openwrt-x86-64-generic-squashfs-combined-efi.img local-lvm
qm set 100 --scsihw virtio-scsi-single --scsi0 local-lvm:vm-100-disk-0
qm set 100 --boot order=scsi0 --agent enabled=1
qm start 100
```

首次启动为 **DHCP 客户端**。到主路由 DHCP 列表查找主机名 `Oasisic-OpenWrt`，浏览器打开 IP 进入设置向导。root 密码以对应 Release 正文为准。

> 没有 PVE？ISO 镜像可直接挂载到虚拟机或写入 U 盘启动，步骤同理。

---

## 🛡️ 安全与源

| 项 | 说明 |
|----|------|
| OpenWrt | 仅官方 `openwrt/openwrt` 对应 Release Tag |
| feeds | 官方 packages/luci/routing/telephony/video + Nikki |
| 包列表 | `scripts/gen-config.sh` 显式声明 |
| 密码 | 每次 CI 构建生成随机 root 哈希；向导可再改 |
| 签名 | minisign；公钥见 `.github/minisign.pub` |

---

## ❓ 常见问题（FAQ）

**1. 多久构建一次？会不会重复编译？**  
cron 设为每天 UTC 06:00（北京 14:00），GitHub 的免费 runner 排队常使其在北京 18:00–22:30 才起跑。合成键 `{OpenWrtTag}_nikki-{完整SHA}` 与仓库里的 `last_build_version` 相同、且未勾 `force_build` 时直接跳过。

**2. 上游发了新版，为什么没有新 Release？**  
三种常见情况：① Nikki 只推了新 commit、还没打新 Tag —— 定时只跟 Tag，需手动填 `nikki_ref`；② 判定为「无变化」（去重生效）；③ 构建真的失败 —— 去 Actions 看那次运行的日志。

**3. 一次构建要多久？**  
冷构建 90–115 分钟；命中缓存 40–70 分钟（GitHub 免费 runner，2 核 4 线程）。含编译、QEMU 烟雾测试与发布。

**4. 想马上吃到 Nikki 的新 commit（还没发 tag）怎么办？**  
手动运行并填 `nikki_ref`（`main` 或短 SHA）+ 勾 `force_build`。定时任务不会自动带上未发 Tag 的 commit。

**5. 怎么增删预装包？**  
改 `scripts/gen-config.sh`（包列表显式声明）后提交；下次构建生效。`check-docs-consistency.sh` 会在构建时校验 README 声称的包与配置是否一致。

**6. root 密码是什么？能改吗？**  
每次构建随机生成（SHA-512），写在对应 Release 正文里；仓库中的 `files/etc/shadow` 只是占位，构建时被替换。首次向导也可再改。

**7. 默认网络配置是什么样的？**  
首次启动为 DHCP 客户端，无硬编码局域网 IP；IPv6 相关（RA / DHCPv6 / NDP）默认关闭；LuCI 诊断地址默认 DNSPod `119.29.29.29`。

**8. 怎么彻底重建（不靠缓存）？**  
删除相关 Release/tag → 清空 Actions caches → 删除 `last_build_version` → 手动运行并勾 `force_build`。冷构建更慢，但结果更干净。

**9. 支持其它架构吗？**  
目前只出 x86/64（squashfs-combined EFI/BIOS + ISO），面向 PVE 与 x86 软路由；换架构需改 `gen-config.sh` 与产物路径。

**10. 定时任务突然不跑了？**  
大概率是「60 天无新提交 → `schedule` 工作流被 GitHub 自动停用」，处理见 [🔧 排错 → ⏰ 定时工作流被停用](#-定时工作流被停用60-天无新提交)。

---

## 🔧 排错

| 症状 | 可能原因 | 处理 |
|------|----------|------|
| `Remote branch <sha> not found` | feeds 把 Commit 写成了 `;SHA` | 必须用 `^完整SHA`（见 `gen-feeds-conf.sh`） |
| feeds / download 网络失败 | 上游瞬时故障 | workflow 已重试；再手动 Run |
| checkout action `429` | GitHub 限流 | 多为 warning，重试后常可继续 |
| LuCI 语言列表空 | languages 未注册 | 确认固件含当前 `99-custom` |
| LuCI 转圈 / JS 异常 | 缺 ucode 或静态资源 | 配置中已含 ucode；看 QEMU 步骤日志 |
| `persist-last-build` 失败 | 无法推 main | 检查 token/分支保护；去重会失效 |
| 想强制全新构建 | 缓存或版本文件残留 | 清 Actions Cache；删除 `last_build_version`；`force_build=true` |
| `staging_dir/host/bin/python3: No such file or directory` | 源码树缓存跨镜像污染（换了 runner 镜像还吃旧缓存） | 现已在 cache key 加镜像维度并自动自检；必要时手动清 Actions Cache |
| PR 里 `build` 没跑 | 未打 `ci:full-build` 标签 | 打标签后推一个 commit，或 Run workflow 指定 PR 分支 |
| 定时不再触发 / 收到「will be disabled soon」邮件 | 仓库 60 天无新提交，`schedule` 工作流被自动停用 | 内置 keepalive 每周心跳；仍失效时推提交 + Enable（见下节 ⏰） |

### ⏰ 定时工作流被停用（60 天无新提交）

GitHub 规则：**公开仓库在 60 天内没有仓库活动（没有新提交）时，所有 `schedule` 触发的工作流会被自动停用**。本仓库只在 `last_build_version` 变化时才产生提交，因此 **OpenWrt / Nikki 长期不发新版时会触发**（与是否有人打开 Actions 无关）。

| 阶段 | 现象 |
|------|------|
| 停用前约 7 天 | 收到邮件 `[GitHub] The "openwrt-auto-build" workflow … will be disabled soon` |
| 到期（最后一次提交后 60 天） | Actions 出现横幅 `This scheduled workflow is disabled because there hasn't been activity in this repository for at least 60 days`；定时构建与 `cleanup-failed-runs` 都不再运行 |

### 💓 自动保活（防止被停用）

仓库内置 `.github/workflows/keepalive.yml`：**每周一 UTC 03:00** 往 `.github/keepalive` 写一次时间戳并提交（commit 带 `[skip ci]`），再顺手检查其它定时工作流的 `state`，发现 `disabled_*` 就调用 API 重新启用。

- 只要心跳能跑，仓库每周都有活动，60 天计时器持续归零
- 心跳自身也是 schedule 工作流，但它每周都在制造活动，因此不会被自己的规则停掉
- 若心跳连续失败超过 60 天，仍需人工按下文恢复

**手动恢复（两步，缺一不可）**

1. **先推一个提交** —— 这一步才是重置 60 天计时的关键。最省事是网页端编辑任意文件后提交；本地亦可：
   ```bash
   git commit --allow-empty -m "🫀 chore: 保活心跳" && git push
   ```
2. **再启用工作流** —— Actions → 左侧选 `openwrt-auto-build` → 右侧 **Enable workflow**；`cleanup-failed-runs` 同样要启用（两个一起被停）。

> ⚠️ 只点 Enable 而不产生新提交，通常会被再次停用——停用条件只判断「仓库是否有活动」。
> API 启用：`PUT /repos/{owner}/{repo}/actions/workflows/{id}/enable`（token 需 `actions: write`）。
> 最省事的记法：**收到提醒邮件时顺手推一个空提交**，60 天计时即重置。

---

## 📌 相关项目

| 项目 | 说明 |
|------|------|
| [Oasisic-Icons](https://github.com/Hawaiine/Oasisic-Icons) | 代理图标 |
| [mihomo-rules](https://github.com/Hawaiine/mihomo-rules) | mihomo 规则集 |
| [Oasisic-IPTV](https://github.com/Hawaiine/Oasisic-IPTV) | IPTV 源聚合 |
| [moviepilot-category](https://github.com/Hawaiine/moviepilot-category) | MoviePilot 分类策略 |

---

## 📜 版本与发布

- **以 [Releases](https://github.com/Hawaiine/Oasisic-OpenWrt/releases) 为准**，不再维护易过期的手工版本表。  
- 标签格式：`{OpenWrt版本号}-n{Nikki 短SHA}`，例如 `25.12.6-n31339d5`；PR 验证件为 `ci-{版本号}-pr{PR号}-r{run号}`。  
- 工程变更看 `git log` / Actions；不在此逐条罗列构建编号。

当前仓库若暂无 Release，说明产物已清理或尚未发布新构建——请直接跑手动/定时流水线生成。

---

## 📜 许可证

[GNU General Public License v2](LICENSE) — 与 OpenWrt 一致。

---

> 🏝️ **Oasisic OpenWrt** — 自动构建 · 开箱即用 · 面向虚拟化