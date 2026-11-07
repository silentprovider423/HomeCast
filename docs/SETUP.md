# Setup guide: from IPA to your podcasts

HomeCast is only the app. Your subscriptions, playback positions, saved episodes and queue live on your own **PinePods server**, so you need one of those first. If you already run PinePods, skip to step 3.

## What you need

- An iPhone with **iOS 26 or newer**
- A computer that runs all the time (NAS, mini PC, home server, old laptop) with **Docker**
- A free Apple ID for sideloading

## 1. Set up PinePods

Official docs: <https://www.pinepods.online/docs/tutorial-basics/docker-compose>

Short version – create a folder, put this `compose.yml` into it and a `.env` file with `DB_PASSWORD=<a long random password>` next to it:

```yaml
name: pinepods
services:
  db:
    image: postgres:18
    environment:
      POSTGRES_DB: pinepods_database
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      PGDATA: /var/lib/pgdata/pgdata
    volumes:
      - ./pgdata:/var/lib/pgdata
    restart: unless-stopped
  valkey:
    image: valkey/valkey:8-alpine
    restart: unless-stopped
  pinepods:
    image: madeofpendletonwool/pinepods:0.9.2
    ports:
      - "8040:8040"
    environment:
      SEARCH_API_URL: "https://search.pinepods.online/api/search"
      PEOPLE_API_URL: "https://people.pinepods.online"
      HOSTNAME: "http://<server-ip>:8040"
      DB_TYPE: postgresql
      DB_HOST: db
      DB_PORT: 5432
      DB_USER: postgres
      DB_PASSWORD: ${DB_PASSWORD}
      DB_NAME: pinepods_database
      VALKEY_HOST: valkey
      VALKEY_PORT: 6379
      TZ: "Europe/Berlin"
    volumes:
      - ./downloads:/opt/pinepods/downloads
      - ./backups:/opt/pinepods/backups
    restart: unless-stopped
    depends_on: [db, valkey]
```

```bash
docker compose up -d
curl http://localhost:8040/api/health     # {"status":"healthy",...}
```

HomeCast is tested with PinePods **0.9.2**. Newer versions usually work, older ones may not.

## 2. Create your account

1. Open `http://<server-ip>:8040` in a browser.
2. The first user you create is the admin. You can use that account in the app, or create a normal user under *Settings → User Management*.
3. Optional: import your existing subscriptions as OPML (*Settings → Import*). You can also simply follow shows from the app.

PinePods refreshes all feeds on the server on a schedule, so new episodes appear even when the app is closed.

## 3. Make the server reachable from the iPhone

| Where | Address to use in the app | Works away from home |
|---|---|---|
| Home Wi-Fi only | `http://192.168.x.y:8040` | no |
| VPN (Tailscale, WireGuard) | `http://100.x.y.z:8040` (Tailscale IP) or your WireGuard IP | yes, with VPN on |
| Public with HTTPS (reverse proxy, Cloudflare Tunnel) | `https://podcasts.example.com` | yes |

Important:

- iOS blocks plain `http://` to public domain names. A public address **must** use HTTPS with a normal certificate (e.g. Let's Encrypt).
- Type `http://` in front of IP addresses. Without it the app tries `http://` for numeric addresses and `https://` for names.
- Audio is streamed directly from the podcast's own servers (like Apple Podcasts does), not through PinePods.

## 4. Install the IPA

1. Install [SideStore](https://sidestore.io) (no computer needed later) or [AltStore](https://altstore.io) (needs AltServer on your computer) and sign in with your Apple ID.
2. Build the IPA with `./build-ipa.sh` on a Mac (or download it from a release, if one is published).
3. Open it with SideStore/AltStore ("Share" → SideStore, or the **+** button in My Apps).
4. If iOS asks: Settings → Privacy & Security → **Developer Mode** on, iPhone restarts.

With a free Apple ID the app has to be **refreshed every 7 days**. SideStore and AltStore do that for you, just open them once a week. HomeCast uses a single app ID (no extensions).

## 5. First start

1. Open HomeCast, enter the server address from step 3, your PinePods user name and password, tap **Sign In**.
2. Allow **local network** access when asked (needed for servers at home).
3. Your shows, queue and progress load. Everything is also stored on the iPhone, so the app works offline; changes made offline are sent the next time the server is reachable.

## Troubleshooting

| Problem | Fix |
|---|---|
| "Wrong username or password" | Log in once in the PinePods web UI to check. Two-factor accounts are not supported yet. |
| Sign-in hangs | The iPhone can't reach the server: same Wi-Fi? VPN on? Try the address in Safari on the iPhone: `<address>/api/health`. |
| New episodes missing | PinePods refreshes feeds periodically. Pull to refresh on a show page to re-read that feed now. |
| Chapters missing | Chapters come from the feed (Podcasting 2.0 `podcast:chapters`) or from the audio file (ID3/MP4). Not every podcast has them. |
