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
    tar -czf "$project_root/artifacts/BiliDownloader-web-ui.tar.gz" -C build/web .
    if [[ "$(uname -s)" == Linux ]]; then
      dart build cli -t bin/web_server.dart -o build/web_service
      mkdir -p build/web_service/bundle/web
      cp -R build/web/. build/web_service/bundle/web/
      cp "$project_root/scripts/run_web_service.sh" build/web_service/bundle/run.sh
      cp "$project_root/docs/web-service.md" build/web_service/bundle/README.md
      chmod +x build/web_service/bundle/run.sh
      tar -czf "$project_root/artifacts/BiliDownloader-web-service-linux-x64.tar.gz" -C build/web_service/bundle .
    fi
    ;;
  *) printf 'Usage: %s {linux|android|web}\n' "$0" >&2; exit 2 ;;
esac
