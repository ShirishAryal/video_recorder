import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

String formatDuration(Duration d) {
  final minutes = d.inMinutes.toString().padLeft(2, '0');
  final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

class PlaybackBar extends StatelessWidget {
  const PlaybackBar({
    super.key,
    required this.player,
    this.padding = const EdgeInsets.fromLTRB(24, 0, 24, 16),
  });

  final VideoPlayerController player;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      color: Colors.white,
      fontSize: 12,
      fontFeatures: [FontFeature.tabularFigures()],
      shadows: [Shadow(blurRadius: 4)],
    );
    return Padding(
      padding: padding,
      child: ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: player,
        builder: (context, value, _) => Row(
          children: [
            Text(formatDuration(value.position), style: style),
            const SizedBox(width: 12),
            Expanded(
              child: VideoProgressIndicator(
                player,
                allowScrubbing: true,
                padding: const EdgeInsets.symmetric(vertical: 12),
                colors: const VideoProgressColors(
                  playedColor: Colors.red,
                  bufferedColor: Colors.white38,
                  backgroundColor: Colors.white24,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(formatDuration(value.duration), style: style),
          ],
        ),
      ),
    );
  }
}
