#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/home"
export TEST_LOG="$tmp_dir/log"
export PATH="$tmp_dir/bin:$PATH"
export HOME="$tmp_dir/home"

for stub in omarchy-launch-webapp omarchy-launch-floating-terminal-with-presentation; do
  cat >"$tmp_dir/bin/$stub" <<SCRIPT
#!/bin/bash
printf '$stub:%s\n' "\$*" >>"\$TEST_LOG"
SCRIPT
  chmod +x "$tmp_dir/bin/$stub"
done

# The retry loop sleeps between polls; a no-op keeps the suite fast.
printf '#!/bin/bash\n' >"$tmp_dir/bin/sleep"
chmod +x "$tmp_dir/bin/sleep"

# A machine that never onboarded gets the wizard, not a dashboard probe.
"$ROOT/bin/omarchy-launch-openclaw"

grep -q '^omarchy-launch-floating-terminal-with-presentation:.*openclaw onboard' "$TEST_LOG" ||
  fail "OpenClaw launch hands a never-onboarded machine to the wizard"
! grep -q '^omarchy-launch-webapp:' "$TEST_LOG" ||
  fail "OpenClaw launch hands a never-onboarded machine to the wizard" "webapp opened anyway"
pass "OpenClaw launch hands a never-onboarded machine to the wizard"

mkdir -p "$HOME/.openclaw"
touch "$HOME/.openclaw/openclaw.json"

# A running gateway answers the first probe; its handoff URL opens as the app.
cat >"$tmp_dir/bin/openclaw" <<'SCRIPT'
#!/bin/bash
printf 'openclaw:%s\n' "$*" >>"$TEST_LOG"
[[ $* == *--json* ]] &&
  echo '{"ok":true,"url":"http://127.0.0.1:18789/?token=shared","browserUrl":"http://127.0.0.1:18789/#handoff"}'
SCRIPT
chmod +x "$tmp_dir/bin/openclaw"
"$ROOT/bin/omarchy-launch-openclaw"

grep -q '^omarchy-launch-webapp:http://127.0.0.1:18789/#handoff$' "$TEST_LOG" ||
  fail "OpenClaw launch opens the running gateway's handoff URL"
pass "OpenClaw launch opens the running gateway's handoff URL"

# A machine whose gateway unit was never installed gets `gateway install`,
# then is polled until the dashboard answers. Never `dashboard --yes`: since
# 2026.9.1 that neither installs nor starts anything and, once the gateway is
# up, pushes a one-time pairing URL into the clipboard.
cat >"$tmp_dir/bin/openclaw" <<SCRIPT
#!/bin/bash
printf 'openclaw:%s\n' "\$*" >>"\$TEST_LOG"
if [[ \$* == *--json* ]]; then
  [[ -f $tmp_dir/gateway-up ]] || { echo '{"ok":false,"reason":"Gateway is not running."}'; exit 1; }
  echo '{"ok":true,"browserUrl":"http://127.0.0.1:18789/#cold-start"}'
elif [[ \$1 == gateway ]]; then
  touch "$tmp_dir/gateway-up"
fi
SCRIPT
chmod +x "$tmp_dir/bin/openclaw"
rm -f "$tmp_dir/gateway-up"
: >"$TEST_LOG"
"$ROOT/bin/omarchy-launch-openclaw"

grep -q '^openclaw:gateway install$' "$TEST_LOG" ||
  fail "OpenClaw launch installs a never-installed gateway before opening the app"
! grep -q '^openclaw:gateway start$' "$TEST_LOG" ||
  fail "OpenClaw launch installs a never-installed gateway before opening the app" "started instead of installing"
grep -q '^omarchy-launch-webapp:http://127.0.0.1:18789/#cold-start$' "$TEST_LOG" ||
  fail "OpenClaw launch installs a never-installed gateway before opening the app" "webapp never opened"
pass "OpenClaw launch installs a never-installed gateway before opening the app"

# An installed but stopped unit is started, not reinstalled.
mkdir -p "$HOME/.config/systemd/user"
touch "$HOME/.config/systemd/user/openclaw-gateway.service"
rm -f "$tmp_dir/gateway-up"
: >"$TEST_LOG"
"$ROOT/bin/omarchy-launch-openclaw"

grep -q '^openclaw:gateway start$' "$TEST_LOG" ||
  fail "OpenClaw launch starts a stopped gateway before opening the app"
! grep -q '^openclaw:gateway install$' "$TEST_LOG" ||
  fail "OpenClaw launch starts a stopped gateway before opening the app" "reinstalled the unit"
! grep -q -- '--yes' "$TEST_LOG" ||
  fail "OpenClaw launch starts a stopped gateway before opening the app" "fell back to dashboard --yes"
grep -q '^omarchy-launch-webapp:http://127.0.0.1:18789/#cold-start$' "$TEST_LOG" ||
  fail "OpenClaw launch starts a stopped gateway before opening the app" "webapp never opened"
pass "OpenClaw launch starts a stopped gateway before opening the app"
rm -f "$HOME/.config/systemd/user/openclaw-gateway.service"

# A gateway that never answers fails the launch instead of opening a dead page.
cat >"$tmp_dir/bin/openclaw" <<'SCRIPT'
#!/bin/bash
printf 'openclaw:%s\n' "$*" >>"$TEST_LOG"
[[ $* == *--json* ]] && exit 1
exit 0
SCRIPT
chmod +x "$tmp_dir/bin/openclaw"
webapp_calls_before=$(grep -c '^omarchy-launch-webapp:' "$TEST_LOG" || true)
rc=0
"$ROOT/bin/omarchy-launch-openclaw" >/dev/null 2>&1 || rc=$?
webapp_calls_after=$(grep -c '^omarchy-launch-webapp:' "$TEST_LOG" || true)

[[ $rc != 0 ]] || fail "OpenClaw launch fails cleanly when the gateway never comes up"
[[ $webapp_calls_before == "$webapp_calls_after" ]] ||
  fail "OpenClaw launch fails cleanly when the gateway never comes up" "webapp opened anyway"
pass "OpenClaw launch fails cleanly when the gateway never comes up"

# --tui runs onboarding in the terminal it is already in, then attaches to the
# gateway with `openclaw tui` -- never the embedded chat, which the running
# gateway's state-directory lock would refuse.
rm -f "$HOME/.openclaw/openclaw.json"
cat >"$tmp_dir/bin/openclaw" <<SCRIPT
#!/bin/bash
printf 'openclaw:%s\n' "\$*" >>"\$TEST_LOG"
case \$1 in
onboard) mkdir -p "\$HOME/.openclaw" && touch "\$HOME/.openclaw/openclaw.json" ;;
dashboard) [[ \$* == *--json* ]] && echo '{"ok":true,"browserUrl":"http://127.0.0.1:18789/#tui"}' ;;
esac
SCRIPT
chmod +x "$tmp_dir/bin/openclaw"
floating_calls_before=$(grep -c '^omarchy-launch-floating-terminal-with-presentation:' "$TEST_LOG" || true)
"$ROOT/bin/omarchy-launch-openclaw" --tui

grep -q '^openclaw:onboard$' "$TEST_LOG" || fail "--tui onboards in the current terminal"
floating_calls_after=$(grep -c '^omarchy-launch-floating-terminal-with-presentation:' "$TEST_LOG" || true)
[[ $floating_calls_before == "$floating_calls_after" ]] ||
  fail "--tui onboards in the current terminal" "spawned a floating terminal"
grep -q '^openclaw:tui$' "$TEST_LOG" || fail "--tui attaches to the gateway"
pass "--tui onboards in place and attaches to the gateway"

: >"$TEST_LOG"
"$ROOT/bin/omarchy-launch-openclaw" --tui --message "Review this project"
grep -q '^openclaw:tui --message Review this project$' "$TEST_LOG" ||
  fail "--tui seeds the session through --message"
! grep -q '^omarchy-launch-webapp:' "$TEST_LOG" ||
  fail "--tui seeds the session through --message" "webapp opened instead"
pass "--tui seeds the session through --message"
