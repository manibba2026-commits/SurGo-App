#!/bin/bash

git clone https://github.com/flutter/flutter.git --depth 1 -b stable "$HOME/flutter"

export PATH="$HOME/flutter/bin:$PATH"

flutter config --enable-web
flutter pub get
# Hosted reads go through Supabase so RLS, not the seed, decides what a signed-in
# account can see. Local development keeps the mock default.
flutter build web --release --dart-define=SURGO_DATA_SOURCE=supabase