#!/usr/bin/env python3
import hashlib
import importlib.util
import io
import json
import pathlib
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("solaris_launcher", ROOT / "launch" / "launcher.py")
launcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(launcher)


class FakeResponse(io.BytesIO):
    def __init__(self, body, url):
        super().__init__(body)
        self.url = url

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()

    def geturl(self):
        return self.url


class LauncherMetadataTests(unittest.TestCase):
    def test_rules_exclude_macos_and_allow_common(self):
        self.assertFalse(launcher.rules_allow([{"action": "allow", "os": {"name": "osx"}}]))
        self.assertTrue(launcher.rules_allow([{"action": "allow"}]))

    def test_rules_apply_matching_override(self):
        rules = [
            {"action": "allow"},
            {"action": "disallow", "os": {"name": "windows"}},
        ]
        self.assertTrue(launcher.rules_allow(rules))

    def test_library_artifact_path_fallback(self):
        library = {"name": "org.lwjgl:lwjgl:3.3.1"}
        self.assertEqual(launcher.artifact_path(library), "org/lwjgl/lwjgl/3.3.1/lwjgl-3.3.1.jar")

    def test_native_classifier_is_resolvable_but_filtered_by_caller(self):
        library = {"name": "org.lwjgl:lwjgl:3.3.1:natives-linux"}
        self.assertEqual(launcher.artifact_path(library), "org/lwjgl/lwjgl/3.3.1/lwjgl-3.3.1-natives-linux.jar")

    def test_inheritance_chain_orders_parent_before_child(self):
        with tempfile.TemporaryDirectory() as temp:
            home = pathlib.Path(temp)
            parent = home / "versions" / "parent"
            child = home / "versions" / "child"
            parent.mkdir(parents=True)
            child.mkdir(parents=True)
            (parent / "parent.json").write_text('{"id":"parent","libraries":[]}')
            (child / "child.json").write_text('{"id":"child","inheritsFrom":"parent"}')
            chain = launcher.metadata_chain(home, "child")
            self.assertEqual([entry[0]["id"] for entry in chain], ["parent", "child"])

    def test_download_verifies_and_reuses_existing_file(self):
        payload = b"artifact contents"
        url = "https://libraries.minecraft.net/demo.jar"
        with tempfile.TemporaryDirectory() as temp:
            destination = pathlib.Path(temp) / "libraries/demo.jar"
            opener = mock.Mock(return_value=FakeResponse(payload, url))
            with mock.patch.object(launcher.urllib.request, "urlopen", opener):
                launcher.download_file(url, destination, len(payload), hashlib.sha1(payload).hexdigest())
                launcher.download_file(url, destination, len(payload), hashlib.sha1(payload).hexdigest())
            opener.assert_called_once()
            self.assertEqual(destination.read_bytes(), payload)

    def test_failed_download_does_not_publish_partial_file(self):
        payload = b"bad payload"
        url = "https://libraries.minecraft.net/demo.jar"
        with tempfile.TemporaryDirectory() as temp:
            destination = pathlib.Path(temp) / "demo.jar"
            with mock.patch.object(launcher.urllib.request, "urlopen", return_value=FakeResponse(payload, url)):
                with self.assertRaises(ValueError):
                    launcher.download_file(url, destination, len(payload), "0" * 40)
            self.assertFalse(destination.exists())
            self.assertEqual(list(destination.parent.iterdir()), [])

    def test_untrusted_url_and_traversal_are_rejected(self):
        with self.assertRaises(ValueError):
            launcher.validate_url("http://libraries.minecraft.net/demo.jar")
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(ValueError):
                launcher.safe_destination(pathlib.Path(temp), "../escape.jar")

    def test_asset_objects_download_from_hash_path(self):
        payload = b"asset-data"
        digest = hashlib.sha1(payload).hexdigest()
        index = {"objects": {"sound/test.ogg": {"hash": digest, "size": len(payload)}}}
        index_bytes = json.dumps(index).encode()
        index_hash = hashlib.sha1(index_bytes).hexdigest()
        index_url = "https://piston-meta.mojang.com/assets/index.json"
        object_url = f"https://resources.download.minecraft.net/{digest[:2]}/{digest}"
        with tempfile.TemporaryDirectory() as temp:
            home = pathlib.Path(temp)
            responses = {
                index_url: FakeResponse(index_bytes, index_url),
                object_url: FakeResponse(payload, object_url),
            }
            with mock.patch.object(launcher.urllib.request, "urlopen", side_effect=lambda req, timeout: responses[req.full_url]):
                launcher.acquire_assets(home, {"id": "test", "url": index_url,
                                               "size": len(index_bytes), "sha1": index_hash})
            self.assertEqual((home / "assets/objects" / digest[:2] / digest).read_bytes(), payload)


if __name__ == "__main__":
    unittest.main()
