import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
              const GamesTab(),
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
          BottomNavigationBarItem(icon: Icon(Icons.sports_esports), label: 'Games'),
        ],
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

class GamesTab extends StatefulWidget {
  const GamesTab({super.key});

  @override
  State<GamesTab> createState() => _GamesTabState();
}

class _GamesTabState extends State<GamesTab> {
  List<String> _board = List.filled(9, '');
  bool _xTurn = true;
  String _winner = '';

  void _tapped(int index) {
    if (_board[index] != '' || _winner != '') return;
    setState(() {
      _board[index] = _xTurn ? 'X' : 'O';
      _xTurn = !_xTurn;
      _checkWinner();
    });
  }

  void _checkWinner() {
    const winConditions = [
      [0, 1, 2], [3, 4, 5], [6, 7, 8], // rows
      [0, 3, 6], [1, 4, 7], [2, 5, 8], // columns
      [0, 4, 8], [2, 4, 6],           // diagonals
    ];

    for (var condition in winConditions) {
      String a = _board[condition[0]];
      String b = _board[condition[1]];
      String c = _board[condition[2]];
      if (a != '' && a == b && b == c) {
        setState(() {
          _winner = '$a Wins!';
        });
        return;
      }
    }

    if (!_board.contains('') && _winner == '') {
      setState(() {
        _winner = 'It\'s a Draw!';
      });
    }
  }

  void _resetGame() {
    setState(() {
      _board = List.filled(9, '');
      _xTurn = true;
      _winner = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Text(
              'Mini Games',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 8),
            const Text(
              'Tic-Tac-Toe',
              style: TextStyle(fontSize: 18, color: Colors.white54),
            ),
            const SizedBox(height: 30),
            Text(
              _winner.isEmpty ? (_xTurn ? 'Turn: X' : 'Turn: O') : _winner,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: 300,
              height: 300,
              child: GridView.builder(
                itemCount: 9,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                itemBuilder: (context, index) {
                  return GestureDetector(
                    onTap: () => _tapped(index),
                    child: Container(
