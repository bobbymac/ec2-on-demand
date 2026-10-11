#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT
mkdir "$temp_dir/bin" "$temp_dir/state"
ln -s "$repo_dir/tests/fake-crontab" "$temp_dir/bin/crontab"
export PATH="$temp_dir/bin:$PATH"
export XDG_STATE_HOME="$temp_dir/state"
export FAKE_CRONTAB_FILE="$temp_dir/crontab"

"$repo_dir/scripts/install-cron" --profile test >/dev/null
"$repo_dir/scripts/install-cron" --profile test >/dev/null

[[ $(grep -c '^CRON_TZ=America/Chicago$' "$FAKE_CRONTAB_FILE") == 1 ]]
[[ $(grep -c '^# ec2-on-demand weekly maintenance$' "$FAKE_CRONTAB_FILE") == 1 ]]
grep -q '^0 3 \* \* 6 .* --profile '\''test'\'' maintain ' "$FAKE_CRONTAB_FILE"
printf 'PASS: cron installation is correctly scheduled and idempotent\n'
