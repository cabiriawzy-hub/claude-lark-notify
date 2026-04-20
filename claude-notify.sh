#!/usr/bin/env bash
# Fires on Claude Code Notification events (permission prompt / idle 60s+).
# Dedups to one Lark message per idle session via a marker file that's
# cleared by the UserPromptSubmit hook when the user replies.
set -euo pipefail

[[ "${CLAUDE_NOTIFY_DISABLE:-}" == "1" ]] && exit 0

MARKER="/tmp/claude-notify-active.marker"
LOG="/tmp/claude-notify.log"

[[ -f "$MARKER" ]] && exit 0

# Translate a shell command into plain Chinese. Returns empty if no match.
humanize_bash() {
  local c="$1"
  # Strip leading env-var assignments (FOO=bar cmd ...)
  c=$(printf '%s' "$c" | sed -E 's/^([[:space:]]*[A-Z_][A-Z0-9_]*=[^[:space:]]+[[:space:]]+)+//; s/^[[:space:]]+//')
  case "$c" in
    "rm -rf"*)                          echo "⚠️ delete an entire folder (irreversible!)" ;;
    "rm "*)                             echo "delete a file" ;;
    "git push"*)                        echo "push code to remote" ;;
    "git pull"*|"git fetch"*)           echo "pull from remote" ;;
    "git commit"*)                      echo "commit changes" ;;
    "git add"*)                         echo "stage changes" ;;
    "git clone"*)                       echo "clone a repo" ;;
    "git checkout"*|"git switch"*)      echo "switch branch" ;;
    "git merge"*)                       echo "merge branches" ;;
    "git rebase"*)                      echo "rebase" ;;
    "git reset"*|"git revert"*|"git restore"*) echo "undo changes" ;;
    "git status"*|"git log"*|"git diff"*|"git show"*|"git branch"*) echo "inspect git state" ;;
    "git "*)                            echo "run a git command" ;;
    "npm install"*|"npm i"*|"pnpm install"*|"yarn install"*|"yarn") echo "install dependencies" ;;
    "npm run dev"*|"npm start"*|"npm run start"*) echo "start the dev server" ;;
    "npm run build"*|"pnpm build"*)     echo "build the project" ;;
    "npm run typecheck"*|"npm run test"*|"npm test"*|"npm t"*) echo "run tests" ;;
    "npm run lint"*)                    echo "run the linter" ;;
    "npm run"*|"pnpm run"*|"bun run"*)  echo "run a project script" ;;
    "npx "*|"bunx "*|"pnpx "*)          echo "run a one-off tool" ;;
    "curl "*)                           echo "hit the network / call an API" ;;
    "wget "*)                           echo "download a file" ;;
    "mkdir "*)                          echo "create a folder" ;;
    "mv "*)                             echo "move/rename a file" ;;
    "cp "*)                             echo "copy a file" ;;
    "chmod "*|"chown "*)                echo "change file permissions" ;;
    "ln "*)                             echo "make a symlink" ;;
    "lark-cli docs +fetch"*|"lark-cli docs +search"*|"lark-cli docs +media-preview"*|"lark-cli docs +media-download"*) echo "read a Lark doc" ;;
    "lark-cli docs"*)                   echo "edit a Lark doc" ;;
    "lark-cli wiki"*)                   echo "work with Lark Wiki" ;;
    "lark-cli minutes"*)                echo "read Lark Minutes" ;;
    "lark-cli vc"*)                     echo "read Lark VC info" ;;
    "lark-cli whiteboard"*)             echo "work with Lark Whiteboard" ;;
    "lark-cli im +messages-send"*|"lark-cli im messages send"*) echo "send a Lark message" ;;
    "lark-cli im +messages-reply"*|"lark-cli im messages reply"*) echo "reply to a Lark message" ;;
    "lark-cli im +chat-create"*|"lark-cli im +chat-update"*) echo "manage a Lark chat" ;;
    "lark-cli im +messages-resources-download"*) echo "download Lark attachments" ;;
    "lark-cli im"*)                     echo "read Lark messages" ;;
    "lark-cli api"*)                    echo "call the Lark API" ;;
    "lark-cli auth"*)                   echo "Lark login/auth" ;;
    "lark-cli schema"*)                 echo "inspect Lark API schema" ;;
    "lark-cli "*)                       echo "run a lark-cli command" ;;
    "paperclipai agent"*)               echo "run Paperclip agent" ;;
    "paperclipai inbox"*)               echo "check Paperclip inbox" ;;
    "paperclipai db:"*|"paperclipai "*"db "*) echo "⚠️ query/modify Paperclip DB" ;;
    "paperclipai "*)                    echo "run a Paperclip command" ;;
    "python3 "*|"python "*)             echo "run a Python script" ;;
    "node "*)                           echo "run a Node.js script" ;;
    "bun "*)                            echo "run a Bun command" ;;
    "pip install"*)                     echo "install a Python package" ;;
    "pip "*)                            echo "manage Python packages" ;;
    "brew install"*)                    echo "install software" ;;
    "brew "*)                           echo "manage software" ;;
    "docker "*)                         echo "work with containers" ;;
    "ssh "*)                            echo "SSH into another machine" ;;
    "kill "*|"pkill "*|"killall "*)     echo "kill a process" ;;
    "ps "*|"ps"|"top"|"htop")           echo "list running processes" ;;
    "ls"|"ls "*)                        echo "list files" ;;
    "cat "*|"head "*|"tail "*|"bat "*)  echo "view a file" ;;
    "find "*|"fd "*)                    echo "find files" ;;
    "grep "*|"rg "*|"ack "*)            echo "search for text" ;;
    "open "*)                           echo "open a file/URL" ;;
    "gh pr"*)                           echo "work with a GitHub PR" ;;
    "gh issue"*)                        echo "work with a GitHub Issue" ;;
    "gh "*)                             echo "work with GitHub" ;;
    "firecrawl "*)                      echo "scrape a webpage" ;;
    "claude "*|"claude")                echo "manage Claude Code itself" ;;
    "cd "*|"cd")                        echo "change directory" ;;
    "echo "*|"printf "*)                echo "print something" ;;
    "sleep "*)                          echo "wait a moment" ;;
    "jq "*)                             echo "process JSON" ;;
    *)                                  echo "" ;;
  esac
}

payload=$(cat || true)
raw_msg=$(printf '%s' "$payload" | jq -r '.message // ""' 2>/dev/null || echo "")
cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null || echo "")
transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")

# Peek at the last tool_use in the transcript to describe what Claude wants to do.
# The Notification fires while the tool is queued awaiting permission, so the
# most recent tool_use is the one we're being asked about.
perm_tool=""
if [[ "$raw_msg" == *"permission to use "* ]]; then
  perm_tool=$(printf '%s' "$raw_msg" | sed -E 's/.*permission to use ([A-Za-z_]+).*/\1/')
fi

action=""
last_tool=""

# Prefer the pending-tool marker written by claude-ccr.sh — it's authoritative
# for the CURRENT tool awaiting permission/answer. Transcript can lag
# (AskUserQuestion's tool_use only flushes after the user answers).
PENDING_TOOL_MARKER="/tmp/ccr-pending-tool.json"
if [[ -f "$PENDING_TOOL_MARKER" ]]; then
  # Only trust marker if recent (within 10 minutes) — stale marker means
  # PostToolUse failed to clean up; fall back to transcript.
  if [[ $(($(date +%s) - $(stat -f %m "$PENDING_TOOL_MARKER" 2>/dev/null || echo 0))) -lt 600 ]]; then
    last_tool=$(jq -r '.tool // ""' "$PENDING_TOOL_MARKER" 2>/dev/null || echo "")
    action=$(jq -r '.action // ""' "$PENDING_TOOL_MARKER" 2>/dev/null || echo "")
  fi
fi

if [[ -z "$last_tool" && -n "$transcript" && -f "$transcript" ]]; then
  if [[ -n "$perm_tool" ]]; then
    last_tu=$(tail -200 "$transcript" 2>/dev/null \
      | jq -c --arg t "$perm_tool" 'select(.message.content? | type=="array") | .message.content[]? | select(.type=="tool_use" and .name == $t)' 2>/dev/null \
      | tail -1)
  else
    last_tu=$(tail -200 "$transcript" 2>/dev/null \
      | jq -c 'select(.message.content? | type=="array") | .message.content[]? | select(.type=="tool_use")' 2>/dev/null \
      | tail -1)
  fi
  if [[ -n "$last_tu" ]]; then
    tname=$(printf '%s' "$last_tu" | jq -r '.name // ""')
    last_tool="$tname"
    case "$tname" in
      Bash)
        cmd=$(printf '%s' "$last_tu" | jq -r '.input.command // ""' | head -1 | cut -c1-80)
        human=$(humanize_bash "$cmd")
        if [[ -n "$human" ]]; then
          action="$human"
        else
          action="run \`${cmd}\`"
        fi
        ;;
      Edit|Write|NotebookEdit)
        fp=$(printf '%s' "$last_tu" | jq -r '.input.file_path // ""')
        action="edit $(basename "$fp")"
        ;;
      Read)
        fp=$(printf '%s' "$last_tu" | jq -r '.input.file_path // ""')
        action="read $(basename "$fp")"
        ;;
      WebFetch)
        url=$(printf '%s' "$last_tu" | jq -r '.input.url // ""' | cut -c1-60)
        action="fetch ${url}"
        ;;
      WebSearch)
        q=$(printf '%s' "$last_tu" | jq -r '.input.query // ""' | cut -c1-40)
        action="search ${q}"
        ;;
      Glob|Grep)
        p=$(printf '%s' "$last_tu" | jq -r '.input.pattern // ""' | cut -c1-40)
        action="grep ${p}"
        ;;
      AskUserQuestion)
        q=$(printf '%s' "$last_tu" | jq -r '.input.questions[0].question // ""' \
          | /usr/bin/python3 -c 'import sys; s=sys.stdin.read().strip().replace("\n"," "); print(s[:30] + ("…" if len(s)>30 else ""), end="")')
        action="ask "${q}""
        ;;
      TaskCreate|TaskUpdate|TaskGet|TaskList)
        action="update the task list"
        ;;
      TaskOutput|TaskStop)
        action="manage a background task"
        ;;
      EnterPlanMode|ExitPlanMode)
        action="toggle plan mode"
        ;;
      EnterWorktree|ExitWorktree)
        action="switch worktree"
        ;;
      Agent)
        action="dispatch a subagent"
        ;;
      Skill)
        action="invoke a skill"
        ;;
      mcp__*)
        action="call ${tname#mcp__}"
        ;;
      "")
        ;;
      *)
        action="${tname}"
        ;;
    esac
  fi
fi

# Map Claude Code's English notification to plain Chinese with emoji.
# silence_if_at_computer: suppress Feishu when user is at computer.
#   - "permission to use" / "needs attention" fire immediately when prompt
#     appears; user already sees local menu, no phone ping needed
#   - "waiting for input" fires AFTER ~60s idle; user may have drifted, send
friendly=""
urgent=0
silence_if_at_computer=false
case "$raw_msg" in
  *"permission to use "*)
    tool=$(printf '%s' "$raw_msg" | sed -E 's/.*permission to use ([A-Za-z_]+).*/\1/')
    if [[ -n "$action" ]]; then
      friendly="🐾 Claude wants to ${action} — approve to continue"
    else
      friendly="🐾 Claude wants to use ${tool} — approve to continue"
    fi
    urgent=1
    silence_if_at_computer=true
    ;;
  *"permission"*|*"Permission"*)
    if [[ -n "$action" ]]; then
      friendly="✋ Claude wants to ${action} — tap approve to continue"
    else
      friendly="✋ Claude is waiting for a permission tap"
    fi
    urgent=1
    silence_if_at_computer=true
    ;;
  *"waiting for your input"*|*"waiting for input"*)
    if [[ "$last_tool" == "AskUserQuestion" ]]; then
      friendly="🙋 Claude wants to ${action} — pick an option"
      urgent=1
    else
      # Heuristic: if Claude's last assistant text ends with a question
      # mark, treat it as a blocking question and urgent-ping.
      # Find the last assistant record that actually HAS text (skip pure
      # tool_use turns), then join its text blocks. Skip "No response
      # requested." — Claude Code injects it into some sidechain transcripts
      # and it's not a real assistant reply.
      last_text=""
      if [[ -n "$transcript" && -f "$transcript" ]]; then
        last_text=$(tail -200 "$transcript" 2>/dev/null \
          | jq -c 'select(.type=="assistant") | . as $r | ([.message.content[]? | select(.type=="text") | .text] | join(" ")) as $t | select($t != "" and ($t | test("^No response requested\\.?$") | not)) | $t' 2>/dev/null \
          | tail -1 \
          | jq -r '.' 2>/dev/null \
          | tr -d '[:space:]' | tail -c 3)
      fi
      if [[ "$last_text" == *"?" || "$last_text" == *"？" ]]; then
        friendly="❓ Claude is asking you a question — reply to continue"
        urgent=1
      else
        friendly="💤 Claude is done — come back when you're ready"
      fi
    fi
    ;;
  *"needs your attention"*|*"needs attention"*)
    if [[ "$last_tool" == "AskUserQuestion" ]]; then
      friendly="🙋 Claude wants to ${action} — pick an option"
    elif [[ -n "$action" ]]; then
      friendly="🔔 Claude wants to ${action} — take a look"
    else
      friendly="🔔 Claude needs you — take a look"
    fi
    urgent=1
    silence_if_at_computer=true
    ;;
  "")
    friendly="👀 Claude can't find you — come back"
    ;;
  *)
    msg_clean=$(printf '%s' "$raw_msg" | sed -E 's/^[Cc]laude([[:space:]][Cc]ode)?[[:space:]]+//')
    friendly="🔔 Claude ${msg_clean}"
    ;;
esac

# Show ~/… for paths under $HOME, else last two path segments.
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

text="${friendly}"

# iTerm click-to-focus URL; the daemon renders it as a card button.
focus_url=""
if [[ "${TERM_PROGRAM:-}" == "iTerm.app" && -n "${ITERM_SESSION_ID:-}" ]]; then
  uuid="${ITERM_SESSION_ID##*:}"
  if [[ "$uuid" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
    focus_url="http://localhost:47823/focus?id=${uuid}"
  fi
fi

body=$(jq -n --arg text "$text" --arg cwd "$cwd" \
  --arg url "$focus_url" --argjson urgent "$urgent" \
  --argjson silence "$silence_if_at_computer" \
  '{text:$text, cwd:$cwd, iterm_focus_url:$url, urgent:($urgent==1),
    silence_if_at_computer:$silence}')

{
  echo "=== $(date '+%F %T') ==="
  echo "raw: $raw_msg"
  echo "sent: $text"
  resp=$(curl -sS --max-time 15 -X POST http://127.0.0.1:19837/notify \
    -H 'Content-Type: application/json' \
    -d "$body" 2>&1) || true
  printf '%s\n' "$resp" | head -5
} >> "$LOG" 2>&1

# Only mark "already notified" if daemon actually delivered. If daemon skipped
# (e.g. permission notification while at_computer), leave MARKER unset so the
# follow-up "waiting for input" notification at t=60s+ can still fire.
if printf '%s' "$resp" | grep -q '"skipped"'; then
  echo "resp indicated skip; MARKER not set" >> "$LOG"
else
  touch "$MARKER"
fi
exit 0
