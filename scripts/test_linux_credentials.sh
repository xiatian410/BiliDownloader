#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d -t bili-keyring-test.XXXXXXXX)"
trap 'rm -rf -- "$test_dir"' EXIT
mkdir -m 700 "$test_dir/config" "$test_dir/data" "$test_dir/cache" "$test_dir/runtime"
export XDG_CONFIG_HOME="$test_dir/config"
export XDG_DATA_HOME="$test_dir/data"
export XDG_CACHE_HOME="$test_dir/cache"
export XDG_RUNTIME_DIR="$test_dir/runtime"
unset GNOME_KEYRING_CONTROL GNOME_KEYRING_PID
cd "$project_root/flutter_app"
xvfb-run -a dbus-run-session -- bash -eu -o pipefail -c '
  printf "integration-only\n" | gnome-keyring-daemon --unlock --components=secrets
  flutter test integration_test/credentials_test.dart -d linux --dart-define=BILI_ISOLATED_KEYRING=true
'
