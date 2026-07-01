# tallarines_verdes_flutter
Band setlist organizer with Spotify-assisted song imports.

## Flutter app
- Install dependencies: `flutter pub get`
- Run app: `flutter run`

## Firebase (Firestore + Auth)
This app now uses Firebase as the primary data store (fresh start, no local migration).

1. In Firebase Console for `tallerines-verdes`:
   - Enable **Authentication** with **Anonymous** provider.
   - Create **Cloud Firestore** database.
2. Deploy Firestore rules from this repo:
   - `firebase deploy --only firestore:rules`
3. App data layout:
   - `users/{uid}/setlists/main`
   - `users/{uid}/setlists/main/songs/{songId}`

## Optional Spotify backend (for playlist URL imports)
The Flutter importer can resolve playlist URLs and account-linked imports through a small local backend.

1. Create Spotify app credentials at Spotify Developer Dashboard.
2. Setup backend environment:
   - `cp backend/.env.example backend/.env`
   - Fill `SPOTIFY_CLIENT_ID` and `SPOTIFY_CLIENT_SECRET`
   - Keep `BASE_URL=https://lull.works/tv` and `API_PREFIX=/tv` for deployed usage
   - This keeps all Spotify backend routes under `/tv/*` so root `lull.works/*` remains untouched
   - In Spotify app settings, use redirect URI: `https://lull.works/tv/spotify/connect/callback`
3. Start backend:
   - `cd backend`
   - `npm install`
   - `npm run dev`
By default, Flutter targets `https://lull.works/tv`.
For local development, override this:
- `flutter run --dart-define=SPOTIFY_BACKEND_BASE_URL=http://localhost:8787/tv`
- `flutter run --dart-define=SPOTIFY_BACKEND_BASE_URL=http://<host>:<port>/tv`

With the backend running, the app supports:
- Import by Spotify track/playlist URL
- Connect Spotify account (OAuth) and import:
  - My Playlists
  - Liked Songs
  - Recently Played

## Production launch (Railway + Firebase)
Use this architecture:
- Frontend: Flutter web (host wherever you prefer)
- Spotify API backend: Railway (`backend/` service)
- Data/Auth: Firebase (Firestore + Auth)

### 1) Railway backend service
Create a Railway service from the `backend/` directory and set:
- Start command: `npm start`
- Config file: `backend/railway.json` is included

Required Railway environment variables:
- `SPOTIFY_CLIENT_ID`
- `SPOTIFY_CLIENT_SECRET`
- `BASE_URL=https://lull.works/tv`
- `API_PREFIX=/tv`
- `FIREBASE_PROJECT_ID=tallerines-verdes`
- `FIREBASE_SERVICE_ACCOUNT_JSON=<service-account-json>`
- `CORS_ALLOWED_ORIGINS=https://lull.works,https://www.lull.works`

### 2) Firebase Admin service account for backend
In Firebase Console:
1. Project settings → Service accounts
2. Generate a new private key JSON
3. Paste the full JSON into Railway as `FIREBASE_SERVICE_ACCOUNT_JSON`

This enables durable backend session storage in Firestore (`spotify_sessions`), so Spotify links survive backend restarts/redeploys.

### 3) Spotify app callback
In Spotify Developer Dashboard, keep:
- `https://lull.works/tv/spotify/connect/callback`

### 4) Frontend production env
Build/run frontend with:
- `SPOTIFY_BACKEND_BASE_URL=https://lull.works/tv`

### 5) Smoke tests after deploy
1. Open `https://lull.works/tv/health` (expect JSON `{ "ok": true }`)
2. Open app and connect Spotify
3. Import from playlist + liked songs
4. Restart backend service
5. Verify Spotify link status remains connected
