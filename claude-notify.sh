#!/usr/bin/env bash
# Claude Code Notification hook → Lark/Feishu message (with urgent-app push).
# Installed by the claude-lark-notify skill. Edit OPEN_ID at the top if it changes.
set -euo pipefail

[[ "${CLAUDE_NOTIFY_DISABLE:-}" == "1" ]] && exit 0

OPEN_ID="__OPEN_ID__"
MARKER="/tmp/claude-notify-active.marker"
LOG="/tmp/claude-notify.log"

[[ -f "$MARKER" ]] && exit 0

humanize_bash() {
  local c="$1"
  c=$(printf '%s' "$c" | sed -E 's/^([[:space:]]*[A-Z_][A-Z0-9_]*=[^[:space:]]+[[:space:]]+)+//; s/^[[:space:]]+//')
  case "$c" in
    "rm -rf"*)                                     echo "⚠️ delete an entire folder (irreversible!)" ;;
    "rm "*)                                        echo "delete a file" ;;
    "git push"*)                                   echo "push code to remote" ;;
    "git pull"*|"git fetch"*)                      echo "pull from remote" ;;
    "git commit"*)                                 echo "commit changes" ;;
    "git add"*)                                    echo "stage changes" ;;
    "git clone"*)                                  echo "clone a repo" ;;
    "git checkout"*|"git switch"*)                 echo "switch branch" ;;
    "git merge"*)                                  echo "merge branches" ;;
    "git rebase"*)                                 echo "rebase" ;;
    "git reset"*|"git revert"*|"git restore"*)     echo "undo changes" ;;
    "git status"*|"git log"*|"git diff"*|"git show"*|"git branch"*) echo "inspect git state" ;;
    "git "*)                                       echo "run a git command" ;;
    "npm install"*|"npm i"*|"pnpm install"*|"yarn install"*|"yarn") echo "install dependencies" ;;
    "npm run dev"*|"npm start"*|"npm run start"*)  echo "start the dev server" ;;
    "npm run build"*|"pnpm build"*)                echo "build the project" ;;
    "npm run typecheck"*|"npm run test"*|"npm test"*|"npm t"*) echo "run tests" ;;
    "npm run lint"*)                               echo "run the linter" ;;
    "npm run"*|"pnpm run"*|"bun run"*)             echo "run a project script" ;;
    "npx "*|"bunx "*|"pnpx "*)                     echo "run a one-off tool" ;;
    "curl "*)                                      echo "hit the network / call an API" ;;
    "wget "*)                                      echo "download a file" ;;
    "mkdir "*)                                     echo "create a folder" ;;
    "mv "*)                                        echo "move/rename a file" ;;
    "cp "*)                                        echo "copy a file" ;;
    "chmod "*|"chown "*)                           echo "change file permissions" ;;
    "ln "*)                                        echo "make a symlink" ;;
    "lark-cli "*)                                  echo "run a lark-cli command" ;;
    "python3 "*|"python "*)                        echo "run a Python script" ;;
    "node "*)                                      echo "run a Node.js script" ;;
    "bun "*)                                       echo "run a Bun command" ;;
    "pip install"*)                                echo "install a Python package" ;;
    "pip "*)                                       echo "manage Python packages" ;;
    "brew install"*)                               echo "install software" ;;
    "brew "*)                                      echo "manage software" ;;
    "docker "*)                                    echo "work with containers" ;;
    "ssh "*)                                       echo "SSH into another machine" ;;
    "kill "*|"pkill "*|"killall "*)                echo "kill a process" ;;
    "ps "*|"ps"|"top"|"htop")                      echo "list running processes" ;;
    "ls"|"ls "*)                                   echo "list files" ;;
    "cat "*|"head "*|"tail "*|"bat "*)             echo "view a file" ;;
    "find "*|"fd "*)                               echo "find files" ;;
    "grep "*|"rg "*|"ack "*)                       echo "search for text" ;;
    "open "*)                                      echo "open a file/URL" ;;
    "gh pr"*)                                      echo "work with a GitHub PR" ;;
    "gh issue"*)                                   echo "work with a GitHub Issue" ;;
    "gh "*)                                        echo "work with GitHub" ;;
    "claude "*|"claude")                           echo "manage Claude Code itself" ;;
    "cd "*|"cd")                                   echo "change directory" ;;
    "echo "*|"printf "*)                           echo "print something" ;;
    "sleep "*)                                     echo "wait a moment" ;;
    "jq "*)                                        echo "process JSON" ;;
    *)                                             echo "" ;;
  esac
}

payload=$(cat || true)
raw_msg=$(printf '%s' "$payload" | jq -r '.message // ""' 2>/dev/null || echo "")
cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null || echo "")
transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")

perm_tool=""
if [[ "$raw_msg" == *"permission to use "* ]]; then
  perm_tool=$(printf '%s' "$raw_msg" | sed -E 's/.*permission to use ([A-Za-z_]+).*/\1/')
fi

action=""
last_tool=""
if [[ -n "$transcript" && -f "$transcript" ]]; then
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
        q=$(printf '%s' "$last_tu" | jq -r '.input.questions[0].question // ""' | cut -c1-50)
        action="ask \"${q}\""
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

friendly=""
urgent=0
case "$raw_msg" in
  *"permission to use "*)
    tool=$(printf '%s' "$raw_msg" | sed -E 's/.*permission to use ([A-Za-z_]+).*/\1/')
    if [[ -n "$action" ]]; then
      friendly="🐾 Claude wants to ${action} — approve to continue"
    else
      friendly="🐾 Claude wants to use ${tool} — approve to continue"
    fi
    urgent=1
    ;;
  *"permission"*|*"Permission"*)
    if [[ -n "$action" ]]; then
      friendly="✋ Claude wants to ${action} — tap approve to continue"
    else
      friendly="✋ Claude is waiting for a permission tap"
    fi
    urgent=1
    ;;
  *"waiting for your input"*|*"waiting for input"*)
    if [[ "$last_tool" == "AskUserQuestion" ]]; then
      friendly="🙋 Claude wants to ${action} — pick an option"
      urgent=1
    else
      friendly="💤 Claude is done — come back when you're ready"
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
    ;;
  "")
    friendly="👀 Claude can't find you — come back"
    ;;
  *)
    msg_clean=$(printf '%s' "$raw_msg" | sed -E 's/^[Cc]laude([[:space:]][Cc]ode)?[[:space:]]+//')
    friendly="🔔 Claude ${msg_clean}"
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
  echo "=== $(date '+%F %T') ==="
  echo "raw: $raw_msg"
  echo "sent: $text"
  resp=$(lark-cli im +messages-send \
    --user-id "$OPEN_ID" \
    --msg-type text \
    --content "$content" \
    --as bot 2>&1) || true
  printf '%s\n' "$resp" | head -5

  if [[ "$urgent" == "1" ]]; then
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
  fi
} >> "$LOG" 2>&1

touch "$MARKER"
exit 0
