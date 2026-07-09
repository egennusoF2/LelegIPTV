# Distribuzione iOS con TestFlight

Questa e' la procedura consigliata per distribuire Leleg IPTV su iPhone e iPad
tramite Apple Developer Program. macOS resta distribuito come `.dmg` esterno.

## Prerequisiti una tantum

1. In Apple Developer, verifica che esista l'App ID
   `it.emanuelegennuso.lelegiptv`.
2. In App Store Connect, crea l'app iOS/iPadOS con:
   - nome: `Leleg IPTV`
   - bundle ID: `it.emanuelegennuso.lelegiptv`
   - SKU libero, ad esempio `leleg-iptv-ios`
3. In Xcode, apri `Settings > Accounts` e accedi con il team Apple Developer
   `PD57DH2235`.
4. Se non esiste ancora un certificato `Apple Distribution`, lascia che Xcode lo
   crei automaticamente: apri `native/flutter/leleg_iptv/ios/Runner.xcworkspace`,
   seleziona `Runner`, abilita `Automatically manage signing` e imposta il team.

Verifica locale:

```bash
security find-identity -v -p codesigning | grep -E "Apple Distribution|iOS Distribution"
```

Se non stampa nulla, il Mac puo' compilare in sviluppo ma non puo' esportare IPA
per TestFlight.

## Build IPA firmata per TestFlight

Dal root del repository:

```bash
APPLE_TEAM_ID=PD57DH2235 bash scripts/package-ios-testflight-ipa.sh
```

Lo script:

- compila Flutter in release;
- crea un archivio iOS firmato con provisioning automatico;
- esporta un IPA `app-store-connect`;
- copia il risultato in
  `www/downloads/current/LelegIPTV-ios-testflight.ipa`;
- aggiorna `www/downloads/current/SHA256SUMS.txt`.

Per forzare versione e build number:

```bash
BUILD_NAME=1.0.20 BUILD_NUMBER=2026070801 \
APPLE_TEAM_ID=PD57DH2235 \
bash scripts/package-ios-testflight-ipa.sh
```

`BUILD_NUMBER` deve essere sempre crescente per App Store Connect.

## Upload su App Store Connect

Metodo consigliato: API key App Store Connect.

```bash
export ASC_API_KEY="ABC123DEFG"
export ASC_API_ISSUER="00000000-0000-0000-0000-000000000000"
export ASC_API_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_ABC123DEFG.p8"
bash scripts/upload-ios-testflight.sh
```

Alternativa con Apple ID e password specifica per app:

```bash
export APPLE_ID="email@example.com"
export APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx"
bash scripts/upload-ios-testflight.sh
```

Dopo l'upload, entra in App Store Connect, attendi la fase di processing, poi
aggiungi tester interni o esterni nella sezione TestFlight.

## Errori comuni

### `No signing certificate "iOS Distribution" found`

Sul Mac non e' installato un certificato Distribution con chiave privata. Apri:

```text
Xcode > Settings > Accounts > Team > Manage Certificates > + > Apple Distribution
```

Poi rilancia:

```bash
APPLE_TEAM_ID=PD57DH2235 bash scripts/package-ios-testflight-ipa.sh
```

### `Team ... does not have permission to create "iOS App Store" provisioning profiles`

L'Apple ID usato da Xcode non ha permesso di creare profili App Store, oppure
mancano contratti/termini da accettare. Risolvi da:

- Apple Developer > Certificates, Identifiers & Profiles;
- App Store Connect > Users and Access;
- App Store Connect > Agreements, Tax, and Banking.

L'utente deve essere Account Holder/Admin oppure avere accesso esplicito a
Certificates, Identifiers & Profiles.

## Fallback sideload

`www/downloads/current/LelegIPTV-ios-unsigned.ipa` resta disponibile per Scarlet,
Sideloadly, AltStore o installazioni manuali. Non e' il canale consigliato ora
che l'account Developer e' attivo.
