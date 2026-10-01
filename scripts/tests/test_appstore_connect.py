import base64
import io
import importlib.util
import json
import stat
import subprocess
import tempfile
import unittest
import urllib.error
import urllib.parse
from pathlib import Path
from unittest import mock

ASC_PATH = Path(__file__).resolve().parents[1] / "appstore-connect.py"
spec = importlib.util.spec_from_file_location("appstore_connect", ASC_PATH)
asc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(asc)

APP_ID = "APPSYNTH01"
BUILD_IOS = "BIOS00001"
BUILD_MAC = "BMAC00001"
VERSION = "1.2.3"
BUILD_NUMBER = "42"
GROUP_INTERNAL = "GRPINT001"
GROUP_EXTERNAL = "GRPEXT001"


def group(group_id, internal):
    return {
        "type": "betaGroups",
        "id": group_id,
        "attributes": {
            "name": "Testers " + group_id,
            "isInternalGroup": internal,
            "publicLinkEnabled": False,
            "hasAccessToAllBuilds": False,
        },
    }


def build_document(
    build_id,
    *,
    platform="IOS",
    app_id=APP_ID,
    bundle_id=asc.BUNDLE_ID,
    version=VERSION,
    version_platform=None,
    build_number=BUILD_NUMBER,
    processing_state="VALID",
    expired=False,
    internal_state="READY_FOR_BETA_TESTING",
    external_state="READY_FOR_BETA_TESTING",
    auto_notify=True,
    group_ids=(),
    localization=None,
    review_state=None,
):
    detail_id = "DETAIL-" + platform
    version_id = "PREV-" + platform
    included = [
        {"type": "apps", "id": app_id, "attributes": {"bundleId": bundle_id}},
        {
            "type": "preReleaseVersions",
            "id": version_id,
            "attributes": {"version": version, "platform": version_platform or platform},
        },
        {
            "type": "buildBetaDetails",
            "id": detail_id,
            "attributes": {
                "internalBuildState": internal_state,
                "externalBuildState": external_state,
                "autoNotifyEnabled": auto_notify,
            },
        },
    ]
    for group_id in group_ids:
        included.append(group(group_id, internal=True))
    localization_refs = []
    if localization is not None:
        included.append(
            {
                "type": "betaBuildLocalizations",
                "id": localization["id"],
                "attributes": {
                    "locale": localization["locale"],
                    "whatsNew": localization.get("whatsNew", ""),
                },
            }
        )
        localization_refs.append(
            {"type": "betaBuildLocalizations", "id": localization["id"]}
        )
    review_data = None
    if review_state is not None:
        included.append(
            {
                "type": "betaAppReviewSubmissions",
                "id": "REV-" + platform,
                "attributes": {"betaReviewState": review_state},
            }
        )
        review_data = {"type": "betaAppReviewSubmissions", "id": "REV-" + platform}
    group_refs = [{"type": "betaGroups", "id": group_id} for group_id in group_ids]
    return {
        "data": {
            "type": "builds",
            "id": build_id,
            "attributes": {
                "version": build_number,
                "processingState": processing_state,
                "expired": expired,
            },
            "relationships": {
                "app": {"data": {"type": "apps", "id": app_id}},
                "preReleaseVersion": {
                    "data": {"type": "preReleaseVersions", "id": version_id}
                },
                "buildBetaDetail": {
                    "data": {"type": "buildBetaDetails", "id": detail_id}
                },
                "betaGroups": {
                    "data": group_refs,
                    "meta": {"paging": {"total": len(group_refs)}},
                },
                "betaBuildLocalizations": {"data": localization_refs},
                "betaAppReviewSubmission": {"data": review_data},
            },
        },
        "included": included,
    }


def manifest_dict(output_directory, **overrides):
    manifest = {
        "appID": APP_ID,
        "bundleID": asc.BUNDLE_ID,
        "version": VERSION,
        "buildNumber": BUILD_NUMBER,
        "builds": {"IOS": BUILD_IOS, "MAC_OS": BUILD_MAC},
        "notes": {"IOS": "ios notes", "MAC_OS": "mac notes"},
        "outputDirectory": output_directory,
    }
    manifest.update(overrides)
    return manifest


def write_manifest(directory, **overrides):
    path = Path(directory) / "manifest.json"
    path.write_text(json.dumps(manifest_dict(directory, **overrides)))
    return path


class CallLog:
    def __init__(self, responder=None):
        self.calls = []
        self.responder = responder or (lambda path, parameters, method, body: {})

    def __call__(self, path, parameters=None, method="GET", body=None):
        self.calls.append({"method": method, "path": path, "parameters": parameters, "body": body})
        return self.responder(path, parameters, method, body)

    def writes(self):
        return [call for call in self.calls if call["method"] != "GET"]

    def posts_to(self, needle):
        return [
            call for call in self.calls
            if call["method"] == "POST" and needle in call["path"]
        ]

    def patches_to(self, needle):
        return [
            call for call in self.calls
            if call["method"] == "PATCH" and needle in call["path"]
        ]

    def assert_no_expiry_or_delete(self, test):
        for call in self.calls:
            test.assertNotEqual(call["method"], "DELETE")
            if call["method"] == "PATCH":
                test.assertFalse(call["path"].startswith("/v1/builds/"))


class QueuedInspector:
    def __init__(self, documents):
        self.documents = {key: list(value) for key, value in documents.items()}
        self.calls = []

    def __call__(self, build_id):
        self.calls.append(build_id)
        return self.documents[build_id].pop(0)


class SnapshotTests(unittest.TestCase):
    def test_snapshot_queries_app_builds_and_groups(self):
        app = {
            "type": "apps",
            "id": APP_ID,
            "attributes": {"name": "Fixture App", "bundleId": asc.BUNDLE_ID},
        }
        builds = [
            {
                "type": "builds",
                "id": BUILD_IOS,
                "attributes": {
                    "version": BUILD_NUMBER,
                    "uploadedDate": "2025-01-01T00:00:00Z",
                    "processingState": "VALID",
                    "expired": False,
                },
            }
        ]
        versions = [
            {
                "type": "preReleaseVersions",
                "id": "PREV1",
                "attributes": {"platform": "IOS", "version": VERSION},
            }
        ]

        def responder(path, parameters, method, body):
            if path == "/v1/apps":
                return {"data": [app]}
            if path == "/v1/builds":
                return {"data": builds, "included": versions}
            if path == f"/v1/apps/{APP_ID}/betaGroups":
                return {"data": [group(GROUP_INTERNAL, True)]}
            raise AssertionError(f"unexpected request {path}")

        log = CallLog(responder)
        with tempfile.TemporaryDirectory() as tmp:
            destination = Path(tmp) / "snapshot.json"
            with mock.patch.object(asc, "request", log):
                asc.snapshot(str(destination))
            receipt = json.loads(destination.read_text())

        self.assertEqual(receipt["app"]["id"], APP_ID)
        self.assertEqual(len(receipt["builds"]), 1)
        self.assertEqual(len(receipt["betaGroups"]), 1)

        apps_call = next(c for c in log.calls if c["path"] == "/v1/apps")
        self.assertEqual(apps_call["method"], "GET")
        self.assertEqual(apps_call["parameters"]["filter[bundleId]"], asc.BUNDLE_ID)

        builds_call = next(c for c in log.calls if c["path"] == "/v1/builds")
        self.assertEqual(builds_call["method"], "GET")
        self.assertEqual(builds_call["parameters"]["filter[app]"], APP_ID)
        self.assertEqual(builds_call["parameters"]["include"], "preReleaseVersion")

        groups_call = next(
            c for c in log.calls if c["path"] == f"/v1/apps/{APP_ID}/betaGroups"
        )
        self.assertEqual(groups_call["method"], "GET")
        self.assertEqual(log.writes(), [])

    def test_paginated_collects_pages_and_dedupes_included(self):
        pages = {
            "/v1/things": {
                "data": [{"type": "things", "id": "T1"}],
                "included": [
                    {"type": "extras", "id": "E1"},
                    {"type": "extras", "id": "E2"},
                ],
                "links": {
                    "next": "https://api.appstoreconnect.apple.com/v1/things?cursor=c2"
                },
            },
        }
        seen_queries = []

        def responder(path, parameters, method, body):
            seen_queries.append((path, dict(parameters)))
            if parameters.get("cursor") == "c2":
                return {
                    "data": [{"type": "things", "id": "T2"}],
                    "included": [
                        {"type": "extras", "id": "E1"},
                        {"type": "extras", "id": "E3"},
                    ],
                }
            return pages[path]

        log = CallLog(responder)
        with mock.patch.object(asc, "request", log):
            rows, included = asc.paginated("/v1/things", {"limit": "1"})
        self.assertEqual([row["id"] for row in rows], ["T1", "T2"])
        self.assertEqual(
            sorted(item["id"] for item in included), ["E1", "E2", "E3"]
        )
        self.assertEqual(len(seen_queries), 2)

    def test_paginated_rejects_foreign_host_next_link(self):
        def responder(path, parameters, method, body):
            return {
                "data": [],
                "links": {"next": "https://example.invalid/v1/things?cursor=x"},
            }

        with mock.patch.object(asc, "request", CallLog(responder)):
            with self.assertRaises(ValueError):
                asc.paginated("/v1/things", {"limit": "1"})

    def test_paginated_rejects_repeated_next_link(self):
        def responder(path, parameters, method, body):
            return {
                "data": [],
                "links": {
                    "next": "https://api.appstoreconnect.apple.com/v1/things?limit=1"
                },
            }

        with mock.patch.object(asc, "request", CallLog(responder)):
            with self.assertRaises(ValueError):
                asc.paginated("/v1/things", {"limit": "1"})


class CliGateTests(unittest.TestCase):
    def test_distribute_without_confirm_exits_before_requests(self):
        log = CallLog()
        with tempfile.TemporaryDirectory() as tmp:
            manifest = write_manifest(tmp)
            with mock.patch.object(asc, "request", log):
                with mock.patch.object(asc, "inspect_build", CallLog()) as inspector:
                    with self.assertRaises(SystemExit) as caught:
                        asc.main(["distribute", str(manifest)])
        self.assertEqual(caught.exception.code, 2)
        self.assertEqual(log.calls, [])
        self.assertEqual(inspector.calls, [])

    def test_snapshot_refuses_existing_output_before_network(self):
        log = CallLog()
        with tempfile.TemporaryDirectory() as tmp:
            existing = Path(tmp) / "receipt.json"
            existing.write_text("{}")
            with mock.patch.object(asc, "request", log):
                with self.assertRaises(ValueError):
                    asc.main(["snapshot", str(existing)])
        self.assertEqual(log.calls, [])

    def test_inspect_refuses_existing_output_before_network(self):
        log = CallLog()
        with tempfile.TemporaryDirectory() as tmp:
            existing = Path(tmp) / "inspect.json"
            existing.write_text("{}")
            with mock.patch.object(asc, "request", log):
                with self.assertRaises(ValueError):
                    asc.main(["inspect", BUILD_IOS, str(existing)])
        self.assertEqual(log.calls, [])

    def test_inspect_only_reads(self):
        log = CallLog(lambda p, q, m, b: {"data": {"type": "builds", "id": BUILD_IOS}})
        with tempfile.TemporaryDirectory() as tmp:
            destination = Path(tmp) / "inspect.json"
            with mock.patch.object(asc, "request", log):
                asc.main(["inspect", BUILD_IOS, str(destination)])
            self.assertTrue(json.loads(destination.read_text())["data"])
        self.assertEqual(len(log.calls), 1)
        self.assertEqual(log.calls[0]["method"], "GET")
        self.assertEqual(log.calls[0]["path"], f"/v1/builds/{BUILD_IOS}")

    def test_no_redirect_refuses_credential_forwarding(self):
        handler = asc.NoRedirect()
        with self.assertRaises(ValueError):
            handler.redirect_request(None, None, 302, "", {}, "https://example.invalid/")


class SignatureTests(unittest.TestCase):
    @staticmethod
    def der(r_bytes, s_bytes):
        body = b"\x02" + bytes([len(r_bytes)]) + r_bytes + b"\x02" + bytes([len(s_bytes)]) + s_bytes
        return b"\x30" + bytes([len(body)]) + body

    def test_der_to_raw_signature(self):
        r = bytes(range(1, 33))
        s = bytes(range(33, 65))
        raw = asc.raw_signature(self.der(r, s))
        self.assertEqual(raw, r + s)
        self.assertEqual(len(raw), 64)

    def test_der_leading_zero_and_short_integers(self):
        r = b"\x00" + bytes(range(1, 33))
        s = b"\x07"
        raw = asc.raw_signature(self.der(r, s))
        self.assertEqual(len(raw), 64)
        self.assertEqual(raw[:32], r[1:])
        self.assertEqual(raw[32:], (b"\x00" * 31) + s)

    def test_der_rejects_malformed(self):
        good_r = b"\x01" * 32
        good_s = b"\x02" * 32
        with self.assertRaises(ValueError):
            asc.raw_signature(self.der(good_r, good_s)[:-3])
        wrong_tag = b"\x31" + self.der(good_r, good_s)[1:]
        with self.assertRaises(ValueError):
            asc.raw_signature(wrong_tag)
        negative = self.der(b"\x80" + good_r[1:], good_s)
        with self.assertRaises(ValueError):
            asc.raw_signature(negative)
        oversized = self.der(b"\x01" * 34, good_s)
        with self.assertRaises(ValueError):
            asc.raw_signature(oversized)
        with self.assertRaises(ValueError):
            asc.raw_signature(self.der(good_r, good_s) + b"\x00")
        short_seq = self.der(good_r, good_s)
        truncated_declared = bytes([short_seq[0], short_seq[1] + 4]) + short_seq[2:]
        with self.assertRaises(ValueError):
            asc.raw_signature(truncated_declared)

    def test_token_signs_synthetic_jwt(self):
        der = self.der(b"\x11" * 32, b"\x22" * 32)
        run = mock.Mock(
            return_value=subprocess.CompletedProcess(
                args=[], returncode=0, stdout=der
            )
        )
        env = {
            "KEY_ID": "SYNTHKEY1",
            "ISSUER_ID": "synthetic-issuer",
            "API_PRIVATE_KEYS_DIR": "/nonexistent-keys",
        }
        with mock.patch.dict("os.environ", env):
            with mock.patch.object(asc.time, "time", return_value=1_700_000_000):
                with mock.patch.object(asc.subprocess, "run", run):
                    signed = asc.token()

        header_b64, payload_b64, signature_b64 = signed.split(".")
        pad = lambda value: value + "=" * (-len(value) % 4)
        header = json.loads(base64.urlsafe_b64decode(pad(header_b64)))
        payload = json.loads(base64.urlsafe_b64decode(pad(payload_b64)))
        signature = base64.urlsafe_b64decode(pad(signature_b64))

        self.assertEqual(header, {"alg": "ES256", "kid": "SYNTHKEY1", "typ": "JWT"})
        self.assertEqual(payload["iss"], "synthetic-issuer")
        self.assertEqual(payload["aud"], "appstoreconnect-v1")
        self.assertEqual(payload["iat"], 1_700_000_000 - 30)
        self.assertEqual(payload["exp"], 1_700_000_000 + 600)
        self.assertEqual(len(signature), 64)

        argv = run.call_args.args[0]
        self.assertEqual(argv[0], "openssl")
        self.assertIn("-sha256", argv)
        self.assertIn("-sign", argv)
        self.assertTrue(argv[-1].endswith("AuthKey_SYNTHKEY1.p8"))
        self.assertFalse(Path(argv[-1]).exists())


class ManifestTests(unittest.TestCase):
    def test_valid_manifest_loads(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = write_manifest(tmp)
            manifest = asc.load_manifest(path)
        self.assertEqual(manifest["buildNumber"], BUILD_NUMBER)

    def test_manifest_rejects_wrong_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = write_manifest(tmp, bundleID="com.example.wrong")
            with self.assertRaises(ValueError):
                asc.load_manifest(path)

    def test_manifest_rejects_bad_build_numbers(self):
        with tempfile.TemporaryDirectory() as tmp:
            for bad in (42, 0, "0", "-3", "x2", "", None):
                path = write_manifest(tmp, buildNumber=bad)
                with self.assertRaises((ValueError, KeyError, TypeError)):
                    asc.load_manifest(path)

    def test_manifest_rejects_duplicate_platform_build_ids(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = write_manifest(tmp, builds={"IOS": "SAMEID01", "MAC_OS": "SAMEID01"})
            with self.assertRaises(ValueError):
                asc.load_manifest(path)

    def test_manifest_rejects_unknown_platform(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = write_manifest(tmp, builds={"TVOS": "BTVOS001"})
            with self.assertRaises((ValueError, KeyError)):
                asc.load_manifest(path)

    def test_manifest_rejects_empty_notes(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = write_manifest(tmp, notes={"IOS": "   ", "MAC_OS": "ok"})
            with self.assertRaises(ValueError):
                asc.load_manifest(path)

    def test_manifest_rejects_nonboolean_review_flag(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = write_manifest(tmp, submitExternalReview="yes")
            with self.assertRaises(ValueError):
                asc.load_manifest(path)

    def test_manifest_rejects_missing_output_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "manifest.json"
            path.write_text(json.dumps(manifest_dict("/no/such/dir-42")))
            with self.assertRaises(ValueError):
                asc.load_manifest(path)

    def test_manifest_rejects_unexpected_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = write_manifest(tmp, groupIDs=[GROUP_EXTERNAL])
            with self.assertRaises(ValueError):
                asc.load_manifest(path)

    def test_manifest_supports_single_platform_and_review_default(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = write_manifest(
                tmp, builds={"IOS": BUILD_IOS}, notes={"IOS": "ios notes"}
            )
            manifest = asc.load_manifest(path)
        self.assertEqual(list(manifest["builds"]), ["IOS"])
        self.assertFalse(manifest.get("submitExternalReview", False))


class DistributePreflightTests(unittest.TestCase):
    def prepare(self, tmp, manifest_overrides=None, inspector_docs=None,
                groups=None, responder=None):
        manifest_path = write_manifest(tmp, **(manifest_overrides or {}))
        inspector = QueuedInspector(inspector_docs or {})
        log = CallLog(responder)
        default_groups = [group(GROUP_INTERNAL, True), group(GROUP_EXTERNAL, False)]

        def invoke():
            with mock.patch.object(
                asc, "groups_for_app",
                return_value=groups if groups is not None else default_groups,
            ):
                with mock.patch.object(asc, "inspect_build", inspector):
                    with mock.patch.object(asc, "request", log):
                        return asc.distribute(manifest_path)

        return invoke, log, inspector

    def test_invalid_second_build_makes_no_write_requests(self):
        corruptions = {
            "wrong app id": {"app_id": "APPWRONG9"},
            "wrong bundle id": {"bundle_id": "com.example.wrong"},
            "wrong marketing version": {"version": "9.9.9"},
            "wrong platform": {"version_platform": "IOS"},
            "wrong build number": {"build_number": "41"},
            "not valid": {"processing_state": "PROCESSING"},
            "expired": {"expired": True},
        }
        for name, kwargs in corruptions.items():
            with self.subTest(name):
                docs = {
                    BUILD_IOS: [build_document(BUILD_IOS, platform="IOS")],
                    BUILD_MAC: [
                        build_document(BUILD_MAC, platform="MAC_OS", **kwargs)
                    ],
                }
                with tempfile.TemporaryDirectory() as tmp:
                    invoke, log, inspector = self.prepare(tmp, inspector_docs=docs)
                    with self.assertRaises(ValueError):
                        invoke()
                    self.assertEqual(inspector.calls, [BUILD_IOS, BUILD_MAC])
                    self.assertEqual(log.writes(), [])
                    self.assertFalse(
                        any(
                            p.name.startswith("distribution-")
                            for p in Path(tmp).iterdir()
                        )
                    )

    def test_truncated_included_relationship_fails_before_writes(self):
        for target, build_id, platform in (
            ("first", BUILD_IOS, "IOS"), ("second", BUILD_MAC, "MAC_OS")
        ):
            for variant in ("paging_total", "missing_included"):
                with self.subTest(target=target, variant=variant):
                    docs = {
                        BUILD_IOS: [build_document(BUILD_IOS, platform="IOS",
                                                   group_ids=[GROUP_INTERNAL])],
                        BUILD_MAC: [build_document(BUILD_MAC, platform="MAC_OS",
                                                   group_ids=[GROUP_INTERNAL])],
                    }
                    doc = docs[build_id][0]
                    if variant == "paging_total":
                        doc["data"]["relationships"]["betaGroups"]["meta"]["paging"]["total"] = 2
                    else:
                        doc["included"] = [
                            item for item in doc["included"]
                            if not (item["type"] == "betaGroups"
                                    and item["id"] == GROUP_INTERNAL)
                        ]
                    with tempfile.TemporaryDirectory() as tmp:
                        invoke, log, inspector = self.prepare(
                            tmp, inspector_docs=docs
                        )
                        with self.assertRaises(ValueError):
                            invoke()
                        self.assertEqual(inspector.calls, [BUILD_IOS, BUILD_MAC])
                        self.assertEqual(log.writes(), [])
                        self.assertFalse(
                            any(
                                p.name.startswith("distribution-")
                                for p in Path(tmp).iterdir()
                            )
                        )

    def test_missing_notification_state_fields_fail_before_writes(self):
        for field in (
            "autoNotifyEnabled", "internalBuildState", "externalBuildState"
        ):
            with self.subTest(field=field):
                doc = build_document(BUILD_MAC, platform="MAC_OS")
                for item in doc["included"]:
                    if item["type"] == "buildBetaDetails":
                        del item["attributes"][field]
                docs = {
                    BUILD_IOS: [build_document(BUILD_IOS, platform="IOS")],
                    BUILD_MAC: [doc],
                }
                with tempfile.TemporaryDirectory() as tmp:
                    invoke, log, inspector = self.prepare(tmp, inspector_docs=docs)
                    with self.assertRaises((ValueError, KeyError)):
                        invoke()
                    self.assertEqual(inspector.calls, [BUILD_IOS, BUILD_MAC])
                    self.assertEqual(log.writes(), [])

    def test_empty_group_list_blocks_distribution_without_writes(self):
        docs = {
            BUILD_IOS: [build_document(BUILD_IOS, platform="IOS")],
            BUILD_MAC: [build_document(BUILD_MAC, platform="MAC_OS")],
        }
        with tempfile.TemporaryDirectory() as tmp:
            invoke, log, inspector = self.prepare(
                tmp, inspector_docs=docs, groups=[]
            )
            with self.assertRaises(ValueError):
                invoke()
            self.assertEqual(inspector.calls, [])
            self.assertEqual(log.calls, [])


class DistributeHappyPathTests(unittest.TestCase):
    def setUp(self):
        self.groups = [group(GROUP_INTERNAL, True), group(GROUP_EXTERNAL, False)]

    def distribute(self, tmp, docs, manifest_overrides=None, responder=None):
        manifest_path = write_manifest(tmp, **(manifest_overrides or {}))
        inspector = QueuedInspector(docs)
        log = CallLog(responder)
        with mock.patch.object(asc, "groups_for_app", return_value=self.groups):
            with mock.patch.object(asc, "inspect_build", inspector):
                with mock.patch.object(asc, "request", log):
                    outcome = asc.distribute(manifest_path)
        return outcome, log, inspector, manifest_path

    def test_happy_distribution_verifies_after_state(self):
        ios_before = build_document(
            BUILD_IOS, platform="IOS",
            group_ids=[GROUP_INTERNAL],
            localization={"id": "LOC-IOS", "locale": "en-US", "whatsNew": "old"},
            auto_notify=False,
        )
        mac_before = build_document(BUILD_MAC, platform="MAC_OS")
        ios_after = build_document(
            BUILD_IOS, platform="IOS",
            group_ids=[GROUP_INTERNAL, GROUP_EXTERNAL],
            localization={"id": "LOC-IOS", "locale": "en-US", "whatsNew": "ios notes"},
            review_state="WAITING_FOR_REVIEW",
        )
        mac_after = build_document(
            BUILD_MAC, platform="MAC_OS",
            group_ids=[GROUP_INTERNAL, GROUP_EXTERNAL],
            review_state="WAITING_FOR_REVIEW",
        )
        docs = {
            BUILD_IOS: [ios_before, ios_after],
            BUILD_MAC: [mac_before, mac_after],
        }
        with tempfile.TemporaryDirectory() as tmp:
            outcome, log, inspector, manifest_path = self.distribute(
                tmp, docs, manifest_overrides={"submitExternalReview": True}
            )
            self.assertEqual(outcome, 0)
            evidence_dirs = [
                p for p in Path(tmp).iterdir()
                if p.is_dir() and p.name.startswith("distribution-")
            ]
            self.assertEqual(len(evidence_dirs), 1)
            evidence = evidence_dirs[0]
            for name in (
                "manifest.json", "groups.json", "status.json",
                "IOS-before.json", "IOS-after.json",
                "MAC_OS-before.json", "MAC_OS-after.json",
                "IOS-review-submission.json",
            ):
                self.assertTrue((evidence / name).is_file(), name)
            status = json.loads((evidence / "status.json").read_text())
            self.assertTrue(status["IOS"]["allGroupsAssigned"])
            self.assertFalse(status["IOS"]["reviewBlocked"])
            self.assertEqual(
                status["IOS"]["betaReviewStates"], ["WAITING_FOR_REVIEW"]
            )
            self.assertEqual(
                status["MAC_OS"]["betaReviewStates"], ["WAITING_FOR_REVIEW"]
            )

        self.assertEqual(inspector.documents[BUILD_IOS], [])
        self.assertEqual(inspector.documents[BUILD_MAC], [])

        notes_patch = log.patches_to("/v1/betaBuildLocalizations/LOC-IOS")
        self.assertEqual(len(notes_patch), 1)
        self.assertEqual(
            notes_patch[0]["body"]["data"]["attributes"]["whatsNew"], "ios notes"
        )
        notes_post = log.posts_to("/v1/betaBuildLocalizations")
        self.assertEqual(len(notes_post), 1)
        self.assertEqual(
            notes_post[0]["body"]["data"]["relationships"]["build"]["data"]["id"],
            BUILD_MAC,
        )
        detail_patch = log.patches_to("/v1/buildBetaDetails/DETAIL-IOS")
        self.assertEqual(len(detail_patch), 1)
        self.assertTrue(
            detail_patch[0]["body"]["data"]["attributes"]["autoNotifyEnabled"]
        )
        self.assertEqual(log.patches_to("/v1/buildBetaDetails/DETAIL-MAC_OS"), [])

        ios_groups = log.posts_to(f"/v1/builds/{BUILD_IOS}/relationships/betaGroups")
        self.assertEqual(len(ios_groups), 1)
        self.assertEqual(
            [item["id"] for item in ios_groups[0]["body"]["data"]],
            [GROUP_EXTERNAL],
        )
        mac_groups = log.posts_to(f"/v1/builds/{BUILD_MAC}/relationships/betaGroups")
        self.assertEqual(len(mac_groups), 1)
        self.assertEqual(
            [item["id"] for item in mac_groups[0]["body"]["data"]],
            sorted([GROUP_EXTERNAL, GROUP_INTERNAL]),
        )

        reviews = log.posts_to("/v1/betaAppReviewSubmissions")
        self.assertEqual(len(reviews), 2)
        for call, build_id in zip(reviews, [BUILD_IOS, BUILD_MAC]):
            self.assertEqual(
                call["body"],
                {
                    "data": {
                        "type": "betaAppReviewSubmissions",
                        "relationships": {
                            "build": {"data": {"type": "builds", "id": build_id}}
                        },
                    }
                },
            )
        log.assert_no_expiry_or_delete(self)

    def test_no_review_post_without_external_flag_or_groups(self):
        for overrides, groups in (
            ({}, None),
            ({"submitExternalReview": False}, None),
            ({"submitExternalReview": True}, [group(GROUP_INTERNAL, True)]),
        ):
            label = json.dumps(overrides) + str(groups is not None)
            with self.subTest(label):
                with tempfile.TemporaryDirectory() as tmp:
                    active = groups if groups is not None else self.groups
                    ios_before = build_document(BUILD_IOS, platform="IOS")
                    ios_after = build_document(
                        BUILD_IOS, platform="IOS",
                        group_ids=[item["id"] for item in active],
                    )
                    docs = {BUILD_IOS: [ios_before, ios_after]}
                    manifest_path = write_manifest(
                        tmp, builds={"IOS": BUILD_IOS}, notes={"IOS": "ios notes"},
                        **overrides,
                    )
                    inspector = QueuedInspector(docs)
                    log = CallLog()
                    with mock.patch.object(asc, "groups_for_app", return_value=active):
                        with mock.patch.object(asc, "inspect_build", inspector):
                            with mock.patch.object(asc, "request", log):
                                outcome = asc.distribute(manifest_path)
                    self.assertEqual(outcome, 0)
                    self.assertEqual(log.posts_to("/v1/betaAppReviewSubmissions"), [])

    def test_missing_review_after_state_fails_verification(self):
        with tempfile.TemporaryDirectory() as tmp:
            ios_before = build_document(BUILD_IOS, platform="IOS")
            ios_after = build_document(
                BUILD_IOS, platform="IOS",
                group_ids=[GROUP_INTERNAL, GROUP_EXTERNAL],
                external_state="PROCESSING",
            )
            docs = {BUILD_IOS: [ios_before, ios_after]}
            manifest_path = write_manifest(
                tmp, builds={"IOS": BUILD_IOS}, notes={"IOS": "ios notes"},
                submitExternalReview=True,
            )
            inspector = QueuedInspector(docs)
            log = CallLog()
            with mock.patch.object(asc, "groups_for_app", return_value=self.groups):
                with mock.patch.object(asc, "inspect_build", inspector):
                    with mock.patch.object(asc, "request", log):
                        with self.assertRaises(ValueError):
                            asc.distribute(manifest_path)

    def test_incomplete_after_state_fails_verification(self):
        with tempfile.TemporaryDirectory() as tmp:
            for after_groups, after_notify in (
                ([GROUP_INTERNAL], True),
                ([GROUP_INTERNAL, GROUP_EXTERNAL], False),
            ):
                with self.subTest(after_groups=after_groups, notify=after_notify):
                    ios_before = build_document(BUILD_IOS, platform="IOS")
                    ios_after = build_document(
                        BUILD_IOS, platform="IOS",
                        group_ids=after_groups, auto_notify=after_notify,
                    )
                    docs = {BUILD_IOS: [ios_before, ios_after]}
                    manifest_path = write_manifest(
                        tmp, builds={"IOS": BUILD_IOS},
                        notes={"IOS": "ios notes"},
                    )
                    inspector = QueuedInspector(docs)
                    with mock.patch.object(asc, "groups_for_app", return_value=self.groups):
                        with mock.patch.object(asc, "inspect_build", inspector):
                            with mock.patch.object(asc, "request", CallLog()):
                                with self.assertRaises(ValueError):
                                    asc.distribute(manifest_path)


class DistributeReviewErrorTests(unittest.TestCase):
    def setUp(self):
        self.groups = [group(GROUP_INTERNAL, True), group(GROUP_EXTERNAL, False)]

    def docs(self, ios_review=None, mac_review=None):
        return {
            BUILD_IOS: [
                build_document(BUILD_IOS, platform="IOS", review_state=ios_review),
                build_document(
                    BUILD_IOS, platform="IOS",
                    group_ids=[GROUP_INTERNAL, GROUP_EXTERNAL],
                    review_state=ios_review or "WAITING_FOR_REVIEW",
                ),
            ],
            BUILD_MAC: [
                build_document(BUILD_MAC, platform="MAC_OS", review_state=mac_review),
                build_document(
                    BUILD_MAC, platform="MAC_OS",
                    group_ids=[GROUP_INTERNAL, GROUP_EXTERNAL],
                    review_state=mac_review or "WAITING_FOR_REVIEW",
                ),
            ],
        }

    def run_distribution(self, tmp, docs, responder=None):
        manifest_path = write_manifest(tmp, submitExternalReview=True)
        inspector = QueuedInspector(docs)
        log = CallLog(responder)
        with mock.patch.object(asc, "groups_for_app", return_value=self.groups):
            with mock.patch.object(asc, "inspect_build", inspector):
                with mock.patch.object(asc, "request", log):
                    return asc.distribute(manifest_path), log, inspector

    def test_another_build_in_review_blocks_platform_and_continues(self):
        def responder(path, parameters, method, body):
            if path == "/v1/betaAppReviewSubmissions" and method == "POST":
                if body["data"]["relationships"]["build"]["data"]["id"] == BUILD_IOS:
                    raise asc.AppStoreError(
                        422,
                        {"errors": [
                            {"code": "ENTITY_UNPROCESSABLE.ANOTHER_BUILD_IN_REVIEW"}
                        ]},
                    )
                return {"data": {"type": "betaAppReviewSubmissions", "id": "NEWREV"}}
            return {}

        with tempfile.TemporaryDirectory() as tmp:
            docs = self.docs()
            outcome, log, inspector = self.run_distribution(tmp, docs, responder)
            self.assertEqual(outcome, 2)
            evidence = next(
                p for p in Path(tmp).iterdir()
                if p.is_dir() and p.name.startswith("distribution-")
            )
            self.assertTrue((evidence / "IOS-review-error.json").is_file())
            self.assertTrue((evidence / "MAC_OS-review-submission.json").is_file())
            self.assertEqual(len(log.posts_to("/v1/betaAppReviewSubmissions")), 2)
            status = json.loads((evidence / "status.json").read_text())
            self.assertTrue(status["IOS"]["reviewBlocked"])
            self.assertFalse(status["MAC_OS"]["reviewBlocked"])
            log.assert_no_expiry_or_delete(self)

    def test_preexisting_rejected_review_blocks(self):
        with tempfile.TemporaryDirectory() as tmp:
            docs = self.docs(ios_review="REJECTED")
            outcome, log, inspector = self.run_distribution(tmp, docs)
            self.assertEqual(outcome, 2)
            evidence = next(
                p for p in Path(tmp).iterdir()
                if p.is_dir() and p.name.startswith("distribution-")
            )
            self.assertFalse((evidence / "IOS-review-submission.json").exists())
            status = json.loads((evidence / "status.json").read_text())
            self.assertTrue(status["IOS"]["reviewBlocked"])

    def test_other_422_rethrows(self):
        def responder(path, parameters, method, body):
            if path == "/v1/betaAppReviewSubmissions" and method == "POST":
                raise asc.AppStoreError(
                    422, {"errors": [{"code": "ENTITY_UNPROCESSABLE.OTHER"}]}
                )
            return {}

        with tempfile.TemporaryDirectory() as tmp:
            docs = {
                BUILD_IOS: [
                    build_document(BUILD_IOS, platform="IOS"),
                    build_document(
                        BUILD_IOS, platform="IOS",
                        group_ids=[GROUP_INTERNAL, GROUP_EXTERNAL],
                        review_state="WAITING_FOR_REVIEW",
                    ),
                ]
            }
            manifest_path = write_manifest(
                tmp, builds={"IOS": BUILD_IOS}, notes={"IOS": "ios notes"},
                submitExternalReview=True,
            )
            inspector = QueuedInspector(docs)
            log = CallLog(responder)
            with mock.patch.object(asc, "groups_for_app", return_value=self.groups):
                with mock.patch.object(asc, "inspect_build", inspector):
                    with mock.patch.object(asc, "request", log):
                        with self.assertRaises(asc.AppStoreError):
                            asc.distribute(manifest_path)

    def test_groups_requests_and_review_skipped_when_present(self):
        with tempfile.TemporaryDirectory() as tmp:
            docs = {
                BUILD_IOS: [
                    build_document(
                        BUILD_IOS, platform="IOS",
                        group_ids=[GROUP_INTERNAL, GROUP_EXTERNAL],
                        review_state="APPROVED",
                    ),
                    build_document(
                        BUILD_IOS, platform="IOS",
                        group_ids=[GROUP_INTERNAL, GROUP_EXTERNAL],
                        review_state="APPROVED",
                    ),
                ]
            }
            manifest_path = write_manifest(
                tmp, builds={"IOS": BUILD_IOS}, notes={"IOS": "ios notes"},
                submitExternalReview=True,
            )
            inspector = QueuedInspector(docs)
            log = CallLog()
            with mock.patch.object(asc, "groups_for_app", return_value=self.groups):
                with mock.patch.object(asc, "inspect_build", inspector):
                    with mock.patch.object(asc, "request", log):
                        outcome = asc.distribute(manifest_path)
            self.assertEqual(outcome, 0)
            self.assertEqual(log.posts_to("/v1/betaAppReviewSubmissions"), [])
            self.assertEqual(
                log.posts_to(f"/v1/builds/{BUILD_IOS}/relationships/betaGroups"), []
            )




class RequestTransportTests(unittest.TestCase):
    @staticmethod
    def opener_recording(payload=b'{"data": []}'):
        class Response:
            def __init__(self, body):
                self.body = body

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def read(self):
                return self.body

        seen = []

        def fake_open(req, timeout=None):
            seen.append({"req": req, "timeout": timeout})
            return Response(payload)

        return seen, fake_open

    def test_get_url_query_auth_headers_and_timeout(self):
        seen, fake_open = self.opener_recording()
        with mock.patch.object(asc, "token", return_value="synthetic.jwt.sig"):
            with mock.patch.object(asc.OPENER, "open", fake_open):
                asc.request("/v1/apps", {"filter[bundleId]": asc.BUNDLE_ID})
        req = seen[0]["req"]
        self.assertEqual(seen[0]["timeout"], 60)
        parsed = urllib.parse.urlparse(req.full_url)
        self.assertEqual(parsed.scheme, "https")
        self.assertEqual(parsed.netloc, "api.appstoreconnect.apple.com")
        self.assertEqual(parsed.path, "/v1/apps")
        query = urllib.parse.parse_qs(parsed.query)
        self.assertEqual(query, {"filter[bundleId]": [asc.BUNDLE_ID]})
        self.assertEqual(
            req.get_header("Authorization"), "Bearer synthetic.jwt.sig"
        )
        self.assertEqual(req.get_header("Content-type"), "application/json")
        self.assertIsNone(req.data)
        self.assertEqual(req.get_method(), "GET")

    def test_post_sends_frozen_json_body(self):
        body = {
            "data": {
                "type": "betaAppReviewSubmissions",
                "relationships": {
                    "build": {"data": {"type": "builds", "id": BUILD_IOS}}
                },
            }
        }
        seen, fake_open = self.opener_recording()
        with mock.patch.object(asc, "token", return_value="synthetic.jwt.sig"):
            with mock.patch.object(asc.OPENER, "open", fake_open):
                asc.request("/v1/betaAppReviewSubmissions", method="POST", body=body)
        req = seen[0]["req"]
        self.assertEqual(req.get_method(), "POST")
        self.assertIsInstance(req.data, bytes)
        self.assertEqual(json.loads(req.data.decode()), body)

    def test_get_without_parameters_has_no_query(self):
        seen, fake_open = self.opener_recording()
        with mock.patch.object(asc, "token", return_value="synthetic.jwt.sig"):
            with mock.patch.object(asc.OPENER, "open", fake_open):
                asc.request("/v1/apps")
        self.assertNotIn("?", seen[0]["req"].full_url)

    def test_inspect_build_uses_frozen_query_shape(self):
        seen, fake_open = self.opener_recording()
        with mock.patch.object(asc, "token", return_value="synthetic.jwt.sig"):
            with mock.patch.object(asc.OPENER, "open", fake_open):
                asc.inspect_build(BUILD_IOS)
        req = seen[0]["req"]
        parsed = urllib.parse.urlparse(req.full_url)
        self.assertEqual(parsed.path, f"/v1/builds/{BUILD_IOS}")
        query = urllib.parse.parse_qs(parsed.query)
        self.assertEqual(
            query["include"],
            ["app,preReleaseVersion,buildBetaDetail,betaGroups,"
             "betaBuildLocalizations,betaAppReviewSubmission"],
        )
        self.assertEqual(
            query["fields[buildBetaDetails]"],
            ["internalBuildState,externalBuildState,autoNotifyEnabled"],
        )

    def test_empty_body_returns_empty_dict(self):
        seen, fake_open = self.opener_recording(payload=b"")
        with mock.patch.object(asc, "token", return_value="synthetic.jwt.sig"):
            with mock.patch.object(asc.OPENER, "open", fake_open):
                self.assertEqual(asc.request("/v1/apps"), {})

    def test_http_error_becomes_appstore_error(self):
        payload = json.dumps(
            {"errors": [{"code": "ENTITY_UNPROCESSABLE.ANOTHER_BUILD_IN_REVIEW"}]}
        ).encode()

        def failing_open(req, timeout=None):
            raise urllib.error.HTTPError(
                req.full_url, 422, "Unprocessable", {}, io.BytesIO(payload)
            )

        with mock.patch.object(asc, "token", return_value="synthetic.jwt.sig"):
            with mock.patch.object(asc.OPENER, "open", failing_open):
                with self.assertRaises(asc.AppStoreError) as caught:
                    asc.request("/v1/apps")
        self.assertEqual(caught.exception.status, 422)
        self.assertTrue(
            caught.exception.has_code(
                "ENTITY_UNPROCESSABLE.ANOTHER_BUILD_IN_REVIEW"
            )
        )

    def test_non_json_error_maps_to_non_json_response(self):
        def failing_open(req, timeout=None):
            raise urllib.error.HTTPError(
                req.full_url, 503, "Unavailable", {}, io.BytesIO(b"not json")
            )

        with mock.patch.object(asc, "token", return_value="synthetic.jwt.sig"):
            with mock.patch.object(asc.OPENER, "open", failing_open):
                with self.assertRaises(asc.AppStoreError) as caught:
                    asc.request("/v1/apps")
        self.assertEqual(caught.exception.status, 503)
        self.assertTrue(caught.exception.has_code("NON_JSON_RESPONSE"))

    def test_rejects_non_api_paths_before_signing(self):
        token = mock.Mock()
        for bad in ("/v2/apps", "/v1/apps?x=1", "v1/apps", "/v1/apps#frag"):
            with mock.patch.object(asc, "token", token):
                with self.assertRaises(ValueError):
                    asc.request(bad)
        token.assert_not_called()


class GroupsTests(unittest.TestCase):
    def test_groups_for_app_paginates_beta_groups_endpoint(self):
        def responder(path, parameters, method, body):
            if parameters.get("cursor") == "c2":
                return {"data": [group("GRPSECOND", False)]}
            if path != f"/v1/apps/{APP_ID}/betaGroups":
                raise AssertionError(f"unexpected path {path}")
            return {
                "data": [group("GRPFIRST1", True)],
                "links": {
                    "next": "https://api.appstoreconnect.apple.com"
                            f"/v1/apps/{APP_ID}/betaGroups?cursor=c2"
                },
            }

        log = CallLog(responder)
        with mock.patch.object(asc, "request", log):
            groups = asc.groups_for_app(APP_ID)
        self.assertEqual(
            [item["id"] for item in groups], ["GRPFIRST1", "GRPSECOND"]
        )
        self.assertEqual(len(log.calls), 2)
        for call in log.calls:
            self.assertEqual(call["method"], "GET")
            self.assertEqual(
                call["path"], f"/v1/apps/{APP_ID}/betaGroups"
            )

    def test_groups_for_app_rejects_nonboolean_internal_flag(self):
        bad = group("GRPBAD001", True)
        bad["attributes"]["isInternalGroup"] = "yes"

        def responder(path, parameters, method, body):
            return {"data": [bad]}

        with mock.patch.object(asc, "request", CallLog(responder)):
            with self.assertRaises(ValueError):
                asc.groups_for_app(APP_ID)


class AfterStateRejectionTests(unittest.TestCase):
    def test_review_rejected_in_after_state_returns_2(self):
        docs = {
            BUILD_IOS: [
                build_document(BUILD_IOS, platform="IOS"),
                build_document(
                    BUILD_IOS, platform="IOS",
                    group_ids=[GROUP_INTERNAL, GROUP_EXTERNAL],
                    review_state="REJECTED",
                    external_state="BETA_REJECTED",
                ),
            ]
        }
        groups = [group(GROUP_INTERNAL, True), group(GROUP_EXTERNAL, False)]
        with tempfile.TemporaryDirectory() as tmp:
            manifest_path = write_manifest(
                tmp, builds={"IOS": BUILD_IOS}, notes={"IOS": "ios notes"},
                submitExternalReview=True,
            )
            inspector = QueuedInspector(docs)
            log = CallLog(
                lambda p, q, m, b: {"data": {"type": "betaAppReviewSubmissions",
                                             "id": "NEWREV"}}
            )
            with mock.patch.object(asc, "groups_for_app", return_value=groups):
                with mock.patch.object(asc, "inspect_build", inspector):
                    with mock.patch.object(asc, "request", log):
                        outcome = asc.distribute(manifest_path)
            self.assertEqual(outcome, 2)
            submissions = log.posts_to("/v1/betaAppReviewSubmissions")
            self.assertEqual(len(submissions), 1)
            evidence = next(
                p for p in Path(tmp).iterdir()
                if p.is_dir() and p.name.startswith("distribution-")
            )
            status = json.loads((evidence / "status.json").read_text())
            self.assertEqual(
                status["IOS"]["betaReviewStates"], ["REJECTED"]
            )
            self.assertTrue(status["IOS"]["reviewBlocked"])
            self.assertTrue(status["IOS"]["allGroupsAssigned"])
            log.assert_no_expiry_or_delete(self)


class ReceiptPermissionsTests(unittest.TestCase):
    def test_distribution_receipts_are_private_and_preserved(self):
        groups = [group(GROUP_INTERNAL, True)]

        def docs():
            return {
                BUILD_IOS: [
                    build_document(BUILD_IOS, platform="IOS"),
                    build_document(
                        BUILD_IOS, platform="IOS",
                        group_ids=[GROUP_INTERNAL],
                    ),
                ]
            }

        with tempfile.TemporaryDirectory() as tmp:
            manifest_path = write_manifest(
                tmp, builds={"IOS": BUILD_IOS}, notes={"IOS": "ios notes"}
            )
            first_dir = None
            first_snapshot = None
            for _ in range(2):
                inspector = QueuedInspector(docs())
                log = CallLog()
                with mock.patch.object(asc, "groups_for_app", return_value=groups):
                    with mock.patch.object(asc, "inspect_build", inspector):
                        with mock.patch.object(asc, "request", log):
                            self.assertEqual(asc.distribute(manifest_path), 0)
                if first_dir is None:
                    first_dir = next(
                        p for p in Path(tmp).iterdir()
                        if p.is_dir() and p.name.startswith("distribution-")
                    )
                    first_snapshot = {
                        f.name: f.read_bytes() for f in first_dir.iterdir()
                    }
            receipts = [
                p for p in Path(tmp).iterdir()
                if p.is_dir() and p.name.startswith("distribution-")
            ]
            self.assertEqual(len(receipts), 2)
            for receipt in receipts:
                self.assertEqual(
                    stat.S_IMODE(receipt.stat().st_mode), 0o700
                )
                for entry in receipt.iterdir():
                    self.assertEqual(
                        stat.S_IMODE(entry.stat().st_mode), 0o600, entry.name
                    )
            self.assertEqual(
                {f.name: f.read_bytes() for f in first_dir.iterdir()},
                first_snapshot,
            )


if __name__ == "__main__":
    unittest.main()
