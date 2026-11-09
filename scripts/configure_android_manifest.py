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
