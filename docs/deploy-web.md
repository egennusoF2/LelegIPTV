# Deploy web app (PWA) — Cloudflare Pages

Hosting pubblico HTTPS gratuito per **Leleg IPTV** (browser + PWA + streaming).

## Perché Cloudflare Pages

| | Cloudflare Pages | Netlify (free) |
|---|---|---|
| **Prezzo** | Gratis | Gratis |
| **Banda** | **Illimitata** | 100 GB/mese |
| **CDN** | Global, molto veloce | Buono |
| **Proxy IPTV** | Pages Function `/__stream` | Edge function |
| **PWA / HTTPS** | Sì | Sì |

Per un player IPTV con proxy HLS, **Cloudflare è la scelta migliore** (banda illimitata).

---

## Setup rapido (5 min)

### 1. Account Cloudflare

1. [dash.cloudflare.com/sign-up](https://dash.cloudflare.com/sign-up) (gratis).
2. **Workers & Pages** → **Create** → **Pages** → **Connect to Git**.
3. Autorizza GitHub → seleziona **`egennusoF2/LelegIPTV`**.

### 2. Impostazioni build

**Se vedi due campi (Build + Deploy)** — Workers & Pages → Builds:

| Campo | Valore |
|-------|--------|
| **Build command** | `pnpm build:pages` |
| **Deploy command** | `pnpm deploy:pages` |

**Se vedi solo Build command** — Pages Git classico:

| Campo | Valore |
|-------|--------|
| **Production branch** | `main` |
| **Build command** | `pnpm build:pages` |
| **Build output directory** | `dist` |
| **Root directory** | `/` (default) |

Cloudflare rileva **pnpm** da `pnpm-lock.yaml`.

### 3. Variabili d'ambiente (Build)

Opzionale se usi `pnpm build:pages` (imposta già `PUBLIC_WEB_STREAM_PROXY=true`).

In **Settings → Environment variables** → **Production** (solo se usi `pnpm build` senza `:pages`):

| Nome | Valore |
|------|--------|
| `PUBLIC_WEB_STREAM_PROXY` | `true` |
| `NODE_VERSION` | `22` |

### 4. Deploy

Clic **Save and Deploy**. Al termine avrai un URL tipo:

`https://leleg-iptv.pages.dev`

Puoi cambiare il nome del progetto in **Settings → General → Project name**.

### 5. Dominio custom (opzionale)

**Custom domains** → **Set up a custom domain** → segui i passi DNS.

---

## Cosa fa il repo

| File | Ruolo |
|------|--------|
| [`wrangler.toml`](../wrangler.toml) | Config Pages + env |
| [`functions/__stream.ts`](../functions/__stream.ts) | Proxy IPTV (HLS, CORS, User-Agent) |
| [`public/_headers`](../public/_headers) | Cache service worker / manifest PWA |
| [`.github/workflows/web-deploy.yml`](../.github/workflows/web-deploy.yml) | Deploy automatico (opzionale) |

Ogni push su `main` ridistribuisce se usi l’integrazione Git di Cloudflare **oppure** il workflow GitHub (sotto).

---

## Deploy automatico via GitHub Actions (opzionale)

Se preferisci il deploy da Actions invece del hook Git di Cloudflare:

1. Cloudflare → **My Profile → API Tokens** → **Create Token** → template **Edit Cloudflare Workers**.
2. Permessi: **Account → Cloudflare Pages → Edit**.
3. Copia **Account ID** da Overview (colonna destra).
4. GitHub repo → **Settings → Secrets → Actions**:
   - `CLOUDFLARE_API_TOKEN`
   - `CLOUDFLARE_ACCOUNT_ID`

Senza secret, il workflow esegue comunque test + build.

---

## Deploy manuale da terminale

```bash
pnpm install -g wrangler   # oppure usa pnpm exec wrangler
wrangler login
pnpm deploy:web            # build + deploy
# oppure, se Cloudflare fa già la build:
pnpm deploy:pages          # solo upload dist/ + functions/
```

Oppure manualmente:

```bash
pnpm build:pages
pnpm deploy:pages
```

---

## Dopo il deploy

- Apri l’URL `*.pages.dev` → login playlist → live TV / VOD
- **PWA:** Impostazioni → *Installa web app*
- **iPhone:** Safari → Condividi → *Aggiungi a Home*
- **Chrome Mac:** menu ⋮ → *Installa pagina come app*

---

## Note

- **Non usare** `http://192.168.x.x` per installare la PWA: serve HTTPS o localhost.
- Le app **Tauri** (desktop/mobile) restano su [GitHub Releases](https://github.com/egennusoF2/LelegIPTV/releases).
- La cartella `docs/` usa GitHub Pages separato — non confonderlo con la web app.
