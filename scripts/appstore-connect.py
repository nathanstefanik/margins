import argparse
import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path


API_HOST = "api.appstoreconnect.apple.com"
BUNDLE_ID = "io.github.nathanstefanik.margins"
PLATFORMS = {"IOS", "MAC_OS"}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("Unexpected API redirect; refusing to forward credentials")


OPENER = urllib.request.build_opener(NoRedirect)


class AppStoreError(Exception):
    def __init__(self, status, response):
        self.status = status
        self.response = response
        codes = ", ".join(item.get("code", "UNKNOWN") for item in response.get("errors", []))
        super().__init__(f"App Store Connect returned HTTP {status}: {codes}")

    def has_code(self, code):
        return any(item.get("code") == code for item in self.response.get("errors", []))


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", value):
        raise ValueError("Expected an App Store Connect resource ID")
    return value


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def raw_signature(der):
    if len(der) < 8 or der[0] != 0x30 or der[1] != len(der) - 2:
        raise ValueError("Unexpected ES256 signature encoding")
    offset = 2
    parts = []
    for _ in range(2):
        if offset + 2 > len(der) or der[offset] != 0x02:
            raise ValueError("Unexpected ES256 signature integer")
        length = der[offset + 1]
        offset += 2
        if not 1 <= length <= 33 or offset + length > len(der):
            raise ValueError("Unexpected ES256 signature length")
        if der[offset] & 0x80 or (length == 33 and der[offset] != 0):
            raise ValueError("Unexpected ES256 signature value")
        parts.append(int.from_bytes(der[offset:offset + length], "big").to_bytes(32, "big"))
        offset += length
    if offset != len(der):
        raise ValueError("Unexpected ES256 signature trailing bytes")
    return b"".join(parts)


def token():
    key_id = identifier(os.environ["KEY_ID"])
    issuer_id = os.environ["ISSUER_ID"]
    key_dir = Path(os.environ.get("API_PRIVATE_KEYS_DIR", Path.home() / ".appstoreconnect/private_keys"))
    key_path = key_dir / f"AuthKey_{key_id}.p8"
    now = int(time.time())
    header = b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    payload = b64(json.dumps({
        "iss": issuer_id, "iat": now - 30, "exp": now + 600, "aud": "appstoreconnect-v1",
    }).encode())
    message = f"{header}.{payload}"
    result = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", str(key_path)],
        input=message.encode(), capture_output=True, check=True,
    )
    return f"{message}.{b64(raw_signature(result.stdout))}"


def request(path, parameters=None, method="GET", body=None):
    if not path.startswith("/v1/") or "?" in path or "#" in path:
        raise ValueError("Unexpected App Store Connect API path")
    url = f"https://{API_HOST}{path}"
    if parameters:
        url += "?" + urllib.parse.urlencode(parameters)
    req = urllib.request.Request(
        url, data=None if body is None else json.dumps(body).encode(), method=method,
        headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"},
    )
    try:
        with OPENER.open(req, timeout=60) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            response = json.loads(raw)
        except ValueError:
            response = {"errors": [{"code": "NON_JSON_RESPONSE"}]}
        raise AppStoreError(error.code, response) from None


def paginated(path, parameters):
    rows = []
    included = {}
    seen = set()
    while True:
        page = (path, tuple(sorted(parameters.items())))
        if page in seen:
            raise ValueError("Repeated App Store Connect pagination link")
        seen.add(page)
        result = request(path, parameters)
        rows.extend(result["data"])
        for item in result.get("included", []):
            included[(item["type"], item["id"])] = item
        next_url = result.get("links", {}).get("next")
        if not next_url:
            return rows, list(included.values())
        parsed = urllib.parse.urlparse(next_url)
        if parsed.scheme != "https" or parsed.netloc != API_HOST or parsed.fragment:
            raise ValueError("Unexpected App Store Connect pagination host")
        path = parsed.path
        parameters = dict(urllib.parse.parse_qsl(parsed.query))


def fresh_output(path):
    path = Path(path)
    if path.exists() or path.is_symlink() or not path.parent.is_dir():
        raise ValueError("Evidence output must be a new file in an existing directory")
    return path


def save_json(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(value, stream, indent=2, ensure_ascii=False)
        stream.write("\n")


def groups_for_app(app_id):
    groups, _ = paginated(
        f"/v1/apps/{identifier(app_id)}/betaGroups",
        {"fields[betaGroups]": "name,isInternalGroup,publicLinkEnabled,hasAccessToAllBuilds", "limit": "200"},
    )
    for group in groups:
        if group["type"] != "betaGroups" or type(group["attributes"]["isInternalGroup"]) is not bool:
            raise ValueError("Unexpected beta group response")
        identifier(group["id"])
    return groups


def snapshot(destination, bundle_id=BUNDLE_ID):
    destination = fresh_output(destination)
    apps, _ = paginated(
        "/v1/apps",
        {"filter[bundleId]": bundle_id, "fields[apps]": "name,bundleId", "limit": "2"},
    )
    if len(apps) != 1 or apps[0]["type"] != "apps" or apps[0]["attributes"]["bundleId"] != bundle_id:
        raise ValueError("Expected exactly one matching App Store Connect app")
    app = apps[0]
    builds, versions = paginated(
        "/v1/builds",
        {
            "filter[app]": identifier(app["id"]), "sort": "-uploadedDate",
            "include": "preReleaseVersion",
            "fields[builds]": "version,uploadedDate,processingState,expired,preReleaseVersion",
            "fields[preReleaseVersions]": "platform,version", "limit": "200",
        },
    )
    save_json(destination, {
        "capturedAt": datetime.now(timezone.utc).isoformat(), "app": app, "builds": builds,
        "preReleaseVersions": versions, "betaGroups": groups_for_app(app["id"]),
    })
    print(f"Saved release snapshot to {destination}")


def inspect_build(build_id):
    return request(
        f"/v1/builds/{identifier(build_id)}",
        {
            "include": "app,preReleaseVersion,buildBetaDetail,betaGroups,betaBuildLocalizations,betaAppReviewSubmission",
            "fields[builds]": "version,processingState,expired,app,preReleaseVersion,buildBetaDetail,betaGroups,betaBuildLocalizations,betaAppReviewSubmission",
            "fields[apps]": "bundleId", "fields[preReleaseVersions]": "version,platform",
            "fields[buildBetaDetails]": "internalBuildState,externalBuildState,autoNotifyEnabled",
            "fields[betaGroups]": "name,isInternalGroup",
            "fields[betaBuildLocalizations]": "locale,whatsNew",
            "fields[betaAppReviewSubmissions]": "betaReviewState,submittedDate",
        },
    )


def related(document, name, resource_type):
    relationship = document["data"]["relationships"][name]
    data = relationship["data"]
    refs = data if isinstance(data, list) else ([] if data is None else [data])
    total = relationship.get("meta", {}).get("paging", {}).get("total", len(refs))
    if total > len(refs):
        raise ValueError(f"Incomplete {name} relationship; verify full membership before distributing")
    included = {(item["type"], item["id"]): item for item in document.get("included", [])}
    result = []
    for ref in refs:
        identifier(ref["id"])
        if ref["type"] != resource_type or (resource_type, ref["id"]) not in included:
            raise ValueError(f"Missing included {name} resource")
        result.append(included[(resource_type, ref["id"])])
    return result


def single_related(document, name, resource_type):
    rows = related(document, name, resource_type)
    if len(rows) != 1:
        raise ValueError(f"Expected one {name} resource")
    return rows[0]


def validate_build(document, manifest, platform):
    build = document["data"]
    app = single_related(document, "app", "apps")
    version = single_related(document, "preReleaseVersion", "preReleaseVersions")
    if (
        build["type"] != "builds" or build["id"] != manifest["builds"][platform]
        or app["id"] != manifest["appID"] or app["attributes"]["bundleId"] != manifest["bundleID"]
        or version["attributes"]["version"] != manifest["version"]
        or version["attributes"]["platform"] != platform
        or build["attributes"]["version"] != manifest["buildNumber"]
        or build["attributes"]["processingState"] != "VALID"
        or build["attributes"]["expired"] is not False
    ):
        raise ValueError(f"Refusing to distribute unexpected or unavailable {platform} build")
    detail = single_related(document, "buildBetaDetail", "buildBetaDetails")["attributes"]
    if type(detail["autoNotifyEnabled"]) is not bool or any(
        not isinstance(detail[field], str) or not detail[field]
        for field in ("internalBuildState", "externalBuildState")
    ):
        raise ValueError("Expected notification and testing state fields")
    related(document, "betaGroups", "betaGroups")
    for item in related(document, "betaBuildLocalizations", "betaBuildLocalizations"):
        if not isinstance(item["attributes"]["locale"], str):
            raise ValueError("Expected localization locale")
    for item in related(document, "betaAppReviewSubmission", "betaAppReviewSubmissions"):
        if not isinstance(item["attributes"]["betaReviewState"], str):
            raise ValueError("Expected beta review state")


def load_manifest(path):
    manifest = json.loads(Path(path).read_text())
    allowed = {
        "appID", "bundleID", "version", "buildNumber", "builds", "notes",
        "outputDirectory", "submitExternalReview",
    }
    if not isinstance(manifest, dict) or set(manifest) - allowed:
        raise ValueError("Unexpected distribution manifest fields")
    identifier(manifest["appID"])
    if manifest["bundleID"] != BUNDLE_ID or not isinstance(manifest["version"], str) or not manifest["version"]:
        raise ValueError("Expected the Margins bundle ID and a marketing version")
    if not isinstance(manifest["buildNumber"], str) or not re.fullmatch(r"[1-9][0-9]*", manifest["buildNumber"]):
        raise ValueError("Expected a positive integer build number string")
    builds = manifest["builds"]
    if not isinstance(builds, dict) or not builds or not set(builds).issubset(PLATFORMS):
        raise ValueError("Expected IOS and/or MAC_OS build IDs")
    if len(set(builds.values())) != len(builds):
        raise ValueError("Each platform must have a different build ID")
    for platform, build_id in builds.items():
        identifier(build_id)
        notes = manifest["notes"][platform]
        if not isinstance(notes, str) or not notes.strip():
            raise ValueError(f"Expected release notes for {platform}")
    if type(manifest.get("submitExternalReview", False)) is not bool:
        raise ValueError("submitExternalReview must be a boolean")
    if not isinstance(manifest["outputDirectory"], str) or not Path(manifest["outputDirectory"]).is_dir():
        raise ValueError("Distribution evidence directory must already exist")
    return manifest


def distribute(manifest_path):
    manifest = load_manifest(manifest_path)
    groups = groups_for_app(manifest["appID"])
    if not groups:
        raise ValueError("No beta groups found; refusing an empty all-groups distribution")
    documents = {platform: inspect_build(build_id) for platform, build_id in manifest["builds"].items()}
    for platform, document in documents.items():
        validate_build(document, manifest, platform)
    output = Path(manifest["outputDirectory"]) / f"distribution-{uuid.uuid4().hex}"
    output.mkdir(mode=0o700)
    save_json(output / "manifest.json", manifest)
    save_json(output / "groups.json", groups)
    for platform, document in documents.items():
        save_json(output / f"{platform}-before.json", document)
    group_ids = {group["id"] for group in groups}
    external = any(not group["attributes"]["isInternalGroup"] for group in groups)
    blocked = []
    status = {}
    print(f"Distribution evidence: {output}")
    for platform, before in documents.items():
        build_id = manifest["builds"][platform]
        localizations = related(before, "betaBuildLocalizations", "betaBuildLocalizations")
        existing = next((item for item in localizations if item["attributes"]["locale"] == "en-US"), None)
        notes = manifest["notes"][platform]
        if existing:
            request(
                f"/v1/betaBuildLocalizations/{identifier(existing['id'])}", method="PATCH",
                body={"data": {"type": "betaBuildLocalizations", "id": existing["id"], "attributes": {"whatsNew": notes}}},
            )
        else:
            request(
                "/v1/betaBuildLocalizations", method="POST",
                body={"data": {
                    "type": "betaBuildLocalizations", "attributes": {"locale": "en-US", "whatsNew": notes},
                    "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
                }},
            )
        detail = single_related(before, "buildBetaDetail", "buildBetaDetails")
        if not detail["attributes"]["autoNotifyEnabled"]:
            request(
                f"/v1/buildBetaDetails/{identifier(detail['id'])}", method="PATCH",
                body={"data": {"type": "buildBetaDetails", "id": detail["id"], "attributes": {"autoNotifyEnabled": True}}},
            )
        existing_ids = {item["id"] for item in related(before, "betaGroups", "betaGroups")}
        missing_ids = group_ids - existing_ids
        if missing_ids:
            request(
                f"/v1/builds/{build_id}/relationships/betaGroups", method="POST",
                body={"data": [{"type": "betaGroups", "id": group} for group in sorted(missing_ids)]},
            )
        reviews = related(before, "betaAppReviewSubmission", "betaAppReviewSubmissions")
        if external and manifest.get("submitExternalReview", False):
            if any(item["attributes"]["betaReviewState"] == "REJECTED" for item in reviews):
                blocked.append(platform)
            elif not reviews:
                try:
                    submission = request(
                        "/v1/betaAppReviewSubmissions", method="POST",
                        body={"data": {
                            "type": "betaAppReviewSubmissions",
                            "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
                        }},
                    )
                    save_json(output / f"{platform}-review-submission.json", submission)
                except AppStoreError as error:
                    save_json(output / f"{platform}-review-error.json", error.response)
                    if error.status != 422 or not error.has_code("ENTITY_UNPROCESSABLE.ANOTHER_BUILD_IN_REVIEW"):
                        raise
                    blocked.append(platform)
        after = inspect_build(build_id)
        save_json(output / f"{platform}-after.json", after)
        validate_build(after, manifest, platform)
        assigned = {item["id"] for item in related(after, "betaGroups", "betaGroups")}
        detail = single_related(after, "buildBetaDetail", "buildBetaDetails")["attributes"]
        if not group_ids.issubset(assigned) or detail["autoNotifyEnabled"] is not True:
            raise ValueError(f"Could not verify all-group assignment and notifications for {platform}")
        reviews = related(after, "betaAppReviewSubmission", "betaAppReviewSubmissions")
        if external and manifest.get("submitExternalReview", False) and platform not in blocked:
            if any(item["attributes"]["betaReviewState"] == "REJECTED" for item in reviews):
                blocked.append(platform)
        if external and manifest.get("submitExternalReview", False) and platform not in blocked:
            if not reviews and detail["externalBuildState"] not in {
                "WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW", "READY_FOR_BETA_TESTING", "IN_BETA_TESTING",
            }:
                raise ValueError(f"Could not verify external beta submission for {platform}")
        status[platform] = {
            "internalBuildState": detail["internalBuildState"],
            "externalBuildState": detail["externalBuildState"],
            "betaReviewStates": [item["attributes"]["betaReviewState"] for item in reviews],
            "allGroupsAssigned": True,
            "reviewBlocked": platform in blocked,
        }
        print(platform, json.dumps(status[platform]))
    save_json(output / "status.json", status)
    return 2 if blocked else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="Inspect and distribute Margins TestFlight builds without expiring any build.")
    commands = parser.add_subparsers(dest="command", required=True)
    capture = commands.add_parser("snapshot", help="Read current builds and all test groups into a private receipt")
    capture.add_argument("output")
    capture.add_argument("--bundle-id", default=BUNDLE_ID)
    inspect = commands.add_parser("inspect", help="Read one build's processing, testing, review, and group state")
    inspect.add_argument("build_id")
    inspect.add_argument("output")
    distribution = commands.add_parser("distribute", help="Assign selected builds to every current test group")
    distribution.add_argument("manifest")
    distribution.add_argument("--confirm", action="store_true", help="Confirm authorized release-note, notification, group, and optional beta-review changes")
    args = parser.parse_args(argv)
    if args.command == "distribute" and not args.confirm:
        parser.error("distribute requires --confirm and explicit user authorization")
    if args.command == "snapshot":
        snapshot(args.output, args.bundle_id)
    elif args.command == "inspect":
        destination = fresh_output(args.output)
        save_json(destination, inspect_build(args.build_id))
        print(f"Saved build inspection to {destination}")
    else:
        return distribute(args.manifest)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (AppStoreError, ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
