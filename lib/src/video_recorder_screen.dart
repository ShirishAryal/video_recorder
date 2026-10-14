import 'dart:async';
import 'dart:io' show File;
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';

import 'hevc_converter.dart';
import 'playback_bar.dart';
import 'streamable_mp4.dart';
import 'video_recorder_options.dart';

enum _Stage { initializing, ready, countdown, recording, review, error }

const _accent = Color(0xFFF7931E);
const _recordRed = Color(0xFFF2364F);

/// Pops its route with the saved [XFile]. Most apps should use
/// `VideoRecorder.record` rather than pushing this directly.
class VideoRecorderScreen extends StatefulWidget {
  const VideoRecorderScreen({
    super.key,
    this.options = const VideoRecorderOptions(),
  });

  final VideoRecorderOptions options;

  @override
  State<VideoRecorderScreen> createState() => _VideoRecorderScreenState();
}

class _VideoRecorderScreenState extends State<VideoRecorderScreen>
    with WidgetsBindingObserver {
  List<CameraDescription> _cameras = const [];
  CameraDescription? _camera;
  CameraController? _controller;
  VideoPlayerController? _player;
  XFile? _take;
  bool _saved = false;

  _Stage _stage = _Stage.initializing;
  String? _error;
  bool _busy = false;
  bool _paused = false;

  /// Non-null while converting on Save; completing it skips the conversion.
  Completer<void>? _skipCompression;
  double? _compressProgress;
  bool get _compressing => _skipCompression != null;
  bool _optimizing = false;
  bool get _finishing => _compressing || _optimizing;
  int _hintIndex = 0;

  late bool _countdownOn = widget.options.countdownSeconds > 0;
  bool _torchOn = false;
  bool _toolsExpanded = false;

  final Stopwatch _stopwatch = Stopwatch();
  Timer? _ticker;
  Timer? _countdownTimer;
  int _countdownLeft = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setUp();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _countdownTimer?.cancel();
    if (_skipCompression case final skip? when !skip.isCompleted) {
      skip.complete();
    }
    final controller = _controller;
    _controller = null;
    if (controller != null) unawaited(_closeCamera(controller));
    _player?.dispose();
    final take = _take;
    if (take != null && !_saved) _deleteQuietly(take);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The camera must be released while the app is in the background and
    // reopened when it comes back.
    if (state == AppLifecycleState.inactive) {
      final controller = _controller;
      // The iOS permission prompt also makes the app inactive; leave a
      // camera that is still initializing alone.
      if (controller == null || !controller.value.isInitialized) return;
      _controller = null;
      _torchOn = false;
      _player?.pause();
      if (_stage == _Stage.countdown) _cancelCountdown();
      if (controller.value.isRecordingVideo) {
        // An interrupted take can't be resumed, so drop it.
        _ticker?.cancel();
        _stopwatch
          ..stop()
          ..reset();
        _paused = false;
        _stage = _Stage.ready;
      }
      unawaited(_closeCamera(controller));
      setState(() {});
    } else if (state == AppLifecycleState.resumed) {
      final camera = _camera;
      if (_controller == null && camera != null) _openCamera(camera);
    }
  }

  Future<void> _setUp() async {
    setState(() {
      _stage = _Stage.initializing;
      _error = null;
    });
    try {
      _cameras = await availableCameras();
    } on CameraException catch (e) {
      _fail(_describe(e));
      return;
    }
    if (_cameras.isEmpty) {
      _fail('No camera was found on this device.');
      return;
    }
    final camera = _cameras.firstWhere(
      (c) => c.lensDirection == widget.options.preferredLens,
      orElse: () => _cameras.first,
    );
    await _openCamera(camera);
  }

  Future<void> _openCamera(CameraDescription camera) async {
    final controller = CameraController(
      camera,
      widget.options.quality.preset,
      enableAudio: widget.options.enableAudio,
      videoBitrate: widget.options.effectiveVideoBitrate,
      audioBitrate: widget.options.audioBitrate,
    );
    _camera = camera;
    _controller = controller;
    try {
      await controller.initialize();
      await controller.prepareForVideoRecording();
    } on CameraException catch (e) {
      if (_controller == controller) {
        _controller = null;
        await controller.dispose();
        _fail(_describe(e));
      }
      return;
    }
    // Disposed or replaced while initializing; whoever did that disposed it.
    if (!mounted || _controller != controller) return;
    setState(() {
      if (_stage == _Stage.initializing) _stage = _Stage.ready;
    });
  }

  static Future<void> _closeCamera(CameraController controller) async {
    if (controller.value.isRecordingVideo) {
      try {
        _deleteQuietly(await controller.stopVideoRecording());
      } on CameraException {
        // Nothing to clean up.
      }
    }
    await controller.dispose();
  }

  void _onRecordPressed() {
    if (_stage != _Stage.ready) return;
    final seconds = _countdownOn ? widget.options.countdownSeconds : 0;
    if (seconds <= 0) {
      _startRecording();
      return;
    }
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_countdownLeft > 1) {
        setState(() => _countdownLeft--);
      } else {
        _countdownTimer?.cancel();
        _countdownTimer = null;
        _startRecording();
      }
    });
    setState(() {
      _countdownLeft = seconds;
      _stage = _Stage.countdown;
    });
  }

  void _cancelCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    setState(() => _stage = _Stage.ready);
  }

  Future<void> _startRecording() async {
    final controller = _controller;
    if (controller == null ||
        (_stage != _Stage.ready && _stage != _Stage.countdown)) {
      return;
    }
    await _run(() async {
      await controller.startVideoRecording();
      _stopwatch
        ..reset()
        ..start();
      _ticker = Timer.periodic(const Duration(milliseconds: 200), _onTick);
      setState(() => _stage = _Stage.recording);
    });
    // Recording failed to start; let the user try again.
    if (mounted && _stage == _Stage.countdown) {
      setState(() => _stage = _Stage.ready);
    }
  }

  void _onTick(Timer _) {
    final max = widget.options.maxDuration;
    if (max != null && _stopwatch.elapsed >= max) {
      _stopRecording();
    }
    setState(() {});
  }

  Future<void> _togglePause() async {
    final controller = _controller;
    if (controller == null || _stage != _Stage.recording) return;
    await _run(() async {
      if (_paused) {
        await controller.resumeVideoRecording();
        _stopwatch.start();
      } else {
        await controller.pauseVideoRecording();
        _stopwatch.stop();
      }
      setState(() => _paused = !_paused);
    });
  }

  Future<void> _stopRecording() async {
    final controller = _controller;
    if (controller == null || _stage != _Stage.recording) return;
    await _run(() async {
      final take = await _finishRecording(controller);
      await _turnTorchOff(controller);
      final player = await _createPlayer(take);
      if (!mounted) {
        await player?.dispose();
        _deleteQuietly(take);
        return;
      }
      setState(() {
        _take = take;
        _player = player;
        _stage = _Stage.review;
      });
    });
  }

  Future<void> _restart() async {
    await _run(() async {
      final controller = _controller;
      if (_stage == _Stage.recording && controller != null) {
        _deleteQuietly(await _finishRecording(controller));
      }
      final player = _player;
      final take = _take;
      _player = null;
      _take = null;
      if (player != null) unawaited(player.dispose());
      if (take != null) _deleteQuietly(take);
      _stopwatch.reset();
      setState(() {
        _stage = _Stage.ready;
        // A new take starts from the first hint again.
        _hintIndex = 0;
      });
    });
  }

  Future<void> _save() async {
    final take = _take;
    if (take == null || _finishing) return;
    _player?.pause();

    var file = take;
    if (widget.options.convertToHevc) {
      final skip = Completer<void>();
      setState(() {
        _skipCompression = skip;
        _compressProgress = null;
      });
      final result = await HevcConverter.convert(
        take,
        bitrate: widget.options.effectiveHevcBitrate,
        onProgress: (p) {
          if (mounted) setState(() => _compressProgress = p);
        },
        cancel: skip.future,
      );
      if (!mounted) {
        // Closed mid-conversion; dispose() already deleted the take.
        if (result.converted) File(result.file.path).delete().ignore();
        return;
      }
      if (result.converted) {
        _deleteQuietly(take);
        file = result.file;
      }
      setState(() => _skipCompression = null);
    }

    if (widget.options.optimizeForStreaming) {
      setState(() => _optimizing = true);
      final streamable = await StreamableMp4.ensure(file);
      if (!mounted) {
        // Closed while saving; dispose() already deleted the take.
        if (streamable.path != file.path) _deleteQuietly(streamable);
        if (file.path != take.path) _deleteQuietly(file);
        return;
      }
      if (streamable.path != file.path) {
        _deleteQuietly(file);
        file = streamable;
      }
      setState(() => _optimizing = false);
    }

    _saved = true;
    Navigator.of(context).pop(file);
  }

  void _skipCompressionNow() {
    final skip = _skipCompression;
    if (skip != null && !skip.isCompleted) skip.complete();
  }

  Future<void> _switchCamera() async {
    final controller = _controller;
    final current = _camera;
    if (controller == null || current == null || _stage != _Stage.ready) {
      return;
    }
    final next = _nextCamera(current);
    if (next == null) return;
    await _run(() async {
      await _turnTorchOff(controller);
      await controller.setDescription(next);
      setState(() => _camera = next);
    });
  }

  Future<void> _toggleTorch() async {
    final controller = _controller;
    if (controller == null) return;
    await _run(() async {
      await controller.setFlashMode(_torchOn ? FlashMode.off : FlashMode.torch);
      setState(() => _torchOn = !_torchOn);
    });
  }

  Future<void> _turnTorchOff(CameraController controller) async {
    if (!_torchOn) return;
    _torchOn = false;
    try {
      await controller.setFlashMode(FlashMode.off);
    } on CameraException {
      // The light goes out with the camera anyway.
    }
  }

  void _toggleCountdown() => setState(() => _countdownOn = !_countdownOn);

  void _showHint(int index) {
    if (index < 0 || index >= widget.options.hints.length) return;
    setState(() => _hintIndex = index);
  }

  Future<void> _togglePlayback() async {
    final player = _player;
    if (player == null) return;
    final value = player.value;
    if (value.isPlaying) {
      await player.pause();
    } else {
      if (value.isCompleted || value.position >= value.duration) {
        await player.seekTo(Duration.zero);
      }
      await player.play();
    }
  }

  void _onPlayerChanged() {
    if (mounted) setState(() {});
  }

  /// Prefers a camera facing the other way so phones with several back
  /// lenses still flip between front and back.
  CameraDescription? _nextCamera(CameraDescription current) {
    if (_cameras.length < 2) return null;
    for (final camera in _cameras) {
      if (camera.lensDirection != current.lensDirection) return camera;
    }
    return _cameras[(_cameras.indexOf(current) + 1) % _cameras.length];
  }

  Future<XFile> _finishRecording(CameraController controller) {
    _ticker?.cancel();
    _ticker = null;
    _stopwatch.stop();
    _paused = false;
    return controller.stopVideoRecording();
  }

  /// `null` if the take can't be played; saving still works without it.
  Future<VideoPlayerController?> _createPlayer(XFile take) async {
    final player = kIsWeb
        ? VideoPlayerController.networkUrl(Uri.parse(take.path))
        : VideoPlayerController.file(File(take.path));
    try {
      await player.initialize();
      await player.play();
      player.addListener(_onPlayerChanged);
      return player;
    } catch (_) {
      await player.dispose();
      return null;
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on CameraException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(_describe(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _stage = _Stage.error;
      _error = message;
    });
  }

  static String _describe(CameraException e) {
    return switch (e.code) {
      'CameraAccessDenied' ||
      'CameraAccessDeniedWithoutPrompt' ||
      'CameraAccessRestricted' =>
        'Camera access is needed to record video. '
            'Allow it in your device settings.',
      'AudioAccessDenied' ||
      'AudioAccessDeniedWithoutPrompt' ||
      'AudioAccessRestricted' =>
        'Microphone access is needed to record sound. '
            'Allow it in your device settings.',
      _ => e.description ?? 'Something went wrong with the camera.',
    };
  }

  static void _deleteQuietly(XFile file) {
    if (kIsWeb) return;
    File(file.path).delete().ignore();
  }

  /// Elapsed time, followed by the limit if there is one.
  String? _timerText() {
    if (_stage case _Stage.ready || _Stage.countdown || _Stage.recording) {
      final elapsed = formatDuration(_stopwatch.elapsed);
      final max = widget.options.maxDuration;
      return max == null ? elapsed : '$elapsed / ${formatDuration(max)}';
    }
    return null;
  }

  List<_Tool> _tools() {
    final ready = _stage == _Stage.ready && !_busy && _controller != null;
    final live =
        _stage == _Stage.ready ||
        _stage == _Stage.countdown ||
        _stage == _Stage.recording;
    if (!live || _controller == null) return const [];
    final seconds = widget.options.countdownSeconds;
    return [
      if (ready && _cameras.length > 1)
        _Tool(
          icon: Icons.cameraswitch_outlined,
          label: 'Switch camera',
          onPressed: _switchCamera,
        ),
      if (ready && seconds > 0)
        _Tool(
          icon: _countdownOn ? Icons.timer_outlined : Icons.timer_off_outlined,
          label: _countdownOn ? 'Timer ${seconds}s' : 'Timer off',
          active: _countdownOn,
          onPressed: _toggleCountdown,
        ),
      // Front cameras rarely have a light.
      if (_camera?.lensDirection == CameraLensDirection.back)
        _Tool(
          icon: _torchOn ? Icons.lightbulb : Icons.lightbulb_outline,
          label: _torchOn ? 'Light on' : 'Light off',
          active: _torchOn,
          onPressed: _busy ? null : _toggleTorch,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final tools = _tools();
    return PopScope(
      canPop: !_busy && !_finishing,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: Center(
                  child: switch (_stage) {
                    _Stage.error => _ErrorMessage(
                      message: _error ?? 'The camera could not be opened.',
                      onRetry: _setUp,
                    ),
                    _Stage.review => _ReviewPreview(
                      player: _player,
                      onTap: _togglePlayback,
                    ),
                    _ => _CameraViewport(controller: _controller),
                  },
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _TopBar(
                  onClose: _busy || _finishing
                      ? null
                      : () => Navigator.of(context).maybePop(),
                  timerText: _timerText(),
                  paused: _paused,
                ),
              ),
              if (_stage == _Stage.countdown)
                Positioned.fill(
                  child: IgnorePointer(
                    child: _CountdownOverlay(seconds: _countdownLeft),
                  ),
                ),
              if (tools.isNotEmpty && !_finishing)
                Positioned.fill(
                  child: Align(
                    alignment: const Alignment(1, 0.15),
                    child: _ToolTray(
                      tools: tools,
                      expanded: _toolsExpanded,
                      onToggle: () =>
                          setState(() => _toolsExpanded = !_toolsExpanded),
                    ),
                  ),
                ),
              if (_compressing)
                Positioned.fill(
                  child: _SavingOverlay(
                    label: 'Compressing…',
                    progress: _compressProgress,
                    onSkip: _skipCompressionNow,
                  ),
                )
              else if (_optimizing)
                const Positioned.fill(child: _SavingOverlay(label: 'Saving…'))
              else if (_stage != _Stage.error)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: DecoratedBox(
                    // Keeps the white controls readable over bright scenes.
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black54],
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 24, bottom: 24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.options.hints.isNotEmpty &&
                              (_stage == _Stage.ready ||
                                  _stage == _Stage.countdown ||
                                  _stage == _Stage.recording))
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                              child: _HintCard(
                                hints: widget.options.hints,
                                index: _hintIndex,
                                onChanged: _showHint,
                              ),
                            ),
                          if (_stage == _Stage.review && _player != null)
                            PlaybackBar(player: _player!),
                          _Controls(
                            stage: _stage,
                            enabled: !_busy && _controller != null,
                            busy: _busy,
                            paused: _paused,
                            maxDuration: widget.options.maxDuration,
                            stopwatch: _stopwatch,
                            player: _player,
                            onRecord: _onRecordPressed,
                            onCancelCountdown: _cancelCountdown,
                            onRestart: _restart,
                            onStop: _stopRecording,
                            onTogglePause: _togglePause,
                            onTogglePlayback: _togglePlayback,
                            onSave: _save,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorMessage extends StatelessWidget {
  const _ErrorMessage({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    );
  }
}

class _ReviewPreview extends StatelessWidget {
  const _ReviewPreview({required this.player, required this.onTap});

  /// `null` if the take can't be played.
  final VideoPlayerController? player;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final player = this.player;
    if (player == null) {
      return const Text(
        'Preview unavailable',
        style: TextStyle(color: Colors.white70),
      );
    }
    return GestureDetector(
      onTap: onTap,
      child: AspectRatio(
        aspectRatio: player.value.aspectRatio,
        child: VideoPlayer(player),
      ),
    );
  }
}

class _CameraViewport extends StatelessWidget {
  const _CameraViewport({required this.controller});

  final CameraController? controller;

  @override
  Widget build(BuildContext context) {
    final controller = this.controller;
    if (controller == null || !controller.value.isInitialized) {
      return const CircularProgressIndicator(color: Colors.white);
    }
    return CameraPreview(controller);
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.onClose,
    required this.timerText,
    required this.paused,
  });

  final VoidCallback? onClose;
  final String? timerText;
  final bool paused;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.arrow_back),
            color: Colors.white,
            tooltip: 'Back',
          ),
          Expanded(
            child: Center(
              child: switch (timerText) {
                final text? => FittedBox(
                  fit: BoxFit.scaleDown,
                  child: _ElapsedBadge(text: paused ? 'Paused · $text' : text),
                ),
                null => const SizedBox.shrink(),
              },
            ),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }
}

/// Restart, the big capture button and Done, whose actions depend on the
/// stage. Restart and Done stay in place, dimmed, until they can be used.
class _Controls extends StatelessWidget {
  const _Controls({
    required this.stage,
    required this.enabled,
    required this.busy,
    required this.paused,
    required this.maxDuration,
    required this.stopwatch,
    required this.player,
    required this.onRecord,
    required this.onCancelCountdown,
    required this.onRestart,
    required this.onStop,
    required this.onTogglePause,
    required this.onTogglePlayback,
    required this.onSave,
  });

  final _Stage stage;
  final bool enabled;
  final bool busy;
  final bool paused;
  final Duration? maxDuration;
  final Stopwatch stopwatch;
  final VideoPlayerController? player;
  final VoidCallback onRecord;
  final VoidCallback onCancelCountdown;
  final VoidCallback onRestart;
  final VoidCallback onStop;
  final VoidCallback onTogglePause;
  final VoidCallback onTogglePlayback;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    const restartIdle = _SideAction(
      icon: Icons.refresh,
      label: 'Restart',
      onPressed: null,
    );
    const doneIdle = _SideAction(
      icon: Icons.check,
      label: 'Done',
      onPressed: null,
    );
    final (Widget left, Widget center, Widget right) = switch (stage) {
      _Stage.initializing || _Stage.error => (
        const SizedBox.shrink(),
        const SizedBox.shrink(),
        const SizedBox.shrink(),
      ),
      _Stage.ready => (
        restartIdle,
        _CaptureButton(
          label: 'Record',
          onPressed: enabled ? onRecord : null,
          limit: maxDuration,
          stopwatch: stopwatch,
        ),
        doneIdle,
      ),
      _Stage.countdown => (
        restartIdle,
        _CaptureButton(
          label: 'Cancel',
          icon: Icons.close,
          onPressed: onCancelCountdown,
          limit: maxDuration,
          stopwatch: stopwatch,
        ),
        doneIdle,
      ),
      _Stage.recording => (
        _SideAction(
          icon: Icons.refresh,
          label: 'Restart',
          onPressed: enabled ? onRestart : null,
        ),
        _CaptureButton(
          label: paused ? 'Resume' : 'Pause',
          icon: paused ? null : Icons.pause,
          onPressed: enabled ? onTogglePause : null,
          limit: maxDuration,
          stopwatch: stopwatch,
          ticking: !paused,
        ),
        _SideAction(
          icon: Icons.check,
          label: 'Done',
          onPressed: enabled ? onStop : null,
        ),
      ),
      _Stage.review => (
        _SideAction(
          icon: Icons.refresh,
          label: 'Re-record',
          onPressed: busy ? null : onRestart,
        ),
        switch (player?.value) {
          null => const SizedBox.shrink(),
          VideoPlayerValue(isPlaying: true) => _CaptureButton.playback(
            label: 'Pause',
            icon: Icons.pause,
            onPressed: onTogglePlayback,
          ),
          VideoPlayerValue(isCompleted: true) => _CaptureButton.playback(
            label: 'Replay',
            icon: Icons.replay,
            onPressed: onTogglePlayback,
          ),
          _ => _CaptureButton.playback(
            label: 'Play',
            icon: Icons.play_arrow,
            onPressed: onTogglePlayback,
          ),
        },
        _SideAction(
          icon: Icons.check,
          label: 'Save',
          onPressed: busy ? null : onSave,
        ),
      ),
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: Center(child: left)),
        center,
        Expanded(child: Center(child: right)),
      ],
    );
  }
}

/// Screen readers announce [label]; sighted users see it only if [child]
/// shows it.
class _LabeledControl extends StatelessWidget {
  const _LabeledControl({
    required this.label,
    required this.onPressed,
    required this.child,
  });

  final String label;
  final VoidCallback? onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: label,
      onTap: onPressed,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Opacity(opacity: onPressed == null ? 0.4 : 1, child: child),
      ),
    );
  }
}

/// A plain icon with its label underneath, either side of the capture
/// button.
class _SideAction extends StatelessWidget {
  const _SideAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  static const _shadows = [Shadow(blurRadius: 4)];

  @override
  Widget build(BuildContext context) {
    return _LabeledControl(
      label: label,
      onPressed: onPressed,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28, color: Colors.white, shadows: _shadows),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                shadows: _shadows,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The big round button in the middle. Its label is only announced, not
/// shown.
class _CaptureButton extends StatelessWidget {
  const _CaptureButton({
    required this.label,
    required this.onPressed,
    required this.stopwatch,
    this.icon,
    this.limit,
    this.ticking = false,
  }) : fill = _recordRed;

  const _CaptureButton.playback({
    required this.label,
    required this.icon,
    required this.onPressed,
  }) : fill = Colors.white24,
       stopwatch = null,
       limit = null,
       ticking = false;

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Color fill;

  final Duration? limit;
  final Stopwatch? stopwatch;

  final bool ticking;

  @override
  Widget build(BuildContext context) {
    Widget button = Container(
      width: 80,
      height: 80,
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 4),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 12)],
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
        child: Icon(icon, size: 32, color: Colors.white),
      ),
    );
    final limit = this.limit;
    final stopwatch = this.stopwatch;
    if (limit != null && stopwatch != null) {
      button = _CountdownRing(
        limit: limit,
        stopwatch: stopwatch,
        ticking: ticking,
        child: button,
      );
    }
    return _LabeledControl(label: label, onPressed: onPressed, child: button);
  }
}

class _CountdownRing extends StatefulWidget {
  const _CountdownRing({
    required this.limit,
    required this.stopwatch,
    required this.ticking,
    required this.child,
  });

  final Duration limit;
  final Stopwatch stopwatch;
  final bool ticking;
  final Widget child;

  @override
  State<_CountdownRing> createState() => _CountdownRingState();
}

class _CountdownRingState extends State<_CountdownRing>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => setState(() {}));
    if (widget.ticking) _ticker.start();
  }

  @override
  void didUpdateWidget(_CountdownRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.ticking && !_ticker.isActive) {
      _ticker.start();
    } else if (!widget.ticking && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  double get _progress {
    final limit = widget.limit.inMicroseconds;
    if (limit <= 0) return 1;
    return (widget.stopwatch.elapsedMicroseconds / limit).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _RingPainter(progress: _progress),
      child: Padding(padding: const EdgeInsets.all(9), child: widget.child),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({required this.progress});

  final double progress;

  static const _strokeWidth = 5.0;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(_strokeWidth / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(rect, 0, 2 * math.pi, false, paint..color = Colors.white24);
    if (progress > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        2 * math.pi * progress,
        false,
        paint..color = _recordRed,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class _Tool {
  const _Tool({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  /// Highlighted, for a setting that is switched on.
  final bool active;
}

/// Camera settings down the right edge. The chevron shows or hides their
/// labels.
class _ToolTray extends StatelessWidget {
  const _ToolTray({
    required this.tools,
    required this.expanded,
    required this.onToggle,
  });

  final List<_Tool> tools;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: onToggle,
          icon: Icon(expanded ? Icons.chevron_right : Icons.chevron_left),
          color: Colors.white,
          tooltip: expanded ? 'Hide labels' : 'Show labels',
        ),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: const BoxDecoration(
            color: Colors.black45,
            borderRadius: BorderRadius.horizontal(left: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final tool in tools)
                _ToolButton(tool: tool, expanded: expanded),
            ],
          ),
        ),
      ],
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({required this.tool, required this.expanded});

  final _Tool tool;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final color = tool.active ? _accent : Colors.white;
    return Tooltip(
      message: tool.label,
      child: _LabeledControl(
        label: tool.label,
        onPressed: tool.onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (expanded) ...[
                Text(
                  tool.label,
                  style: TextStyle(
                    color: color,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Icon(tool.icon, size: 24, color: color),
            ],
          ),
        ),
      ),
    );
  }
}

class _HintCard extends StatelessWidget {
  const _HintCard({
    required this.hints,
    required this.index,
    required this.onChanged,
  });

  final List<String> hints;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final hasPrevious = index > 0;
    final hasNext = index < hints.length - 1;
    return GestureDetector(
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity < -200 && hasNext) onChanged(index + 1);
        if (velocity > 200 && hasPrevious) onChanged(index - 1);
      },
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Semantics(
              liveRegion: true,
              label: 'Hint ${index + 1} of ${hints.length}',
              excludeSemantics: true,
              child: _HintNumber(number: index + 1),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: SingleChildScrollView(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    layoutBuilder: (current, previous) => Stack(
                      alignment: AlignmentDirectional.centerStart,
                      children: [...previous, ?current],
                    ),
                    child: Text(
                      hints[index],
                      key: ValueKey(index),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (hasNext) ...[
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: () => onChanged(index + 1),
                icon: const Icon(Icons.arrow_forward),
                iconAlignment: IconAlignment.end,
                label: const Text('Next'),
                style: FilledButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.white,
                  textStyle: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HintNumber extends StatelessWidget {
  const _HintNumber({required this.number});

  final int number;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: const BoxDecoration(color: _accent, shape: BoxShape.circle),
      child: Text(
        '$number',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _CountdownOverlay extends StatelessWidget {
  const _CountdownOverlay({required this.seconds});

  final int seconds;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black26,
      child: Center(
        child: Semantics(
          liveRegion: true,
          label: 'Recording starts in $seconds',
          excludeSemantics: true,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween(begin: 1.6, end: 1.0).animate(animation),
                child: child,
              ),
            ),
            child: Text(
              '$seconds',
              key: ValueKey(seconds),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 120,
                fontWeight: FontWeight.w700,
                shadows: [Shadow(blurRadius: 16)],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SavingOverlay extends StatelessWidget {
  const _SavingOverlay({required this.label, this.progress, this.onSkip});

  final String label;
  final double? progress;
  final VoidCallback? onSkip;

  @override
  Widget build(BuildContext context) {
    final progress = this.progress;
    return ColoredBox(
      color: Colors.black87,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 56,
              child: CircularProgressIndicator(
                value: progress,
                color: Colors.white,
                backgroundColor: Colors.white24,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              progress == null ? label : '$label ${(progress * 100).round()}%',
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
            if (onSkip case final onSkip?) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: onSkip,
                style: TextButton.styleFrom(foregroundColor: Colors.white70),
                child: const Text('Skip'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ElapsedBadge extends StatelessWidget {
  const _ElapsedBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: _recordRed,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
