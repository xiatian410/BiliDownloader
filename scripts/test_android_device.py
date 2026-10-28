#!/usr/bin/env python3
"""CI-only, disposable 16 KiB emulator. Never installs an image on a developer PC."""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "io.github.xiatian410.bili_downloader"
IMAGE = "system-images;android-35;google_apis_ps16k;x86_64"
SERIAL = "emulator-5554"
REPORTS = ROOT / "artifacts/android-device"


def run(args, *, timeout=60, check=True, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout, **kwargs)
    if check and result.returncode:
        raise RuntimeError(f"{args[0]} failed ({result.returncode}):\n{result.stdout}\n{result.stderr}")
    return result


def stop(process):
    if process and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)


def main():
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise SystemExit("This harness runs only on an ephemeral GitHub Actions runner.")
    sdk = Path(os.environ["ANDROID_HOME"])
    adb = [str(sdk / "platform-tools/adb"), "-s", SERIAL]
    REPORTS.mkdir(parents=True, exist_ok=True)

    def shell(*args, **kwargs):
        return run([*adb, "shell", *args], **kwargs).stdout.strip()

    def instrument(method, tests, name):
        result = run([*adb, "shell", "am", "instrument", "-w", "-r", "-e", "class",
                      f"{PACKAGE}.{method}", f"{PACKAGE}.test/androidx.test.runner.AndroidJUnitRunner"],
                     timeout=240, check=False)
        output = result.stdout + result.stderr
        (REPORTS / name).write_text(output)
        if result.returncode or not re.search(rf"OK \({tests} tests?\)", output):
            raise RuntimeError(f"Device tests failed; see {name}:\n{output[-12000:]}")

    with tempfile.TemporaryDirectory(prefix="bili-device-", dir=os.environ["RUNNER_TEMP"]) as temp:
        environment = dict(os.environ, ANDROID_AVD_HOME=temp)
        run([str(sdk / "cmdline-tools/latest/bin/avdmanager"), "create", "avd", "--force",
             "--name", "bili-16k", "--package", IMAGE, "--device", "pixel_2"],
            input="no\n", env=environment)
        # Only the emulator we launch is managed; refuse to replace an existing device.
        devices = run([str(sdk / "platform-tools/adb"), "devices"]).stdout
        if SERIAL in devices:
            raise RuntimeError(f"{SERIAL} is already in use")
        emulator = None
        interrupted = None
        try:
            with (REPORTS / "emulator.log").open("w") as log:
                emulator = subprocess.Popen([str(sdk / "emulator/emulator"), "-avd", "bili-16k",
                    "-port", "5554", "-no-window", "-no-audio", "-no-boot-anim", "-no-snapshot",
                    "-wipe-data", "-gpu", "swiftshader_indirect", "-memory", "4096", "-cores", "2"],
                    env=environment, stdout=log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 180
            while time.monotonic() < deadline:
                if emulator.poll() is not None:
                    raise RuntimeError("Emulator exited before boot; see emulator.log")
                if shell("getprop", "sys.boot_completed", timeout=10, check=False) == "1":
                    break
                time.sleep(2)
            else:
                raise RuntimeError("Emulator boot exceeded 180 seconds")
            assert shell("getprop", "ro.kernel.qemu") == "1", "Refusing a physical device"
            assert shell("getconf", "PAGE_SIZE") == "16384", "Not a 16 KiB environment"
            run([*adb, "root"])
            run([*adb, "wait-for-device"], timeout=30)
            shell("setprop", "bionic.linker.16kb.app_compat.enabled", "false")
            shell("setprop", "pm.16kb.app_compat.disabled", "true")
            assert shell("getprop", "bionic.linker.16kb.app_compat.enabled") == "false"
            assert shell("getprop", "pm.16kb.app_compat.disabled") == "true"
            shell("settings", "put", "system", "font_scale", "2.0")
            shell("input", "keyevent", "KEYCODE_WAKEUP")
            shell("wm", "dismiss-keyguard")
            apk = ROOT / "flutter_app/build/app/outputs/apk"
            for path in [apk / "debug/app-debug.apk", apk / "androidTest/debug/app-debug-androidTest.apk"]:
                assert path.is_file(), f"Missing {path}"
                run([*adb, "install", "-t", str(path)], timeout=90)
            shell("am", "start", "-W", "-n", f"{PACKAGE}.test/{PACKAGE}.FixtureGrantActivity")
            instrument("ExportInstrumentationTest", 4, "instrumentation.log")

            # A separate invocation is stopped while the provider holds a partial copy.
            # Polling is bounded to 20 seconds and exists only in this test harness.
            with (REPORTS / "interrupted-instrumentation.log").open("w") as log:
                interrupted = subprocess.Popen([*adb, "shell", "am", "instrument", "-w", "-r",
                    "-e", "class", f"{PACKAGE}.ExportProcessDeathTest#begin",
                    f"{PACKAGE}.test/androidx.test.runner.AndroidJUnitRunner"],
                    stdout=log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                assert interrupted.poll() is None, "Copy exited before forced stop"
                state = shell("content", "query", "--uri",
                    f"content://{PACKAGE}.test.documents/tree/root/document/root",
                    "--projection", "fixture_held")
                if "fixture_held=1" in state:
                    break
                time.sleep(0.25)
            else:
                raise RuntimeError("Provider did not reach the partial-copy checkpoint")
            shell("am", "force-stop", PACKAGE)
            interrupted.wait(timeout=15)
            instrument("ExportProcessDeathTest#recover", 1, "recovery-instrumentation.log")
            run([*adb, "pull", f"/sdcard/Android/data/{PACKAGE}/files/test-reports/.", str(REPORTS)])
            result = json.loads((REPORTS / "device-result.json").read_text())
            for flag in ["binderCopyRecovery", "receiptReusedWithoutCopy", "externalEditsPreserved",
                         "unicodeFolderExport", "providerPermissionFailure", "bundledFfmpegEncodedAndDecoded",
                         "flutterDownloadControlsVisible"]:
                assert result.get(flag) is True, flag
            assert result.get("pageSize") == 16384
            assert json.loads((REPORTS / "process-death-result.json").read_text())["forcedStopCopyRecovered"] is True
            assert (REPORTS / "android-large-font.png").stat().st_size > 0
            result.update(forcedStopCopyRecovered=True, abi=shell("getprop", "ro.product.cpu.abi"),
                          api=shell("getprop", "ro.build.version.sdk"), fontScale=shell("settings", "get", "system", "font_scale"),
                          compatibilityModeDisabled=True, systemImage=IMAGE)
            (REPORTS / "result.json").write_text(json.dumps(result, indent=2) + "\n")
            print(json.dumps(result, indent=2))
        finally:
            stop(interrupted)
            try:
                # Keep partial test evidence and process-exit reasons even on failure.
                run([*adb, "pull", f"/sdcard/Android/data/{PACKAGE}/files/test-reports/.", str(REPORTS)],
                    timeout=20, check=False)
                exits = shell("dumpsys", "activity", "exit-info", PACKAGE, timeout=20, check=False)
                (REPORTS / "process-exits.log").write_text(exits)
                logs = run([*adb, "logcat", "-d", "-t", "3000"], timeout=20, check=False)
                (REPORTS / "logcat.log").write_text(logs.stdout + logs.stderr)
            finally:
                stop(emulator)


if __name__ == "__main__":
    main()
