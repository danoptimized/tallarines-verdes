import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'firebase_options.dart';

const Color _appBackground = Color(0xFF0B0A14);
const Color _appSurface = Color(0xFF171324);
const Color _appSurfaceStrong = Color(0xFF211B33);
const Color _appPrimary = Color(0xFFE0F64F);
const Color _appMutedText = Color(0xFFB8B5CB);
const Color _appAccent = Color(0xFF5D4A8A);

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

String _normalizeForMatch(String value) {
  return value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
}

const String _spotifyBackendBaseUrl = String.fromEnvironment(
  'SPOTIFY_BACKEND_BASE_URL',
  defaultValue: 'https://tv.lull.works',
);

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
    return _SpotifyImportTrack(
      title: (json['title'] as String? ?? '').trim(),
      artist: (json['artist'] as String? ?? '').trim(),
      duration: (json['duration'] as String? ?? '').trim(),
      spotifyUrl: (json['spotifyUrl'] as String? ?? '').trim(),
      spotifyTrackId: (json['spotifyTrackId'] as String? ?? '').trim(),
      spotifyUri: (json['spotifyUri'] as String? ?? '').trim(),
      artworkUrl: (json['artworkUrl'] as String?)?.trim(),
    );
  }
}

class _SpotifyPlaylistSummary {
  const _SpotifyPlaylistSummary({
    required this.id,
    required this.name,
    required this.tracksTotal,
  });

  final String id;
  final String name;
  final int tracksTotal;

  factory _SpotifyPlaylistSummary.fromJson(Map<String, dynamic> json) {
    return _SpotifyPlaylistSummary(
      id: (json['id'] as String? ?? '').trim(),
      name: (json['name'] as String? ?? '').trim(),
      tracksTotal: (json['tracksTotal'] as num?)?.toInt() ?? 0,
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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
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
  });

  final String id;
  final String instrument;
  final String player;

  factory RoleAssignment.fromJson(Map<String, dynamic> json) {
    return RoleAssignment(
      id: json['id'] as String? ?? _createId('role'),
      instrument: json['instrument'] as String? ?? '',
      player: json['player'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'instrument': instrument,
      'player': player,
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
  const _ImportMergeResult({required this.addedCount, required this.updatedCount});

  final int addedCount;
  final int updatedCount;

  int get totalProcessed => addedCount + updatedCount;
}

class _SetlistHomePageState extends State<SetlistHomePage> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  List<Song> _songs = <Song>[];
  String? _currentSongId;
  int _tabIndex = 0;
  bool _isLoading = true;
  String? _firebaseUserId;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
      _setlistSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _songsSubscription;

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

  CollectionReference<Map<String, dynamic>>? get _songsCollection {
    final DocumentReference<Map<String, dynamic>>? setlistDoc = _setlistDoc;
    if (setlistDoc == null) {
      return null;
    }
    return setlistDoc.collection('songs');
  }

  String? get _resolvedCurrentSongId {
    if (_songs.isEmpty) {
      return null;
    }
    if (_currentSongId != null &&
        _songs.any((Song song) => song.id == _currentSongId)) {
      return _currentSongId;
    }
    return _songs.first.id;
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

  int get _currentSongPosition {
    final String? currentId = _resolvedCurrentSongId;
    if (currentId == null) {
      return 0;
    }
    final int index = _songs.indexWhere((Song song) => song.id == currentId);
    if (index < 0) {
      return 0;
    }
    return index + 1;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_initializeCloudState());
  }

  @override
  void dispose() {
    unawaited(_setlistSubscription?.cancel());
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
      await _ensureCloudSetlistExists();
      await _setlistSubscription?.cancel();
      await _songsSubscription?.cancel();

      final DocumentReference<Map<String, dynamic>>? setlistDoc = _setlistDoc;
      final CollectionReference<Map<String, dynamic>>? songsCollection =
          _songsCollection;
      if (setlistDoc == null || songsCollection == null) {
        throw const FormatException('Missing Firestore setlist references');
      }

      _setlistSubscription = setlistDoc.snapshots().listen((
        DocumentSnapshot<Map<String, dynamic>> snapshot,
      ) {
        final String? remoteCurrentSongId =
            snapshot.data()?['currentSongId'] as String?;
        if (!mounted) {
          return;
        }
        setState(() {
          _currentSongId = remoteCurrentSongId;
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
                if (_currentSongId != null &&
                    !_songs.any((Song song) => song.id == _currentSongId)) {
                  _currentSongId = _songs.isEmpty ? null : _songs.first.id;
                }
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

  Future<void> _ensureCloudSetlistExists() async {
    final DocumentReference<Map<String, dynamic>>? setlistDoc = _setlistDoc;
    if (setlistDoc == null) {
      return;
    }
    final DocumentSnapshot<Map<String, dynamic>> snapshot =
        await setlistDoc.get();
    if (snapshot.exists) {
      return;
    }
    await setlistDoc.set(<String, dynamic>{
      'currentSongId': null,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> _updateCurrentSongIdInCloud(String? currentSongId) async {
    final DocumentReference<Map<String, dynamic>>? setlistDoc = _setlistDoc;
    if (setlistDoc == null) {
      return;
    }
    await setlistDoc.set(<String, dynamic>{
      'currentSongId': currentSongId,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> _replaceCloudState(
    List<Song> songs,
    String? currentSongId,
  ) async {
    final CollectionReference<Map<String, dynamic>>? songsCollection =
        _songsCollection;
    final DocumentReference<Map<String, dynamic>>? setlistDoc = _setlistDoc;
    if (songsCollection == null || setlistDoc == null) {
      return;
    }

    final QuerySnapshot<Map<String, dynamic>> existingSongsSnapshot =
        await songsCollection.get();
    final Set<String> nextSongIds = songs.map((Song song) => song.id).toSet();

    final WriteBatch batch = _firestore.batch();
    for (final QueryDocumentSnapshot<Map<String, dynamic>>
        existingSong in existingSongsSnapshot.docs) {
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

    batch.set(setlistDoc, <String, dynamic>{
      'currentSongId': currentSongId,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    await batch.commit();
  }

  void _setCurrentSong(String songId) {
    if (!_songs.any((Song song) => song.id == songId)) {
      return;
    }
    setState(() {
      _currentSongId = songId;
    });
    unawaited(_updateCurrentSongIdInCloud(songId));
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
    String? focusSongId;

    for (final Song song in importedSongs) {
      final int existingIndex = _findSongMatchIndex(song);
      if (existingIndex < 0) {
        nextSongs.add(song);
        addedCount += 1;
        focusSongId = song.id;
        continue;
      }

      final Song existingSong = nextSongs[existingIndex];
      final Song mergedSong = Song(
        id: existingSong.id,
        title:
            song.title.trim().isEmpty ? existingSong.title : song.title.trim(),
        artist:
            song.artist.trim().isEmpty
                ? existingSong.artist
                : song.artist.trim(),
        duration:
            song.duration.trim().isEmpty
                ? existingSong.duration
                : song.duration.trim(),
        key: existingSong.key,
        bpm: existingSong.bpm,
        spotifyUrl:
            song.spotifyUrl.trim().isEmpty
                ? existingSong.spotifyUrl
                : song.spotifyUrl.trim(),
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
      focusSongId = mergedSong.id;
    }

    final String? nextCurrentSongId = focusSongId ?? _currentSongId;
    setState(() {
      _songs = nextSongs;
      _currentSongId = nextCurrentSongId;
      _tabIndex = 0;
    });
    unawaited(_replaceCloudState(nextSongs, nextCurrentSongId));
    return _ImportMergeResult(addedCount: addedCount, updatedCount: updatedCount);
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

    String? nextCurrentSongId = _currentSongId;
    if (nextSongs.isEmpty) {
      nextCurrentSongId = null;
    } else if (removedCurrentSong) {
      final int fallbackIndex = min(indexToRemove, nextSongs.length - 1);
      nextCurrentSongId = nextSongs[fallbackIndex].id;
    }

    setState(() {
      _songs = nextSongs;
      _currentSongId = nextCurrentSongId;
    });
    unawaited(_replaceCloudState(nextSongs, nextCurrentSongId));
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
    _setCurrentSong(_songs[nextIndex].id);
  }

  Future<void> _openSpotify(String spotifyUrl) async {
    final Uri? uri = Uri.tryParse(spotifyUrl.trim());
    if (uri == null) {
      return;
    }
    final bool opened = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    if (!opened || !mounted) {
      return;
    }
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
                    'Pick a song',
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
    _setCurrentSong(selectedSongId);
    if (_tabIndex != 0) {
      setState(() {
        _tabIndex = 0;
      });
    }
  }

  void _selectBottomAction(int index) {
    if (index == 2) {
      unawaited(_showSongPickerModal());
      return;
    }
    if (_tabIndex == index) {
      return;
    }
    setState(() {
      _tabIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final Widget bodyContent;
    if (_isLoading) {
      bodyContent = const Center(
        child: CircularProgressIndicator(color: _appPrimary),
      );
    } else if (_tabIndex == 0) {
      bodyContent = SetlistPage(
        songs: _songs,
        currentSong: _currentSong,
        currentSongPosition: _currentSongPosition,
        totalRuntime: _formatRuntime(_totalRuntimeSeconds),
        onPreviousSong: () => _stepCurrentSong(-1),
        onNextSong: () => _stepCurrentSong(1),
        onSelectSong: _setCurrentSong,
        onRemoveSong: _removeSong,
        onOpenSpotify: _openSpotify,
      );
    } else {
      bodyContent = _SongImporterPage(onSongsImported: _upsertImportedSongs);
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
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: bodyContent,
          ),
        ),
      ),
      bottomNavigationBar: _BottomActionBar(
        activeIndex: _tabIndex,
        onActionPressed: _selectBottomAction,
      ),
    );
  }
}

class SetlistPage extends StatelessWidget {
  const SetlistPage({
    super.key,
    required this.songs,
    required this.currentSong,
    required this.currentSongPosition,
    required this.totalRuntime,
    required this.onPreviousSong,
    required this.onNextSong,
    required this.onSelectSong,
    required this.onRemoveSong,
    required this.onOpenSpotify,
  });

  final List<Song> songs;
  final Song? currentSong;
  final int currentSongPosition;
  final String totalRuntime;
  final VoidCallback onPreviousSong;
  final VoidCallback onNextSong;
  final ValueChanged<String> onSelectSong;
  final ValueChanged<String> onRemoveSong;
  final Future<void> Function(String spotifyUrl) onOpenSpotify;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const _SectionLabel(text: 'Band Setlist Companion'),
          const SizedBox(height: 10),
          const Text(
            'Tallarines Verdes',
            style: TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.6,
              color: _appPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Songs ${songs.length} • Runtime $totalRuntime',
            style: const TextStyle(color: _appMutedText, fontSize: 13),
          ),
          const SizedBox(height: 14),
          _SectionCard(
            child: currentSong == null
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 28),
                    child: Center(
                      child: Text(
                        'Add your first song from Importer.',
                        style: TextStyle(color: _appMutedText),
                      ),
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const _SectionLabel(text: 'Now Playing'),
                      const SizedBox(height: 8),
                      Text(
                        'Song $currentSongPosition of ${songs.length}',
                        style: const TextStyle(
                          color: _appMutedText,
                          fontSize: 12,
                          letterSpacing: 0.7,
                        ),
                      ),
                      const SizedBox(height: 12),
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
                      const SizedBox(height: 12),
                      if (currentSong!.roles.isEmpty)
                        const Text(
                          'No instrument roles assigned.',
                          style: TextStyle(color: _appMutedText),
                        )
                      else
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: currentSong!.roles.map((
                            RoleAssignment role,
                          ) {
                            return Chip(
                              backgroundColor: _appSurfaceStrong,
                              side: BorderSide(
                                color: Colors.white.withValues(alpha: 0.08),
                              ),
                              label: Text(
                                '${role.instrument}: ${role.player}',
                                style: const TextStyle(fontSize: 12),
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
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: onPreviousSong,
                              icon: const Icon(Icons.skip_previous_rounded),
                              label: const Text('Previous'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                side: BorderSide(
                                  color: Colors.white.withValues(alpha: 0.15),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: onNextSong,
                              icon: const Icon(Icons.skip_next_rounded),
                              label: const Text('Next'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                side: BorderSide(
                                  color: Colors.white.withValues(alpha: 0.15),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (currentSong!.spotifyUrl
                          .trim()
                          .isNotEmpty) ...<Widget>[
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: () =>
                                onOpenSpotify(currentSong!.spotifyUrl),
                            icon: const Icon(Icons.open_in_new_rounded),
                            label: const Text('Open in Spotify'),
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
          const SizedBox(height: 14),
          _SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const _SectionLabel(text: 'Entire Setlist View'),
                const SizedBox(height: 8),
                const Text(
                  'Full running order',
                  style: TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w700,
                    color: _appPrimary,
                  ),
                ),
                const SizedBox(height: 10),
                if (songs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: Text(
                      'No songs yet. Use Importer to add one.',
                      style: TextStyle(color: _appMutedText),
                    ),
                  )
                else
                  Column(
                    children: songs.asMap().entries.map((
                      MapEntry<int, Song> entry,
                    ) {
                      final int index = entry.key;
                      final Song song = entry.value;
                      final bool isCurrent = currentSong?.id == song.id;

                      return Container(
                        margin: EdgeInsets.only(
                          bottom: index == songs.length - 1 ? 0 : 10,
                        ),
                        padding: const EdgeInsets.all(12),
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
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            CircleAvatar(
                              radius: 14,
                              backgroundColor: isCurrent
                                  ? _appPrimary
                                  : _appAccent.withValues(alpha: 0.7),
                              child: Text(
                                '${index + 1}',
                                style: TextStyle(
                                  color: isCurrent
                                      ? Colors.black
                                      : Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    song.title,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 16,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    song.artist,
                                    style: const TextStyle(
                                      color: _appMutedText,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    children:
                                        <String>[
                                          if (song.duration.trim().isNotEmpty)
                                            song.duration.trim(),
                                          if (song.key.trim().isNotEmpty)
                                            'Key ${song.key.trim()}',
                                          if (song.bpm.trim().isNotEmpty)
                                            '${song.bpm.trim()} BPM',
                                        ].map((String label) {
                                          return Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 4,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.white.withValues(
                                                alpha: 0.06,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(999),
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
                              ),
                            ),
                            Column(
                              children: <Widget>[
                                IconButton(
                                  icon: const Icon(Icons.play_arrow_rounded),
                                  tooltip: 'Set as current song',
                                  onPressed: () => onSelectSong(song.id),
                                ),
                                if (song.spotifyUrl.trim().isNotEmpty)
                                  IconButton(
                                    icon: const Icon(Icons.open_in_new_rounded),
                                    tooltip: 'Open in Spotify',
                                    onPressed: () =>
                                        onOpenSpotify(song.spotifyUrl),
                                  ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                  ),
                                  tooltip: 'Remove song',
                                  onPressed: () => onRemoveSong(song.id),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
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

class _RoleDraft {
  _RoleDraft({required this.id, String instrument = '', String player = ''})
    : instrumentController = TextEditingController(text: instrument),
      playerController = TextEditingController(text: player);

  final String id;
  final TextEditingController instrumentController;
  final TextEditingController playerController;

  void dispose() {
    instrumentController.dispose();
    playerController.dispose();
  }
}

class _SongImporterPage extends StatefulWidget {
  const _SongImporterPage({required this.onSongsImported});

  final _ImportMergeResult Function(List<Song> songs) onSongsImported;

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
  final TextEditingController _notesController = TextEditingController();

  final List<_RoleDraft> _roleDrafts = <_RoleDraft>[
    _RoleDraft(id: _createId('role-draft')),
  ];

  String? _artworkUrl;
  String? _importedSpotifyTrackId;
  String? _importedSpotifyUri;
  SongSourceType _importSourceType = SongSourceType.manual;
  _ImportState _importState = _ImportState.idle;
  String _statusMessage = '';
  String? _spotifySessionId;
  bool _spotifyAccountConnected = false;
  bool _isLinkingSpotify = false;
  @override
  void initState() {
    super.initState();
    unawaited(_syncSpotifyConnectionStatus().catchError((Object _) {}));
  }

  @override
  void dispose() {
    _spotifyUrlController.dispose();
    _titleController.dispose();
    _artistController.dispose();
    _durationController.dispose();
    _keyController.dispose();
    _bpmController.dispose();
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

  String _sessionId() {
    _spotifySessionId ??= _createId('spotify-session');
    return _spotifySessionId!;
  }

  Uri _backendUri(
    String path, {
    Map<String, String> queryParameters = const <String, String>{},
  }) {
    return Uri.parse('$_spotifyBackendBaseUrl$path').replace(
      queryParameters: queryParameters,
    );
  }

  Future<void> _syncSpotifyConnectionStatus() async {
    final http.Response response = await http.get(
      _backendUri(
        '/spotify/connect/status',
        queryParameters: <String, String>{'sessionId': _sessionId()},
      ),
      headers: <String, String>{'Accept': 'application/json'},
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
    });
  }

  Future<void> _connectSpotifyAccount() async {
    if (_isLinkingSpotify) {
      return;
    }
    setState(() {
      _isLinkingSpotify = true;
      _importState = _ImportState.loading;
      _statusMessage = 'Opening Spotify authorization...';
    });

    try {
      final http.Response response = await http.get(
        _backendUri(
          '/spotify/connect/start',
          queryParameters: <String, String>{'sessionId': _sessionId()},
        ),
        headers: <String, String>{'Accept': 'application/json'},
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
      final Uri authUri = Uri.parse(authorizeUrl);
      final bool opened = await launchUrl(
        authUri,
        mode: LaunchMode.externalApplication,
      );
      if (!opened) {
        throw const FormatException('Could not open Spotify authorization URL');
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _statusMessage =
            'Complete Spotify login in the browser. Waiting for confirmation...';
      });

      final DateTime start = DateTime.now();
      while (DateTime.now().difference(start).inSeconds < 90) {
        await Future<void>.delayed(const Duration(seconds: 2));
        final http.Response statusResponse = await http.get(
          _backendUri(
            '/spotify/connect/status',
            queryParameters: <String, String>{'sessionId': _sessionId()},
          ),
          headers: <String, String>{'Accept': 'application/json'},
        );
        if (statusResponse.statusCode < 200 || statusResponse.statusCode >= 300) {
          continue;
        }
        final Map<String, dynamic>? statusPayload = _asStringKeyedMap(
          jsonDecode(statusResponse.body),
        );
        if (statusPayload?['connected'] == true) {
          if (!mounted) {
            return;
          }
          setState(() {
            _spotifyAccountConnected = true;
            _importState = _ImportState.success;
            _statusMessage = 'Spotify account connected.';
          });
          return;
        }
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _importState = _ImportState.error;
        _statusMessage =
            'Spotify connection timed out. Retry after completing browser login.';
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _importState = _ImportState.error;
        _statusMessage =
            'Spotify connect failed. Verify backend is running and credentials are configured.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLinkingSpotify = false;
        });
      }
    }
  }

  Future<void> _disconnectSpotifyAccount() async {
    try {
      final http.Response response = await http.post(
        _backendUri('/spotify/connect/disconnect'),
        headers: <String, String>{
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(<String, String>{'sessionId': _sessionId()}),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const FormatException('Spotify disconnect failed');
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _spotifyAccountConnected = false;
        _importState = _ImportState.success;
        _statusMessage = 'Spotify account disconnected.';
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _importState = _ImportState.error;
        _statusMessage = 'Could not disconnect Spotify account.';
      });
    }
  }

  Future<List<_SpotifyImportTrack>> _importFromAccountEndpoint(
    String path, {
    Map<String, String> queryParameters = const <String, String>{},
  }) async {
    final Map<String, String> fullQuery = <String, String>{
      ...queryParameters,
      'sessionId': _sessionId(),
    };
    final http.Response response = await http.get(
      _backendUri(path, queryParameters: fullQuery),
      headers: <String, String>{'Accept': 'application/json'},
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const FormatException('Spotify account import failed');
    }
    final Map<String, dynamic>? payload = _asStringKeyedMap(
      jsonDecode(response.body),
    );
    final Object? rawTracks = payload?['tracks'];
    if (rawTracks is! List) {
      throw const FormatException('Track payload missing');
    }

    final List<_SpotifyImportTrack> tracks = <_SpotifyImportTrack>[];
    for (final Object? rawTrack in rawTracks) {
      final Map<String, dynamic>? trackMap = _asStringKeyedMap(rawTrack);
      if (trackMap == null) {
        continue;
      }
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

  Future<List<_SpotifyPlaylistSummary>> _fetchAccountPlaylists() async {
    final http.Response response = await http.get(
      _backendUri(
        '/spotify/me/playlists',
        queryParameters: <String, String>{'sessionId': _sessionId()},
      ),
      headers: <String, String>{'Accept': 'application/json'},
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const FormatException('Failed to fetch playlists');
    }
    final Map<String, dynamic>? payload = _asStringKeyedMap(
      jsonDecode(response.body),
    );
    final Object? rawPlaylists = payload?['playlists'];
    if (rawPlaylists is! List) {
      throw const FormatException('Playlists payload missing');
    }

    final List<_SpotifyPlaylistSummary> playlists = <_SpotifyPlaylistSummary>[];
    for (final Object? rawPlaylist in rawPlaylists) {
      final Map<String, dynamic>? playlistMap = _asStringKeyedMap(rawPlaylist);
      if (playlistMap == null) {
        continue;
      }
      final _SpotifyPlaylistSummary playlist =
          _SpotifyPlaylistSummary.fromJson(playlistMap);
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

  Future<void> _importLikedSongs() async {
    setState(() {
      _importState = _ImportState.loading;
      _statusMessage = 'Importing liked songs...';
    });
    try {
      final List<_SpotifyImportTrack> tracks = await _importFromAccountEndpoint(
        '/spotify/me/liked-tracks',
        queryParameters: const <String, String>{'limit': '50'},
      );
      _applyImportedTracks(tracks, 'Liked songs');
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
      _statusMessage = 'Importing recently played songs...';
    });
    try {
      final List<_SpotifyImportTrack> tracks = await _importFromAccountEndpoint(
        '/spotify/me/recently-played',
        queryParameters: const <String, String>{'limit': '50'},
      );
      _applyImportedTracks(tracks, 'Recently played');
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
        });
        return;
      }
      setState(() {
        _importState = _ImportState.loading;
        _statusMessage = 'Importing playlist "${selectedPlaylist.name}"...';
      });
      final List<_SpotifyImportTrack> tracks = await _importFromAccountEndpoint(
        '/spotify/me/playlist-tracks',
        queryParameters: <String, String>{'playlistId': selectedPlaylist.id},
      );
      _applyImportedTracks(tracks, selectedPlaylist.name);
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _importState = _ImportState.error;
        _statusMessage = 'Could not import from your playlists.';
      });
    }
  }

  Future<List<_SpotifyImportTrack>> _importFromBackend(Uri spotifyUri) async {
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
    return tracks;
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
      });
      try {
        final List<_SpotifyImportTrack> importedTracks = await _importFromBackend(
          spotifyUri,
        );
        final List<Song> songs = importedTracks
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
    });
  }

  @override
  Widget build(BuildContext context) {
    final Color statusColor = switch (_importState) {
      _ImportState.error => const Color(0xFFFF9A9A),
      _ImportState.success => _appPrimary,
      _ImportState.loading => _appMutedText,
      _ImportState.idle => _appMutedText,
    };

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const _SectionLabel(text: 'Song Importer'),
          const SizedBox(height: 10),
          const Text(
            'Import + Add Song',
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w900,
              color: _appPrimary,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Import title, artist, cover, and link from Spotify, then assign instrument roles.',
            style: TextStyle(color: _appMutedText, fontSize: 13),
          ),
          const SizedBox(height: 14),
          _SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'Spotify link',
                  style: TextStyle(
                    fontSize: 12,
                    letterSpacing: 0.7,
                    color: _appMutedText,
                  ),
                ),
                const SizedBox(height: 8),
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
                          : 'Import from Spotify',
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: _appPrimary,
                      foregroundColor: const Color(0xFF131313),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed:
                            _isLinkingSpotify || _importState == _ImportState.loading
                            ? null
                            : _spotifyAccountConnected
                            ? _disconnectSpotifyAccount
                            : _connectSpotifyAccount,
                        icon: Icon(
                          _spotifyAccountConnected
                              ? Icons.link_off_rounded
                              : Icons.link_rounded,
                        ),
                        label: Text(
                          _spotifyAccountConnected
                              ? 'Disconnect Spotify'
                              : (_isLinkingSpotify
                                    ? 'Connecting...'
                                    : 'Connect Spotify'),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: BorderSide(
                            color: Colors.white.withValues(alpha: 0.2),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    FilledButton.tonalIcon(
                      onPressed:
                          (!_spotifyAccountConnected ||
                              _importState == _ImportState.loading)
                          ? null
                          : _importFromMyPlaylists,
                      icon: const Icon(Icons.queue_music_rounded),
                      label: const Text('My Playlists'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed:
                          (!_spotifyAccountConnected ||
                              _importState == _ImportState.loading)
                          ? null
                          : _importLikedSongs,
                      icon: const Icon(Icons.favorite_rounded),
                      label: const Text('Liked Songs'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed:
                          (!_spotifyAccountConnected ||
                              _importState == _ImportState.loading)
                          ? null
                          : _importRecentlyPlayed,
                      icon: const Icon(Icons.history_rounded),
                      label: const Text('Recently Played'),
                    ),
                  ],
                ),
                if (_statusMessage.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    _statusMessage,
                    style: TextStyle(color: statusColor, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          if (_artworkUrl != null) ...<Widget>[
            const SizedBox(height: 12),
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
                  Expanded(
                    child: Text(
                      'Cover art imported from Spotify.',
                      style: const TextStyle(
                        color: _appMutedText,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
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
                    child: Row(
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
                  );
                }),
              ],
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _createSong,
            icon: const Icon(Icons.library_add_rounded),
            label: const Text('Add song to setlist'),
            style: FilledButton.styleFrom(
              backgroundColor: _appPrimary,
              foregroundColor: const Color(0xFF131313),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Saved songs keep their Spotify link, so players can open each track directly.',
            style: TextStyle(color: _appMutedText, fontSize: 12),
          ),
          const SizedBox(height: 84),
        ],
      ),
    );
  }
}

class _BottomActionBar extends StatelessWidget {
  const _BottomActionBar({
    required this.activeIndex,
    required this.onActionPressed,
  });

  final int activeIndex;
  final ValueChanged<int> onActionPressed;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(14, 8, 14, 12),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: _appSurfaceStrong.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: _BottomActionButton(
                label: 'Setlist',
                icon: Icons.queue_music_rounded,
                selected: activeIndex == 0,
                onPressed: () => onActionPressed(0),
              ),
            ),
            Expanded(
              child: _BottomActionButton(
                label: 'Importer',
                icon: Icons.playlist_add_rounded,
                selected: activeIndex == 1,
                onPressed: () => onActionPressed(1),
              ),
            ),
            Expanded(
              child: _BottomActionButton(
                label: 'Pick Song',
                icon: Icons.music_note_rounded,
                selected: false,
                onPressed: () => onActionPressed(2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BottomActionButton extends StatelessWidget {
  const _BottomActionButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: selected ? Colors.black : _appMutedText,
        backgroundColor: selected ? _appPrimary : Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.symmetric(vertical: 10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 20),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
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

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: _appSurfaceStrong,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 10,
          color: _appMutedText,
          letterSpacing: 1.0,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
