#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
target="${1:-linux}"
cd "$project_root/flutter_app"
flutter pub get --enforce-lockfile
mkdir -p "$project_root/artifacts"
case "$target" in
  linux)
    flutter build linux --release
    tar -czf "$project_root/artifacts/BiliDownloader-linux-x64.tar.gz" -C build/linux/x64/release/bundle .
    ;;
  android)
    flutter build apk --release --split-per-abi
    cp build/app/outputs/flutter-apk/app-*-release.apk "$project_root/artifacts/"
    ;;
  web)
    flutter build web --release --no-web-resources-cdn
    tar -czf "$project_root/artifacts/BiliDownloader-web-preview.tar.gz" -C build/web .
    ;;
  *) printf 'Usage: %s {linux|android|web}\n' "$0" >&2; exit 2 ;;
esac
