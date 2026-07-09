# Build degli artefatti LelegIPTV

Questa pagina e' per chi deve rigenerare gli artefatti. La pagina pubblica
`docs/installazione-dispositivi.html` deve restare orientata agli utenti:
download, installazione e autorizzazioni dispositivo.

## Prerequisiti comuni

- Flutter stable configurato.
- Repository aggiornato.
- Per Tizen: Node/pnpm e Tizen Studio.
- Per Android: Android SDK e licenze accettate.
- Per iOS/macOS: Xcode installato.

## Web app

```bash
pnpm install
pnpm build:pages
```

La pagina download viene pubblicata dal deploy Oracle/Docker su
`https://lelegiptv.ddns.net/`. La web app resta nelle route applicative
(`/home`, `/login`, `/livetv`, `/movies`, `/series`, `/epg`, ecc.).

## Download center per deploy web

```bash
pnpm build:pages
node scripts/prepare-download-center.mjs
```

Lo script:

- copia `www/index.html` in `dist/index.html`;
- copia in `dist/downloads/current/` solo gli artefatti sotto 50 MB;
- riscrive i link locali `../www/downloads/current/` in link web
  `downloads/current/`;
- aggiunge il link alla web app su `/home`.

Gli artefatti installabili (`.apk`, `.ipa`, `.dmg`, `.zip`, `.tpk`) non sono
tracciati in Git. Per Oracle/Caddy, dove possiamo servire anche file grandi:

```bash
ALLOW_LARGE_DOWNLOADS=1 pnpm download-center:prepare
```

`deploy-remote.sh` usa automaticamente questa modalita'.

## macOS

```bash
cd native/flutter/leleg_iptv
flutter config --no-enable-swift-package-manager
flutter build macos --release
```

Packaging locale:

```bash
codesign --force --deep --sign - www/downloads/current/LelegIPTV.app
ditto -c -k --keepParent www/downloads/current/LelegIPTV.app \
  www/downloads/current/LelegIPTV-macos-arm64-release.zip
hdiutil create -volname LelegIPTV \
  -srcfolder www/downloads/current/LelegIPTV.app \
  -ov -format UDZO \
  www/downloads/current/LelegIPTV-macos-arm64-release.dmg
```

## Android smartphone e tablet

```bash
cd native/flutter/leleg_iptv
flutter build apk --release --flavor mobile
```

Output:

```text
native/flutter/leleg_iptv/build/app/outputs/flutter-apk/app-release.apk
```

Copia consigliata:

```bash
bash scripts/package-flutter-android-apks.sh
```

Oppure manualmente:

```bash
cd native/flutter/leleg_iptv
flutter build apk --release --flavor mobile
flutter build apk --release --flavor tv --dart-define=LELEG_ANDROID_TV=true
cp build/app/outputs/flutter-apk/app-mobile-release.apk \
  ../../../www/downloads/current/LelegIPTV-android-universal-release.apk
cp build/app/outputs/flutter-apk/app-tv-release.apk \
  ../../../www/downloads/current/LelegIPTV-android-tv-release.apk
```

Nota operativa:

- `LelegIPTV-android-universal-release.apk` e' il flavor **mobile** (telefono/tablet).
- `LelegIPTV-android-tv-release.apk` e' il flavor **tv**: launcher solo Leanback,
- Evitare copie versionate parallele: in passato hanno creato confusione tra
  build vecchie e nuove.
- Su Android smartphone/tablet il download offline e' demandato al
  `DownloadManager` di sistema: per la validazione manuale bisogna verificare
  la notifica Android oltre alla sezione `Download` dell'app.

## Android TV, Google TV, Chromecast e Fire TV

La versione TV non deriva più dal flavor Flutter. È un'app nativa separata
basata su Kotlin, Compose for TV e Media3:

```bash
bash scripts/package-native-android-tv.sh
```

Output:

```text
www/downloads/current/LelegIPTV-android-tv-release.apk
```

## iOS / iPadOS TestFlight

```bash
APPLE_TEAM_ID=PD57DH2235 bash scripts/package-ios-testflight-ipa.sh
```

Output:

```text
www/downloads/current/LelegIPTV-ios-testflight.ipa
```

L'IPA e' firmata per App Store Connect/TestFlight. Prima build una tantum:
crea l'app su App Store Connect con bundle ID `it.emanuelegennuso.lelegiptv`, imposta
il team `PD57DH2235` in Xcode e lascia il provisioning automatico attivo.

Upload:

```bash
export ASC_API_KEY="ABC123DEFG"
export ASC_API_ISSUER="00000000-0000-0000-0000-000000000000"
export ASC_API_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_ABC123DEFG.p8"
bash scripts/upload-ios-testflight.sh
```

Guida completa: `docs/TESTFLIGHT_DISTRIBUTION.md`.

## iOS TestFlight

```bash
APPLE_TEAM_ID=PD57DH2235 bash scripts/package-ios-testflight-ipa.sh
bash scripts/upload-ios-testflight.sh
```

Output:

```text
www/downloads/current/LelegIPTV-ios-testflight.ipa
```

Il canale di distribuzione per iPhone/iPad e' TestFlight tramite App Store
Connect. Configura una API key o una app-specific password prima dell'upload.

Runtime iOS:

- il player usa `media_kit` anche su iPhone/iPad per mantenere selezione tracce
  audio e sottotitoli;
- i download offline passano dal canale nativo
  `com.lelegiptv.native/storage` e da `URLSessionConfiguration.background`,
  con header `Referer`/`User-Agent`, progressi inviati a Flutter e continuita'
  quando il telefono va in lock o l'app passa in background;
- i file salvati finiscono in `Documents/LelegIPTV`, visibili nell'app File
  grazie a `UIFileSharingEnabled` e `LSSupportsOpeningDocumentsInPlace`.

## Samsung Tizen TV

Tizen usa l'app TV TypeScript dedicata in `native/tizen-tv`, separata sia dalla
web app Astro sia dall'app Flutter condivisa.
Il formato corretto per Samsung TV in developer mode e' un pacchetto `.wgt`.

Toolchain locale:

```bash
export PATH="$HOME/tizen-studio/tools:$PATH"
tizen version
sdb version
```

Build e firma:

```bash
cd native/tizen-tv
npm install
npm run build
npm run package:wgt
```

Installazione su TV collegata:

```bash
sdb connect IP_DELLA_TV:26101
tizen install -n "$PWD/build/LelegIPTV-tizen-tv.wgt" -t NOME_DEVICE
tizen run -p LelegIPTV1.LelegIPTVTv -t NOME_DEVICE
```

Il pacchetto firmato viene copiato automaticamente in:

`www/downloads/current/LelegIPTV-tizen-tv-release.wgt`.

Il fullscreen usa Samsung AVPlay; l'anteprima Live usa il player HTML5/HLS per
evitare i limiti di compositing del piano video hardware nei riquadri HTML.

## Windows da Parallels o GitHub Actions

### Windows x64 da GitHub Actions

Per PC Windows Intel/AMD usa la CI, perche' da Parallels su Apple Silicon si
ottiene normalmente una build Windows ARM64. Avvia il workflow GitHub Actions
`Flutter installable artifacts` e scarica l'artifact:

```text
LelegIPTV-windows-x64-release.zip
```

La action produce uno zip gia' installabile/eseguibile con tutti i DLL accanto
all'eseguibile Flutter. Se lanciata manualmente (`workflow_dispatch`), aggiorna
anche la release GitHub `native-latest`; la pagina pubblica punta a:

```text
https://github.com/egennusoF2/LelegIPTV/releases/latest/download/LelegIPTV-windows-x64-release.zip
```

### Windows ARM64 da Parallels Apple Silicon

Non compilare dalla share Parallels `X:` o da un path UNC (`\\Mac\...`): Flutter
deve creare symlink dei plugin in `windows/flutter/ephemeral/.plugin_symlinks`
e la share Parallels puo' fallire con `ERROR_INVALID_FUNCTION`.

Copia prima il progetto su disco locale Windows, compila da `C:\dev`, poi copia
lo zip finale nella cartella download del repository su Mac:

```powershell
robocopy X:\PROGETTI\MIEI\LelegIPTV C:\dev\LelegIPTV /MIR `
  /XD .git node_modules dist .tmp native\flutter\leleg_iptv\build `
  /R:2 /W:2

cd C:\dev\LelegIPTV\native\flutter\leleg_iptv
C:\dev\flutter\bin\flutter.bat config --enable-windows-desktop
C:\dev\flutter\bin\flutter.bat pub get
C:\dev\flutter\bin\flutter.bat build windows --release

Compress-Archive -Path "build\windows\arm64\runner\Release\*" `
  -DestinationPath "C:\dev\LelegIPTV-windows-arm64-release.zip" `
  -Force

Copy-Item "C:\dev\LelegIPTV-windows-arm64-release.zip" `
  "X:\PROGETTI\MIEI\LelegIPTV\www\downloads\current\LelegIPTV-windows-arm64-release.zip" `
  -Force
```

Se il percorso `arm64` non esiste, cerca l'eseguibile generato:

```powershell
Get-ChildItem build\windows -Recurse -Filter *.exe
```

Output attesi:

```text
www/downloads/current/LelegIPTV-windows-x64-release.zip
www/downloads/current/LelegIPTV-windows-arm64-release.zip (solo se generato localmente)
```

## Linux

Da Linux o CI Linux:

```bash
sudo apt-get update
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev libmpv-dev
cd native/flutter/leleg_iptv
flutter config --enable-linux-desktop
flutter pub get
flutter build linux --release
tar -C build/linux/x64/release/bundle -czf \
  ../../../www/downloads/current/LelegIPTV-linux-x64-release.tar.gz .
```

## Rigenerare hash

```bash
find www/downloads/current -maxdepth 1 -type f ! -name SHA256SUMS.txt -print0 \
  | xargs -0 shasum -a 256 > www/downloads/current/SHA256SUMS.txt
shasum -a 256 -c www/downloads/current/SHA256SUMS.txt
```
