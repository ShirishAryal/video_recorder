# video_recorder

A full-screen video recorder for Flutter apps. The package handles the camera,
recording and preview, and returns the recorded file to your app.

## Features

- **Capture**: tap the big button to start recording and **Done** to stop,
  with a running timer. A 3-2-1 countdown runs before recording starts
  (configurable, can be turned off with the timer tool, and can be
  cancelled).
- **Pause / resume**: while recording, the big button pauses and resumes, and
  the take carries on in the same file.
- **Restart**: throw away the take while recording and start over.
- **Review and replay**: after stopping, the take plays back once so the user
  can check it, with a scrubbable progress bar, Play / Pause, and Replay
  when it ends.
- **Re-record**: not happy with the take? Discard it and record again.
- **Save**: return the take to the app.
- **Camera tools**: a tray on the right edge switches between the back and
  front cameras, turns the countdown on or off, and turns the light (torch)
  on the back camera on or off. Its chevron shows or hides their labels.
- **Hints**: pass a list of messages (talking points, questions, a script)
  to show just above the record button, numbered, with a **Next** button.
  The user can also swipe between them, including while recording.
- Every control has a label that screen readers announce. Restart, Done,
  Re-record and Save show theirs under the icon; the big button's
  (Record, Pause, Resume, Cancel, Play, Replay) is announced only.
- 720p by default. 480p, 1080p and 2160p are also available.
- Optional audio.
- Compact files by default: 720p records at 2.5 Mbps (about 3 MB per 10
  seconds) instead of the phone's usual 10–15 Mbps. Video and audio bitrates
  can be overridden.
- Optional **HEVC conversion on save** (`convertToHevc`): converts the take
  to HEVC/H.265 on the device before returning it, typically 30–40% smaller
  at the same quality, so your server doesn't have to.
- Optional time limit (`maxDuration`): a ring around the record button fills
  up as time runs out, the timer shows elapsed time against the limit
  (00:12 / 00:45), and recording stops automatically at the limit.

Supported on Android and iOS 15+, and on the web without HEVC conversion
(through the [`camera`](https://pub.dev/packages/camera) plugin).

## Setup

### iOS

Add to `ios/Runner/Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>The camera is used to record videos.</string>
<key>NSMicrophoneUsageDescription</key>
<string>The microphone is used to record sound with videos.</string>
```

### Android

Requires `minSdk` 24 or higher, which is the current Flutter default. The camera
and microphone permissions are added automatically by the camera plugin.

## Usage

```dart
import 'package:video_recorder/video_recorder.dart';

final XFile? video = await VideoRecorder.record(context);

if (video != null) {
  // Upload it, move it, etc. Your app owns the file now.
  print(video.path);
}
```

`record` returns `null` if the user closes the recorder without saving.

### Options

```dart
final video = await VideoRecorder.record(
  context,
  options: const VideoRecorderOptions(
    quality: VideoQuality.p720,                   // default
    enableAudio: true,                            // default
    preferredLens: CameraLensDirection.front,     // default: back
    maxDuration: Duration(seconds: 30),           // default: no limit
    countdownSeconds: 3,                          // default: 3, 0 = off
    videoBitrate: 2500000,                        // bits/s; default: per quality
    audioBitrate: 128000,                         // bits/s; default: device
    hints: [                                      // default: none
      RecorderHint(
        'Introduce yourself',
        description: 'Say your name and what you do.',
      ),
      RecorderHint('Describe the problem'),       // description is optional
      RecorderHint('Say thanks'),
    ],
  ),
);
```

To place the recorder in your own route, use `VideoRecorderScreen`. It pops
its route with the saved `XFile`.

### Notes

- Quality is approximate: the device picks the closest size the camera supports.
- Bitrate controls file size: about `bitrate × seconds ÷ 8` bytes. Default
  video bitrates, chosen for someone talking to the camera:

  | Quality | Default video bitrate | Per 10 s | Per minute |
  |---|---|---|---|
  | `p480` | 1.2 Mbps | ~1.5 MB | ~9 MB |
  | `p720` | 2.5 Mbps | ~3.2 MB | ~19 MB |
  | `p1080` | 5 Mbps | ~6.3 MB | ~38 MB |
  | `p2160` | 16 Mbps | ~20 MB | ~120 MB |

  Pass `videoBitrate` to override. The device may round to a bitrate it
  supports.
- Unsaved takes are deleted. A saved file is never deleted by the package, so
  delete or move it when you're done with it.
- Hints show while getting ready and while recording, and are hidden while
  reviewing the take. Restart goes back to the first hint.
- If the app goes to the background while recording, that take is discarded
  and the camera is reopened when the app comes back.

## Playing the returned video

`RecordedVideoPlayer` plays the file `record` returns (or any local video),
with play/pause, a scrubbable progress bar, position and length, and Replay
when it ends. Tap the video to play or pause.

```dart
final video = await VideoRecorder.record(context);
if (video != null) {
  // e.g. in build():
  RecordedVideoPlayer(
    key: ValueKey(video.path), // or just pass a new file to load it
    file: video,
    autoPlay: false,           // default
    looping: false,            // default
  );
}
```

### From a URL

```dart
RecordedVideoPlayer.network(
  Uri.parse('https://example.com/videos/123.mp4'),
  httpHeaders: {'Authorization': 'Bearer $token'}, // optional
  autoPlay: true,
)
```

While the stream is buffering, a spinner is shown. If it fails to load, or
the connection drops during playback, the player shows a Retry button.

- Use `https`. Android and iOS block plain `http` by default.
- On Android, release builds need
  `<uses-permission android:name="android.permission.INTERNET"/>` in
  `android/app/src/main/AndroidManifest.xml` (debug builds get it
  automatically).

### Preloading a feed

`VideoPreloader` opens upcoming videos without playing them. A player given
the same preloader picks up the open video, so it starts instantly when the
user swipes to it.

```dart
final videoCache = VideoCache(); // create once, e.g. top-level
final preloader = VideoPreloader(maxIdle: 3, cache: videoCache);

// As the user moves through the feed, open the next two:
onPageChanged: (i) => preloader.preload(urls.skip(i + 1).take(2)),

RecordedVideoPlayer.network(url, preloader: preloader, autoPlay: true)

// When the feed closes:
preloader.dispose();
```

When the player goes away, the video goes back to the preloader paused at
the start. The preloader keeps at most `maxIdle` videos that aren't on
screen. Over that, it releases the least recently requested ones first,
but never the ones from the latest `preload` call, so a video the user just
left can't push out the next one. With `maxIdle` one more than the number
preloaded (3 and 2 above), the previous video stays open too and swiping
back is instant.

**Caching.** With a `VideoCache`, preloading downloads each upcoming video
whole and opens it from disk once it's done. Saved videos play from disk
next time, also after the app restarts.

Each video is downloaded once:

- If the user reaches a video whose download is nearly done (under about
  a second left at its speed so far), the player waits for it.
- If the download is further off, the player streams the video instead.
  The download still finishes in the background, so that video is
  downloaded twice this once.
- Videos that weren't preloaded just stream and aren't saved. To save one
  anyway, call `videoCache.download(url)`.

A player can read the cache without a preloader too:

```dart
RecordedVideoPlayer.network(url, cache: videoCache)
```

The cache keeps at most `maxFiles` videos (30 by default) and drops ones
not played for `maxAge` (7 days); the least recently played go first. It
counts files, not bytes, so lower `maxFiles` for long videos. Call
`videoCache.clear()` to delete everything. On the web the cache is ignored.

Downloads aren't cancelled when the user swipes past; they finish and are
kept for next time. Videos are cached by URL, so a changed video needs a
new URL.

**Data use without a cache.** The platform players decide how much a
paused video keeps downloading, and `video_player` doesn't let us limit it.
Measured with a 60-second, 19 MB video on a fast connection, a preloaded
video that was never played downloaded:

| Platform | After it was ready (~0.5 s) | After 10 s |
|---|---|---|
| Android (ExoPlayer) | 4 MB | 19 MB (about 50 s of video) |
| iOS (AVPlayer) | most of the file | the whole file |

On slower mobile connections the download is slower but heads toward the
same amount. Keep `maxIdle` small, and keep feed videos short. Limiting
preloading to the first few seconds needs a byte-limited cache or HLS
segments, which `video_player` doesn't support.

### Layout

It sizes itself to the video's shape and the available width, plus a row of
controls. Inside a box with a limited height it shrinks to fit, so wrap it
in e.g. `ConstrainedBox(constraints: BoxConstraints(maxHeight: 480))` to
keep portrait videos from filling a scrolling page. Files that can't be
played show a message instead of crashing.

## Streaming-ready files

MP4 files have an index (`moov`) that players need before they can show the
first frame. If it's at the end of the file, a player streaming from a URL
has to fetch the end first, so playback starts late and preloading the first
few seconds doesn't work.

On Save, the recorder moves the index to the front when it isn't there
already (`optimizeForStreaming`, on by default). The media is copied as-is,
without re-encoding: about 1 second for a large file, shown as "Saving…".
The HEVC converter writes its output index-first on both platforms.

For other files, e.g. picked from the gallery:

```dart
final file = await StreamableMp4.ensure(video); // or the original, unchanged
final ready = await StreamableMp4.isStreamable(video);
```

## HEVC conversion

```dart
final video = await VideoRecorder.record(
  context,
  options: const VideoRecorderOptions(convertToHevc: true),
);
```

After the user taps Save, the take is converted with the phone's own encoder
(AVFoundation on iOS, Media3 Transformer on Android) while a "Compressing…"
screen shows progress and a Skip button. Audio is copied unchanged and
portrait videos stay portrait.

- **Bitrate**: 1.5 Mbps at 720p by default (`VideoQuality.hevcBitrate`), or
  set `hevcBitrate`. Some Android devices enforce a minimum, so treat it as a
  target.
- **Always returns a usable video.** The original take is returned instead
  if the device has no HEVC encoder, the conversion fails or is skipped, or
  the HEVC file isn't smaller.
- **Playback**: HEVC plays on iOS, macOS, Safari and most Android devices,
  but not in every desktop browser. Check where the videos are watched before
  turning it on.
- **Quality**: converting re-encodes the video, which loses a little detail.
  At the default bitrates this is hard to see in talking-to-camera videos,
  but compare a few real recordings before relying on it.

`HevcConverter.convert` is also available on its own, e.g. for videos picked
from the gallery:

```dart
final result = await HevcConverter.convert(file, bitrate: 1500000);
upload(result.file); // the HEVC file, or the original if it wasn't converted
```

### iOS deployment target

The plugin needs iOS 15 or newer (Xcode 27 can't build older targets). If
your app's `Podfile` still targets an older version, set
`platform :ios, '15.0'`. If another pod still declares an older target, add
this to the `post_install` block in `ios/Podfile`:

```ruby
target.build_configurations.each do |config|
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
end
```

## Development

[`architecture.html`](architecture.html) explains how the package fits
together, with diagrams of its layers, the recorder's states, the Save
pipeline and the native bridge. Open it in a browser.

The Dart ↔ native API for HEVC conversion is generated by
[Pigeon](https://pub.dev/packages/pigeon) from `pigeons/messages.dart`. After
changing that file, regenerate the Dart, Kotlin and Swift code (don't edit
the `*.g.*` files by hand):

```sh
dart run pigeon --input pigeons/messages.dart
```

If you add a new native source file on iOS, run `pod install` in
`example/ios` so the example's Xcode project picks it up.

```sh
flutter test                                   # unit and widget tests
cd example
flutter test integration_test -d <device>      # real conversion + playback
```

`video_cache_test.dart` downloads a sample clip and plays it from the cache.
`feed_preload_test.dart` swipes through the example feed and compares how
fast a preloaded video starts. `network_player_test.dart` streams a public
sample video, so it needs
internet access but no camera (it runs on the iOS simulator).
`recorder_e2e_test.dart` and `example_app_test.dart` drive the real camera,
so they need a device or emulator with a camera, and camera and microphone
permission granted (`adb shell pm grant com.example.video_recorder_example
android.permission.CAMERA`, and the same for `RECORD_AUDIO`, once the test
app is installed). They skip themselves on the iOS simulator, which has no
camera.

## Example

See [`example/`](example/lib/main.dart).
