#!/usr/bin/env python3
"""Configure Quick-Ride Android permissions, OAuth links and Mapbox navigation."""
from __future__ import annotations

import os
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ANDROID_NS = "http://schemas.android.com/apk/res/android"
ET.register_namespace("android", ANDROID_NS)


def main() -> int:
    if len(sys.argv) not in (3, 4):
        raise SystemExit(
            "usage: configure_android_manifest.py MANIFEST_PATH APP_SCHEME [--fragment-activity]"
        )

    manifest_path = Path(sys.argv[1])
    app_scheme = sys.argv[2]
    use_fragment_activity = len(sys.argv) == 4 and sys.argv[3] == "--fragment-activity"
    if len(sys.argv) == 4 and not use_fragment_activity:
        raise SystemExit("Unknown option: " + sys.argv[3])
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
    if role == "driver":
        required.extend([
            "android.permission.ACCESS_BACKGROUND_LOCATION",
            "android.permission.FOREGROUND_SERVICE",
            "android.permission.FOREGROUND_SERVICE_LOCATION",
        ])

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
    activity = application.find("activity")
    if activity is None:
        raise SystemExit("MainActivity element not found")

    for old in list(activity.findall("intent-filter")):
        data = old.find("data")
        if data is not None and data.get(f"{{{ANDROID_NS}}}scheme") == app_scheme:
            activity.remove(old)

    intent = ET.SubElement(activity, "intent-filter")
    ET.SubElement(
        intent, "action",
        {f"{{{ANDROID_NS}}}name": "android.intent.action.VIEW"},
    )
    ET.SubElement(
        intent, "category",
        {f"{{{ANDROID_NS}}}name": "android.intent.category.DEFAULT"},
    )
    ET.SubElement(
        intent, "category",
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

    if use_fragment_activity:
        kotlin_root = manifest_path.parents[2] / "src" / "main" / "kotlin"
        main_activities = list(kotlin_root.rglob("MainActivity.kt"))
        if len(main_activities) != 1:
            raise SystemExit(
                f"Expected one MainActivity.kt for FragmentActivity, found {len(main_activities)}"
            )
        activity_file = main_activities[0]
        source = activity_file.read_text(encoding="utf-8")
        if "FlutterFragmentActivity" not in source:
            if "FlutterActivity" not in source:
                raise SystemExit("Could not find FlutterActivity in MainActivity.kt")
            source = source.replace("FlutterActivity", "FlutterFragmentActivity")
            activity_file.write_text(source, encoding="utf-8")

        gradle_file = manifest_path.parents[2] / "build.gradle.kts"
        if gradle_file.is_file():
            gradle_source = gradle_file.read_text(encoding="utf-8")
            gradle_source = gradle_source.replace(
                "compileSdk = flutter.compileSdkVersion", "compileSdk = 36"
            )
            gradle_source = gradle_source.replace(
                "minSdk = flutter.minSdkVersion", "minSdk = 21"
            )
            gradle_file.write_text(gradle_source, encoding="utf-8")
        else:
            groovy_gradle = manifest_path.parents[2] / "build.gradle"
            if not groovy_gradle.is_file():
                raise SystemExit("Android app Gradle file was not generated")
            gradle_source = groovy_gradle.read_text(encoding="utf-8")
            gradle_source = gradle_source.replace(
                "compileSdkVersion flutter.compileSdkVersion", "compileSdkVersion 36"
            )
            gradle_source = gradle_source.replace(
                "minSdkVersion flutter.minSdkVersion", "minSdkVersion 21"
            )
            groovy_gradle.write_text(gradle_source, encoding="utf-8")

        public_token = os.environ.get("MAPBOX_PUBLIC_TOKEN", "").strip()
        if not public_token.startswith("pk."):
            raise SystemExit(
                "MAPBOX_PUBLIC_TOKEN must be a restricted public Mapbox pk. token"
            )
        values_dir = manifest_path.parents[2] / "src" / "main" / "res" / "values"
        values_dir.mkdir(parents=True, exist_ok=True)
        strings_file = values_dir / "strings.xml"
        if strings_file.exists():
            strings_tree = ET.parse(strings_file)
            strings_root = strings_tree.getroot()
        else:
            strings_root = ET.Element("resources")
            strings_tree = ET.ElementTree(strings_root)
        token_node = next(
            (
                node
                for node in strings_root.findall("string")
                if node.get("name") == "mapbox_access_token"
            ),
            None,
        )
        if token_node is None:
            token_node = ET.SubElement(
                strings_root, "string", {"name": "mapbox_access_token"}
            )
        token_node.text = public_token
        strings_tree.write(strings_file, encoding="utf-8", xml_declaration=True)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
