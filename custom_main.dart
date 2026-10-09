import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

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
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: Colors.white),
          bodyMedium: TextStyle(color: Colors.white),
        ),
      ),
      home: const PlayerScreen(),
    );
  }
}

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

class Track {
  final String id;
  final String title;
  final String author;
  final String maxResThumb;
  final String highResThumb;

  const Track({
    required this.id,
    required this.title,
    required this.author,
    required this.maxResThumb,
    required this.highResThumb,
  });
}

// ---------------------------------------------------------------------------
// Player screen
// ---------------------------------------------------------------------------

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final YoutubeExplode _yt = YoutubeExplode();
  final AudioPlayer _player = AudioPlayer();

  final List<Track> _tracks = [];
  int _currentIndex = 0;

  bool _loadingPlaylist = true;
  String? _playlistError;

  bool _resolvingStream = false;
  bool _hasSource = false;
  String? _trackError;
  int _loadToken = 0;

  PlayerState _playerState = PlayerState(false, ProcessingState.idle);
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double? _dragValueMs;

  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<PlaybackEvent>? _eventSub;

  @override
  void initState() {
    super.initState();

    _stateSub = _player.playerStateStream.listen((state) {
      if (!mounted) return;
      setState(() => _playerState = state);
      if (state.processingState == ProcessingState.completed) {
        _skipNext();
      }
    });

    _positionSub = _player.positionStream.listen((pos) {
      if (!mounted) return;
      setState(() => _position = pos);
    });

    _durationSub = _player.durationStream.listen((dur) {
      if (!mounted) return;
      setState(() => _duration = dur ?? Duration.zero);
    });

    _eventSub = _player.playbackEventStream.listen(
      (_) {},
      onError: (Object e, StackTrace st) {
        if (!mounted) return;
        setState(() {
          _trackError = 'Playback error. Try another track.';
          _resolvingStream = false;
        });
      },
    );

    _loadPlaylist();
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _eventSub?.cancel();
    _player.dispose();
    _yt.close();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Data loading
  // -------------------------------------------------------------------------

  Future<void> _loadPlaylist() async {
    setState(() {
      _loadingPlaylist = true;
      _playlistError = null;
    });

    try {
      final results = await Future.wait<List<Track>>([
        _searchTracks('xaviersobased', 3),
        _searchTracks('Lil Peep', 3),
      ]);

      final seen = <String>{};
      final merged = <Track>[];
      for (final list in results) {
        for (final t in list) {
          if (seen.add(t.id)) merged.add(t);
        }
      }

      if (!mounted) return;

      if (merged.isEmpty) {
        setState(() {
          _loadingPlaylist = false;
          _playlistError = 'No tracks found. Check your connection.';
        });
        return;
      }

      setState(() {
        _tracks
          ..clear()
          ..addAll(merged);
        _currentIndex = 0;
        _loadingPlaylist = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingPlaylist = false;
        _playlistError = 'Could not load playlist.\n$e';
      });
    }
  }

  Future<List<Track>> _searchTracks(String query, int count) async {
    final results = await _yt.search.search(query);
    final out = <Track>[];
    for (final video in results) {
      if (video.isLive) continue;
      final d = video.duration;
      if (d != null && (d.inMinutes > 10 || d.inSeconds < 30)) continue;
      out.add(Track(
        id: video.id.value,
        title: video.title,
        author: video.author,
        maxResThumb: video.thumbnails.maxResUrl,
        highResThumb: video.thumbnails.highResUrl,
      ));
      if (out.length >= count) break;
    }
    return out;
  }

  Future<String> _resolveAudioUrl(String videoId) async {
    final manifest = await _yt.videos.streamsClient
        .getManifest(videoId)
        .timeout(const Duration(seconds: 25));

    final audioStreams = manifest.audioOnly.toList();
    if (audioStreams.isEmpty) {
      throw Exception('No audio streams available');
    }

    final m4aStreams =
        audioStreams.where((s) => s.container == StreamContainer.mp4).toList();
    final pool = m4aStreams.isNotEmpty ? m4aStreams : audioStreams;

    var best = pool.first;
    for (final s in pool) {
      if (s.bitrate.bitsPerSecond > best.bitrate.bitsPerSecond) {
        best = s;
      }
    }
    return best.url.toString();
  }

  // -------------------------------------------------------------------------
  // Playback control
  // -------------------------------------------------------------------------

  Future<void> _playIndex(int index) async {
    if (_tracks.isEmpty) return;
    final safeIndex = ((index % _tracks.length) + _tracks.length) % _tracks.length;
    final token = ++_loadToken;
    final track = _tracks[safeIndex];

    setState(() {
      _currentIndex = safeIndex;
      _resolvingStream = true;
      _trackError = null;
      _position = Duration.zero;
      _duration = Duration.zero;
      _dragValueMs = null;
      _hasSource = false;
    });

    try {
      await _player.stop();
      final url = await _resolveAudioUrl(track.id);
      if (!mounted || token != _loadToken) return;

      await _player.setUrl(url);
      if (!mounted || token != _loadToken) return;

      setState(() {
        _hasSource = true;
        _resolvingStream = false;
      });

      // Intentionally not awaited: play() completes only when playback ends.
      unawaited(_player.play());
    } catch (e) {
      if (!mounted || token != _loadToken) return;
      setState(() {
        _resolvingStream = false;
        _hasSource = false;
        _trackError = 'Could not load this track. Tap play to retry.';
      });
    }
  }

  Future<void> _togglePlayPause() async {
    if (_tracks.isEmpty || _resolvingStream) return;

    if (!_hasSource ||
        _playerState.processingState == ProcessingState.completed ||
        _playerState.processingState == ProcessingState.idle) {
      await _playIndex(_currentIndex);
      return;
    }

    if (_player.playing) {
      await _player.pause();
    } else {
      unawaited(_player.play());
    }
  }

  Future<void> _skipNext() async {
    if (_tracks.isEmpty) return;
    await _playIndex(_currentIndex + 1);
  }

  Future<void> _skipPrevious() async {
    if (_tracks.isEmpty) return;
    if (_hasSource && _position > const Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
      return;
    }
    await _playIndex(_currentIndex - 1);
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  String _fmt(Duration d) {
    final totalSeconds = d.inSeconds < 0 ? 0 : d.inSeconds;
    final m = totalSeconds ~/ 60;
    final s = totalSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  bool get _isPlaying =>
      _playerState.playing &&
      _playerState.processingState != ProcessingState.completed &&
      _playerState.processingState != ProcessingState.idle;

  bool get _isBusy =>
      _resolvingStream ||
      (_playerState.playing &&
          (_playerState.processingState == ProcessingState.loading ||
              _playerState.processingState == ProcessingState.buffering));

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_loadingPlaylist) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
            SizedBox(height: 20),
            Text(
              'Loading playlist',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 14,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
      );
    }

    if (_playlistError != null || _tracks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, color: Colors.white38, size: 48),
              const SizedBox(height: 16),
              Text(
                _playlistError ?? 'No tracks available.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: _loadPlaylist,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white38),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                ),
                child: const Text('RETRY'),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Expanded(child: _buildScrollableTop()),
        _buildBottomControls(),
      ],
    );
  }

  Widget _buildScrollableTop() {
    final track = _tracks[_currentIndex];
    final screenWidth = MediaQuery.of(context).size.width;
    final artSize = (screenWidth - 56).clamp(160.0, 420.0);

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'NOW PLAYING',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 2.4,
            ),
          ),
          const SizedBox(height: 20),
          Center(
            child: SizedBox(
              width: artSize,
              height: artSize,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                child: _AlbumArt(
                  key: ValueKey<String>(track.id),
                  primaryUrl: track.maxResThumb,
                  fallbackUrl: track.highResThumb,
                  size: artSize,
                  radius: 24,
                ),
              ),
            ),
          ),
          const SizedBox(height: 28),
          Text(
            track.title,
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
          const SizedBox(height: 6),
          Text(
            track.author,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white60,
              fontSize: 16,
              fontWeight: FontWeight.w400,
            ),
          ),
          if (_trackError != null) ...[
            const SizedBox(height: 10),
            Text(
              _trackError!,
              style: const TextStyle(
                color: Color(0xFFFF6B6B),
                fontSize: 13,
              ),
            ),
          ],
          const SizedBox(height: 32),
          const Text(
            'QUEUE',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 2.4,
            ),
          ),
          const SizedBox(height: 12),
          for (int i = 0; i < _tracks.length; i++) _buildQueueItem(i),
        ],
      ),
    );
  }

  Widget _buildQueueItem(int index) {
    final t = _tracks[index];
    final selected = index == _currentIndex;

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => _playIndex(index),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 52,
                height: 52,
                child: Image.network(
                  t.highResThumb,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stack) => Container(
                    color: const Color(0xFF121212),
                    child: const Icon(Icons.music_note, color: Colors.white24),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? Colors.white : Colors.white70,
                      fontSize: 15,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    t.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              Icon(
                _isPlaying ? Icons.graphic_eq : Icons.pause,
                color: Colors.white,
                size: 20,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomControls() {
    final durationMs = _duration.inMilliseconds.toDouble();
    final hasDuration = durationMs > 0 && _hasSource;
    final maxValue = hasDuration ? durationMs : 1.0;
    final rawValue = _dragValueMs ?? _position.inMilliseconds.toDouble();
    final sliderValue = hasDuration ? rawValue.clamp(0.0, maxValue) : 0.0;
    final shownPosition = _dragValueMs != null
        ? Duration(milliseconds: _dragValueMs!.round())
        : _position;

    return Container(
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
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
              thumbShape:
                  const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: SliderComponentShape.noOverlay,
              trackShape: const RectangularSliderTrackShape(),
            ),
            child: Slider(
              min: 0,
              max: maxValue,
              value: sliderValue,
              onChangeStart: hasDuration
                  ? (v) => setState(() => _dragValueMs = v)
                  : null,
              onChanged: hasDuration
                  ? (v) => setState(() => _dragValueMs = v)
                  : null,
              onChangeEnd: hasDuration
                  ? (v) async {
                      final target = Duration(milliseconds: v.round());
                      await _player.seek(target);
                      if (!mounted) return;
                      setState(() {
                        _position = target;
                        _dragValueMs = null;
                      });
                    }
                  : null,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _fmt(shownPosition),
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  hasDuration ? _fmt(_duration) : '--:--',
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                iconSize: 40,
                splashRadius: 28,
                color: Colors.white,
                onPressed: _skipPrevious,
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
                child: _isBusy
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
                        onPressed: _togglePlayPause,
                        icon: Icon(
                          _isPlaying ? Icons.pause : Icons.play_arrow,
                        ),
                      ),
              ),
              const SizedBox(width: 20),
              IconButton(
                iconSize: 40,
                splashRadius: 28,
                color: Colors.white,
                onPressed: _skipNext,
                icon: const Icon(Icons.skip_next),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Album art widget (max-res thumbnail with automatic fallback)
// ---------------------------------------------------------------------------

class _AlbumArt extends StatelessWidget {
  final String primaryUrl;
  final String fallbackUrl;
  final double size;
  final double radius;

  const _AlbumArt({
    super.key,
    required this.primaryUrl,
    required this.fallbackUrl,
    required this.size,
    required this.radius,
  });

  Widget _placeholder() {
    return Container(
      color: const Color(0xFF121212),
      child: const Center(
        child: Icon(Icons.music_note, color: Colors.white24, size: 64),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: Image.network(
          primaryUrl,
          width: size,
          height: size,
          fit: BoxFit.cover,
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return _placeholder();
          },
          errorBuilder: (context, error, stack) {
            return Image.network(
              fallbackUrl,
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
