#!/usr/bin/env python3
"""Small, fail-closed source and release pipeline; publication treats archives as data."""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.parse
import zipfile

ROOT = Path(__file__).resolve().parent.parent
UPSTREAM_API = "https://api.github.com/repos/libass/libass/releases/latest"
REPOSITORY = "vvisionnn/swift-libass"
ZERO = "0" * 64
COMPONENTS = ("libass", "freetype", "harfbuzz", "fribidi")
LICENSE_INPUTS = {
    "libass": {"COPYING": "libass-ISC.txt"},
    "freetype": {"docs/FTL.TXT": "FreeType-FTL.txt"},
    "harfbuzz": {"COPYING": "HarfBuzz-Old-MIT.txt", "src/ms-use/COPYING": "HarfBuzz-Microsoft-MIT.txt"},
    "fribidi": {"COPYING": "FriBidi-LGPL-2.1.txt"},
}
VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")
DIGEST = re.compile(r"[0-9a-f]{64}\Z")
MAX_ARCHIVE_SIZE = 512 * 1024 * 1024


class ReleaseError(ValueError):
    """An input cannot be trusted or does not describe the intended release."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ReleaseError(message)


def version(value: object) -> tuple[int, int, int]:
    require(isinstance(value, str) and VERSION.fullmatch(value) is not None,
            "expected a canonical stable three-component version")
    return tuple(int(part) for part in value.split("."))


def digest(value: object) -> str:
    require(isinstance(value, str) and DIGEST.fullmatch(value) is not None,
            "expected a lowercase SHA-256 digest")
    return value


def read_json(path: Path) -> dict:
    def unique(pairs: list) -> dict:
        result = {}
        for key, value in pairs:
            require(key not in result, f"duplicate JSON key: {key}")
            result[key] = value
        return result

    require(path.is_file() and not path.is_symlink(), f"not a regular JSON file: {path}")
    require(path.stat().st_size <= 4 * 1024 * 1024, "JSON input is too large")
    result = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique)
    require(isinstance(result, dict), "JSON document must be an object")
    return result


def json_bytes(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def sha256(path: Path) -> str:
    require(path.is_file() and not path.is_symlink(), f"not a regular file: {path}")
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def source_url(component: str, number: str) -> str:
    version(number)
    if component == "freetype":
        return f"https://download.savannah.gnu.org/releases/freetype/freetype-{number}.tar.xz"
    tag = "v" + number if component == "fribidi" else number
    return f"https://github.com/{component}/{component}/releases/download/{tag}/{component}-{number}.tar.xz"


def validate_config(config: dict) -> dict:
    require(set(config) == {"schemaVersion", "packageVersion", "artifact", "build", "toolchain", *COMPONENTS},
            "unexpected release configuration fields")
    require(type(config["schemaVersion"]) is int and config["schemaVersion"] == 1, "unsupported configuration schema")
    version(config["packageVersion"])
    for component in COMPONENTS:
        item = config[component]
        require(isinstance(item, dict) and set(item) == {"version", "url", "sha256"}, "invalid source pin")
        require(item["url"] == source_url(component, item["version"]), f"noncanonical {component} source URL")
        require(digest(item["sha256"]) != ZERO, "source checksum cannot be a placeholder")
    artifact = config["artifact"]
    require(isinstance(artifact, dict) and set(artifact) == {"name", "swiftPackageChecksum"}, "invalid artifact configuration")
    require(artifact["name"] == "LibASS.xcframework.zip", "unexpected binary artifact name")
    digest(artifact["swiftPackageChecksum"])
    build = config["build"]
    require(isinstance(build, dict) and set(build) == {"iOSMinimumVersion", "macOSMinimumVersion", "sourceDateEpoch"},
            "invalid build configuration")
    require(type(build["sourceDateEpoch"]) is int and 315532800 <= build["sourceDateEpoch"] < 4354819200,
            "sourceDateEpoch is outside the ZIP timestamp range")
    for key in ("iOSMinimumVersion", "macOSMinimumVersion"):
        require(isinstance(build[key], str) and re.fullmatch(r"[0-9]+\.[0-9]+", build[key]) is not None,
                "invalid deployment target")
    require(isinstance(config["toolchain"], dict) and config["toolchain"] and
            all(isinstance(k, str) and isinstance(v, str) and v for k, v in config["toolchain"].items()),
            "invalid toolchain pins")
    return config


def download(url: str, destination: Path, maximum: int = MAX_ARCHIVE_SIZE) -> None:
    require(urllib.parse.urlparse(url).scheme == "https", "downloads require HTTPS")
    destination.parent.mkdir(parents=True, exist_ok=True)
    require(not destination.is_symlink(), "download destination cannot be a symlink")
    # curl enforces HTTPS on redirects as well as the initial request. No shell is used.
    with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".download-", delete=False) as stream:
        temporary = Path(stream.name)
    try:
        subprocess.run(["curl", "--disable", "--fail", "--silent", "--show-error", "--location",
                        "--proto", "=https", "--proto-redir", "=https", "--tlsv1.2",
                        "--retry", "3", "--connect-timeout", "30", "--max-time", "300",
                        "--max-filesize", str(maximum), "--output", str(temporary), url], check=True)
        require(0 < temporary.stat().st_size <= maximum, "download size is unsafe")
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def discover_document(document: dict, config: dict) -> dict:
    validate_config(config)
    require(document.get("draft") is False and document.get("prerelease") is False,
            "latest upstream release must be published and stable")
    number = document.get("tag_name")
    numeric = version(number)
    require(document.get("html_url") == f"https://github.com/libass/libass/releases/tag/{number}",
            "upstream release identity mismatch")
    require(numeric >= version(config["libass"]["version"]), "upstream discovery would roll back libass")
    published = document.get("published_at")
    require(isinstance(published, str) and re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", published),
            "missing canonical release timestamp")
    try:
        dt.datetime.strptime(published, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as error:
        raise ReleaseError("invalid release timestamp") from error
    assets = document.get("assets")
    require(isinstance(assets, list) and all(isinstance(item, dict) for item in assets), "missing upstream assets")
    expected = f"libass-{number}.tar.xz"
    matches = [item for item in assets if item.get("name") == expected]
    require(len(matches) == 1, "canonical source archive must occur exactly once")
    asset = matches[0]
    require(asset.get("browser_download_url") == source_url("libass", number), "noncanonical source asset URL")
    require(asset.get("state") == "uploaded", "source archive is not fully uploaded")
    require(type(asset.get("size")) is int and 0 < asset["size"] <= MAX_ARCHIVE_SIZE, "unsafe source asset size")
    raw_digest = asset.get("digest")
    require(isinstance(raw_digest, str) and raw_digest.startswith("sha256:"), "upstream source has no SHA-256 digest")
    source_digest = digest(raw_digest[7:])
    require(source_digest != ZERO, "upstream source digest cannot be a placeholder")
    if number == config["libass"]["version"]:
        require(source_digest == config["libass"]["sha256"], "upstream changed an already pinned source release")
    return {"schemaVersion": 1, "configuredVersion": config["libass"]["version"],
            "updateAvailable": numeric > version(config["libass"]["version"]),
            "release": {"version": number, "url": source_url("libass", number),
                        "sha256": source_digest, "publishedAt": published}}


def discover(config: dict, document_path: Path | None = None) -> dict:
    if document_path:
        return discover_document(read_json(document_path), config)
    with tempfile.TemporaryDirectory(prefix="swift-libass-discovery-") as temporary:
        path = Path(temporary) / "release.json"
        download(UPSTREAM_API, path, 4 * 1024 * 1024)
        return discover_document(read_json(path), config)


def prepare_config(config: dict, discovery: dict) -> dict:
    validate_config(config)
    require(set(discovery) == {"schemaVersion", "configuredVersion", "updateAvailable", "release"} and
            type(discovery["schemaVersion"]) is int and discovery["schemaVersion"] == 1,
            "invalid discovery schema")
    require(discovery["configuredVersion"] == config["libass"]["version"], "stale discovery base")
    release = discovery["release"]
    require(isinstance(release, dict) and set(release) == {"version", "url", "sha256", "publishedAt"},
            "invalid discovered release")
    # Reuse the canonical validation for both live and saved discovery documents.
    checked = discover_document({"draft": False, "prerelease": False, "tag_name": release["version"],
        "html_url": f'https://github.com/libass/libass/releases/tag/{release["version"]}',
        "published_at": release["publishedAt"], "assets": [{"name": f'libass-{release["version"]}.tar.xz',
        "browser_download_url": release["url"], "digest": f'sha256:{release["sha256"]}',
        "state": "uploaded", "size": 1}]}, config)
    require(type(discovery["updateAvailable"]) is bool and discovery == checked, "inconsistent discovery decision")
    result = copy.deepcopy(config)
    if discovery["updateAvailable"]:
        major, minor, patch = version(config["packageVersion"])
        result["packageVersion"] = f"{major}.{minor}.{patch + 1}"
        result["libass"] = {key: release[key] for key in ("version", "url", "sha256")}
        result["build"]["sourceDateEpoch"] = int(dt.datetime.strptime(
            release["publishedAt"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc).timestamp())
        result["artifact"]["swiftPackageChecksum"] = ZERO
    return validate_config(result)


def update_package(text: str, old: dict, new: dict) -> str:
    url = f'https://github.com/{REPOSITORY}/releases/download/{old["packageVersion"]}/LibASS.xcframework.zip'
    replacement = f'https://github.com/{REPOSITORY}/releases/download/{new["packageVersion"]}/LibASS.xcframework.zip'
    pattern = re.compile(r'(url:\s*")' + re.escape(url) + r'("\s*,\s*checksum:\s*")' +
                         re.escape(old["artifact"]["swiftPackageChecksum"]) + r'(")')
    require(len(pattern.findall(text)) == 1, "Package.swift must contain exactly the configured URL/checksum pair")
    return pattern.sub(lambda match: match[1] + replacement + match[2] +
                       new["artifact"]["swiftPackageChecksum"] + match[3], text)


def write_configuration(root: Path, old: dict, new: dict) -> None:
    package = root / "Package.swift"
    require(package.is_file() and not package.is_symlink(), "Package.swift must be a regular file")
    updated = update_package(package.read_text(), old, new)
    package.write_text(updated, encoding="utf-8")
    (root / "Configuration/release.json").write_bytes(json_bytes(new))


def safe_member_name(name: str, top: str) -> str:
    require(isinstance(name, str) and name and "\\" not in name and not any(ord(char) < 32 for char in name),
            "unsafe archive path")
    value = name.rstrip("/")
    path = PurePosixPath(value)
    require(not path.is_absolute() and path.parts and path.parts[0] == top and
            all(part not in (".", "..", "") for part in name.rstrip("/").split("/")),
            f"archive path escapes its source root: {name}")
    return value


def verify_tar(path: Path, top: str) -> None:
    require(path.is_file() and not path.is_symlink(), "source archive must be a regular file")
    require(0 < path.stat().st_size <= MAX_ARCHIVE_SIZE, "source archive size is unsafe")
    members: dict[str, tarfile.TarInfo] = {}
    total = 0
    with tarfile.open(path, "r:*") as archive:
        for entry in archive:
            name = safe_member_name(entry.name, top)
            require(name not in members, f"duplicate archive path: {name}")
            require(entry.isfile() or entry.isdir() or entry.issym() or entry.islnk(), "special archive entries are forbidden")
            require(not entry.mode & 0o6000, "setuid/setgid archive entries are forbidden")
            require(entry.size >= 0, "negative archive entry size")
            total += entry.size
            require(total <= 2 * 1024**3 and len(members) < 100000, "source archive expands beyond the safety limit")
            if entry.issym() or entry.islnk():
                require(entry.linkname and not entry.linkname.startswith("/") and "\\" not in entry.linkname,
                        "unsafe archive link target")
                target = posixpath.normpath(posixpath.join(posixpath.dirname(name), entry.linkname)
                                            if entry.issym() else entry.linkname)
                safe_member_name(target, top)
            members[name] = entry
    require(members, "empty source archive")
    for name in members:
        for ancestor in PurePosixPath(name).parents:
            if str(ancestor) in members:
                require(members[str(ancestor)].isdir(), "archive entry traverses a file or symbolic link")


def verify_sources(root: Path, config: dict, fetch: bool = False) -> None:
    for component in COMPONENTS:
        item = config[component]
        path = root / ".cache/sources" / f'{component}-{item["version"]}.tar.xz'
        if fetch and not path.exists():
            download(item["url"], path)
        require(sha256(path) == item["sha256"], f"source checksum mismatch: {component}")
        verify_tar(path, f'{component}-{item["version"]}')
        with path.open("rb") as source:
            verify_licenses(source, component, item["version"], root)
        print(f"Verified {component} {item['version']}", file=sys.stderr)


def verify_licenses(source, component: str, number: str, root: Path) -> None:
    expected = {f"{component}-{number}/{name}": root / "Licenses" / filename
                for name, filename in LICENSE_INPUTS[component].items()}
    found = set()
    with tarfile.open(fileobj=source, mode="r|*") as archive:
        for item in archive:
            if item.name in expected:
                require(item.isfile() and 0 < item.size <= 1024 * 1024, "unsafe source license entry")
                require(item.name not in found, "duplicate source license")
                stream = archive.extractfile(item)
                require(stream is not None, "missing source license bytes")
                require(stream.read() == expected[item.name].read_bytes(),
                        f"source license differs from the reviewed notice: {item.name}")
                found.add(item.name)
    require(found == set(expected), f"missing {component} source licenses")


def normalized_zip(destination: Path, entries: dict[str, tuple[Path, bool]], epoch: int) -> None:
    require(entries, "cannot create an empty archive")
    timestamp = dt.datetime.fromtimestamp(epoch, dt.timezone.utc)
    stamp = (timestamp.year, timestamp.month, timestamp.day, timestamp.hour, timestamp.minute, timestamp.second // 2 * 2)
    destination.parent.mkdir(parents=True, exist_ok=True)
    require(not destination.is_symlink(), "ZIP destination cannot be a symbolic link")
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_STORED, allowZip64=True) as archive:
        for name, (path, executable) in sorted(entries.items()):
            require(path.is_file() and not path.is_symlink(), f"cannot package special file: {path}")
            info = zipfile.ZipInfo(name, stamp)
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | (0o755 if executable else 0o644)) << 16
            with path.open("rb") as source, archive.open(info, "w") as target:
                while data := source.read(1024 * 1024):
                    target.write(data)


def tree_entries(root: Path, prefix: str) -> dict[str, tuple[Path, bool]]:
    require(root.is_dir() and not root.is_symlink(), f"not a regular directory: {root}")
    result = {}
    for path in sorted(root.rglob("*")):
        require(not path.is_symlink(), f"cannot package symbolic link: {path}")
        if path.is_file():
            result[f"{prefix}/{path.relative_to(root).as_posix()}"] = (path, bool(path.stat().st_mode & 0o111))
        else:
            require(path.is_dir(), f"cannot package special entry: {path}")
    return result


def asset_names(config: dict) -> tuple[str, str]:
    return "LibASS.xcframework.zip", f'swift-libass-{config["packageVersion"]}-source-kit.zip'


def source_kit_entries(root: Path, config: dict) -> dict[str, tuple[Path, bool]]:
    entries = {}
    for directory in ("Scripts", "Configuration", "Licenses", "Sources", "Tests"):
        for name, value in tree_entries(root / directory, directory).items():
            if "__pycache__" not in PurePosixPath(name).parts and not name.endswith(".pyc"):
                entries[name] = value
    for filename in ("Package.swift", "mise.toml", "mise.lock", "LICENSE", "README.md",
                     "THIRD_PARTY_NOTICES.md", "CONTRIBUTING.md", "SECURITY.md"):
        path = root / filename
        require(path.is_file(), f"source kit is missing {filename}")
        entries[filename] = (path, False)
    for component in COMPONENTS:
        filename = f'{component}-{config[component]["version"]}.tar.xz'
        entries[f".cache/sources/{filename}"] = (root / ".cache/sources" / filename, False)
    return entries


def package_release(root: Path, config: dict, output: Path) -> None:
    verify_sources(root, config)
    output.mkdir(parents=True, exist_ok=True)
    names = asset_names(config)
    require(not output.is_symlink(), "release output cannot be a symlink")
    require(not {path.name for path in output.iterdir()} - {*names, "release-manifest.json", "SHA256SUMS"},
            "release directory has unexpected files; use an empty output directory")
    framework_entries = tree_entries(root / "Artifacts/LibASS.xcframework", "LibASS.xcframework")
    require("LibASS.xcframework/Info.plist" in framework_entries, "missing XCFramework metadata")
    normalized_zip(output / names[0], {name: (path, False) for name, (path, _) in framework_entries.items()},
                   config["build"]["sourceDateEpoch"])
    entries = source_kit_entries(root, config)
    normalized_zip(output / names[1], entries, config["build"]["sourceDateEpoch"])
    manifest = {"schemaVersion": 1, "packageVersion": config["packageVersion"], "configuration": config,
                "assets": [{"name": name, "sha256": sha256(output / name), "size": (output / name).stat().st_size}
                           for name in names]}
    (output / "release-manifest.json").write_bytes(json_bytes(manifest))
    (output / "SHA256SUMS").write_text("".join(f"{sha256(output / name)}  {name}\n"
        for name in (*names, "release-manifest.json")), encoding="ascii")
    print(f"Packaged {config['packageVersion']}: {sha256(output / names[0])}")


def verify_release(root: Path, config: dict, output: Path) -> None:
    names = asset_names(config)
    expected = {*names, "release-manifest.json", "SHA256SUMS"}
    require(output.is_dir() and not output.is_symlink(), "release directory is unsafe")
    require({path.name for path in output.iterdir()} == expected, "release file inventory mismatch")
    for name in expected:
        path = output / name
        require(path.is_file() and not path.is_symlink() and 0 < path.stat().st_size <= 2 * MAX_ARCHIVE_SIZE,
                f"unsafe release file: {name}")
    document = read_json(output / "release-manifest.json")
    require(set(document) == {"schemaVersion", "packageVersion", "configuration", "assets"} and
            type(document["schemaVersion"]) is int and document["schemaVersion"] == 1,
            "release manifest schema mismatch")
    require(document["configuration"] == config and document["packageVersion"] == config["packageVersion"],
            "release manifest configuration mismatch")
    expected_assets = [{"name": name, "sha256": sha256(output / name), "size": (output / name).stat().st_size}
                       for name in names]
    require(document["assets"] == expected_assets, "release asset size/digest inventory mismatch")
    require(config["artifact"]["swiftPackageChecksum"] != ZERO and
            config["artifact"]["swiftPackageChecksum"] == expected_assets[0]["sha256"], "Swift package checksum mismatch")
    sums = "".join(f"{sha256(output / name)}  {name}\n" for name in (*names, "release-manifest.json"))
    require((output / "SHA256SUMS").read_text(encoding="ascii") == sums, "SHA256SUMS mismatch")
    package = (root / "Package.swift").read_text(encoding="utf-8")
    require(update_package(package, config, config) == package, "Package.swift mismatch")
    # Read the source kit in place (never extract it): every recipe/license must
    # match the trusted checkout, and each upstream archive must match its pin.
    kit_entries = source_kit_entries(root, config)
    expected_hashes = {name: sha256(path) for name, (path, _) in kit_entries.items()
                       if not name.startswith(".cache/sources/")}
    for component in COMPONENTS:
        expected_hashes[f'.cache/sources/{component}-{config[component]["version"]}.tar.xz'] = config[component]["sha256"]
    with zipfile.ZipFile(output / names[1]) as archive:
        require(sorted(archive.namelist()) == sorted(expected_hashes), "source kit inventory mismatch")
        for item in archive.infolist():
            require(not item.flag_bits & 1 and stat.S_ISREG(item.external_attr >> 16), "unsafe source kit entry")
            require(0 <= item.file_size <= MAX_ARCHIVE_SIZE, "unsafe source kit size")
            with archive.open(item) as source:
                require(hashlib.file_digest(source, "sha256").hexdigest() == expected_hashes[item.filename],
                        f"source kit input mismatch: {item.filename}")
        for component in COMPONENTS:
            number = config[component]["version"]
            with archive.open(f".cache/sources/{component}-{number}.tar.xz") as source:
                verify_licenses(source, component, number, root)
    # Deliberately do not extract or execute candidate archive contents here. The
    # fresh, read-only remote-smoke job exercises published binaries afterwards.
    print(f"Verified release {config['packageVersion']} and all four fixed assets")


def verify_github_release(document: dict, config: dict, output: Path, commit: str, draft: bool) -> None:
    """Bind uploaded GitHub assets to the local verified release before publication."""
    require(re.fullmatch(r"[0-9a-f]{40}", commit) is not None, "invalid expected commit")
    require(type(document.get("id")) is int and document["id"] > 0, "invalid release ID")
    require(document.get("url") == f'https://api.github.com/repos/{REPOSITORY}/releases/{document["id"]}',
            "release belongs to a different repository")
    require(document.get("tag_name") == config["packageVersion"] and document.get("target_commitish") == commit,
            "release target does not match the verified candidate")
    require(document.get("draft") is draft and document.get("prerelease") is False, "unexpected release publication state")
    if not draft:
        require(document.get("immutable") is True, "published release is not immutable")
        require(document.get("html_url") == f'https://github.com/{REPOSITORY}/releases/tag/{config["packageVersion"]}',
                "published release URL mismatch")
    expected = {*asset_names(config), "release-manifest.json", "SHA256SUMS"}
    assets = document.get("assets")
    require(isinstance(assets, list) and all(isinstance(item, dict) for item in assets), "invalid GitHub asset inventory")
    require(len(assets) == len(expected) and {item.get("name") for item in assets} == expected,
            "uploaded GitHub asset inventory mismatch")
    for asset in assets:
        path = output / asset["name"]
        require(asset.get("state") == "uploaded" and type(asset.get("size")) is int and
                asset["size"] == path.stat().st_size and asset.get("digest") == "sha256:" + sha256(path),
                f'uploaded GitHub asset mismatch: {asset["name"]}')
        if not draft:
            expected_url = f'https://github.com/{REPOSITORY}/releases/download/{config["packageVersion"]}/{asset["name"]}'
            require(asset.get("browser_download_url") == expected_url, "published asset URL mismatch")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("fetch-sources", "verify-sources"):
        commands.add_parser(name)
    discovery_parser = commands.add_parser("discover")
    discovery_parser.add_argument("--document", type=Path)
    discovery_parser.add_argument("--github-output", type=Path)
    update_parser = commands.add_parser("prepare-update")
    update_parser.add_argument("--discovery", type=Path)
    for name in ("package", "finalize", "verify-release"):
        commands.add_parser(name).add_argument("--output", type=Path)
    github_parser = commands.add_parser("verify-github-release")
    github_parser.add_argument("--output", type=Path)
    github_parser.add_argument("--document", type=Path, required=True)
    github_parser.add_argument("--commit", required=True)
    github_parser.add_argument("--draft", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        config = validate_config(read_json(root / "Configuration/release.json"))
        if args.command in ("fetch-sources", "verify-sources"):
            verify_sources(root, config, fetch=args.command == "fetch-sources")
        elif args.command == "discover":
            result = discover(config, args.document)
            sys.stdout.buffer.write(json_bytes(result))
            if args.github_output:
                with args.github_output.open("a", encoding="utf-8") as stream:
                    stream.write(f'update_available={str(result["updateAvailable"]).lower()}\n')
                    stream.write(f'package_version={config["packageVersion"]}\n')
        elif args.command == "prepare-update":
            result = read_json(args.discovery) if args.discovery else discover(config)
            write_configuration(root, config, prepare_config(config, result))
        else:
            output = args.output or root / ".artifacts/release"
            if args.command == "package":
                package_release(root, config, output)
            elif args.command == "finalize":
                updated = copy.deepcopy(config)
                updated["artifact"]["swiftPackageChecksum"] = sha256(output / "LibASS.xcframework.zip")
                write_configuration(root, config, updated)
                print(updated["artifact"]["swiftPackageChecksum"])
            elif args.command == "verify-release":
                verify_release(root, config, output)
            else:
                verify_github_release(read_json(args.document), config, output, args.commit, args.draft)
    except (ReleaseError, OSError, ValueError, tarfile.TarError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
