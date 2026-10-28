# BiliDownloader Flutter

Flutter migration of the Python/PySide application. The original `src/` remains available as a reference; the Flutter application runs independently and does not invoke Python or the old update server.

## Features

- Adaptive Material 3 workspace: desktop sidebar, compact rail and mobile bottom navigation, with system/light/dark themes.
- Batch input with per-source errors, episode search, selection and output previews.
- BV/AV video and MD/EP series resolution, WBI-signed playback URLs, QR sign-in.
- Maximum quality, preferred AVC/HEVC/AV1 codec, optional FLAC/Dolby and AI dubbed audio.
- Concurrent download queue (native 1–8, Web service 1–4), pause/resume, bounded network retries and one expired-link refresh.
- Checksummed task history and frozen task options; unfinished jobs restore paused and resume only on request.
- HTTP Range and resource validation before appending partial downloads; existing output files are not overwritten.
- FFmpeg stream-copy merge, audio-only/comment-only modes, separate audio retention and ASS comments.
- Stable media identifiers in output names, flat or grouped directories, searchable tasks and scoped batch actions.
- Optional automatic covers and per-part NFO metadata, with individual attachment results and retry without downloading completed media again.
- CC subtitles as UTF-8 SRT, with explicit language preview, one-language/all-language selection and per-episode lookup. Missing tracks, login requirements and request errors remain distinct; retries preserve successful languages and media.
- Android system folder selection/export through the Storage Access Framework.
- Chinese/English UI; credentials use the OS credential store, never plain preferences.

## Toolchain and commands

Validated toolchain target: Flutter **3.47.8**, Dart **3.13.7**, Java **17**, Android API **36**, NDK **28.2.13676358**. Native FFmpeg is provided by the locked `ffmpeg_kit_flutter_new_min` dependency. Native apps need no external Python or manually configured FFmpeg executable. The Web service uses an external `ffmpeg` executable on PATH.

```sh
cd flutter_app
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter run -d linux
```

On Debian/Ubuntu, install build prerequisites:

```sh
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev libjson-glib-dev patchelf xvfb dbus-x11
xvfb-run -a dbus-run-session -- flutter test integration_test/native_smoke_test.dart -d linux
```

The Linux bundle includes Flutter and FFmpeg libraries; GTK 3, libsecret, JSON-GLib and a desktop secret service are still system dependencies. Its FFmpeg library search paths are fixed during packaging to use the included libraries. Linux credentials use cancellable asynchronous libsecret operations, so an unavailable or locked keyring cannot block the GTK event loop. A storage failure is reported; credentials remain in memory for that run.

From the repository root:

```sh
bash scripts/build_flutter.sh linux
bash scripts/build_flutter.sh android
bash scripts/build_flutter.sh web
```

For Windows, install Flutter and Visual Studio's **Desktop development with C++** workload, then run `./scripts/build_flutter.ps1` from PowerShell 7. Windows must be built on Windows. The script archives the **whole release directory**, including plugin/FFmpeg DLLs and data.

Run platform builds sequentially in the same checkout: Flutter regenerates shared plugin registration files for tests and release builds. CI uses isolated jobs.

Build artifacts go to the root `artifacts/` directory (ignored by Git). `.github/workflows/flutter-build.yml` contains separate Windows/Linux/Android/Web jobs; creating the workflow locally does not mean a remote build has run.

## Android

- Minimum Android version: API 24 (Android 7.0).
- Select a system folder in Settings to save outside the app's private storage. Permission is retained across launches.
- Downloads run while the application is open; there is no background service yet. Task records survive process termination, with unfinished tasks restored paused.
- SAF exports retain the staged source until history commits. Recovery from termination during a document-provider copy still needs device validation; an existing destination is preserved and may require manual reconciliation.
- Release APKs currently use the generated **development signing key**. Configure a private release signing key before distributing updates to users or publishing to a store. No signing key is committed.
- The app requests Internet access and user-selected folder access; it does not request unrestricted storage access.

## Web download service

`flutter build web` compiles the shared adaptive UI with a same-origin service adapter. The Dart service handles Bilibili sessions, parsing, media downloads and FFmpeg. Task updates use WebSocket events; completed files require the owning browser session.

Web batches are persisted together before entering the service queue. Closing the browser leaves both running and queued tasks on the service. Each page uses one event connection for the full queue; a disconnect preserves the last known state and offers explicit reconnection. Queue concurrency is persisted on the service and synchronized between tabs. A service restart restores unfinished work paused, requiring manual continuation.

After building, run `dart run bin/web_server.dart` from `flutter_app` and open `http://127.0.0.1:18743`. Install FFmpeg on the service host. A plain static file server is insufficient for login and downloads.

The service binds to loopback. Remote access uses an explicitly configured HTTPS origin, a local reverse proxy and an operator-generated access key. Authorization expires after 12 hours; locking or expiration leaves background tasks running. Reauthorization restores the same browser workspace, while missing ownership cookies require explicit creation of a new workspace. Bilibili cookies remain in service memory; Bilibili sign-in must be repeated after service restart. See [Web service instructions](../docs/web-service.md) for configuration, local HTTPS browser validation and independent executable builds. Production DNS/TLS deployment and real Bilibili account validation remain unverified.

## Migration limits

- Existing Python settings and encrypted sessions are left untouched. Sign in again in Flutter.
- The private legacy updater and Qt-specific font/style switches are not reused. Flutter has its own bundled font and rendering.
- Native history lives in the application support directory under `history/queue.*.json`; server history lives under the download root's `.state/`. Records store media URL fingerprints, not signed URLs or credentials. Corrupt records are preserved rather than silently reset.
- ASS currently covers ordinary scrolling/top/bottom comments; positioned/scripted comments are not converted.
- NFO files describe each part as an independent video item. Full TV-show/season library organization and music-library metadata remain separate work. Artwork keeps its actual JPEG/PNG/WebP/AVIF format; consumer support for each format varies.
- Subtitles are separate SRT files, not embedded tracks or locally generated speech transcripts. Track identity is frozen after discovery; retries refresh URLs but never substitute a different track. Signed subtitle URLs are not stored in history or sent to the browser.
- A successful mock test or build does not prove that Bilibili permits requests from a particular IP/account. Report HTTP/API failures separately from field mapping or UI errors.

To test real Linux credential storage in a private temporary keyring (requires `gnome-keyring`), run `bash scripts/test_linux_credentials.sh` from the repository root. This wrapper isolates D-Bus and XDG directories from your existing credentials.

See [rewrite progress](../docs/rewrite-progress.md) for current measured results and remaining work. [The migration validation report](../docs/flutter-validation.md) records the earlier baseline separately.
