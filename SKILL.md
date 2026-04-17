---
name: lark-notify-setup
description: 一键装一个 Claude Code 的 Notification 钩子——Claude 卡在权限确认、AskUserQuestion、或空闲等输入时，会往用户飞书私聊里发一条带加急的消息。使用场景：用户说"每次 Claude 停下来叫我，发飞书提醒""飞书提醒""lark notify""setup lark notify"之类。
---

# Lark Notify Setup

装一个 Claude Code 的 Notification 钩子，Claude 每次停下来要确认/提问/闲置时，会往用户飞书私聊里发一条消息，权限/提问类会加急。

核心文件：
- `~/.claude/skills/lark-notify-setup/claude-notify.sh`（模板，带 `__OPEN_ID__` 占位符）
- 安装后会落到 `~/.claude/hooks/claude-notify.sh`（填好 open_id）
- `~/.claude/settings.json` 里注册 `Notification` 和 `UserPromptSubmit` 两个 hook

## 安装流程

按顺序跑下面的 checklist，每一步失败就给用户清楚的修复指令，再等用户回来确认。

### 1. 依赖检查

```bash
command -v lark-cli && command -v jq
```

- `lark-cli` 缺：告诉用户"需要先装 lark-cli（字节内部飞书 CLI），这个 Skill 靠它发消息"，给内部安装文档链接或让用户自己 `brew install` / 下载。
- `jq` 缺：`brew install jq`。

### 2. 飞书登录 + 拿 open_id

```bash
lark-cli auth status
```

输出是 JSON，解析：
- `.tokenStatus == "valid"`：OK
- `.userOpenId`：用户自己的 open_id，拿来发消息和加急
- 其他情况（`expired` / `missing`）：让用户 `lark-cli auth login`，浏览器走完 OAuth 后回来重试

拿到 open_id 后，用 `AskUserQuestion` 跟用户确认一次（显示检测到的 userName + openId 前 8 位），避免装到别人名下。

### 3. 铺 hook 脚本

```bash
mkdir -p ~/.claude/hooks
sed "s|__OPEN_ID__|${OPEN_ID}|g" \
  ~/.claude/skills/lark-notify-setup/claude-notify.sh \
  > ~/.claude/hooks/claude-notify.sh
chmod +x ~/.claude/hooks/claude-notify.sh
```

如果 `~/.claude/hooks/claude-notify.sh` 已经存在、且 `OPEN_ID` 跟当前检测到的不一样，用 `AskUserQuestion` 让用户选：覆盖 / 保留旧的 / 取消。

### 4. 注册 hooks 到 settings.json

目标：在 `~/.claude/settings.json` 的 `hooks.Notification` 里加一条跑我们脚本的命令，在 `hooks.UserPromptSubmit` 里加一条清 marker 的命令。**绝对不能**清掉用户已有的其他 hook / 权限 / 插件配置。

用 jq 做幂等合并：

```bash
SETTINGS=~/.claude/settings.json
HOOK=~/.claude/hooks/claude-notify.sh
MARKER_CLEAR="rm -f /tmp/claude-notify-active.marker"

[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"

jq --arg hook "$HOOK" --arg mc "$MARKER_CLEAR" '
  .hooks //= {} |
  .hooks.Notification //= [] |
  (if any(.hooks.Notification[]?.hooks[]?; .command == $hook)
   then .
   else .hooks.Notification += [{"hooks":[{"type":"command","command":$hook}]}]
   end) |
  .hooks.UserPromptSubmit //= [] |
  (if any(.hooks.UserPromptSubmit[]?.hooks[]?; .command == $mc)
   then .
   else .hooks.UserPromptSubmit += [{"hooks":[{"type":"command","command":$mc}]}]
   end)
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
```

### 5. 端到端测试

跑一次假的 Notification 荷载，确认能发到飞书，并且（如果有加急权限）能加急：

```bash
rm -f /tmp/claude-notify-active.marker
printf '{"message":"Claude needs your permission to use Bash","cwd":"%s","transcript_path":""}' \
  "$HOME" | ~/.claude/hooks/claude-notify.sh
echo "exit=$?"
tail -15 /tmp/claude-notify.log
```

判定：
- 日志里有 `"ok": true` → 消息发成功
- 日志里有 `urgent_app for om_...` + `"code": 0` → 加急成功
- 日志里有 `(urgent failed)` 或 `permission_violations` → 加急权限没开，告诉用户：消息能发、但不会加急；想开加急要飞书开发者后台给应用加 `im:message.urgent` 或 `im:message.urgent:app_send` scope

### 6. 收尾

告诉用户：
- ✅ 装好了，让他们打开飞书找自己的私聊，应该能看到测试消息
- 日志在 `/tmp/claude-notify.log`，有问题翻这里
- 临时不想被打扰：`export CLAUDE_NOTIFY_DISABLE=1`
- 卸载：删 `~/.claude/hooks/claude-notify.sh` + 从 `~/.claude/settings.json` 里撤掉两个 hook 条目

## 注意事项

- **必须 `--as bot`**：用户身份缺 `im:message.send_as_user` scope（企业管控），能发的只有应用身份。
- **Notification 不是实时**：Claude 问问题时，钩子要等 ~60 秒空闲才响，不是秒发。这是 Claude Code 本身的行为，Skill 改不了。
- **加急需要应用权限**：`im:message.urgent` / `im:message.urgent:app_send` 常被企业管控，可能需要找管理员加白名单。消息发送本身不受影响。
- **OPEN_ID 硬编码**：模板把 open_id 直接 sed 进脚本，不读环境变量。用户换账号要重跑 Skill（或手改脚本顶部那行）。
