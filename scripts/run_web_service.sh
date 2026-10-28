#!/bin/sh
set -eu
service_root="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
export BILI_WEB_ROOT="${BILI_WEB_ROOT:-$service_root/web}"
export BILI_DOWNLOAD_ROOT="${BILI_DOWNLOAD_ROOT:-$service_root/downloads}"
exec "$service_root/bin/web_server"
