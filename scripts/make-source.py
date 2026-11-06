#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Writes an AltStore / SideStore source (source.json) for one EdgePlay release.

Add the source once in AltStore/SideStore using
    https://github.com/<owner>/<repo>/releases/latest/download/source.json
and the app shows up there with an Update button for every new release.

usage: make-source.py --repo owner/name --tag v1.0.0 --ipa build/EdgePlay.ipa --out build/source.json
"""
import argparse
import datetime as dt
import json
import os

p = argparse.ArgumentParser()
p.add_argument("--repo", required=True, help="GitHub owner/name")
p.add_argument("--tag", required=True, help="release tag, e.g. v1.0.0")
p.add_argument("--ipa", required=True)
p.add_argument("--out", required=True)
p.add_argument("--bundle-id", default="com.example.edgeplay")
p.add_argument("--branch", default="main")
a = p.parse_args()

version = a.tag[1:] if a.tag.startswith("v") else a.tag
size = os.path.getsize(a.ipa)
today = dt.date.today().isoformat()
base = f"https://github.com/{a.repo}"
download = f"{base}/releases/download/{a.tag}/EdgePlay.ipa"
icon = f"https://raw.githubusercontent.com/{a.repo}/{a.branch}/assets/icon-1024.png"
description = (
    "Full-screen PS5/PS4 Remote Play for iPhone. Fill mode uses the whole display with a "
    "crop-vs-stretch slider, plays from anywhere over Tailscale, wakes the console, and shows "
    "live stream stats. Built on chiaki-ng. Not affiliated with Sony."
)

source = {
    "name": "EdgePlay",
    "identifier": f"io.github.{a.repo.replace('/', '.').lower()}.source",
    "subtitle": "Full-screen Remote Play",
    "website": base,
    "iconURL": icon,
    "apps": [
        {
            "name": "EdgePlay",
            "bundleIdentifier": a.bundle_id,
            "developerName": a.repo.split("/")[0],
            "subtitle": "Full-screen PS Remote Play",
            "localizedDescription": description,
            "iconURL": icon,
            "tintColor": "#6C4BFF",
            "category": "entertainment",
            "versions": [
                {
                    "version": version,
                    "date": today,
                    "localizedDescription": f"EdgePlay {version}",
                    "downloadURL": download,
                    "size": size,
                    "minOSVersion": "16.0",
                }
            ],
            # Older SideStore/AltStore builds read these top-level fields.
            "version": version,
            "versionDate": today,
            "downloadURL": download,
            "size": size,
            "appPermissions": {
                "entitlements": [],
                "privacy": {
                    "NSLocalNetworkUsageDescription": "Talk to your PlayStation on your network to check it's on, wake it and stream from it."
                },
            },
        }
    ],
    "news": [],
}

with open(a.out, "w") as f:
    json.dump(source, f, indent=2)
print(f"wrote {a.out} for {version} ({size} bytes)")
