import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

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

  @const
  @override
  State<MainContainer> createState() => _MainContainerState();
}

class _MainContainerState extends State<MainContainer> {
  int _currentIndex = 0;
  
  final AudioPlayer _audioPlayer = AudioPlayer();
  YoutubeExplode? _yt;
  
  Song? _currentSong;
  List<Song> _queue = [];
  int _queueIndex = 0;
  bool _isPlaying = false;
  bool _isLoadingTrack = false;
  String? _errorMessage;

  List<Song> _likedSongs = [];
  List<Song> _searchResults = [];
  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _yt = YoutubeExplode();
    _loadLikedSongs();
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
    _yt?.close();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadLikedSongs() async {
    final prefs = await SharedPreferences.getInstance();
    final String? likedJson = prefs.getString('liked_songs');
    if (likedJson != null) {
      final List decoded = jsonDecode(likedJson);
      setState(() {
        _likedSongs = decoded.map((e) => Song.fromJson(e)).toList();
      });
    }
  }

  Future<void> _saveLikedSongs() async {
    final prefs = await SharedPreferences.getInstance();
    final String encoded = jsonEncode(_likedSongs.map((e) => e.toJson()).toList());
    await prefs.setString('liked_songs', encoded);
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

    try {
      // Bypass 403 blocks explicitly utilizing the Android VR client stream manifest
      var manifest = await _yt!.videos.streamsClient.getManifest(
        song.videoId,
        ytClients: [YoutubeApiClient.androidVr, YoutubeApiClient.safari],
      );
      var audioStream = manifest.audioOnly.withHighestBitrate();
      
      await _audioPlayer.setUrl(audioStream.url.toString());
      await _audioPlayer.play();

      if (mounted) {
        setState(() {
          _isLoadingTrack = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingTrack = false;
          _errorMessage = "Could not load track. Tap play to retry.";
        });
      }
    }
  }

  Future<void> _searchYouTube(String query) async {
    if (query.trim().isEmpty) return;
    setState(() {
      _isSearching = true;
      _searchResults = [];
    });

    try {
      var searchList = await _yt!.search.search(query);
      List<Song> results = [];
      for (var video in searchList) {
        if (video is Video) {
          results.add(Song(
            videoId: video.id.value,
            title: video.title,
            author: video.author,
            thumbnailUrl: video.thumbnails.highResUrl,
          ));
        }
      }
      if (mounted) {
        setState(() {
          _searchResults = results;
          _isSearching = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSearching = false;
        });
      }
    }
  }

  void _openNowPlaying() {
    if (_currentSong == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black,
      builder: (context) => FullPlayerSheet(
        player: this,
      ),
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
          BottomNavigationBarItem(icon: Icon(Icons.search), label: 'Search'),
          BottomNavigationBarItem(icon: Icon(Icons.library_music), label: 'Library'),
        ],
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
              'Override Music',
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
                  onPressed: () => parent._searchYouTube(parent._searchController.text),
                ),
              ),
              onSubmitted: (val) => parent._searchYouTube(val),
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
