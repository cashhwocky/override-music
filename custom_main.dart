import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

class OverrideMusicApp extends StatelessWidget {
  const OverrideMusicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Override Music',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        canvasColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Colors.white,
          secondary: Colors.white24,
          surface: Colors.black,
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

  Song({
    required this.videoId,
    required this.title,
    required this.author,
    required this.thumbnailUrl,
  });

  Map<String, dynamic> toJson() => {
        'videoId': videoId,
        'title': title,
        'author': author,
        'thumbnailUrl': thumbnailUrl,
      };

  factory Song.fromJson(Map<String, dynamic> json) => Song(
        videoId: json['videoId'],
        title: json['title'],
        author: json['author'],
        thumbnailUrl: json['thumbnailUrl'],
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
  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();

  static const List<String> _apiMirrors = [
    'https://pipedapi.kavin.rocks',
    'https://pipedapi.tokhmi.xyz',
    'https://piped-api.garudalinux.org',
  ];

  @override
  void initState() {
    super.initState();
    _loadData();
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

    bool played = false;
    for (String base in _apiMirrors) {
      try {
        final response = await http
            .get(Uri.parse('$base/streams/${song.videoId}'))
            .timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final audioStreams = data['audioStreams'] as List;
          
          var bestStream = audioStreams.isNotEmpty ? audioStreams[0] : null;
          for (var stream in audioStreams) {
            if ((stream['bitrate'] ?? 0) > (bestStream['bitrate'] ?? 0)) {
              bestStream = stream;
            }
          }

          if (bestStream != null && bestStream['url'] != null) {
            String streamUrl = bestStream['url'];
            await _audioPlayer.setUrl(streamUrl);
            await _audioPlayer.play();
            played = true;
            break;
          }
        }
      } catch (_) {
        continue;
      }
    }

    if (mounted) {
      setState(() {
        _isLoadingTrack = false;
        if (!played) {
          _errorMessage = "Could not load track. Tap to retry.";
        }
      });
    }
  }

  Future<void> _searchMusic(String query) async {
    if (query.trim().isEmpty) return;
    setState(() {
      _isSearching = true;
      _searchResults = [];
    });

    List<Song> results = [];
    for (String base in _apiMirrors) {
      try {
        final response = await http
            .get(Uri.parse('$base/search?q=${Uri.encodeComponent(query)}&filter=videos'))
            .timeout(const Duration(seconds: 12));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final items = data['items'] as List;
          for (var item in items) {
            if (item['type'] == 'stream') {
              String url = item['url'] ?? '';
              String videoId = url.replaceAll('/watch?v=', '');
              results.add(Song(
                videoId: videoId,
                title: item['title'] ?? 'Unknown Title',
                author: item['uploaderName'] ?? 'Unknown Artist',
                thumbnailUrl: item['thumbnail'] ?? 'https://img.youtube.com/vi/$videoId/hqdefault.jpg',
              ));
            }
          }
          if (results.isNotEmpty) break;
        }
      } catch (_) {
        continue;
      }
    }

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
      backgroundColor: Colors.black,
      builder: (context) => FullPlayerSheet(parent: this),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          IndexedStack(
            index: _currentIndex,
            children: [
              HomeTab(parent: this),
              SearchTab(parent: this),
              LibraryTab(parent: this),
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
        backgroundColor: Colors.black,
        selectedItemColor: Colors.white,
        unselectedItemColor: Colors.white54,
        onTap: (index) => setState(() => _currentIndex = index),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.search), label: 'Search'),
          BottomNavigationBarItem(icon: Icon(Icons.library_music), label: 'Library'),
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
                            child: Image.network(
                              song.thumbnailUrl,
                              width: 50,
                              height: 50,
                              fit: BoxFit.cover,
                              errorBuilder: (c, e, s) => Container(width: 50, height: 50, color: Colors.white24),
                            ),
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

class SettingsScreen extends StatelessWidget {
  final _MainContainerState parent;
  const SettingsScreen({super.key, required this.parent});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: ListView(
          children: [
            const Text('App Info', style: TextStyle(color: Colors.white54, fontSize: 14, fontWeight: FontWeight.bold)),
            const ListTile(
              title: Text('App Name', style: TextStyle(color: Colors.white)),
              trailing: Text('Override Music', style: TextStyle(color: Colors.white54)),
            ),
            const ListTile(
              title: Text('Aesthetic', style: TextStyle(color: Colors.white)),
              trailing: Text('Pure AMOLED Black', style: TextStyle(color: Colors.white54)),
            ),
            const Divider(color: Colors.white24),
            const Text('Data & Storage', style: TextStyle(color: Colors.white54, fontSize: 14, fontWeight: FontWeight.bold)),
            ListTile(
              title: const Text('Clear Recently Played History', style: TextStyle(color: Colors.white)),
              trailing: const Icon(Icons.delete_outline, color: Colors.redAccent),
              onTap: () {
                parent.setState(() {
                  parent._recentSongs.clear();
                });
                parent._saveRecentSongs();
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
                            child: Image.network(song.thumbnailUrl, width: 50, height: 50, fit: BoxFit.cover,
                              errorBuilder: (c, e, s) => Container(width: 50, height: 50, color: Colors.white24),
                            ),
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
              child: Image.network(song.thumbnailUrl, width: 45, height: 45, fit: BoxFit.cover),
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

    return Container(
      color: Colors.black,
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
            child: Image.network(song.thumbnailUrl, width: 300, height: 300, fit: BoxFit.cover,
              errorBuilder: (c, e, s) => Container(width: 300, height: 300, color: Colors.white24),
            ),
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
