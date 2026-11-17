#!/usr/bin/env bash
# Write a private Devin worker config, preserving user settings and hooks.
# Usage: fm-devin-config.sh [--secondmate <home>] <state-dir> <task-id> <busy-gen> [<user-config>]
# The default source is ~/.config/devin/config.json (Devin's --config default).
# An absent source starts from {}; unreadable or malformed sources refuse.
# Output: <state-dir>/<task-id>.devin-config.json, mode 600, atomically replaced.
# No project or user config is edited. fm-control-lib.sh owns retirement.
# read_config_from.claude=false is forced for every worker,
# because Devin otherwise runs every Claude Code hook it finds (~/.claude and
# the project's .claude/settings*.json), including Herdr's hook that reports
# the pane as a Claude agent; it also drops Devin's CLAUDE.md, .claude/skills,
# and Claude MCP imports, while AGENTS.md and .agents/skills still load.
# attribution=false is forced too, because Devin otherwise adds a
# Co-Authored-By: Devin trailer and a Generated with Devin line to commits
# and PRs, unless FM_KEEP_AI_TRAILERS=1 (fm-spawn sets it when the home has
# config/keep-ai-trailers); then the source's attribution setting is kept.
# UserPromptSubmit opens a turn; Stop and SessionEnd close it. Devin 3000.11.1
# emits no Stop on double-Escape cancellation, so fm-control invalidates its
# state to unknown after delivering that interrupt, never fabricating idle.
# Turn-end touches follow a successful generation-bound apply; events
# rejected as stale emit no notification.
# --secondmate <home> writes a Devin secondmate's config instead: <home> is
# the mate's own firstmate home (an existing directory, resolved with pwd -P)
# and the added hooks point at <home>/bin/fm-devin-primary.sh, the same hook
# owner a Devin primary registers (docs/configuration.md "Devin secondmate").
# The busy UserPromptSubmit and SessionEnd writes stay, so the parent's
# active-turn gate still reads this mate's verdicts, but no busy idle Stop
# hook and no turn-ended touch are added: a secondmate never touches the
# parent's turn-ended marker, and the Stop verdict reaches the parent busy
# record through <home>/.fm-busy-stop, which fm-devin-primary.sh stop reads.
# A fail-closed SessionStart hook arms the mate's own lock and quiet daemon,
# and the same ask_user_question PreToolUse block a Devin primary carries
# keeps a held dialog from wedging the mate's supervised pane.
set -eu
case "${1:-}" in
  -h|--help)
    sed -n '2,/^set -eu/{ /^#/s/^# \{0,1\}//p; }' "$0"
    exit 0
    ;;
esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SM_HOME=
if [ "${1:-}" = --secondmate ]; then
  SM_HOME=${2:?--secondmate needs a home directory}
  shift 2
  [ -d "$SM_HOME" ] || { echo 'error: --secondmate home directory missing' >&2; exit 1; }
  SM_HOME=$(cd "$SM_HOME" && pwd -P)
fi
STATE=${1:?state directory required}
ID=${2:?task id required}
GEN=${3:?busy generation required}
SOURCE=${4:-$HOME/.config/devin/config.json}
KEEP=${FM_KEEP_AI_TRAILERS:-0}
case "$ID" in ''|*[!A-Za-z0-9._-]*) echo 'error: invalid task id' >&2; exit 1 ;; esac
[ -d "$STATE" ] || { echo 'error: state directory missing' >&2; exit 1; }
STATE=$(cd "$STATE" && pwd -P)
quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
prefix="$(quote "$SCRIPT_DIR/fm-busy-event.sh") apply $(quote "$STATE") $(quote "$ID")"
suffix="--gen $(quote "$GEN") --source devin-hook"
submit="$prefix busy $suffix --event user-prompt-submit >/dev/null 2>&1 || true"
stop="$prefix idle $suffix --event stop >/dev/null 2>&1 && touch $(quote "$STATE/$ID.turn-ended"); true"
end="$prefix idle $suffix --event session-end >/dev/null 2>&1 || true"
if [ ! -e "$SOURCE" ] && [ ! -L "$SOURCE" ]; then SOURCE=/dev/null; fi
umask 077
temp=$(mktemp "$STATE/.$ID.devin-config.XXXXXX")
trap 'rm -f "$temp"' EXIT
if [ -z "$SM_HOME" ]; then
  jq -s --arg keep "$KEEP" --arg submit "$submit" --arg stop "$stop" --arg end "$end" '
    (if length == 0 then {} elif length == 1 then .[0] else error("expected one config object") end) |
    if type != "object" then error("expected config object") else . end |
    (if $keep == "1" then . else .attribution = false end) |
    .read_config_from = ((.read_config_from // {}) + {claude: false}) |
    .hooks = (.hooks // {}) |
    def hook($cmd): {hooks: [{type: "command", command: $cmd, timeout: 10}]};
    .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) + [hook($submit)]) |
    .hooks.Stop = ((.hooks.Stop // []) + [hook($stop)]) |
    .hooks.SessionEnd = ((.hooks.SessionEnd // []) + [hook($end)])
  ' "$SOURCE" > "$temp"
else
  wrapper="bash $(quote "$SM_HOME/bin/fm-devin-primary.sh")"
  question_block='printf %s '"'"'{"decision":"block","reason":"Firstmate on Devin: never open a question dialog; ask in plain text and end the turn."}'"'"''
  jq -s --arg keep "$KEEP" --arg submit "$submit" --arg end "$end" \
      --arg wrapper "$wrapper" --arg qblock "$question_block" '
    (if length == 0 then {} elif length == 1 then .[0] else error("expected one config object") end) |
    if type != "object" then error("expected config object") else . end |
    (if $keep == "1" then . else .attribution = false end) |
    .read_config_from = ((.read_config_from // {}) + {claude: false}) |
    .hooks = (.hooks // {}) |
    def hook($cmd): {hooks: [{type: "command", command: $cmd, timeout: 10}]};
    def primary($sub; $timeout): {matcher: "", hooks: [{type: "command", command: ($wrapper + " " + $sub), timeout: $timeout}]};
    def primary_fc($sub; $timeout): {matcher: "", hooks: [{type: "command", command: ($wrapper + " " + $sub), timeout: $timeout, fail_closed: true}]};
    .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) + [hook($submit)]) |
    .hooks.SessionStart = ((.hooks.SessionStart // []) + [primary_fc("session-start"; 120)]) |
    .hooks.Stop = ((.hooks.Stop // []) + [primary("stop"; 90)]) |
    .hooks.SessionEnd = ((.hooks.SessionEnd // []) + [hook($end), primary("session-end"; 60)]) |
    .hooks.PreToolUse = ((.hooks.PreToolUse // []) +
      [{matcher: "^ask_user_question$", hooks: [{type: "command", command: $qblock, timeout: 10}]}])
  ' "$SOURCE" > "$temp"
fi
mv "$temp" "$STATE/$ID.devin-config.json"
