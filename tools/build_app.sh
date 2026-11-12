#!/usr/bin/env bash
# Builds SurGo with the MapTiler key from a file outside the repository, so the
# key never appears in shell history or in a committed file.
#
#   tools/build_app.sh web
#   tools/build_app.sh apk
#   tools/build_app.sh appbundle
#   tools/build_app.sh run
#
# Override the file with SURGO_DEFINES_FILE=/path/to/dart_defines.json.
set -euo pipefail

defines="${SURGO_DEFINES_FILE:-$HOME/.surgo-secrets/dart_defines.json}"
if [ ! -f "$defines" ]; then
  echo "Missing $defines — see docs/MAP_TILES.md" >&2
  exit 1
fi
if command -v cygpath >/dev/null 2>&1; then
  defines="$(cygpath -w "$defines")"
fi

target="${1:-web}"
shift || true

case "$target" in
  web)
    exec flutter build web --release \
      --dart-define-from-file="$defines" \
      --dart-define=SURGO_DATA_SOURCE=supabase "$@"
    ;;
  apk)
    exec flutter build apk --release --dart-define-from-file="$defines" "$@"
    ;;
  appbundle)
    exec flutter build appbundle --release --dart-define-from-file="$defines" "$@"
    ;;
  run)
    exec flutter run --dart-define-from-file="$defines" "$@"
    ;;
  *)
    echo "Usage: tools/build_app.sh [web|apk|appbundle|run] [extra flutter args]" >&2
    exit 2
    ;;
esac
