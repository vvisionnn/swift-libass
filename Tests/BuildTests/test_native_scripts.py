"""Native build and privacy contracts, including adversarial mutations."""

import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BUILDER = ROOT / "Scripts/build-xcframework.sh"
VALIDATOR = ROOT / "Scripts/validate-artifact.sh"
CANONICAL = ROOT / "Scripts/support/LibASS.PrivacyInfo.xcprivacy"
PRIVACY_PATHS = (
    "ios-arm64/LibASS.framework/PrivacyInfo.xcprivacy",
    "ios-arm64_x86_64-simulator/LibASS.framework/PrivacyInfo.xcprivacy",
    "macos-arm64_x86_64/LibASS.framework/Resources/PrivacyInfo.xcprivacy",
)


class NativeScriptsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="swift-libass-native-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.framework = self.root / "LibASS.xcframework"
        for relative in PRIVACY_PATHS:
            (self.framework / relative).parent.mkdir(parents=True, exist_ok=True)

    def invoke(self, script, *args, env=None):
        return subprocess.run(
            [str(script), *map(str, args)], cwd=ROOT, env=env,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False,
        )

    def install(self):
        result = self.invoke(BUILDER, "--install-privacy-manifests", self.framework)
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_canonical_privacy_contract(self):
        expected = {
            "NSPrivacyAccessedAPITypes": [{
                "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryFileTimestamp",
                "NSPrivacyAccessedAPITypeReasons": ["C617.1", "3B52.1"],
            }],
            "NSPrivacyCollectedDataTypes": [],
            "NSPrivacyTracking": False,
            "NSPrivacyTrackingDomains": [],
        }
        self.assertEqual(plistlib.loads(CANONICAL.read_bytes()), expected)
        self.assertEqual(
            CANONICAL.read_bytes(),
            (ROOT / "Sources/LibASSLinkerSupport/PrivacyInfo.xcprivacy").read_bytes(),
        )

    def test_installs_identical_privacy_into_all_variants(self):
        self.install()
        result = self.invoke(BUILDER, "--verify-privacy-manifests", self.framework)
        self.assertEqual(result.returncode, 0, result.stdout)
        for relative in PRIVACY_PATHS:
            self.assertEqual((self.framework / relative).read_bytes(), CANONICAL.read_bytes())

    def test_rejects_modified_manifest_in_each_variant(self):
        for relative in PRIVACY_PATHS:
            with self.subTest(relative=relative):
                self.install()
                (self.framework / relative).write_text("tampered", encoding="utf-8")
                result = self.invoke(BUILDER, "--verify-privacy-manifests", self.framework)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("differs from canonical bytes", result.stdout)

    def test_rejects_missing_manifest_in_each_variant(self):
        for relative in PRIVACY_PATHS:
            with self.subTest(relative=relative):
                self.install()
                (self.framework / relative).unlink()
                result = self.invoke(BUILDER, "--verify-privacy-manifests", self.framework)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("privacy manifest is missing or unsafe", result.stdout)

    def test_install_never_follows_destination_symlink(self):
        self.install()
        sentinel = self.root / "sentinel"
        sentinel.write_text("unchanged", encoding="utf-8")
        for relative in PRIVACY_PATHS:
            with self.subTest(relative=relative):
                destination = self.framework / relative
                destination.unlink()
                destination.symlink_to(sentinel)
                result = self.invoke(BUILDER, "--install-privacy-manifests", self.framework)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("destination may not be a symbolic link", result.stdout)
                self.assertEqual(sentinel.read_text(encoding="utf-8"), "unchanged")
                destination.unlink()
                self.install()

    def test_rejects_symlinked_framework_and_resources(self):
        target = self.framework / "macos-arm64_x86_64/LibASS.framework/Resources"
        target.rmdir()
        target.symlink_to(self.root, target_is_directory=True)
        result = self.invoke(BUILDER, "--install-privacy-manifests", self.framework)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Resources directory may not be a symbolic link", result.stdout)
        alias = self.root / "Alias.xcframework"
        alias.symlink_to(self.framework, target_is_directory=True)
        result = self.invoke(BUILDER, "--verify-privacy-manifests", alias)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("XCFramework is missing or unsafe", result.stdout)

    def test_rejects_shell_startup_overrides_without_execution(self):
        sentinel = self.root / "executed"
        startup = self.root / "startup.sh"
        startup.write_text(f"touch '{sentinel}'\n", encoding="utf-8")
        for variable in ("BASH_ENV", "ENV", "CDPATH"):
            with self.subTest(variable=variable):
                environment = dict(os.environ, **{variable: str(startup)})
                result = self.invoke(BUILDER, "--verify-privacy-manifests", self.framework, env=environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Shell startup override is not accepted", result.stdout)
                self.assertFalse(sentinel.exists())

    def test_deterministic_archiver_rejects_invalid_arguments(self):
        archiver = ROOT / "Scripts/support/deterministic-ar.sh"
        result = self.invoke(archiver, "--version")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("swift-libass deterministic ar", result.stdout)
        self.assertNotEqual(self.invoke(archiver, "x", "archive.a", "object.o").returncode, 0)
        self.assertNotEqual(self.invoke(archiver).returncode, 0)

    def test_artifact_validator_rejects_missing_and_symlinked_artifacts(self):
        result = self.invoke(VALIDATOR, self.root / "absent")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing or unsafe", result.stdout)
        alias = self.root / "alias"
        alias.symlink_to(self.framework, target_is_directory=True)
        self.assertNotEqual(self.invoke(VALIDATOR, alias).returncode, 0)


@unittest.skipUnless((ROOT / "Artifacts/LibASS.xcframework").is_dir(), "native artifact not built")
class ArtifactMutationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="swift-libass-artifact-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.framework = Path(self.temporary.name) / "LibASS.xcframework"
        shutil.copytree(ROOT / "Artifacts/LibASS.xcframework", self.framework)

    def rejected(self, diagnostic):
        result = subprocess.run(
            [str(VALIDATOR), str(self.framework)], cwd=ROOT, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False,
        )
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(diagnostic, result.stdout)

    def test_accepts_all_native_variants(self):
        result = subprocess.run(
            [str(VALIDATOR), str(self.framework)], cwd=ROOT, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout)

    def add_undefined_symbol(self, symbol):
        scratch = Path(self.temporary.name)
        source = scratch / "api.c"
        source.write_text(
            f'extern int uncovered(void) __asm__("_{symbol}");\n'
            'int privacy_fixture(void) { return uncovered(); }\n',
            encoding="utf-8",
        )
        sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
        subprocess.run([
            "xcrun", "--sdk", "iphoneos", "clang", "-target", "arm64-apple-ios15.0",
            "-isysroot", sdk, "-c", str(source), "-o", str(scratch / "api.o"),
        ], check=True)
        archive = self.framework / "ios-arm64/LibASS.framework/LibASS"
        subprocess.run([
            "/usr/bin/libtool", "-static", "-D", "-o", str(scratch / "merged.a"),
            str(archive), str(scratch / "api.o"),
        ], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        shutil.copyfile(scratch / "merged.a", archive)

    def test_rejects_undeclared_required_reason_symbol(self):
        self.add_undefined_symbol("mach_absolute_time")
        self.rejected("Undeclared required-reason API _mach_absolute_time")

    def test_rejects_undeclared_required_reason_abi_variant(self):
        self.add_undefined_symbol("statfs$INODE64")
        self.rejected("Undeclared required-reason API _statfs")

    def test_rejects_missing_architecture(self):
        binary = self.framework / "ios-arm64_x86_64-simulator/LibASS.framework/LibASS"
        subprocess.run(["/usr/bin/lipo", str(binary), "-thin", "arm64", "-output", str(binary)], check=True)
        self.rejected("architectures mismatch")

    def test_rejects_modified_module_map(self):
        (self.framework / "ios-arm64/LibASS.framework/Modules/module.modulemap").write_text("invalid")
        self.rejected("Module map differs")

    def test_rejects_wrong_bundle_version(self):
        path = self.framework / "ios-arm64/LibASS.framework/Info.plist"
        info = plistlib.loads(path.read_bytes())
        info["CFBundleShortVersionString"] = "0.0.1"
        path.write_bytes(plistlib.dumps(info))
        self.rejected("bundle version mismatch")

    def test_rejects_wrong_header_version(self):
        for relative in ("ios-arm64", "ios-arm64_x86_64-simulator", "macos-arm64_x86_64"):
            path = self.framework / relative / "LibASS.framework/Headers/ass/ass.h"
            path.write_text(path.read_text().replace("#define LIBASS_VERSION", "#define WRONG_VERSION"))
        self.rejected("header version mismatch")

    def test_rejects_wrong_platform_metadata(self):
        path = self.framework / "Info.plist"
        info = plistlib.loads(path.read_bytes())
        info["AvailableLibraries"][0]["SupportedPlatform"] = "tvos"
        path.write_bytes(plistlib.dumps(info))
        self.rejected("XCFramework variants mismatch")

    def test_rejects_symlinked_binary(self):
        path = self.framework / "ios-arm64/LibASS.framework/LibASS"
        path.unlink()
        path.symlink_to(ROOT / "Artifacts/LibASS.xcframework/ios-arm64/LibASS.framework/LibASS")
        self.rejected("symbolic link or special file")


if __name__ == "__main__":
    unittest.main()
