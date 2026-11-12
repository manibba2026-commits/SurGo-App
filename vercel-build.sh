#!/bin/bash

git clone https://github.com/flutter/flutter.git --depth 1 -b stable "$HOME/flutter"

export PATH="$HOME/flutter/bin:$PATH"

flutter config --enable-web
flutter pub get
# Hosted reads go through Supabase so RLS, not the seed, decides what a signed-in
# account can see. Local development keeps the mock default.
# MAPTILER_API_KEY is a Vercel project environment variable; an empty value
# falls back to the labelled offline map instead of failing the build.
flutter build web --release \
  --dart-define=SURGO_DATA_SOURCE=supabase \
  --dart-define=MAPTILER_API_KEY="${MAPTILER_API_KEY:-}"