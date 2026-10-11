#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT
mkdir "$temp_dir/bin" "$temp_dir/state"
ln -s "$repo_dir/tests/fake-aws" "$temp_dir/bin/aws"
state_file="$temp_dir/state/aws-state"
log_file="$temp_dir/state/aws.log"
: >"$log_file"
config="$temp_dir/config"
cat >"$config" <<'EOF'
AWS_REGION=us-east-2
INSTANCE_ID=i-test
SSH_USER=ubuntu
TAILSCALE_HOST=test.example
SUPPORTED_INSTANCE_TYPES=(t3.medium)
START_TIMEOUT=1
SSM_TIMEOUT=1
PATCH_TIMEOUT=1
REBOOT_TIMEOUT=1
STOP_TIMEOUT=1
FORCE_STOP_TIMEOUT=1
POLL_INTERVAL=0
EOF

export PATH="$temp_dir/bin:$PATH"
export EC2CTL_CONFIG="$config"
export XDG_STATE_HOME="$temp_dir/state"
export FAKE_AWS_STATE_FILE="$state_file"
export FAKE_AWS_LOG_FILE="$log_file"
cli="$repo_dir/bin/ec2ctl"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { [[ $1 == *"$2"* ]] || fail "expected output to contain: $2"; }

printf 'running' >"$state_file"
output=$($cli status)
assert_contains "$output" 'State: running'
assert_contains "$output" 'Systems Manager: Online'
assert_contains "$output" 'no local result available'

output=$($cli sizes)
assert_contains "$output" 't3.medium'
assert_contains "$output" '* current'

output=$($cli start)
assert_contains "$output" 'already running'
assert_contains "$output" 'tailscale ssh ubuntu@test.example'

if $cli start --choose --instance-type t3.medium >/dev/null 2>&1; then fail 'conflicting start flags succeeded'; fi
if $cli start --choose </dev/null >/dev/null 2>&1; then fail 'noninteractive size menu succeeded'; fi
if $cli start --instance-type m9.invalid >/dev/null 2>&1; then fail 'running resize succeeded'; fi

printf 'stopped' >"$state_file"
output=$($cli start)
assert_contains "$output" 'EC2 state: running'
[[ $(<"$state_file") == running ]] || fail 'start did not transition fake state'

output=$($cli stop)
assert_contains "$output" 'EC2 state: stopped'
[[ $(<"$state_file") == stopped ]] || fail 'stop did not transition fake state'

printf 'running' >"$state_file"
export FAKE_NORMAL_STOP_STUCK=1
output=$($cli stop 2>&1)
assert_contains "$output" 'requesting forced stop'
[[ $(<"$state_file") == stopped ]] || fail 'forced stop did not transition fake state'
unset FAKE_NORMAL_STOP_STUCK

output=$($cli cost-audit)
assert_contains "$output" 'vol-test'
assert_contains "$output" 'eipalloc-test'

printf 'running' >"$state_file"
output=$($cli maintain)
assert_contains "$output" 'Maintenance result: success'
[[ $(<"$state_file") == stopped ]] || fail 'maintenance cleanup did not stop instance'
record="$XDG_STATE_HOME/ec2ctl/last-maintenance"
[[ -f $record ]] || fail 'maintenance record was not written'
grep -q '^update_outcome=success$' "$record" || fail 'maintenance update result missing'
grep -q '^shutdown_outcome=success$' "$record" || fail 'maintenance shutdown result missing'

printf 'running' >"$state_file"
export FAKE_PATCH_FAIL=1
if $cli maintain >/dev/null 2>&1; then fail 'failed patch run reported success'; fi
unset FAKE_PATCH_FAIL
[[ $(<"$state_file") == stopped ]] || fail 'failed maintenance did not stop instance'
grep -q '^update_outcome=failure$' "$record" || fail 'failed update result missing'
grep -q '^shutdown_outcome=success$' "$record" || fail 'failed maintenance cleanup result missing'

exec 8>"$XDG_STATE_HOME/ec2ctl/maintenance.lock"
flock -n 8
if $cli maintain >/dev/null 2>&1; then fail 'concurrent maintenance succeeded'; fi
flock -u 8

printf 'PASS: CLI lifecycle, validation, maintenance cleanup, status, and cost audit\n'
