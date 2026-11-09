#!/usr/bin/env python3
"""Configure Quick-Ride Android permissions and OAuth deep links."""
from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ANDROID_NS = "http://schemas.android.com/apk/res/android"
ET.register_namespace("android", ANDROID_NS)


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit(
            "usage: configure_android_manifest.py MANIFEST_PATH APP_SCHEME"
        )

    manifest_path = Path(sys.argv[1])
    app_scheme = sys.argv[2]
    if not manifest_path.is_file():
        raise SystemExit(f"Android manifest not found: {manifest_path}")

    role = app_scheme.rsplit(".", 1)[-1]
    required = [
        "android.permission.INTERNET",
        "android.permission.ACCESS_NETWORK_STATE",
        "android.permission.POST_NOTIFICATIONS",
    ]
    if role in ("customer", "driver"):
        required.extend([
            "android.permission.ACCESS_COARSE_LOCATION",
            "android.permission.ACCESS_FINE_LOCATION",
        ])
    if role == "customer":
        required.append("android.permission.RECORD_AUDIO")
    if role == "driver":
        required.extend([
            "android.permission.ACCESS_BACKGROUND_LOCATION",
            "android.permission.FOREGROUND_SERVICE",
            "android.permission.FOREGROUND_SERVICE_LOCATION",
        ])

    app_labels = {
        "customer": "Quick Ride",
        "driver": "Quick Ride Captain",
        "admin": "Admin",
    }
    tree = ET.parse(manifest_path)
    root = tree.getroot()
    if root.tag != "manifest":
        raise SystemExit("Unexpected Android manifest root element")

    existing = {
        node.get(f"{{{ANDROID_NS}}}name")
        for node in root.findall("uses-permission")
    }
    for permission in required:
        if permission not in existing:
            root.insert(
                0,
                ET.Element(
                    "uses-permission",
                    {f"{{{ANDROID_NS}}}name": permission},
                ),
            )

    application = root.find("application")
    if application is None:
        raise SystemExit("Android application element not found")
    application.set(f"{{{ANDROID_NS}}}label", app_labels.get(role, "Quick Ride"))

    # Use three distinct, original vector launcher marks. The vector drawable
    # works on Android 5.0+ and does not add raster assets to the APK.
    icon_paths = {
        "customer": (
            "#2463EB",
            "M54 4C81.6 4 104 26.4 104 54S81.6 104 54 104 4 81.6 4 54 26.4 4 54 4Z",
            "M54 22c-10.5 0-19 8.5-19 19 0 14.2 19 35 19 35s19-20.8 19-35c0-10.5-8.5-19-19-19Zm0 26a7 7 0 1 1 0-14 7 7 0 0 1 0 14Z",
        ),
        "driver": (
            "#008A68",
            "M54 4C81.6 4 104 26.4 104 54S81.6 104 54 104 4 81.6 4 54 26.4 4 54 4Z",
            "M36 31a10 10 0 1 1 20 0 10 10 0 0 1-20 0Zm-8 39a9 9 0 1 0 18 0 9 9 0 0 0-18 0Zm32 0a9 9 0 1 0 18 0 9 9 0 0 0-18 0ZM39 48h17l8 12h8l5 7h-8a12 12 0 0 0-23 0H39a12 12 0 0 0-23 0H12l7-17h14l6-8Z",
        ),
        "admin": (
            "#343B55",
            "M54 4C81.6 4 104 26.4 104 54S81.6 104 54 104 4 81.6 4 54 26.4 4 54 4Z",
            "M54 19 82 30v20c0 19-12 31-28 39C38 81 26 69 26 50V30l28-11Zm0 10L36 36v14c0 13 7 23 18 30 11-7 18-17 18-30V36L54 29Zm-4 14v22h8V43h-8Zm0-10v7h8v-7h-8Z",
        ),
    }
    fill, circle_path, symbol_path = icon_paths.get(role, icon_paths["customer"])
    drawable_dir = manifest_path.parent / "src" / "main" / "res" / "drawable"
    drawable_dir.mkdir(parents=True, exist_ok=True)
    launcher = (
        '<vector xmlns:android="http://schemas.android.com/apk/res/android" '
        'android:width="108dp" android:height="108dp" '
        'android:viewportWidth="108" android:viewportHeight="108">\n'
        f'<path android:fillColor="{fill}" android:pathData="{circle_path}"/>\n'
        f'<path android:fillColor="#FFFFFFFF" android:pathData="{symbol_path}"/>\n'
        '</vector>\n'
    )
    (drawable_dir / "quick_ride_launcher.xml").write_text(launcher, encoding="utf-8")
    application.set(f"{{{ANDROID_NS}}}icon", "@drawable/quick_ride_launcher")
    application.set(f"{{{ANDROID_NS}}}roundIcon", "@drawable/quick_ride_launcher")

    values_dir = manifest_path.parent / "src" / "main" / "res" / "values"
    values_dir.mkdir(parents=True, exist_ok=True)
    (values_dir / "quick_ride_branding.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<resources>\n'
        f'  <color name="quick_ride_splash_background">{fill}</color>\n'
        '</resources>\n',
        encoding="utf-8",
    )
    (drawable_dir / "launch_background.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<layer-list xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '  <item android:drawable="@color/quick_ride_splash_background"/>\n'
        '  <item android:drawable="@drawable/quick_ride_launcher" '
        'android:gravity="center" android:width="144dp" android:height="144dp"/>\n'
        '</layer-list>\n',
        encoding="utf-8",
    )

    firebase_fid_meta = next(
        (
            node
            for node in application.findall("meta-data")
            if node.get(f"{{{ANDROID_NS}}}name")
            == "firebase_messaging_installation_id_enabled"
        ),
        None,
    )
    if firebase_fid_meta is None:
        ET.SubElement(
            application,
            "meta-data",
            {
                f"{{{ANDROID_NS}}}name": "firebase_messaging_installation_id_enabled",
                f"{{{ANDROID_NS}}}value": "true",
            },
        )

    # Android 11+ discovery for voice-search recognition services.
    if role == "customer" and root.find("queries") is None:
        queries = ET.Element("queries")
        intent_query = ET.SubElement(queries, "intent")
        ET.SubElement(intent_query, "action", {
            f"{{{ANDROID_NS}}}name": "android.speech.RecognitionService"
        })
        root.insert(0, queries)

    activity = application.find("activity")
    if activity is None:
        raise SystemExit("MainActivity element not found")

    for old in list(activity.findall("intent-filter")):
        data = old.find("data")
        if (
            data is not None
            and data.get(f"{{{ANDROID_NS}}}scheme") == app_scheme
            and data.get(f"{{{ANDROID_NS}}}host") == "login-callback"
        ):
            activity.remove(old)

    intent = ET.SubElement(activity, "intent-filter")
    ET.SubElement(
        intent,
        "action",
        {f"{{{ANDROID_NS}}}name": "android.intent.action.VIEW"},
    )
    ET.SubElement(
        intent,
        "category",
        {f"{{{ANDROID_NS}}}name": "android.intent.category.DEFAULT"},
    )
    ET.SubElement(
        intent,
        "category",
        {f"{{{ANDROID_NS}}}name": "android.intent.category.BROWSABLE"},
    )
    ET.SubElement(
        intent,
        "data",
        {
            f"{{{ANDROID_NS}}}scheme": app_scheme,
            f"{{{ANDROID_NS}}}host": "login-callback",
        },
    )
    tree.write(manifest_path, encoding="utf-8", xml_declaration=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
