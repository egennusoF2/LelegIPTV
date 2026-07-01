# Leleg IPTV per Samsung Tizen TV

Applicazione TV web nativa per Samsung Smart TV (Tizen 6.0+), separata dal
vecchio runtime Flutter e allineata all'app Android TV in `native/android-tv/`.

## Stack

- TypeScript + Vite
- HTML/CSS (design token condivisi con Android TV)
- Samsung **AVPlay** per live e VOD
- IndexedDB/localStorage per profili e cache catalogo
- Focus manager esplicito per telecomando Samsung

## Funzionalita

- Profilo Xtream con compilazione automatica tramite codice lista digitato nel
  campo nome; i codici non sono mostrati nell'interfaccia
- Home e menu laterale ottimizzati per telecomando
- Live TV: categorie, lista canali, anteprima e guida contestuale centrata sul
  programma in onda, con tre eventi precedenti e tre successivi
- Film e serie: categorie verticali e griglia poster navigabile come Android TV,
  caricata progressivamente per mantenere fluida la TV anche con cataloghi molto
  grandi; schede dettaglio, stagioni ed episodi
- Ricerca globale, preferiti e guida TV giornaliera con canali e programmi
  navigabili da telecomando
- Live registrati tramite catch-up Xtream, accessibili sia dalla guida generale
  sia dall'EPG contestuale
- Player fullscreen AVPlay con seek, velocita, audio e sottotitoli
- Il fullscreen live mostra il programma EPG corrente; audio e sottotitoli
  vengono riletti da AVPlay dopo l'avvio e possono essere cambiati dalla toolbar
- I dettagli film vengono completati tramite `get_vod_info`, così trama,
  valutazione e data non dipendono dai dati ridotti del catalogo
- Ripresa VOD allineata ad Android TV: posizione salvata ogni 5 secondi,
  `Riprendi` dopo 15 secondi, `Ricomincia`, completamento al 92%, avanzamento
  sugli episodi e fascia `Continua a guardare` nella Home
- Cache locale del catalogo e indicatore di caricamento
- Browser dev: fallback `<video>` HTML5 quando AVPlay non è presente

La guida unisce `get_short_epg` con `get_simple_data_table` (e il fallback
`get_simple_date_table`), elimina i duplicati e conserva la finestra di archivio
indicata dal canale. Il solo `get_short_epg` non è sufficiente per mostrare i
programmi precedenti.

## Comandi telecomando

- Frecce: spostamento spaziale tra gli elementi
- `OK`: selezione o apertura della barra del player
- `Back`: chiude prima la barra/player/dettaglio, poi torna alla schermata precedente
- Live fullscreen: `Su/Giu` cambia canale
- Barra player: play/pausa, -10/+10 secondi, audio, sottotitoli, velocita e chiusura

## Sviluppo locale

```bash
cd native/tizen-tv
npm install
npm run dev
```

Apri l'URL Vite nel browser e usa le frecce + Invio.

## Test senza televisore

Il Samsung TV Web Simulator installato con Tizen Studio consente di verificare
layout, focus e telecomando:

```bash
open -na "$HOME/tizen-studio/tools/sec-tv-simulator/nwjs.app" --args \
  --platform tv --tizentvversion 10.0 --resolution 1920x1080 \
  --file "$PWD/dist/index.html"
```

Il simulatore web non riproduce fedelmente il piano hardware AVPlay, i codec e
le differenze tra modelli. La riproduzione finale va quindi confermata su una
TV Samsung reale. L'emulatore firmware x86_64 non puo essere avviato sui Mac
Apple Silicon perche richiede virtualizzazione x86 hardware.

## Build e pacchetto WGT

```bash
pnpm tizen-tv:build
```

Con Tizen Studio installato e certificato configurato:

```bash
cd native/tizen-tv
TIZEN_CERT_PROFILE=<profilo> npm run package:wgt
```

Pubblica negli artefatti download del sito:

```bash
pnpm tizen-tv:publish
```

Output: `www/downloads/current/LelegIPTV-tizen-tv-release.wgt`

## Installazione su TV Samsung

```bash
sdb connect IP_TV:26101
tizen install -n LelegIPTV-tizen-tv-release.wgt -t NOME_TARGET_TIZEN
```

## App id

- Package: `LelegIPTV1`
- Application: `LelegIPTV1.LelegIPTVTv`

## Architettura

Questa app non usa Flutter. Sulle TV Samsung la riproduzione passa direttamente
dal piano video hardware di AVPlay; l'interfaccia HTML resta sopra il video.
L'ordine di inizializzazione e `open -> listener/proprieta -> prepareAsync ->
play` deve essere mantenuto, cosi come la configurazione degli header nello
stato `IDLE`.

Riferimenti Samsung:

- [Riproduzione con AVPlay](https://developer.samsung.com/smarttv/develop/guides/multimedia/media-playback/using-avplay.html)
- [API AVPlay](https://developer.samsung.com/smarttv/develop/api-references/samsung-product-api-references/avplay-api.html)
- [API TVInputDevice](https://developer.samsung.com/smarttv/develop/api-references/tizen-web-device-api-references/tvinputdevice-api.html)
- [Telecomando Samsung](https://developer.samsung.com/smarttv/develop/guides/user-interaction/remote-control.html)
