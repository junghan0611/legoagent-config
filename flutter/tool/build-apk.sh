#!/usr/bin/env bash
# Run inside the Flutter dev shell; embed this build's actual metadata.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

version=$(awk '/^version:[[:space:]]/ { print $2; exit }' pubspec.yaml)
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$ ]]; then
	printf 'Invalid or missing pubspec version: %s\n' "$version" >&2
	exit 2
fi
build_time=$(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S KST')
if [[ $# -eq 0 ]]; then
	set -- --debug
fi
printf 'Building legoagent %s (%s)\n' "$version" "$build_time"
flutter build apk "$@" \
	--dart-define="APP_VERSION=$version" \
	--dart-define="BUILD_TIME=$build_time"
