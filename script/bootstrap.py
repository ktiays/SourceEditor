#!/usr/bin/env python3
"""Install the pinned C dependencies without adding upstream files to Git."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parent.parent
STAMP = ".sourceeditor-dependency.json"


def file_hash(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tree_hash(directory):
    if directory.is_symlink():
        raise ValueError(f"Unexpected symbolic link: {directory}")
    files = {}
    for path in sorted(directory.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"Unexpected symbolic link: {path}")
        relative = path.relative_to(directory).as_posix()
        if path.is_file() and relative != STAMP:
            files[relative] = file_hash(path)
    return hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()


def is_ready(destination, dependency):
    stamp = destination / STAMP
    if not stamp.is_file():
        return False
    metadata = json.loads(stamp.read_text())
    return metadata.get("dependency") == dependency and metadata.get("tree_sha256") == tree_hash(destination)


def fetch_archive(dependency, cache):
    archive = cache / dependency["archive_sha256"]
    if archive.is_file() and file_hash(archive) == dependency["archive_sha256"]:
        return archive
    with tempfile.TemporaryDirectory(prefix="download-", dir=cache) as temporary:
        download = Path(temporary) / "archive"
        print(f"Downloading {dependency['name']} {dependency['version']}...", flush=True)
        subprocess.run([
            "curl", "--fail", "--location", "--silent", "--show-error",
            "--retry", "3", "--connect-timeout", "15", "--max-time", "180",
            "--proto", "=https", "--proto-redir", "=https",
            "--output", str(download), dependency["source"],
        ], check=True)
        if file_hash(download) != dependency["archive_sha256"]:
            raise ValueError(f"SHA-256 mismatch for {dependency['name']}; no files were installed")
        download.replace(archive)
    return archive


def stage_dependency(archive, dependency, destination):
    # Extract only the declared source subset, without trusting archive paths or links.
    found = set()
    roots = set()
    strip_components = dependency["strip_components"]
    paths = {PurePosixPath(item) for item in dependency["paths"]}
    with tarfile.open(archive, "r:*") as source:
        for member in source:
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or not path.parts:
                raise ValueError(f"Unsafe archive path: {member.name}")
            roots.add(path.parts[:strip_components])
            relative = PurePosixPath(*path.parts[strip_components:])
            selected = {item for item in paths if relative == item or item in relative.parents}
            if not selected:
                continue
            if not member.isfile() and not member.isdir():
                raise ValueError(f"Unsupported archive entry: {member.name}")
            target = destination.joinpath(*relative.parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with source.extractfile(member) as content, target.open("wb") as output:
                    shutil.copyfileobj(content, output)
                found.update(selected)
    if len(roots) != 1 or found != paths:
        raise ValueError(f"Archive layout does not match the pinned paths for {dependency['name']}")


def install(dependency, cache, check):
    destination = ROOT / "Vendor" / dependency["name"]
    if is_ready(destination, dependency):
        print(f"Ready: {dependency['name']} {dependency['version']}")
        return
    if check:
        raise ValueError(f"{dependency['name']} is missing or changed; run ./script/bootstrap.sh")
    archive = fetch_archive(dependency, cache)
    with tempfile.TemporaryDirectory(prefix=".bootstrap-", dir=ROOT / "Vendor") as temporary:
        staged = Path(temporary) / dependency["name"]
        staged.mkdir()
        stage_dependency(archive, dependency, staged)
        checksum = tree_hash(staged)
        if destination.exists():
            # Adopt an identical pre-bootstrap copy, but preserve any local edits.
            if tree_hash(destination) != checksum:
                raise ValueError(f"{destination} differs from the pinned archive; move it aside and rerun bootstrap")
            staged = destination
        (staged / STAMP).write_text(json.dumps({
            "dependency": dependency,
            "tree_sha256": checksum,
        }, indent=2) + "\n")
        if staged != destination:
            staged.rename(destination)
    print(f"Installed: {dependency['name']} {dependency['version']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify local dependencies without downloading")
    arguments = parser.parse_args()
    dependencies = json.loads((ROOT / "Vendor/versions.json").read_text())
    cache = ROOT / ".build/dependency-archives"
    if not arguments.check:
        cache.mkdir(parents=True, exist_ok=True)
    for dependency in dependencies:
        install(dependency, cache, arguments.check)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, tarfile.TarError, subprocess.CalledProcessError) as error:
        print(f"bootstrap: {error}", file=sys.stderr)
        sys.exit(1)
