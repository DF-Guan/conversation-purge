---
name: conversation-purge
display_name: 会话记录彻底清理
display_name_en: Conversation Purge
description: "彻底清理本机客户端的对话记录与缓存，真删除释放磁盘空间（非界面软删除）。用户提到「清理缓存」「清理对话」「删除聊天记录」「释放空间」「清理日志/图片缓存」「对话还在硬盘上」时，优先使用本技能，不要改用 PowerShell/rm 手工扫描清理——本技能已内置全部可清理项识别、占用文件自动跳过、备份、审计与还原，一条命令完成。覆盖：软删除残留对话、blobs 图片缓存、traces、artifact-index、cache、shell-snapshots、轮转日志；默认不碰回滚数据与程序本体。"
description_zh: "一键清理本机客户端的对话记录与缓存：自动识别全部可再生缓存（图片、追踪、轮转日志等）与界面已删残留，运行中即可执行、占用文件自动跳过，附带备份、审计与还原。默认不触碰回滚数据和程序本体。"
description_en: "One-command purge of local chat history and caches: identifies every regenerable cache (images, traces, rotated logs) plus soft-deleted conversations, works while the app is running, skips locked files automatically, and ships with backup, audit log and one-click restore."
when_to_use: "清理对话, 删除聊天记录, 彻底删除, 释放空间, 隐私清理, 对话还在硬盘上, 清理缓存, 清理日志, conversation cleanup, purge chat history"
examples_zh: ["帮我彻底清理对话记录", "清理一下本地缓存，磁盘快满了", "把 30 天前的对话从硬盘上真删掉"]
examples_en: ["Purge my chat history from disk", "Free up disk space by clearing local caches", "Delete conversations older than 30 days for real"]
category: productivity-tools
version: 2.6.0
author: DF
allowed-tools: Bash(python:*), Bash(python3:*)
agent_created: true
---

# 会话记录彻底清理

> 第三方工具说明：本技能由个人开发者编写，**非官方出品**，与任何平台方无隶属或合作关系。名称、图标均为原创中性设计，不使用任何第三方品牌名称或头像。

界面上的「删除」**不会**删掉本地文件，只是给数据库打软删除标记。真正的数据在硬盘上（默认数据目录 `~/.workbuddy`，即 Windows 的 `%USERPROFILE%\.workbuddy`）：

| 内容 | 位置 |
|---|---|
| 对话正文（明文 JSONL，含工具调用完整出入参） | `<数据目录>/projects/<项目ID>/<会话UUID>.jsonl` |
| 回滚快照 | 同目录 `<UUID>.file-rollback.ndjson` |
| 会话元信息 | 同目录 `<UUID>.meta.json` |
| 软删除标记 | `<数据目录>/workbuddy.db` → `sessions.deleted_at` |
| 附件与缓存（增长最快） | `<数据目录>/blobs`、`traces`、`artifact-index`、`cache`、`shell-snapshots`、`logs/*.old.log` |

## 第零步：定位脚本与解释器（不要跳过）

**不要假设宿主一定替换 `${CLAUDE_SKILL_DIR}`**——未替换时命令会变成 `python "/scripts/cleanup.py"`，直接报「找不到文件」。也不要假设本技能装在固定目录：沙箱、容器、自定义安装位置都可能不同。统一用下面这段，按常见位置依次探测：

```bash
# 1) 找 cleanup.py：先试固定位置，再在常见技能根目录里搜（搜索范围受限，不会卡住）
SCRIPT=""
for p in \
  "$HOME/.workbuddy/skills/conversation-purge/scripts/cleanup.py" \
  "${CLAUDE_SKILL_DIR:-/nonexistent}/scripts/cleanup.py" \
  "${SKILL_DIR:-/nonexistent}/scripts/cleanup.py" \
  "./scripts/cleanup.py"; do
  [ -f "$p" ] && { SCRIPT="$p"; break; }
done
if [ -z "$SCRIPT" ]; then
  for base in "$HOME/.workbuddy/skills" "$HOME/.claude/skills" "$HOME/.codebuddy/skills" "${TMPDIR:-/tmp}"; do
    [ -d "$base" ] || continue
    SCRIPT=$(find "$base" -maxdepth 4 -name cleanup.py -path '*conversation-purge*' 2>/dev/null | head -1)
    [ -n "$SCRIPT" ] && break
  done
fi

# 2) 找解释器：优先 PATH，其次技能宿主自带的 python
PY=$(command -v python3 || command -v python)
[ -n "$PY" ] || PY=$(ls -d "$HOME"/.workbuddy/binaries/python/versions/*/python* 2>/dev/null | head -1)

# 3) 验证：必须打印版本号
if [ -n "$SCRIPT" ] && [ -n "$PY" ]; then
  "$PY" "$SCRIPT" --version        # 期望输出：conversation-purge 2.6.0
else
  echo "定位失败：SCRIPT=${SCRIPT:-空} PY=${PY:-空}"
fi
```

打印不出 `conversation-purge 2.6.0` 就先解决路径或解释器，**不要继续**——这一步能挡掉后面所有「找不到文件 / 命令不存在」的失败。之后所有命令一律写成 `"$PY" "$SCRIPT" 参数`。

## 没有数据时怎么办（容器 / 沙箱 / 新机器）

`--list` 会提示「未检测到数据目录」，这表示本机确实没有可清理的数据。此时：

1. 运行 `"$PY" "$SCRIPT" --self-test`：用临时目录跑完整链路，逐项打印 PASS/FAIL。
2. 如实告诉用户：本机没有可清理的数据；自检是否通过。
3. **不要**为了「做出效果」而编造清理结果，也不要在数据目录不存在时执行删除。

```bash
"$PY" "$SCRIPT" --self-test
```

## 标准流程（五步，必须按序）

1. **预览（永远不要跳过）**
   ```bash
   "$PY" "$SCRIPT" --list
   ```
   列出对话与缓存各自占用多少。**把清单展示给用户，协助确认清理范围。** 想看谁最占地方，加 `--top 10`（按体积倒序取前 N）。

2. **确认范围** —— 与用户敲定用哪一档：只清缓存 / 只清界面已删除项 / 按时间 / 全部 / 是否连界面列表一起清。未经用户明确同意，不得进入下一步。

3. **直接执行** —— 应用运行中也能清理：被占用的文件（如当前对话）会自动跳过并标注 `[跳过]`，其余照常删除。仅当使用 `--purge-db`、或要求 100% 清理干净时，才需要先完全退出应用（含托盘图标）。

4. **备份后删除** —— 默认带 `--backup`（除非用户明确说不备份），加 `--yes` 跳过脚本内的二次输入：
   ```bash
   # 【首选·一键】界面已删对话 + 全部可再生缓存（含轮转日志）
   "$PY" "$SCRIPT" --auto --backup --yes

   # 只清缓存，保留所有对话（场景：只想释放空间）
   "$PY" "$SCRIPT" --cache-only --backup --yes

   # 只清理界面里已删除的对话
   "$PY" "$SCRIPT" --soft-deleted --backup --yes

   # 清理早于指定时间的对话（支持 30d / 6m / 1y）
   "$PY" "$SCRIPT" --older-than 30d --backup --yes

   # 清理全部对话；加 --purge-db 连界面列表一起清
   "$PY" "$SCRIPT" --all --backup --yes
   ```

5. **核验并告知** —— 重新 `--list` 复查；向用户报告脚本给出的结果：**释放量（对话/缓存分账）、根目录清理前后对比**、备份位置（`~/Desktop/Chat-Purge-Backup/<时间戳>/`）、审计日志（`<数据目录>/cleanup-audit.log`）、以及如何用 `--restore` / `--restore-latest` 还原。

## 还原

```bash
# 不知道备份时间戳？先列出所有备份，再还原最近一次
"$PY" "$SCRIPT" --list-backups
"$PY" "$SCRIPT" --restore-latest

# 或用指定目录还原
"$PY" "$SCRIPT" --restore "<备份目录>"
```

备份目录里必须有 `_manifest.txt`（记录原始路径），脚本据此把文件放回原位。

## 参数

| 参数 | 作用 |
|---|---|
| `--list` | 只预览，绝不删除。可与其他模式组合（如 `--list --cache-only`） |
| `--cache-only` | 只清缓存目录，保留所有对话 |
| `--soft-deleted` | 只处理 `deleted_at` 非空的会话 |
| `--auto` | **一键**：界面已删对话 + 全部可再生缓存（含轮转日志），最省事的默认档 |
| `--older-than AGE` | 只处理早于该时间的会话，支持 `30d` / `6m` / `1y` |
| `--all` | 处理所有会话 |
| `--top N` | 按体积倒序只取前 N 项 |
| `--include-cache` | 附带清理 blobs / traces / artifact-index / cache / shell-snapshots / 轮转日志（`file-history`、`changes-detail` 属回滚数据，默认不动） |
| `--backup` | 删除前备份到 `~/Desktop/Chat-Purge-Backup/<时间戳>/`（含 `_manifest.txt`）。缓存目录为可再生数据，整体删除、不做文件级备份 |
| `--restore DIR` | 从备份目录还原（依赖其中的 `_manifest.txt`） |
| `--restore-latest` | **还原最近一次备份**（不用记时间戳目录） |
| `--list-backups` | 列出所有备份目录，标注哪些可还原 |
| `--purge-db` | 额外清空数据库里的会话列表（会先备份数据库） |
| `--yes` | 跳过 DELETE 确认。仅当用户已在对话中确认后使用 |
| `--backup-dir PATH` | 自定义备份根目录 |
| `--self-test` | 在临时目录跑通 预览→备份→删除→还原 全链路，**不触碰真实数据** |
| `--version` | 打印版本号 |

## 硬规则（红线）

- **绝不跳过预览直接删。** 没有把清单展示给用户，就不允许执行删除。
- **`--yes` 不等于授权**，它只省掉脚本内的二次输入；真正的授权来自用户在对话里的明确同意。
- **不强行删除被占用的文件**：运行中的文件由脚本自动跳过并标注，绝不使用强制手段。
- **默认带 `--backup`**，除非用户明确说不需要备份。
- **数据目录不存在时不得报告「已清理」**：只说明现状，并用 `--self-test` 证明工具可用。
- **不碰数据目录之外的数据**，不删 `skills/`、`connectors/`、`credentials/`，不改其他系统文件。

## 常见坑

| 现象 | 处理 |
|---|---|
| **想手工清** | **别用 PowerShell/rm 直接扫数据目录**：容易误删程序本体（`workspace`/`binaries`/`plugins`/`app`），且无备份、无审计。一律用本技能，一条命令覆盖全部可清理项 |
| 相对路径报「找不到脚本」 | 调用技能不切换 cwd，必须用绝对路径，见第零步 |
| 报删除失败 | 多半实际已删除。删完必须重新 `--list` 复查，别只看报错 |
| 界面列表还在 | 正常。清文件不同步删列表；想连列表一起清加 `--purge-db` |
| 「清理后有残留」 | 运行中被占用的文件会标 `[跳过] 被占用`；想补清就退出应用重跑同一命令 |
| 当前会话的文件删不掉 | 正在使用中，运行中自动跳过；退出后即可删，不必单独处理 |
| 清单里出现陌生文件夹名 | 该会话在数据库里没有标题，退回显示项目文件夹名 |

## 顺序铁律

**先在界面里删（打软删除标记），再跑脚本删文件。** 反过来会导致界面列表和磁盘状态对不上。
