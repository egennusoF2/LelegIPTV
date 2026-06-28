# Decisione architetturale per le applicazioni TV

Data: 2026-06-27

## Decisione

Le applicazioni TV non continueranno a condividere il runtime Flutter usato dalle
app mobile e desktop.

- Android TV, Google TV, Chromecast con Google TV e Fire TV: applicazione nativa
  Kotlin con Jetpack Compose for TV e Media3 ExoPlayer.
- Samsung TV Tizen: applicazione Tizen Web in TypeScript/HTML/CSS con Samsung
  AVPlay.
- Mobile e desktop: restano sull'implementazione Flutter attuale.
- Web/PWA: resta sull'implementazione web attuale.

La parita tra le piattaforme verra mantenuta tramite specifiche UX, design token,
modelli dati e test di accettazione comuni, non tramite un unico renderer UI o
un unico player multipiattaforma.

## Perche Flutter non e adatto a questo ramo TV

Flutter supporta Android come piattaforma generale, ma non offre un framework TV
ufficiale equivalente a Compose for TV. Tizen non compare tra le piattaforme di
deploy supportate dal team Flutter ed e fornito da un port separato.

Nel progetto attuale:

- `lib/main.dart` supera le 13.000 righe;
- focus, navigazione, schermate, catalogo e player sono accoppiati;
- Android TV intercetta i tasti sia nel layer Kotlin sia nel layer Flutter;
- convivono `media_kit`, `video_player` e `video_player_avplay`;
- Tizen passa attraverso un wrapper Flutter prima di raggiungere AVPlay;
- le liste molto grandi vengono renderizzate e navigate in un albero Flutter
  nato anche per touch, con costi e stati di focus difficili da prevedere.

Questo spiega i sintomi ripetuti: focus perso, Back incoerente, liste lente o in
crash, player con solo audio, tracce non selezionabili e comportamenti diversi
tra emulatore e dispositivo.

## Android TV e Fire TV

### Stack

- Kotlin
- Jetpack Compose for TV
- Navigation Compose
- Media3 ExoPlayer e `PlayerView`
- MediaSession
- DataStore per profili e preferenze
- Room per cache catalogo, EPG, preferiti e cronologia
- WorkManager per aggiornamenti differiti

### Player

Media3 gestisce direttamente:

- HLS, DASH e file progressivi supportati dal dispositivo;
- superficie video hardware;
- timeline, seek, buffering e stato;
- sottotitoli;
- enumerazione e selezione delle tracce audio e testo;
- MediaSession e tasti multimediali.

Per Fire TV si mantiene un modulo player sostituibile, così da poter usare la
variante ExoPlayer raccomandata da Amazon quando necessaria senza duplicare la UI.

### Navigazione

Ogni schermata deve avere:

- un solo proprietario del focus;
- gruppi di focus espliciti per menu, filtri, righe e player;
- destinazioni `up/down/left/right` deterministiche nei passaggi tra zone;
- focus iniziale e focus restaurato per ogni rotta;
- LazyRow/LazyColumn con chiavi stabili;
- Back gestito dallo stack di navigazione; conferma uscita solo alla radice.

Non devono esistere un dispatcher Kotlin e un dispatcher UI che elaborano lo
stesso evento D-pad.

## Samsung Tizen

### Stack

- Tizen Web Application
- TypeScript
- HTML/CSS ottimizzati per 1920x1080
- Samsung AVPlay
- router e focus manager applicativi leggeri
- IndexedDB per cache e profili

### Player

AVPlay viene usato direttamente per:

- `open`, `prepareAsync`, `play`, `pause`, `seekTo`;
- `setDisplayRect` e modalita full screen;
- buffering e callback di errore;
- `getTotalTrackInfo`;
- `setSelectTrack("AUDIO", index)`;
- `setSelectTrack("TEXT", index)`;
- sottotitoli embedded ed esterni supportati.

Il video non deve passare da un widget Flutter o da una texture intermedia.

### Navigazione

Il focus manager mantiene un grafo esplicito di elementi per schermata. I tasti
obbligatori `ArrowLeft`, `ArrowRight`, `ArrowUp`, `ArrowDown`, `Enter` e `Back`
sono gestiti tramite `keydown`; i tasti media aggiuntivi sono registrati con
`tvinputdevice.registerKeyBatch`.

## Componenti condivisi

Le due app TV condividono come specifica, non come UI runtime:

- contratti Xtream e normalizzazione delle risposte;
- regole per URL live, VOD, serie e catch-up;
- mapping EPG e disponibilita archivio;
- design token: colori, spaziature, tipografia e stati focus;
- struttura delle rotte;
- fixture JSON anonimizzate;
- test di accettazione.

Se utile, i contratti di rete possono essere descritti in JSON Schema e generare
modelli Kotlin e TypeScript.

## Piano di migrazione

1. Congelare il flavor Flutter TV senza eliminarlo.
2. Estrarre fixture e contratti dal client Xtream esistente.
3. Costruire un vertical slice Android TV:
   profilo -> categorie live -> canali -> player -> tracce -> Back.
4. Verificarlo su emulatore Android TV e Fire Stick reale.
5. Aggiungere film, serie, ricerca, EPG, catch-up e preferiti.
6. Costruire lo stesso vertical slice Tizen Web con AVPlay.
7. Verificarlo su TV Samsung reale con Web Inspector.
8. Solo dopo la parita funzionale, sostituire gli artefatti TV Flutter.

## Criteri di accettazione del vertical slice

- caricamento iniziale visibile e input bloccato fino allo stato pronto;
- focus sempre visibile;
- nessuna zona irraggiungibile col solo telecomando;
- Back deterministico;
- lista di almeno 20.000 elementi senza caricamento integrale in memoria UI;
- avvio live e VOD;
- video e audio entrambi presenti;
- seek VOD;
- cambio traccia audio;
- attivazione/disattivazione sottotitoli;
- toolbar full screen navigabile;
- cambio canale e EPG contestuale;
- nessun crash o ANR in una sessione di navigazione rapida di 15 minuti.

## Riferimenti ufficiali

- Flutter supported platforms:
  https://docs.flutter.dev/reference/supported-platforms
- Android Compose for TV:
  https://developer.android.com/training/tv/playback/compose
- Android TV navigation:
  https://developer.android.com/training/tv/get-started/navigation
- Media3 track selection:
  https://developer.android.com/media/media3/exoplayer/track-selection
- Media3 PlayerView:
  https://developer.android.com/media/media3/ui/playerview
- Amazon Fire TV media players:
  https://developer.amazon.com/docs/fire-tv/media-players.html
- Amazon Fire TV remote input:
  https://developer.amazon.com/docs/fire-tv/ja-remote-input.html
- Samsung AVPlay:
  https://developer.samsung.com/smarttv/develop/api-references/samsung-product-api-references/avplay-api.html
- Samsung AVPlay guide:
  https://developer.samsung.com/smarttv/develop/guides/multimedia/media-playback/using-avplay.html
- Samsung remote control:
  https://developer.samsung.com/smarttv/develop/guides/user-interaction/remote-control.html
