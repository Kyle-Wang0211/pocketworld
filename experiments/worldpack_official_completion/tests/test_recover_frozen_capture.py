from __future__ import annotations

import json

from recover_frozen_capture import rebuild_photo_archive_manifest


def test_rebuild_photo_archive_manifest_keeps_only_frozen_jxl_sources() -> None:
    current = {
        "schema": "pw_photo_archive_manifest_v1",
        "codec": "jpeg-xl",
        "mode": "jpeg-reconstruction",
        "libjxl_revision": "revision",
        "entries": {
            "a.jpg": {"archive_relative_path": "photos_highres/a.jpg.jxl"},
            "b.jpg": {"archive_relative_path": "photos_highres/b.jpg.jxl"},
        },
    }
    rebuilt = rebuild_photo_archive_manifest(current, {"a.jpg"})
    assert list(rebuilt["entries"]) == ["a.jpg"]
    assert json.dumps(rebuilt, indent=2).encode() == (
        b'{\n  "schema": "pw_photo_archive_manifest_v1",\n'
        b'  "codec": "jpeg-xl",\n  "mode": "jpeg-reconstruction",\n'
        b'  "libjxl_revision": "revision",\n  "entries": {\n'
        b'    "a.jpg": {\n      "archive_relative_path": '
        b'"photos_highres/a.jpg.jxl"\n    }\n  }\n}'
    )

