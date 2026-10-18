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

    def test_runtime_environment_preserves_and_extends_library_paths(self):
        source = {
            "SOLARIS_LIBRARY_PATH": "/opt/solaris/lib",
            "MESA_LIBRARY_PATH": "/opt/mesa/lib",
            "VULKAN_LIBRARY_PATH": "/opt/vulkan/lib",
            "LD_LIBRARY_PATH": "/custom/lib",
            "VK_DRIVER_FILES": "/etc/vulkan/icd.d/sparc.json",
        }
        with mock.patch.object(launcher.platform, "machine", return_value="sparcv9"), \
             mock.patch.object(launcher.platform, "system", return_value="SunOS"):
            env = launcher.runtime_environment(pathlib.Path("/game/bin"), source)
        entries = env["LD_LIBRARY_PATH"].split(":")
        self.assertEqual(entries[0], "/game/bin")
        self.assertIn("/opt/solaris/lib", entries)
        self.assertIn("/opt/mesa/lib", entries)
        self.assertIn("/opt/vulkan/lib", entries)
        self.assertEqual(entries[-1], "/custom/lib")
        self.assertEqual(env["VK_DRIVER_FILES"], source["VK_DRIVER_FILES"])
        self.assertEqual(source["LD_LIBRARY_PATH"], "/custom/lib")
        self.assertEqual(env["LD_LIBRARY_PATH_64"], env["LD_LIBRARY_PATH"])

    def test_runtime_environment_preserves_64_bit_solaris_search_path(self):
        source = {"LD_LIBRARY_PATH": "/legacy/lib", "LD_LIBRARY_PATH_64": "/sparcv9/lib"}
        with mock.patch.object(launcher.platform, "machine", return_value="sparcv9"), \
             mock.patch.object(launcher.platform, "system", return_value="SunOS"):
            env = launcher.runtime_environment(pathlib.Path("/game/bin"), source)
        self.assertIn("/legacy/lib", env["LD_LIBRARY_PATH"])
        self.assertTrue(env["LD_LIBRARY_PATH_64"].endswith(":" + "/sparcv9/lib"))
        self.assertEqual(source["LD_LIBRARY_PATH_64"], "/sparcv9/lib")

    def test_runtime_environment_adds_64_bit_path_for_solaris_machine_names(self):
        for machine in ("sun4u", "sun4v"):
            with self.subTest(machine=machine), \
                 mock.patch.object(launcher.platform, "machine", return_value=machine), \
                 mock.patch.object(launcher.platform, "system", return_value="SunOS"):
                env = launcher.runtime_environment(pathlib.Path("/game/bin"), {})
            self.assertEqual(env["LD_LIBRARY_PATH_64"], env["LD_LIBRARY_PATH"])

    def test_runtime_environment_does_not_treat_sun4_as_solaris_off_host(self):
        for system in ("Linux", "Darwin"):
            with self.subTest(system=system), \
                 mock.patch.object(launcher.platform, "machine", return_value="sun4v"), \
                 mock.patch.object(launcher.platform, "system", return_value=system):
                env = launcher.runtime_environment(pathlib.Path("/game/bin"), {})
            self.assertNotIn("LD_LIBRARY_PATH_64", env)

    def test_vulkan_jvm_library_override(self):
        self.assertEqual(launcher.vulkan_jvm_args({}), [])
        self.assertEqual(launcher.vulkan_jvm_args({
            "MC_VULKAN_LIBRARY_NAME": "/opt/vulkan/lib/sparcv9/libvulkan.so.1"
        }), ["-Dorg.lwjgl.vulkan.libname=/opt/vulkan/lib/sparcv9/libvulkan.so.1"])

    def test_runtime_environment_does_not_create_ld_library_path_64_off_sparc(self):
        with mock.patch.object(launcher.platform, "machine", return_value="x86_64"):
            env = launcher.runtime_environment(pathlib.Path("/game/bin"), {})
        self.assertNotIn("LD_LIBRARY_PATH_64", env)

    def test_runtime_environment_adds_no_unconfigured_vulkan_defaults(self):
        env = launcher.runtime_environment(pathlib.Path("/game/bin"), {})
        self.assertEqual(env["LD_LIBRARY_PATH"], ":".join([
            "/game/bin", *launcher.DEFAULT_LIBRARY_PATH.split(":")]))
        self.assertNotIn("VULKAN_LIBRARY_PATH", env)
        self.assertNotIn("VK_DRIVER_FILES", env)
        self.assertNotIn("VK_ICD_FILENAMES", env)

    def test_vulkan_diagnostics_report_only_optional_vulkan_settings(self):
        stream = io.StringIO()
        with mock.patch.object(launcher.sys, "stderr", stream):
            launcher.log_vulkan_configuration({
                "VULKAN_LIBRARY_PATH": "/opt/vulkan-1.3.250/lib",
                "VK_DRIVER_FILES": "/etc/vulkan/icd.d/lavapipe.json",
                "MC_ACCESS_TOKEN": "must-not-appear",
            })
        output = stream.getvalue()
        self.assertIn("VULKAN_LIBRARY_PATH=/opt/vulkan-1.3.250/lib", output)
        self.assertIn("VK_DRIVER_FILES=/etc/vulkan/icd.d/lavapipe.json", output)
        self.assertNotIn("must-not-appear", output)

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
