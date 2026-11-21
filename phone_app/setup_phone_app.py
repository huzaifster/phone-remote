"""
Prepares your Flutter project for: auto-discovery, background notifications and app lock.

Run ONCE (safe to run again), from anywhere:
    python setup_phone_app.py "C:\\path\\to\\phone_app"

Put icon.png and icon_foreground.png (made by the PC app's make_icons.py) in the
same folder as this script. They give the phone app its icon.

It changes:
  - the app name + icon (home screen label "Phone Remote")
  - AndroidManifest.xml      new permissions + the background service
  - app/build.gradle.kts     Java desugaring (needed by notifications) + minSdk 23
  - MainActivity.kt          fingerprint support + hides the app in the recent-apps preview
and installs the new Flutter packages. Originals are saved next to each file as *.bak
"""
import re
import shutil
import subprocess
import sys
from pathlib import Path

PERMISSIONS = [
    "android.permission.INTERNET",
    "android.permission.CAMERA",
    "android.permission.ACCESS_WIFI_STATE",
    "android.permission.CHANGE_WIFI_MULTICAST_STATE",
    "android.permission.POST_NOTIFICATIONS",
    "android.permission.FOREGROUND_SERVICE",
    "android.permission.FOREGROUND_SERVICE_DATA_SYNC",
    "android.permission.WAKE_LOCK",
    "android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS",
    "android.permission.USE_BIOMETRIC",
]

SERVICE_TAG = (
    '<service android:name="com.pravera.flutter_foreground_task.service.ForegroundService" '
    'android:foregroundServiceType="dataSync" android:exported="false" />'
)

PACKAGES = [
    "nsd",
    "flutter_foreground_task:^9.2.2",
    "flutter_local_notifications:^19.0.0",
    "local_auth:^2.3.0",
]


def backup(path: Path) -> None:
    bak = path.with_suffix(path.suffix + ".bak")
    if not bak.exists():
        shutil.copy2(path, bak)


def patch_manifest(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    original = text
    for perm in PERMISSIONS:
        if f'"{perm}"' not in text:
            text = text.replace(
                "<application", f'<uses-permission android:name="{perm}"/>\n    <application', 1
            )
    if "ForegroundService" not in text:
        match = re.search(r"<application\b[^>]*>", text, re.S)
        if not match:
            sys.exit("Could not find the <application> tag in AndroidManifest.xml")
        text = text[: match.end()] + "\n        " + SERVICE_TAG + text[match.end():]
    if text != original:
        backup(path)
        path.write_text(text, encoding="utf-8")
    print("  AndroidManifest.xml  OK")


def patch_gradle(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    original = text
    if "isCoreLibraryDesugaringEnabled" not in text:
        text, n = re.subn(r"(compileOptions\s*\{)", r"\1\n        isCoreLibraryDesugaringEnabled = true",
                          text, count=1)
        if n == 0:
            sys.exit("Could not find compileOptions in build.gradle.kts. Tell Claude what the file looks like.")
    if "coreLibraryDesugaring(" not in text:
        text += '\ndependencies {\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")\n}\n'
    text = re.sub(r"minSdk\s*=\s*flutter\.minSdkVersion", "minSdk = 23", text)
    if text != original:
        backup(path)
        path.write_text(text, encoding="utf-8")
    print("  build.gradle.kts     OK")


def patch_main_activity(root: Path) -> None:
    files = list((root / "android/app/src/main").rglob("MainActivity.kt"))
    if not files:
        print("  MainActivity.kt      not found (skipped: fingerprint may not work)")
        return
    path = files[0]
    old = path.read_text(encoding="utf-8")
    if "FlutterFragmentActivity" in old:
        print("  MainActivity.kt      already done")
        return
    pkg = re.search(r"^package\s+([\w.]+)", old, re.M).group(1)
    backup(path)
    path.write_text(
        f"""package {pkg}

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity() {{
    override fun onCreate(savedInstanceState: Bundle?) {{
        super.onCreate(savedInstanceState)
        // Hides the app in the recent-apps preview and blocks screenshots of it.
        // Delete the next 4 lines if you want to be able to screenshot the app.
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )
    }}
}}
""",
        encoding="utf-8",
    )
    print("  MainActivity.kt     OK")


APP_LABEL = "Phone Remote"

ICON_CONFIG = """
flutter_launcher_icons:
  android: true
  ios: true
  image_path: "assets/icon.png"
  adaptive_icon_background: "#161A33"
  adaptive_icon_foreground: "assets/icon_foreground.png"
  remove_alpha_ios: true
"""


def patch_label(root: Path, manifest: Path) -> None:
    text = manifest.read_text(encoding="utf-8")
    new = re.sub(r'(<application\b[^>]*?android:label=")[^"]*(")', rf"\g<1>{APP_LABEL}\g<2>", text, count=1, flags=re.S)
    if new != text:
        backup(manifest)
        manifest.write_text(new, encoding="utf-8")
    plist = root / "ios/Runner/Info.plist"
    if plist.exists():
        t = plist.read_text(encoding="utf-8")
        t2 = re.sub(r"(<key>CFBundleDisplayName</key>\s*<string>)[^<]*(</string>)", rf"\g<1>{APP_LABEL}\g<2>", t)
        if t2 != t:
            backup(plist)
            plist.write_text(t2, encoding="utf-8")
    print("  App name             OK")


def setup_icons(root: Path) -> None:
    here = Path(__file__).resolve().parent
    assets = root / "assets"
    assets.mkdir(exist_ok=True)
    for name in ("icon.png", "icon_foreground.png"):
        src = here / name
        if not src.exists():
            print(f"  Icons                skipped ({name} not next to this script)")
            return
        shutil.copy2(src, assets / name)
    pubspec = root / "pubspec.yaml"
    text = pubspec.read_text(encoding="utf-8")
    if "flutter_launcher_icons:" not in text:
        backup(pubspec)
        pubspec.write_text(text.rstrip() + "\n" + ICON_CONFIG, encoding="utf-8")
    subprocess.run(["flutter", "pub", "add", "--dev", "flutter_launcher_icons"], cwd=root, shell=True)
    subprocess.run(["flutter", "pub", "get"], cwd=root, shell=True)
    result = subprocess.run(["dart", "run", "flutter_launcher_icons"], cwd=root, shell=True)
    print("  Icons                " + ("OK" if result.returncode == 0 else "FAILED (read the error above)"))


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    root = Path(sys.argv[1])
    manifest = root / "android/app/src/main/AndroidManifest.xml"
    gradle = root / "android/app/build.gradle.kts"
    if not manifest.exists() or not gradle.exists():
        sys.exit(
            "This doesn't look like your Flutter project folder.\n"
            "It should contain android\\app\\build.gradle.kts. Check the path."
        )
    print("Updating Android settings...")
    patch_manifest(manifest)
    patch_gradle(gradle)
    patch_main_activity(root)
    patch_label(root, manifest)

    print("\nInstalling Flutter packages (this can take a minute)...")
    result = subprocess.run(["flutter", "pub", "add", *PACKAGES], cwd=root, shell=True)
    if result.returncode != 0:
        sys.exit("\n'flutter pub add' failed. Scroll up to read the error.")
    print("\nSetting up the app icon...")
    setup_icons(root)

    print("\nAll set. Now run:  flutter run -d <your phone id>")


if __name__ == "__main__":
    main()
