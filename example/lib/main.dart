import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_recorder/video_recorder.dart';

import 'feed_page.dart';

void main() {
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'video_recorder example',
      theme: ThemeData(colorSchemeSeed: Colors.deepPurple),
      home: const ExampleHomePage(),
    );
  }
}

class ExampleHomePage extends StatefulWidget {
  const ExampleHomePage({super.key});

  @override
  State<ExampleHomePage> createState() => _ExampleHomePageState();
}

class _ExampleHomePageState extends State<ExampleHomePage> {
  VideoQuality _quality = VideoQuality.p720;
  bool _enableAudio = true;
  bool _limitTo30Seconds = false;
  bool _showHints = true;
  bool _countdown = true;
  bool _smallerFiles = false;
  bool _convertToHevc = false;

  static const _hints = [
    RecorderHint(
      'Introduce yourself',
      description: 'Say your name and what you do.',
    ),
    RecorderHint(
      'Describe the problem',
      description: 'Walk through what you ran into, step by step.',
    ),
    RecorderHint(
      'What did you expect?',
      description: 'Explain what you expected to happen instead.',
    ),
    RecorderHint('Wrap up', description: 'Thank the viewer and finish.'),
  ];

  XFile? _video;
  int? _videoBytes;

  final _urlController = TextEditingController(
    text:
        'https://flutter.github.io/assets-for-api-docs/assets/videos/butterfly.mp4',
  );
  Uri? _url;

  // Public sample clips; the query strings make four distinct feed items.
  static final _feedUrls = [
    for (final (name, n) in [
      ('butterfly', 1),
      ('bee', 1),
      ('butterfly', 2),
      ('bee', 2),
    ])
      Uri.parse(
        'https://flutter.github.io/assets-for-api-docs/assets/videos/'
        '$name.mp4?item=$n',
      ),
  ];

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  void _playUrl() {
    final url = Uri.tryParse(_urlController.text.trim());
    if (url == null || !url.hasScheme || url.host.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Enter a full video URL.')));
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _url = url);
  }

  Future<void> _record() async {
    final video = await VideoRecorder.record(
      context,
      options: VideoRecorderOptions(
        quality: _quality,
        enableAudio: _enableAudio,
        maxDuration: _limitTo30Seconds ? const Duration(seconds: 30) : null,
        hints: _showHints ? _hints : const [],
        countdownSeconds: _countdown ? 3 : 0,
        // Without these, the package uses its per-quality default
        // (2.5 Mbps at 720p).
        videoBitrate: _smallerFiles ? 1500000 : null,
        audioBitrate: _smallerFiles ? 64000 : null,
        convertToHevc: _convertToHevc,
      ),
    );
    if (video == null) return; // Closed without saving.

    final bytes = await video.length();
    // The app owns returned files, so clean up the previous recording.
    final previous = _video;
    if (previous != null) File(previous.path).delete().ignore();
    setState(() {
      _video = video;
      _videoBytes = bytes;
    });
  }

  @override
  Widget build(BuildContext context) {
    final video = _video;
    return Scaffold(
      appBar: AppBar(title: const Text('video_recorder example')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Quality', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<VideoQuality>(
            segments: const [
              ButtonSegment(value: VideoQuality.p480, label: Text('480p')),
              ButtonSegment(value: VideoQuality.p720, label: Text('720p')),
              ButtonSegment(value: VideoQuality.p1080, label: Text('1080p')),
            ],
            selected: {_quality},
            onSelectionChanged: (s) => setState(() => _quality = s.single),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Record audio'),
            value: _enableAudio,
            onChanged: (v) => setState(() => _enableAudio = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Stop after 30 seconds'),
            value: _limitTo30Seconds,
            onChanged: (v) => setState(() => _limitTo30Seconds = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Extra small files'),
            subtitle: const Text('1.5 Mbps video, 64 kbps audio'),
            value: _smallerFiles,
            onChanged: (v) => setState(() => _smallerFiles = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Convert to HEVC on save'),
            subtitle: const Text(
              'About 40% smaller; plays on phones and Safari',
            ),
            value: _convertToHevc,
            onChanged: (v) => setState(() => _convertToHevc = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('3-2-1 countdown before recording'),
            value: _countdown,
            onChanged: (v) => setState(() => _countdown = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Show hints while recording'),
            value: _showHints,
            onChanged: (v) => setState(() => _showHints = v),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _record,
            icon: const Icon(Icons.videocam),
            label: const Text('Record video'),
          ),
          const SizedBox(height: 24),
          if (video != null)
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Keeps portrait videos from taking over the screen.
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 480),
                    child: RecordedVideoPlayer(
                      key: ValueKey(video.path),
                      file: video,
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.movie),
                    title: Text(video.name),
                    subtitle: Text(
                      '${(_videoBytes! / (1024 * 1024)).toStringAsFixed(1)} MB\n'
                      '${video.path}',
                    ),
                    isThreeLine: true,
                  ),
                ],
              ),
            ),
          const Divider(height: 48),
          Text(
            'Play from a URL',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _urlController,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => _playUrl(),
            decoration: const InputDecoration(
              labelText: 'Video URL',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _playUrl,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Play URL'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => FeedPage(urls: _feedUrls),
              ),
            ),
            icon: const Icon(Icons.swipe_vertical),
            label: const Text('Open feed (preloads next videos)'),
          ),
          if (_url case final url?) ...[
            const SizedBox(height: 16),
            Card(
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 480),
                child: RecordedVideoPlayer.network(
                  url,
                  key: ValueKey(url),
                  autoPlay: true,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
