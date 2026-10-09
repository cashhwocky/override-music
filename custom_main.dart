Future<void> _searchMusic(String query) async {
    if (query.trim().isEmpty) return;
    setState(() {
      _isSearching = true;
      _searchResults = [];
    });

    List<Song> results = [];
    final instances = [
      'https://pipedapi.kavin.rocks',
      'https://pipedapi.adminforge.de',
      'https://pipedapi.privacy.com.de',
    ];

    for (var instance in instances) {
      try {
        final response = await http.get(
          Uri.parse('$instance/search?q=${Uri.encodeComponent(query)}&filter=videos'),
        ).timeout(const Duration(seconds: 4));
        
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final items = data['items'] as List?;
          if (items != null && items.isNotEmpty) {
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
            break; // Got results, exit the loop
          }
        }
      } catch (_) {
        continue; // Try the next backup instance
      }
    }

    if (mounted) {
      setState(() {
        _searchResults = results;
        _isSearching = false;
      });
    }
  }
