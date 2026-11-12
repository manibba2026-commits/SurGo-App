# SurGo Map Tiles — Configuration Guide

SurGo renders **MapTiler Dataviz Dark** vector tiles through MapLibre
(`package:maplibre`), with SurGo's own purple pins, route lines and
safe-area-aware overlays on top.

- Style: `https://api.maptiler.com/maps/dataviz-dark/style.json`
- Attribution: **© MapTiler · © OpenStreetMap contributors** (always shown)
- The key is injected at **compile time** through `--dart-define`. It is never
  read from source, never committed, and never stored at runtime.

Without `MAPTILER_API_KEY`, every `SurgoMap` shows a labelled dark offline
grid. The app never falls back to unrestricted `tile.openstreetmap.org`.

## Local builds

Keep the key in a JSON file **outside the repository** so no build command
leaks it into shell history:

`C:\Users\NITRO\.surgo-secrets\dart_defines.json`

```json
{ "MAPTILER_API_KEY": "<key>" }
```

```bash
# Web (mock data, no Supabase reads)
flutter build web --no-pub \
  --dart-define-from-file=C:/Users/NITRO/.surgo-secrets/dart_defines.json \
  --dart-define=SURGO_DEMO_AUTH=true \
  --dart-define=SURGO_DATA_SOURCE=mock

# Web (hosted reads)
flutter build web --release \
  --dart-define-from-file=C:/Users/NITRO/.surgo-secrets/dart_defines.json \
  --dart-define=SURGO_DATA_SOURCE=supabase

# Android
flutter build apk --release \
  --dart-define-from-file=C:/Users/NITRO/.surgo-secrets/dart_defines.json
flutter build appbundle --release \
  --dart-define-from-file=C:/Users/NITRO/.surgo-secrets/dart_defines.json
```

`dart_defines.local.json` in the project root is also ignored by git if you
prefer a repo-local file; the copy in `.surgo-secrets` is preferred.

In Android Studio / IntelliJ, put the same flag in **Run/Debug Configurations
→ Additional run args**. In VS Code, use
`"args": ["--dart-define-from-file=${env:HOME}/.surgo-secrets/dart_defines.json"]`.

A helper script wraps both platforms:

```bash
tools/build_app.sh web
tools/build_app.sh apk
tools/build_app.sh run
```

It reads `SURGO_DEFINES_FILE` if set, otherwise the JSON file above.

## Production (Vercel)

`vercel-build.sh` forwards `MAPTILER_API_KEY` into the Flutter build:

```bash
flutter build web --release \
  --dart-define=SURGO_DATA_SOURCE=supabase \
  --dart-define=MAPTILER_API_KEY="${MAPTILER_API_KEY:-}"
```

Set `MAPTILER_API_KEY` as a **Vercel project environment variable**
(Production + Preview). It is never written to the repository. A missing value
builds successfully and shows the offline map.

## Restrict the key in MapTiler Cloud

A browser key is visible in network requests, so restriction is the real
control. In [cloud.maptiler.com](https://cloud.maptiler.com) → Account → API
keys → edit:

- **Web:** allow only `localhost` and the production domain
  (`sur-go-flutter-app-main.vercel.app` and any custom domain).
- **Android/iOS:** restrict by bundle/package id (`com.example.surgo` for the
  current app id).
- If the provider does not offer a restriction that fits, rotate the key rather
  than shipping an unrestricted one.

## Verification

1. Build with a key and open the app; the map must show real streets and
   labels, not the "Offline map preview" grid.
2. In DevTools → Network, requests go to `api.maptiler.com` and return `200`.
3. A plain build without the key still shows the labelled offline grid.
4. Run the map widget tests:

```bash
flutter test test/surgo_map_test.dart test/passenger_map_screen_test.dart
```
