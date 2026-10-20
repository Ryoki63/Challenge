#!/usr/bin/env python3
"""Upload an Android App Bundle to Google Play's internal testing track.

This script intentionally uses only the Python standard library and the
`openssl` command. It does not vendor or install a Google API client, so the
supply chain is limited to Python, OpenSSL, and Google's HTTPS endpoints.

Safety properties:
  * Only the `internal` track is accepted. Production/alpha/beta are refused.
  * The service-account JSON and access token are never printed.
  * A failed upload abandons (deletes) the Play edit, so no half-applied
    change is left behind.
  * `--dry-run` authenticates, creates an edit, lists existing bundles, and
    deletes the edit without uploading anything.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any
from urllib import error, parse, request

SCOPE = "https://www.googleapis.com/auth/androidpublisher"
DEFAULT_TOKEN_URI = "https://oauth2.googleapis.com/token"
API_ROOT = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
UPLOAD_ROOT = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications"
ALLOWED_TRACKS = ("internal",)
ALLOWED_STATUSES = ("completed", "draft")


class PlayError(RuntimeError):
    """A Play API or input error that is safe to show in CI logs."""


def b64url(data: bytes) -> str:
    """Base64url without padding (RFC 7515)."""
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def sign_rs256(data: bytes, private_key_pem: str) -> bytes:
    """Sign `data` with RS256 using the openssl CLI.

    The private key is written to a 0600 temporary file and removed in a
    finally block. The key itself is never included in an exception.
    """
    tmp_path = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", suffix=".pem", delete=False
        ) as handle:
            tmp_path = handle.name
            os.chmod(tmp_path, 0o600)
            handle.write(private_key_pem)
        proc = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", tmp_path],
            input=data,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if proc.returncode != 0:
            # stderr may include the temp path but never the key contents.
            detail = proc.stderr.decode("utf-8", "replace").strip()
            raise PlayError(f"openssl failed to sign the JWT (exit {proc.returncode}): {detail}")
        return proc.stdout
    finally:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except FileNotFoundError:
                pass


def build_assertion(
    service_account: dict[str, Any],
    now: int | None = None,
    signer=sign_rs256,
) -> str:
    """Build a signed JWT assertion for the OAuth2 service-account flow."""
    issued_at = int(time.time()) if now is None else int(now)
    header = {"alg": "RS256", "typ": "JWT"}
    claims = {
        "iss": service_account["client_email"],
        "scope": SCOPE,
        "aud": service_account.get("token_uri") or DEFAULT_TOKEN_URI,
        "iat": issued_at - 60,
        "exp": issued_at + 3600,
    }
    encoded_header = b64url(json.dumps(header, separators=(",", ":")).encode("utf-8"))
    encoded_claims = b64url(json.dumps(claims, separators=(",", ":")).encode("utf-8"))
    signing_input = f"{encoded_header}.{encoded_claims}".encode("ascii")
    signature = signer(signing_input, service_account["private_key"])
    return f"{encoded_header}.{encoded_claims}.{b64url(signature)}"


def load_service_account(path: Path) -> dict[str, Any]:
    """Load and minimally validate a Google service-account JSON file."""
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise PlayError(f"service-account JSON cannot be read: {path}") from exc
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise PlayError("service-account JSON is not valid JSON") from exc
    if not isinstance(data, dict):
        raise PlayError("service-account JSON must be an object")
    if data.get("type") != "service_account":
        raise PlayError("service-account JSON must have type=service_account")
    for key in ("client_email", "private_key"):
        if not isinstance(data.get(key), str) or not data[key]:
            raise PlayError(f"service-account JSON is missing {key}")
    return data


def access_token(assertion: str, token_uri: str, timeout: int = 60) -> str:
    """Exchange a JWT assertion for an OAuth2 access token."""
    body = parse.urlencode(
        {
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": assertion,
        }
    ).encode("ascii")
    req = request.Request(
        token_uri,
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        with request.urlopen(req, timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except error.HTTPError as exc:
        detail = _read_error(exc)
        raise PlayError(f"OAuth2 token request failed: HTTP {exc.code}: {detail}") from exc
    except error.URLError as exc:
        raise PlayError(f"OAuth2 token request failed: {exc.reason}") from exc
    except TimeoutError as exc:
        raise PlayError("OAuth2 token request timed out") from exc
    if not isinstance(payload, dict):
        raise PlayError("OAuth2 response was not a JSON object")
    token = payload.get("access_token")
    if not isinstance(token, str) or not token:
        raise PlayError("OAuth2 response did not contain access_token")
    return token


def _read_error(exc: error.HTTPError) -> str:
    """Read a short, safe error message from an HTTP error response."""
    try:
        body = exc.read().decode("utf-8", "replace")
    except Exception:  # pragma: no cover - defensive
        return "no response body"
    try:
        payload = json.loads(body)
        message = payload.get("error", {}).get("message")
        if isinstance(message, str) and message:
            return message[:500]
    except (json.JSONDecodeError, AttributeError):
        pass
    return body.strip()[:500] or "no response body"


def api_json(
    method: str,
    url: str,
    token: str,
    *,
    body: dict[str, Any] | None = None,
    raw: bytes | None = None,
    content_type: str = "application/json",
    timeout: int = 180,
) -> dict[str, Any]:
    """Call a Play API endpoint and return the JSON object (or {})."""
    headers = {"Authorization": f"Bearer {token}"}
    data = None
    if raw is not None:
        headers["Content-Type"] = content_type
        data = raw
    elif body is not None:
        headers["Content-Type"] = "application/json; charset=utf-8"
        data = json.dumps(body, separators=(",", ":")).encode("utf-8")
    req = request.Request(url, data=data, headers=headers, method=method)
    try:
        with request.urlopen(req, timeout=timeout) as response:
            payload = response.read()
    except error.HTTPError as exc:
        detail = _read_error(exc)
        raise PlayError(f"{method} {url.split('?', 1)[0]} failed: HTTP {exc.code}: {detail}") from exc
    except error.URLError as exc:
        raise PlayError(f"{method} {url.split('?', 1)[0]} failed: {exc.reason}") from exc
    except TimeoutError as exc:
        raise PlayError(f"{method} {url.split('?', 1)[0]} timed out") from exc
    if not payload:
        return {}
    try:
        decoded = json.loads(payload.decode("utf-8"))
    except json.JSONDecodeError as exc:
        raise PlayError(f"{method} {url.split('?', 1)[0]} returned non-JSON") from exc
    if not isinstance(decoded, dict):
        raise PlayError(f"{method} {url.split('?', 1)[0]} returned a non-object")
    return decoded


def app_path(package: str) -> str:
    return f"{API_ROOT}/{parse.quote(package, safe='')}"


def create_edit(package: str, token: str, timeout: int) -> dict[str, Any]:
    return api_json("POST", f"{app_path(package)}/edits", token, body={}, timeout=timeout)


def delete_edit(package: str, edit_id: str, token: str, timeout: int) -> None:
    """Best-effort cleanup. Never mask the original error."""
    try:
        api_json(
            "DELETE",
            f"{app_path(package)}/edits/{parse.quote(edit_id, safe='')}",
            token,
            timeout=timeout,
        )
    except PlayError as exc:
        print(f"warning: could not delete Play edit {edit_id}: {exc}", file=sys.stderr)


def list_bundles(package: str, edit_id: str, token: str, timeout: int) -> list[int]:
    payload = api_json(
        "GET",
        f"{app_path(package)}/edits/{parse.quote(edit_id, safe='')}/bundles",
        token,
        timeout=timeout,
    )
    bundles = payload.get("bundles", [])
    if not isinstance(bundles, list):
        return []
    return [int(item["versionCode"]) for item in bundles if isinstance(item, dict) and "versionCode" in item]


def upload_bundle(
    package: str, edit_id: str, token: str, aab: Path, timeout: int
) -> dict[str, Any]:
    url = (
        f"{UPLOAD_ROOT}/{parse.quote(package, safe='')}/edits/"
        f"{parse.quote(edit_id, safe='')}/bundles?uploadType=media"
    )
    return api_json(
        "POST",
        url,
        token,
        raw=aab.read_bytes(),
        content_type="application/octet-stream",
        timeout=timeout,
    )


def track_body(
    track: str,
    version_code: str,
    *,
    status: str,
    version_name: str,
    release_notes: str | None,
) -> dict[str, Any]:
    release: dict[str, Any] = {
        "name": f"{version_name} ({version_code})",
        "versionCodes": [str(version_code)],
        "status": status,
    }
    if release_notes:
        release["releaseNotes"] = [{"language": "ja-JP", "text": release_notes}]
    return {"track": track, "releases": [release]}


def update_track(
    package: str,
    edit_id: str,
    token: str,
    body: dict[str, Any],
    timeout: int,
) -> dict[str, Any]:
    track = parse.quote(str(body["track"]), safe="")
    return api_json(
        "PUT",
        f"{app_path(package)}/edits/{parse.quote(edit_id, safe='')}/tracks/{track}",
        token,
        body=body,
        timeout=timeout,
    )


def commit_edit(package: str, edit_id: str, token: str, timeout: int) -> dict[str, Any]:
    return api_json(
        "POST",
        f"{app_path(package)}/edits/{parse.quote(edit_id, safe='')}:commit",
        token,
        body={},
        timeout=timeout,
    )


def validate_track(track: str) -> None:
    if track not in ALLOWED_TRACKS:
        raise PlayError(
            f"track '{track}' is not allowed by this workflow; allowed: {', '.join(ALLOWED_TRACKS)}"
        )


def validate_aab(path: Path) -> int:
    if not path.is_file():
        raise PlayError(f"AAB does not exist: {path}")
    size = path.stat().st_size
    if size <= 0:
        raise PlayError(f"AAB is empty: {path}")
    with path.open("rb") as handle:
        magic = handle.read(2)
    if magic != b"PK":
        raise PlayError(f"AAB is not a ZIP/JAR file: {path}")
    return size


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Upload an AAB to Google Play's internal testing track."
    )
    parser.add_argument("--service-account", required=True, type=Path, help="service-account JSON path")
    parser.add_argument("--package", required=True, help="applicationId (e.g. com.ryoki63.lien)")
    parser.add_argument("--aab", required=True, type=Path, help="signed AAB path")
    parser.add_argument("--track", default="internal", choices=ALLOWED_TRACKS)
    parser.add_argument("--status", default="completed", choices=ALLOWED_STATUSES)
    parser.add_argument("--version-name", default="Lien Android", help="release name shown in Play")
    parser.add_argument("--release-notes", default=None, help="ja-JP release notes")
    parser.add_argument("--expected-version-code", type=int, default=None)
    parser.add_argument("--dry-run", action="store_true", help="authenticate and list bundles; no upload")
    parser.add_argument("--timeout", type=int, default=180, help="HTTP timeout seconds")
    return parser.parse_args(argv)


def run(args: argparse.Namespace) -> int:
    validate_track(args.track)
    if not args.package or "/" in args.package:
        raise PlayError("--package must be a non-empty applicationId")
    size = validate_aab(args.aab)
    service_account = load_service_account(args.service_account)
    token_uri = service_account.get("token_uri") or DEFAULT_TOKEN_URI
    assertion = build_assertion(service_account)
    token = access_token(assertion, token_uri)

    edit = create_edit(args.package, token, args.timeout)
    edit_id = edit.get("id")
    if not isinstance(edit_id, str) or not edit_id:
        raise PlayError("Play API did not return an edit id")

    try:
        if args.dry_run:
            versions = list_bundles(args.package, edit_id, token, args.timeout)
            print(
                json.dumps(
                    {
                        "dryRun": True,
                        "package": args.package,
                        "track": args.track,
                        "existingVersionCodes": versions,
                        "aabBytes": size,
                    },
                    ensure_ascii=False,
                )
            )
            # A dry run must not leave an open edit behind.
            delete_edit(args.package, edit_id, token, args.timeout)
            return 0

        bundle = upload_bundle(args.package, edit_id, token, args.aab, args.timeout)
        if "versionCode" not in bundle:
            raise PlayError("Play API upload response did not contain versionCode")
        version_code = str(bundle["versionCode"])
        if args.expected_version_code is not None and version_code != str(args.expected_version_code):
            raise PlayError(
                f"uploaded versionCode {version_code} does not match expected {args.expected_version_code}"
            )

        body = track_body(
            args.track,
            version_code,
            status=args.status,
            version_name=args.version_name,
            release_notes=args.release_notes,
        )
        update_track(args.package, edit_id, token, body, args.timeout)
        commit_edit(args.package, edit_id, token, args.timeout)

        print(
            json.dumps(
                {
                    "package": args.package,
                    "track": args.track,
                    "status": args.status,
                    "versionCode": version_code,
                    "aabBytes": size,
                    "editId": edit_id,
                },
                ensure_ascii=False,
            )
        )
        return 0
    except Exception:
        # Do not leave a dangling edit with an uploaded bundle. If the commit
        # already succeeded, deleting the edit returns 404 and is harmless.
        delete_edit(args.package, edit_id, token, args.timeout)
        raise


def main(argv: list[str] | None = None) -> int:
    try:
        return run(parse_args(argv))
    except PlayError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("error: interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
