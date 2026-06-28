# Leleg IPTV per Android TV e Fire TV

Applicazione TV nativa separata dalle versioni Flutter mobile e desktop.

## Stack

- Kotlin
- Jetpack Compose for TV
- Android Media3 ExoPlayer
- Player hardware del dispositivo

## Package

Durante la migrazione usa il package `com.lelegiptv.tv`, quindi puo essere
installata accanto alla precedente build TV Flutter.

## Emulatore Android TV (Mac)

L'AVD TV spesso arriva con `hw.keyboard=no`: la tastiera del Mac non passa
all'emulatore. Dopo un **cold boot** con tastiera abilitata, clicca dentro la
finestra emulatore e usa frecce + Invio come D-pad.

Se i comandi non arrivano comunque, controlla l'emulatore dal terminale:

```bash
chmod +x scripts/tv-emulator-remote.sh

# Modalità telecomando interattiva (frecce + invio nel terminale)
./scripts/tv-emulator-remote.sh interactive

# Comandi singoli
./scripts/tv-emulator-remote.sh down
./scripts/tv-emulator-remote.sh ok
./scripts/tv-emulator-remote.sh back
./scripts/tv-emulator-remote.sh text ITALIA2
```

In Android Studio: **Emulator → Settings → General** → disattiva
*"Send keyboard shortcuts to device"* se le frecce muovono i pannelli
dell'emulatore invece dell'app.

## Build

```bash
cd native/android-tv
./gradlew assembleRelease
```

APK:

```text
app/build/outputs/apk/release/app-release.apk
```

La build release locale e attualmente firmata con la chiave debug per consentire
il test diretto. Prima della distribuzione pubblica deve essere configurata una
chiave release stabile.

## Installazione Fire TV

```bash
adb connect IP_FIRE_TV:5555
adb -s IP_FIRE_TV:5555 install -r \
  app/build/outputs/apk/release/app-release.apk
adb -s IP_FIRE_TV:5555 shell am start \
  -n com.lelegiptv.tv/.MainActivity
```

## Vertical slice verificato

Il 27 giugno 2026 e stato verificato su Fire TV reale:

- avvio app;
- inserimento codice lista con telecomando;
- caricamento di 6.161 canali;
- navigazione menu, categorie e canali con D-pad;
- apertura player full screen;
- decodifica hardware H.264;
- video e audio;
- ritorno alla lista con Back.

La versione 0.3 aggiunge:

- cache locale del catalogo valida 24 ore;
- riapertura immediata del catalogo senza una nuova richiesta al provider;
- EPG breve normalizzato per il canale in riproduzione;
- pannello EPG contestuale nella pagina Live;
- programma corrente persistente nel player fullscreen;
- overlay player TV a scomparsa;
- play e pausa;
- timeline e seek per contenuti VOD;
- selezione nativa delle tracce audio;
- selezione e disattivazione dei sottotitoli;
- stato esplicito quando il flusso non espone tracce audio o sottotitoli;
- cambio canale precedente/successivo con D-pad nel player live;
- stato di buffering ed errori visibili.
- cataloghi Film e Serie con cache giornaliera;
- ricerca globale TV;
- dettagli di film, serie e stagioni;
- griglia poster ottimizzata per D-pad;
- Guida TV navigabile e centrata sul programma corrente;
- riproduzione dell'archivio Xtream;
- conferma di uscita dalla home.

## Confini

Questo modulo non deve importare codice UI o player da Flutter. I contratti
Xtream possono essere replicati, ma focus, navigazione e riproduzione rimangono
nativi.
