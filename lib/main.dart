import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:spotify_sdk/models/player_state.dart';
import 'package:spotify_sdk/models/track.dart';
import 'package:spotify_sdk/spotify_sdk.dart';
import 'package:url_launcher/url_launcher.dart';
import 'firebase_options.dart';

const Color _appBackground = Color(0xFF0B0A14);
const Color _appSurface = Color(0xFF171324);
const Color _appSurfaceStrong = Color(0xFF211B33);
const Color _appPrimary = Color(0xFFE0F64F);
const Color _appMutedText = Color(0xFFB8B5CB);
const Color _appAccent = Color(0xFF5D4A8A);

// Shared geometry between _CurrentSongBar and _BottomActionBar so the
// current-song outline lines up exactly with the "Current Song" tab.
const double _bottomNavHorizontalPadding = 8;
const double _bottomNavTabHorizontalInset = 10;
const double _bottomNavOuterCornerRadius = 20;
const double _connectedOutlineWidth = 1.5;
const int _bottomNavTabCount = 3;

double _currentSongTabLeft(double barWidth) {
  final double tabRowWidth = barWidth - _bottomNavHorizontalPadding;
  final double tabCellWidth = tabRowWidth / _bottomNavTabCount;
  return _bottomNavHorizontalPadding +
      (tabCellWidth * (_bottomNavTabCount - 1)) +
      _bottomNavTabHorizontalInset;
}

double _currentSongTabRight(double barWidth) => barWidth;
const List<String> _editableInstrumentOptions = <String>[
  'Guitar',
  'Drums',
  'Vocals',
  'Bass',
  'Keys',
];
const List<String> _editablePlayerOptions = <String>[
  'Daniel',
  'Jim',
  'Matt',
  'Brenda',
  'Ben',
  'Mikayla',
];

enum SongSourceType { manual, spotifyUrl, spotifyAccount }

enum _SpotifyUrlKind { invalid, track, playlist }

final Random _random = Random();

String _createId(String prefix) {
  return '$prefix-${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(999999)}';
}

String _cleanSpotifyTitle(String value) {
  return value
      .replaceFirst(RegExp(r'\s*\|\s*Spotify\s*$', caseSensitive: false), '')
      .trim();
}

String _asTrimmedString(Object? value) {
  if (value == null) {
    return '';
  }
  if (value is String) {
    return value.trim();
  }
  return value.toString().trim();
}

int? _asInt(Object? value) {
  if (value is num) {
    return value.toInt();
  }
  final String parsed = _asTrimmedString(value);
  if (parsed.isEmpty) {
    return null;
  }
  return int.tryParse(parsed);
}

Map<String, dynamic>? _asStringKeyedMap(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map<String, dynamic>(
      (Object? key, Object? mappedValue) =>
          MapEntry<String, dynamic>(key.toString(), mappedValue),
    );
  }
  return null;
}

String? _firstSpotifyImageUrl(Object? rawImages) {
  if (rawImages is! List) {
    return null;
  }
  for (final Object? rawImage in rawImages) {
    final Map<String, dynamic>? image = _asStringKeyedMap(rawImage);
    final String url = (image?['url'] as String? ?? '').trim();
    if (url.isNotEmpty) {
      return url;
    }
  }
  return null;
}

bool _isValidSpotifyHost(String host) {
  final String normalizedHost = host.toLowerCase();
  return normalizedHost == 'open.spotify.com' ||
      normalizedHost == 'play.spotify.com';
}

_SpotifyUrlKind _spotifyUrlKind(Uri uri) {
  if (!_isValidSpotifyHost(uri.host)) {
    return _SpotifyUrlKind.invalid;
  }
  if (uri.pathSegments.length < 2) {
    return _SpotifyUrlKind.invalid;
  }

  final String resource = uri.pathSegments.first.toLowerCase();
  if (resource == 'track') {
    return _SpotifyUrlKind.track;
  }
  if (resource == 'playlist') {
    return _SpotifyUrlKind.playlist;
  }
  return _SpotifyUrlKind.invalid;
}

String? _spotifyEntityIdFromUri(Uri uri, String resource) {
  if (!_isValidSpotifyHost(uri.host) || uri.pathSegments.length < 2) {
    return null;
  }
  if (uri.pathSegments.first.toLowerCase() != resource.toLowerCase()) {
    return null;
  }
  final String parsed = uri.pathSegments[1].trim();
  if (parsed.isEmpty) {
    return null;
  }
  return parsed;
}

String? _spotifyTrackIdFromUrl(String spotifyUrl) {
  final Uri? uri = Uri.tryParse(spotifyUrl.trim());
  if (uri == null) {
    return null;
  }
  return _spotifyEntityIdFromUri(uri, 'track');
}

String _sanitizeSpotifyTrackId(String value) {
  return value.trim().split('?').first.split('#').first.trim();
}

String? _spotifyTrackIdFromSpotifyUri(String? spotifyUri) {
  final List<String> parts = (spotifyUri ?? '').trim().split(':');
  if (parts.length < 3) {
    return null;
  }
  final String type = parts[1].trim().toLowerCase();
  if (type != 'track') {
    return null;
  }
  final String trackId = _sanitizeSpotifyTrackId(parts[2]);
  if (trackId.isEmpty) {
    return null;
  }
  return trackId;
}

String _spotifyPlayUriFromTrackId(String trackId) {
  return 'spotify:track:${_sanitizeSpotifyTrackId(trackId)}';
}

String _durationFromMilliseconds(int milliseconds) {
  if (milliseconds <= 0) {
    return '';
  }
  final int totalSeconds = milliseconds ~/ 1000;
  final int minutes = totalSeconds ~/ 60;
  final int seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

String? _spotifyPlaylistIdFromSpotifyUri(String? spotifyUri) {
  final List<String> parts = (spotifyUri ?? '').trim().split(':');
  if (parts.length < 3) {
    return null;
  }
  final String type = parts[1].trim().toLowerCase();
  if (type != 'playlist') {
    return null;
  }
  final String playlistId = parts[2].split('?').first.split('#').first.trim();
  if (playlistId.isEmpty) {
    return null;
  }
  return playlistId;
}

Uri? _parseExternalHttpUri(String rawUrl) {
  final Uri? parsed = Uri.tryParse(rawUrl.trim());
  if (parsed == null) {
    return null;
  }
  if (parsed.scheme != 'http' && parsed.scheme != 'https') {
    return null;
  }
  return parsed;
}

bool _songHasPlayableSpotifyTrack(Song song) {
  if ((song.spotifyTrackId ?? '').trim().isNotEmpty) {
    return true;
  }
  if (_spotifyTrackIdFromSpotifyUri(song.spotifyUri) != null) {
    return true;
  }
  return _spotifyTrackIdFromUrl(song.spotifyUrl) != null;
}

Future<void> _openExternalLink(
  BuildContext context,
  String rawUrl, {
  String failureMessage = 'Could not open link.',
}) async {
  final Uri? uri = _parseExternalHttpUri(rawUrl);
  if (uri == null) {
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Invalid link URL.')));
    return;
  }
  bool opened = false;
  try {
    opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {}
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(failureMessage)));
  }
}

String _normalizeForMatch(String value) {
  return value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _spotifyBackendFailureMessage(
  Object? error, {
  http.Response? response,
  required String fallback,
}) {
  if (response != null) {
    try {
      final Object? decoded = jsonDecode(response.body);
      final Map<String, dynamic>? payload = _asStringKeyedMap(decoded);
      final String serverError = _asTrimmedString(payload?['error']);
      if (serverError.isNotEmpty) {
        return serverError;
      }
    } catch (_) {}
    if (response.statusCode == 401) {
      return 'Spotify account not connected. Reconnect Spotify and try again.';
    }
  }
  if (error is FormatException) {
    final String message = error.message.trim();
    if (message.isNotEmpty) {
      return message;
    }
  }
  return fallback;
}

const String _spotifyBackendBaseUrl = String.fromEnvironment(
  'SPOTIFY_BACKEND_BASE_URL',
  defaultValue: 'https://tv.lull.works',
);
const String _spotifySdkClientId = String.fromEnvironment(
  'SPOTIFY_SDK_CLIENT_ID',
  defaultValue: '',
);
const String _spotifySdkRedirectUri = String.fromEnvironment(
  'SPOTIFY_SDK_REDIRECT_URI',
  defaultValue: '',
);
const String _spotifyAndroidAppRemoteRedirectUri = 'spotify-sdk://auth';
const String _spotifyIosAppRemoteRedirectUri =
    'tallarinesverdes://spotify-auth';
const String _spotifyRemoteAuthScope =
    'app-remote-control,user-modify-playback-state,user-read-playback-state,user-read-currently-playing,streaming';

String _resolveSpotifySdkRedirectUri(String serverRedirectUri) {
  final String configuredRedirectUri = _spotifySdkRedirectUri.trim();
  if (configuredRedirectUri.isNotEmpty) {
    return configuredRedirectUri;
  }
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return _spotifyAndroidAppRemoteRedirectUri;
  }
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
    return _spotifyIosAppRemoteRedirectUri;
  }
  return serverRedirectUri.trim();
}

class _SpotifyImportTrack {
  const _SpotifyImportTrack({
    required this.title,
    required this.artist,
    required this.duration,
    required this.spotifyUrl,
    required this.spotifyTrackId,
    required this.spotifyUri,
    required this.artworkUrl,
  });

  final String title;
  final String artist;
  final String duration;
  final String spotifyUrl;
  final String spotifyTrackId;
  final String spotifyUri;
  final String? artworkUrl;

  factory _SpotifyImportTrack.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> trackPayload =
        _asStringKeyedMap(json['track']) ??
        _asStringKeyedMap(json['item']) ??
        json;
    final Map<String, dynamic>? externalUrls = _asStringKeyedMap(
      trackPayload['external_urls'],
    );
    final Map<String, dynamic>? albumPayload = _asStringKeyedMap(
      trackPayload['album'],
    );

    final String title = _asTrimmedString(trackPayload['title']).isNotEmpty
        ? _asTrimmedString(trackPayload['title'])
        : _asTrimmedString(trackPayload['name']);

    String artist = _asTrimmedString(trackPayload['artist']);
    if (artist.isEmpty) {
      artist = _asTrimmedString(trackPayload['artistsText']);
    }
    if (artist.isEmpty) {
      final Object? rawArtists = trackPayload['artists'];
      if (rawArtists is List) {
        final List<String> artistNames = rawArtists
            .map((Object? rawArtist) {
              final Map<String, dynamic>? artistMap = _asStringKeyedMap(
                rawArtist,
              );
              return _asTrimmedString(artistMap?['name']);
            })
            .where((String value) => value.isNotEmpty)
            .toList(growable: false);
        artist = artistNames.join(', ');
      }
    }

    String spotifyUrl = _asTrimmedString(trackPayload['spotifyUrl']);
    if (spotifyUrl.isEmpty) {
      spotifyUrl = _asTrimmedString(trackPayload['url']);
    }
    if (spotifyUrl.isEmpty) {
      spotifyUrl = _asTrimmedString(externalUrls?['spotify']);
    }

    String spotifyUri = _asTrimmedString(trackPayload['spotifyUri']);
    if (spotifyUri.isEmpty) {
      spotifyUri = _asTrimmedString(trackPayload['uri']);
    }

    String spotifyTrackId = _sanitizeSpotifyTrackId(
      _asTrimmedString(trackPayload['spotifyTrackId']).isNotEmpty
          ? _asTrimmedString(trackPayload['spotifyTrackId'])
          : _asTrimmedString(trackPayload['trackId']).isNotEmpty
          ? _asTrimmedString(trackPayload['trackId'])
          : _asTrimmedString(trackPayload['id']),
    );
    if (spotifyTrackId.isEmpty) {
      spotifyTrackId =
          _spotifyTrackIdFromSpotifyUri(spotifyUri) ??
          (_spotifyTrackIdFromUrl(spotifyUrl) ?? '');
    }
    spotifyTrackId = _sanitizeSpotifyTrackId(spotifyTrackId);
    if (spotifyTrackId.isNotEmpty && spotifyUri.isEmpty) {
      spotifyUri = _spotifyPlayUriFromTrackId(spotifyTrackId);
    }
    if (spotifyTrackId.isNotEmpty && spotifyUrl.isEmpty) {
      spotifyUrl = 'https://open.spotify.com/track/$spotifyTrackId';
    }

    String duration = _asTrimmedString(trackPayload['duration']);
    if (duration.isEmpty) {
      final int durationMs =
          _asInt(trackPayload['durationMs']) ??
          _asInt(trackPayload['duration_ms']) ??
          0;
      duration = _durationFromMilliseconds(durationMs);
    }

    String artworkUrl = _asTrimmedString(trackPayload['artworkUrl']);
    if (artworkUrl.isEmpty) {
      artworkUrl = _firstSpotifyImageUrl(trackPayload['images']) ?? '';
    }
    if (artworkUrl.isEmpty) {
      artworkUrl = _asTrimmedString(albumPayload?['artworkUrl']);
    }
    if (artworkUrl.isEmpty) {
      artworkUrl = _firstSpotifyImageUrl(albumPayload?['images']) ?? '';
    }
    final String? normalizedArtworkUrl = artworkUrl.isEmpty ? null : artworkUrl;
    return _SpotifyImportTrack(
      title: title,
      artist: artist,
      duration: duration,
      spotifyUrl: spotifyUrl,
      spotifyTrackId: spotifyTrackId,
      spotifyUri: spotifyUri,
      artworkUrl: normalizedArtworkUrl,
    );
  }
}

class _ImportArtworkThumbnail extends StatelessWidget {
  const _ImportArtworkThumbnail({
    required this.artworkUrl,
    this.size = 48,
  });

  final String? artworkUrl;
  final double size;

  @override
  Widget build(BuildContext context) {
    final String resolvedArtworkUrl = (artworkUrl ?? '').trim();
    final Widget fallback = Container(
      color: _appSurface,
      alignment: Alignment.center,
      child: Icon(
        Icons.queue_music_rounded,
        size: size * 0.42,
        color: Colors.white.withValues(alpha: 0.7),
      ),
    );

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: resolvedArtworkUrl.isEmpty
            ? fallback
            : Image.network(
                resolvedArtworkUrl,
                fit: BoxFit.cover,
                errorBuilder:
                    (
                      BuildContext context,
                      Object error,
                      StackTrace? stackTrace,
                    ) {
                      return fallback;
                    },
              ),
      ),
    );
  }
}

class _SongArtworkThumbnail extends StatelessWidget {
  const _SongArtworkThumbnail({
    required this.artworkUrl,
    required this.isCurrent,
  });

  final String? artworkUrl;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final String resolvedArtworkUrl = (artworkUrl ?? '').trim();
    final Widget fallback = Container(
      color: _appSurface,
      alignment: Alignment.center,
      child: Icon(
        Icons.music_note_rounded,
        size: 20,
        color: Colors.white.withValues(alpha: 0.7),
      ),
    );

    return Container(
      width: 54,
      height: 54,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isCurrent
              ? _appPrimary.withValues(alpha: 0.7)
              : Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: resolvedArtworkUrl.isEmpty
            ? fallback
            : Image.network(
                resolvedArtworkUrl,
                fit: BoxFit.cover,
                errorBuilder:
                    (
                      BuildContext context,
                      Object error,
                      StackTrace? stackTrace,
                    ) {
                      return fallback;
                    },
              ),
      ),
    );
  }
}

class _SetlistActionBarButton extends StatelessWidget {
  const _SetlistActionBarButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.highlighted = false,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool highlighted;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final bool isEnabled = onPressed != null;
    final Color activeColor = danger
        ? const Color(0xFFFF9A9A)
        : highlighted
        ? _appPrimary
        : _appMutedText;
    final Color foregroundColor = isEnabled
        ? activeColor
        : _appMutedText.withValues(alpha: 0.5);
    return Expanded(
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: foregroundColor,
          padding: const EdgeInsets.symmetric(vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 19),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class _SpotifyPlaybackToken {
  const _SpotifyPlaybackToken({
    required this.accessToken,
    required this.clientId,
    required this.redirectUri,
  });

  final String accessToken;
  final String clientId;
  final String redirectUri;

  factory _SpotifyPlaybackToken.fromJson(Map<String, dynamic> json) {
    final String accessToken = (json['accessToken'] as String? ?? '').trim();
    final String serverClientId = (json['clientId'] as String? ?? '').trim();
    final String serverRedirectUri = (json['redirectUri'] as String? ?? '')
        .trim();
    final String clientId = _spotifySdkClientId.isEmpty
        ? serverClientId
        : _spotifySdkClientId.trim();
    final String redirectUri = _resolveSpotifySdkRedirectUri(serverRedirectUri);
    return _SpotifyPlaybackToken(
      accessToken: accessToken,
      clientId: clientId,
      redirectUri: redirectUri,
    );
  }
}

class _SpotifyPlaylistSummary {
  const _SpotifyPlaylistSummary({
    required this.id,
    required this.name,
    required this.tracksTotal,
    this.artworkUrl,
  });

  final String id;
  final String name;
  final int tracksTotal;
  final String? artworkUrl;

  factory _SpotifyPlaylistSummary.fromJson(Map<String, dynamic> json) {
    String id = _asTrimmedString(json['id']);
    if (id.isEmpty) {
      id = _asTrimmedString(json['playlistId']);
    }
    if (id.isEmpty) {
      id =
          _spotifyPlaylistIdFromSpotifyUri(_asTrimmedString(json['uri'])) ?? '';
    }
    if (id.isEmpty) {
      final Map<String, dynamic>? externalUrls = _asStringKeyedMap(
        json['external_urls'],
      );
      final Uri? playlistUri = Uri.tryParse(
        _asTrimmedString(externalUrls?['spotify']),
      );
      id = playlistUri == null
          ? ''
          : (_spotifyEntityIdFromUri(playlistUri, 'playlist') ?? '');
    }

    String name = _asTrimmedString(json['name']);
    if (name.isEmpty) {
      name = _asTrimmedString(json['title']);
    }

    final Map<String, dynamic>? tracksMap = _asStringKeyedMap(json['tracks']);
    final Map<String, dynamic>? itemsMap = _asStringKeyedMap(json['items']);
    final Object? rawTrackItems = tracksMap?['items'] ?? itemsMap?['items'];
    final int nestedItemsCount = rawTrackItems is List
        ? rawTrackItems.length
        : 0;
    final int tracksTotal =
        _asInt(json['tracksTotal']) ??
        _asInt(json['tracks_count']) ??
        _asInt(json['trackCount']) ??
        _asInt(json['totalTracks']) ??
        _asInt(itemsMap?['total']) ??
        _asInt(tracksMap?['total']) ??
        nestedItemsCount;
    final String artworkUrl = _asTrimmedString(json['artworkUrl']);
    final String? resolvedArtworkUrl = artworkUrl.isNotEmpty
        ? artworkUrl
        : _firstSpotifyImageUrl(json['images']);
    return _SpotifyPlaylistSummary(
      id: id,
      name: name,
      tracksTotal: tracksTotal,
      artworkUrl: resolvedArtworkUrl,
    );
  }
}

int _durationToSeconds(String duration) {
  final RegExpMatch? match = RegExp(
    r'^(\d{1,2}):([0-5]\d)$',
  ).firstMatch(duration.trim());
  if (match == null) {
    return 0;
  }
  final int minutes = int.tryParse(match.group(1) ?? '') ?? 0;
  final int seconds = int.tryParse(match.group(2) ?? '') ?? 0;
  return (minutes * 60) + seconds;
}

String _formatRuntime(int seconds) {
  if (seconds <= 0) {
    return 'Unknown';
  }
  final int minutes = seconds ~/ 60;
  final int remainingSeconds = seconds % 60;
  return '${minutes}m ${remainingSeconds.toString().padLeft(2, '0')}s';
}

String? _spotifyImageUriToUrl(String? imageUriRaw) {
  final String raw = (imageUriRaw ?? '').trim();
  if (raw.isEmpty) {
    return null;
  }
  if (raw.startsWith('http://') || raw.startsWith('https://')) {
    return raw;
  }
  const String prefix = 'spotify:image:';
  if (!raw.startsWith(prefix)) {
    return null;
  }
  final String imageId = raw.substring(prefix.length).trim();
  if (imageId.isEmpty) {
    return null;
  }
  return 'https://i.scdn.co/image/$imageId';
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const TallarinesVerdesApp());
}

class TallarinesVerdesApp extends StatelessWidget {
  const TallarinesVerdesApp({super.key});

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme =
        ColorScheme.fromSeed(
          seedColor: _appPrimary,
          brightness: Brightness.dark,
        ).copyWith(
          primary: _appPrimary,
          onPrimary: const Color(0xFF111111),
          secondary: _appAccent,
          onSecondary: Colors.white,
          surface: _appSurface,
          onSurface: Colors.white,
        );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Tallarines Verdes',
      themeMode: ThemeMode.dark,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _appBackground,
        cardTheme: CardThemeData(
          color: _appSurface.withValues(alpha: 0.95),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
        ),
      ),
      home: const SetlistHomePage(),
    );
  }
}

class RoleAssignment {
  const RoleAssignment({
    required this.id,
    required this.instrument,
    required this.player,
    required this.chartUrl,
  });

  final String id;
  final String instrument;
  final String player;
  final String chartUrl;

  factory RoleAssignment.fromJson(Map<String, dynamic> json) {
    return RoleAssignment(
      id: json['id'] as String? ?? _createId('role'),
      instrument: json['instrument'] as String? ?? '',
      player: json['player'] as String? ?? '',
      chartUrl:
          (json['chartUrl'] as String? ??
                  json['chordsTabUrl'] as String? ??
                  json['link'] as String? ??
                  '')
              .trim(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'instrument': instrument,
      'player': player,
      'chartUrl': chartUrl,
    };
  }
}

class Song {
  const Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.duration,
    required this.key,
    required this.bpm,
    required this.spotifyUrl,
    required this.modifier,
    required this.notes,
    required this.artworkUrl,
    required this.roles,
    this.spotifyTrackId,
    this.spotifyUri,
    this.sourceType = SongSourceType.manual,
    this.sourceImportedAt,
  });

  final String id;
  final String title;
  final String artist;
  final String duration;
  final String key;
  final String bpm;
  final String spotifyUrl;
  final String modifier;
  final String notes;
  final String? artworkUrl;
  final List<RoleAssignment> roles;
  final String? spotifyTrackId;
  final String? spotifyUri;
  final SongSourceType sourceType;
  final String? sourceImportedAt;

  factory Song.fromJson(Map<String, dynamic> json) {
    final List<RoleAssignment> parsedRoles = <RoleAssignment>[];
    final Object? rawRoles = json['roles'];
    if (rawRoles is List) {
      for (final Object? rawRole in rawRoles) {
        final Map<String, dynamic>? roleMap = _asStringKeyedMap(rawRole);
        if (roleMap == null) {
          continue;
        }
        parsedRoles.add(RoleAssignment.fromJson(roleMap));
      }
    }

    return Song(
      id: json['id'] as String? ?? _createId('song'),
      title: json['title'] as String? ?? '',
      artist: json['artist'] as String? ?? '',
      duration: json['duration'] as String? ?? '',
      key: json['key'] as String? ?? '',
      bpm: json['bpm'] as String? ?? '',
      spotifyUrl: json['spotifyUrl'] as String? ?? '',
      modifier: json['modifier'] as String? ?? '',
      notes: json['notes'] as String? ?? '',
      artworkUrl: json['artworkUrl'] as String?,
      roles: parsedRoles,
      spotifyTrackId:
          json['spotifyTrackId'] as String? ??
          _spotifyTrackIdFromUrl(json['spotifyUrl'] as String? ?? ''),
      spotifyUri: json['spotifyUri'] as String?,
      sourceType: SongSourceType.values.firstWhere(
        (SongSourceType value) =>
            value.name == (json['sourceType'] as String? ?? ''),
        orElse: () => SongSourceType.manual,
      ),
      sourceImportedAt: json['sourceImportedAt'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'title': title,
      'artist': artist,
      'duration': duration,
      'key': key,
      'bpm': bpm,
      'spotifyUrl': spotifyUrl,
      'modifier': modifier,
      'notes': notes,
      'artworkUrl': artworkUrl,
      'roles': roles.map((RoleAssignment role) => role.toJson()).toList(),
      'spotifyTrackId': spotifyTrackId,
      'spotifyUri': spotifyUri,
      'sourceType': sourceType.name,
      'sourceImportedAt': sourceImportedAt,
    };
  }
}

class SetlistHomePage extends StatefulWidget {
  const SetlistHomePage({super.key});

  @override
  State<SetlistHomePage> createState() => _SetlistHomePageState();
}

class _ImportMergeResult {
  const _ImportMergeResult({
    required this.addedCount,
    required this.updatedCount,
  });

  final int addedCount;
  final int updatedCount;
  int get totalProcessed => addedCount + updatedCount;
}

class _SetlistHomePageState extends State<SetlistHomePage> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  List<Song> _songs = <Song>[];
  String? _currentSongId;
  int _tabIndex = 1;
  bool _isLoading = true;
  String? _firebaseUserId;
  bool _spotifyAccountConnected = false;
  bool _isLinkingSpotify = false;
  String? _spotifyProfileName;
  String? _spotifyProfileImageUrl;
  bool _spotifyPlayerReady = false;
  bool _isPlayerConnecting = false;
  PlayerState? _spotifyPlayerState;
  String? _spotifyPlayerErrorMessage;
  StreamSubscription<PlayerState>? _spotifyPlayerStateSubscription;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
  _sharedSetlistSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _songsSubscription;
  String? _sharedCurrentSongSpotifyTrackId;
  String? _sharedCurrentSongTitle;
  String? _sharedCurrentSongArtist;

  String? get _spotifySessionId {
    final String trimmed = (_firebaseUserId ?? '').trim();
    if (trimmed.isEmpty) {
      return null;
    }
    return trimmed;
  }

  bool get _supportsSpotifyRemotePlayback {
    if (kIsWeb) {
      return false;
    }
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  Uri _backendUri(
    String path, {
    Map<String, String> queryParameters = const <String, String>{},
  }) {
    return Uri.parse(
      '$_spotifyBackendBaseUrl$path',
    ).replace(queryParameters: queryParameters);
  }

  DocumentReference<Map<String, dynamic>>? get _setlistDoc {
    final String? userId = _firebaseUserId;
    if (userId == null) {
      return null;
    }
    return _firestore
        .collection('users')
        .doc(userId)
        .collection('setlists')
        .doc('main');
  }

  DocumentReference<Map<String, dynamic>> get _sharedSetlistDoc {
    return _firestore.collection('setlists').doc('live');
  }

  CollectionReference<Map<String, dynamic>>? get _songsCollection {
    final DocumentReference<Map<String, dynamic>>? setlistDoc = _setlistDoc;
    if (setlistDoc == null) {
      return null;
    }
    return setlistDoc.collection('songs');
  }

  String? get _resolvedCurrentSongId {
    if (_currentSongId != null &&
        _songs.any((Song song) => song.id == _currentSongId)) {
      return _currentSongId;
    }
    return null;
  }

  Song? _songById(String songId) {
    for (final Song song in _songs) {
      if (song.id == songId) {
        return song;
      }
    }
    return null;
  }

  String? _resolveCurrentSongIdFromSharedRef() {
    final String sharedTrackId = (_sharedCurrentSongSpotifyTrackId ?? '').trim();
    if (sharedTrackId.isNotEmpty) {
      for (final Song song in _songs) {
        if ((song.spotifyTrackId ?? '').trim() == sharedTrackId) {
          return song.id;
        }
      }
    }

    final String sharedTitle = _normalizeForMatch(
      _sharedCurrentSongTitle ?? '',
    );
    final String sharedArtist = _normalizeForMatch(
      _sharedCurrentSongArtist ?? '',
    );
    if (sharedTitle.isEmpty || sharedArtist.isEmpty) {
      return null;
    }

    for (final Song song in _songs) {
      if (_normalizeForMatch(song.title) == sharedTitle &&
          _normalizeForMatch(song.artist) == sharedArtist) {
        return song.id;
      }
    }
    return null;
  }

  void _applySharedCurrentSongRef(Map<String, dynamic>? data) {
    _sharedCurrentSongSpotifyTrackId =
        data?['currentSongSpotifyTrackId'] as String?;
    _sharedCurrentSongTitle = data?['currentSongTitle'] as String?;
    _sharedCurrentSongArtist = data?['currentSongArtist'] as String?;
    _currentSongId = _resolveCurrentSongIdFromSharedRef();
  }

  Song? get _currentSong {
    final String? currentId = _resolvedCurrentSongId;
    if (currentId == null) {
      return null;
    }
    for (final Song song in _songs) {
      if (song.id == currentId) {
        return song;
      }
    }
    return null;
  }

  int get _totalRuntimeSeconds {
    return _songs.fold<int>(
      0,
      (int runningTotal, Song song) =>
          runningTotal + _durationToSeconds(song.duration),
    );
  }

  @override
  void initState() {
    super.initState();
    unawaited(_initializeCloudState());
  }

  @override
  void dispose() {
    unawaited(_spotifyPlayerStateSubscription?.cancel());
    unawaited(_sharedSetlistSubscription?.cancel());
    unawaited(_songsSubscription?.cancel());
    super.dispose();
  }

  Future<void> _initializeCloudState() async {
    try {
      if (_auth.currentUser == null) {
        await _auth.signInAnonymously();
      }
      final User? user = _auth.currentUser;
      if (user == null) {
        throw const FormatException('Could not establish Firebase user');
      }

      _firebaseUserId = user.uid;
      await _syncSpotifyConnectionStatus();
      await _ensureCloudSetlistExists();
      await _ensureSharedSetlistExists();
      await _sharedSetlistSubscription?.cancel();
      await _songsSubscription?.cancel();

      final DocumentReference<Map<String, dynamic>>? setlistDoc = _setlistDoc;
      final CollectionReference<Map<String, dynamic>>? songsCollection =
          _songsCollection;
      if (setlistDoc == null || songsCollection == null) {
        throw const FormatException('Missing Firestore setlist references');
      }

      _sharedSetlistSubscription = _sharedSetlistDoc.snapshots().listen((
        DocumentSnapshot<Map<String, dynamic>> snapshot,
      ) {
        if (!mounted) {
          return;
        }
        setState(() {
          _applySharedCurrentSongRef(snapshot.data());
        });
      });

      _songsSubscription = songsCollection
          .orderBy('position')
          .snapshots()
          .listen(
            (QuerySnapshot<Map<String, dynamic>> snapshot) {
              final List<Song> loadedSongs = snapshot.docs
                  .map((QueryDocumentSnapshot<Map<String, dynamic>> doc) {
                    final Map<String, dynamic> data = doc.data();
                    return Song.fromJson(<String, dynamic>{
                      ...data,
                      'id': doc.id,
                    });
                  })
                  .toList(growable: false);

              if (!mounted) {
                return;
              }
              setState(() {
                _songs = loadedSongs;
                _currentSongId = _resolveCurrentSongIdFromSharedRef();
                _isLoading = false;
              });
            },
            onError: (_) {
              if (!mounted) {
                return;
              }
              setState(() {
                _isLoading = false;
              });
            },
          );
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _syncSpotifyConnectionStatus() async {
    final String? sessionId = _spotifySessionId;
    if (sessionId == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        _spotifyAccountConnected = false;
        _spotifyProfileName = null;
        _spotifyProfileImageUrl = null;
        _spotifyPlayerReady = false;
        _spotifyPlayerState = null;
        _spotifyPlayerErrorMessage = null;
      });
      return;
    }
    final http.Response response = await http.get(
      _backendUri(
        '/spotify/connect/status',
        queryParameters: <String, String>{'sessionId': sessionId},
      ),
      headers: const <String, String>{'Accept': 'application/json'},
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const FormatException('Failed to read Spotify connection status');
    }
    final Map<String, dynamic>? payload = _asStringKeyedMap(
      jsonDecode(response.body),
    );
    final bool connected = payload?['connected'] == true;
    if (!mounted) {
      return;
    }
    setState(() {
      _spotifyAccountConnected = connected;
      if (!connected) {
        _spotifyProfileName = null;
        _spotifyProfileImageUrl = null;
        _spotifyPlayerReady = false;
        _spotifyPlayerState = null;
        _spotifyPlayerErrorMessage = null;
      }
    });
    if (connected) {
      await _loadSpotifyProfile();
    }
  }

  Future<void> _loadSpotifyProfile() async {
    final String? sessionId = _spotifySessionId;
    if (sessionId == null) {
      return;
    }
    final http.Response response = await http.get(
      _backendUri(
        '/spotify/me/profile',
        queryParameters: <String, String>{'sessionId': sessionId},
      ),
      headers: const <String, String>{'Accept': 'application/json'},
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return;
    }
    final Map<String, dynamic>? payload = _asStringKeyedMap(
      jsonDecode(response.body),
    );
    final String displayName = (payload?['displayName'] as String? ?? '')
        .trim();
    final String fallbackName = (payload?['id'] as String? ?? '').trim();
    final Object? rawImageUrl = payload?['imageUrl'];
    final String imageUrlValue = rawImageUrl is String
        ? rawImageUrl.trim()
        : '';
    final String? imageUrl = imageUrlValue.isNotEmpty
        ? imageUrlValue
        : _firstSpotifyImageUrl(payload?['images']);
    if (!mounted) {
      return;
    }
    setState(() {
      _spotifyProfileName = displayName.isNotEmpty ? displayName : fallbackName;
      _spotifyProfileImageUrl = (imageUrl ?? '').isEmpty ? null : imageUrl;
    });
  }

  Future<void> _connectSpotifyAccount() async {
    if (_isLinkingSpotify) {
      return;
    }
    final String? sessionId = _spotifySessionId;
    if (sessionId == null) {
      return;
    }
    setState(() {
      _isLinkingSpotify = true;
    });
    try {
      final http.Response response = await http.get(
        _backendUri(
          '/spotify/connect/start',
          queryParameters: <String, String>{'sessionId': sessionId},
        ),
        headers: const <String, String>{'Accept': 'application/json'},
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const FormatException('Spotify connect start failed');
      }
      final Map<String, dynamic>? payload = _asStringKeyedMap(
        jsonDecode(response.body),
      );
      final String authorizeUrl = (payload?['authorizeUrl'] as String? ?? '')
          .trim();
      if (authorizeUrl.isEmpty) {
        throw const FormatException('Spotify authorize URL missing');
      }
      final bool opened = await launchUrl(
        Uri.parse(authorizeUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) {
        throw const FormatException('Could not open Spotify authorization URL');
      }
      final DateTime start = DateTime.now();
      while (DateTime.now().difference(start).inSeconds < 90) {
        await Future<void>.delayed(const Duration(seconds: 2));
        await _syncSpotifyConnectionStatus();
        if (!mounted) {
          return;
        }
        if (_spotifyAccountConnected) {
          return;
        }
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _spotifyPlayerErrorMessage = 'Spotify connection failed.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLinkingSpotify = false;
        });
      }
    }
  }

  String? _trackIdFromSpotifyUri(String? spotifyUri) {
    return _spotifyTrackIdFromSpotifyUri(spotifyUri);
  }

  List<String> _spotifyUrisForSong(Song song) {
    final Set<String> uris = <String>{};

    void addTrackId(String? rawTrackId) {
      final String trackId = _sanitizeSpotifyTrackId(rawTrackId ?? '');
      if (trackId.isEmpty) {
        return;
      }
      uris.add(_spotifyPlayUriFromTrackId(trackId));
    }

    addTrackId(_spotifyTrackIdFromSpotifyUri(song.spotifyUri));
    addTrackId(song.spotifyTrackId);
    addTrackId(_spotifyTrackIdFromUrl(song.spotifyUrl));
    return uris.toList(growable: false);
  }

  bool _isNotImplementedSpotifySdkError(Object error) {
    if (error is MissingPluginException) {
      return true;
    }
    if (error is PlatformException) {
      final String code = error.code.toLowerCase();
      final String message = (error.message ?? '').toLowerCase();
      return code.contains('notimplemented') ||
          message.contains('not implemented');
    }
    return false;
  }

  String _spotifyPlaybackErrorHint(Object error) {
    if (error is FormatException) {
      final String message = error.message.trim();
      return message.isEmpty ? '' : message;
    }
    if (error is PlatformException) {
      final String code = error.code.trim();
      final String message = (error.message ?? '').trim();
      if (code.isNotEmpty && message.isNotEmpty) {
        return '$code: $message';
      }
      if (message.isNotEmpty) {
        return message;
      }
      if (code.isNotEmpty) {
        return code;
      }
    }
    return '';
  }

  bool _isSpotifyRemoteDisconnectedError(Object error) {
    if (error is! PlatformException) {
      return false;
    }
    final String code = error.code.toLowerCase();
    final String message = (error.message ?? '').toLowerCase();
    return code.contains('notconnected') ||
        code.contains('disconnected') ||
        message.contains('not connected') ||
        message.contains('disconnected');
  }

  Future<void> _switchSpotifyToLocalDeviceIfPossible() async {
    try {
      await SpotifySdk.switchToLocalDevice();
    } catch (_) {}
  }

  bool _playerStateMatchesTargetTrack(PlayerState? state, String spotifyUri) {
    final String? targetTrackId = _spotifyTrackIdFromSpotifyUri(spotifyUri);
    final String? activeTrackId = _trackIdFromSpotifyUri(state?.track?.uri);
    if (targetTrackId == null || activeTrackId == null) {
      return false;
    }
    return targetTrackId == activeTrackId;
  }

  Future<bool> _waitForPlaybackStart(String spotifyUri) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final PlayerState? state = await SpotifySdk.getPlayerState();
        final bool matchesTrack = _playerStateMatchesTargetTrack(
          state,
          spotifyUri,
        );
        final bool isPlaying = !(state?.isPaused ?? true);
        if (matchesTrack && isPlaying) {
          if (mounted) {
            setState(() {
              _spotifyPlayerState = state;
            });
          }
          return true;
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return false;
  }

  Future<void> _playSpotifyUriWithReconnect(String spotifyUri) async {
    Future<void> playSequence() async {
      await _switchSpotifyToLocalDeviceIfPossible();
      await SpotifySdk.play(spotifyUri: spotifyUri);
      bool started = await _waitForPlaybackStart(spotifyUri);
      if (started) {
        return;
      }

      await _switchSpotifyToLocalDeviceIfPossible();
      await SpotifySdk.play(spotifyUri: spotifyUri);
      started = await _waitForPlaybackStart(spotifyUri);
      if (started) {
        return;
      }

      try {
        await SpotifySdk.resume();
      } catch (_) {}
      started = await _waitForPlaybackStart(spotifyUri);
      if (!started) {
        throw const FormatException(
          'Spotify acknowledged play request but playback did not start.',
        );
      }
    }

    try {
      await playSequence();
    } catch (error) {
      if (!_isSpotifyRemoteDisconnectedError(error)) {
        rethrow;
      }
      if (!mounted) {
        rethrow;
      }
      setState(() {
        _spotifyPlayerReady = false;
        _spotifyPlayerState = null;
      });
      await _ensureSpotifyPlayerConnected();
      await playSequence();
    }
  }

  Future<bool> _openSongInSpotifyApp(Song song) async {
    final String sanitizedTrackId = _sanitizeSpotifyTrackId(
      song.spotifyTrackId ?? '',
    );
    final String? trackId =
        _spotifyTrackIdFromSpotifyUri(song.spotifyUri) ??
        (sanitizedTrackId.isEmpty ? null : sanitizedTrackId) ??
        _spotifyTrackIdFromUrl(song.spotifyUrl);
    if (trackId == null || trackId.isEmpty) {
      return false;
    }
    final Uri appUri = Uri.parse(_spotifyPlayUriFromTrackId(trackId));
    final Uri webUri = Uri.https('open.spotify.com', '/track/$trackId');
    try {
      if (await launchUrl(appUri, mode: LaunchMode.externalApplication)) {
        return true;
      }
    } catch (_) {}
    try {
      if (await launchUrl(webUri, mode: LaunchMode.externalApplication)) {
        return true;
      }
    } catch (_) {}
    return false;
  }

  Future<_SpotifyPlaybackToken> _fetchSpotifyPlaybackToken() async {
    final String? sessionId = _spotifySessionId;
    if (sessionId == null) {
      throw const FormatException('Missing Spotify session ID');
    }
    final http.Response response = await http.get(
      _backendUri(
        '/spotify/connect/access-token',
        queryParameters: <String, String>{'sessionId': sessionId},
      ),
      headers: const <String, String>{'Accept': 'application/json'},
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const FormatException('Failed to fetch Spotify playback token');
    }
    final Map<String, dynamic>? payload = _asStringKeyedMap(
      jsonDecode(response.body),
    );
    if (payload == null) {
      throw const FormatException('Spotify playback token payload missing');
    }
    final _SpotifyPlaybackToken token = _SpotifyPlaybackToken.fromJson(payload);
    if (token.accessToken.isEmpty ||
        token.clientId.isEmpty ||
        token.redirectUri.isEmpty) {
      throw const FormatException('Spotify playback token response incomplete');
    }
    return token;
  }

  Future<void> _authorizeSpotifyRemoteClient(
    _SpotifyPlaybackToken token,
  ) async {
    await SpotifySdk.getAccessToken(
      clientId: token.clientId,
      redirectUrl: token.redirectUri,
      scope: _spotifyRemoteAuthScope,
    );
  }

  Future<void> _connectSpotifyRemoteAndSubscribe(
    _SpotifyPlaybackToken token,
  ) async {
    final bool connected = await SpotifySdk.connectToSpotifyRemote(
      clientId: token.clientId,
      redirectUrl: token.redirectUri,
      accessToken: token.accessToken,
    );
    if (!connected) {
      throw const FormatException('Could not connect to Spotify remote');
    }
    await _switchSpotifyToLocalDeviceIfPossible();
    await _spotifyPlayerStateSubscription?.cancel();
    _spotifyPlayerStateSubscription = SpotifySdk.subscribePlayerState().listen(
      (PlayerState state) {
        if (!mounted) {
          return;
        }
        setState(() {
          _spotifyPlayerState = state;
          _spotifyPlayerReady = true;
        });
      },
      onError: (Object _) {
        if (!mounted) {
          return;
        }
        setState(() {
          _spotifyPlayerReady = false;
          _spotifyPlayerState = null;
        });
      },
    );
    final PlayerState? state = await SpotifySdk.getPlayerState();
    if (!mounted) {
      return;
    }
    setState(() {
      _spotifyPlayerReady = true;
      _spotifyPlayerState = state;
    });
  }

  Future<void> _ensureSpotifyPlayerConnected() async {
    if (_spotifyPlayerReady || _isPlayerConnecting) {
      return;
    }
    if (!_supportsSpotifyRemotePlayback) {
      throw MissingPluginException('Spotify SDK remote playback unavailable');
    }
    setState(() {
      _isPlayerConnecting = true;
      _spotifyPlayerErrorMessage = null;
    });
    try {
      final _SpotifyPlaybackToken token = await _fetchSpotifyPlaybackToken();
      try {
        await _connectSpotifyRemoteAndSubscribe(token);
      } on PlatformException catch (error) {
        if (error.code != 'UserNotAuthorizedException') {
          rethrow;
        }
        await _authorizeSpotifyRemoteClient(token);
        await _connectSpotifyRemoteAndSubscribe(token);
      }
    } on MissingPluginException {
      if (!mounted) {
        return;
      }
      setState(() {
        _spotifyPlayerReady = false;
        _spotifyPlayerState = null;
        _spotifyPlayerErrorMessage =
            'In-app Spotify playback is not available on this platform.';
      });
      rethrow;
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _spotifyPlayerReady = false;
        _spotifyPlayerState = null;
        _spotifyPlayerErrorMessage = _isNotImplementedSpotifySdkError(error)
            ? 'In-app Spotify playback is not available on this build.'
            : error.code == 'UserNotAuthorizedException'
            ? 'Spotify authorization required. Approve this app in Spotify and try again.'
            : 'Spotify playback unavailable. Reconnect Spotify and ensure Spotify app is open.';
      });
      rethrow;
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _spotifyPlayerReady = false;
        _spotifyPlayerState = null;
        _spotifyPlayerErrorMessage =
            'Spotify playback unavailable. Reconnect Spotify and ensure Spotify app is open.';
      });
      rethrow;
    } finally {
      if (mounted) {
        setState(() {
          _isPlayerConnecting = false;
        });
      }
    }
  }

  Future<void> _playSongInMiniPlayer(Song song) async {
    final List<String> playableUris = _spotifyUrisForSong(song);
    if (playableUris.isEmpty) {
      setState(() {
        _spotifyPlayerErrorMessage = 'Song has no playable Spotify track id.';
      });
      return;
    }
    if (!_supportsSpotifyRemotePlayback) {
      final bool openedInSpotifyApp = await _openSongInSpotifyApp(song);
      if (!mounted) {
        return;
      }
      setState(() {
        _spotifyPlayerErrorMessage = openedInSpotifyApp
            ? 'In-app playback is unavailable here, opened song in Spotify app.'
            : 'In-app Spotify playback is unavailable on this platform.';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            openedInSpotifyApp
                ? 'Opened song in Spotify app.'
                : 'In-app Spotify playback is unavailable on this platform.',
          ),
        ),
      );
      return;
    }
    try {
      await _ensureSpotifyPlayerConnected();
      Object? lastError;
      bool played = false;
      for (final String spotifyUri in playableUris) {
        try {
          await _playSpotifyUriWithReconnect(spotifyUri);
          played = true;
          break;
        } catch (error) {
          lastError = error;
        }
      }
      if (!played) {
        if (lastError != null) {
          throw lastError;
        }
        throw const FormatException('No playable Spotify URI.');
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _spotifyPlayerErrorMessage = null;
      });
    } catch (error) {
      final bool openedInSpotifyApp = await _openSongInSpotifyApp(song);
      final String errorHint = _spotifyPlaybackErrorHint(error);
      if (!mounted) {
        return;
      }
      setState(() {
        _spotifyPlayerErrorMessage = _isNotImplementedSpotifySdkError(error)
            ? 'In-app Spotify playback is unavailable in this build.'
            : openedInSpotifyApp
            ? 'In-app playback failed, opened the song in Spotify instead.'
            : errorHint.isEmpty
            ? 'Could not start Spotify playback. Keep Spotify app open and reconnect.'
            : 'Could not start Spotify playback ($errorHint).';
      });
    }
  }

  Future<void> _ensureCloudSetlistExists() async {
    final DocumentReference<Map<String, dynamic>>? setlistDoc = _setlistDoc;
    if (setlistDoc == null) {
      return;
    }
    final DocumentSnapshot<Map<String, dynamic>> snapshot = await setlistDoc
        .get();
    if (snapshot.exists) {
      return;
    }
    await setlistDoc.set(<String, dynamic>{
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> _ensureSharedSetlistExists() async {
    final DocumentSnapshot<Map<String, dynamic>> snapshot =
        await _sharedSetlistDoc.get();
    if (snapshot.exists) {
      return;
    }
    await _sharedSetlistDoc.set(<String, dynamic>{
      'currentSongSpotifyTrackId': null,
      'currentSongTitle': null,
      'currentSongArtist': null,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> _updateSharedCurrentSong(Song? song) async {
    if (song == null) {
      await _sharedSetlistDoc.set(<String, dynamic>{
        'currentSongSpotifyTrackId': null,
        'currentSongTitle': null,
        'currentSongArtist': null,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      return;
    }

    final String spotifyTrackId = (song.spotifyTrackId ?? '').trim();
    await _sharedSetlistDoc.set(<String, dynamic>{
      'currentSongSpotifyTrackId': spotifyTrackId.isEmpty
          ? null
          : spotifyTrackId,
      'currentSongTitle': song.title.trim(),
      'currentSongArtist': song.artist.trim(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> _replaceCloudSongs(List<Song> songs) async {
    final CollectionReference<Map<String, dynamic>>? songsCollection =
        _songsCollection;
    if (songsCollection == null) {
      return;
    }

    final QuerySnapshot<Map<String, dynamic>> existingSongsSnapshot =
        await songsCollection.get();
    final Set<String> nextSongIds = songs.map((Song song) => song.id).toSet();

    final WriteBatch batch = _firestore.batch();
    for (final QueryDocumentSnapshot<Map<String, dynamic>> existingSong
        in existingSongsSnapshot.docs) {
      if (!nextSongIds.contains(existingSong.id)) {
        batch.delete(existingSong.reference);
      }
    }

    for (int i = 0; i < songs.length; i += 1) {
      final Song song = songs[i];
      batch.set(songsCollection.doc(song.id), <String, dynamic>{
        ...song.toJson(),
        'position': i,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }

    await batch.commit();
  }

  void _setCurrentSong(String songId) {
    final Song? song = _songById(songId);
    if (song == null) {
      return;
    }
    setState(() {
      _sharedCurrentSongSpotifyTrackId = (song.spotifyTrackId ?? '').trim().isEmpty
          ? null
          : song.spotifyTrackId?.trim();
      _sharedCurrentSongTitle = song.title.trim();
      _sharedCurrentSongArtist = song.artist.trim();
      _currentSongId = song.id;
    });
    unawaited(_updateSharedCurrentSong(song));
  }

  Future<void> _confirmSetCurrentSong(String songId) async {
    final Song? song = _songById(songId);
    if (song == null) {
      return;
    }
    if (song.id == _resolvedCurrentSongId) {
      return;
    }

    final bool confirmed =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              backgroundColor: _appSurfaceStrong,
              title: const Center(
                child: Text('Set current song?'),
              ),
              actionsAlignment: MainAxisAlignment.center,
              actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('No'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  style: FilledButton.styleFrom(
                    backgroundColor: _appPrimary,
                    foregroundColor: const Color(0xFF171717),
                  ),
                  child: const Text('Yes'),
                ),
              ],
            );
          },
        ) ??
        false;
    if (!confirmed || !mounted) {
      return;
    }
    _setCurrentSong(songId);
  }

  int _findSongMatchIndex(Song incomingSong) {
    final String incomingTrackId = incomingSong.spotifyTrackId?.trim() ?? '';
    if (incomingTrackId.isNotEmpty) {
      return _songs.indexWhere((Song existingSong) {
        return (existingSong.spotifyTrackId?.trim() ?? '') == incomingTrackId;
      });
    }

    final String incomingTitle = _normalizeForMatch(incomingSong.title);
    final String incomingArtist = _normalizeForMatch(incomingSong.artist);
    if (incomingTitle.isEmpty || incomingArtist.isEmpty) {
      return -1;
    }

    return _songs.indexWhere((Song existingSong) {
      return _normalizeForMatch(existingSong.title) == incomingTitle &&
          _normalizeForMatch(existingSong.artist) == incomingArtist;
    });
  }

  _ImportMergeResult _upsertImportedSongs(List<Song> importedSongs) {
    if (importedSongs.isEmpty) {
      return const _ImportMergeResult(addedCount: 0, updatedCount: 0);
    }

    final List<Song> nextSongs = List<Song>.from(_songs);
    int addedCount = 0;
    int updatedCount = 0;

    for (final Song song in importedSongs) {
      final int existingIndex = _findSongMatchIndex(song);
      if (existingIndex < 0) {
        nextSongs.add(song);
        addedCount += 1;
        continue;
      }

      final Song existingSong = nextSongs[existingIndex];
      final Song mergedSong = Song(
        id: existingSong.id,
        title: song.title.trim().isEmpty
            ? existingSong.title
            : song.title.trim(),
        artist: song.artist.trim().isEmpty
            ? existingSong.artist
            : song.artist.trim(),
        duration: song.duration.trim().isEmpty
            ? existingSong.duration
            : song.duration.trim(),
        key: existingSong.key,
        bpm: existingSong.bpm,
        spotifyUrl: song.spotifyUrl.trim().isEmpty
            ? existingSong.spotifyUrl
            : song.spotifyUrl.trim(),
        modifier: song.modifier.trim().isEmpty
            ? existingSong.modifier
            : song.modifier.trim(),
        notes: existingSong.notes,
        artworkUrl: song.artworkUrl ?? existingSong.artworkUrl,
        roles: existingSong.roles,
        spotifyTrackId: song.spotifyTrackId ?? existingSong.spotifyTrackId,
        spotifyUri: song.spotifyUri ?? existingSong.spotifyUri,
        sourceType: song.sourceType,
        sourceImportedAt:
            song.sourceImportedAt ?? existingSong.sourceImportedAt,
      );
      nextSongs[existingIndex] = mergedSong;
      updatedCount += 1;
    }

    setState(() {
      _songs = nextSongs;
      _tabIndex = 1;
    });
    unawaited(_replaceCloudSongs(nextSongs));
    return _ImportMergeResult(
      addedCount: addedCount,
      updatedCount: updatedCount,
    );
  }

  void _reorderSongs(int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        newIndex < 0 ||
        oldIndex >= _songs.length ||
        newIndex >= _songs.length) {
      return;
    }
    final List<Song> nextSongs = List<Song>.from(_songs);
    final Song movedSong = nextSongs.removeAt(oldIndex);
    nextSongs.insert(newIndex, movedSong);
    setState(() {
      _songs = nextSongs;
    });
    unawaited(_replaceCloudSongs(nextSongs));
  }

  void _removeSong(String songId) {
    final int indexToRemove = _songs.indexWhere(
      (Song song) => song.id == songId,
    );
    if (indexToRemove < 0) {
      return;
    }

    final String? currentId = _resolvedCurrentSongId;
    final bool removedCurrentSong = currentId == songId;
    final List<Song> nextSongs = _songs
        .where((Song song) => song.id != songId)
        .toList(growable: false);

    Song? nextCurrentSong;
    if (nextSongs.isEmpty) {
      nextCurrentSong = null;
    } else if (removedCurrentSong) {
      final int fallbackIndex = min(indexToRemove, nextSongs.length - 1);
      nextCurrentSong = nextSongs[fallbackIndex];
    }

    setState(() {
      _songs = nextSongs;
      if (removedCurrentSong) {
        if (nextCurrentSong == null) {
          _sharedCurrentSongSpotifyTrackId = null;
          _sharedCurrentSongTitle = null;
          _sharedCurrentSongArtist = null;
          _currentSongId = null;
        } else {
          _sharedCurrentSongSpotifyTrackId =
              (nextCurrentSong.spotifyTrackId ?? '').trim().isEmpty
              ? null
              : nextCurrentSong.spotifyTrackId?.trim();
          _sharedCurrentSongTitle = nextCurrentSong.title.trim();
          _sharedCurrentSongArtist = nextCurrentSong.artist.trim();
          _currentSongId = nextCurrentSong.id;
        }
      }
    });
    unawaited(_replaceCloudSongs(nextSongs));
    if (removedCurrentSong) {
      unawaited(_updateSharedCurrentSong(nextCurrentSong));
    }
  }

  Future<void> _editSong(Song song) async {
    final Song? editedSong = await Navigator.of(context).push<Song>(
      MaterialPageRoute<Song>(
        fullscreenDialog: true,
        builder: (BuildContext context) => _EditSongPage(song: song),
      ),
    );
    if (editedSong == null) {
      return;
    }
    final int songIndex = _songs.indexWhere((Song item) => item.id == song.id);
    if (songIndex < 0) {
      return;
    }
    final List<Song> nextSongs = List<Song>.from(_songs);
    nextSongs[songIndex] = editedSong;
    setState(() {
      _songs = nextSongs;
      _currentSongId = _resolveCurrentSongIdFromSharedRef();
    });
    unawaited(_replaceCloudSongs(nextSongs));
  }

  void _stepCurrentSong(int delta) {
    final String? currentId = _resolvedCurrentSongId;
    if (currentId == null || _songs.isEmpty) {
      return;
    }

    final int index = _songs.indexWhere((Song song) => song.id == currentId);
    if (index < 0) {
      return;
    }

    final int nextIndex = (index + delta + _songs.length) % _songs.length;
    if (nextIndex == index) {
      return;
    }
    _setCurrentSong(_songs[nextIndex].id);
  }

  Song? _adjacentSong(int delta) {
    final String? currentId = _resolvedCurrentSongId;
    if (currentId == null || _songs.isEmpty) {
      return null;
    }

    final int index = _songs.indexWhere((Song song) => song.id == currentId);
    if (index < 0) {
      return null;
    }

    final int adjacentIndex = (index + delta + _songs.length) % _songs.length;
    if (adjacentIndex == index) {
      return null;
    }
    return _songs[adjacentIndex];
  }

  Future<void> _showSongPickerModal() async {
    if (_songs.isEmpty) {
      return;
    }

    final String? selectedSongId = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _appSurfaceStrong,
      showDragHandle: true,
      builder: (BuildContext context) {
        final String? activeSongId = _resolvedCurrentSongId;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Select current song',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _songs.length,
                  itemBuilder: (BuildContext context, int index) {
                    final Song song = _songs[index];
                    final bool isActive = song.id == activeSongId;
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: isActive
                            ? _appPrimary.withValues(alpha: 0.3)
                            : _appAccent.withValues(alpha: 0.5),
                        child: Text(
                          '${index + 1}',
                          style: TextStyle(
                            color: isActive ? Colors.black : Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      title: Text(song.title),
                      subtitle: Text(song.artist),
                      trailing: isActive
                          ? const Icon(
                              Icons.equalizer_rounded,
                              color: _appPrimary,
                            )
                          : null,
                      onTap: () {
                        Navigator.of(context).pop(song.id);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );

    if (selectedSongId == null) {
      return;
    }
    await _confirmSetCurrentSong(selectedSongId);
  }

  void _selectBottomAction(int index) {
    if (_tabIndex == index) {
      return;
    }
    setState(() {
      _tabIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: _StartupSplash(),
      );
    }

    final Widget? topBarTrailing = _spotifyAccountConnected
        ? null
        : (_spotifySessionId == null
              ? const _TopStatusTag(
                  text: 'Preparing account',
                  icon: Icons.hourglass_top_rounded,
                )
              : FilledButton.tonalIcon(
                  onPressed: _isLinkingSpotify ? null : _connectSpotifyAccount,
                  icon: _isLinkingSpotify
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.link_rounded),
                  label: Text(
                    _isLinkingSpotify ? 'Connecting...' : 'Connect Spotify',
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: _appPrimary,
                    foregroundColor: const Color(0xFF161616),
                  ),
                ));
    final Widget bodyContent;
    if (_tabIndex == 0) {
      bodyContent = _SongImporterPage(
        onSongsImported: _upsertImportedSongs,
        spotifySessionId: _spotifySessionId,
        spotifyAccountConnected: _spotifyAccountConnected,
      );
    } else if (_tabIndex == 1) {
      bodyContent = SetlistPage(
        songs: _songs,
        currentSong: _currentSong,
        totalRuntime: _formatRuntime(_totalRuntimeSeconds),
        spotifyAccountConnected: _spotifyAccountConnected,
        supportsSpotifyRemotePlayback: _supportsSpotifyRemotePlayback,
        onSelectSong: _confirmSetCurrentSong,
        onRemoveSong: _removeSong,
        onEditSong: _editSong,
        onPlaySpotify: _playSongInMiniPlayer,
        onReorderSongs: _reorderSongs,
      );
    } else {
      bodyContent = _CurrentSongPage(
        currentSong: _currentSong,
        previousSong: _adjacentSong(-1),
        nextSong: _adjacentSong(1),
        onPreviousSong: () => _stepCurrentSong(-1),
        onNextSong: () => _stepCurrentSong(1),
        onPlaySpotify: _playSongInMiniPlayer,
        onOpenSongPicker: _showSongPickerModal,
        onEditSong: _editSong,
      );
    }

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topCenter,
            radius: 1.1,
            colors: <Color>[
              Color(0x883F1A63),
              Color(0xFF151126),
              _appBackground,
            ],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
                child: _TopStatusBar(
                  title: 'Tallarines Verdes',
                  subtitle:
                      _spotifyAccountConnected &&
                          (_spotifyProfileName ?? '').trim().isNotEmpty
                      ? _spotifyProfileName!.trim()
                      : 'Band setlist companion',
                  imageUrl: _spotifyAccountConnected
                      ? _spotifyProfileImageUrl
                      : null,
                  trailing: topBarTrailing,
                ),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  layoutBuilder:
                      (Widget? currentChild, List<Widget> previousChildren) {
                        return Stack(
                          fit: StackFit.expand,
                          alignment: Alignment.topCenter,
                          children: <Widget>[
                            ...previousChildren,
                            if (currentChild != null) currentChild,
                          ],
                        );
                      },
                  child: bodyContent,
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (_currentSong != null)
              _CurrentSongBar(
                song: _currentSong!,
                playerState: _spotifyPlayerState,
                isConnecting: _isPlayerConnecting,
                errorMessage: _spotifyPlayerErrorMessage,
                onPressed: () => _selectBottomAction(2),
              ),
            _BottomActionBar(
              activeIndex: _tabIndex,
              onActionPressed: _selectBottomAction,
              margin: EdgeInsets.fromLTRB(
                14,
                _currentSong == null ? 8 : 0,
                14,
                12,
              ),
              showCurrentSongConnector: _currentSong != null,
              highlightCurrentSongAction: _currentSong != null,
            ),
          ],
        ),
      ),
    );
  }
}

class _StartupSplash extends StatelessWidget {
  const _StartupSplash();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Image(
        image: AssetImage('assets/splash/splash_icon.png'),
        width: 168,
        height: 168,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      ),
    );
  }
}

class SetlistPage extends StatefulWidget {
  const SetlistPage({
    super.key,
    required this.songs,
    required this.currentSong,
    required this.totalRuntime,
    required this.spotifyAccountConnected,
    required this.supportsSpotifyRemotePlayback,
    required this.onSelectSong,
    required this.onRemoveSong,
    required this.onEditSong,
    required this.onPlaySpotify,
    required this.onReorderSongs,
  });

  final List<Song> songs;
  final Song? currentSong;
  final String totalRuntime;
  final bool spotifyAccountConnected;
  final bool supportsSpotifyRemotePlayback;
  final Future<void> Function(String songId) onSelectSong;
  final ValueChanged<String> onRemoveSong;
  final ValueChanged<Song> onEditSong;
  final Future<void> Function(Song song) onPlaySpotify;
  final void Function(int oldIndex, int newIndex) onReorderSongs;

  @override
  State<SetlistPage> createState() => _SetlistPageState();
}

class _SetlistPageState extends State<SetlistPage> {
  String? _expandedSongId;

  @override
  void didUpdateWidget(covariant SetlistPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_expandedSongId != null &&
        !widget.songs.any((Song song) => song.id == _expandedSongId)) {
      _expandedSongId = null;
    }
  }

  void _toggleExpandedSong(String songId) {
    setState(() {
      _expandedSongId = _expandedSongId == songId ? null : songId;
    });
  }

  void _playSongFromCard(Song song) {
    unawaited(widget.onPlaySpotify(song));
  }

  void _handleReorderItem(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) {
      return;
    }
    widget.onReorderSongs(oldIndex, newIndex);
  }

  Widget _buildExpandedDetails(Song song, bool isCurrent) {
    final bool hasPlayableTrack = _songHasPlayableSpotifyTrack(song);
    final bool canAttemptInAppPlayback =
        hasPlayableTrack &&
        widget.spotifyAccountConnected &&
        widget.supportsSpotifyRemotePlayback;
    final String playLabel = !hasPlayableTrack
        ? 'No track'
        : canAttemptInAppPlayback
        ? 'Play'
        : widget.supportsSpotifyRemotePlayback
        ? 'Connect'
        : 'Open';
    final IconData playIcon = !hasPlayableTrack
        ? Icons.music_off_rounded
        : canAttemptInAppPlayback
        ? Icons.play_arrow_rounded
        : widget.supportsSpotifyRemotePlayback
        ? Icons.link_rounded
        : Icons.open_in_new_rounded;
    final VoidCallback? playAction = hasPlayableTrack
        ? () => _playSongFromCard(song)
        : null;
    final List<String> quickFacts = <String>[
      if (song.key.trim().isNotEmpty) 'Key ${song.key.trim()}',
      if (song.bpm.trim().isNotEmpty) '${song.bpm.trim()} BPM',
    ];
    final bool hasExtraDetails =
        quickFacts.isNotEmpty ||
        song.modifier.trim().isNotEmpty ||
        song.roles.isNotEmpty ||
        song.notes.trim().isNotEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            decoration: BoxDecoration(
              color: _appSurface.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Row(
              children: <Widget>[
                _SetlistActionBarButton(
                  icon: isCurrent
                      ? Icons.equalizer_rounded
                      : Icons.radio_button_unchecked_rounded,
                  label: isCurrent ? 'Current' : 'Set current',
                  highlighted: isCurrent,
                  onPressed: () => unawaited(widget.onSelectSong(song.id)),
                ),
                _SetlistActionBarButton(
                  icon: playIcon,
                  label: playLabel,
                  highlighted: hasPlayableTrack,
                  onPressed: playAction,
                ),
                _SetlistActionBarButton(
                  icon: Icons.edit_rounded,
                  label: 'Edit',
                  onPressed: () => widget.onEditSong(song),
                ),
                _SetlistActionBarButton(
                  icon: Icons.delete_outline_rounded,
                  label: 'Remove',
                  danger: true,
                  onPressed: () => widget.onRemoveSong(song.id),
                ),
              ],
            ),
          ),
          if (!hasExtraDetails) ...<Widget>[
            const SizedBox(height: 10),
            const Text(
              'No additional details yet.',
              style: TextStyle(color: _appMutedText, fontSize: 12),
            ),
          ] else ...<Widget>[
            if (quickFacts.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: quickFacts.map((String label) {
                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontSize: 11,
                        color: _appMutedText,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
            if (song.modifier.trim().isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              const Text(
                'Modifier',
                style: TextStyle(
                  color: _appMutedText,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                song.modifier.trim(),
                style: const TextStyle(fontSize: 13, height: 1.35),
              ),
            ],
            if (song.roles.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              const Text(
                'Instrument roles',
                style: TextStyle(
                  color: _appMutedText,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 4),
              ...song.roles.asMap().entries.map((
                MapEntry<int, RoleAssignment> entry,
              ) {
                final RoleAssignment role = entry.value;
                final String roleLabel = [role.instrument, role.player]
                    .map((String value) => value.trim())
                    .where((String value) => value.isNotEmpty)
                    .join(' • ');
                final bool hasChartLink =
                    _parseExternalHttpUri(role.chartUrl) != null;
                return Padding(
                  padding: EdgeInsets.only(
                    bottom: entry.key == song.roles.length - 1 ? 0 : 4,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          roleLabel.isEmpty ? 'Unnamed role' : roleLabel,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      if (hasChartLink)
                        TextButton.icon(
                          onPressed: () {
                            unawaited(
                              _openExternalLink(
                                context,
                                role.chartUrl,
                                failureMessage:
                                    'Could not open chords/tab link.',
                              ),
                            );
                          },
                          style: TextButton.styleFrom(
                            foregroundColor: _appPrimary,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 0,
                            ),
                            minimumSize: const Size(0, 28),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          icon: const Icon(Icons.link_rounded, size: 14),
                          label: const Text('Chords/tab'),
                        ),
                    ],
                  ),
                );
              }),
            ],
            if (song.notes.trim().isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              const Text(
                'Notes',
                style: TextStyle(
                  color: _appMutedText,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                song.notes.trim(),
                style: const TextStyle(
                  color: _appMutedText,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildSongCard({
    required Key key,
    required int index,
    required Song song,
    required bool isCurrent,
    required bool isExpanded,
  }) {
    final List<String> metadataLabels = <String>[
      if (song.key.trim().isNotEmpty) 'Key ${song.key.trim()}',
      if (song.bpm.trim().isNotEmpty) '${song.bpm.trim()} BPM',
    ];

    return Padding(
      key: key,
      padding: EdgeInsets.only(
        bottom: index == widget.songs.length - 1 ? 0 : 10,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: isCurrent
              ? _appAccent.withValues(alpha: 0.3)
              : _appSurfaceStrong.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isCurrent
                ? _appPrimary.withValues(alpha: 0.6)
                : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Column(
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                ReorderableDragStartListener(
                  index: index,
                  child: const Padding(
                    padding: EdgeInsets.fromLTRB(6, 10, 0, 10),
                    child: Icon(
                      Icons.drag_handle_rounded,
                      color: _appMutedText,
                    ),
                  ),
                ),
                Expanded(
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _playSongFromCard(song),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(0, 10, 0, 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: <Widget>[
                            _SongArtworkThumbnail(
                              artworkUrl: song.artworkUrl,
                              isCurrent: isCurrent,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    song.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 15,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    song.artist,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: _appMutedText,
                                      fontSize: 13,
                                    ),
                                  ),
                                  if (metadataLabels.isNotEmpty) ...<Widget>[
                                    const SizedBox(height: 5),
                                    Text(
                                      metadataLabels.join(' • '),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: _appMutedText,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => _toggleExpandedSong(song.id),
                  tooltip: isExpanded ? 'Hide details' : 'Show details',
                  icon: Icon(
                    isExpanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: isCurrent ? _appPrimary : _appMutedText,
                  ),
                ),
              ],
            ),
            AnimatedCrossFade(
              firstChild: const SizedBox.shrink(),
              secondChild: _buildExpandedDetails(song, isCurrent),
              crossFadeState: isExpanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 180),
              sizeCurve: Curves.easeInOut,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const _PageTitleHeading(text: 'Setlist'),
              const SizedBox(height: 6),
              Text(
                'Songs ${widget.songs.length} • Runtime ${widget.totalRuntime}',
                style: const TextStyle(color: _appMutedText, fontSize: 13),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: Card(
              clipBehavior: Clip.antiAlias,
              margin: EdgeInsets.zero,
              child: widget.songs.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No songs yet. Use Importer to add one.',
                          style: TextStyle(color: _appMutedText),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 84),
                      itemCount: widget.songs.length,
                      onReorderItem: _handleReorderItem,
                      proxyDecorator:
                          (Widget child, int index, Animation<double> animation) {
                            return Material(
                              color: Colors.transparent,
                              elevation: 6,
                              shadowColor: Colors.black.withValues(alpha: 0.35),
                              borderRadius: BorderRadius.circular(16),
                              child: child,
                            );
                          },
                      itemBuilder: (BuildContext context, int index) {
                        final Song song = widget.songs[index];
                        final bool isCurrent =
                            widget.currentSong?.id == song.id;
                        final bool isExpanded = _expandedSongId == song.id;
                        return _buildSongCard(
                          key: ValueKey<String>(song.id),
                          index: index,
                          song: song,
                          isCurrent: isCurrent,
                          isExpanded: isExpanded,
                        );
                      },
                    ),
            ),
          ),
        ),
      ],
    );
  }
}

class _AdjacentSongButton extends StatelessWidget {
  const _AdjacentSongButton({
    required this.directionLabel,
    required this.song,
    required this.icon,
    required this.onPressed,
  });

  final String directionLabel;
  final Song? song;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final bool isEnabled = song != null;
    return OutlinedButton(
      onPressed: isEnabled ? onPressed : null,
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        disabledForegroundColor: _appMutedText.withValues(alpha: 0.55),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 18),
              const SizedBox(width: 4),
              Text(
                directionLabel,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (song != null) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              song!.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CurrentSongPage extends StatelessWidget {
  const _CurrentSongPage({
    required this.currentSong,
    required this.previousSong,
    required this.nextSong,
    required this.onPreviousSong,
    required this.onNextSong,
    required this.onPlaySpotify,
    required this.onOpenSongPicker,
    required this.onEditSong,
  });

  final Song? currentSong;
  final Song? previousSong;
  final Song? nextSong;
  final VoidCallback onPreviousSong;
  final VoidCallback onNextSong;
  final Future<void> Function(Song song) onPlaySpotify;
  final Future<void> Function() onOpenSongPicker;
  final ValueChanged<Song> onEditSong;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const _PageTitleHeading(text: 'Current song'),
          const SizedBox(height: 12),
          _SectionCard(
            child: currentSong == null
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 28),
                    child: Center(
                      child: Text(
                        'No current song selected yet.',
                        style: TextStyle(color: _appMutedText),
                      ),
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  currentSong!.title,
                                  style: const TextStyle(
                                    fontSize: 28,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: -0.3,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  currentSong!.artist,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    color: _appMutedText,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (currentSong!.artworkUrl != null)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(14),
                              child: Image.network(
                                currentSong!.artworkUrl!,
                                width: 72,
                                height: 72,
                                fit: BoxFit.cover,
                                errorBuilder:
                                    (
                                      BuildContext context,
                                      Object error,
                                      StackTrace? stackTrace,
                                    ) {
                                      return const SizedBox.shrink();
                                    },
                              ),
                            ),
                        ],
                      ),
                      if (currentSong!.modifier.trim().isNotEmpty) ...<Widget>[
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: _appSurfaceStrong.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.08),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              const Text(
                                'Modifier',
                                style: TextStyle(
                                  color: _appMutedText,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.5,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                currentSong!.modifier.trim(),
                                style: const TextStyle(
                                  fontSize: 13,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      if (currentSong!.roles.isEmpty)
                        const Text(
                          'No instrument roles assigned.',
                          style: TextStyle(color: _appMutedText),
                        )
                      else
                        Column(
                          children: currentSong!.roles.asMap().entries.map((
                            MapEntry<int, RoleAssignment> entry,
                          ) {
                            final RoleAssignment role = entry.value;
                            final bool hasChartLink =
                                _parseExternalHttpUri(role.chartUrl) != null;
                            return Container(
                              width: double.infinity,
                              margin: EdgeInsets.only(
                                bottom:
                                    entry.key == currentSong!.roles.length - 1
                                    ? 0
                                    : 8,
                              ),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: _appSurfaceStrong,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.08),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    '${role.instrument}: ${role.player}',
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                  if (hasChartLink) ...<Widget>[
                                    const SizedBox(height: 4),
                                    TextButton.icon(
                                      onPressed: () {
                                        unawaited(
                                          _openExternalLink(
                                            context,
                                            role.chartUrl,
                                            failureMessage:
                                                'Could not open chords/tab link.',
                                          ),
                                        );
                                      },
                                      style: TextButton.styleFrom(
                                        foregroundColor: _appPrimary,
                                        padding: EdgeInsets.zero,
                                        minimumSize: const Size(0, 30),
                                        alignment: Alignment.centerLeft,
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                      ),
                                      icon: const Icon(
                                        Icons.link_rounded,
                                        size: 16,
                                      ),
                                      label: const Text('Open chords/tab link'),
                                    ),
                                  ],
                                ],
                              ),
                            );
                          }).toList(),
                        ),
                      if (currentSong!.notes.trim().isNotEmpty) ...<Widget>[
                        const SizedBox(height: 12),
                        Text(
                          currentSong!.notes.trim(),
                          style: const TextStyle(
                            color: _appMutedText,
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => onEditSong(currentSong!),
                          icon: const Icon(Icons.edit_rounded),
                          label: const Text('Edit song'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: BorderSide(
                              color: Colors.white.withValues(alpha: 0.15),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: _AdjacentSongButton(
                              directionLabel: 'Previous',
                              song: previousSong,
                              icon: Icons.skip_previous_rounded,
                              onPressed: onPreviousSong,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _AdjacentSongButton(
                              directionLabel: 'Next',
                              song: nextSong,
                              icon: Icons.skip_next_rounded,
                              onPressed: onNextSong,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () {
                            unawaited(onOpenSongPicker());
                          },
                          icon: const Icon(Icons.library_music_rounded),
                          label: const Text('Select another song'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: BorderSide(
                              color: Colors.white.withValues(alpha: 0.15),
                            ),
                          ),
                        ),
                      ),
                      if (_songHasPlayableSpotifyTrack(
                        currentSong!,
                      )) ...<Widget>[
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: () => onPlaySpotify(currentSong!),
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: const Text('Play in app'),
                            style: FilledButton.styleFrom(
                              backgroundColor: _appPrimary,
                              foregroundColor: const Color(0xFF171717),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
          const SizedBox(height: 84),
        ],
      ),
    );
  }
}

enum _ImportState { idle, loading, success, error }

enum _ImporterStep { choose, link, account, details }

List<_RoleDraft> _buildPresetEditSongRoleDrafts(List<RoleAssignment> existingRoles) {
  final Map<String, RoleAssignment> rolesByInstrument = <String, RoleAssignment>{};
  final List<RoleAssignment> customRoles = <RoleAssignment>[];

  for (final RoleAssignment role in existingRoles) {
    final String instrument = role.instrument.trim();
    if (_editableInstrumentOptions.contains(instrument)) {
      rolesByInstrument[instrument] = role;
    } else if (instrument.isNotEmpty || role.player.trim().isNotEmpty) {
      customRoles.add(role);
    }
  }

  final List<_RoleDraft> drafts = _editableInstrumentOptions
      .map((String instrument) {
        final RoleAssignment? existing = rolesByInstrument[instrument];
        if (existing != null) {
          return _RoleDraft(
            id: existing.id,
            instrument: instrument,
            player: existing.player,
            chartUrl: existing.chartUrl,
            isPreset: true,
          );
        }
        return _RoleDraft(
          id: _createId('role'),
          instrument: instrument,
          isPreset: true,
        );
      })
      .toList(growable: true);

  for (final RoleAssignment role in customRoles) {
    drafts.add(
      _RoleDraft(
        id: role.id,
        instrument: role.instrument,
        player: role.player,
        chartUrl: role.chartUrl,
      ),
    );
  }

  return drafts;
}

class _RoleDraft {
  _RoleDraft({
    required this.id,
    String instrument = '',
    String player = '',
    String chartUrl = '',
    this.isPreset = false,
  }) : instrumentController = TextEditingController(text: instrument),
       playerController = TextEditingController(text: player),
       chartUrlController = TextEditingController(text: chartUrl);

  final String id;
  final bool isPreset;
  final TextEditingController instrumentController;
  final TextEditingController playerController;
  final TextEditingController chartUrlController;

  void dispose() {
    instrumentController.dispose();
    playerController.dispose();
    chartUrlController.dispose();
  }
}

class _EditSongPage extends StatefulWidget {
  const _EditSongPage({required this.song});

  final Song song;

  @override
  State<_EditSongPage> createState() => _EditSongPageState();
}

class _EditSongPageState extends State<_EditSongPage> {
  late final TextEditingController _notesController;
  late final List<_RoleDraft> _roleDrafts;

  @override
  void initState() {
    super.initState();
    _notesController = TextEditingController(text: widget.song.notes);
    _roleDrafts = _buildPresetEditSongRoleDrafts(widget.song.roles);
  }

  @override
  void dispose() {
    _notesController.dispose();
    for (final _RoleDraft roleDraft in _roleDrafts) {
      roleDraft.dispose();
    }
    super.dispose();
  }

  void _addRoleDraft() {
    setState(() {
      _roleDrafts.add(_RoleDraft(id: _createId('role')));
    });
  }

  void _removeRoleDraft(_RoleDraft roleDraft) {
    if (roleDraft.isPreset) {
      return;
    }
    setState(() {
      _roleDrafts.remove(roleDraft);
      roleDraft.dispose();
    });
  }

  void _save() {
    final String title = widget.song.title.trim();
    final String artist = widget.song.artist.trim();
    if (title.isEmpty || artist.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Song title and artist are required.')),
      );
      return;
    }

    final List<RoleAssignment> roles = <RoleAssignment>[];
    for (final _RoleDraft roleDraft in _roleDrafts) {
      final String instrument = roleDraft.instrumentController.text.trim();
      final String player = roleDraft.playerController.text.trim();
      final String chartUrl = roleDraft.chartUrlController.text.trim();
      if (instrument.isEmpty && player.isEmpty && chartUrl.isEmpty) {
        continue;
      }
      if (instrument.isEmpty || player.isEmpty) {
        continue;
      }
      roles.add(
        RoleAssignment(
          id: roleDraft.id,
          instrument: instrument,
          player: player,
          chartUrl: chartUrl,
        ),
      );
    }

    final Song editedSong = Song(
      id: widget.song.id,
      title: title,
      artist: artist,
      duration: widget.song.duration.trim(),
      key: widget.song.key,
      bpm: widget.song.bpm,
      spotifyUrl: widget.song.spotifyUrl,
      modifier: widget.song.modifier,
      notes: _notesController.text.trim(),
      artworkUrl: widget.song.artworkUrl,
      roles: roles,
      spotifyTrackId: widget.song.spotifyTrackId,
      spotifyUri: widget.song.spotifyUri,
      sourceType: widget.song.sourceType,
      sourceImportedAt: widget.song.sourceImportedAt,
    );
    Navigator.of(context).pop(editedSong);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topCenter,
            radius: 1.1,
            colors: <Color>[
              Color(0x883F1A63),
              Color(0xFF151126),
              _appBackground,
            ],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.arrow_back_rounded),
                      tooltip: 'Back',
                    ),
                    const SizedBox(width: 2),
                    const Expanded(child: _PageTitleHeading(text: 'Edit song')),
                  ],
                ),
                const SizedBox(height: 12),
                _SectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _ReadOnlySongDetailTile(
                        label: 'Song title',
                        value: widget.song.title.trim().isEmpty
                            ? 'Untitled song'
                            : widget.song.title.trim(),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: _ReadOnlySongDetailTile(
                              label: 'Artist',
                              value: widget.song.artist.trim().isEmpty
                                  ? 'Unknown artist'
                                  : widget.song.artist.trim(),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _ReadOnlySongDetailTile(
                              label: 'Duration',
                              value: widget.song.duration.trim().isEmpty
                                  ? 'Unknown'
                                  : widget.song.duration.trim(),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _notesController,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'Notes',
                          alignLabelWithHint: true,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _SectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          const _SectionLabel(text: 'Instrument roles'),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: _addRoleDraft,
                            icon: const Icon(Icons.add),
                            label: const Text('Add role'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      ..._roleDrafts.asMap().entries.map((
                        MapEntry<int, _RoleDraft> entry,
                      ) {
                        final _RoleDraft roleDraft = entry.value;
                        final bool isLastRole =
                            entry.key == _roleDrafts.length - 1;
                        final String instrumentValue = roleDraft
                            .instrumentController
                            .text
                            .trim();
                        final String playerValue = roleDraft
                            .playerController
                            .text
                            .trim();
                        final String? selectedInstrument =
                            _editableInstrumentOptions.contains(instrumentValue)
                            ? instrumentValue
                            : null;
                        final String? selectedPlayer =
                            _editablePlayerOptions.contains(playerValue)
                            ? playerValue
                            : null;
                        return Padding(
                          padding: EdgeInsets.only(bottom: isLastRole ? 0 : 20),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: _appSurface.withValues(alpha: 0.35),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.06),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                  if (roleDraft.isPreset)
                                    SizedBox(
                                      width: 96,
                                      child: _RoleInstrumentLabel(
                                        instrument: instrumentValue,
                                      ),
                                    )
                                  else
                                    Expanded(
                                      flex: 2,
                                      child: DropdownButtonFormField<String>(
                                        isExpanded: true,
                                        initialValue: selectedInstrument,
                                        hint: const Text('Instrument'),
                                        decoration: _rolePillInputDecoration(),
                                        items: _editableInstrumentOptions
                                            .map((String option) {
                                              return DropdownMenuItem<String>(
                                                value: option,
                                                child: Text(
                                                  option,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              );
                                            })
                                            .toList(growable: false),
                                        onChanged: (String? value) {
                                          setState(() {
                                            roleDraft
                                                    .instrumentController
                                                    .text =
                                                value ?? '';
                                          });
                                        },
                                      ),
                                    ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    flex: 3,
                                    child: DropdownButtonFormField<String>(
                                      isExpanded: true,
                                      initialValue: selectedPlayer,
                                      hint: const Text('Select player'),
                                      decoration: _rolePillInputDecoration(),
                                      items: _editablePlayerOptions
                                          .map((String option) {
                                            return DropdownMenuItem<String>(
                                              value: option,
                                              child: Text(
                                                option,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            );
                                          })
                                          .toList(growable: false),
                                      onChanged: (String? value) {
                                        setState(() {
                                          roleDraft.playerController.text =
                                              value ?? '';
                                        });
                                      },
                                    ),
                                  ),
                                  if (!roleDraft.isPreset)
                                    IconButton(
                                      onPressed: () =>
                                          _removeRoleDraft(roleDraft),
                                      icon: const Icon(
                                        Icons.delete_outline_rounded,
                                      ),
                                      tooltip: 'Remove role',
                                    ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: roleDraft.chartUrlController,
                                decoration: _rolePillInputDecoration(
                                  hintText:
                                      'Chords/Tab link (optional)',
                                ),
                              ),
                            ],
                          ),
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              Color(0x00151126),
              Color(0xFF151126),
              _appBackground,
            ],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.check_rounded),
              label: const Text('Save changes'),
              style: FilledButton.styleFrom(
                backgroundColor: _appPrimary,
                foregroundColor: const Color(0xFF131313),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SongImporterPage extends StatefulWidget {
  const _SongImporterPage({
    required this.onSongsImported,
    required this.spotifySessionId,
    required this.spotifyAccountConnected,
  });

  final _ImportMergeResult Function(List<Song> songs) onSongsImported;
  final String? spotifySessionId;
  final bool spotifyAccountConnected;

  @override
  State<_SongImporterPage> createState() => _SongImporterPageState();
}

class _SongImporterPageState extends State<_SongImporterPage> {
  final TextEditingController _spotifyUrlController = TextEditingController();
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _artistController = TextEditingController();
  final TextEditingController _durationController = TextEditingController();
  final TextEditingController _keyController = TextEditingController();
  final TextEditingController _bpmController = TextEditingController();
  final TextEditingController _modifierController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();

  final List<_RoleDraft> _roleDrafts = <_RoleDraft>[
    _RoleDraft(id: _createId('role-draft')),
  ];

  String? _artworkUrl;
  String? _importedSpotifyTrackId;
  String? _importedSpotifyUri;
  SongSourceType _importSourceType = SongSourceType.manual;
  _ImportState _importState = _ImportState.idle;
  _ImporterStep _importerStep = _ImporterStep.choose;
  String _statusMessage = '';
  String? _playlistImportArtworkUrl;
  String? get _spotifySessionId {
    final String trimmed = (widget.spotifySessionId ?? '').trim();
    if (trimmed.isEmpty) {
      return null;
    }
    return trimmed;
  }

  String _requireSpotifySessionId() {
    final String? sessionId = _spotifySessionId;
    if (sessionId == null) {
      throw const FormatException('Missing Spotify session ID');
    }
    return sessionId;
  }

  @override
  void dispose() {
    _spotifyUrlController.dispose();
    _titleController.dispose();
    _artistController.dispose();
    _durationController.dispose();
    _keyController.dispose();
    _bpmController.dispose();
    _modifierController.dispose();
    _notesController.dispose();
    for (final _RoleDraft roleDraft in _roleDrafts) {
      roleDraft.dispose();
    }
    super.dispose();
  }

  void _addRoleDraft() {
    setState(() {
      _roleDrafts.add(_RoleDraft(id: _createId('role-draft')));
    });
  }

  void _removeRoleDraft(_RoleDraft roleDraft) {
    if (_roleDrafts.length <= 1) {
      return;
    }
    setState(() {
      _roleDrafts.remove(roleDraft);
      roleDraft.dispose();
    });
  }

  Uri _backendUri(
    String path, {
    Map<String, String> queryParameters = const <String, String>{},
  }) {
    return Uri.parse(
      '$_spotifyBackendBaseUrl$path',
    ).replace(queryParameters: queryParameters);
  }

  List<Map<String, dynamic>> _extractTrackPayloadsFromAccountPayload(
    Map<String, dynamic>? payload,
  ) {
    final List<Map<String, dynamic>> trackPayloads = <Map<String, dynamic>>[];

    void appendTrackEntries(Object? rawEntries) {
      if (rawEntries is! List) {
        return;
      }
      for (final Object? rawEntry in rawEntries) {
        final Map<String, dynamic>? entry = _asStringKeyedMap(rawEntry);
        if (entry == null) {
          continue;
        }
        trackPayloads.add(entry);
      }
    }

    appendTrackEntries(payload?['tracks']);
    appendTrackEntries(payload?['items']);

    final Map<String, dynamic>? tracksMap = _asStringKeyedMap(
      payload?['tracks'],
    );
    appendTrackEntries(tracksMap?['items']);

    final Map<String, dynamic>? dataMap = _asStringKeyedMap(payload?['data']);
    appendTrackEntries(dataMap?['tracks']);
    appendTrackEntries(dataMap?['items']);

    final Map<String, dynamic>? dataTracksMap = _asStringKeyedMap(
      dataMap?['tracks'],
    );
    appendTrackEntries(dataTracksMap?['items']);

    return trackPayloads;
  }

  Future<List<_SpotifyImportTrack>> _importFromAccountEndpoint(
    String path, {
    Map<String, String> queryParameters = const <String, String>{},
  }) async {
    final Map<String, String> fullQuery = <String, String>{
      ...queryParameters,
      'sessionId': _requireSpotifySessionId(),
    };
    final http.Response response = await http.get(
      _backendUri(path, queryParameters: fullQuery),
      headers: <String, String>{'Accept': 'application/json'},
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException(
        _spotifyBackendFailureMessage(
          null,
          response: response,
          fallback: 'Spotify account import failed',
        ),
      );
    }
    final Object? decoded = jsonDecode(response.body);
    final Map<String, dynamic>? payload = _asStringKeyedMap(decoded);
    final List<Map<String, dynamic>> trackPayloads =
        _extractTrackPayloadsFromAccountPayload(payload);
    if (trackPayloads.isEmpty && decoded is List) {
      for (final Object? rawEntry in decoded) {
        final Map<String, dynamic>? entry = _asStringKeyedMap(rawEntry);
        if (entry == null) {
          continue;
        }
        trackPayloads.add(entry);
      }
    }
    if (trackPayloads.isEmpty) {
      throw const FormatException('Track payload missing');
    }

    final List<_SpotifyImportTrack> tracks = <_SpotifyImportTrack>[];
    for (final Map<String, dynamic> trackMap in trackPayloads) {
      final _SpotifyImportTrack parsed = _SpotifyImportTrack.fromJson(trackMap);
      if (parsed.spotifyTrackId.isEmpty ||
          parsed.title.isEmpty ||
          parsed.artist.isEmpty) {
        continue;
      }
      tracks.add(parsed);
    }
    if (tracks.isEmpty) {
      throw const FormatException('No tracks found');
    }
    return tracks;
  }

  Future<List<_SpotifyImportTrack>> _importPlaylistTracksById(
    String playlistId,
  ) async {
    final String trimmedPlaylistId = playlistId.trim();
    if (trimmedPlaylistId.isEmpty) {
      throw const FormatException('Playlist id missing');
    }

    final List<Map<String, String>> queryVariants = <Map<String, String>>[
      <String, String>{'playlistId': trimmedPlaylistId},
      <String, String>{'playlist_id': trimmedPlaylistId},
      <String, String>{'id': trimmedPlaylistId},
    ];

    Object? lastError;
    for (final Map<String, String> query in queryVariants) {
      try {
        return await _importFromAccountEndpoint(
          '/spotify/me/playlist-tracks',
          queryParameters: query,
        );
      } catch (error) {
        lastError = error;
      }
    }

    if (lastError != null) {
      throw lastError;
    }
    throw const FormatException('Playlist import failed');
  }

  Future<List<_SpotifyPlaylistSummary>> _fetchAccountPlaylists() async {
    final http.Response response = await http.get(
      _backendUri(
        '/spotify/me/playlists',
        queryParameters: <String, String>{
          'sessionId': _requireSpotifySessionId(),
        },
      ),
      headers: <String, String>{'Accept': 'application/json'},
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException(
        _spotifyBackendFailureMessage(
          null,
          response: response,
          fallback: 'Failed to fetch playlists',
        ),
      );
    }
    final Object? decoded = jsonDecode(response.body);
    final Map<String, dynamic>? payload = _asStringKeyedMap(decoded);
    final List<Object?> rawPlaylistEntries = <Object?>[];

    void appendPlaylistEntries(Object? rawEntries) {
      if (rawEntries is! List) {
        return;
      }
      rawPlaylistEntries.addAll(rawEntries);
    }

    if (decoded is List) {
      rawPlaylistEntries.addAll(decoded);
    }
    appendPlaylistEntries(payload?['playlists']);
    appendPlaylistEntries(payload?['items']);
    final Map<String, dynamic>? playlistsMap = _asStringKeyedMap(
      payload?['playlists'],
    );
    appendPlaylistEntries(playlistsMap?['items']);

    if (rawPlaylistEntries.isEmpty) {
      return <_SpotifyPlaylistSummary>[];
    }

    final List<_SpotifyPlaylistSummary> playlists = <_SpotifyPlaylistSummary>[];
    for (final Object? rawPlaylist in rawPlaylistEntries) {
      final Map<String, dynamic>? playlistMap = _asStringKeyedMap(rawPlaylist);
      if (playlistMap == null) {
        continue;
      }
      final _SpotifyPlaylistSummary playlist = _SpotifyPlaylistSummary.fromJson(
        playlistMap,
      );
      if (playlist.id.isEmpty || playlist.name.isEmpty) {
        continue;
      }
      playlists.add(playlist);
    }
    return playlists;
  }

  void _applyImportedTracks(
    List<_SpotifyImportTrack> tracks,
    String sourceLabel, {
    SongSourceType sourceType = SongSourceType.spotifyAccount,
  }) {
    final List<Song> songs = tracks
        .map(
          (_SpotifyImportTrack track) =>
              _songFromImportedTrack(track, sourceType: sourceType),
        )
        .toList(growable: false);
    final _ImportMergeResult mergeResult = widget.onSongsImported(songs);
    if (!mounted) {
      return;
    }
    setState(() {
      _importState = _ImportState.success;
      _statusMessage =
          '$sourceLabel import complete: ${mergeResult.addedCount} added, ${mergeResult.updatedCount} updated.';
    });
  }

  Future<List<_SpotifyImportTrack>?> _showTrackSelectionSheet({
    required String title,
    required List<_SpotifyImportTrack> tracks,
    String? artworkUrl,
  }) async {
    return showModalBottomSheet<List<_SpotifyImportTrack>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _appSurfaceStrong,
      showDragHandle: true,
      builder: (BuildContext context) {
        final Set<int> selectedIndexes = <int>{};
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            final int selectedCount = selectedIndexes.length;
            return SafeArea(
              child: SizedBox(
                height: MediaQuery.of(context).size.height * 0.86,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      if ((artworkUrl ?? '').trim().isNotEmpty)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            _ImportArtworkThumbnail(
                              artworkUrl: artworkUrl,
                              size: 56,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    title,
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.white,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    '${tracks.length} songs available • $selectedCount selected',
                                    style: const TextStyle(
                                      color: _appMutedText,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        )
                      else ...<Widget>[
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${tracks.length} songs available • $selectedCount selected',
                          style: const TextStyle(color: _appMutedText),
                        ),
                      ],
                      const SizedBox(height: 10),
                      Row(
                        children: <Widget>[
                          TextButton(
                            onPressed: () {
                              setModalState(() {
                                selectedIndexes
                                  ..clear()
                                  ..addAll(
                                    List<int>.generate(
                                      tracks.length,
                                      (int index) => index,
                                    ),
                                  );
                              });
                            },
                            child: const Text('Select all'),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: () {
                              setModalState(() {
                                selectedIndexes.clear();
                              });
                            },
                            child: const Text('Clear'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Expanded(
                        child: tracks.isEmpty
                            ? const Center(
                                child: Text(
                                  'No songs available for selection.',
                                  style: TextStyle(color: _appMutedText),
                                ),
                              )
                            : ListView.builder(
                                itemCount: tracks.length,
                                itemBuilder: (BuildContext context, int index) {
                                  final _SpotifyImportTrack track =
                                      tracks[index];
                                  final bool isSelected = selectedIndexes
                                      .contains(index);
                                  final String durationLabel =
                                      track.duration.trim().isEmpty
                                      ? ''
                                      : ' • ${track.duration.trim()}';
                                  return CheckboxListTile(
                                    value: isSelected,
                                    onChanged: (bool? value) {
                                      setModalState(() {
                                        if (value ?? false) {
                                          selectedIndexes.add(index);
                                        } else {
                                          selectedIndexes.remove(index);
                                        }
                                      });
                                    },
                                    title: Text(track.title),
                                    subtitle: Text(
                                      '${track.artist}$durationLabel',
                                      style: const TextStyle(
                                        color: _appMutedText,
                                      ),
                                    ),
                                    activeColor: _appPrimary,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                    ),
                                  );
                                },
                              ),
                      ),
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        onPressed: selectedCount == 0
                            ? null
                            : () {
                                final List<_SpotifyImportTrack> selectedTracks =
                                    <_SpotifyImportTrack>[
                                      for (int i = 0; i < tracks.length; i += 1)
                                        if (selectedIndexes.contains(i))
                                          tracks[i],
                                    ];
                                Navigator.of(context).pop(selectedTracks);
                              },
                        icon: const Icon(Icons.playlist_add_check_rounded),
                        label: Text(
                          selectedCount == 0
                              ? 'Select songs to import'
                              : 'Import $selectedCount selected',
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: _appPrimary,
                          foregroundColor: const Color(0xFF171717),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _selectTracksAndImport({
    required String selectionTitle,
    required String sourceLabel,
    required List<_SpotifyImportTrack> tracks,
    String? artworkUrl,
  }) async {
    if (!mounted) {
      return;
    }
    final List<_SpotifyImportTrack>? selectedTracks =
        await _showTrackSelectionSheet(
          title: selectionTitle,
          tracks: tracks,
          artworkUrl: artworkUrl,
        );
    if (!mounted) {
      return;
    }
    if (selectedTracks == null) {
      setState(() {
        _importState = _ImportState.idle;
        _statusMessage = '';
        _playlistImportArtworkUrl = null;
      });
      return;
    }
    if (selectedTracks.isEmpty) {
      setState(() {
        _importState = _ImportState.error;
        _statusMessage = 'Select at least one song to import.';
      });
      return;
    }
    _applyImportedTracks(selectedTracks, sourceLabel);
    setState(() {
      _playlistImportArtworkUrl = null;
    });
  }

  Future<void> _importLikedSongs() async {
    setState(() {
      _importState = _ImportState.loading;
      _statusMessage = 'Loading liked songs...';
    });
    try {
      final List<_SpotifyImportTrack> tracks = await _importFromAccountEndpoint(
        '/spotify/me/liked-tracks',
        queryParameters: const <String, String>{'limit': '50'},
      );
      await _selectTracksAndImport(
        selectionTitle: 'Select liked songs',
        sourceLabel: 'Liked songs',
        tracks: tracks,
      );
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _importState = _ImportState.error;
        _statusMessage = 'Could not import liked songs.';
      });
    }
  }

  Future<void> _importRecentlyPlayed() async {
    setState(() {
      _importState = _ImportState.loading;
      _statusMessage = 'Loading recently played songs...';
    });
    try {
      final List<_SpotifyImportTrack> tracks = await _importFromAccountEndpoint(
        '/spotify/me/recently-played',
        queryParameters: const <String, String>{'limit': '50'},
      );
      await _selectTracksAndImport(
        selectionTitle: 'Select recently played songs',
        sourceLabel: 'Recently played',
        tracks: tracks,
      );
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _importState = _ImportState.error;
        _statusMessage = 'Could not import recently played songs.';
      });
    }
  }

  Future<void> _importFromMyPlaylists() async {
    setState(() {
      _importState = _ImportState.loading;
      _statusMessage = 'Fetching your playlists...';
    });
    try {
      final List<_SpotifyPlaylistSummary> playlists =
          await _fetchAccountPlaylists();
      if (!mounted) {
        return;
      }
      final _SpotifyPlaylistSummary? selectedPlaylist =
          await showModalBottomSheet<_SpotifyPlaylistSummary>(
            context: context,
            backgroundColor: _appSurfaceStrong,
            showDragHandle: true,
            builder: (BuildContext context) {
              if (playlists.isEmpty) {
                return const SafeArea(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Text(
                      'No playlists available on this Spotify account.',
                      style: TextStyle(color: _appMutedText),
                    ),
                  ),
                );
              }
              return SafeArea(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: playlists.length,
                  itemBuilder: (BuildContext context, int index) {
                    final _SpotifyPlaylistSummary playlist = playlists[index];
                    return ListTile(
                      leading: _ImportArtworkThumbnail(
                        artworkUrl: playlist.artworkUrl,
                      ),
                      title: Text(playlist.name),
                      subtitle: Text('${playlist.tracksTotal} songs'),
                      onTap: () {
                        Navigator.of(context).pop(playlist);
                      },
                    );
                  },
                ),
              );
            },
          );
      if (selectedPlaylist == null) {
        setState(() {
          _importState = _ImportState.idle;
          _statusMessage = '';
          _playlistImportArtworkUrl = null;
        });
        return;
      }
      setState(() {
        _importState = _ImportState.loading;
        _statusMessage = 'Loading songs from ${selectedPlaylist.name}...';
        _playlistImportArtworkUrl = selectedPlaylist.artworkUrl;
      });
      final List<_SpotifyImportTrack> tracks = await _importPlaylistTracksById(
        selectedPlaylist.id,
      );
      await _selectTracksAndImport(
        selectionTitle: 'Select songs from ${selectedPlaylist.name}',
        sourceLabel: selectedPlaylist.name,
        tracks: tracks,
        artworkUrl: selectedPlaylist.artworkUrl,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _importState = _ImportState.error;
        _statusMessage = _spotifyBackendFailureMessage(
          error,
          fallback: 'Could not import from your playlists.',
        );
        _playlistImportArtworkUrl = null;
      });
    }
  }

  Future<({List<_SpotifyImportTrack> tracks, String? playlistArtworkUrl})>
  _importFromBackend(Uri spotifyUri) async {
    final Uri endpoint = Uri.parse(
      '$_spotifyBackendBaseUrl/spotify/import-url',
    ).replace(queryParameters: <String, String>{'url': spotifyUri.toString()});

    final http.Response response = await http.get(
      endpoint,
      headers: <String, String>{'Accept': 'application/json'},
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const FormatException('Backend import failed');
    }

    final Object? decoded = jsonDecode(response.body);
    final Map<String, dynamic>? payload = _asStringKeyedMap(decoded);
    if (payload == null) {
      throw const FormatException('Backend payload malformed');
    }
    final Object? rawTracks = payload['tracks'];
    if (rawTracks is! List) {
      throw const FormatException('Backend tracks missing');
    }

    final List<_SpotifyImportTrack> tracks = <_SpotifyImportTrack>[];
    for (final Object? rawTrack in rawTracks) {
      final Map<String, dynamic>? trackMap = _asStringKeyedMap(rawTrack);
      if (trackMap == null) {
        continue;
      }
      final _SpotifyImportTrack track = _SpotifyImportTrack.fromJson(trackMap);
      if (track.spotifyTrackId.isEmpty ||
          track.title.isEmpty ||
          track.artist.isEmpty) {
        continue;
      }
      tracks.add(track);
    }
    if (tracks.isEmpty) {
      throw const FormatException('No tracks found');
    }
    final Map<String, dynamic>? playlistMap = _asStringKeyedMap(payload['playlist']);
    final String? playlistArtworkUrl = playlistMap == null
        ? null
        : _SpotifyPlaylistSummary.fromJson(playlistMap).artworkUrl;
    return (tracks: tracks, playlistArtworkUrl: playlistArtworkUrl);
  }

  Song _songFromImportedTrack(
    _SpotifyImportTrack track, {
    SongSourceType sourceType = SongSourceType.spotifyUrl,
  }) {
    return Song(
      id: _createId('song'),
      title: track.title,
      artist: track.artist,
      duration: track.duration,
      key: '',
      bpm: '',
      spotifyUrl: track.spotifyUrl,
      modifier: '',
      notes: '',
      artworkUrl: track.artworkUrl,
      roles: const <RoleAssignment>[],
      spotifyTrackId: track.spotifyTrackId,
      spotifyUri: track.spotifyUri,
      sourceType: sourceType,
      sourceImportedAt: DateTime.now().toUtc().toIso8601String(),
    );
  }

  Future<void> _importSpotifyMetadata() async {
    final String rawUrl = _spotifyUrlController.text.trim();
    final Uri? spotifyUri = Uri.tryParse(rawUrl);
    final _SpotifyUrlKind urlKind = spotifyUri == null
        ? _SpotifyUrlKind.invalid
        : _spotifyUrlKind(spotifyUri);

    if (spotifyUri == null || urlKind == _SpotifyUrlKind.invalid) {
      setState(() {
        _importState = _ImportState.error;
        _statusMessage =
            'Use a valid Spotify track or playlist URL from open.spotify.com.';
      });
      return;
    }

    if (urlKind == _SpotifyUrlKind.playlist) {
      setState(() {
        _importState = _ImportState.loading;
        _statusMessage = 'Importing playlist from Spotify...';
        _playlistImportArtworkUrl = null;
      });
      try {
        final ({
          List<_SpotifyImportTrack> tracks,
          String? playlistArtworkUrl,
        }) importResult = await _importFromBackend(spotifyUri);
        if (!mounted) {
          return;
        }
        setState(() {
          _playlistImportArtworkUrl = importResult.playlistArtworkUrl;
        });
        final List<Song> songs = importResult.tracks
            .map(
              (_SpotifyImportTrack track) => _songFromImportedTrack(
                track,
                sourceType: SongSourceType.spotifyUrl,
              ),
            )
            .toList(growable: false);
        if (!mounted) {
          return;
        }
        final _ImportMergeResult mergeResult = widget.onSongsImported(songs);
        setState(() {
          _importState = _ImportState.success;
          _statusMessage =
              'Playlist import complete: ${mergeResult.addedCount} added, ${mergeResult.updatedCount} updated.';
        });
      } catch (_) {
        if (!mounted) {
          return;
        }
        setState(() {
          _importState = _ImportState.error;
          _statusMessage =
              'Playlist import needs the backend running at $_spotifyBackendBaseUrl.';
          _playlistImportArtworkUrl = null;
        });
      }
      return;
    }

    setState(() {
      _importState = _ImportState.loading;
      _statusMessage = 'Importing from Spotify...';
    });

    final Uri endpoint = Uri.https(
      'open.spotify.com',
      '/oembed',
      <String, String>{'url': spotifyUri.toString()},
    );

    try {
      final http.Response response = await http.get(
        endpoint,
        headers: <String, String>{'Accept': 'application/json'},
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const FormatException('Spotify metadata unavailable');
      }

      final Object? decoded = jsonDecode(response.body);
      final Map<String, dynamic>? payload = _asStringKeyedMap(decoded);
      if (payload == null) {
        throw const FormatException('Spotify returned an unexpected response');
      }

      final String importedTitle = _cleanSpotifyTitle(
        (payload['title'] as String? ?? '').trim(),
      );
      final String importedArtist = (payload['author_name'] as String? ?? '')
          .trim();
      final String importedArtwork = (payload['thumbnail_url'] as String? ?? '')
          .trim();

      if (!mounted) {
        return;
      }

      setState(() {
        if (importedTitle.isNotEmpty) {
          _titleController.text = importedTitle;
        }
        if (importedArtist.isNotEmpty) {
          _artistController.text = importedArtist;
        }
        _spotifyUrlController.text = spotifyUri.toString();
        _importedSpotifyTrackId = _spotifyEntityIdFromUri(spotifyUri, 'track');
        _importedSpotifyUri = _importedSpotifyTrackId == null
            ? null
            : 'spotify:track:$_importedSpotifyTrackId';
        _importSourceType = SongSourceType.spotifyUrl;
        _artworkUrl = importedArtwork.isEmpty ? null : importedArtwork;
        _importerStep = _ImporterStep.details;
        _importState = _ImportState.success;
        _statusMessage =
            'Imported song name, artist, cover image (when available), and Spotify link.';
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _importState = _ImportState.error;
        _statusMessage = 'Spotify import failed. Try another Spotify link.';
      });
    }
  }

  void _resetDraft() {
    _spotifyUrlController.clear();
    _titleController.clear();
    _artistController.clear();
    _durationController.clear();
    _keyController.clear();
    _bpmController.clear();
    _modifierController.clear();
    _notesController.clear();
    for (final _RoleDraft roleDraft in _roleDrafts) {
      roleDraft.dispose();
    }
    _roleDrafts
      ..clear()
      ..add(_RoleDraft(id: _createId('role-draft')));
    _artworkUrl = null;
    _importedSpotifyTrackId = null;
    _importedSpotifyUri = null;
    _importSourceType = SongSourceType.manual;
  }

  void _createSong() {
    final String title = _titleController.text.trim();
    final String artist = _artistController.text.trim();

    if (title.isEmpty || artist.isEmpty) {
      setState(() {
        _importState = _ImportState.error;
        _statusMessage = 'Song title and artist are required.';
      });
      return;
    }

    final List<RoleAssignment> roles = _roleDrafts
        .map((_RoleDraft roleDraft) {
          final String instrument = roleDraft.instrumentController.text.trim();
          final String player = roleDraft.playerController.text.trim();
          if (instrument.isEmpty || player.isEmpty) {
            return null;
          }
          return RoleAssignment(
            id: _createId('role'),
            instrument: instrument,
            player: player,
            chartUrl: roleDraft.chartUrlController.text.trim(),
          );
        })
        .whereType<RoleAssignment>()
        .toList(growable: false);
    final String spotifyUrl = _spotifyUrlController.text.trim();
    final String? spotifyTrackId =
        _importedSpotifyTrackId ?? _spotifyTrackIdFromUrl(spotifyUrl);
    final SongSourceType sourceType = spotifyTrackId == null
        ? SongSourceType.manual
        : _importSourceType;
    final String? sourceImportedAt = spotifyTrackId == null
        ? null
        : DateTime.now().toUtc().toIso8601String();

    final Song newSong = Song(
      id: _createId('song'),
      title: title,
      artist: artist,
      duration: _durationController.text.trim(),
      key: _keyController.text.trim(),
      bpm: _bpmController.text.trim(),
      spotifyUrl: spotifyUrl,
      modifier: _modifierController.text.trim(),
      notes: _notesController.text.trim(),
      artworkUrl: _artworkUrl,
      roles: roles,
      spotifyTrackId: spotifyTrackId,
      spotifyUri: _importedSpotifyUri,
      sourceType: sourceType,
      sourceImportedAt: sourceImportedAt,
    );

    final _ImportMergeResult mergeResult = widget.onSongsImported(<Song>[
      newSong,
    ]);
    setState(() {
      _importState = _ImportState.success;
      _statusMessage =
          'Import complete: ${mergeResult.addedCount} added, ${mergeResult.updatedCount} updated.';
      _resetDraft();
      _importerStep = _ImporterStep.choose;
    });
  }

  void _setImporterStep(_ImporterStep step) {
    if (_importerStep == step) {
      return;
    }
    setState(() {
      _importerStep = step;
    });
  }

  Widget _buildStatusMessage(Color statusColor) {
    if (_statusMessage.isEmpty) {
      return const SizedBox.shrink();
    }
    final String? artworkUrl = _playlistImportArtworkUrl;
    if ((artworkUrl ?? '').trim().isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          _statusMessage,
          style: TextStyle(color: statusColor, fontSize: 12),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _ImportArtworkThumbnail(artworkUrl: artworkUrl, size: 44),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _statusMessage,
              style: TextStyle(color: statusColor, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepBackButton(_ImporterStep step) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () => _setImporterStep(step),
        icon: const Icon(Icons.arrow_back_rounded),
        label: const Text('Back'),
      ),
    );
  }

  Widget _buildImportMethodButton({
    required IconData icon,
    required String title,
    String? subtitle,
    required VoidCallback onPressed,
    bool highlighted = false,
  }) {
    final Color backgroundColor = highlighted
        ? _appPrimary
        : _appSurfaceStrong.withValues(alpha: 0.94);
    final Color foregroundColor = highlighted
        ? const Color(0xFF111111)
        : Colors.white;
    final Color subtitleColor = highlighted
        ? const Color(0xFF3D3D3D)
        : _appMutedText;
    final String subtitleText = (subtitle ?? '').trim();

    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: backgroundColor,
        foregroundColor: foregroundColor,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 19),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (subtitleText.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    subtitleText,
                    style: TextStyle(fontSize: 12, color: subtitleColor),
                  ),
                ],
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, size: 20),
        ],
      ),
    );
  }

  Widget _buildChooseStep(Color statusColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const _PageTitleHeading(text: 'How do you want to add a song?'),
        const SizedBox(height: 12),
        _SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _buildImportMethodButton(
                onPressed: () => _setImporterStep(_ImporterStep.link),
                icon: Icons.link_rounded,
                title: 'Spotify link',
                highlighted: true,
              ),
              const SizedBox(height: 10),
              _buildImportMethodButton(
                onPressed: () => _setImporterStep(_ImporterStep.account),
                icon: Icons.account_circle_rounded,
                title: 'Spotify account',
              ),
              if (!widget.spotifyAccountConnected) ...<Widget>[
                const SizedBox(height: 8),
                const Text(
                  'Connect Spotify in the top bar to unlock account imports.',
                  style: TextStyle(color: _appMutedText, fontSize: 12),
                ),
              ],
              _buildStatusMessage(statusColor),
            ],
          ),
        ),
        const SizedBox(height: 84),
      ],
    );
  }

  Widget _buildLinkStep(Color statusColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildStepBackButton(_ImporterStep.choose),
        const SizedBox(height: 4),
        const _PageTitleHeading(text: 'Import with Spotify link'),
        const SizedBox(height: 12),
        _SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              TextField(
                controller: _spotifyUrlController,
                decoration: const InputDecoration(
                  hintText:
                      'https://open.spotify.com/track/... (or playlist/...)',
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _importState == _ImportState.loading
                      ? null
                      : _importSpotifyMetadata,
                  icon: _importState == _ImportState.loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_rounded),
                  label: Text(
                    _importState == _ImportState.loading
                        ? 'Importing...'
                        : 'Import link',
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: _appPrimary,
                    foregroundColor: const Color(0xFF131313),
                  ),
                ),
              ),
              _buildStatusMessage(statusColor),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const _SectionLabel(text: 'Song details'),
              const SizedBox(height: 10),
              const Text(
                'For track links, continue to review/edit song details before adding.',
                style: TextStyle(color: _appMutedText, fontSize: 12),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => _setImporterStep(_ImporterStep.details),
                icon: const Icon(Icons.edit_note_rounded),
                label: const Text('Open song details'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 84),
      ],
    );
  }

  Widget _buildAccountStep(Color statusColor) {
    final bool accountImportDisabled =
        _spotifySessionId == null ||
        !widget.spotifyAccountConnected ||
        _importState == _ImportState.loading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildStepBackButton(_ImporterStep.choose),
        const SizedBox(height: 4),
        const _PageTitleHeading(text: 'Import from Spotify account'),
        const SizedBox(height: 12),
        _SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              FilledButton.tonalIcon(
                onPressed: accountImportDisabled
                    ? null
                    : _importFromMyPlaylists,
                icon: const Icon(Icons.queue_music_rounded),
                label: const Text('My Playlists'),
              ),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: accountImportDisabled ? null : _importLikedSongs,
                icon: const Icon(Icons.favorite_rounded),
                label: const Text('Liked Songs'),
              ),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: accountImportDisabled ? null : _importRecentlyPlayed,
                icon: const Icon(Icons.history_rounded),
                label: const Text('Recently Played'),
              ),
              if (!widget.spotifyAccountConnected) ...<Widget>[
                const SizedBox(height: 8),
                const Text(
                  'Account imports are disabled until Spotify is connected.',
                  style: TextStyle(color: _appMutedText, fontSize: 12),
                ),
              ],
              _buildStatusMessage(statusColor),
            ],
          ),
        ),
        const SizedBox(height: 84),
      ],
    );
  }

  Widget _buildDetailsStep(Color statusColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildStepBackButton(_ImporterStep.link),
        const SizedBox(height: 4),
        const _PageTitleHeading(text: 'Song details'),
        const SizedBox(height: 12),
        if (_artworkUrl != null) ...<Widget>[
          _SectionCard(
            child: Row(
              children: <Widget>[
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.network(
                    _artworkUrl!,
                    width: 72,
                    height: 72,
                    fit: BoxFit.cover,
                    errorBuilder:
                        (
                          BuildContext context,
                          Object error,
                          StackTrace? stackTrace,
                        ) {
                          return Container(
                            width: 72,
                            height: 72,
                            color: _appSurfaceStrong,
                            alignment: Alignment.center,
                            child: const Icon(Icons.music_note_rounded),
                          );
                        },
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Cover art imported from Spotify.',
                    style: TextStyle(color: _appMutedText, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        _SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const _SectionLabel(text: 'Song details'),
              const SizedBox(height: 10),
              TextField(
                controller: _titleController,
                decoration: const InputDecoration(labelText: 'Song title'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _artistController,
                decoration: const InputDecoration(labelText: 'Artist'),
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _durationController,
                      decoration: const InputDecoration(
                        labelText: 'Duration (mm:ss)',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _bpmController,
                      decoration: const InputDecoration(labelText: 'BPM'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _keyController,
                decoration: const InputDecoration(labelText: 'Key'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _modifierController,
                decoration: const InputDecoration(
                  labelText: 'Modifier (e.g. Capo 2, Drop D, Acoustic)',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _notesController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  alignLabelWithHint: true,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const _SectionLabel(text: 'Instrument roles'),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _addRoleDraft,
                    icon: const Icon(Icons.add),
                    label: const Text('Add role'),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ..._roleDrafts.map((_RoleDraft roleDraft) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: TextField(
                              controller: roleDraft.instrumentController,
                              decoration: const InputDecoration(
                                labelText: 'Instrument',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: roleDraft.playerController,
                              decoration: const InputDecoration(
                                labelText: 'Player',
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () => _removeRoleDraft(roleDraft),
                            icon: const Icon(Icons.delete_outline_rounded),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: roleDraft.chartUrlController,
                        decoration: const InputDecoration(
                          labelText: 'Chords/Tab link (optional)',
                          hintText:
                              'https://www.ultimate-guitar.com/... or any chart link',
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _createSong,
          icon: const Icon(Icons.library_add_rounded),
          label: const Text('Save song'),
          style: FilledButton.styleFrom(
            backgroundColor: _appPrimary,
            foregroundColor: const Color(0xFF131313),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
        _buildStatusMessage(statusColor),
        const SizedBox(height: 8),
        const Text(
          'Saved songs keep their Spotify link, so players can open each track directly.',
          style: TextStyle(color: _appMutedText, fontSize: 12),
        ),
        const SizedBox(height: 84),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final Color statusColor = switch (_importState) {
      _ImportState.error => const Color(0xFFFF9A9A),
      _ImportState.success => _appPrimary,
      _ImportState.loading => _appMutedText,
      _ImportState.idle => _appMutedText,
    };

    final Widget stepContent = switch (_importerStep) {
      _ImporterStep.choose => _buildChooseStep(statusColor),
      _ImporterStep.link => _buildLinkStep(statusColor),
      _ImporterStep.account => _buildAccountStep(statusColor),
      _ImporterStep.details => _buildDetailsStep(statusColor),
    };

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        child: KeyedSubtree(
          key: ValueKey<_ImporterStep>(_importerStep),
          child: stepContent,
        ),
      ),
    );
  }
}

class _TopStatusBar extends StatelessWidget {
  const _TopStatusBar({
    required this.title,
    required this.subtitle,
    this.imageUrl,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final String? imageUrl;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        _ProfileAvatar(imageUrl: imageUrl),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(color: _appMutedText, fontSize: 12),
              ),
            ],
          ),
        ),
        if (trailing != null) ...<Widget>[
          const SizedBox(width: 10),
          Flexible(
            child: Align(alignment: Alignment.centerRight, child: trailing!),
          ),
        ],
      ],
    );
  }
}

class _TopStatusTag extends StatelessWidget {
  const _TopStatusTag({required this.text, required this.icon});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _appSurfaceStrong,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 14, color: _appPrimary),
          const SizedBox(width: 6),
          Text(
            text,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: _appMutedText,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({this.imageUrl});

  final String? imageUrl;
  static const String _fallbackAvatarUrl =
      'https://api.dicebear.com/9.x/notionists/png?seed=TallarinesVerdes';

  @override
  Widget build(BuildContext context) {
    final String resolvedImageUrl = (imageUrl ?? '').trim();
    return CircleAvatar(
      radius: 20,
      backgroundColor: _appSurfaceStrong,
      backgroundImage: const NetworkImage(_fallbackAvatarUrl),
      foregroundImage: resolvedImageUrl.isEmpty
          ? null
          : NetworkImage(resolvedImageUrl),
      child: resolvedImageUrl.isEmpty
          ? const Icon(Icons.person_rounded, color: Colors.white)
          : null,
    );
  }
}

class _CurrentSongBarFramePainter extends CustomPainter {
  const _CurrentSongBarFramePainter({
    required this.tabLeft,
    required this.tabRight,
    required this.cornerRadius,
    required this.strokeWidth,
    required this.color,
  });

  final double tabLeft;
  final double tabRight;
  final double cornerRadius;
  final double strokeWidth;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double inset = strokeWidth / 2;
    final double radius = cornerRadius;
    final double width = size.width;
    final double height = size.height;

    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeJoin = StrokeJoin.miter;

    final Path path = Path()
      ..moveTo(inset, inset + radius)
      ..arcToPoint(
        Offset(inset + radius, inset),
        radius: Radius.circular(radius),
        clockwise: true,
      )
      ..lineTo(width - inset - radius, inset)
      ..arcToPoint(
        Offset(width - inset, inset + radius),
        radius: Radius.circular(radius),
        clockwise: true,
      )
      ..lineTo(width - inset, height - inset)
      ..lineTo(tabRight - inset, height - inset)
      ..moveTo(tabLeft + inset, height - inset)
      ..lineTo(inset + radius, height - inset)
      ..arcToPoint(
        Offset(inset, height - inset - radius),
        radius: Radius.circular(radius),
        clockwise: true,
      )
      ..lineTo(inset, inset + radius);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CurrentSongBarFramePainter oldDelegate) {
    return tabLeft != oldDelegate.tabLeft ||
        tabRight != oldDelegate.tabRight ||
        cornerRadius != oldDelegate.cornerRadius ||
        strokeWidth != oldDelegate.strokeWidth ||
        color != oldDelegate.color;
  }
}

class _CurrentSongBar extends StatelessWidget {
  const _CurrentSongBar({
    required this.song,
    required this.playerState,
    required this.isConnecting,
    required this.errorMessage,
    required this.onPressed,
  });
  final Song song;

  final PlayerState? playerState;
  final bool isConnecting;
  final String? errorMessage;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final Track? track = playerState?.track;
    final String title = song.title.trim().isEmpty
        ? 'Untitled song'
        : song.title.trim();
    final String artistName = song.artist.trim().isEmpty
        ? 'Unknown artist'
        : song.artist.trim();
    final String? spotifyArtworkUrl = _spotifyImageUriToUrl(
      track?.imageUri.raw,
    );
    final String artworkFallback = (song.artworkUrl ?? '').trim();
    final String? artworkUrl =
        spotifyArtworkUrl ?? (artworkFallback.isEmpty ? null : artworkFallback);
    final String playbackError = (errorMessage ?? '').trim();
    final bool hasPlaybackError = playbackError.isNotEmpty;
    final bool isPlaying = !(playerState?.isPaused ?? true);
    final String? statusSuffix = hasPlaybackError
        ? 'Playback issue'
        : isConnecting
        ? 'Connecting Spotify'
        : isPlaying
        ? 'Spotify playing'
        : null;
    final String subtitle = statusSuffix == null
        ? artistName
        : '$artistName • $statusSuffix';
    final IconData statusIcon = hasPlaybackError
        ? Icons.warning_amber_rounded
        : isConnecting
        ? Icons.sync_rounded
        : isPlaying
        ? Icons.graphic_eq_rounded
        : Icons.music_note_rounded;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double barWidth = constraints.maxWidth;
          final double tabLeft = _currentSongTabLeft(barWidth);
          final double tabRight = _currentSongTabRight(barWidth);
          const double barCornerRadius = 18;

          return Stack(
            children: <Widget>[
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onPressed,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(barCornerRadius),
                    topRight: Radius.circular(barCornerRadius),
                    bottomLeft: Radius.circular(barCornerRadius),
                  ),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(10, 9, 12, 9),
                    decoration: BoxDecoration(
                      color: _appSurfaceStrong.withValues(alpha: 0.96),
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(barCornerRadius),
                        topRight: Radius.circular(barCornerRadius),
                        bottomLeft: Radius.circular(barCornerRadius),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: artworkUrl == null
                                  ? Container(
                                      width: 44,
                                      height: 44,
                                      color: _appSurface.withValues(
                                        alpha: 0.65,
                                      ),
                                      alignment: Alignment.center,
                                      child: Icon(
                                        statusIcon,
                                        color: _appPrimary,
                                      ),
                                    )
                                  : Image.network(
                                      artworkUrl,
                                      width: 44,
                                      height: 44,
                                      fit: BoxFit.cover,
                                      errorBuilder:
                                          (
                                            BuildContext context,
                                            Object error,
                                            StackTrace? stackTrace,
                                          ) {
                                            return Container(
                                              width: 44,
                                              height: 44,
                                              color: _appSurface.withValues(
                                                alpha: 0.65,
                                              ),
                                              alignment: Alignment.center,
                                              child: Icon(
                                                statusIcon,
                                                color: _appPrimary,
                                              ),
                                            );
                                          },
                                    ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: 1),
                                  Text(
                                    subtitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: _appMutedText.withValues(
                                        alpha: 0.95,
                                      ),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (hasPlaybackError) ...<Widget>[
                          const SizedBox(height: 4),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              playbackError,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFF7A1D1D),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _CurrentSongBarFramePainter(
                      tabLeft: tabLeft,
                      tabRight: tabRight,
                      cornerRadius: barCornerRadius,
                      strokeWidth: _connectedOutlineWidth,
                      color: _appPrimary,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _BottomActionBar extends StatelessWidget {
  const _BottomActionBar({
    required this.activeIndex,
    required this.onActionPressed,
    this.margin = const EdgeInsets.fromLTRB(14, 8, 14, 12),
    this.showCurrentSongConnector = false,
    this.highlightCurrentSongAction = false,
  });

  final int activeIndex;
  final ValueChanged<int> onActionPressed;
  final EdgeInsets margin;
  final bool showCurrentSongConnector;
  final bool highlightCurrentSongAction;

  @override
  Widget build(BuildContext context) {
    final bool hasConnectedCurrentSongSection = showCurrentSongConnector;
    return Container(
      margin: margin,
      padding: EdgeInsets.fromLTRB(
        _bottomNavHorizontalPadding,
        hasConnectedCurrentSongSection ? 0 : 8,
        hasConnectedCurrentSongSection ? 0 : _bottomNavHorizontalPadding,
        8,
      ),
      decoration: BoxDecoration(
        color: _appSurfaceStrong.withValues(alpha: 0.96),
        borderRadius: hasConnectedCurrentSongSection
            ? const BorderRadius.only(
                bottomLeft: Radius.circular(_bottomNavOuterCornerRadius),
                bottomRight: Radius.circular(_bottomNavOuterCornerRadius),
              )
            : BorderRadius.circular(_bottomNavOuterCornerRadius),
        border: hasConnectedCurrentSongSection
            ? null
            : Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: _bottomNavTabHorizontalInset,
              ),
              child: _BottomActionButton(
                label: 'Importer',
                icon: Icons.playlist_add_rounded,
                selected: activeIndex == 0,
                topInset: hasConnectedCurrentSongSection ? 8 : 0,
                onPressed: () => onActionPressed(0),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: _bottomNavTabHorizontalInset,
              ),
              child: _BottomActionButton(
                label: 'Setlist',
                icon: Icons.queue_music_rounded,
                selected: activeIndex == 1,
                topInset: hasConnectedCurrentSongSection ? 8 : 0,
                onPressed: () => onActionPressed(1),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                left: _bottomNavTabHorizontalInset,
                right: hasConnectedCurrentSongSection
                    ? 0
                    : _bottomNavTabHorizontalInset,
              ),
              child: _BottomActionButton(
                label: 'Current Song',
                icon: Icons.equalizer_rounded,
                selected: activeIndex == 2,
                highlighted: highlightCurrentSongAction,
                connectedToBar: hasConnectedCurrentSongSection,
                onPressed: () => onActionPressed(2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomActionButton extends StatelessWidget {
  const _BottomActionButton({
    required this.label,
    required this.icon,
    required this.selected,
    this.highlighted = false,
    this.connectedToBar = false,
    this.topInset = 0,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final bool highlighted;
  final bool connectedToBar;
  final double topInset;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final bool isSelected = selected;
    final bool isHighlighted = highlighted && !selected;
    final bool useConnectedBorder = connectedToBar && (highlighted || selected);
    final BorderRadius borderRadius = connectedToBar
        ? const BorderRadius.only(
            bottomLeft: Radius.circular(14),
            bottomRight: Radius.circular(_bottomNavOuterCornerRadius),
          )
        : BorderRadius.circular(14);
    final BoxBorder? border = useConnectedBorder
        ? const Border(
            left: BorderSide(color: _appPrimary, width: _connectedOutlineWidth),
            right: BorderSide(
              color: _appPrimary,
              width: _connectedOutlineWidth,
            ),
            bottom: BorderSide(
              color: _appPrimary,
              width: _connectedOutlineWidth,
            ),
          )
        : isHighlighted
        ? Border.all(color: _appPrimary, width: _connectedOutlineWidth)
        : null;
    final Color foregroundColor = isSelected
        ? Colors.black
        : (highlighted ? _appPrimary : _appMutedText);
    final Color backgroundColor = isSelected ? _appPrimary : Colors.transparent;

    // The connected tab has no outer top inset so its outline meets the
    // current-song bar flush; the siblings' inset moves inside the tab
    // instead, keeping icon and label aligned across all tabs.
    final EdgeInsets contentPadding = connectedToBar
        ? const EdgeInsets.only(top: 18, bottom: 10)
        : const EdgeInsets.symmetric(vertical: 10);

    return Padding(
      padding: EdgeInsets.only(top: topInset),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: borderRadius,
          child: Ink(
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: borderRadius,
              border: border,
            ),
            padding: contentPadding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(icon, size: 20, color: foregroundColor),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(
                    color: foregroundColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PageTitleHeading extends StatelessWidget {
  const _PageTitleHeading({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 30,
        fontWeight: FontWeight.w800,
        height: 1.05,
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }
}

class _ReadOnlySongDetailTile extends StatelessWidget {
  const _ReadOnlySongDetailTile({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: _appSurface.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: const TextStyle(
              color: _appMutedText,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _RoleInstrumentLabel extends StatelessWidget {
  const _RoleInstrumentLabel({required this.instrument});

  final String instrument;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: _appSurface.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      alignment: Alignment.centerLeft,
      child: Text(
        instrument,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

InputDecoration _rolePillInputDecoration({String? hintText}) {
  final OutlineInputBorder border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
  );
  return InputDecoration(
    hintText: hintText,
    filled: true,
    fillColor: _appSurface.withValues(alpha: 0.55),
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
    border: border,
    enabledBorder: border,
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: _appPrimary.withValues(alpha: 0.75)),
    ),
  );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          text.toUpperCase(),
          style: const TextStyle(
            fontSize: 11,
            color: _appMutedText,
            letterSpacing: 0.7,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          width: 34,
          height: 2,
          decoration: BoxDecoration(
            color: _appPrimary.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(999),
          ),
        ),
      ],
    );
  }
}
