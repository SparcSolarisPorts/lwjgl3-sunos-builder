#!/usr/bin/env python3
import importlib.util
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("solaris_launcher", ROOT / "launch" / "launcher.py")
launcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(launcher)


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


if __name__ == "__main__":
    unittest.main()
