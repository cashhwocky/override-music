import 'dart:convert';
import 'dart:math';
import 'package:flutter/material';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:file_picker/file_picker.dart';

// --- SERVICE INITIALIZATION ---
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Set up the background execution service layer for locked-screen audio playback
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.override.music.channel.audio',
    androidNotificationChannelName: 'Override Music Streams',
    androidNotificationOngoing: true,
    androidShowNotificationBadge: true,
  );

  runApp(const OverrideApp());
}

class OverrideApp extends StatelessWidget {
  const OverrideApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Override',
      debugShowCheckedModeBanner: false,
      // Tidal-style absolute dark theme configuration
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xff000000),
        primaryColor: const Color(0xff00e5ff),
        colorScheme: const ColorScheme.dark(
          background: Color(0xff000000),
          surface: Color(0xff121212),
          primary: Color(0xff00e5ff),
        ),
      ),
      home: const MainNavigationHub(),
    );
  }
}

// --- DATA STRUCT MODELS ---
class MusicTrack {
  final String id;
  final String title;
  final String artist;
  final String artworkUrl;
  final String? directStreamUrl;
  final bool isLocal;

  MusicTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.artworkUrl,
    this.directStreamUrl,
    required this.isLocal,
  });
}

// --- MULTI-TAB NAVIGATION HUB ---
class MainNavigationHub extends StatefulWidget {
  const MainNavigationHub({super.key});

  @override
  State<MainNavigationHub> createState() => _MainNavigationHubState();
}

class _MainNavigationHubState extends State<MainNavigationHub> {
  int _currentTabIndex = 0;
  final AudioPlayer _globalAudioPlayer = AudioPlayer();
  MusicTrack? _currentlyPlayingTrack;
  bool _isAudioBuffering = false;

  // Active globally shared fallback Piped servers
  final List<String> _pipedGateways = [
    'https://kavin.rocks',
    'https://adminforge.de',
    'https://privacy.com.de',
  ];

  // Persisted state cache array tracking explicitly imported system storage audio files
  final List<MusicTrack> _locallyImportedTracks = [];

  @override
  void initState() {
    super.initState();
    // Catch player tracking events to toggle UI control state logic
    _globalAudioPlayer.processingStateStream.listen((state) {
      if (mounted) {
        setState(() {
          _isAudioBuffering = (state == ProcessingState.buffering || state == ProcessingState.loading);
        });
      }
    });
  }

  @override
  void dispose() {
    _globalAudioPlayer.dispose();
    super.dispose();
  }

  // Resolves direct streaming asset links and triggers background playback pipelines
  Future<void> _initiateTrackPlayback(MusicTrack track) async {
    setState(() {
      _currentlyPlayingTrack = track;
      _isAudioBuffering = true;
    });

    String? executableSourceUrl = track.directStreamUrl;

    if (!track.isLocal) {
      // Stream extraction parsing fallback routine targeting Piped API mirrors
      for (var server in _pipedGateways) {
        try {
          final res = await http.get(Uri.parse('$server/streams/${track.id}')).timeout(const Duration(seconds: 4));
          if (res.statusCode == 200) {
            final payload = jsonDecode(res.body);
            final audioStreams = payload['audioStreams'] as List?;
            if (audioStreams != null && audioStreams.isNotEmpty) {
              audioStreams.sort((a, b) => (b['bitrate'] ?? 0).compareTo(a['bitrate'] ?? 0));
              executableSourceUrl = audioStreams.first['url'];
              if (executableSourceUrl != null) break;
            }
          }
        } catch (_) {
          continue;
        }
      }
    }

    if (executableSourceUrl != null) {
      try {
        await _globalAudioPlayer.setAudioSource(
          AudioSource.uri(
            Uri.parse(executableSourceUrl),
            tag: MediaItem(
              id: track.id,
              album: track.isLocal ? 'Local Storage' : 'YouTube Stream',
              title: track.title,
              artist: track.artist,
              artUri: Uri.tryParse(track.artworkUrl),
            ),
          ),
        );
        _globalAudioPlayer.play();
      } catch (e) {
        _displaySystemAlert('Playback Initialization Engine Failure.');
      }
    } else {
      _displaySystemAlert('Failed to acquire valid streaming media endpoints.');
    }

    if (mounted) {
      setState(() {
        _isAudioBuffering = false;
      });
    }
  }

  void _displaySystemAlert(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    // Dynamically manage views while continuously retaining individual state profiles
    final List<Widget> systemTabs = [
      OnlineStreamingView(onTrackSelected: _initiateTrackPlayback, servers: _pipedGateways),
      LocalLibraryView(
        onTrackSelected: _initiateTrackPlayback,
        importedTracks: _locallyImportedTracks,
        onImportCompleted: (newTrack) {
          setState(() {
            _locallyImportedTracks.add(newTrack);
          });
        },
      ),
      const CustomGamingDashboard(),
    ];

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: systemTabs[_currentTabIndex]),
            if (_currentlyPlayingTrack != null) _renderBottomFloatingController(),
          ],
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentTabIndex,
        backgroundColor: const Color(0xff090909),
        selectedItemColor: const Color(0xff00e5ff),
        unselectedItemColor: Colors.grey.shade600,
        showUnselectedLabels: true,
        type: BottomNavigationBarType.fixed,
        onTap: (index) => setState(() => _currentTabIndex = index),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.search), label: 'Explore'),
          BottomNavigationBarItem(icon: Icon(Icons.library_music), label: 'My Media'),
          BottomNavigationBarItem(icon: Icon(Icons.sports_esports), label: 'Games'),
        ],
      ),
    );
  }

  Widget _renderBottomFloatingController() {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xff0f0f0f),
        border: Border(top: BorderSide(color: Color(0xff1a1a1a), width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: _currentlyPlayingTrack!.isLocal
                ? Container(color: const Color(0xff222222), width: 44, height: 44, child: const Icon(Icons.audiotrack, color: Color(0xff00e5ff)))
                : Image.network(
                    _currentlyPlayingTrack!.artworkUrl,
                    width: 44,
                    height: 44,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(color: const Color(0xff222222), child: const Icon(Icons.music_note)),
                  ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_currentlyPlayingTrack!.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
                const SizedBox(height: 2),
                Text(_currentlyPlayingTrack!.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
              ],
            ),
          ),
          _isAudioBuffering
              ? const Padding(padding: EdgeInsets.symmetric(horizontal: 14), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xff00e5ff))))
              : StreamBuilder<bool>(
                  stream: _globalAudioPlayer.playingStream,
                  builder: (context, snapshot) {
                    final isPlaying = snapshot.data ?? false;
                    return IconButton(
                      icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow, size: 28, color: Colors.white),
                      onPressed: () => isPlaying ? _globalAudioPlayer.pause() : _globalAudioPlayer.play(),
                    );
                  },
                ),
        ],
      ),
    );
  }
}

// ==========================================
// TAB 1: ONLINE YOUTUBE STREAMING COMPONENT
// ==========================================
class OnlineStreamingView extends StatefulWidget {
  final Function(MusicTrack) onTrackSelected;
  final List<String> servers;

  const OnlineStreamingView({super.key, required this.onTrackSelected, required this.servers});

  @override
  State<OnlineStreamingView> createState() => _OnlineStreamingViewState();
}

class _OnlineStreamingViewState extends State<OnlineStreamingView> {
  final TextEditingController _queryInputController = TextEditingController();
  List<MusicTrack> _queryExecutionCache = [];
  bool _searchActiveFlag = false;

  Future<void> _executeNetworkSearch(String query) async {
    if (query.trim().isEmpty) return;
    setState(() {
      _searchActiveFlag = true;
      _queryExecutionCache = [];
    });

    List<MusicTrack> internalBuffer = [];

    for (var node in widget.servers) {
      try {
final endpoint = '$node/search?q=${Uri.encodeComponent(query)}&filter=videos';
final payloadRes = await http.get(Uri.parse(endpoint)).timeout(const Duration(seconds: 4));
if (payloadRes.statusCode == 200) {
final Map<String, dynamic> metadata = jsonDecode(payloadRes.body);
final parsedItems = metadata['items'] as List?;
if (parsedItems != null && parsedItems.isNotEmpty) {
for (var entry in parsedItems) {
String locationPath = entry['url'] ?? '';
String trackingId = '';
if (locationPath.contains('v=')) {
trackingId = locationPath.split('v=').last;
} else {
trackingId = locationPath.split('/').last;
}
if (trackingId.isNotEmpty) {
internalBuffer.add(MusicTrack(
id: trackingId,
title: entry['title'] ?? 'Unknown Title',
artist: entry['uploaderName'] ?? 'Unknown Artist',
artworkUrl: entry['thumbnail'] ?? '',
isLocal: false,
));
}
}
break;
}
}
} catch (_) {
continue;
}
}
if (mounted) {
setState(() {
_queryExecutionCache = internalBuffer;
_searchActiveFlag = false;
});
}
}
@override
Widget build(BuildContext context) {
return Column(
children: [
Padding(
padding: const EdgeInsets.all(16.0),
child: TextField(
controller: _queryInputController,
onSubmitted: _executeNetworkSearch,
decoration: InputDecoration(
hintText: 'Search Track or Artist...',
hintStyle: TextStyle(color: Colors.grey.shade500),
prefixIcon: const Icon(Icons.search, color: Colors.grey),
filled: true,
fillColor: const Color(0xff121212),
enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xff00e5ff), width: 1)),
),
),
),
Expanded(
child: _searchActiveFlag
? const Center(child: CircularProgressIndicator(color: Color(0xff00e5ff)))
: _queryExecutionCache.isEmpty
? Center(child: Text('Explore new audio streams', style: TextStyle(color: Colors.grey.shade600)))
: ListView.builder(
itemCount: _queryExecutionCache.length,
itemBuilder: (context, idx) {
final song = queryExecutionCache[idx];
return ListTile(
contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
leading: ClipRRect(
borderRadius: BorderRadius.circular(4),
child: Image.network(
song.artworkUrl,
width: 48,
height: 48,
fit: BoxFit.cover,
errorBuilder: (, __, ___) => Container(color: Colors.grey, width: 48, height: 48),
),
),
title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
subtitle: Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.grey.shade400)),
onTap: () => widget.onTrackSelected(song),
);
},
),
),
],
);
}
}
// ==========================================
// TAB 2: LOCAL LIBRARY & STORAGE IMPORT VIEW
// ==========================================
class LocalLibraryView extends StatelessWidget {
final Function(MusicTrack) onTrackSelected;
final List importedTracks;
final Function(MusicTrack) onImportCompleted;
const LocalLibraryView({
super.key,
required this.onTrackSelected,
required this.importedTracks,
required this.onImportCompleted,
});
// Accesses the storage permission layers to select files from device memory or linked cloud accounts
Future _pickAndImportAudioFile() async {
try {
FilePickerResult? pickResult = await FilePicker.platform.pickFiles(
type: FileType.audio,
allowCompression: false,
);
if (pickResult != null && pickResult.files.single.path != null) {
final chosenFile = pickResult.files.single;
final newlyScaffoldedTrack = MusicTrack(
id: DateTime.now().millisecondsSinceEpoch.toString(),
title: chosenFile.name.replaceAll(RegExp(r'.mp3|.wav|.m4a|.flac'), ''),
artist: 'Imported Media Source',
artworkUrl: '',
directStreamUrl: chosenFile.path,
isLocal: true,
);
onImportCompleted(newlyScaffoldedTrack);
}
} catch (_) {
// Safe generic catch to protect system lifecycle integrity
}
}
@override
Widget build(BuildContext context) {
return Column(
children: [
Padding(
padding: const EdgeInsets.all(16.0),
child: Row(
mainAxisAlignment: MainAxisAlignment.between,
children: [
const Text('Local Audio Library', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
IconButton(
icon: const Icon(Icons.add_circle_outline, color: Color(0xff00e5ff), size: 28),
onPressed: _pickAndImportAudioFile,
tooltip: 'Import from Storage or Drive',
),
],
),
),
Expanded(
child: importedTracks.isEmpty
? Center(
child: Padding(
padding: const EdgeInsets.all(24.0),
child: Text(
'No system files detected.\nTap the (+) button above to safely link local paths or Google Drive audio sheets.',
textAlign: TextAlign.center,
style: TextStyle(color: Colors.grey.shade600, height: 1.4),
),
),
)
: ListView.builder(
itemCount: importedTracks.length,
itemBuilder: (context, index) {
final audioItem = importedTracks[index];
return ListTile(
contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
leading: Container(
width: 48,
height: 48,
decoration: BoxDecoration(color: const Color(0xff121212), borderRadius: BorderRadius.circular(4)),
child: const Icon(Icons.audiotrack, color: Color(0xff00e5ff)),
),
title: Text(audioItem.title, maxLines: 1, overflow: TextOverflow.ellipsis),
subtitle: Text(audioItem.artist, style: TextStyle(color: Colors.grey.shade400)),
onTap: () => onTrackSelected(audioItem),
);
},
),
),
],
);
}
}
// ==========================================
// TAB 3: CUSTOM ENTERTAINMENT GAME MODULE
// ==========================================
class CustomGamingDashboard extends StatefulWidget {
const CustomGamingDashboard({super.key});
@override
State createState() => _CustomGamingDashboardState();
}
class _CustomGamingDashboardState extends State {
int? _activeGameInstanceIndex;
@override
Widget build(BuildContext context) {
if (_activeGameInstanceIndex != null) {
return WillPopScope(
onWillPop: () async {
setState(() => _activeGameInstanceIndex = null);
return false;
},
child: _activeGameInstanceIndex == 0 ? const FPSArenaEngine() : const SecretPuzzleMatrix(),
);
}
return Padding(
padding: const EdgeInsets.all(16.0),
key: const ValueKey('DashboardGridView'),
child: Column(
crossAxisAlignment: CrossAxisAlignment.start,
children: [
const Text('Entertainment Module', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
const SizedBox(height: 16),
Expanded(
child: GridView.count(
crossAxisCount: 2,
crossAxisSpacing: 14,
mainAxisSpacing: 14,
children: [
_buildLaunchCard('FPS Framework Target', Icons.track_changes, Colors.orange.shade800, () => setState(() => _activeGameInstanceIndex = 0)),
_buildLaunchCard('Secret Audio Grid', Icons.grid_on_sharp, Colors.purple.shade800, () => setState(() => _activeGameInstanceIndex = 1)),
],
),
)
],
),
);
}
Widget _buildLaunchCard(String text, IconData icon, Color stylingColor, VoidCallback action) {
return InkWell(
onTap: action,
borderRadius: BorderRadius.circular(12),
child: Container(
decoration: BoxDecoration(
color: const Color(0xff121212),
borderRadius: BorderRadius.circular(12),
border: Border.all(color: const Color(0xff1c1c1c), width: 1),
),
child: Column(
mainAxisAlignment: MainAxisAlignment.center,
children: [
Icon(icon, size: 40, color: stylingColor),
const SizedBox(height: 12),
Text(text, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
],
),
),
);
}
}
// EXTENSION 1: PRIMARY FPS ARENA SCHEMATIC
class FPSArenaEngine extends StatefulWidget {
const FPSArenaEngine({super.key});
@override
State createState() => _FPSArenaEngineState();
}
class _FPSArenaEngineState extends State {
int _scoreCount = 0;
double _targetCoordinateX = 0.0;
double _targetCoordinateY = 0.0;
final Random _coordinateGenerator = Random();
void _repositionTarget() {
setState(() {
_scoreCount++;
_targetCoordinateX = (_coordinateGenerator.nextDouble() * 2.0) - 1.0;
_targetCoordinateY = (_coordinateGenerator.nextDouble() * 2.0) - 1.0;
});
}
@override
Widget build(BuildContext context) {
return Container(
color: const Color(0xff050505),
child: Stack(
children: [
Align(
alignment: const Alignment(-0.9, -0.9),
child: Text('TARGETS DOWNED: $_scoreCount', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.orange)),
),
Align(
alignment: Alignment(_targetCoordinateX, _targetCoordinateY),
child: GestureDetector(
onTap: _repositionTarget,
child: Container(
width: 45,
height: 45,
decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Colors.redAccent, blurRadius: 10)]),
child: const Center(child: Icon(Icons.gps_fixed, color: Colors.white, size: 20)),
),
),
),
const Center(child: Icon(Icons.add, size: 32, color: Colors.white30)),
],
),
);
}
}
// EXTENSION 2: THE SECRET HIDDEN MATRIX GAME
class SecretPuzzleMatrix extends StatefulWidget {
const SecretPuzzleMatrix({super.key});
@override
State createState() => _SecretPuzzleMatrixState();
}
class _SecretPuzzleMatrixState extends State {
late List _gridArrayLayout;
int _movesCounter = 0;
@override
void initState() {
super.initState();
_resetPuzzleState();
}
void _resetPuzzleState() {
setState(() {
_gridArrayLayout = List.generate(16, (index) => index)..shuffle();
_movesCounter = 0;
});
}
void _handleGridSelection(int cellIdx) {
int blankCellIdx = _gridArrayLayout.indexOf(0);
int selectedRow = cellIdx ~/ 4;
int selectedCol = cellIdx % 4;
int blankRow = blankCellIdx ~/ 4;
int blankCol = blankCellIdx % 4;
if ((selectedRow == blankRow && (selectedCol - blankCol).abs() == 1) || (selectedCol == blankCol && (selectedRow - blankRow).abs() == 1)) {
setState(() {
_gridArrayLayout[blankCellIdx] = _gridArrayLayout[cellIdx];
_gridArrayLayout[cellIdx] = 0;
_movesCounter++;
});
}
}
@override
Widget build(BuildContext context) {
return Container(
color: const Color(0xff020202),
padding: const EdgeInsets.all(24),
child: Column(
mainAxisAlignment: MainAxisAlignment.center,
children: [
Text('MATRIX MOVES: $_movesCounter', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.purpleAccent)),
const SizedBox(height: 20),
AspectRatio(
aspectRatio: 1,
child: GridView.builder(
physics: const NeverScrollableScrollPhysics(),
gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, crossAxisSpacing: 6, mainAxisSpacing: 6),
itemCount: 16,
itemBuilder: (context, i) {
final cellValue = _gridArrayLayout[i];
if (cellValue == 0) return const SizedBox.shrink();
return GestureDetector(
onTap: () => _handleGridSelection(i),
child: Container(
decoration: BoxDecoration(color: const Color(0xff121212), borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.purple.shade900)),
child: Center(child: Text('$cellValue', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white))),
),
);
},
),
),
const SizedBox(height: 24),
TextButton.icon(icon: const Icon(Icons.refresh), label: const Text('SCRAMBLE GRID'), onPressed: _resetPuzzleState),
],
),
);
}
}
