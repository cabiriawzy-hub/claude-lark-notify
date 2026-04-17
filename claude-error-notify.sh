#!/usr/bin/env bash
# Claude Code Stop hook → Lark message on API errors only.
# Catches things like "Request too large (max 32MB)" that never trigger
# the idle Notification hook because the request fails before Claude waits.
# Installed by the claude-lark-notify skill. Edit OPEN_ID at the top if it changes.
set -euo pipefail

[[ "${CLAUDE_NOTIFY_DISABLE:-}" == "1" ]] && exit 0

OPEN_ID="__OPEN_ID__"
LOG="/tmp/claude-notify.log"
IDLE_MARKER="/tmp/claude-notify-active.marker"

payload=$(cat || true)
transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")
cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null || echo "")

[[ -z "$transcript" || ! -f "$transcript" ]] && exit 0

last=$(tail -30 "$transcript" 2>/dev/null | jq -c 'select(.type == "assistant")' 2>/dev/null | tail -1)
[[ -z "$last" ]] && exit 0

is_err=$(printf '%s' "$last" | jq -r '.isApiErrorMessage // false' 2>/dev/null)
[[ "$is_err" != "true" ]] && exit 0

err_text=$(printf '%s' "$last" | jq -r '.message.content[0].text // ""' 2>/dev/null)

friendly=""
case "$err_text" in
  *"Request too large"*|*"max 32MB"*|*"request_too_large"*)
    friendly="🚨 Request too large (over 32MB) — double-tap Esc to go back, or trim large files/output and retry"
    ;;
  *"rate_limit"*|*"Rate limit"*|*"rate limit"*)
    friendly="🚦 API rate-limited — wait a few minutes before retrying"
    ;;
  *"overloaded"*|*"Overloaded"*)
    friendly="🔥 Claude API overloaded — retry in a bit"
    ;;
  *"context_length"*|*"context length"*|*"maximum context"*)
    friendly="📦 Context full — start a new session or /compact"
    ;;
  *)
    clean=$(printf '%s' "$err_text" | tr '\n' ' ' | head -c 120)
    friendly="⚠️ Claude API error: ${clean}"
    ;;
esac

project=""
if [[ -n "$cwd" ]]; then
  if [[ "$cwd" == "$HOME" ]]; then
    project="~"
  elif [[ "$cwd" == "$HOME/"* ]]; then
    project="~/${cwd#$HOME/}"
  else
    project="$cwd"
  fi
fi

if [[ -n "$project" ]]; then
  text="${friendly} 📂 ${project}"
else
  text="${friendly}"
fi

content=$(jq -n --arg t "$text" '{text:$t}')

{
  echo "=== $(date '+%F %T') [error-notify] ==="
  echo "err: $(printf '%s' "$err_text" | head -c 200)"
  echo "sent: $text"
  resp=$(lark-cli im +messages-send \
    --user-id "$OPEN_ID" \
    --msg-type text \
    --content "$content" \
    --as bot 2>&1) || true
  printf '%s\n' "$resp" | head -5

  mid=$(printf '%s' "$resp" | jq -r '.data.message_id // .message_id // empty' 2>/dev/null)
  if [[ -n "$mid" ]]; then
    echo "urgent_app for $mid"
    lark-cli api PATCH "/open-apis/im/v1/messages/${mid}/urgent_app" \
      --params '{"user_id_type":"open_id"}' \
      --data "{\"user_id_list\":[\"${OPEN_ID}\"]}" \
      --as bot 2>&1 | head -5 || echo "(urgent failed)"
  else
    echo "(no message_id — skip urgent)"
  fi
} >> "$LOG" 2>&1

touch "$IDLE_MARKER"
exit 0
