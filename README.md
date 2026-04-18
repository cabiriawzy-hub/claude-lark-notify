# claude-lark-notify

Ping yourself on Lark whenever Claude Code pauses — permission prompts, AskUserQuestion, 60s idle, and API errors all push a message (with urgent-app) to your own Lark DM so you don't miss it.

> 中文版 / Chinese version: [claude-feishu-notify](https://github.com/cabiriawzy-hub/claude-feishu-notify)

## What is this

A Claude Code [Skill](https://docs.claude.com/en/docs/claude-code/skills) plus two hook scripts. Once installed:

- **Permission prompts** (Claude wants to run a Bash command, fetch a URL, delete a file) → instant urgent ping
- **AskUserQuestion** → 60s no-response urgent ping
- **Idle** (Claude finished a turn and is waiting for you) → 60s no-response normal ping
- **API errors** (Request too large / rate limit / overloaded / context full) → instant urgent ping via `Stop` hook
- Every message includes a **humanized action description** (e.g. `git push origin main` → "push code to remote") and the **project path**
- **iTerm2 click-to-focus** (optional, macOS only) → click the "Click to focus" link in Lark and the matching iTerm2 session jumps to the front

## Dependencies

- [Claude Code](https://claude.com/claude-code)
- [`lark-cli`](https://bytedance.larkoffice.com/docx/WnHkdJQM6oGpQFxm9i7ckVdenSh) — a public Lark/Feishu CLI. Install guide: https://bytedance.larkoffice.com/wiki/P6DiwXsrZiMYBOk2ikzc9Btanee
- `jq` (`brew install jq`)
- Lark app with `im:message.urgent` or `im:message.urgent:app_send` scope — optional; without it messages still send, they just don't urgent-ping

## One-shot install

```bash
git clone https://github.com/cabiriawzy-hub/claude-lark-notify.git \
  ~/.claude/skills/claude-lark-notify
```

Then in Claude Code, just say:

```
/claude-lark-notify
```

Or in natural language: "install lark notify for me". Claude will automatically:

1. Check that `lark-cli` / `jq` are installed and logged in
2. Pull your `open_id` from `lark-cli auth status` and confirm with you
3. Drop the hook scripts into `~/.claude/hooks/claude-notify.sh` and `~/.claude/hooks/claude-error-notify.sh` with your `open_id` filled in
4. Idempotent-merge into `~/.claude/settings.json` (preserves your existing config)
5. Send two test messages + urgent-app to verify the pipeline

## Disable / uninstall

Temporarily mute:

```bash
export CLAUDE_NOTIFY_DISABLE=1
```

Permanent uninstall:

```bash
rm ~/.claude/hooks/claude-notify.sh ~/.claude/hooks/claude-error-notify.sh
# Then remove the Notification / Stop / UserPromptSubmit entries from ~/.claude/settings.json

# If the iTerm2 click-to-focus daemon was installed, also run:
launchctl bootout gui/$UID ~/Library/LaunchAgents/com.claude.focus-daemon.plist
rm ~/Library/LaunchAgents/com.claude.focus-daemon.plist ~/.claude/hooks/claude-focus-daemon.py
```

## Known limitations

- **Notification is not real-time**: when Claude asks a question, the hook waits ~60s of idle before firing. Permission prompts are real-time.
- **Can't send as a user**: `im:message.send_as_user` is typically locked down at the enterprise level, so the script always uses the app identity (`--as bot`).
- **Urgent needs an app scope**: `im:message.urgent` / `im:message.urgent:app_send` are often gated behind admin approval — ask your admin to whitelist them.
- **Stop hook fires on every turn-stop**: but the script filters — only pushes when the last assistant record has `isApiErrorMessage=true`. Normal completions are zero-noise.
- **Click-to-focus is iTerm2-only**: relies on the `ITERM_SESSION_ID` env var + iTerm2's AppleScript `unique id`. Terminal.app / Ghostty / WezTerm / SSH don't have that env var, so messages won't include the link but everything else works.

## Logs

Every send is recorded in `/tmp/claude-notify.log` — check there when debugging.
