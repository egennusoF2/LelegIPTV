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

La pagina download viene pubblicata dal deploy Oracle/Docker. La web app resta
nelle route applicative (`/login`, `/livetv`, `/movies`, `/series`, `/epg`,
ecc.).

## Download center per deploy web

```bash
pnpm build:pages
node scripts/prepare-download-center.mjs
```

Lo script:

- copia `docs/installazione-dispositivi.html` in `dist/index.html`;
- copia in `dist/downloads/current/` solo gli artefatti sotto 50 MB;
- riscrive i link locali `../www/downloads/current/` in link web
  `downloads/current/`;
- aggiunge il link alla web app su `/login`.

Gli artefatti installabili (`.apk`, `.ipa`, `.dmg`, `.zip`, `.tpk`) non sono
tracciati in Git. Per Oracle, dove possiamo servire anche file grandi:

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

## Android smartphone, tablet, Android TV

```bash
cd native/flutter/leleg_iptv
flutter build apk --release
```

Output:

```text
native/flutter/leleg_iptv/build/app/outputs/flutter-apk/app-release.apk
```

Copia consigliata:

```bash
cp native/flutter/leleg_iptv/build/app/outputs/flutter-apk/app-release.apk \
  www/downloads/current/LelegIPTV-android-universal-release.apk
```

Nota operativa:

- `www/downloads/current/LelegIPTV-android-universal-release.apk` e' il file
  pubblicato dalla download center. Evitare copie versionate parallele: in
  passato hanno creato confusione tra build vecchie e nuove.
- Su Android smartphone/tablet il download offline e' demandato al
  `DownloadManager` di sistema: per la validazione manuale bisogna verificare
  la notifica Android oltre alla sezione `Download` dell'app.

## iOS unsigned IPA per Scarlet / Sideloadly / AltStore

```bash
cd native/flutter/leleg_iptv
flutter config --no-enable-swift-package-manager
flutter build ios --release --no-codesign
bash ../../../scripts/package-flutter-ios-unsigned-ipa.sh
```

Output:

```text
www/downloads/current/LelegIPTV-ios-unsigned.ipa
```

L'IPA non e' firmata. Scarlet/Sideloadly/AltStore/Xcode applicano la firma
personale al momento dell'installazione. La pagina pubblica deve linkare
direttamente `LelegIPTV-ios-unsigned.ipa` e spiegare l'import da Scarlet senza
mostrare questi comandi di build.

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

Tizen deve partire dalla app Flutter nativa, non dalla build web Astro.
Il formato corretto per Samsung TV in developer mode e' un pacchetto `.tpk`.

Toolchain locale:

```bash
git clone https://github.com/flutter-tizen/flutter-tizen.git tools/flutter-tizen
tools/flutter-tizen/bin/flutter-tizen doctor -v
```

Se `doctor` segnala una rootstrap mancante, installa il pacchetto richiesto dal
Tizen Package Manager. Su questo Mac sono serviti i profili headed 6.0 e 6.5:

```bash
/Users/emanuelegennuso/tizen-studio/package-manager/package-manager-cli.bin \
  install IOT-Headed-6.0-NativeAppDevelopment-CLI
/Users/emanuelegennuso/tizen-studio/package-manager/package-manager-cli.bin \
  install IOT-Headed-6.5-NativeAppDevelopment-CLI
```

Generazione e build del TPK Flutter:

```bash
cd native/flutter/leleg_iptv
TIZEN_SDK="$HOME/tizen-studio" \
  ../../../tools/flutter-tizen/bin/flutter-tizen create .
TIZEN_SDK="$HOME/tizen-studio" \
  ../../../tools/flutter-tizen/bin/flutter-tizen pub get
TIZEN_SDK="$HOME/tizen-studio" \
  ../../../tools/flutter-tizen/bin/flutter-tizen build tpk --device-profile tv
cp build/tizen/tpk/com.lelegiptv.leleg_iptv-1.0.0.tpk \
  ../../../www/downloads/current/LelegIPTV-tizen-tv-release.tpk
```

Installazione su TV collegata:

```bash
sdb connect IP_DELLA_TV:26101
TIZEN_SDK="$HOME/tizen-studio" \
  tools/flutter-tizen/bin/flutter-tizen run -d IP_DELLA_TV:26101 --release
```

Nota player: il TPK usa il backend Samsung AVPlay tramite
`video_player_avplay`. Il codice Flutter tiene separato Tizen da `media_kit`:
su Tizen vengono saltati `MediaKit.ensureInitialized()` e la creazione del
player `media_kit`, per evitare il crash da `libmpv` assente su Samsung TV.
Il manifest Tizen usa `api-version="6.5"` e privilegi media storage,
external storage e internet.

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
