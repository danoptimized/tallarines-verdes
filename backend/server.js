import 'dotenv/config';
import crypto from 'crypto';

import cors from 'cors';
import express from 'express';
import { applicationDefault, cert, getApps, initializeApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';

const app = express();
const port = Number(process.env.PORT || '8787');
const rawBaseUrl = (process.env.BASE_URL || 'https://tv.lull.works').trim();
const baseUrl = rawBaseUrl.endsWith('/')
  ? rawBaseUrl.substring(0, rawBaseUrl.length - 1)
  : rawBaseUrl;
const rawApiPrefix = (process.env.API_PREFIX || '').trim();
const apiPrefix = (() => {
  if (!rawApiPrefix || rawApiPrefix === '/') {
    return '';
  }
  const withoutLeading = rawApiPrefix.startsWith('/')
    ? rawApiPrefix.substring(1)
    : rawApiPrefix;
  const trimmed = withoutLeading.replace(/\/+$/, '');
  return `/${trimmed}`;
})();
const spotifyApi = express.Router();
const firebaseProjectId = (process.env.FIREBASE_PROJECT_ID || 'tallerines-verdes')
  .trim();
const firebaseServiceAccountJson = (
  process.env.FIREBASE_SERVICE_ACCOUNT_JSON || ''
).trim();
const rawCorsAllowedOrigins = (
  process.env.CORS_ALLOWED_ORIGINS ||
  'https://lull.works,https://www.lull.works,https://tv.lull.works,http://localhost:3000,http://localhost:5173'
).trim();
const corsAllowedOrigins = rawCorsAllowedOrigins
  .split(',')
  .map((origin) => origin.trim())
  .filter(Boolean);

function initializeFirebaseAdmin() {
  if (getApps().length > 0) {
    return getApps()[0];
  }

  if (firebaseServiceAccountJson) {
    let parsedServiceAccount;
    try {
      parsedServiceAccount = JSON.parse(firebaseServiceAccountJson);
    } catch (_) {
      throw new Error(
        'FIREBASE_SERVICE_ACCOUNT_JSON is not valid JSON.',
      );
    }
    return initializeApp({
      credential: cert(parsedServiceAccount),
      projectId: firebaseProjectId || parsedServiceAccount.project_id,
    });
  }

  return initializeApp({
    credential: applicationDefault(),
    projectId: firebaseProjectId || undefined,
  });
}

const firebaseApp = initializeFirebaseAdmin();
const firestore = getFirestore(firebaseApp);
const spotifySessionsCollection = firestore.collection('spotify_sessions');

function isLocalOrigin(origin) {
  try {
    const parsed = new URL(origin);
    return parsed.hostname === 'localhost' || parsed.hostname === '127.0.0.1';
  } catch (_) {
    return false;
  }
}

app.use(
  cors({
    origin(origin, callback) {
      if (!origin) {
        callback(null, true);
        return;
      }
      if (corsAllowedOrigins.includes(origin) || isLocalOrigin(origin)) {
        callback(null, true);
        return;
      }
      callback(new Error(`CORS blocked origin: ${origin}`));
    },
  }),
);
app.use(express.json());

const spotifyClientId = (process.env.SPOTIFY_CLIENT_ID || '').trim();
const spotifyClientSecret = (process.env.SPOTIFY_CLIENT_SECRET || '').trim();

const connectStates = new Map();

let cachedAppToken = null;
let cachedAppTokenExpiresAt = 0;

function requireClientCredentials() {
  if (!spotifyClientId || !spotifyClientSecret) {
    throw new Error('Missing SPOTIFY_CLIENT_ID/SPOTIFY_CLIENT_SECRET');
  }
}

function isValidSpotifyHost(hostname) {
  const host = (hostname || '').toLowerCase();
  return host === 'open.spotify.com' || host === 'play.spotify.com';
}

function spotifyEntityIdFromUrl(spotifyUrl, entity) {
  let uri;
  try {
    uri = new URL(spotifyUrl);
  } catch (_) {
    return null;
  }
  if (!isValidSpotifyHost(uri.hostname)) {
    return null;
  }
  const parts = uri.pathname.split('/').filter(Boolean);
  if (parts.length < 2) {
    return null;
  }
  if ((parts[0] || '').toLowerCase() !== entity.toLowerCase()) {
    return null;
  }
  return (parts[1] || '').trim() || null;
}

function toDuration(durationMs) {
  if (!Number.isFinite(durationMs) || durationMs <= 0) {
    return '';
  }
  const totalSeconds = Math.floor(durationMs / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${minutes}:${String(seconds).padStart(2, '0')}`;
}

function normalizeTrack(track) {
  const images = track?.album?.images;
  return {
    title: (track?.name || '').trim(),
    artist: (track?.artists || [])
      .map((artist) => (artist?.name || '').trim())
      .filter(Boolean)
      .join(', '),
    duration: toDuration(track?.duration_ms),
    spotifyUrl: track?.external_urls?.spotify || '',
    spotifyTrackId: track?.id || '',
    spotifyUri: track?.uri || '',
    artworkUrl: Array.isArray(images) && images.length > 0 ? images[0]?.url || null : null,
  };
}

function normalizePlaylist(playlist) {
  return {
    id: playlist?.id || '',
    name: (playlist?.name || '').trim(),
    tracksTotal: Number(playlist?.tracks?.total || 0),
  };
}

function firstSpotifyImageUrl(images) {
  if (!Array.isArray(images)) {
    return null;
  }
  for (const image of images) {
    const url = (image?.url || '').trim();
    if (url) {
      return url;
    }
  }
  return null;
}

function spotifyAuthHeader() {
  return `Basic ${Buffer.from(`${spotifyClientId}:${spotifyClientSecret}`).toString('base64')}`;
}

async function requestToken(params) {
  requireClientCredentials();
  const response = await fetch('https://accounts.spotify.com/api/token', {
    method: 'POST',
    headers: {
      Authorization: spotifyAuthHeader(),
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: new URLSearchParams(params),
  });
  if (!response.ok) {
    throw new Error(`Spotify token request failed (${response.status})`);
  }
  return response.json();
}

async function getSpotifyAccessToken() {
  const now = Date.now();
  if (cachedAppToken && now < cachedAppTokenExpiresAt - 20_000) {
    return cachedAppToken;
  }
  const payload = await requestToken({ grant_type: 'client_credentials' });
  cachedAppToken = payload.access_token || null;
  cachedAppTokenExpiresAt = now + Number(payload.expires_in || 3600) * 1000;
  if (!cachedAppToken) {
    throw new Error('Spotify app token missing in response');
  }
  return cachedAppToken;
}

async function spotifyGetJson(path, accessToken) {
  const response = await fetch(`https://api.spotify.com/v1${path}`, {
    headers: {
      Authorization: `Bearer ${accessToken}`,
      Accept: 'application/json',
    },
  });
  if (response.status === 401) {
    const error = new Error('Spotify token expired');
    error.code = 'token_expired';
    throw error;
  }
  if (!response.ok) {
    throw new Error(`Spotify request failed for ${path} (${response.status})`);
  }
  return response.json();
}

function assertSessionId(sessionId) {
  if (!sessionId) {
    const error = new Error('Missing sessionId query parameter');
    error.statusCode = 400;
    throw error;
  }
}

async function readSession(sessionId) {
  assertSessionId(sessionId);
  const sessionSnapshot = await spotifySessionsCollection.doc(sessionId).get();
  const session = sessionSnapshot.exists
    ? sessionSnapshot.data()
    : null;
  if (!session?.refreshToken) {
    const error = new Error('Spotify account not connected for this session');
    error.statusCode = 401;
    throw error;
  }
  return session;
}
async function saveSession(sessionId, session) {
  await spotifySessionsCollection.doc(sessionId).set({
    ...session,
    updatedAt: new Date().toISOString(),
  }, { merge: true });
}

async function deleteSession(sessionId) {
  assertSessionId(sessionId);
  await spotifySessionsCollection.doc(sessionId).delete();
}

async function refreshUserToken(sessionId, refreshToken) {
  const payload = await requestToken({
    grant_type: 'refresh_token',
    refresh_token: refreshToken,
  });
  const nextSession = {
    accessToken: payload.access_token || '',
    refreshToken: payload.refresh_token || refreshToken,
    expiresAt: Date.now() + Number(payload.expires_in || 3600) * 1000,
    connectedAt: new Date().toISOString(),
  };
  await saveSession(sessionId, nextSession);
  return nextSession;
}

async function getUserAccessToken(sessionId) {
  const session = await readSession(sessionId);
  if (
    session.accessToken &&
    Number.isFinite(session.expiresAt) &&
    Date.now() < session.expiresAt - 20_000
  ) {
    return session.accessToken;
  }
  const refreshed = await refreshUserToken(sessionId, session.refreshToken);
  return refreshed.accessToken;
}

async function userSpotifyGetJson(sessionId, path) {
  let accessToken = await getUserAccessToken(sessionId);
  try {
    return await spotifyGetJson(path, accessToken);
  } catch (error) {
    if (error?.code !== 'token_expired') {
      throw error;
    }
    const session = await readSession(sessionId);
    const refreshed = await refreshUserToken(sessionId, session.refreshToken);
    accessToken = refreshed.accessToken;
    return spotifyGetJson(path, accessToken);
  }
}

async function importTrackById(trackId) {
  const appToken = await getSpotifyAccessToken();
  const payload = await spotifyGetJson(`/tracks/${encodeURIComponent(trackId)}`, appToken);
  return [normalizeTrack(payload)];
}

async function importPlaylistByIdWithAppToken(playlistId) {
  const appToken = await getSpotifyAccessToken();
  return importPlaylistByIdWithToken(playlistId, appToken);
}

async function importPlaylistByIdForSession(sessionId, playlistId) {
  const accessToken = await getUserAccessToken(sessionId);
  return importPlaylistByIdWithToken(playlistId, accessToken, sessionId);
}

async function importPlaylistByIdWithToken(playlistId, accessToken, sessionId) {
  const tracks = [];
  let offset = 0;
  const limit = 100;

  while (true) {
    const payload = sessionId
      ? await userSpotifyGetJson(
          sessionId,
          `/playlists/${encodeURIComponent(
            playlistId,
          )}/tracks?limit=${limit}&offset=${offset}&fields=items(track(id,name,uri,duration_ms,external_urls,album(images),artists(name))),next`,
        )
      : await spotifyGetJson(
          `/playlists/${encodeURIComponent(
            playlistId,
          )}/tracks?limit=${limit}&offset=${offset}&fields=items(track(id,name,uri,duration_ms,external_urls,album(images),artists(name))),next`,
          accessToken,
        );

    const items = Array.isArray(payload?.items) ? payload.items : [];
    for (const item of items) {
      const track = item?.track;
      if (!track?.id) {
        continue;
      }
      tracks.push(normalizeTrack(track));
    }
    if (!payload?.next) {
      break;
    }
    offset += limit;
  }
  return tracks;
}

async function listUserPlaylists(sessionId) {
  const playlists = [];
  let offset = 0;
  const limit = 50;

  while (true) {
    const payload = await userSpotifyGetJson(
      sessionId,
      `/me/playlists?limit=${limit}&offset=${offset}&fields=items(id,name,tracks(total)),next`,
    );
    const items = Array.isArray(payload?.items) ? payload.items : [];
    for (const playlist of items) {
      if (!playlist?.id) {
        continue;
      }
      playlists.push(normalizePlaylist(playlist));
    }
    if (!payload?.next) {
      break;
    }
    offset += limit;
  }
  return playlists;
}

async function listLikedSongs(sessionId, limit) {
  const tracks = [];
  let offset = 0;
  const pageSize = Math.min(Math.max(limit, 1), 50);
  const hardLimit = Math.max(limit, 1);

  while (tracks.length < hardLimit) {
    const payload = await userSpotifyGetJson(
      sessionId,
      `/me/tracks?limit=${pageSize}&offset=${offset}&fields=items(track(id,name,uri,duration_ms,external_urls,album(images),artists(name))),next`,
    );
    const items = Array.isArray(payload?.items) ? payload.items : [];
    for (const item of items) {
      const track = item?.track;
      if (!track?.id) {
        continue;
      }
      tracks.push(normalizeTrack(track));
      if (tracks.length >= hardLimit) {
        break;
      }
    }
    if (!payload?.next || items.length === 0) {
      break;
    }
    offset += pageSize;
  }
  return tracks.slice(0, hardLimit);
}

async function listRecentlyPlayed(sessionId, limit) {
  const capped = Math.min(Math.max(limit, 1), 50);
  const payload = await userSpotifyGetJson(
    sessionId,
    `/me/player/recently-played?limit=${capped}`,
  );
  const items = Array.isArray(payload?.items) ? payload.items : [];
  const seen = new Set();
  const tracks = [];
  for (const item of items) {
    const track = item?.track;
    if (!track?.id || seen.has(track.id)) {
      continue;
    }
    seen.add(track.id);
    tracks.push(normalizeTrack(track));
  }
  return tracks;
}

function callbackHtml(message) {
  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <title>Spotify linked</title>
    <style>
      body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #0b0a14; color: #f5f5f5; display:flex; align-items:center; justify-content:center; min-height:100vh; margin:0; }
      .card { background:#171324; border:1px solid #2b2542; border-radius:12px; padding:24px; max-width:520px; text-align:center; }
      h1 { margin-top:0; color:#e0f64f; font-size:22px; }
      p { color:#c8c5dc; line-height:1.5; }
    </style>
  </head>
  <body>
    <div class="card">
      <h1>Spotify connection complete</h1>
      <p>${message}</p>
      <p>You can return to the app now.</p>
    </div>
  </body>
</html>`;
}

spotifyApi.get('/health', (_req, res) => {
  res.json({ ok: true });
});

spotifyApi.get('/spotify/connect/start', (req, res) => {
  try {
    requireClientCredentials();
    const sessionId = String(req.query.sessionId || '').trim();
    if (!sessionId) {
      return res.status(400).json({ error: 'Missing sessionId query parameter' });
    }

    const state = crypto.randomUUID();
    connectStates.set(state, {
      sessionId,
      createdAt: Date.now(),
    });

    const redirectUri = `${baseUrl}/spotify/connect/callback`;
    const scope = [
      'playlist-read-private',
      'playlist-read-collaborative',
      'user-library-read',
      'user-read-private',
      'user-read-recently-played',
      'user-read-playback-state',
      'user-read-currently-playing',
      'user-modify-playback-state',
      'streaming',
      'app-remote-control',
    ].join(' ');

    const authorizeUrl = new URL('https://accounts.spotify.com/authorize');
    authorizeUrl.searchParams.set('response_type', 'code');
    authorizeUrl.searchParams.set('client_id', spotifyClientId);
    authorizeUrl.searchParams.set('scope', scope);
    authorizeUrl.searchParams.set('redirect_uri', redirectUri);
    authorizeUrl.searchParams.set('state', state);

    return res.json({
      sessionId,
      authorizeUrl: authorizeUrl.toString(),
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown error';
    return res.status(500).json({ error: message });
  }
});

spotifyApi.get('/spotify/connect/callback', async (req, res) => {
  const code = String(req.query.code || '').trim();
  const state = String(req.query.state || '').trim();
  if (!code || !state) {
    return res
      .status(400)
      .send(callbackHtml('Spotify callback was missing required parameters.'));
  }

  const pending = connectStates.get(state);
  connectStates.delete(state);
  if (!pending?.sessionId) {
    return res.status(400).send(callbackHtml('Connection state was invalid or expired.'));
  }

  try {
    const redirectUri = `${baseUrl}/spotify/connect/callback`;
    const payload = await requestToken({
      grant_type: 'authorization_code',
      code,
      redirect_uri: redirectUri,
    });

    await saveSession(pending.sessionId, {
      accessToken: payload.access_token || '',
      refreshToken: payload.refresh_token || '',
      expiresAt: Date.now() + Number(payload.expires_in || 3600) * 1000,
      connectedAt: new Date().toISOString(),
    });

    return res.status(200).send(
      callbackHtml('Your Spotify account has been linked successfully.'),
    );
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown error';
    return res.status(500).send(callbackHtml(`Spotify linking failed: ${message}`));
  }
});

spotifyApi.get('/spotify/connect/status', async (req, res) => {
  const sessionId = String(req.query.sessionId || '').trim();
  if (!sessionId) {
    return res.status(400).json({ error: 'Missing sessionId query parameter' });
  }
  try {
    const sessionSnapshot = await spotifySessionsCollection.doc(sessionId).get();
    const session = sessionSnapshot.exists
      ? sessionSnapshot.data()
      : null;
    return res.json({
      sessionId,
      connected: Boolean(session?.refreshToken),
      connectedAt: session?.connectedAt || null,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown error';
    return res.status(500).json({ error: message });
  }
});
spotifyApi.get('/spotify/connect/access-token', async (req, res) => {
  const sessionId = String(req.query.sessionId || '').trim();
  if (!sessionId) {
    return res.status(400).json({ error: 'Missing sessionId query parameter' });
  }
  try {
    const accessToken = await getUserAccessToken(sessionId);
    return res.json({
      sessionId,
      accessToken,
      tokenType: 'Bearer',
      clientId: spotifyClientId,
      redirectUri: `${baseUrl}/spotify/connect/callback`,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown error';
    return res.status(error.statusCode || 500).json({ error: message });
  }
});

spotifyApi.get('/spotify/me/profile', async (req, res) => {
  try {
    const sessionId = String(req.query.sessionId || '').trim();
    const payload = await userSpotifyGetJson(
      sessionId,
      '/me?fields=id,display_name,images(url)',
    );
    const id = (payload?.id || '').trim();
    const displayName = (payload?.display_name || '').trim();
    let imageUrl = firstSpotifyImageUrl(payload?.images);
    if (!imageUrl && id) {
      try {
        const publicProfile = await userSpotifyGetJson(
          sessionId,
          `/users/${encodeURIComponent(id)}?fields=images(url)`,
        );
        imageUrl = firstSpotifyImageUrl(publicProfile?.images);
      } catch (_) {}
    }
    return res.json({
      id,
      displayName,
      imageUrl,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown error';
    return res.status(error.statusCode || 500).json({ error: message });
  }
});
spotifyApi.post('/spotify/connect/disconnect', async (req, res) => {
  const sessionId = String(req.body?.sessionId || '').trim();
  if (!sessionId) {
    return res.status(400).json({ error: 'Missing sessionId body parameter' });
  }
  try {
    await deleteSession(sessionId);
    return res.json({ disconnected: true, sessionId });
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown error';
    return res.status(error.statusCode || 500).json({ error: message });
  }
});

spotifyApi.get('/spotify/me/playlists', async (req, res) => {
  try {
    const sessionId = String(req.query.sessionId || '').trim();
    const playlists = await listUserPlaylists(sessionId);
    return res.json({ playlists });
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown error';
    return res.status(error.statusCode || 500).json({ error: message });
  }
});

spotifyApi.get('/spotify/me/playlist-tracks', async (req, res) => {
  try {
    const sessionId = String(req.query.sessionId || '').trim();
    const playlistId = String(req.query.playlistId || '').trim();
    if (!playlistId) {
      return res.status(400).json({ error: 'Missing playlistId query parameter' });
    }
    const tracks = await importPlaylistByIdForSession(sessionId, playlistId);
    return res.json({ tracks });
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown error';
    return res.status(error.statusCode || 500).json({ error: message });
  }
});

spotifyApi.get('/spotify/me/liked-tracks', async (req, res) => {
  try {
    const sessionId = String(req.query.sessionId || '').trim();
    const limit = Number(req.query.limit || 50);
    const tracks = await listLikedSongs(sessionId, limit);
    return res.json({ tracks });
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown error';
    return res.status(error.statusCode || 500).json({ error: message });
  }
});

spotifyApi.get('/spotify/me/recently-played', async (req, res) => {
  try {
    const sessionId = String(req.query.sessionId || '').trim();
    const limit = Number(req.query.limit || 50);
    const tracks = await listRecentlyPlayed(sessionId, limit);
    return res.json({ tracks });
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown error';
    return res.status(error.statusCode || 500).json({ error: message });
  }
});

spotifyApi.get('/spotify/import-url', async (req, res) => {
  try {
    const spotifyUrl = String(req.query.url || '').trim();
    if (!spotifyUrl) {
      return res.status(400).json({ error: 'Missing url query parameter' });
    }

    const trackId = spotifyEntityIdFromUrl(spotifyUrl, 'track');
    if (trackId) {
      const tracks = await importTrackById(trackId);
      return res.json({ tracks });
    }

    const playlistId = spotifyEntityIdFromUrl(spotifyUrl, 'playlist');
    if (playlistId) {
      const tracks = await importPlaylistByIdWithAppToken(playlistId);
      return res.json({ tracks });
    }

    return res.status(400).json({
      error: 'Unsupported Spotify URL type. Supported: track, playlist',
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown error';
    return res.status(500).json({ error: message });
  }
});
if (apiPrefix) {
  app.use(apiPrefix, spotifyApi);
} else {
  app.use(spotifyApi);
}

app.listen(port, () => {
  const activePrefix = apiPrefix || '/';
  console.log(
    `Spotify backend listening on port ${port} (API prefix: ${activePrefix})`,
  );
});