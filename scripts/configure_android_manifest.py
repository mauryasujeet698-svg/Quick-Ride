#!/usr/bin/env python3
"""Apply Quick-Ride Android permissions and the app-specific Supabase OAuth deep link."""
from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ANDROID_NS = "http://schemas.android.com/apk/res/android"
ET.register_namespace("android", ANDROID_NS)

def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: configure_android_manifest.py MANIFEST_PATH APP_SCHEME")
    manifest_path = Path(sys.argv[1])
    app_scheme = sys.argv[2]
    if not manifest_path.is_file():
        raise SystemExit(f"Android manifest not found: {manifest_path}")

    tree = ET.parse(manifest_path)
    root = tree.getroot()
    if root.tag != "manifest":
        raise SystemExit("Unexpected Android manifest root element")

    required = [
        "android.permission.INTERNET",
        "android.permission.ACCESS_NETWORK_STATE",
        "android.permission.ACCESS_COARSE_LOCATION",
        "android.permission.ACCESS_FINE_LOCATION",
        "android.permission.ACCESS_BACKGROUND_LOCATION",
        "android.permission.FOREGROUND_SERVICE",
        "android.permission.FOREGROUND_SERVICE_LOCATION",
        "android.permission.POST_NOTIFICATIONS",
    ]
    existing = {
        node.get(f"{{{ANDROID_NS}}}name")
        for node in root.findall("uses-permission")
    }
    for permission in required:
        if permission not in existing:
            root.insert(0, ET.Element("uses-permission", {f"{{{ANDROID_NS}}}name": permission}))

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
    ET.SubElement(intent, "action", {f"{{{ANDROID_NS}}}name": "android.intent.action.VIEW"})
    ET.SubElement(intent, "category", {f"{{{ANDROID_NS}}}name": "android.intent.category.DEFAULT"})
    ET.SubElement(intent, "category", {f"{{{ANDROID_NS}}}name": "android.intent.category.BROWSABLE"})
    ET.SubElement(intent, "data", {
        f"{{{ANDROID_NS}}}scheme": app_scheme,
        f"{{{ANDROID_NS}}}host": "login-callback",
    })

    tree.write(manifest_path, encoding="utf-8", xml_declaration=True)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
