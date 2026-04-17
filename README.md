# claude-lark-notify

Claude Code 卡住就推飞书 —— Claude 要权限确认 / 问你问题 / 闲置等输入时，往你飞书私聊里发一条带加急的消息，让你别再错过。

## 这是啥

一个 Claude Code [Skill](https://docs.claude.com/en/docs/claude-code/skills) + 一个 Notification 钩子脚本。装好之后：

- **权限确认**（Claude 想跑个 Bash、抓个网页、删个文件）→ 秒推加急
- **问你问题**（AskUserQuestion）→ 60 秒没回应推加急
- **闲置摸鱼**（Claude 干完活等你下一步）→ 60 秒没回应推普通消息
- 消息带**中文化的操作描述**（比如 `git push origin main` → "把代码推到远端"）和**项目路径**

## 依赖

- [Claude Code](https://claude.com/claude-code)
- [`lark-cli`](https://bytedance.larkoffice.com)（字节内部飞书 CLI；非字节用户需要自己封一层等价的 `messages-send` + `urgent_app` 调用）
- `jq`（`brew install jq`）
- 飞书应用已开 `im:message.urgent` 或 `im:message.urgent:app_send` scope —— 不开也能用，只是消息不会加急

## 一键安装

```bash
git clone https://github.com/cabiriawzy-hub/claude-lark-notify.git \
  ~/.claude/skills/lark-notify-setup
```

然后在 Claude Code 里说一句：

```
/lark-notify-setup
```

或者口语："帮我装飞书提醒"。Claude 会自动：

1. 检查 `lark-cli` / `jq` 装了没、登录了没
2. 从 `lark-cli auth status` 抽你的 `open_id` 并跟你确认
3. 把钩子脚本填好 `open_id` 落到 `~/.claude/hooks/claude-notify.sh`
4. 幂等合并进 `~/.claude/settings.json`（保留你已有的配置）
5. 发一条测试消息 + 加急，确认链路通

## 关掉 / 卸载

临时闭嘴：

```bash
export CLAUDE_NOTIFY_DISABLE=1
```

永久卸载：

```bash
rm ~/.claude/hooks/claude-notify.sh
# 再从 ~/.claude/settings.json 里移除 Notification 和 UserPromptSubmit 的条目
```

## 已知限制

- **Notification 不是实时**：Claude 问问题时钩子要等 ~60 秒空闲才响，秒答会绕过。权限确认是实时的。
- **用户身份发不了消息**：飞书 `im:message.send_as_user` 通常被企业管控，所以脚本固定用应用身份（`--as bot`）。
- **加急需要应用权限**：`im:message.urgent` / `im:message.urgent:app_send` 常被企业管控，可能要找管理员加白名单。

## 日志

所有发送记录都在 `/tmp/claude-notify.log`，有问题翻这里。
