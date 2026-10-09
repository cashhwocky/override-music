import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const Map<String, String> kStreamHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
};

const String kLikedKey = 'liked_songs_v1';
const Color kSurface = Color(0xFF121212);
const Color kAccent = Color(0xFF00FFFF);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.black,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Colors.black,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const TidalCloneApp());
}

// ---------------------------------------------------------------------------
// App root
// ---------------------------------------------------------------------------

class TidalCloneApp extends StatelessWidget {
  const TidalCloneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tidal Clone',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        canvasColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Colors.white,
          secondary: Colors.white,
          surface: Colors.black,
        ),
        textSelectionTheme: const TextSelectionThemeData(
          cursorColor: Colors.white,
          selectionHandleColor: Colors.white,
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: Colors.black,
          selectedItemColor: Colors.white,
          unselectedItemColor: Colors.white38,
          type: BottomNavigationBarType.fixed,
          elevation: 0,
          showSelectedLabels: true,
          showUnselectedLabels: true,
        ),
      ),
      home: const RootScreen(),
    );
  }
}

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

class Song {
  final String id;
  final String title;
  final String author;
  final String thumbnailUrl;

  const Song({
    required this.id,
    required this.title,
    required this.author,
    required this.thumbnailUrl,
  });

  String get fallbackThumbnailUrl => 'https://img.youtube.com/vi/$id/hqdefault.jpg';

  Map<String, dynamic> toJson() => {
        'videoId': id,
        'title': title,
        'author': author,
        'thumbnail': thumbnailUrl,
      };

  factory Song.fromJson(Map<String, dynamic> json) {
    return Song(
      id: json['videoId'] as String,
      title: (json['title'] as String?) ?? 'Unknown title',
      author: (json['author'] as String?) ?? 'Unknown artist',
      thumbnailUrl: (json['thumbnail'] as String?) ??
          'https://img.youtube.com/vi/${json['videoId']}/hqdefault.jpg',
    );
  }

  @override
  bool operator ==(Object other) => other is Song && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

String formatDuration(Duration d) {
  final totalSeconds = d.inSeconds < 0 ? 0 : d.inSeconds;
  final m = totalSeconds ~/ 60;
  final s = totalSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

// ---------------------------------------------------------------------------
// Player controller (shared state for all screens)
// ---------------------------------------------------------------------------

class PlayerController extends ChangeNotifier {
  final YoutubeExplode yt = YoutubeExplode();
  final AudioPlayer player = AudioPlayer();

  /// High-frequency position updates are kept out of notifyListeners().
  final ValueNotifier<Duration> position = ValueNotifier<Duration>(Duration.zero);

  List<Song> _queue = [];
  int _index = -1;
  final List<Song> liked = [];

  bool resolving = false;
  bool hasSource = false;
  String? error;
  Duration duration = Duration.zero;
  PlayerState playerState = PlayerState(false, ProcessingState.idle);

  int _token = 0;
  SharedPreferences? _prefs;

  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<PlaybackEvent>? _eventSub;

  PlayerController() {
    _stateSub = player.playerStateStream.listen((state) {
      playerState = state;
      notifyListeners();
      if (state.processingState == ProcessingState.completed &&
          hasSource &&
          _queue.length > 1) {
        next();
      }
    });

    _positionSub = player.positionStream.listen((pos) {
      position.value = pos;
    });

    _durationSub = player.durationStream.listen((dur) {
      duration = dur ?? Duration.zero;
      notifyListeners();
    });

    _eventSub = player.playbackEventStream.listen(
      (_) {},
      onError: (Object e, StackTrace st) {
        error = 'Playback error. Tap play to retry.';
        resolving = false;
        notifyListeners();
      },
    );

    _loadLiked();
  }

  // ----- Getters -----------------------------------------------------------

  Song? get current =>
      (_index >= 0 && _index < _queue.length) ? _queue[_index] : null;

  bool get isPlaying =>
      playerState.playing &&
      playerState.processingState != ProcessingState.idle &&
      playerState.processingState != ProcessingState.completed;

  bool get isBusy =>
      resolving ||
      (playerState.playing &&
          (playerState.processingState == ProcessingState.loading ||
              playerState.processingState == ProcessingState.buffering));

  bool isLiked(String id) => liked.any((s) => s.id == id);

  // ----- Library persistence -----------------------------------------------

  Future<void> _loadLiked() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      final raw = _prefs!.getStringList(kLikedKey) ?? <String>[];
      final loaded = <Song>[];
      for (final item in raw) {
        try {
          final map = jsonDecode(item) as Map<String, dynamic>;
          loaded.add(Song.fromJson(map));
        } catch (_) {
          // Skip corrupted entries.
        }
      }
      liked
        ..clear()
        ..addAll(loaded);
      notifyListeners();
    } catch (_) {
      // Storage unavailable; the library simply starts empty.
    }
  }

  Future<void> _saveLiked() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs!.setStringList(
        kLikedKey,
        liked.map((s) => jsonEncode(s.toJson())).toList(),
      );
    } catch (_) {
      // Ignore write failures.
    }
  }

  Future<void> toggleLike(Song song) async {
    if (isLiked(song.id)) {
      liked.removeWhere((s) => s.id == song.id);
    } else {
      liked.insert(0, song);
    }
    notifyListeners();
    await _saveLiked();
  }

  // ----- Search ------------------------------------------------------------

  Future<List<Song>> search(String query) async {
    final results = await yt.search.search(query);
    final out = <Song>[];
    for (final v in results) {
      if (v.isLive) continue;
      out.add(Song(
        id: v.id.value,
        title: v.title,
        author: v.author,
        thumbnailUrl: v.thumbnails.maxResUrl,
      ));
      if (out.length >= 30) break;
    }
    return out;
  }

  // ----- Stream resolution -------------------------------------------------

  Future<String> _resolveAudioUrl(String videoId) async {
    final manifest = await yt.videos.streamsClient
        .getManifest(videoId)
        .timeout(const Duration(seconds: 25));

    final audioStreams = manifest.audioOnly.toList();
    if (audioStreams.isEmpty) {
      throw Exception('No audio streams available');
    }

    final m4a =
        audioStreams.where((s) => s.container == StreamContainer.mp4).toList();
    final pool = m4a.isNotEmpty ? m4a : audioStreams;

    var best = pool.first;
    for (final s in pool) {
      if (s.bitrate.bitsPerSecond > best.bitrate.bitsPerSecond) {
        best = s;
      }
    }
    return best.url.toString();
  }

  // ----- Playback ----------------------------------------------------------

  Future<void> playQueue(List<Song> songs, int index) async {
    if (songs.isEmpty) return;
    _queue = List<Song>.of(songs);
    await _playAt(index);
  }

  Future<void> _playAt(int index) async {
    if (_queue.isEmpty) return;
    final safeIndex = ((index % _queue.length) + _queue.length) % _queue.length;
    final token = ++_token;
    final song = _queue[safeIndex];

    _index = safeIndex;
    resolving = true;
    hasSource = false;
    error = null;
    duration = Duration.zero;
    position.value = Duration.zero;
    notifyListeners();

    try {
      await player.stop();
      final url = await _resolveAudioUrl(song.id);
      if (token != _token) return;

      final uri = Uri.parse(url);
      try {
        await player.setAudioSource(
          AudioSource.uri(uri, headers: kStreamHeaders),
        );
      } catch (_) {
        if (token != _token) return;
        // Fallback: retry once with no custom headers.
        await player.setAudioSource(AudioSource.uri(uri));
      }
      if (token != _token) return;

      hasSource = true;
      resolving = false;
      notifyListeners();

      // Not awaited: play() completes only when playback finishes.
      unawaited(player.play());
    } catch (e) {
      if (token != _token) return;
      resolving = false;
      hasSource = false;
      error = 'Could not load this track. Tap play to retry.';
      notifyListeners();
    }
  }

  Future<void> togglePlayPause() async {
    if (current == null || resolving) return;

    if (!hasSource) {
      await _playAt(_index);
      return;
    }

    if (playerState.processingState == ProcessingState.completed) {
      await player.seek(Duration.zero);
      unawaited(player.play());
      return;
    }

    if (player.playing) {
      await player.pause();
    } else {
      unawaited(player.play());
    }
  }

  Future<void> next() async {
    if (_queue.isEmpty) return;
    await _playAt(_index + 1);
  }

  Future<void> previous() async {
    if (_queue.isEmpty) return;
    if (hasSource && position.value > const Duration(seconds: 3)) {
      await player.seek(Duration.zero);
      position.value = Duration.zero;
      return;
    }
    await _playAt(_index - 1);
  }

  Future<void> seek(Duration target) async {
    if (!hasSource) return;
    await player.seek(target);
    position.value = target;
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _eventSub?.cancel();
    player.dispose();
    yt.close();
    position.dispose();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Navigation helpers
// ---------------------------------------------------------------------------

void openNowPlaying(BuildContext context, PlayerController controller) {
  Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 380),
      reverseTransitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) =>
          NowPlayingScreen(controller: controller),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        );
      },
    ),
  );
}

// ---------------------------------------------------------------------------
// Root screen: tabs + persistent mini-player
// ---------------------------------------------------------------------------

class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  late final PlayerController _controller;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _controller = PlayerController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        bottom: false,
        child: IndexedStack(
          index: _tab,
          children: [
            SearchScreen(controller: _controller),
            LibraryScreen(controller: _controller),
          ],
        ),
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MiniPlayer(controller: _controller),
          Container(
            decoration: const BoxDecoration(
              color: Colors.black,
              border: Border(
                top: BorderSide(color: Colors.white12, width: 0.5),
              ),
            ),
            child: BottomNavigationBar(
              currentIndex: _tab,
              onTap: (i) => setState(() => _tab = i),
              backgroundColor: Colors.black,
              items: const [
                BottomNavigationBarItem(
                  icon: Icon(Icons.search),
                  label: 'Search',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.library_music_outlined),
                  activeIcon: Icon(Icons.library_music),
                  label: 'Library',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Mini-player
// ---------------------------------------------------------------------------

class MiniPlayer extends StatelessWidget {
  final PlayerController controller;

  const MiniPlayer({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final song = controller.current;
        if (song == null) return const SizedBox.shrink();

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => openNowPlaying(context, controller),
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            decoration: BoxDecoration(
              color: kSurface,
              borderRadius: BorderRadius.circular(18),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 10, 6, 8),
                  child: Row(
                    children: [
                      ArtImage(
                        song: song,
                        size: 48,
                        radius: 12,
                        useMaxRes: false,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              song.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              song.author,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        width: 48,
                        height: 48,
                        child: controller.isBusy
                            ? const Padding(
                                padding: EdgeInsets.all(14),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : IconButton(
                                iconSize: 30,
                                color: Colors.white,
                                onPressed: controller.togglePlayPause,
                                icon: Icon(
                                  controller.isPlaying
                                      ? Icons.pause
                                      : Icons.play_arrow,
                                ),
                              ),
                      ),
                      IconButton(
                        iconSize: 28,
                        color: Colors.white,
                        onPressed: controller.next,
                        icon: const Icon(Icons.skip_next),
                      ),
                    ],
                  ),
                ),
                ValueListenableBuilder<Duration>(
                  valueListenable: controller.position,
                  builder: (context, pos, _) {
                    final durMs = controller.duration.inMilliseconds;
                    final value = (controller.hasSource && durMs > 0)
                        ? (pos.inMilliseconds / durMs).clamp(0.0, 1.0)
                        : 0.0;
                    return LinearProgressIndicator(
                      value: value,
                      minHeight: 2,
                      backgroundColor: Colors.white12,
                      valueColor:
                          const AlwaysStoppedAnimation<Color>(Colors.white),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Search screen
// ---------------------------------------------------------------------------

class SearchScreen extends StatefulWidget {
  final PlayerController controller;

  const SearchScreen({super.key, required this.controller});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _textController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  List<Song> _results = [];
  bool _loading = false;
  bool _hasSearched = false;
  String? _error;
  int _searchToken = 0;

  @override
  void dispose() {
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _runSearch() async {
    final query = _textController.text.trim();
    if (query.isEmpty) return;
    _focusNode.unfocus();

    final token = ++_searchToken;
    setState(() {
      _loading = true;
      _error = null;
      _hasSearched = true;
    });

    try {
      final results = await widget.controller.search(query);
      if (!mounted || token != _searchToken) return;
      setState(() {
        _results = results;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || token != _searchToken) return;
      setState(() {
        _results = [];
        _loading = false;
        _error = 'Search failed. Check your connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Search',
            style: TextStyle(
              color: Colors.white,
              fontSize: 34,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.8,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _textController,
            focusNode: _focusNode,
            style: const TextStyle(color: Colors.white, fontSize: 16),
            cursorColor: Colors.white,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _runSearch(),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              filled: true,
              fillColor: kSurface,
              hintText: 'Songs, artists',
              hintStyle: const TextStyle(color: Colors.white38),
              prefixIcon: const Icon(Icons.search, color: Colors.white54),
              suffixIcon: _textController.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () {
                        _textController.clear();
                        setState(() {});
                      },
                    ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: const BorderSide(color: Colors.white24),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(child: _buildResults()),
        ],
      ),
    );
  }

  Widget _buildResults() {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white54, fontSize: 14),
        ),
      );
    }

    if (!_hasSearched) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.graphic_eq, color: Colors.white24, size: 56),
            SizedBox(height: 12),
            Text(
              'Find something to play',
              style: TextStyle(color: Colors.white38, fontSize: 14),
            ),
          ],
        ),
      );
    }

    if (_results.isEmpty) {
      return const Center(
        child: Text(
          'No results',
          style: TextStyle(color: Colors.white38, fontSize: 14),
        ),
      );
    }

    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final currentId = widget.controller.current?.id;
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 16),
          itemCount: _results.length,
          itemBuilder: (context, i) {
            final song = _results[i];
            return SongTile(
              song: song,
              isCurrent: song.id == currentId,
              onTap: () => widget.controller.playQueue(_results, i),
            );
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Library screen (Liked Songs)
// ---------------------------------------------------------------------------

class LibraryScreen extends StatelessWidget {
  final PlayerController controller;

  const LibraryScreen({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final songs = controller.liked;
        final currentId = controller.current?.id;

        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Library',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.8,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Liked Songs',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          songs.length == 1 ? '1 track' : '${songs.length} tracks',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (songs.isNotEmpty)
                    Container(
                      width: 52,
                      height: 52,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        iconSize: 30,
                        color: Colors.black,
                        onPressed: () =>
                            controller.playQueue(List<Song>.of(songs), 0),
                        icon: const Icon(Icons.play_arrow),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: songs.isEmpty
                    ? const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.favorite_border,
                                color: Colors.white24, size: 56),
                            SizedBox(height: 12),
                            Text(
                              'Songs you like will appear here',
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 16),
                        itemCount: songs.length,
                        itemBuilder: (context, i) {
                          final song = songs[i];
                          return SongTile(
                            song: song,
                            isCurrent: song.id == currentId,
                            onTap: () => controller.playQueue(
                              List<Song>.of(songs),
                              i,
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.favorite, color: kAccent),
                              onPressed: () => controller.toggleLike(song),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Shared list tile
// ---------------------------------------------------------------------------

class SongTile extends StatelessWidget {
  final Song song;
  final bool isCurrent;
  final VoidCallback onTap;
  final Widget? trailing;

  const SongTile({
    super.key,
    required this.song,
    required this.isCurrent,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            ArtImage(song: song, size: 56, radius: 12, useMaxRes: false),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isCurrent ? Colors.white : Colors.white70,
                      fontSize: 15,
                      fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    song.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white38, fontSize: 13),
                  ),
                ],
              ),
            ),
            if (isCurrent)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Icon(Icons.graphic_eq, color: Colors.white, size: 20),
              ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Now Playing (full-screen)
// ---------------------------------------------------------------------------

class NowPlayingScreen extends StatelessWidget {
  final PlayerController controller;

  const NowPlayingScreen({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onVerticalDragEnd: (details) {
            if ((details.primaryVelocity ?? 0) > 400) {
              Navigator.of(context).maybePop();
            }
          },
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final song = controller.current;
              if (song == null) {
                return Center(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('Nothing playing'),
                  ),
                );
              }
              final liked = controller.isLiked(song.id);

              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                    child: Row(
                      children: [
                        IconButton(
                          iconSize: 32,
                          color: Colors.white,
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: const Icon(Icons.keyboard_arrow_down),
                        ),
                        const Expanded(
                          child: Text(
                            'NOW PLAYING',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 2.4,
                            ),
                          ),
                        ),
                        const SizedBox(width: 48),
                      ],
                    ),
                  ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final side = (constraints.maxWidth - 56)
                            .clamp(100.0, 460.0)
                            .toDouble();
                        final maxH =
                            (constraints.maxHeight - 16).clamp(100.0, 460.0);
                        final artSize = side < maxH ? side : maxH.toDouble();
                        return Center(
                          child: SizedBox(
                            width: artSize,
                            height: artSize,
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 350),
                              child: ArtImage(
                                key: ValueKey<String>(song.id),
                                song: song,
                                size: artSize,
                                radius: 24,
                                useMaxRes: true,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(28, 16, 12, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                song.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 24,
                                  fontWeight: FontWeight.w700,
                                  height: 1.2,
                                  letterSpacing: -0.3,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                song.author,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white60,
                                  fontSize: 16,
                                ),
                              ),
                              if (controller.error != null) ...[
                                const SizedBox(height: 6),
                                Text(
                                  controller.error!,
                                  style: const TextStyle(
                                    color: Color(0xFFFF6B6B),
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        IconButton(
                          iconSize: 30,
                          onPressed: () => controller.toggleLike(song),
                          icon: Icon(
                            liked ? Icons.favorite : Icons.favorite_border,
                            color: liked ? kAccent : Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: SeekBar(controller: controller),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        iconSize: 40,
                        color: Colors.white,
                        onPressed: controller.previous,
                        icon: const Icon(Icons.skip_previous),
                      ),
                      const SizedBox(width: 20),
                      Container(
                        width: 72,
                        height: 72,
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                        child: controller.isBusy
                            ? const Padding(
                                padding: EdgeInsets.all(22),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: Colors.black,
                                ),
                              )
                            : IconButton(
                                iconSize: 40,
                                color: Colors.black,
                                onPressed: controller.togglePlayPause,
                                icon: Icon(
                                  controller.isPlaying
                                      ? Icons.pause
                                      : Icons.play_arrow,
                                ),
                              ),
                      ),
                      const SizedBox(width: 20),
                      IconButton(
                        iconSize: 40,
                        color: Colors.white,
                        onPressed: controller.next,
                        icon: const Icon(Icons.skip_next),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Seek bar (ultra-thin slider)
// ---------------------------------------------------------------------------

class SeekBar extends StatefulWidget {
  final PlayerController controller;

  const SeekBar({super.key, required this.controller});

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _dragMs;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;

    return ListenableBuilder(
      listenable: Listenable.merge([c, c.position]),
      builder: (context, _) {
        final durMs = c.duration.inMilliseconds.toDouble();
        final enabled = durMs > 0 && c.hasSource;
        final maxValue = enabled ? durMs : 1.0;
        final raw = _dragMs ?? c.position.value.inMilliseconds.toDouble();
        final value = enabled ? raw.clamp(0.0, maxValue).toDouble() : 0.0;
        final shownPos = _dragMs != null
            ? Duration(milliseconds: _dragMs!.round())
            : c.position.value;

        return Column(
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                activeTrackColor: Colors.white,
                inactiveTrackColor: Colors.white24,
                disabledActiveTrackColor: Colors.white24,
                disabledInactiveTrackColor: Colors.white12,
                thumbColor: Colors.white,
                disabledThumbColor: Colors.white24,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: SliderComponentShape.noOverlay,
                trackShape: const RectangularSliderTrackShape(),
              ),
              child: Slider(
                min: 0,
                max: maxValue,
                value: value,
                onChangeStart:
                    enabled ? (v) => setState(() => _dragMs = v) : null,
                onChanged: enabled ? (v) => setState(() => _dragMs = v) : null,
                onChangeEnd: enabled
                    ? (v) async {
                        final target = Duration(milliseconds: v.round());
                        await c.seek(target);
                        if (!mounted) return;
                        setState(() => _dragMs = null);
                      }
                    : null,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    formatDuration(shownPos),
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    enabled ? formatDuration(c.duration) : '--:--',
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Album art widget (max-res thumbnail with automatic fallback)
// ---------------------------------------------------------------------------

class ArtImage extends StatelessWidget {
  final Song song;
  final double size;
  final double radius;
  final bool useMaxRes;

  const ArtImage({
    super.key,
    required this.song,
    required this.size,
    required this.radius,
    required this.useMaxRes,
  });

  Widget _placeholder() {
    return Container(
      width: size,
      height: size,
      color: kSurface,
      child: Center(
        child: Icon(
          Icons.music_note,
          color: Colors.white24,
          size: size * 0.4,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primary = useMaxRes ? song.thumbnailUrl : song.fallbackThumbnailUrl;
    final secondary = useMaxRes ? song.fallbackThumbnailUrl : song.thumbnailUrl;

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: Image.network(
          primary,
          width: size,
          height: size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return _placeholder();
          },
          errorBuilder: (context, error, stack) {
            return Image.network(
              secondary,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (context, error2, stack2) => _placeholder(),
            );
          },
        ),
      ),
    );
  }
}
