# BiliDownloader Flutter

Flutter migration of the Python/PySide application. The original `src/` remains available as a reference; the Flutter application runs independently and does not invoke Python or the old update server.

## Features

- Adaptive Material 3 workspace: desktop sidebar, compact rail and mobile bottom navigation, with system/light/dark themes.
- Batch input with per-source errors, episode search, selection and output previews.
- BV/AV video and MD/EP series resolution, WBI-signed playback URLs, QR sign-in.
- Maximum quality, preferred AVC/HEVC/AV1 codec, optional FLAC/Dolby and AI dubbed audio.
- Concurrent download queue (1–8), pause/resume, bounded network retries and one expired-link refresh.
- HTTP Range and resource validation before appending partial downloads; existing output files are not overwritten.
- FFmpeg stream-copy merge, audio-only/comment-only modes, separate audio retention and ASS comments.
- Stable media identifiers in output names, flat or grouped directories, searchable tasks and scoped batch actions.
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
- Downloads run while the application is open; there is no background service or persistent queue after process termination.
- Release APKs currently use the generated **development signing key**. Configure a private release signing key before distributing updates to users or publishing to a store. No signing key is committed.
- The app requests Internet access and user-selected folder access; it does not request unrestricted storage access.

## Web download service

`flutter build web` compiles the shared adaptive UI with a same-origin service adapter. The Dart service handles Bilibili sessions, parsing, media downloads and FFmpeg. Task updates use WebSocket events; completed files require the owning browser session.

After building, run `dart run bin/web_server.dart` from `flutter_app` and open `http://127.0.0.1:18743`. Install FFmpeg on the service host. A plain static file server is insufficient for login and downloads.

The service currently binds to loopback. It keeps Bilibili cookies in memory and never sends them to the frontend. Browser refresh restores tasks while the service is running; process restart persistence and authenticated remote deployment remain in progress. See [Web service instructions](../docs/web-service.md), including the real-browser fixture test and independent executable build.

## Migration limits

- Existing Python settings and encrypted sessions are left untouched. Sign in again in Flutter.
- The private legacy updater and Qt-specific font/style switches are not reused. Flutter has its own bundled font and rendering.
- The queue and partial-download identity are kept for the current app session; restart persistence is not implemented.
- ASS currently covers ordinary scrolling/top/bottom comments; positioned/scripted comments are not converted.
- A successful mock test or build does not prove that Bilibili permits requests from a particular IP/account. Report HTTP/API failures separately from field mapping or UI errors.

To test real Linux credential storage in a private temporary keyring (requires `gnome-keyring`), run `bash scripts/test_linux_credentials.sh` from the repository root. This wrapper isolates D-Bus and XDG directories from your existing credentials.

See [rewrite progress](../docs/rewrite-progress.md) for current measured results and remaining work. [The migration validation report](../docs/flutter-validation.md) records the earlier baseline separately.
