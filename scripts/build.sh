#!/bin/zsh
# Build de distribuição do Tradutor.
#
# Uso:
#   scripts/build.sh            build Release assinado ad-hoc (só para este Mac)
#   scripts/build.sh --release  Developer ID + notarização + DMG (para distribuir)
#
# Variáveis para --release:
#   DEVELOPMENT_TEAM   ID da equipa (10 caracteres), ex.: ABCDE12345
#   NOTARY_PROFILE     perfil criado com `xcrun notarytool store-credentials` (por defeito: tradutor-notary)
#
# Resultado em build/dist/.
set -euo pipefail

cd "$(dirname "$0")/.."
MODE=${1:-adhoc}
DIST=build/dist
ARCHIVE=build/Tradutor.xcarchive
NOTARY_PROFILE=${NOTARY_PROFILE:-tradutor-notary}
VERSION=$(grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"(.*)".*/\1/')

step() { print -P "%F{cyan}==>%f $1" }

command -v xcodegen >/dev/null || { echo "Falta o XcodeGen: brew install xcodegen"; exit 1 }
step "A gerar o projeto"
xcodegen generate --quiet

rm -rf "$ARCHIVE" "$DIST"
mkdir -p "$DIST"

case "$MODE" in
  adhoc)
    step "Archive (Release, assinatura ad-hoc)"
    xcodebuild archive -quiet \
      -project Tradutor.xcodeproj -scheme Tradutor -configuration Release -destination "generic/platform=macOS" \
      -archivePath "$ARCHIVE"
    ditto "$ARCHIVE/Products/Applications/Tradutor.app" "$DIST/Tradutor.app"
    step "Pronto: $DIST/Tradutor.app (só funciona neste Mac; o Gatekeeper bloqueia-a noutros)"
    ;;

  --release)
    : "${DEVELOPMENT_TEAM:?Define DEVELOPMENT_TEAM com o ID da tua equipa}"

    step "Archive (Release, Developer ID, Hardened Runtime)"
    # --timestamp: a notarização exige assinaturas com carimbo de tempo seguro.
    xcodebuild archive -quiet \
      -project Tradutor.xcodeproj -scheme Tradutor -configuration Release -destination "generic/platform=macOS" \
      -archivePath "$ARCHIVE" \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY="Developer ID Application" \
      DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
      OTHER_CODE_SIGN_FLAGS="--timestamp"

    step "Exportar com Developer ID"
    EXPORT_OPTIONS=$(mktemp -t ExportOptions).plist
    cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>teamID</key><string>$DEVELOPMENT_TEAM</string>
</dict>
</plist>
PLIST
    xcodebuild -exportArchive -quiet \
      -archivePath "$ARCHIVE" -exportOptionsPlist "$EXPORT_OPTIONS" -exportPath "$DIST"

    step "Verificar a assinatura"
    codesign --verify --deep --strict --verbose=2 "$DIST/Tradutor.app"

    step "Notarizar a app"
    ditto -c -k --keepParent "$DIST/Tradutor.app" "$DIST/Tradutor.zip"
    xcrun notarytool submit "$DIST/Tradutor.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DIST/Tradutor.app"
    rm "$DIST/Tradutor.zip"

    step "Criar, assinar e notarizar o DMG"
    DMG="$DIST/Tradutor-$VERSION.dmg"
    STAGING=$(mktemp -d)
    ditto "$DIST/Tradutor.app" "$STAGING/Tradutor.app"
    ln -s /Applications "$STAGING/Applications"
    hdiutil create -quiet -volname "Tradutor" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
    rm -rf "$STAGING"
    codesign --sign "Developer ID Application" --timestamp "$DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"

    step "Confirmar que o Gatekeeper aceita"
    spctl --assess --type execute --verbose "$DIST/Tradutor.app"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG"

    step "Pronto: $DMG"
    ;;

  *)
    echo "Uso: $0 [--release]"; exit 1 ;;
esac
