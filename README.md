# claude-lark-notify

Ping yourself on Lark whenever Claude Code pauses — **and now tap a button on the card to let Claude keep running**. Permission prompts, file edits, AskUserQuestion picks, idle, and API errors all become interactive Lark cards that you can resolve from your phone without going back to the computer.

> 中文版 / Chinese version: [claude-feishu-notify](https://github.com/cabiriawzy-hub/claude-feishu-notify)

## V1 → V2 upgrade

| | V1 | V2 |
|---|---|---|
| Role of Lark | 📣 Speaker (notify only) | 🎮 Remote (decide directly) |
| Permission prompts | Plain text ping | **Interactive card**, ✅ Approve / ❌ Deny |
| File edits | Not handled | Purple card with path + diff preview, one-tap approve |
| AskUserQuestion | Plain text ping | Blue card — one button per option, tap the one you want |
| At-computer detection | Always pushed | **Auto-detected** — if you're in front of a terminal, stay silent (local menu only); push to Lark only when you're away |
| Jump back to terminal | Markdown link in the message | Every card has a `🖥️ Focus iTerm` URL button |

## What is this

A Claude Code [Skill](https://docs.claude.com/en/docs/claude-code/skills) + a set of hooks + a persistent daemon. Once installed:

**🔴 Risky commands** (Bash, rm, git push, …) → red card with command + cwd + humanized description + ✅ Approve / ❌ Deny buttons.

**🟣 File edits** (Edit / Write) → purple card with file path + diff preview + ✅ Approve / ❌ Deny.

**🔵 Single-question picks** (AskUserQuestion, `questions.length == 1`) → blue card, one button per option + 💻 Answer on computer.

**🔔 Idle / question / API error** (already in V1) → blue info card, non-blocking, with `🖥️ Focus iTerm` / `🙅 Busy right now` buttons.

## The nicest bit: automatic at-computer detection

Every time Claude needs a decision, the daemon quietly checks: **are you in front of the terminal right now?**

- ✅ **Terminal is frontmost** (iTerm2 / Terminal / Ghostty / Alacritty / kitty / WezTerm): Lark stays silent. You get Claude Code's native local menu — just press a number. Zero overhead vs. vanilla Claude Code.
- 🏃 **Away / screen locked / different app**: card lands on your phone. Tap a button and Claude continues.

The big deal is it's **automatic** — no `ccr start/stop` toggling, no mode switches.

## Dependencies

- [Claude Code](https://claude.com/claude-code)
- [`lark-cli`](https://bytedance.larkoffice.com/docx/WnHkdJQM6oGpQFxm9i7ckVdenSh) — a public Lark/Feishu CLI. Install guide: https://bytedance.larkoffice.com/wiki/P6DiwXsrZiMYBOk2ikzc9Btanee
- `jq` (`brew install jq`)
- macOS only — the `ccr` daemon uses `lsappinfo` for frontmost-app detection; Linux/Windows are not supported
- Lark app with `im:message.urgent` / `im:message.urgent:app_send` scope — optional; without it cards still send, they just don't urgent-ping

## One-shot install

```bash
git clone https://github.com/cabiriawzy-hub/claude-lark-notify.git \
  ~/.claude/skills/claude-lark-notify
```

Then in Claude Code:

```
/claude-lark-notify
```

Or in natural language: "install lark remote / install lark v2 / setup lark notify". Claude will automatically:

1. Check `lark-cli` / `jq` / macOS
2. Pull your `open_id` from `lark-cli auth status` and confirm with you
3. Drop every script under `~/.claude/hooks/` with your `open_id` filled in
4. Install the **`ccr` daemon**: copy `ccr-daemon.py` + generate LaunchAgent plist + `launchctl bootstrap`
5. Idempotent-merge into `~/.claude/settings.json`: `Notification` / `Stop` / `UserPromptSubmit` / `PreToolUse(Bash|Write|Edit|AskUserQuestion)` / `PostToolUse`
6. Send two test messages + an urgent-app to verify the pipeline

## `ccr` CLI

After install, `~/.claude/hooks/ccr` gives you a small command-line tool (add it to `PATH` or alias it):

```bash
ccr status     # mode + daemon health + presence + recent log
ccr enable     # enable remote approval (default)
ccr disable    # flip hooks to no-op; fall back to native Claude Code UI only
ccr restart    # unload + reload the LaunchAgent
ccr log        # tail the daemon log
```

## Disable / uninstall

Temporarily mute:

```bash
ccr disable          # soft switch, hooks become no-ops instantly
# or
export CLAUDE_NOTIFY_DISABLE=1
```

Permanent uninstall:

```bash
# 1. Uninstall daemon
launchctl bootout gui/$UID ~/Library/LaunchAgents/com.claude.ccr.plist
rm ~/Library/LaunchAgents/com.claude.ccr.plist

# 2. Delete hook scripts
rm ~/.claude/hooks/{ccr-daemon.py,claude-ccr.sh,claude-notify.sh,claude-error-notify.sh,ccr}

# 3. Remove the corresponding hook entries from ~/.claude/settings.json

# 4. If the iTerm2 click-to-focus daemon was installed, also run:
launchctl bootout gui/$UID ~/Library/LaunchAgents/com.claude.focus-daemon.plist
rm ~/Library/LaunchAgents/com.claude.focus-daemon.plist ~/.claude/hooks/claude-focus-daemon.py
```

## Known limitations

- **macOS only**: frontmost-app detection relies on `lsappinfo`; won't run on Linux / Windows.
- **Single daemon per host**: the daemon listens on `127.0.0.1:19837`; one daemon serves every Claude Code session on the machine. Concurrent sessions are isolated by request id, so their cards don't collide.
- **AskUserQuestion: single-question only**: cards fire only when `questions.length == 1`. Multi-question forms fall through to the local menu.
- **Cards wait 10 minutes**: decision cards treat a 10-minute silence as denial. Info cards are non-blocking.
- **Can't send as a user**: `im:message.send_as_user` is typically locked down at the enterprise level, so the script always uses the app identity (`--as bot`).
- **Urgent needs an app scope**: `im:message.urgent` / `im:message.urgent:app_send` are often gated behind admin approval. Sending still works either way.
- **Click-to-focus is iTerm2-only**: relies on the `ITERM_SESSION_ID` env var. Terminal.app / Ghostty / WezTerm don't set it, so cards skip the `Focus iTerm` button; everything else works.

## Logs

- daemon: `/tmp/ccr-daemon.log`
- hooks: `/tmp/ccr-approve.log` (PreToolUse) + `/tmp/claude-notify.log` (Notification / Stop)

Check there when debugging.
