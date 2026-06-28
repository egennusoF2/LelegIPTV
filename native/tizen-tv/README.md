# Leleg IPTV per Samsung Tizen TV

Applicazione TV web nativa per Samsung Smart TV (Tizen 6.0+), separata dal
vecchio runtime Flutter e allineata all'app Android TV in `native/android-tv/`.

## Stack

- TypeScript + Vite
- HTML/CSS (design token condivisi con Android TV)
- Samsung **AVPlay** per live e VOD
- IndexedDB/localStorage per profili e cache catalogo
- Focus manager esplicito per telecomando Samsung

## Vertical slice (v0.1)

- Profilo Xtream con preset (ITALIA1, MONDO1, …)
- Home + menu laterale (stesse voci dell'app Android TV)
- Live TV: categorie, lista canali, anteprima, EPG breve
- Film: categorie on-demand con caricamento per categoria (no OOM)
- Player fullscreen AVPlay con play/pausa e cambio canale ← →
- Browser dev: fallback `<video>` HTML5 quando AVPlay non è presente

## Sviluppo locale

```bash
cd native/tizen-tv
npm install
npm run dev
```

Apri l'URL Vite nel browser e usa le frecce + Invio.

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
tizen install -n LelegIPTV-tizen-tv-release.wgt -t IP_TV:26101
```

## App id

- Package: `com.lelegiptv.tizen`
- Application: `com.lelegiptv.tizen.LelegIPTV`

## Prossimi passi

- Serie, preferiti, ricerca, guida TV completa
- IndexedDB per cache catalogo grande
- Test su TV Samsung reale con Web Inspector
- Sostituire il vecchio `.tpk` Flutter nel download center
