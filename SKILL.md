---
name: claude-lark-notify
description: One-shot installer for a Claude Code notification hook — pushes a Lark/Feishu message (with urgent-app ping) whenever Claude pauses for permission/AskUserQuestion, idles waiting for input, or hits an API error (request too large, rate limit, overload). Trigger when the user says "ping me on Lark when Claude stops", "lark notify", "setup lark notify", "feishu notify", etc.
---

# Claude Lark Notify

Installs two Claude Code hooks so every time Claude "stops and needs you" it pushes a Lark DM:

1. **Notification hook** — fires on permission prompts, AskUserQuestion, and 60s idle-waiting
2. **Stop hook** — fires only when Claude's last turn is an API error (Request too large / rate limit / overloaded / context full)

Both push with urgent-app so the Lark app will ping through.

Core files:
- `~/.claude/skills/claude-lark-notify/claude-notify.sh` (Notification template, with `__OPEN_ID__` placeholder)
- `~/.claude/skills/claude-lark-notify/claude-error-notify.sh` (Stop template, same placeholder)
- `~/.claude/skills/claude-lark-notify/claude-focus-daemon.py` (optional: click-to-focus iTerm2 session, macOS only)
- After install: hook scripts land in `~/.claude/hooks/` with `OPEN_ID` filled in
- `~/.claude/settings.json` gets three hook entries registered: `Notification`, `Stop`, `UserPromptSubmit`

## Install checklist

Run each step in order. On any failure, give the user a clear fix and wait for them to come back.

### 1. Check dependencies

```bash
command -v lark-cli && command -v jq
```

- `lark-cli` missing: tell the user they need lark-cli to send messages. Overview doc: https://bytedance.larkoffice.com/docx/WnHkdJQM6oGpQFxm9i7ckVdenSh . Install doc: https://bytedance.larkoffice.com/wiki/P6DiwXsrZiMYBOk2ikzc9Btanee .
- `jq` missing: `brew install jq`.

### 2. Lark login + fetch open_id

```bash
lark-cli auth status
```

Output is JSON; parse:
- `.tokenStatus == "valid"` → OK
- `.userOpenId` → the user's own open_id (we send to this + urgent-app it)
- Anything else (`expired` / `missing`) → have the user `lark-cli auth login`, finish the browser OAuth, then retry

Once you have the open_id, confirm with the user via `AskUserQuestion` (show the detected `userName` + first 8 chars of the open_id) so you don't wire it to the wrong account.

### 3. Drop the two hook scripts

```bash
mkdir -p ~/.claude/hooks

for f in claude-notify.sh claude-error-notify.sh; do
  sed "s|__OPEN_ID__|${OPEN_ID}|g" \
    ~/.claude/skills/claude-lark-notify/$f \
    > ~/.claude/hooks/$f
  chmod +x ~/.claude/hooks/$f
done
```

If either target already exists and its `OPEN_ID` differs from the one you just detected, use `AskUserQuestion` to let the user pick: overwrite / keep old / cancel.

### 4. Register hooks in settings.json

Goal: add three hook entries to `~/.claude/settings.json`:
- `hooks.Notification` runs `claude-notify.sh`
- `hooks.Stop` runs `claude-error-notify.sh`
- `hooks.UserPromptSubmit` clears the marker file

**Never** clobber the user's existing hooks / permissions / plugins. Use jq for an idempotent merge:

```bash
SETTINGS=~/.claude/settings.json
NOTIFY_HOOK=~/.claude/hooks/claude-notify.sh
ERROR_HOOK=~/.claude/hooks/claude-error-notify.sh
MARKER_CLEAR="rm -f /tmp/claude-notify-active.marker"

[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"

jq --arg nh "$NOTIFY_HOOK" --arg eh "$ERROR_HOOK" --arg mc "$MARKER_CLEAR" '
  .hooks //= {} |
  .hooks.Notification //= [] |
  (if any(.hooks.Notification[]?.hooks[]?; .command == $nh)
   then .
   else .hooks.Notification += [{"hooks":[{"type":"command","command":$nh}]}]
   end) |
  .hooks.Stop //= [] |
  (if any(.hooks.Stop[]?.hooks[]?; .command == $eh)
   then .
   else .hooks.Stop += [{"hooks":[{"type":"command","command":$eh}]}]
   end) |
  .hooks.UserPromptSubmit //= [] |
  (if any(.hooks.UserPromptSubmit[]?.hooks[]?; .command == $mc)
   then .
   else .hooks.UserPromptSubmit += [{"hooks":[{"type":"command","command":$mc}]}]
   end)
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
```

### 5. Optional: install the iTerm2 click-to-focus daemon

**macOS + iTerm2 only.** If the user is on non-macOS or uses Terminal.app / Ghostty / WezTerm, **skip this step** — the hook won't add a link to messages either.

First ask the user: "Do you use iTerm2? If yes, clicking a link in the Lark message will bring the matching terminal session to the front." Use `AskUserQuestion` to let them pick Install / Skip.

If they choose install, run:

```bash
# Copy the daemon script to hooks dir
cp ~/.claude/skills/claude-lark-notify/claude-focus-daemon.py ~/.claude/hooks/claude-focus-daemon.py
chmod +x ~/.claude/hooks/claude-focus-daemon.py

# Generate launchd plist (generated fresh because paths are per-user)
mkdir -p ~/Library/LaunchAgents
cat > ~/Library/LaunchAgents/com.claude.focus-daemon.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude.focus-daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>$HOME/.claude/hooks/claude-focus-daemon.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/claude-focus-daemon.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/claude-focus-daemon.log</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
EOF

# Load via launchd (bootout first if already loaded, idempotent)
launchctl bootout gui/$UID ~/Library/LaunchAgents/com.claude.focus-daemon.plist 2>/dev/null || true
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.claude.focus-daemon.plist

# Verify the daemon came up
sleep 1
curl -sS -o /dev/null -w "%{http_code}" "http://127.0.0.1:47823/focus?id=00000000-0000-0000-0000-000000000000"
# Expected: 404 (valid UUID shape but no matching session) — means the daemon is alive
```

Verification:
- `404` → daemon is up, tell the user it's installed
- `000` or connection error → daemon didn't start; have the user check `/tmp/claude-focus-daemon.log`
- On non-iTerm terminals the hook silently skips the link — no error

### 6. End-to-end test

**Notification hook** (permission prompt scenario):

```bash
rm -f /tmp/claude-notify-active.marker
printf '{"message":"Claude needs your permission to use Bash","cwd":"%s","transcript_path":""}' \
  "$HOME" | ~/.claude/hooks/claude-notify.sh
echo "exit=$?"
tail -15 /tmp/claude-notify.log
```

**Stop hook** (API error scenario):

```bash
rm -f /tmp/claude-notify-active.marker
cat > /tmp/test-error-transcript.jsonl <<'EOF'
{"type":"user","message":{"role":"user","content":"hi"}}
{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"Request too large (max 32MB). Double press esc to go back and try with a smaller file."}]}}
EOF
printf '{"transcript_path":"/tmp/test-error-transcript.jsonl","cwd":"%s"}' "$HOME" \
  | ~/.claude/hooks/claude-error-notify.sh
echo "exit=$?"
tail -15 /tmp/claude-notify.log
rm -f /tmp/test-error-transcript.jsonl
```

Both test messages should land in Lark. Verification:
- Log contains `"ok": true` → message sent
- Log contains `urgent_app for om_...` + `"code": 0` → urgent-app succeeded
- Log contains `(urgent failed)` or `permission_violations` → urgent scope isn't granted. Tell the user: messages are sent but not urgent-pinged. To enable urgent, add `im:message.urgent` or `im:message.urgent:app_send` scope to the bot app in the Lark developer console.

### 7. Wrap up

Tell the user:
- ✅ Done — open the Lark self-chat, you should see two test messages
- Log file: `/tmp/claude-notify.log` (check here when debugging)
- To temporarily mute: `export CLAUDE_NOTIFY_DISABLE=1`
- To uninstall: delete `~/.claude/hooks/claude-notify.sh` + `~/.claude/hooks/claude-error-notify.sh`, then remove the three hook entries from `~/.claude/settings.json`
- If the iTerm2 click-to-focus daemon was installed, also run: `launchctl bootout gui/$UID ~/Library/LaunchAgents/com.claude.focus-daemon.plist && rm ~/Library/LaunchAgents/com.claude.focus-daemon.plist ~/.claude/hooks/claude-focus-daemon.py`

## Caveats

- **Must use `--as bot`**: user identity lacks the `im:message.send_as_user` scope (enterprise-managed), so we can only send as the app.
- **Notification is not real-time**: when Claude asks a question, the Notification hook waits ~60s of idle before firing. That's Claude Code's own behavior — the skill can't change it.
- **Stop hook runs on every turn-stop**: but the script filters — it only pushes when the last assistant record has `isApiErrorMessage=true`. Normal completions are zero-noise.
- **Urgent needs an app scope**: `im:message.urgent` / `im:message.urgent:app_send` are often locked behind enterprise admin approval. Message sending itself is unaffected.
- **OPEN_ID is hard-coded**: the template seds the open_id directly into the script — it doesn't read env vars. Re-run the skill to switch accounts (or edit the `OPEN_ID=` line at the top of each hook).
- **Click-to-focus is iTerm2-only**: the daemon relies on the `ITERM_SESSION_ID` env var + iTerm2's AppleScript `unique id`. Terminal.app / Ghostty / WezTerm / SSH sessions don't set that env var, so the hook silently skips adding the link.
