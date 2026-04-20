---
name: claude-lark-notify
description: One-shot installer for Claude Code Lark remote control (V2) — pushes interactive Lark cards when Claude pauses for permission, file edits, AskUserQuestion picks, idle, or API errors. The user taps buttons on their phone to approve/deny/pick and Claude continues. Automatically detects whether the user is at the computer: if a terminal is frontmost it stays silent and uses the native menu; if not, it pushes a card. Trigger when the user says "install lark remote", "lark v2", "approve Claude on my phone", "lark notify", "setup lark remote", "feishu v2", etc.
---

# Claude Lark Notify V2

Installs a set of Claude Code hooks + a persistent daemon (`ccr` = Claude Code Remote) that push Claude's "I need a decision" moments to Lark as **interactive cards**. The user taps buttons on their phone and Claude continues.

## V2 vs V1

V1 was a "speaker" (notify only). V2 is a "remote":

- **🔴 Bash commands** → red card, ✅ Approve / ❌ Deny
- **🟣 Edit / Write** → purple card with diff, ✅ Approve / ❌ Deny
- **🔵 AskUserQuestion single-question** → blue card, one button per option
- **🔔 Idle / API errors** → blue info card, non-blocking (V1 feature, upgraded to a card with a `🖥️ Focus iTerm` URL button)
- **Automatic presence detection**: user in front of a terminal → local menu (zero overhead); away → push to Lark. Uses macOS `lsappinfo` to read the frontmost app.

## Core files

- `~/.claude/skills/claude-lark-notify/ccr-daemon.py` (persistent HTTP service on 127.0.0.1:19837, with `__OPEN_ID__` placeholder)
- `~/.claude/skills/claude-lark-notify/claude-ccr.sh` (PreToolUse hook; routes Bash / Write / Edit / AskUserQuestion to the daemon)
- `~/.claude/skills/claude-lark-notify/claude-notify.sh` (Notification hook; POSTs to the daemon's `/notify`)
- `~/.claude/skills/claude-lark-notify/claude-error-notify.sh` (Stop hook; API errors only, has `__OPEN_ID__` placeholder)
- `~/.claude/skills/claude-lark-notify/claude-focus-daemon.py` (optional: iTerm2 click-to-focus)
- `~/.claude/skills/claude-lark-notify/ccr` (CLI tool)
- Hooks and daemon land under `~/.claude/hooks/` after install (with `open_id` filled in)
- `~/Library/LaunchAgents/com.claude.ccr.plist` (auto-starts the daemon at login)
- `~/.claude/settings.json` registers 5 hooks: `Notification` / `Stop` / `UserPromptSubmit` / `PreToolUse` / `PostToolUse`

## Install flow

Run the checklist in order. If any step fails, give the user a clear fix and wait for confirmation before continuing.

### 1. Dependency check

```bash
command -v lark-cli && command -v jq
uname -s     # must be Darwin (macOS); Linux / Windows not supported
python3 -c 'import sys; assert sys.version_info >= (3,9)'
```

- `lark-cli` missing: tell the user "you need to install lark-cli first". Docs: https://bytedance.larkoffice.com/docx/WnHkdJQM6oGpQFxm9i7ckVdenSh . Install: https://bytedance.larkoffice.com/wiki/P6DiwXsrZiMYBOk2ikzc9Btanee .
- `jq` missing: `brew install jq`.
- Not macOS: tell the user "the `ccr` daemon is macOS-only (`lsappinfo`-based frontmost-app detection); your system can't run it. Use the V1 version (text pings) or skip." Then stop.

### 2. Lark login + open_id

```bash
lark-cli auth status
```

Output is JSON. Parse:
- `.tokenStatus == "valid"`: OK
- `.userOpenId`: the user's own open_id
- Otherwise (`expired` / `missing`): have the user run `lark-cli auth login`.

Once you have the open_id, use `AskUserQuestion` to confirm it with the user (show the detected `userName` + first 8 chars of the open_id).

### 3. Drop scripts into ~/.claude/hooks/

```bash
mkdir -p ~/.claude/hooks

# files with OPEN_ID placeholder → sed replace
for f in ccr-daemon.py claude-error-notify.sh; do
  sed "s|__OPEN_ID__|${OPEN_ID}|g" \
    ~/.claude/skills/claude-lark-notify/$f \
    > ~/.claude/hooks/$f
  chmod +x ~/.claude/hooks/$f
done

# files without placeholder → plain copy
for f in claude-ccr.sh claude-notify.sh ccr; do
  cp ~/.claude/skills/claude-lark-notify/$f ~/.claude/hooks/$f
  chmod +x ~/.claude/hooks/$f
done
```

If a target file already exists and its `OPEN_ID` differs from the detected one, use `AskUserQuestion` to let the user pick: overwrite / keep existing / cancel.

### 4. Install the ccr daemon LaunchAgent

```bash
mkdir -p ~/Library/LaunchAgents
cat > ~/Library/LaunchAgents/com.claude.ccr.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude.ccr</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>$HOME/.claude/hooks/ccr-daemon.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/ccr-daemon.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/ccr-daemon.log</string>
    <key>ProcessType</key>
    <string>Background</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
EOF

# Idempotent load
launchctl bootout gui/$UID ~/Library/LaunchAgents/com.claude.ccr.plist 2>/dev/null || true
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.claude.ccr.plist

sleep 2
curl -sS -m 3 http://127.0.0.1:19837/healthz
# Expected: {"subscribe_alive": true, "pending": 0, "uptime": 2}
```

Judgment:
- JSON with `subscribe_alive: true` → daemon is up and Lark event subscription is connected
- `subscribe_alive: false` → daemon is running but `lark-cli event +subscribe` didn't connect (common cause: the bot doesn't have `im:message` event subscription). Card button clicks will be silently dropped. Tell the user to enable event subscriptions in the Lark developer console.
- Connection fails → check `/tmp/ccr-daemon.log`

### 5. Register the 5 hooks in settings.json

**Never** wipe the user's existing hooks / permissions / plugin config. Use jq to merge idempotently:

```bash
SETTINGS=~/.claude/settings.json
NOTIFY_HOOK=~/.claude/hooks/claude-notify.sh
ERROR_HOOK=~/.claude/hooks/claude-error-notify.sh
CCR_HOOK=~/.claude/hooks/claude-ccr.sh
MARKER_CLEAR="rm -f /tmp/claude-notify-active.marker"
CANCEL_PENDING="curl -sS -m 2 -X POST http://127.0.0.1:19837/cancel-pending >/dev/null 2>&1 || true"
PRE_MATCHER="Bash|Write|Edit|AskUserQuestion"

[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"

jq --arg nh "$NOTIFY_HOOK" --arg eh "$ERROR_HOOK" --arg ch "$CCR_HOOK" \
   --arg mc "$MARKER_CLEAR" --arg cp "$CANCEL_PENDING" --arg pm "$PRE_MATCHER" '
  .hooks //= {}

  # Notification → claude-notify.sh
  | .hooks.Notification //= []
  | (if any(.hooks.Notification[]?.hooks[]?; .command == $nh) then .
     else .hooks.Notification += [{"hooks":[{"type":"command","command":$nh}]}] end)

  # Stop → claude-error-notify.sh
  | .hooks.Stop //= []
  | (if any(.hooks.Stop[]?.hooks[]?; .command == $eh) then .
     else .hooks.Stop += [{"hooks":[{"type":"command","command":$eh}]}] end)

  # UserPromptSubmit → clear marker + cancel daemon follow-ups
  | .hooks.UserPromptSubmit //= []
  | (if any(.hooks.UserPromptSubmit[]?.hooks[]?; .command == $mc) then .
     else .hooks.UserPromptSubmit += [{"hooks":[{"type":"command","command":$mc}]}] end)
  | (if any(.hooks.UserPromptSubmit[]?.hooks[]?; .command == $cp) then .
     else .hooks.UserPromptSubmit += [{"hooks":[{"type":"command","command":$cp}]}] end)

  # PreToolUse (matcher Bash|Write|Edit|AskUserQuestion) → claude-ccr.sh
  | .hooks.PreToolUse //= []
  | (if any(.hooks.PreToolUse[]?; .matcher == $pm and any(.hooks[]?; .command == $ch))
     then .
     else .hooks.PreToolUse += [{"matcher":$pm,"hooks":[{"type":"command","command":$ch}]}]
     end)

  # PostToolUse (matcher Bash|Write|Edit|AskUserQuestion) → cancel daemon follow-ups
  | .hooks.PostToolUse //= []
  | (if any(.hooks.PostToolUse[]?; .matcher == $pm and any(.hooks[]?; .command == $cp))
     then .
     else .hooks.PostToolUse += [{"matcher":$pm,"hooks":[{"type":"command","command":$cp}]}]
     end)
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
```

### 6. Optional: iTerm2 click-to-focus daemon

**macOS + iTerm2 only.** Ask the user "Do you use iTerm2? If so, a click on the Lark card can jump straight to the matching terminal session."

If they pick "install", run (same as V1):

```bash
cp ~/.claude/skills/claude-lark-notify/claude-focus-daemon.py ~/.claude/hooks/claude-focus-daemon.py
chmod +x ~/.claude/hooks/claude-focus-daemon.py

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
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/tmp/claude-focus-daemon.log</string>
    <key>StandardErrorPath</key><string>/tmp/claude-focus-daemon.log</string>
    <key>ProcessType</key><string>Background</string>
</dict>
</plist>
EOF

launchctl bootout gui/$UID ~/Library/LaunchAgents/com.claude.focus-daemon.plist 2>/dev/null || true
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.claude.focus-daemon.plist

sleep 1
curl -sS -o /dev/null -w "%{http_code}" "http://127.0.0.1:47823/focus?id=00000000-0000-0000-0000-000000000000"
# Expected 404 = daemon alive
```

### 7. End-to-end tests

**Test 1: Notification hook** (permission scenario; should urgent-ping)

```bash
rm -f /tmp/claude-notify-active.marker
printf '{"message":"Claude needs your permission to use Bash","cwd":"%s","transcript_path":""}' \
  "$HOME" | ~/.claude/hooks/claude-notify.sh
echo "exit=$?"
tail -15 /tmp/claude-notify.log
```

Expected: Lark receives "🐾 Claude wants to … — approve to continue" (or if at_computer, the daemon skips it and schedules a 60s follow-up).

**Test 2: Stop hook** (API error; same flow as V1)

```bash
cat > /tmp/test-error-transcript.jsonl <<'EOF'
{"type":"user","message":{"role":"user","content":"hi"}}
{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"Request too large (max 32MB)."}]}}
EOF
printf '{"transcript_path":"/tmp/test-error-transcript.jsonl","cwd":"%s"}' "$HOME" \
  | ~/.claude/hooks/claude-error-notify.sh
tail -10 /tmp/claude-notify.log
rm -f /tmp/test-error-transcript.jsonl
```

**Test 3: ccr daemon interactive card** (V2 core)

```bash
cat > /tmp/test-ccr-payload.json <<'EOF'
{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/ccr-test-dir"},"cwd":"/tmp"}
EOF

# Waits for the user to tap a button on Lark (up to 10 minutes)
~/.claude/hooks/claude-ccr.sh < /tmp/test-ccr-payload.json
echo "exit=$?"
```

Expected:
- **Terminal frontmost**: daemon returns `local`, hook exits 0, no card. This is by design — don't disturb the user when they're at the computer.
- **Switched away / screen locked**: Lark receives a red "⚠️ Claude wants to run a risky command" card with command + cwd + humanized description + ✅ Approve / ❌ Deny.

For the frontmost short-circuit: just run it. For remote approval: switch to Lark or lock the screen before running.

### 8. Wrap-up

Tell the user:
- ✅ Installed. Open Lark and check the two test messages.
- Daemon log: `/tmp/ccr-daemon.log`; hook logs: `/tmp/ccr-approve.log`, `/tmp/claude-notify.log`.
- Command-line control: `ccr status / ccr enable / ccr disable / ccr restart / ccr log` (use `~/.claude/hooks/ccr` if it's not on `PATH`).
- Temporarily mute: `ccr disable`.
- Uninstall: see README.md.

## Notes

- **`--as bot` is required**: `im:message.send_as_user` is typically gated by enterprise policy, so the scripts always use the app identity.
- **Event subscription permission**: V2 relies on `lark-cli event +subscribe --event-types card.action.trigger` to receive button taps. The Lark app needs event subscription enabled (usually it is by default). If it's not, tapping buttons does nothing and the card spins for 10 minutes until timeout. `ccr status` prints `subscribe_alive` to help diagnose this.
- **Urgent needs an app scope**: same as V1.
- **AskUserQuestion: single-question only**: cards fire only when `questions.length == 1`; multi-question forms go straight to the local menu.
- **Concurrent sessions**: one daemon serves every Claude Code session on the host. Requests are isolated by `rid`; cards don't collide.
- **OPEN_ID is hardcoded into ccr-daemon.py + claude-error-notify.sh**: if the user switches accounts, re-run the Skill.
- **Click-to-focus is iTerm2-only**.
