#!/usr/bin/env python3
"""Launch an installed Minecraft release with this project's Solaris natives."""
import hashlib
import json
import os
import pathlib
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

MANIFEST_URL = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
ASSET_OBJECT_URL = "https://resources.download.minecraft.net"
DEFAULT_LIBRARY_URL = "https://libraries.minecraft.net/"
OFFICIAL_DOWNLOAD_HOSTS = {"piston-meta.mojang.com", "launchermeta.mojang.com", "launcher.mojang.com", "libraries.minecraft.net", "resources.download.minecraft.net", "piston-data.mojang.com"}
DEFAULT_LIBRARY_PATH = "/usr/lib/64:/usr/lib/sparcv9:/usr/lib/mesa/sparcv9:/usr/lib/GL/sparcv9"


def fail(message):
    print(f"launcher: error: {message}", file=sys.stderr)
    raise SystemExit(1)


def validate_url(url):
    parsed = urllib.parse.urlparse(url)
    if (parsed.scheme != "https" or parsed.hostname not in OFFICIAL_DOWNLOAD_HOSTS or
            parsed.username or parsed.password or parsed.port not in (None, 443)):
        raise ValueError(f"untrusted Mojang download URL: {url}")
    return url


def fetch_bytes(url):
    validate_url(url)
    request = urllib.request.Request(url, headers={"User-Agent": "lwjgl3-sunos-builder/1.0"})
    with urllib.request.urlopen(request, timeout=30) as response:
        final_url = response.geturl()
        validate_url(final_url)
        return response.read()


def fetch_json(url):
    return json.loads(fetch_bytes(url).decode("utf-8"))


def safe_destination(root, relative):
    if not isinstance(relative, str) or not relative or "\\" in relative:
        raise ValueError("invalid artifact path")
    rel = pathlib.PurePosixPath(relative)
    if rel.is_absolute() or any(part in ("", ".", "..") for part in rel.parts):
        raise ValueError(f"unsafe artifact path: {relative}")
    destination = (root / pathlib.Path(*rel.parts)).resolve()
    try:
        destination.relative_to(root.resolve())
    except ValueError:
        raise ValueError(f"artifact path escapes Minecraft directory: {relative}")
    return destination


def valid_payload(path, expected_size=None, expected_sha1=None):
    try:
        size = path.stat().st_size
        if expected_size is not None and size != int(expected_size):
            return False
        if expected_sha1:
            digest = hashlib.sha1()
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
            if digest.hexdigest().lower() != str(expected_sha1).lower():
                return False
        return True
    except (OSError, ValueError, TypeError):
        return False


def download_file(url, destination, expected_size=None, expected_sha1=None):
    validate_url(url)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_file() and valid_payload(destination, expected_size, expected_sha1):
        return destination
    fd, temp_name = tempfile.mkstemp(prefix=f".{destination.name}.", suffix=".part", dir=destination.parent)
    os.close(fd)
    temporary = pathlib.Path(temp_name)
    try:
        request = urllib.request.Request(url, headers={"User-Agent": "lwjgl3-sunos-builder/1.0"})
        with urllib.request.urlopen(request, timeout=60) as response, temporary.open("wb") as output:
            validate_url(response.geturl())
            shutil.copyfileobj(response, output)
        if not valid_payload(temporary, expected_size, expected_sha1):
            raise ValueError(f"download verification failed for {url}")
        os.replace(temporary, destination)
        print(f"launcher: downloaded {destination}", file=sys.stderr)
        return destination
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def get_metadata(mc_home, version):
    path = mc_home / "versions" / version / f"{version}.json"
    if path.is_file():
        try:
            return json.loads(path.read_text(encoding="utf-8")), path
        except (OSError, json.JSONDecodeError) as exc:
            fail(f"cannot read {path}: {exc}")
    try:
        manifest = fetch_json(MANIFEST_URL)
        entry = next(item for item in manifest["versions"] if item["id"] == version and item["type"] == "release")
        metadata_bytes = fetch_bytes(entry["url"])
        expected = entry.get("sha1")
        if expected and hashlib.sha1(metadata_bytes).hexdigest().lower() != expected.lower():
            raise ValueError(f"version metadata SHA-1 mismatch for {version}")
        metadata = json.loads(metadata_bytes.decode("utf-8"))
    except (OSError, ValueError, KeyError, StopIteration) as exc:
        fail(f"could not obtain official release metadata for {version}: {exc}")
    return metadata, None


def rules_allow(rules):
    if not rules:
        return True
    allowed = False
    # This helper targets Solaris even when metadata is inspected from macOS.
    os_name = "solaris"
    arch = platform.machine().lower()
    for rule in rules:
        test = rule.get("os", {})
        match = test.get("name", os_name) == os_name
        if "arch" in test:
            expected = test["arch"]
            match = match and ((expected == "x86" and arch in ("i386", "i486", "i586", "i686")) or
                               (expected == "x86_64" and arch in ("x86_64", "amd64")) or
                               expected == arch)
        features = rule.get("features", {})
        if features:
            def enabled(feature):
                if feature == "is_demo_user":
                    return os.environ.get("MC_DEMO_USER") == "1"
                if feature == "has_custom_resolution":
                    return bool(os.environ.get("MC_RESOLUTION_WIDTH") and os.environ.get("MC_RESOLUTION_HEIGHT"))
                env_key = "MC_" + feature.upper()
                return os.environ.get(env_key) == "1"
            match = match and all(enabled(feature) == wanted for feature, wanted in features.items())
        allowed = rule["action"] == "allow" if match else allowed
    return allowed


def expand_entry(entry):
    if isinstance(entry, str):
        return [entry]
    if not isinstance(entry, dict):
        return []
    if "rules" in entry and not rules_allow(entry["rules"]):
        return []
    value = entry.get("value", [])
    return value if isinstance(value, list) else [value]


def artifact_path(library):
    downloads = library.get("downloads", {})
    artifact = downloads.get("artifact")
    if artifact and artifact.get("path"):
        return artifact["path"]
    name = library.get("name", "")
    parts = name.split(":")
    if len(parts) < 3 or len(parts) > 4:
        return None
    group, artifact_name, version = parts[:3]
    classifier = parts[3] if len(parts) == 4 else ""
    filename = f"{artifact_name}-{version}{('-' + classifier) if classifier else ''}.jar"
    return "/".join(group.split(".")) + f"/{artifact_name}/{version}/{filename}"


def metadata_chain(mc_home, version):
    chain = []
    seen = set()
    current = version
    while current:
        if current in seen:
            fail(f"metadata inheritance cycle at {current}")
        seen.add(current)
        metadata, path = get_metadata(mc_home, current)
        chain.insert(0, (metadata, path))
        current = metadata.get("inheritsFrom")
    return chain


def acquire_assets(mc_home, asset_index):
    if not asset_index:
        return
    index_id = asset_index.get("id")
    index_url = asset_index.get("url")
    if not index_id or not index_url:
        fail("assetIndex metadata is incomplete")
    try:
        index_path = safe_destination(mc_home, f"assets/indexes/{index_id}.json")
        if index_path.is_file() and valid_payload(index_path, asset_index.get("size"), asset_index.get("sha1")):
            pass
        else:
            download_file(index_url, index_path, asset_index.get("size"), asset_index.get("sha1"))
        index = json.loads(index_path.read_text(encoding="utf-8"))
        for obj in index.get("objects", {}).values():
            digest = obj.get("hash", "")
            if not re.fullmatch(r"[0-9a-fA-F]{40}", digest):
                raise ValueError("asset index contains an invalid SHA-1")
            rel = f"assets/objects/{digest[:2].lower()}/{digest.lower()}"
            path = safe_destination(mc_home, rel)
            if not valid_payload(path, obj.get("size"), digest):
                download_file(f"{ASSET_OBJECT_URL}/{digest[:2].lower()}/{digest.lower()}", path,
                              obj.get("size"), digest)
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
        fail(f"could not download/verify Minecraft assets: {exc}")


def substitute(value, values):
    env_names = {
        "auth_uuid": "MC_UUID", "auth_access_token": "MC_ACCESS_TOKEN",
        "clientid": "MC_CLIENT_ID", "auth_xuid": "MC_XUID",
        "resolution_width": "MC_RESOLUTION_WIDTH", "resolution_height": "MC_RESOLUTION_HEIGHT",
        "quickPlayPath": "MC_QUICKPLAY_PATH",
        "quickPlaySingleplayer": "MC_QUICKPLAY_SINGLEPLAYER",
        "quickPlayMultiplayer": "MC_QUICKPLAY_MULTIPLAYER",
        "quickPlayRealms": "MC_QUICKPLAY_REALMS",
    }
    def replace(match):
        key = match.group(1)
        if key not in values or values[key] is None:
            fail(f"Minecraft metadata requires ${{{key}}}; set {env_names.get(key, 'a compatible launcher')}")
        return str(values[key])
    return re.sub(r"\$\{([^}]+)\}", replace, value)


def main():
    if len(sys.argv) != 2:
        fail("usage: launch-<version>.sh")
    version = sys.argv[1]
    repo = pathlib.Path(__file__).resolve().parent.parent
    default_mc = pathlib.Path.home() / ".minecraft"
    mac_mc = pathlib.Path.home() / "Library" / "Application Support" / "minecraft"
    mc_home = pathlib.Path(os.environ.get("MINECRAFT_HOME", mac_mc if mac_mc.is_dir() else default_mc)).expanduser().resolve()
    native_dir = pathlib.Path(os.environ.get("MC_NATIVE_DIR", repo / "bin" / version)).expanduser().resolve()
    if not native_dir.is_dir():
        fail(f"native directory not found: {native_dir}; build this release first")

    chain = metadata_chain(mc_home, version)
    meta = chain[-1][0]
    effective = {}
    for item, _ in chain:
        effective.update(item)
    version_dir = mc_home / "versions" / version
    client_info = meta.get("downloads", {}).get("client")
    if not client_info or not client_info.get("url"):
        fail(f"client download metadata missing for {version}")
    try:
        client_rel = client_info.get("path") or f"versions/{version}/{version}.jar"
        client = safe_destination(mc_home, client_rel)
        download_file(client_info["url"], client, client_info.get("size"), client_info.get("sha1"))
    except (OSError, ValueError, KeyError, TypeError) as exc:
        fail(f"could not obtain client jar for Minecraft {version}: {exc}")
    try:
        acquire_assets(mc_home, meta.get("assetIndex"))
    except SystemExit:
        raise
    main_class = effective.get("mainClass")
    if not main_class:
        fail(f"mainClass is missing from metadata for {version}")

    classpath = []
    for item, _ in chain:
        for library in item.get("libraries", []):
            if not rules_allow(library.get("rules", [])):
                continue
            name = library.get("name", "")
            # Native classifier jars are not Solaris-compatible; native files
            # come from bin/<version> instead. Non-native classifiers such as
            # LWJGL's "unsafe" Java artifact remain on the classpath.
            parts = name.split(":")
            if len(parts) > 3 and parts[3].startswith("natives-"):
                continue
            artifact = library.get("downloads", {}).get("artifact", {})
            rel = artifact_path(library)
            if not rel:
                continue
            try:
                jar = safe_destination(mc_home, f"libraries/{rel}")
                url = artifact.get("url")
                if not url:
                    base = library.get("url") or DEFAULT_LIBRARY_URL
                    url = urllib.parse.urljoin(base.rstrip("/") + "/", rel)
                download_file(url, jar, artifact.get("size"), artifact.get("sha1"))
            except (OSError, ValueError, KeyError, TypeError) as exc:
                fail(f"could not obtain library {name}: {exc}")
            classpath.append(str(jar))
    if not classpath:
        fail(f"no Java libraries found in metadata for {version}")
    stock_lwjgl = [p for p in classpath if re.search(r"/org/lwjgl/lwjgl/[0-9][^/]*/lwjgl-[^/]+\.jar$", p)]
    classpath = [p for p in classpath if p not in stock_lwjgl]
    patched_jar = native_dir / "lwjgl.jar"
    if patched_jar.is_file():
        classpath.insert(0, str(patched_jar))
    elif stock_lwjgl:
        fail(f"patched core jar missing: {patched_jar}")
    classpath.append(str(client))
    cp = os.pathsep.join(classpath)

    java_home = pathlib.Path(os.environ.get("JAVA_HOME", "" )).expanduser() if os.environ.get("JAVA_HOME") else None
    java = str(java_home / "bin" / "java") if java_home else shutil.which("java")
    if not java or not os.access(java, os.X_OK):
        fail("Java executable not found; set JAVA_HOME to a supported Solaris JDK")
    required_java = meta.get("javaVersion", {}).get("majorVersion")
    if required_java:
        try:
            detected = subprocess.check_output([java, "-version"], stderr=subprocess.STDOUT, text=True)
            match = re.search(r'version "(?:1\.)?(\d+)', detected)
            if not match:
                match = re.search(r'openjdk (\d+)', detected)
            if match and int(match.group(1)) < int(required_java):
                fail(f"Minecraft {version} requires Java {required_java} or newer")
        except (OSError, subprocess.CalledProcessError):
            fail(f"cannot determine Java version from {java}")

    values = {
        "auth_player_name": os.environ.get("MC_USERNAME", "Player"),
        "version_name": version,
        "game_directory": os.environ.get("MC_GAME_DIR", str(mc_home)),
        "assets_root": str(mc_home / "assets"),
        "assets_index_name": meta.get("assetIndex", {}).get("id"),
        "auth_uuid": os.environ.get("MC_UUID"),
        "auth_access_token": os.environ.get("MC_ACCESS_TOKEN"),
        "clientid": os.environ.get("MC_CLIENT_ID"),
        "auth_xuid": os.environ.get("MC_XUID", ""),
        "user_type": os.environ.get("MC_USER_TYPE", "msa"),
        "version_type": os.environ.get("MC_VERSION_TYPE", "release"),
        "classpath": cp,
        "natives_directory": str(native_dir),
        "launcher_name": os.environ.get("MC_LAUNCHER_NAME", "SolarisSPARC"),
        "launcher_version": os.environ.get("MC_LAUNCHER_VERSION", "1"),
        "resolution_width": os.environ.get("MC_RESOLUTION_WIDTH"),
        "resolution_height": os.environ.get("MC_RESOLUTION_HEIGHT"),
        "quickPlayPath": os.environ.get("MC_QUICKPLAY_PATH"),
        "quickPlaySingleplayer": os.environ.get("MC_QUICKPLAY_SINGLEPLAYER"),
        "quickPlayMultiplayer": os.environ.get("MC_QUICKPLAY_MULTIPLAYER"),
        "quickPlayRealms": os.environ.get("MC_QUICKPLAY_REALMS"),
    }
    if meta.get("arguments"):
        args_meta = meta["arguments"]
        jvm = []
        for entry in args_meta.get("jvm", []) + args_meta.get("default-user-jvm", []):
            jvm.extend(expand_entry(entry))
        game = []
        for entry in args_meta.get("game", []):
            game.extend(expand_entry(entry))
    elif meta.get("minecraftArguments"):
        jvm = ["-Djava.library.path=" + str(native_dir), "-Dorg.lwjgl.librarypath=" + str(native_dir), "-cp", cp]
        game = shlex.split(meta["minecraftArguments"])
    else:
        fail(f"no supported game arguments in metadata for {version}")

    args = []
    skip_next = False
    for raw in jvm:
        if skip_next:
            skip_next = False
            continue
        if raw == "-cp" or raw == "-classpath":
            skip_next = True
            continue
        expanded = substitute(raw, values)
        if expanded.startswith(("-Djava.library.path=", "-Dorg.lwjgl.librarypath=")):
            continue
        args.append(expanded)
    args += [f"-Djava.library.path={native_dir}", f"-Dorg.lwjgl.librarypath={native_dir}", "-cp", cp]
    game_args = [substitute(arg, values) for arg in game]
    print(f"launcher: Minecraft {version}, Java {required_java or 'unspecified'}, natives={native_dir}", file=sys.stderr)
    print(f"launcher: classpath contains {len(classpath)} jars; credentials are not logged", file=sys.stderr)

    extra_paths = os.environ.get("SOLARIS_LIBRARY_PATH", "")
    ld_paths = [str(native_dir), *DEFAULT_LIBRARY_PATH.split(":"), *[p for p in extra_paths.split(":") if p]]
    if os.environ.get("MESA_LIBRARY_PATH"):
        ld_paths.append(os.environ["MESA_LIBRARY_PATH"])
    if os.environ.get("VULKAN_LIBRARY_PATH"):
        ld_paths.append(os.environ["VULKAN_LIBRARY_PATH"])
    if os.environ.get("LD_LIBRARY_PATH"):
        ld_paths.append(os.environ["LD_LIBRARY_PATH"])
    os.environ["LD_LIBRARY_PATH"] = ":".join(ld_paths)
    mesa_override = os.environ.get("MESA_GL_VERSION_OVERRIDE")
    if mesa_override:
        os.environ["MESA_GL_VERSION_OVERRIDE"] = mesa_override
    os.execve(java, [java, *args, main_class, *game_args], os.environ)


if __name__ == "__main__":
    main()
