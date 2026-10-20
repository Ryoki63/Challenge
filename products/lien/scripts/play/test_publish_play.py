import base64
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import publish_play as play


def _decode_part(part: str) -> dict:
    padding = "=" * (-len(part) % 4)
    return json.loads(base64.urlsafe_b64decode(part + padding))


class KeyFixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        cls.tmp = Path(cls._tmp.name)
        cls.private_key = cls.tmp / "key.pem"
        cls.public_key = cls.tmp / "key.pub.pem"
        subprocess.run(
            [
                "openssl",
                "genpkey",
                "-algorithm",
                "RSA",
                "-pkeyopt",
                "rsa_keygen_bits:2048",
                "-out",
                str(cls.private_key),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        subprocess.run(
            ["openssl", "rsa", "-in", str(cls.private_key), "-pubout", "-out", str(cls.public_key)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        cls.private_pem = cls.private_key.read_text(encoding="utf-8")

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()


class B64UrlTests(unittest.TestCase):
    def test_no_padding_and_urlsafe_alphabet(self):
        encoded = play.b64url(b"\xfb\xff\xfe")
        self.assertNotIn("=", encoded)
        self.assertNotIn("+", encoded)
        self.assertNotIn("/", encoded)
        self.assertEqual(encoded, "-__-")


class AssertionTests(KeyFixture):
    def test_claims_and_header(self):
        sa = {"client_email": "ci@example.invalid", "private_key": "unused"}
        signed_inputs = []

        def fake_signer(data, key):
            signed_inputs.append((data, key))
            return b"signature"

        assertion = play.build_assertion(sa, now=1_700_000_000, signer=fake_signer)
        header_b64, claims_b64, sig_b64 = assertion.split(".")
        header = _decode_part(header_b64)
        claims = _decode_part(claims_b64)
        self.assertEqual(header, {"alg": "RS256", "typ": "JWT"})
        self.assertEqual(claims["iss"], "ci@example.invalid")
        self.assertEqual(claims["scope"], play.SCOPE)
        self.assertEqual(claims["aud"], play.DEFAULT_TOKEN_URI)
        self.assertEqual(claims["iat"], 1_700_000_000 - 60)
        self.assertEqual(claims["exp"], 1_700_000_000 + 3600)
        self.assertEqual(sig_b64, play.b64url(b"signature"))
        self.assertEqual(len(signed_inputs), 1)
        self.assertEqual(signed_inputs[0][1], "unused")

    def test_real_rs256_signature_verifies_with_openssl(self):
        sa = {"client_email": "ci@example.invalid", "private_key": self.private_pem}
        assertion = play.build_assertion(sa, now=1_700_000_000)
        header_b64, claims_b64, sig_b64 = assertion.split(".")
        signing_input = f"{header_b64}.{claims_b64}".encode("ascii")
        signature = base64.urlsafe_b64decode(sig_b64 + "=" * (-len(sig_b64) % 4))
        sig_path = self.tmp / "sig.bin"
        sig_path.write_bytes(signature)
        proc = subprocess.run(
            [
                "openssl",
                "dgst",
                "-sha256",
                "-verify",
                str(self.public_key),
                "-signature",
                str(sig_path),
            ],
            input=signing_input,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr.decode("utf-8", "replace"))
        self.assertIn(b"Verified OK", proc.stdout)


class ServiceAccountTests(unittest.TestCase):
    def _write(self, payload):
        handle = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        with handle:
            json.dump(payload, handle)
        self.addCleanup(os.unlink, handle.name)
        return Path(handle.name)

    def test_accepts_service_account(self):
        path = self._write(
            {
                "type": "service_account",
                "client_email": "ci@example.invalid",
                "private_key": "test-key-placeholder",
            }
        )
        data = play.load_service_account(path)
        self.assertEqual(data["client_email"], "ci@example.invalid")

    def test_rejects_other_type(self):
        path = self._write({"type": "authorized_user", "client_email": "x", "private_key": "y"})
        with self.assertRaises(play.PlayError):
            play.load_service_account(path)

    def test_rejects_missing_private_key(self):
        path = self._write({"type": "service_account", "client_email": "x"})
        with self.assertRaises(play.PlayError):
            play.load_service_account(path)


class TrackTests(unittest.TestCase):
    def test_internal_only(self):
        play.validate_track("internal")
        for track in ("production", "alpha", "beta", "qa", ""):
            with self.assertRaises(play.PlayError):
                play.validate_track(track)

    def test_body_uses_string_version_codes(self):
        body = play.track_body(
            "internal",
            42,
            status="completed",
            version_name="Lien Android",
            release_notes="テスト配布",
        )
        self.assertEqual(body["track"], "internal")
        release = body["releases"][0]
        self.assertEqual(release["versionCodes"], ["42"])
        self.assertEqual(release["status"], "completed")
        self.assertEqual(release["releaseNotes"], [{"language": "ja-JP", "text": "テスト配布"}])

    def test_body_omits_empty_notes(self):
        body = play.track_body(
            "internal", 1, status="draft", version_name="Lien", release_notes=None
        )
        self.assertNotIn("releaseNotes", body["releases"][0])


class AabTests(unittest.TestCase):
    def test_accepts_zip_magic(self):
        handle = tempfile.NamedTemporaryFile("wb", suffix=".aab", delete=False)
        with handle:
            handle.write(b"PK\x03\x04rest")
        self.addCleanup(os.unlink, handle.name)
        self.assertGreater(play.validate_aab(Path(handle.name)), 0)

    def test_rejects_non_zip(self):
        handle = tempfile.NamedTemporaryFile("wb", suffix=".aab", delete=False)
        with handle:
            handle.write(b"not a zip")
        self.addCleanup(os.unlink, handle.name)
        with self.assertRaises(play.PlayError):
            play.validate_aab(Path(handle.name))

    def test_rejects_missing(self):
        with self.assertRaises(play.PlayError):
            play.validate_aab(Path("/nonexistent/lien.aab"))


class FlowTests(unittest.TestCase):
    def _aab(self):
        handle = tempfile.NamedTemporaryFile("wb", suffix=".aab", delete=False)
        with handle:
            handle.write(b"PK\x03\x04rest")
        self.addCleanup(os.unlink, handle.name)
        return Path(handle.name)

    def _sa(self):
        handle = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        with handle:
            json.dump(
                {
                    "type": "service_account",
                    "client_email": "ci@example.invalid",
                    "private_key": "unused",
                    "token_uri": "https://oauth2.example.invalid/token",
                },
                handle,
            )
        self.addCleanup(os.unlink, handle.name)
        return Path(handle.name)

    def test_dry_run_lists_bundles_and_deletes_edit(self):
        args = play.parse_args(
            [
                "--service-account",
                str(self._sa()),
                "--package",
                "com.ryoki63.lien",
                "--aab",
                str(self._aab()),
                "--dry-run",
            ]
        )
        with mock.patch.object(play, "build_assertion", return_value="assertion"), \
             mock.patch.object(play, "access_token", return_value="token"), \
             mock.patch.object(play, "create_edit", return_value={"id": "edit-1"}), \
             mock.patch.object(play, "list_bundles", return_value=[1, 2]), \
             mock.patch.object(play, "upload_bundle") as upload, \
             mock.patch.object(play, "delete_edit") as delete:
            self.assertEqual(play.run(args), 0)
            upload.assert_not_called()
            delete.assert_called_once()

    def test_failed_upload_deletes_edit(self):
        args = play.parse_args(
            [
                "--service-account",
                str(self._sa()),
                "--package",
                "com.ryoki63.lien",
                "--aab",
                str(self._aab()),
            ]
        )
        with mock.patch.object(play, "build_assertion", return_value="assertion"), \
             mock.patch.object(play, "access_token", return_value="token"), \
             mock.patch.object(play, "create_edit", return_value={"id": "edit-1"}), \
             mock.patch.object(play, "upload_bundle", side_effect=play.PlayError("boom")), \
             mock.patch.object(play, "delete_edit") as delete:
            with self.assertRaises(play.PlayError):
                play.run(args)
            delete.assert_called_once()

    def test_commit_happens_after_track_update(self):
        args = play.parse_args(
            [
                "--service-account",
                str(self._sa()),
                "--package",
                "com.ryoki63.lien",
                "--aab",
                str(self._aab()),
                "--release-notes",
                "note",
            ]
        )
        calls = []
        with mock.patch.object(play, "build_assertion", return_value="assertion"), \
             mock.patch.object(play, "access_token", return_value="token"), \
             mock.patch.object(play, "create_edit", return_value={"id": "edit-1"}), \
             mock.patch.object(play, "upload_bundle", return_value={"versionCode": 7}), \
             mock.patch.object(play, "update_track", side_effect=lambda *a, **k: calls.append("track") or {}), \
             mock.patch.object(play, "commit_edit", side_effect=lambda *a, **k: calls.append("commit") or {}):
            self.assertEqual(play.run(args), 0)
        self.assertEqual(calls, ["track", "commit"])


if __name__ == "__main__":
    unittest.main()
