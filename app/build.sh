#!/bin/bash
# Compile "VPN Rotate.app" à côté de ce dossier
set -e
cd "$(dirname "$0")/.."
APP="VPN Rotate.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Optimisé pour la taille : modules compilés ensemble, code inutilisé et symboles retirés
xcrun swiftc -parse-as-library -Osize -wmo -Xlinker -dead_strip -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  app/App.swift app/Model.swift app/Stats.swift app/Circuit.swift app/WorldMap.swift -o "$APP/Contents/MacOS/VPNRotation"
xcrun strip -rSTx "$APP/Contents/MacOS/VPNRotation" 2>/dev/null
cp app/AppIcon.icns app/countries.bin "$APP/Contents/Resources/"
cp app/install.sh app/control.sh app/rotate.sh app/net.sh app/stats.sh "$APP/Contents/Resources/"

# WireGuard est embarqué : rien à installer sur le Mac qui reçoit l'application
BREW="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
WG="$APP/Contents/Resources/wireguard"
mkdir -p "$WG/bin" "$WG/lib"
for tool in bash wg wg-quick wireguard-go; do
  [ -x "$BREW/bin/$tool" ] || { echo "Manquant : brew install wireguard-tools bash" >&2; exit 1; }
  cp -L "$BREW/bin/$tool" "$WG/bin/$tool"
  chmod 755 "$WG/bin/$tool"
done
# Les bibliothèques de bash sont copiées à côté de lui
for dep in $(otool -L "$WG/bin/bash" | awk -v b="$BREW/" 'index($1, b) == 1 { print $1 }'); do
  name="$(basename "$dep")"
  cp -L "$dep" "$WG/lib/$name"
  chmod 644 "$WG/lib/$name"
  install_name_tool -id "@executable_path/../lib/$name" "$WG/lib/$name" 2>/dev/null
  install_name_tool -change "$dep" "@executable_path/../lib/$name" "$WG/bin/bash" 2>/dev/null
done
for file in "$WG"/lib/* "$WG/bin/bash" "$WG/bin/wg" "$WG/bin/wireguard-go"; do
  if otool -L "$file" | tail -n +2 | grep -q "$BREW/"; then
    echo "Dépendance non embarquée : $file" >&2
    exit 1
  fi
  codesign --force --sign - "$file" 2>/dev/null
done
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>VPN Rotate</string>
  <key>CFBundleDisplayName</key><string>VPN Rotate</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>local.vpnrotate.app</string>
  <key>CFBundleExecutable</key><string>VPNRotation</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
EOF
codesign --force --sign - "$APP"
echo "Créée : $PWD/$APP"
