#!/usr/bin/env python3
"""Make Mapbox Maps Flutter 3.34.x compatible with Flutter's AGP 9 default.

Flutter's AGP 9 migrator sets android.builtInKotlin=false by default.
Mapbox 3.34.x currently gates its KGP application on AGP < 9 alone, so
its kotlin {} block has no Kotlin extension when built-in Kotlin is off.
This narrow cache patch applies KGP whenever built-in Kotlin is not active.
"""
from __future__ import annotations

import os
import re
from pathlib import Path


def main() -> int:
    pub_cache = Path(os.environ.get("PUB_CACHE", Path.home() / ".pub-cache"))
    matches = sorted(
        pub_cache.glob(
            "hosted/pub.dev/mapbox_maps_flutter_mobile-*/android/build.gradle"
        )
    )
    if not matches:
        raise SystemExit(
            f"Could not find mapbox_maps_flutter_mobile Android Gradle file under {pub_cache}"
        )

    patched = 0
    for path in matches:
        source = path.read_text(encoding="utf-8")
        if "builtInKotlinEnabled" in source:
            continue

        pattern = re.compile(
            r"if\s*\(\s*agpMajor\s*<\s*9\s*\)\s*\{\s*"
            r"apply plugin:\s*['\"]kotlin-android['\"]\s*\}",
            re.MULTILINE,
        )
        replacement = (
            "def builtInKotlinEnabled = "
            "rootProject.findProperty('android.builtInKotlin')?.toString() == 'true'\n"
            "if (agpMajor < 9 || !builtInKotlinEnabled) {\n"
            "    apply plugin: 'kotlin-android'\n"
            "}"
        )
        updated, count = pattern.subn(replacement, source, count=1)
        if count != 1:
            raise SystemExit(
                f"Unsupported Mapbox Android Gradle layout in {path}; "
                "expected the AGP-major Kotlin plugin guard."
            )
        path.write_text(updated, encoding="utf-8")
        patched += 1

    if patched == 0:
        print("Mapbox Android Kotlin configuration already compatible.")
    else:
        print(f"Patched {patched} Mapbox Android Gradle file(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
