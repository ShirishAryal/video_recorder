## 0.0.1

* Full-screen recorder with capture, pause/resume, restart, save and switch-camera controls.
* Text labels under every control.
* 3-2-1 countdown before recording starts (`countdownSeconds`, default 3, 0 to turn off), with Cancel.
* Review screen plays the take once, with a scrubbable progress bar, Replay when it ends, and Re-record to discard it and record again.
* Optional `hints`: `RecorderHint`s (a title and optional description) the user steps through with Next or a swipe while recording.
* Returns the saved video as an `XFile`, or `null` if the user closes without saving.
* Records at 720p by default; 480p, 1080p and 2160p are also available.
* Optional audio.
* Saved files are streaming-ready: the MP4 index is moved to the front without re-encoding (`optimizeForStreaming`, on by default; also `StreamableMp4.ensure`). The iOS HEVC converter now writes index-first output.
* Optional on-device HEVC conversion on save (`convertToHevc`, `hevcBitrate`), with progress and Skip; falls back to the original file whenever conversion isn't possible or doesn't help. Also available as `HevcConverter.convert`.
* `RecordedVideoPlayer` widget to play the returned file, with play/pause, scrubbing and Replay.
* `VideoPreloader` opens upcoming feed videos without playing them, so `RecordedVideoPlayer.network(url, preloader: …)` starts instantly. The example app has a swipeable feed that uses it.
* `VideoPreloader` no longer lets the video the user just left push out an upcoming one, which left most feed videos not preloaded.
* `VideoCache` saves network videos to disk so they replay without the network, also after a restart. Give it to `VideoPreloader(cache: …)` to download upcoming videos whole; a player reaching one waits if its download is nearly done, else streams it. Videos that weren't preloaded stream without being saved, so nothing is downloaded twice. Uses `flutter_cache_manager`.
* `RecordedVideoPlayer.network` streams a video from a URL, with optional HTTP headers, a buffering spinner and Retry.
* Native calls use type-safe Pigeon-generated APIs (`pigeons/messages.dart`).
* Now a Flutter plugin (native code for Android and iOS); iOS 15+ required.
* Default video bitrate per quality (720p: 2.5 Mbps, about 3 MB per 10 s), overridable with `videoBitrate`; optional `audioBitrate`.
* Optional `maxDuration`: a ring around the record button fills as time runs out, the timer counts down the time left, and recording stops at 00:00.
