#!/usr/bin/env bash
# tests/fm-devin-secondmate.test.sh - the Devin secondmate path: the generated
# secondmate config (fm-devin-config.sh --secondmate), the spawn wiring and
# its refusals, the parent's busy record through the home's .fm-busy-stop
# pointer, and the home's own lock + quiet daemon lifecycle.
#
# Hook runs reuse the fm-devin-primary.test.sh mechanics: a devin-named fake
# process so the session-lock ancestry walk resolves as under the real CLI,
# and a stub daemon (FM_AFK_LAUNCH_ENTRY) so the launch and lock mechanics are
# real while no watcher runs.
# shellcheck disable=SC2016 # single quotes are deliberate: $$ and $FM_HOME expand inside the fixture child
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-devin-secondmate)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s /bin/bash "$FAKEBIN/devin"
NAMED_DEVIN="$FAKEBIN/devin"

export FM_TEST_HARNESS=devin FM_TEST_SEAM=1
unset PI_CODING_AGENT FM_PI_HARNESS CURSOR_AGENT CURSOR_INVOKED_AS CLAUDECODE GEMINI_CLI ATLASSIAN_AGENT_TYPE ROVODEV_CLI

# A private tmux server for the daemon terminals the launch path creates.
export TMUX_TMPDIR="$TMP_ROOT/tmux-server"
mkdir -p "$TMUX_TMPDIR"

# The same stub daemon as fm-devin-primary.test.sh: records its identity in
# the home's daemon lock and stays alive without running a watcher, so
# fm_afk_daemon_owns_supervision holds while .last-watcher-beat stays stale.
STUB_DAEMON="$TMP_ROOT/stub-daemon.sh"
cat > "$STUB_DAEMON" <<SH
#!/usr/bin/env bash
set -u
. "$ROOT/bin/fm-wake-lib.sh"
state="\${FM_HOME:?}/state"
mkdir -p "\$state/.supervise-daemon.lock"
printf '%s\n' "\$\$" > "\$state/.supervise-daemon.lock/pid"
fm_pid_identity "\$\$" > "\$state/.supervise-daemon.lock/pid-identity"
trap 'rm -rf "\$state/.supervise-daemon.lock"; exit 0' TERM
sleep 600
SH
chmod +x "$STUB_DAEMON"

pid_alive() {  # <pid>
  bash -c '. "$1"; fm_pid_alive "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$1"
}

BG_PIDS=()
CLEANUP() {
  local pid
  for pid in ${BG_PIDS[@]+"${BG_PIDS[@]}"}; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  tmux kill-server 2>/dev/null || true
}
trap 'CLEANUP; fm_test_cleanup' EXIT

# A genuine secondmate home: the full tracked bin/ and docs/ trees, an
# AGENTS.md, a valid .fm-secondmate-home marker, and the home's own
# state/config/data dirs. The marker makes fm_primary_root_matches accept it
# without a plain-checkout .git, but the home still gets one so the spawn's
# git-exclude path runs for real.
make_sm_home() {  # <dir-path> [id]
  local dir=$1 id=${2:-sm-devin}
  mkdir -p "$dir/state" "$dir/config" "$dir/data" "$dir/projects"
  cp -R "$ROOT/bin" "$ROOT/docs" "$dir/"
  : > "$dir/AGENTS.md"
  printf '%s\n' "$id" > "$dir/.fm-secondmate-home"
  printf 'charter\n' > "$dir/data/charter.md"
  fm_git_init_commit "$dir" >/dev/null
  printf '%s\n' "$dir"
}

# Run a hook subcommand inside a devin-named process in home <home>, with the
# pane seam set so the launch path can resolve the supervisor endpoint.
run_hook() {  # <subcommand> <home> [payload] [extra-env...]
  local sub=$1 home=$2 payload=${3:-'{}'}
  shift 3 || shift $#
  env -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID "$@" \
    FM_HOME="$home" FM_SUPERVISOR_TARGET=test-pane FM_SUPERVISOR_BACKEND=tmux \
    FM_AFK_LAUNCH_ENTRY="$STUB_DAEMON" \
    "$NAMED_DEVIN" -c '
      printf "%s" "$1" | bash "$2" "$3" > "$4/out" 2> "$4/err"
      printf "%s\n" "$?" > "$4/rc"
    ' _ "$payload" "$home/bin/fm-devin-primary.sh" "$sub" "$home"
  cat "$home/out" 2>/dev/null || true
}

run_hook_rc() { tr -d '[:space:]' < "$1/rc" 2>/dev/null || true; }
run_hook_err() { cat "$1/err" 2>/dev/null || true; }

# A live devin-named process outside the hook's own ancestry: a foreign lock
# owner the reclaim must refuse.
start_foreign_devin() {
  "$NAMED_DEVIN" -c 'sleep 60 & wait' >/dev/null 2>&1 &
  BG_PIDS+=("$!")
  printf '%s\n' "$!"
}

# Run the stop hook as the lock-owning devin session of <home>.
run_owned_stop() {  # <home> <payload>
  env -u TMUX_PANE \
    FM_HOME="$1" FM_SUPERVISOR_TARGET=test-pane FM_SUPERVISOR_BACKEND=tmux \
    FM_AFK_LAUNCH_ENTRY="$STUB_DAEMON" FM_TURNEND_MAX_BLOCKS=3 \
    "$NAMED_DEVIN" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s" "$1" | bash "$0" stop 2> "$FM_HOME/stop-err"
    ' "$1/bin/fm-devin-primary.sh" "$2"
}

wait_daemon_pid() {  # <home>
  local i=0
  while [ "$i" -lt 100 ] && [ ! -s "$1/state/.supervise-daemon.lock/pid-identity" ]; do
    i=$((i + 1))
    sleep 0.05
  done
  cat "$1/state/.supervise-daemon.lock/pid" 2>/dev/null
}

# Start a daemon for <home> the way an earlier primary would have: through the
# real launch path, for <pane>. Prints its pid.
start_earlier_daemon() {  # <home> <pane>
  env -u TMUX_PANE FM_HOME="$1" FM_SUPERVISOR_TARGET="$2" FM_SUPERVISOR_BACKEND=tmux \
    FM_AFK_LAUNCH_ENTRY="$STUB_DAEMON" FM_AFK_MODE=quiet \
    bash -c '"$0" enter && "$0" start' "$1/bin/fm-afk-launch.sh" >/dev/null 2>&1 \
    || fail "could not start the earlier daemon for the fixture"
  wait_daemon_pid "$1"
}

# Write the secondmate's .fm-busy-stop pointer bound to a parent busy record
# armed in <parent-state> for <id>. Prints the armed gen.
arm_parent_pointer() {  # <home> <parent-state> <id>
  local home=$1 pstate=$2 id=$3 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$pstate" "$id")
  {
    printf 'writer=%s\n' "$ROOT/bin/fm-busy-event.sh"
    printf 'state=%s\n' "$pstate"
    printf 'id=%s\n' "$id"
    printf 'gen=%s\n' "$gen"
  } > "$home/.fm-busy-stop"
  printf '%s\n' "$gen"
}

test_config_secondmate_shape() {
  local dir sm state gen config
  dir="$TMP_ROOT/cfg"
  sm=$(make_sm_home "$dir/sm")
  state="$dir/state"
  mkdir -p "$state"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" sm-devin)
  printf '%s\n' '{"agent":{"model":"swe-2-high"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo user-stop"}]}],"SessionStart":[{"hooks":[{"type":"command","command":"echo user-start"}]}]}}' \
    > "$dir/user.json"
  "$ROOT/bin/fm-devin-config.sh" --secondmate "$sm" "$state" sm-devin "$gen" "$dir/user.json" \
    || fail 'secondmate config writer failed'
  config="$state/sm-devin.devin-config.json"
  [ "$(jq -r '.read_config_from.claude' "$config")" = false ] || fail 'secondmate config imports Claude config'
  [ "$(jq -r '.attribution' "$config")" = false ] || fail 'secondmate config keeps Devin attribution'
  jq -e '.agent.model == "swe-2-high"' "$config" >/dev/null || fail 'user settings lost'
  jq -e '[.hooks.Stop[].hooks[].command] | any(. == "echo user-stop")' "$config" >/dev/null \
    || fail 'user Stop hooks were not preserved'
  jq -e '[.hooks.SessionStart[].hooks[].command] | any(. == "echo user-start")' "$config" >/dev/null \
    || fail 'user SessionStart hooks were not preserved'
  jq -e --arg c "bash '$sm/bin/fm-devin-primary.sh' session-start" \
    '.hooks.SessionStart[-1] | .matcher == "" and .hooks[0].command == $c and .hooks[0].timeout == 120 and .hooks[0].fail_closed == true' \
    "$config" >/dev/null || fail 'secondmate SessionStart hook missing or not fail-closed'
  jq -e --arg c "bash '$sm/bin/fm-devin-primary.sh' stop" \
    '.hooks.Stop[-1] | .matcher == "" and .hooks[0].command == $c and .hooks[0].timeout == 90' \
    "$config" >/dev/null || fail 'secondmate Stop hook missing'
  if jq -e '[.hooks.Stop[].hooks[].command] | any(contains("turn-ended") or contains("--event stop"))' "$config" >/dev/null; then
    fail 'secondmate config carries a busy idle Stop hook or a turn-ended touch'
  fi
  jq -e --arg c "bash '$sm/bin/fm-devin-primary.sh' session-end" \
    '[.hooks.SessionEnd[].hooks[] | select(.command == $c and .timeout == 60)] | length == 1' \
    "$config" >/dev/null || fail 'secondmate SessionEnd wrapper hook missing'
  jq -e '[.hooks.SessionEnd[].hooks[].command] | any(contains("--event session-end"))' "$config" >/dev/null \
    || fail 'secondmate config lost the busy SessionEnd hook'
  jq -e '[.hooks.UserPromptSubmit[].hooks[].command] | any(contains("--event user-prompt-submit"))' "$config" >/dev/null \
    || fail 'secondmate config lost the busy UserPromptSubmit hook'
  qcmd=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "^ask_user_question$") | .hooks[0].command' "$config")
  [ "$(bash -c "$qcmd" | jq -r '.decision')" = block ] || fail 'secondmate PreToolUse does not block ask_user_question'
  [ "$(stat -c %a "$config")" = 600 ] || fail 'secondmate config is not mode 600'

  # Worker mode is unchanged: same busy lifecycle hooks, no secondmate hooks.
  "$ROOT/bin/fm-devin-config.sh" "$state" sm-devin "$gen" "$dir/user.json" || fail 'worker config writer failed'
  jq -e '[.hooks.Stop[].hooks[].command] | any(contains("--event stop") and contains("turn-ended"))' "$config" >/dev/null \
    || fail 'worker config lost the busy Stop hook with the turn-ended touch'
  [ "$(jq '.hooks.SessionStart | length' "$config")" = 1 ] || fail 'worker config gained secondmate SessionStart hooks'
  [ "$(jq 'has("PreToolUse")' "$config")" = false ] || fail 'worker config gained a PreToolUse hook'

  # keep-ai-trailers leaves the source attribution on in secondmate mode too.
  FM_KEEP_AI_TRAILERS=1 "$ROOT/bin/fm-devin-config.sh" --secondmate "$sm" "$state" sm-devin "$gen" "$dir/user.json" \
    || fail 'keep-ai-trailers secondmate config failed'
  [ "$(jq -r '.attribution' "$config")" != false ] || fail 'keep-ai-trailers must not force attribution off'
  [ "$(jq -r '.read_config_from.claude' "$config")" = false ] || fail 'keep-ai-trailers must still disable Claude hook import'
  pass "fm-devin-config --secondmate: shape, no busy Stop, fail-closed SessionStart, question block, user hooks kept"
}

# A devin secondmate spawn on tmux: the launch carries the generated
# secondmate config, the home gets the .fm-busy-stop pointer (git-excluded),
# and the parent's busy record is armed.
seed_sm_home_for_spawn() {  # <home> <id> [wrapper-script]
  local home=$1 id=$2 wrapper=${3:-$ROOT/bin/fm-devin-primary.sh}
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$wrapper" "$home/bin/fm-devin-primary.sh"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter\n' > "$home/data/charter.md"
  fm_git_init_commit "$home" >/dev/null
}

run_sm_spawn() {  # <case-dir> <id> [fm-spawn extra args...]
  local case_dir=$1 id=$2 primary sm fakebin
  shift 2
  primary="$case_dir/primary"
  sm="$case_dir/sm"
  mkdir -p "$case_dir"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" devin zellij)
  fm_test_spawn_home "$primary" devin
  seed_sm_home_for_spawn "$sm" "$id" "${SECONDMATE_WRAPPER:-$ROOT/bin/fm-devin-primary.sh}"
  : > "$case_dir/launch.log"
  FM_BACKEND=tmux FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    fm_test_run_spawn "$primary" "$sm" "$fakebin" "$id" "$sm" --secondmate "$@"
}

test_spawn_secondmate_devin_tmux() {
  local case_dir id=sm-devin-tmux primary sm launch gen config out
  case_dir="$TMP_ROOT/spawn-tmux"
  primary="$case_dir/primary"
  sm="$case_dir/sm"
  out=$(run_sm_spawn "$case_dir" "$id" --harness devin) || fail "devin secondmate spawn failed: $out"
  launch=$(cat "$case_dir/launch.log")
  assert_contains "$launch" "--config '$primary/state/$id.devin-config.json'" 'launch did not use the generated secondmate config'
  assert_contains "$launch" 'env -u CLAUDECODE' 'launch lost the foreign-marker clearing'
  assert_contains "$launch" 'NO_COLOR' 'launch did not clear NO_COLOR'
  assert_contains "$launch" 'encode launch-brief' 'typed launch envelope lost'
  assert_contains "$launch" "FM_HOME='$sm'" 'launch did not pin FM_HOME to the secondmate home'
  config="$primary/state/$id.devin-config.json"
  jq -e --arg c "bash '$sm/bin/fm-devin-primary.sh' session-start" \
    '[.hooks.SessionStart[].hooks[].command] | any(. == $c)' "$config" >/dev/null \
    || fail 'the generated config does not point SessionStart at the mate home'
  gen=$(cat "$primary/state/$id.busy-gen")
  [ -f "$sm/.fm-busy-stop" ] || fail 'the .fm-busy-stop pointer was not written'
  grep -qxF "writer=$ROOT/bin/fm-busy-event.sh" "$sm/.fm-busy-stop" || fail 'pointer writer= wrong'
  grep -qxF "state=$primary/state" "$sm/.fm-busy-stop" || fail 'pointer state= wrong'
  grep -qxF "id=$id" "$sm/.fm-busy-stop" || fail 'pointer id= wrong'
  grep -qxF "gen=$gen" "$sm/.fm-busy-stop" || fail 'pointer gen= wrong'
  if git -C "$sm" status --porcelain | grep -F '.fm-busy-stop' >/dev/null; then
    fail 'the .fm-busy-stop pointer is not git-excluded'
  fi
  [ "$(fm_busy_classify tmux fake:w devin "$id" "$primary/state")" = 'busy fm-spawn' ] || fail 'launch not armed'
  pass "fm-spawn --secondmate --harness devin: launch, generated config, and the git-excluded Stop pointer"
}

test_spawn_secondmate_devin_refusals() {
  local case_dir id=sm-devin-ref out sm
  case_dir="$TMP_ROOT/spawn-refusals"

  if out=$(run_sm_spawn "$case_dir/raw" "$id" 'devin --permission-mode dangerous' 2>&1); then
    fail 'raw devin secondmate launch accepted'
  fi
  assert_contains "$out" 'needs the canonical --harness devin launch' 'wrong raw secondmate refusal'
  [ ! -e "$case_dir/raw/primary/state/$id.busy-gen" ] || fail 'raw refusal still armed a busy gen'
  [ ! -e "$case_dir/raw/sm/.fm-busy-stop" ] || fail 'raw refusal still wrote the pointer'

  if out=$(run_sm_spawn "$case_dir/backend" "$id" --harness devin --backend zellij 2>&1); then
    fail 'devin secondmate launch on a non-tmux/herdr backend accepted'
  fi
  assert_contains "$out" 'quiet daemon is verified only on tmux and Herdr panes' 'wrong backend refusal'
  [ ! -e "$case_dir/backend/primary/state/$id.busy-gen" ] || fail 'backend refusal still armed a busy gen'

  # A home whose fm-devin-primary.sh still lacks .fm-busy-stop support after
  # the pre-launch sync is refused. The fixture's secondmate home is its own
  # unrelated repo, so the sync skips and the check judges the stale copy.
  SECONDMATE_WRAPPER="$case_dir/old-wrapper.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SECONDMATE_WRAPPER"
  chmod +x "$SECONDMATE_WRAPPER"
  if out=$(run_sm_spawn "$case_dir/oldhome" "$id" --harness devin 2>&1); then
    fail 'devin secondmate launch against a stale home accepted'
  fi
  assert_contains "$out" 'still lacks Devin secondmate support after the pre-launch sync' 'wrong stale-home refusal'
  [ ! -e "$case_dir/oldhome/primary/state/$id.busy-gen" ] || fail 'stale-home refusal still armed a busy gen'
  [ ! -e "$case_dir/oldhome/primary/state/$id.devin-config.json" ] || fail 'stale-home refusal still wrote the config'
  [ ! -e "$case_dir/oldhome/sm/.fm-busy-stop" ] || fail 'stale-home refusal still wrote the pointer'
  pass "fm-spawn --secondmate --harness devin: raw, backend, and stale-home refusals provision nothing"
}

test_supports_kind_allows_devin_secondmate() {
  fm_control_harness_supports_kind devin secondmate || fail 'devin secondmate refused by the control plane'
  fm_control_harness_supports_kind devin ship || fail 'devin ship refused by the control plane'
  pass "fm_control_harness_supports_kind allows devin secondmates"
}

test_stop_records_parent_busy_on_block_and_idle_on_allow() {
  local sm pstate gen out
  sm=$(make_sm_home "$TMP_ROOT/stop-rec/sm")
  pstate="$TMP_ROOT/stop-rec/pstate"
  mkdir -p "$pstate"
  gen=$(arm_parent_pointer "$sm" "$pstate" sm-devin)

  # A blocked Stop (stale beacon, work in flight, no daemon) records busy
  # with event stop-blocked under the spawn's gen.
  : > "$sm/state/task1.meta"
  touch -t 202001010000 "$sm/state/.last-watcher-beat"
  out=$(env -u TMUX_PANE \
    FM_HOME="$sm" FM_SUPERVISOR_TARGET=test-pane FM_SUPERVISOR_BACKEND=tmux \
    FM_AFK_LAUNCH_ENTRY=/nonexistent/fm-no-daemon FM_TURNEND_MAX_BLOCKS=3 \
    "$NAMED_DEVIN" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s" "$1" | bash "$0" stop 2>/dev/null
    ' "$sm/bin/fm-devin-primary.sh" '{"prompt_id":"p-block","session_id":"s-1","stop_hook_active":false}')
  assert_contains "$out" '"decision":"block"' "a stop whose self-heal failed did not block: $out"
  assert_grep "state=busy source=devin-hook event=stop-blocked" "$pstate/sm-devin.busy-state" \
    "a blocked Stop did not record busy in the parent record"
  grep -qF "gen=$gen " "$pstate/sm-devin.busy-state" || fail 'the parent record carries the wrong gen'

  # A Stop whose self-heal proves a live daemon allows the turn end and
  # records idle with event stop.
  rm -f "$sm/state/task1.meta"
  out=$(run_owned_stop "$sm" '{"prompt_id":"p-heal","session_id":"s-1","stop_hook_active":false}')
  [ -z "$out" ] || fail "a healed stop blocked: $out"
  assert_grep "state=idle source=devin-hook event=stop" "$pstate/sm-devin.busy-state" \
    "an allowed Stop did not record idle in the parent record"

  # The lock-not-owned early exit records idle the same way.
  rm -f "$sm/state/.lock"
  foreign=$(start_foreign_devin)
  printf '%s\n' "$foreign" > "$sm/state/.lock"
  out=$(env -u TMUX_PANE FM_HOME="$sm" "$NAMED_DEVIN" -c '
    printf "%s" "$1" | bash "$0" stop
  ' "$sm/bin/fm-devin-primary.sh" '{"prompt_id":"p-foreign","session_id":"s-1","stop_hook_active":false}')
  [ -z "$out" ] || fail "a foreign session's stop produced output: $out"
  assert_grep "state=idle source=devin-hook event=stop" "$pstate/sm-devin.busy-state" \
    "the lock-not-owned early exit did not record idle in the parent record"
  pass "fm-devin-primary stop in a secondmate home: busy/stop-blocked on block, idle/stop on allow and on the foreign-lock exit"
}

test_stop_writes_nothing_without_a_pointer() {
  local sm pstate out
  sm=$(make_sm_home "$TMP_ROOT/stop-noptr/sm")
  pstate="$TMP_ROOT/stop-noptr/pstate"
  mkdir -p "$pstate"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$pstate" sm-devin)
  out=$(run_owned_stop "$sm" '{"prompt_id":"p-noptr","session_id":"s-1","stop_hook_active":false}')
  [ -z "$out" ] || fail "a healed stop blocked: $out"
  assert_grep "state=busy source=fm-spawn" "$pstate/sm-devin.busy-state" \
    "a stop without a pointer still wrote the parent record"
  pass "fm-devin-primary stop without .fm-busy-stop leaves the parent record alone"
}

test_session_start_in_secondmate_home() {
  local sm out ctx foreign
  sm=$(make_sm_home "$TMP_ROOT/start/sm")
  out=$(run_hook session-start "$sm" '{"source":"startup"}')
  expect_code 0 "$(run_hook_rc "$sm")" "session-start failed: $(run_hook_err "$sm")"
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
  assert_contains "$ctx" "lock acquired" "session-start context lost the lock report: $ctx"
  assert_contains "$ctx" "quiet daemon running" "session-start context lost the daemon report: $ctx"
  assert_contains "$ctx" "Run bin/fm-session-start.sh now, once." "session-start context lost the digest nudge: $ctx"
  [ -f "$sm/state/.lock" ] || fail 'session-start did not take the home lock'
  pid_alive "$(cat "$sm/state/.supervise-daemon.lock/pid" 2>/dev/null)" \
    || fail 'session-start left no live daemon'
  [ "$(cut -f4 "$sm/state/.afk-daemon-terminal" 2>/dev/null)" = test-pane ] \
    || fail "the daemon record does not name the supervised pane: $(cat "$sm/state/.afk-daemon-terminal" 2>/dev/null)"

  foreign=$(start_foreign_devin)
  sm2=$(make_sm_home "$TMP_ROOT/start-foreign/sm")
  printf '%s\n' "$foreign" > "$sm2/state/.lock"
  out=$(run_hook session-start "$sm2" '{"source":"startup"}')
  assert_contains "$out" '"decision":"block"' "session-start did not block a foreign-held lock: $out"
  assert_contains "$out" "session lock" "session-start block reason did not name the lock: $out"
  [ ! -e "$sm2/state/.afk" ] || fail 'a lock-refused session-start still entered quiet mode'

  sm3=$(make_sm_home "$TMP_ROOT/start-nopane/sm")
  out=$(env -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u FM_SUPERVISOR_TARGET \
    FM_HOME="$sm3" \
    "$NAMED_DEVIN" -c '
      printf "%s" "{\"source\":\"startup\"}" | bash "$0" session-start
    ' "$sm3/bin/fm-devin-primary.sh")
  assert_contains "$out" '"decision":"block"' "session-start did not block a pane-less secondmate launch: $out"
  assert_contains "$out" "this secondmate is not inside a tmux or Herdr pane" \
    "the pane-less block did not use the secondmate reason: $out"
  assert_contains "$out" "bin/fm-spawn.sh --secondmate --harness devin" \
    "the pane-less block did not name the relaunch path: $out"
  [ ! -e "$sm3/state/.lock" ] || fail 'a pane-less session-start still took the session lock'
  pass "fm-devin-primary session-start in a secondmate home: lock, daemon, foreign-lock and secondmate pane-less refusals"
}

test_session_start_replaces_a_dead_pane_daemon() {
  local sm old new out
  sm=$(make_sm_home "$TMP_ROOT/start-stale/sm")
  old=$(start_earlier_daemon "$sm" dead-pane)
  pid_alive "$old" || fail 'the earlier daemon is not running'
  out=$(env -u TMUX_PANE FM_HOME="$sm" FM_SUPERVISOR_TARGET=pane-b FM_SUPERVISOR_BACKEND=tmux \
    FM_AFK_LAUNCH_ENTRY="$STUB_DAEMON" \
    "$NAMED_DEVIN" -c '
      printf "%s" "{\"source\":\"startup\"}" | bash "$0" session-start
    ' "$sm/bin/fm-devin-primary.sh")
  assert_not_contains "$out" '"decision":"block"' "session-start refused the relaunch: $out"
  ! pid_alive "$old" || fail 'the daemon supervising the dead pane is still running'
  new=$(cat "$sm/state/.supervise-daemon.lock/pid" 2>/dev/null)
  if [ -z "$new" ] || [ "$new" = "$old" ] || ! pid_alive "$new"; then
    fail "the relaunch did not leave a fresh live daemon (old $old, new ${new:-none})"
  fi
  [ "$(cut -f4 "$sm/state/.afk-daemon-terminal" 2>/dev/null)" = pane-b ] \
    || fail "the fresh daemon's record does not name pane-b: $(cat "$sm/state/.afk-daemon-terminal" 2>/dev/null)"
  pass "fm-devin-primary session-start relaunch: a daemon recorded for a dead pane is replaced by one for the new pane"
}

test_config_secondmate_shape
test_spawn_secondmate_devin_tmux
test_spawn_secondmate_devin_refusals
test_supports_kind_allows_devin_secondmate
test_stop_records_parent_busy_on_block_and_idle_on_allow
test_stop_writes_nothing_without_a_pointer
test_session_start_in_secondmate_home
test_session_start_replaces_a_dead_pane_daemon
