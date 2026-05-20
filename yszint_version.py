#!/usr/bin/env python3

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import subprocess
import sys
from typing import List


RELENG_DIR = Path(__file__).resolve().parent
ROOT_DIR = RELENG_DIR.parent


@dataclass
class YszintVersion:
    name:  str
    major: int
    minor: int
    micro: int
    nano: int
    commit: str


def main(argv:  List[str]):
    parser = argparse.ArgumentParser()
    parser.add_argument("repo", nargs="?", type=Path, default=ROOT_DIR)
    args = parser.parse_args()

    version = detect(args.repo)
    print(version.name)


def detect(repo: Path) -> YszintVersion:
    version_name = "0.0.0"
    major = 0
    minor = 0
    micro = 0
    nano = 0
    commit = ""

    if not (repo / ".git").exists():
        version_file = repo / "VERSION"
        if version_file.exists():
            version_text = version_file.read_text().strip()
            m = re.match(r"^(\d+)\.(\d+)\.(\d+)(?:-(.+))?$", version_text)
            if m:
                major = int(m.group(1))
                minor = int(m.group(2))
                micro = int(m.group(3))
                suffix = m.group(4)
                if suffix:
                    version_name = f"{major}.{minor}.{micro}-{suffix}"
                else:
                    version_name = f"{major}.{minor}.{micro}"
                return YszintVersion(version_name, major, minor, micro, nano, commit)
        return YszintVersion(version_name, major, minor, micro, nano, commit)

    proc = subprocess.run(
        ["git", "describe", "--tags", "--always", "--long"],
        cwd=repo,
        capture_output=True,
        encoding="utf-8",
        check=False,
    )
    description = proc.stdout.strip()

    if "-" not in description:
        # No tags found, fall back to VERSION file
        commit = description
        version_file = repo / "VERSION"
        if version_file.exists():
            version_text = version_file.read_text().strip()
            m = re.match(r"^(\d+)\.(\d+)\.(\d+)(?:-(.+))?$", version_text)
            if m:
                major = int(m.group(1))
                minor = int(m.group(2))
                micro = int(m.group(3))
                suffix = m.group(4)
                if suffix:
                    version_name = f"{major}.{minor}.{micro}-{suffix}"
                else:
                    version_name = f"{major}.{minor}.{micro}"
        return YszintVersion(version_name, major, minor, micro, nano, commit)

    parts = description.rsplit("-", 2)
    if len(parts) != 3:
        raise VersionParseError(
            f"Unexpected format from git describe: {description!r}")

    tag_part, distance_str, commit_part = parts
    commit = commit_part.lstrip("g")

    try:
        distance = int(distance_str)
    except ValueError as exc:
        raise VersionParseError(
            f"Invalid distance in {description!r}") from exc

    nano = distance

    # Try strict semver first; if that fails, try to FIND a semver substring
    # inside the tag (handles WIP tags like 'rebase-17.9.10-wip-20260520'
    # which contain 17.9.10 but aren't bare semver). This keeps the build
    # working when a workspace is on a non-release tag (e.g. mid-rebase).
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)(?:-(.+))?$", tag_part)
    if m is None:
        m = re.search(r"(\d+)\.(\d+)\.(\d+)(?:-([^-]+))?", tag_part)
        if m is None:
            # Final fallback: don't break the build, but emit 0.0.0 so the
            # caller knows this isn't a release build.
            return YszintVersion("0.0.0", 0, 0, 0, nano, commit)

    major = int(m.group(1))
    minor = int(m.group(2))
    micro = int(m.group(3))
    suffix = m.group(4)

    if suffix is None:
        if distance == 0:
            version_name = f"{major}.{minor}.{micro}"
        else:
            micro += 1
            version_name = f"{major}.{minor}.{micro}-dev.{distance - 1}"
    else:
        base = f"{major}.{minor}.{micro}-{suffix}"
        if distance == 0:
            version_name = base
        else:
            version_name = f"{base}-dev.{distance - 1}"

    return YszintVersion(version_name, major, minor, micro, nano, commit)


class VersionParseError(Exception):
    pass


if __name__ == "__main__":
    main(sys.argv)
