"""Adversarial source/discovery/publication checks, runnable without Apple tools."""

import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("release", ROOT / "Scripts/release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


def configuration():
    return release.read_json(ROOT / "Configuration/release.json")


def upstream(config, number=None):
    number = number or config["libass"]["version"]
    checksum = config["libass"]["sha256"] if number == config["libass"]["version"] else "a" * 64
    return {"tag_name": number, "html_url": f"https://github.com/libass/libass/releases/tag/{number}",
            "published_at": "2026-09-01T12:00:00Z", "draft": False, "prerelease": False,
            "assets": [{"name": f"libass-{number}.tar.xz", "state": "uploaded", "size": 100,
                        "browser_download_url": release.source_url("libass", number),
                        "digest": "sha256:" + checksum}]}


def write_tar(path, entries):
    with tarfile.open(path, "w:xz") as archive:
        for name, kind, target in entries:
            item = tarfile.TarInfo(name)
            item.type = kind
            if kind == tarfile.REGTYPE:
                data = target.encode()
                item.size = len(data)
                archive.addfile(item, io.BytesIO(data))
            else:
                item.linkname = target
                archive.addfile(item)


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.config = configuration()
        major, minor, patch_number = release.version(self.config["libass"]["version"])
        self.next = f"{major}.{minor}.{patch_number + 1}"

    def test_current_release_is_noop(self):
        result = release.discover_document(upstream(self.config), self.config)
        self.assertFalse(result["updateAvailable"])
        self.assertEqual(release.prepare_config(self.config, result), self.config)

    def test_new_release_updates_only_libass_package_checksum_and_epoch(self):
        result = release.discover_document(upstream(self.config, self.next), self.config)
        candidate = release.prepare_config(self.config, result)
        self.assertTrue(result["updateAvailable"])
        self.assertEqual(candidate["libass"]["version"], self.next)
        self.assertEqual(candidate["artifact"]["swiftPackageChecksum"], release.ZERO)
        for key in ("freetype", "harfbuzz", "fribidi", "toolchain"):
            self.assertEqual(candidate[key], self.config[key])

    def test_prerelease_draft_and_noncanonical_metadata_rejected(self):
        cases = [("draft", True), ("prerelease", True), ("draft", 0), ("prerelease", None),
                 ("tag_name", "v0.17.5"), ("tag_name", "0.17.5-rc1"), ("tag_name", "0.17.05"),
                 ("tag_name", "0.17.4"), ("tag_name", "0.17.5\n"),
                 ("html_url", "https://github.com/example/libass/releases/tag/0.17.5"),
                 ("published_at", "2026-99-01T00:00:00Z"), ("published_at", None),
                 ("published_at", "2026-06-24"), ("assets", None), ("assets", []), ("assets", [1])]
        for key, value in cases:
            with self.subTest(key=key, value=value):
                document = upstream(self.config)
                document[key] = value
                with self.assertRaises(release.ReleaseError):
                    release.discover_document(document, self.config)

    def test_asset_mutations_rejected(self):
        cases = [("name", "source.tar.xz"), ("browser_download_url", "http://github.com/libass/libass/source"),
                 ("browser_download_url", "https://example.com/source.tar.xz"),
                 ("browser_download_url", release.source_url("libass", self.config["libass"]["version"]) + "?token=1"),
                 ("digest", None), ("digest", "md5:" + "a" * 32), ("digest", "sha256:" + "A" * 64),
                 ("digest", "sha256:" + release.ZERO), ("digest", "sha256:" + "a" * 64),
                 ("state", "new"), ("size", 0), ("size", True), ("size", release.MAX_ARCHIVE_SIZE + 1)]
        for key, value in cases:
            with self.subTest(key=key, value=value):
                document = upstream(self.config)
                document["assets"][0][key] = value
                with self.assertRaises(release.ReleaseError):
                    release.discover_document(document, self.config)

    def test_duplicate_source_asset_rejected(self):
        document = upstream(self.config)
        document["assets"].append(copy.deepcopy(document["assets"][0]))
        with self.assertRaises(release.ReleaseError):
            release.discover_document(document, self.config)

    def test_stale_or_inconsistent_discovery_rejected(self):
        result = release.discover_document(upstream(self.config, self.next), self.config)
        for key, value in (("configuredVersion", "0.0.1"), ("updateAvailable", False),
                           ("updateAvailable", 1), ("schemaVersion", True), ("extra", 1)):
            with self.subTest(key=key):
                malformed = copy.deepcopy(result)
                malformed[key] = value
                with self.assertRaises(release.ReleaseError):
                    release.prepare_config(self.config, malformed)

    def test_config_source_urls_and_digests_are_canonical(self):
        for component in release.COMPONENTS:
            for key, value in (("url", "https://example.org/source.tar.xz"), ("sha256", release.ZERO),
                               ("sha256", "a" * 63), ("version", "1.0.0; echo unsafe")):
                with self.subTest(component=component, key=key):
                    config = copy.deepcopy(self.config)
                    config[component][key] = value
                    with self.assertRaises(release.ReleaseError):
                        release.validate_config(config)

    def test_duplicate_json_keys_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "duplicate.json"
            path.write_text('{"schemaVersion":1,"schemaVersion":2}')
            with self.assertRaises(release.ReleaseError):
                release.read_json(path)


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "source.tar.xz"

    def test_regular_tree_and_internal_links_accepted(self):
        write_tar(self.path, [("source", tarfile.DIRTYPE, ""), ("source/LICENSE", tarfile.REGTYPE, "text"),
                             ("source/link", tarfile.SYMTYPE, "LICENSE"),
                             ("source/hard", tarfile.LNKTYPE, "source/LICENSE")])
        release.verify_tar(self.path, "source")

    def test_unsafe_member_paths_rejected(self):
        for name in ("/source/file", "../file", "source/../file", "source/./file", "source//file",
                     "other/file", "source/back\\slash", "source/line\nfeed"):
            with self.subTest(name=name):
                write_tar(self.path, [(name, tarfile.REGTYPE, "text")])
                with self.assertRaises(release.ReleaseError):
                    release.verify_tar(self.path, "source")

    def test_unsafe_links_rejected(self):
        for kind, target in ((tarfile.SYMTYPE, "../../outside"), (tarfile.SYMTYPE, "/tmp/file"),
                             (tarfile.SYMTYPE, "bad\\target"), (tarfile.LNKTYPE, "../outside"),
                             (tarfile.LNKTYPE, "/source/file")):
            with self.subTest(kind=kind, target=target):
                write_tar(self.path, [("source/link", kind, target)])
                with self.assertRaises(release.ReleaseError):
                    release.verify_tar(self.path, "source")

    def test_duplicate_entries_and_link_descendants_rejected(self):
        for entries in ([('source/file', tarfile.REGTYPE, "a"), ('source/file', tarfile.REGTYPE, "b")],
                        [('source/link', tarfile.SYMTYPE, "directory"), ('source/link/file', tarfile.REGTYPE, "x")],
                        [('source/file/child', tarfile.REGTYPE, "x"), ('source/file', tarfile.REGTYPE, "x")]):
            with self.subTest(entries=entries):
                write_tar(self.path, entries)
                with self.assertRaises(release.ReleaseError):
                    release.verify_tar(self.path, "source")

    def test_special_entries_rejected(self):
        for kind in (tarfile.FIFOTYPE, tarfile.CHRTYPE, tarfile.BLKTYPE):
            with self.subTest(kind=kind):
                write_tar(self.path, [("source/special", kind, "")])
                with self.assertRaises(release.ReleaseError):
                    release.verify_tar(self.path, "source")

    def test_setuid_and_empty_archives_rejected(self):
        with tarfile.open(self.path, "w:xz") as archive:
            item = tarfile.TarInfo("source/file")
            item.mode = 0o4755
            archive.addfile(item, io.BytesIO())
        with self.assertRaises(release.ReleaseError):
            release.verify_tar(self.path, "source")
        write_tar(self.path, [])
        with self.assertRaises(release.ReleaseError):
            release.verify_tar(self.path, "source")

    def test_download_rejects_non_https_and_symlink_destinations(self):
        with self.assertRaises(release.ReleaseError):
            release.download("http://example.org/source", self.path)
        self.path.symlink_to(Path(self.temporary.name) / "target")
        with self.assertRaises(release.ReleaseError):
            release.download("https://example.org/source", self.path)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.config = configuration()
        self.config["artifact"]["swiftPackageChecksum"] = release.ZERO
        for directory in ("Scripts", "Configuration", "Licenses", "Sources", "Tests", ".cache/sources", "Artifacts/LibASS.xcframework"):
            (self.root / directory).mkdir(parents=True)
        for component in release.COMPONENTS:
            number = self.config[component]["version"]
            path = self.root / ".cache/sources" / f"{component}-{number}.tar.xz"
            write_tar(path, [(f"{component}-{number}/{name}", tarfile.REGTYPE, "license")
                             for name in release.LICENSE_INPUTS[component]])
            for filename in release.LICENSE_INPUTS[component].values():
                (self.root / "Licenses" / filename).write_text("license")
            self.config[component]["sha256"] = release.sha256(path)
        self.package = (f'url: "https://github.com/{release.REPOSITORY}/releases/download/'
                        f'{self.config["packageVersion"]}/LibASS.xcframework.zip",\nchecksum: "{release.ZERO}"')
        (self.root / "Package.swift").write_text(self.package)
        (self.root / "Configuration/release.json").write_bytes(release.json_bytes(self.config))
        for filename in ("mise.toml", "mise.lock", "LICENSE", "README.md", "THIRD_PARTY_NOTICES.md",
                         "CONTRIBUTING.md", "SECURITY.md", "Scripts/build.sh", "Licenses/license.txt",
                         "Artifacts/LibASS.xcframework/Info.plist", "Artifacts/LibASS.xcframework/library.a"):
            (self.root / filename).write_text(filename)
        self.output = self.root / ".artifacts/release"

    def qualify(self):
        release.package_release(self.root, self.config, self.output)
        final = copy.deepcopy(self.config)
        final["artifact"]["swiftPackageChecksum"] = release.sha256(self.output / "LibASS.xcframework.zip")
        release.write_configuration(self.root, self.config, final)
        self.config = final
        release.package_release(self.root, self.config, self.output)
        release.verify_release(self.root, self.config, self.output)

    def test_package_finalize_verify_round_trip_and_determinism(self):
        self.qualify()
        before = {path.name: release.sha256(path) for path in self.output.iterdir()}
        os.utime(self.root / "Artifacts/LibASS.xcframework/library.a", (1, 1))
        (self.root / "Artifacts/LibASS.xcframework/library.a").chmod(0o777)
        release.package_release(self.root, self.config, self.output)
        self.assertEqual(before, {path.name: release.sha256(path) for path in self.output.iterdir()})

    def test_source_kit_contains_all_pins_and_build_recipes(self):
        self.qualify()
        with zipfile.ZipFile(self.output / release.asset_names(self.config)[1]) as archive:
            self.assertIn("Scripts/build.sh", archive.namelist())
            self.assertIn("Licenses/license.txt", archive.namelist())
            for component in release.COMPONENTS:
                self.assertIn(f'.cache/sources/{component}-{self.config[component]["version"]}.tar.xz', archive.namelist())

    def test_manifest_inventory_digest_and_config_mutations_rejected(self):
        self.qualify()
        path = self.output / "release-manifest.json"
        baseline = release.read_json(path)
        mutations = [lambda d: d.update(schemaVersion=True), lambda d: d.update(extra=1),
                     lambda d: d.update(packageVersion="9.9.9"), lambda d: d["assets"].reverse(),
                     lambda d: d["assets"][0].update(name="../file"), lambda d: d["assets"][0].update(size=1),
                     lambda d: d["assets"][0].update(sha256="a" * 64),
                     lambda d: d["configuration"]["freetype"].update(version="9.9.9")]
        for mutation in mutations:
            document = copy.deepcopy(baseline)
            mutation(document)
            path.write_bytes(release.json_bytes(document))
            with self.assertRaises(release.ReleaseError):
                release.verify_release(self.root, self.config, self.output)
        path.write_bytes(release.json_bytes(baseline))

    def test_unknown_release_assets_rejected(self):
        self.qualify()
        (self.output / "extra.txt").write_text("extra")
        with self.assertRaises(release.ReleaseError):
            release.verify_release(self.root, self.config, self.output)

    def test_checksum_file_mutation_rejected(self):
        self.qualify()
        (self.output / "SHA256SUMS").write_text("invalid")
        with self.assertRaises(release.ReleaseError):
            release.verify_release(self.root, self.config, self.output)

    def test_binary_mutation_rejected(self):
        self.qualify()
        (self.output / "LibASS.xcframework.zip").write_bytes(b"tampered")
        with self.assertRaises(release.ReleaseError):
            release.verify_release(self.root, self.config, self.output)

    def test_source_kit_compared_to_trusted_inputs(self):
        self.qualify()
        (self.root / "Scripts/build.sh").write_text("changed recipe")
        with self.assertRaises(release.ReleaseError):
            release.verify_release(self.root, self.config, self.output)

    def test_package_refuses_symlinks(self):
        (self.root / "Artifacts/LibASS.xcframework/link").symlink_to("Info.plist")
        with self.assertRaises(release.ReleaseError):
            release.package_release(self.root, self.config, self.output)

    def test_source_pin_mismatch_rejected_before_packaging(self):
        self.config["libass"]["sha256"] = "a" * 64
        with self.assertRaises(release.ReleaseError):
            release.package_release(self.root, self.config, self.output)

    def test_reviewed_license_mismatch_rejected_before_packaging(self):
        (self.root / "Licenses/libass-ISC.txt").write_text("unreviewed license")
        with self.assertRaises(release.ReleaseError):
            release.package_release(self.root, self.config, self.output)

    def test_manifest_rewrite_is_narrow_and_fails_closed(self):
        new = copy.deepcopy(self.config)
        new["packageVersion"] = "1.2.3"
        new["artifact"]["swiftPackageChecksum"] = "a" * 64
        updated = release.update_package(self.package, self.config, new)
        self.assertIn("/1.2.3/LibASS.xcframework.zip", updated)
        self.assertIn("a" * 64, updated)
        for text in (self.package * 2, self.package.replace("checksum:", "other:"),
                     self.package.replace("https://github.com/", "https://example.com/")):
            with self.assertRaises(release.ReleaseError):
                release.update_package(text, self.config, new)

    def test_placeholder_is_not_a_publishable_release(self):
        release.package_release(self.root, self.config, self.output)
        with self.assertRaises(release.ReleaseError):
            release.verify_release(self.root, self.config, self.output)

    def test_remote_verifier_does_not_need_local_sources_or_native_execution(self):
        self.qualify()
        for path in (self.root / ".cache/sources").iterdir():
            path.unlink()
        with patch.object(release.subprocess, "run", side_effect=AssertionError("must not execute binaries")):
            release.verify_release(self.root, self.config, self.output)

    def github_document(self, draft=False):
        return {"id": 123, "url": f"https://api.github.com/repos/{release.REPOSITORY}/releases/123",
                "html_url": f'https://github.com/{release.REPOSITORY}/releases/tag/{self.config["packageVersion"]}',
                "tag_name": self.config["packageVersion"], "target_commitish": "b" * 40,
                "draft": draft, "prerelease": False, "immutable": not draft,
                "assets": [{"name": path.name, "state": "uploaded", "size": path.stat().st_size,
                            "digest": "sha256:" + release.sha256(path),
                            "browser_download_url": f'https://github.com/{release.REPOSITORY}/releases/download/{self.config["packageVersion"]}/{path.name}'}
                           for path in self.output.iterdir()]}

    def test_uploaded_draft_and_immutable_release_bind_to_exact_candidate(self):
        self.qualify()
        for draft in (False, True):
            release.verify_github_release(self.github_document(draft), self.config, self.output, "b" * 40, draft)

    def test_github_release_identity_and_publication_state_rejected(self):
        self.qualify()
        for key, value in (("id", True), ("url", "https://api.github.com/repos/other/libass/releases/123"),
                           ("tag_name", "9.9.9"), ("target_commitish", "c" * 40), ("draft", True),
                           ("prerelease", True), ("immutable", False), ("html_url", "https://example.org")):
            with self.subTest(key=key):
                document = self.github_document()
                document[key] = value
                with self.assertRaises(release.ReleaseError):
                    release.verify_github_release(document, self.config, self.output, "b" * 40, False)

    def test_github_uploaded_asset_digest_inventory_and_url_rejected(self):
        self.qualify()
        for key, value in (("name", "extra.zip"), ("state", "new"), ("size", True), ("size", 1),
                           ("digest", None), ("digest", "sha256:" + "a" * 64),
                           ("browser_download_url", "https://example.org/artifact")):
            with self.subTest(key=key):
                document = self.github_document()
                document["assets"][0][key] = value
                with self.assertRaises(release.ReleaseError):
                    release.verify_github_release(document, self.config, self.output, "b" * 40, False)
        document = self.github_document()
        document["assets"].append(document["assets"][0])
        with self.assertRaises(release.ReleaseError):
            release.verify_github_release(document, self.config, self.output, "b" * 40, False)


if __name__ == "__main__":
    unittest.main()
