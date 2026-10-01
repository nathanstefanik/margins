import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "apple-upload.sh"

XCRUN_STUB = """#!/bin/sh
printf '%s\\n' "$*" >> "${XC_RUN_LOG:?}"
case "$1 $2" in
  "altool --validate-app")
    [ $# -eq 7 ] && [ "$4" = "--api-key" ] && [ "$6" = "--api-issuer" ] || exit 9
    case "$*" in
      *badvalidate*) exit 1 ;;
    esac
    ;;
  "altool --upload-package")
    [ $# -eq 8 ] && [ "$4" = "--wait" ] && [ "$5" = "--api-key" ] && [ "$7" = "--api-issuer" ] || exit 9
    case "$*" in
      *badupload*) exit 1 ;;
    esac
    ;;
  *) exit 9 ;;
esac
exit 0
"""


class AppleUploadWrapperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.bin_dir = self.base / "stub bin"
        self.bin_dir.mkdir()
        stub = self.bin_dir / "xcrun"
        stub.write_text(XCRUN_STUB)
        stub.chmod(0o755)
        self.output_dir = self.base / "output dir"
        self.output_dir.mkdir()
        self.xcrun_log = self.base / "xcrun.log"
        self.env = {
            "PATH": f"{self.bin_dir}:/usr/bin:/bin",
            "KEY_ID": "SYNTHKEY42",
            "ISSUER_ID": "synthetic-issuer",
            "XC_RUN_LOG": str(self.xcrun_log),
            "HOME": str(self.base),
        }

    def tearDown(self):
        self.tmp.cleanup()

    def artifact(self, name="Marginal.ipa", directory=None):
        directory = directory or self.base
        path = directory / name
        path.write_bytes(b"synthetic-artifact-bytes")
        return path

    def invoke(self, *args, env=None):
        return subprocess.run(
            ["sh", str(SCRIPT), *args],
            env=self.env if env is None else env,
            capture_output=True,
            text=True,
        )

    def xcrun_calls(self):
        if not self.xcrun_log.exists():
            return []
        return [
            line for line in self.xcrun_log.read_text().splitlines() if line
        ]

    def log_dirs(self):
        return sorted(
            p for p in self.output_dir.iterdir() if p.name.startswith("apple-upload.")
        )

    def test_validate_records_flags_and_hashes(self):
        first = self.artifact("Marginal.ipa")
        second = self.artifact("Marginal Mac.pkg")
        result = self.invoke("validate", str(self.output_dir), str(first), str(second))
        self.assertEqual(result.returncode, 0, result.stderr)

        calls = self.xcrun_calls()
        self.assertEqual(len(calls), 2)
        self.assertEqual(
            calls[0],
            f"altool --validate-app {first} --api-key SYNTHKEY42 --api-issuer synthetic-issuer",
        )
        self.assertEqual(
            calls[1],
            f"altool --validate-app {second} --api-key SYNTHKEY42 --api-issuer synthetic-issuer",
        )
        self.assertFalse(any("--upload-package" in call for call in calls))

        logs = self.log_dirs()
        self.assertEqual(len(logs), 1)
        self.assertIn(str(logs[0]), result.stdout)
        entries = sorted(p.name for p in logs[0].iterdir())
        self.assertIn("01-Marginal.ipa.sha256", entries)
        self.assertIn("02-Marginal Mac.pkg.sha256", entries)
        self.assertIn("01-Marginal.ipa-validate.log", entries)
        self.assertIn("02-Marginal Mac.pkg-validate.log", entries)
        digest = (logs[0] / "01-Marginal.ipa.sha256").read_text()
        self.assertRegex(digest, r"^[0-9a-f]{64}  ")

        mode = stat.S_IMODE(logs[0].stat().st_mode)
        self.assertEqual(mode, 0o700)
        for entry in logs[0].iterdir():
            self.assertEqual(stat.S_IMODE(entry.stat().st_mode), 0o600)

    def test_confirmed_upload_validates_all_before_uploading(self):
        first = self.artifact("Marginal.ipa")
        second = self.artifact("Marginal.pkg")
        result = self.invoke(
            "upload", "--confirm", str(self.output_dir), str(first), str(second)
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.xcrun_calls()
        self.assertEqual(len(calls), 4)
        self.assertTrue(all("--validate-app" in call for call in calls[:2]))
        self.assertTrue(
            all("--upload-package" in call and "--wait" in call for call in calls[2:])
        )
        self.assertIn(
            f"altool --upload-package {first} --wait --api-key SYNTHKEY42 --api-issuer synthetic-issuer",
            calls[2:],
        )
        logs = self.log_dirs()
        names = sorted(p.name for p in logs[0].iterdir())
        self.assertIn("01-Marginal.ipa-upload.log", names)
        self.assertIn("02-Marginal.pkg-upload.log", names)

    def test_second_validation_failure_blocks_all_uploads(self):
        good = self.artifact("good.ipa")
        bad = self.artifact("badvalidate.pkg")
        result = self.invoke(
            "upload", "--confirm", str(self.output_dir), str(good), str(bad)
        )
        self.assertEqual(result.returncode, 1)
        calls = self.xcrun_calls()
        self.assertEqual(len(calls), 2)
        self.assertTrue(all("--validate-app" in call for call in calls))

    def test_upload_failure_propagates(self):
        good = self.artifact("good.ipa")
        bad = self.artifact("badupload.pkg")
        result = self.invoke(
            "upload", "--confirm", str(self.output_dir), str(good), str(bad)
        )
        self.assertEqual(result.returncode, 1)
        calls = self.xcrun_calls()
        self.assertEqual(len(calls), 4)
        self.assertIn("--upload-package", calls[-1])
        self.assertIn("badupload.pkg", calls[-1])

    def test_upload_without_confirm_does_nothing(self):
        artifact = self.artifact()
        before = set(self.output_dir.iterdir())
        result = self.invoke("upload", str(self.output_dir), str(artifact))
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.xcrun_calls(), [])
        self.assertEqual(set(self.output_dir.iterdir()), before)

    def test_missing_env_and_bad_inputs_reject(self):
        artifact = self.artifact()
        env_no_key = dict(self.env)
        del env_no_key["KEY_ID"]
        result = self.invoke(
            "validate", str(self.output_dir), str(artifact), env=env_no_key
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.xcrun_calls(), [])

        env_no_issuer = dict(self.env)
        del env_no_issuer["ISSUER_ID"]
        result = self.invoke(
            "validate", str(self.output_dir), str(artifact), env=env_no_issuer
        )
        self.assertEqual(result.returncode, 1)

        result = self.invoke("validate", str(self.base / "no such dir"), str(artifact))
        self.assertEqual(result.returncode, 1)

        result = self.invoke("validate", str(self.output_dir), str(self.base / "missing.ipa"))
        self.assertEqual(result.returncode, 1)

        text = self.base / "notes.txt"
        text.write_text("not an artifact")
        result = self.invoke("validate", str(self.output_dir), str(text))
        self.assertEqual(result.returncode, 1)

        result = self.invoke("validate", str(self.output_dir))
        self.assertEqual(result.returncode, 1)

        result = self.invoke("bogus", str(self.output_dir), str(artifact))
        self.assertEqual(result.returncode, 1)

    def test_repeated_runs_preserve_prior_logs(self):
        artifact = self.artifact()
        self.assertEqual(self.invoke("validate", str(self.output_dir), str(artifact)).returncode, 0)
        self.assertEqual(self.invoke("validate", str(self.output_dir), str(artifact)).returncode, 0)
        logs = self.log_dirs()
        self.assertEqual(len(logs), 2)
        for directory in logs:
            self.assertTrue((directory / "01-Marginal.ipa.sha256").is_file())

    def test_same_basename_artifacts_get_numbered_logs(self):
        dir_a = self.base / "dir one"
        dir_b = self.base / "dir two"
        dir_a.mkdir()
        dir_b.mkdir()
        first = self.artifact("Margins.ipa", dir_a)
        second = self.artifact("Margins.ipa", dir_b)
        result = self.invoke("validate", str(self.output_dir), str(first), str(second))
        self.assertEqual(result.returncode, 0, result.stderr)
        logs = self.log_dirs()
        names = sorted(p.name for p in logs[0].iterdir())
        self.assertIn("01-Margins.ipa.sha256", names)
        self.assertIn("02-Margins.ipa.sha256", names)
        self.assertIn("01-Margins.ipa-validate.log", names)
        self.assertIn("02-Margins.ipa-validate.log", names)


if __name__ == "__main__":
    unittest.main()
