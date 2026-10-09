import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt_explode;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.black,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Colors.black,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const OverrideMusicApp());
}

class OverrideMusicApp extends StatefulWidget {
  const OverrideMusicApp({super.key});

  @override
  State<OverrideMusicApp> createState() => _OverrideMusicAppState();

  static _OverrideMusicAppState? of(BuildContext context) =>
      context.findAncestorStateOfType<_OverrideMusicAppState>();
}

class _OverrideMusicAppState extends State<OverrideMusicApp> {
  String _currentThemeKey = 'black';

  final Map<String, Color> themes = {
    'black': Colors.black,
    'indigo': const Color(0xFF181C32), // Google Pixel 10 Indigo subtle tint
    'red': const Color(0xFF241212),    // Subtle Red
    'green': const Color(0xFF112214),  // Subtle Green
    'blue': const Color(0xFF111928),   // Subtle Blue
  };

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _currentThemeKey = prefs.getString('app_theme') ?? 'black';
    });
  }

  Future<void> setTheme(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_theme', key);
    setState(() {
      _currentThemeKey = key;
    });
  }

  Color get currentBackgroundColor => themes[_currentThemeKey] ?? Colors.black;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Override Music',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: currentBackgroundColor,
        canvasColor: currentBackgroundColor,
        colorScheme: ColorScheme.dark(
          primary: Colors.white,
          secondary: Colors.white24,
          surface: currentBackgroundColor,
        ),
      ),
      home: const MainContainer(),
    );
  }
}

class Song {
  final String videoId;
  final String title;
  final String author;
  final String thumbnailUrl;
  final bool isLocal;
  final String? filePath;

  Song({
    required this.videoId,
    required this.title,
    required this.author,
    required this.thumbnailUrl,
    this.isLocal = false,
    this.filePath,
  });

  Map<String, dynamic> toJson() => {
        'videoId': videoId,
        'title': title,
        'author': author,
        'thumbnailUrl': thumbnailUrl,
        'isLocal': isLocal,
        'filePath': filePath,
      };

  factory Song.fromJson(Map<String, dynamic> json) => Song(
        videoId: json['videoId'],
        title: json['title'],
        author: json['author'],
        thumbnailUrl: json['thumbnailUrl'],
        isLocal: json['isLocal'] ?? false,
        filePath: json['filePath'],
      );
}

class MainContainer extends StatefulWidget {
  const MainContainer({super.key});

  @override
  State<MainContainer> createState() => _MainContainerState();
}

class _MainContainerState extends State<MainContainer> {
  int _currentIndex = 0;
  
  final AudioPlayer _audioPlayer = AudioPlayer();
  
  Song? _currentSong;
  List<Song> _queue = [];
  int _queueIndex = 0;
  bool _isPlaying = false;
  bool _isLoadingTrack = false;
  String? _errorMessage;

  List<Song> _likedSongs = [];
  List<Song> _recentSongs = [];
  List<Song> _searchResults = [];
  List<Song> _localSongs = [];
  bool _isSearching = false;
  bool _isScanningLocal = false;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadData();
    _scanLocalFiles();
    _audioPlayer.playerStateStream.listen((state) {
      if (mounted) {
        setState(() {
          _isPlaying = state.playing;
        });
      }
    });
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    
    final String? likedJson = prefs.getString('liked_songs');
    if (likedJson != null) {
      final List decoded = jsonDecode(likedJson);
      _likedSongs = decoded.map((e) => Song.fromJson(e)).toList();
    }

    final String? recentJson = prefs.getString('recent_songs');
    if (recentJson != null) {
      final List decoded = jsonDecode(recentJson);
      _recentSongs = decoded.map((e) => Song.fromJson(e)).toList();
    }
    setState(() {});
  }

  Future<void> _saveLikedSongs() async {
    final prefs = await SharedPreferences.getInstance();
    final String encoded = jsonEncode(_likedSongs.map((e) => e.toJson()).toList());
    await prefs.setString('liked_songs', encoded);
  }

  Future<void> _saveRecentSongs() async {
    final prefs = await SharedPreferences.getInstance();
    final String encoded = jsonEncode(_recentSongs.map((e) => e.toJson()).toList());
    await prefs.setString('recent_songs', encoded);
  }

  void clearRecentHistory() {
    setState(() {
      _recentSongs.clear();
    });
    _saveRecentSongs();
  }

  Future<void> _scanLocalFiles() async {
    setState(() => _isScanningLocal = true);
    try {
      List<Song> foundSongs = [];
      List<Directory> directories = [
        Directory('/storage/emulated/0/Download'),
        Directory('/storage/emulated/0/Music'),
      ];

      for (var dir in directories) {
        if (await dir.exists()) {
          try {
            await for (var entity in dir.list(recursive: true, followLinks: false)) {
              if (entity is File) {
                String path = entity.path.toLowerCase();
                if (path.endsWith('.mp3') || path.endsWith('.m4a') || path.endsWith('.wav') || path.endsWith('.aac')) {
                  String fileName = entity.uri.pathSegments.last;
                  foundSongs.add(Song(
                    videoId: 'local_${path.hashCode}',
                    title: fileName.replaceAll(RegExp(r'\.[^\\]*$'), ''),
                    author: 'Local Device',
                    thumbnailUrl: '',
                    isLocal: true,
                    filePath: entity.path,
                  ));
                }
              }
            }
          } catch (_) {}
        }
      }

      if (mounted) {
        setState(() {
          _localSongs = foundSongs;
          _isScanningLocal = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isScanningLocal = false);
    }
  }

  void _addToRecents(Song song) {
    setState(() {
      _recentSongs.removeWhere((s) => s.videoId == song.videoId);
      _recentSongs.insert(0, song);
      if (_recentSongs.length > 20) {
        _recentSongs.removeLast();
      }
    });
    _saveRecentSongs();
  }

  bool _isLiked(Song song) {
    return _likedSongs.any((s) => s.videoId == song.videoId);
  }

  void _toggleLike(Song song) {
    setState(() {
      if (_isLiked(song)) {
        _likedSongs.removeWhere((s) => s.videoId == song.videoId);
      } else {
        _likedSongs.add(song);
      }
    });
    _saveLikedSongs();
  }

  Future<void> _playSong(Song song, {List<Song>? newQueue, int index = 0}) async {
    setState(() {
      _currentSong = song;
      _isLoadingTrack = true;
      _errorMessage = null;
      if (newQueue != null) {
        _queue = newQueue;
        _queueIndex = index;
      }
    });

    _addToRecents(song);

    try {
      if (song.isLocal && song.filePath != null) {
        await _audioPlayer.setFilePath(song.filePath!);
        await _audioPlayer.play();
        if (mounted) setState(() => _isLoadingTrack = false);
        return;
      }

      var yt = yt_explode.YoutubeExplode();
      var manifest = await yt.videos.streamsClient.getManifest(song.videoId);
      var audioStream = manifest.audioOnly.withHighestBitrate();
      var audioUrl = audioStream.url.toString();
      yt.close();

      await _audioPlayer.setUrl(audioUrl);
      await _audioPlayer.play();

      if (mounted) {
        setState(() {
          _isLoadingTrack = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoadingTrack = false;
          _errorMessage = "Could not load track. Tap to retry.";
        });
      }
    }
  }

  Future<void> _searchMusic(String query) async {
    if (query.trim().isEmpty) return;
    setState(() {
      _isSearching = true;
      _searchResults = [];
    });

    List<Song> results = [];
    try {
      final response = await http.get(
        Uri.parse('https://pipedapi.kavin.rocks/search?q=${Uri.encodeComponent(query)}&filter=videos'),
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final items = data['items'] as List?;
        if (items != null) {
          for (var item in items) {
            String url = item['url'] ?? '';
            String videoId = url.contains('?v=') ? url.split('?v=').last : '';
            if (videoId.isNotEmpty) {
              results.add(Song(
                videoId: videoId,
                title: item['title'] ?? 'Unknown Title',
                author: item['uploaderName'] ?? 'Unknown Artist',
                thumbnailUrl: item['thumbnail'] ?? '',
              ));
            }
          }
        }
      }
    } catch (_) {}

    if (mounted) {
      setState(() {
        _searchResults = results;
        _isSearching = false;
      });
    }
  }

  void _openNowPlaying() {
    if (_currentSong == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => FullPlayerSheet(parent: this),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bgColor = OverrideMusicApp.of(context)?.currentBackgroundColor ?? Colors.black;
    return Scaffold(
      backgroundColor: bgColor,
      body: Stack(
        children: [
          IndexedStack(
            index: _currentIndex,
            children: [
              HomeTab(parent: this),
              SearchTab(parent: this),
              LocalTab(parent: this),
              LibraryTab(parent: this),
              const MiniFpsGameTab(),
            ],
          ),
          if (_currentSong != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 80,
              child: MiniPlayer(parent: this),
            ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        backgroundColor: bgColor,
        selectedItemColor: Colors.white,
        unselectedItemColor: Colors.white54,
        type: BottomNavigationBarType.fixed,
        onTap: (index) => setState(() => _currentIndex = index),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.search), label: 'Search'),
          BottomNavigationBarItem(icon: Icon(Icons.folder_open), label: 'Local'),
          BottomNavigationBarItem(icon: Icon(Icons.library_music), label: 'Library'),
          BottomNavigationBarItem(icon: Icon(Icons.sports_esports), label: 'FPS Game'),
        ],
      ),
    );
  }
}

class SettingsScreen extends StatelessWidget {
  final _MainContainerState parent;
  const SettingsScreen({super.key, required this.parent});

  @override
  Widget build(BuildContext context) {
    final appState = OverrideMusicApp.of(context);
    final currentKey = appState?._currentThemeKey ?? 'black';

    return Scaffold(
      backgroundColor: appState?.currentBackgroundColor ?? Colors.black,
      appBar: AppBar(
        title: const Text('Settings', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: ListView(
          children: [
            const Text('Appearance & Themes', style: TextStyle(color: Colors.white54, fontSize: 14, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ListTile(
              title: const Text('Select Theme', style: TextStyle(color: Colors.white)),
              subtitle: Text('Current: ${currentKey.toUpperCase()}', style: const TextStyle(color: Colors.white54)),
              trailing: DropdownButton<String>(
                value: currentKey,
                dropdownColor: const Color(0xFF1E1E1E),
                style: const TextStyle(color: Colors.white),
                underline: const SizedBox(),
                items: const [
                  DropdownMenuItem(value: 'black', child: Text('Pure Black')),
                  DropdownMenuItem(value: 'indigo', child: Text('Pixel 10 Indigo')),
                  DropdownMenuItem(value: 'red', child: Text('Subtle Red')),
                  DropdownMenuItem(value: 'green', child: Text('Subtle Green')),
                  DropdownMenuItem(value: 'blue', child: Text('Subtle Blue')),
                ],
                onChanged: (String? val) {
                  if (val != null) {
                    appState?.setTheme(val);
                  }
                },
              ),
            ),
            const Divider(color: Colors.white24),
            const Text('App Info', style: TextStyle(color: Colors.white54, fontSize: 14, fontWeight: FontWeight.bold)),
            const ListTile(
              title: Text('App Name', style: TextStyle(color: Colors.white)),
              trailing: Text('Override Music', style: TextStyle(color: Colors.white54)),
            ),
            const ListTile(
              title: Text('Routing Engine', style: TextStyle(color: Colors.white)),
              trailing: Text('Piped API / YoutubeExplode', style: TextStyle(color: Colors.white54)),
            ),
            const Divider(color: Colors.white24),
            const Text('Data & Storage', style: TextStyle(color: Colors.white54, fontSize: 14, fontWeight: FontWeight.bold)),
            ListTile(
              title: const Text('Clear Recently Played History', style: TextStyle(color: Colors.white)),
              trailing: const Icon(Icons.delete_outline, color: Colors.redAccent),
              onTap: () {
                parent.clearRecentHistory();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('History cleared')),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class HomeTab extends StatelessWidget {
  final _MainContainerState parent;
  const HomeTab({super.key, required this.parent});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Welcome back',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
                ),
                IconButton(
                  icon: const Icon(Icons.settings, color: Colors.white),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => SettingsScreen(parent: parent)),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 20),
            const Text(
              'Recently Played',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white70),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: parent._recentSongs.isEmpty
                  ? const Center(
                      child: Text(
                        'No history yet. Search and play a track!',
                        style: TextStyle(color: Colors.white54),
                      ),
                    )
                  : ListView.builder(
                      itemCount: parent._recentSongs.length,
                      itemBuilder: (context, index) {
                        final song = parent._recentSongs[index];
                        return ListTile(
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: song.thumbnailUrl.isNotEmpty
                                ? Image.network(song.thumbnailUrl, width: 50, height: 50, fit: BoxFit.cover,
                                    errorBuilder: (c, e, s) => Container(width: 50, height: 50, color: Colors.white24, child: const Icon(Icons.music_note)))
                                : Container(width: 50, height: 50, color: Colors.white24, child: const Icon(Icons.music_note)),
                          ),
                          title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white)),
                          subtitle: Text(song.author, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white54)),
                          onTap: () => parent._playSong(song, newQueue: parent._recentSongs, index: index),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class LocalTab extends StatelessWidget {
  final _MainContainerState parent;
  const LocalTab({super.key, required this.parent});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Local Files',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, color: Colors.white),
                  onPressed: parent._scanLocalFiles,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: parent._isScanningLocal
                  ? const Center(child: CircularProgressIndicator(color: Colors.white))
                  : parent._localSongs.isEmpty
                      ? const Center(
                          child: Text(
                            'No local music files found.\nMake sure you have audio files in your Download or Music folder!',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white54),
                          ),
                        )
                      : ListView.builder(
                          itemCount: parent._localSongs.length,
                          itemBuilder: (context, index) {
                            final song = parent._localSongs[index];
                            return ListTile(
                              leading: Container(
                                width: 50,
                                height: 50,
                                decoration: BoxDecoration(
                                  color: Colors.white24,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(Icons.audio_file, color: Colors.white),
                              ),
                              title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white)),
                              subtitle: Text(song.author, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white54)),
                              onTap: () => parent._playSong(song, newQueue: parent._localSongs, index: index),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

class MiniFpsGameTab extends StatefulWidget {
  const MiniFpsGameTab({super.key});

  @override
  State<MiniFpsGameTab> createState() => _MiniFpsGameTabState();
}

class _MiniFpsGameTabState extends State<MiniFpsGameTab> {
  int _score = 0;
  int _timeLeft = 20;
  bool _isPlaying = false;
  Timer? _gameTimer;
  Timer? _targetTimer;
  
  // Target position coordinates (percentages 0.1 to 0.8)
  double _targetX = 0.5;
  double _targetY = 0.5;
  bool _targetVisible = false;

  void _startGame() {
    setState(() {
      _score = 0;
      _timeLeft = 20;
      _isPlaying = true;
      _spawnTarget();
    });

    _gameTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        if (_timeLeft > 0) {
          _timeLeft--;
        } else {
          _stopGame();
        }
      });
    });
  }

  void _spawnTarget() {
    if (!_isPlaying) return;
    final random = Random();
    setState(() {
      _targetX = 0.15 + random.nextDouble() * 0.7;
      _targetY = 0.2 + random.nextDouble() * 0.6;
      _targetVisible = true;
    });

    // Move target every 1.2 seconds if not clicked
    _targetTimer?.cancel();
    _targetTimer = Timer(const Duration(milliseconds: 1200), () {
      if (_isPlaying) _spawnTarget();
    });
  }

  void _shootTarget() {
    if (!_isPlaying || !_targetVisible) return;
    setState(() {
      _score += 100;
      _targetVisible = false;
    });
    _targetTimer?.cancel();
    _spawnTarget();
  }

  void _stopGame() {
    _gameTimer?.cancel();
    _targetTimer?.cancel();
    setState(() {
      _isPlaying = false;
      _targetVisible = false;
    });
  }

  @override
  void dispose() {
    _gameTimer?.cancel();
    _targetTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Aim Trainer FPS',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
                ),
                Text(
                  'Score: $_score',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.greenAccent),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Time: ${_timeLeft}s',
                  style: const TextStyle(fontSize: 16, color: Colors.white54),
                ),
                if (!_isPlaying)
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.white24),
                    onPressed: _startGame,
                    child: const Text('Start Game', style: TextStyle(color: Colors.white)),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF0D0D0D),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white24),
                ),
                child: Stack(
                  children: [
                    // Center crosshair
                    const Center(
                      child: Icon(Icons.add, color: Colors.white24, size: 36),
                    ),
                    if (_isPlaying && _targetVisible)
                      Positioned(
                        left: MediaQuery.of(context).size.width * _targetX - 35,
                        top: 300 * _targetY - 35,
                        child: GestureDetector(
                          onTap: _shootTarget,
                          child: Container(
                            width: 70,
                            height: 70,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.redAccent,
                              border: Border.all(color: Colors.white, width: 3),
                              boxShadow: const [BoxShadow(color: Colors.red, blurRadius: 10)],
                            ),
                            child: const Center(
                              child: CircleAvatar(
                                radius: 12,
                                backgroundColor: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (!_isPlaying)
                      Center(
                        child: Text(
                          _score > 0 ? 'Game Over!\nFinal Score: $_score' : 'Tap Start to Play FPS Aim Trainer!',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 18, color: Colors.white54),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SearchTab extends StatelessWidget {
  final _MainContainerState parent;
  const SearchTab({super.key, required this.parent});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Search',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: parent._searchController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Search artists, songs...',
                hintStyle: const TextStyle(color: Colors.white54),
                filled: true,
                fillColor: const Color(0xFF121212),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search, color: Colors.white),
                  onPressed: () => parent._searchMusic(parent._searchController.text),
                ),
              ),
              onSubmitted: (val) => parent._searchMusic(val),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: parent._isSearching
                  ? const Center(child: CircularProgressIndicator(color: Colors.white))
                  : ListView.builder(
                      itemCount: parent._searchResults.length,
                      itemBuilder: (context, index) {
                        final song = parent._searchResults[index];
                        return ListTile(
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(song.thumbnailUrl, width: 50, height: 50, fit: BoxFit.cover,
                              errorBuilder: (c, e, s) => Container(width: 50, height: 50, color: Colors.white24),
                            ),
                          ),
                          title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white)),
                          subtitle: Text(song.author, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white54)),
                          onTap: () => parent._playSong(song, newQueue: parent._searchResults, index: index),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class LibraryTab extends StatelessWidget {
  final _MainContainerState parent;
  const LibraryTab({super.key, required this.parent});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Liked Songs',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: parent._likedSongs.isEmpty
                  ? const Center(child: Text('No liked songs yet.', style: TextStyle(color: Colors.white54)))
                  : ListView.builder(
                      itemCount: parent._likedSongs.length,
                      itemBuilder: (context, index) {
                        final song = parent._likedSongs[index];
                        return ListTile(
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: song.thumbnailUrl.isNotEmpty
                                ? Image.network(song.thumbnailUrl, width: 50, height: 50, fit: BoxFit.cover,
                                    errorBuilder: (c, e, s) => Container(width: 50, height: 50, color: Colors.white24))
                                : Container(width: 50, height: 50, color: Colors.white24, child: const Icon(Icons.music_note)),
                          ),
                          title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white)),
                          subtitle: Text(song.author, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white54)),
                          trailing: IconButton(
                            icon: const Icon(Icons.favorite, color: Colors.white),
                            onPressed: () => parent._toggleLike(song),
                          ),
                          onTap: () => parent._playSong(song, newQueue: parent._likedSongs, index: index),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class MiniPlayer extends StatelessWidget {
  final _MainContainerState parent;
  const MiniPlayer({super.key, required this.parent});

  @override
  Widget build(BuildContext context) {
    final song = parent._currentSong!;
    return GestureDetector(
      onTap: parent._openNowPlaying,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: song.thumbnailUrl.isNotEmpty
                  ? Image.network(song.thumbnailUrl, width: 45, height: 45, fit: BoxFit.cover,
                      errorBuilder: (c, e, s) => Container(width: 45, height: 45, color: Colors.white24))
                  : Container(width: 45, height: 45, color: Colors.white24, child: const Icon(Icons.music_note, size: 20)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  Text(song.author, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                ],
              ),
            ),
            IconButton(
              icon: Icon(parent._isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white),
              onPressed: () {
                if (parent._isPlaying) {
                  parent._audioPlayer.pause();
                } else {
                  parent._audioPlayer.play();
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

class FullPlayerSheet extends StatelessWidget {
  final _MainContainerState parent;
  const FullPlayerSheet({super.key, required this.parent});

  @override
  Widget build(BuildContext context) {
    final song = parent._currentSong!;
    final isLiked = parent._isLiked(song);
    final bgColor = OverrideMusicApp.of(context)?.currentBackgroundColor ?? Colors.black;

    return Container(
      color: bgColor,
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white, size: 30),
                onPressed: () => Navigator.pop(context),
              ),
              const Text('NOW PLAYING', style: TextStyle(color: Colors.white54, letterSpacing: 1.5, fontSize: 12)),
              const SizedBox(width: 30),
            ],
          ),
          const SizedBox(height: 40),
          ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: song.thumbnailUrl.isNotEmpty
                ? Image.network(song.thumbnailUrl, width: 300, height: 300, fit: BoxFit.cover,
                    errorBuilder: (c, e, s) => Container(width: 300, height: 300, color: Colors.white24, child: const Icon(Icons.music_note, size: 80)))
                : Container(width: 300, height: 300, color: Colors.white24, child: const Icon(Icons.music_note, size: 80)),
          ),
          const SizedBox(height: 30),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
                    const SizedBox(height: 4),
                    Text(song.author, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, color: Colors.white54)),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(isLiked ? Icons.favorite : Icons.favorite_border, color: isLiked ? Colors.white : Colors.white54, size: 28),
                onPressed: () => parent._toggleLike(song),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (parent._isLoadingTrack)
            const CircularProgressIndicator(color: Colors.white)
          else if (parent._errorMessage != null)
            Text(parent._errorMessage!, style: const TextStyle(color: Colors.redAccent, fontSize: 14)),
          const Spacer(),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.skip_previous, color: Colors.white, size: 40),
                onPressed: parent._queue.isNotEmpty
                    ? () {
                        int newIndex = (parent._queueIndex - 1) % parent._queue.length;
                        parent._playSong(parent._queue[newIndex], newQueue: parent._queue, index: newIndex);
                      }
                    : null,
              ),
              const SizedBox(width: 30),
              IconButton(
                icon: Icon(parent._isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled, color: Colors.white, size: 64),
                onPressed: () {
                  if (parent._isPlaying) {
                    parent._audioPlayer.pause();
                  } else {
                    parent._audioPlayer.play();
                  }
                },
              ),
              const SizedBox(width: 30),
              IconButton(
                icon: const Icon(Icons.skip_next, color: Colors.white, size: 40),
                onPressed: parent._queue.isNotEmpty
                    ? () {
                        int newIndex = (parent._queueIndex + 1) % parent._queue.length;
                        parent._playSong(parent._queue[newIndex], newQueue: parent._queue, index: newIndex);
                      }
                    : null,
              ),
            ],
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}
