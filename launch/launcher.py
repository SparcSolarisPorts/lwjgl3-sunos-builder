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
FABRIC_DOWNLOAD_HOSTS = {"maven.fabricmc.net"}
DEFAULT_LIBRARY_PATH = "/usr/lib/64:/usr/lib/sparcv9:/usr/lib/mesa/sparcv9:/usr/lib/GL/sparcv9"


def fail(message):
    print(f"launcher: error: {message}", file=sys.stderr)
    raise SystemExit(1)


def runtime_environment(native_dir, source=None):
    env = dict(os.environ if source is None else source)
    ld_paths = [str(native_dir), *DEFAULT_LIBRARY_PATH.split(":"),
                *[p for p in env.get("SOLARIS_LIBRARY_PATH", "").split(":") if p]]
    if env.get("MESA_LIBRARY_PATH"):
        ld_paths.append(env["MESA_LIBRARY_PATH"])
    if env.get("VULKAN_LIBRARY_PATH"):
        ld_paths.append(env["VULKAN_LIBRARY_PATH"])
    if env.get("LD_LIBRARY_PATH"):
        ld_paths.append(env["LD_LIBRARY_PATH"])
    if env.get("LD_LIBRARY_PATH_64"):
        ld_paths.append(env["LD_LIBRARY_PATH_64"])
    env["LD_LIBRARY_PATH"] = ":".join(ld_paths)
    machine = platform.machine().lower()
    is_sparcv9 = "sparcv9" in machine
    is_solaris_sparc = platform.system() == "SunOS" and machine in {"sun4u", "sun4v"}
    if env.get("LD_LIBRARY_PATH_64") or is_sparcv9 or is_solaris_sparc:
        env["LD_LIBRARY_PATH_64"] = ":".join(ld_paths)
    return env


def vulkan_jvm_args(source=None):
    env = os.environ if source is None else source
    library_name = env.get("MC_VULKAN_LIBRARY_NAME")
    return [f"-Dorg.lwjgl.vulkan.libname={library_name}"] if library_name else []


def log_vulkan_configuration(env):
    for name in ("VULKAN_LIBRARY_PATH", "VK_DRIVER_FILES", "VK_ICD_FILENAMES", "MC_VULKAN_LIBRARY_NAME"):
        value = env.get(name)
        if value:
            print(f"launcher: {name}={value}", file=sys.stderr)
        else:
            print(f"launcher: {name} is not set", file=sys.stderr)


def validate_url(url, fabric=False):
    parsed = urllib.parse.urlparse(url)
    hosts = OFFICIAL_DOWNLOAD_HOSTS | (FABRIC_DOWNLOAD_HOSTS if fabric else set())
    if (parsed.scheme != "https" or parsed.hostname not in hosts or
            parsed.username or parsed.password or parsed.port not in (None, 443)):
        raise ValueError(f"untrusted {'Fabric or Mojang' if fabric else 'Mojang'} download URL: {url}")
    return url


def fetch_bytes(url, fabric=False):
    validate_url(url, fabric=fabric)
    request = urllib.request.Request(url, headers={"User-Agent": "lwjgl3-sunos-builder/1.0"})
    with urllib.request.urlopen(request, timeout=30) as response:
        final_url = response.geturl()
        validate_url(final_url, fabric=fabric)
        return response.read()


def fetch_json(url, fabric=False):
    return json.loads(fetch_bytes(url, fabric=fabric).decode("utf-8"))


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


def download_file(url, destination, expected_size=None, expected_sha1=None, fabric=False):
    validate_url(url, fabric=fabric)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_file() and valid_payload(destination, expected_size, expected_sha1):
        return destination
    fd, temp_name = tempfile.mkstemp(prefix=f".{destination.name}.", suffix=".part", dir=destination.parent)
    os.close(fd)
    temporary = pathlib.Path(temp_name)
    try:
        request = urllib.request.Request(url, headers={"User-Agent": "lwjgl3-sunos-builder/1.0"})
        with urllib.request.urlopen(request, timeout=60) as response, temporary.open("wb") as output:
            validate_url(response.geturl(), fabric=fabric)
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
    os_name = "solaris"
    arch = platform.machine().lower()
    for rule in rules:
        test = rule.get("os", {})
        match = test.get("name", os_name) == os_name
        if "arch" in test:
            expected = test["arch"]
            match = match and ((expected == "x86" and arch in ("i386", "i486", "i586", "i686")) or
                               (expected == "x86_64" and arch in ("x86_64", "amd64")) or expected == arch)
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
    value = entry.get("value", entry.get("values", []))
    return value if isinstance(value, list) else [value]


def artifact_path(library):
    downloads = library.get("downloads", {})
    artifact = downloads.get("artifact") or library.get("artifact")
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
    if isinstance(asset_index, str):
        asset_index = {"id": asset_index, "url": f"https://piston-meta.mojang.com/assets/{asset_index}.json"}
    index_id = asset_index.get("id")
    index_url = asset_index.get("url")
    if not index_id or not index_url:
        fail("assetIndex metadata is incomplete")
    try:
        index_path = safe_destination(mc_home, f"assets/indexes/{index_id}.json")
        if not (index_path.is_file() and valid_payload(index_path, asset_index.get("size"), asset_index.get("sha1"))):
            download_file(index_url, index_path, asset_index.get("size"), asset_index.get("sha1"))
        index = json.loads(index_path.read_text(encoding="utf-8"))
        for obj in index.get("objects", {}).values():
            digest = obj.get("hash", "")
            if not re.fullmatch(r"[0-9a-fA-F]{40}", digest):
                raise ValueError("asset index contains an invalid SHA-1")
            rel = f"assets/objects/{digest[:2].lower()}/{digest.lower()}"
            path = safe_destination(mc_home, rel)
            if not valid_payload(path, obj.get("size"), digest):
                download_file(f"{ASSET_OBJECT_URL}/{digest[:2].lower()}/{digest.lower()}", path, obj.get("size"), digest)
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
        fail(f"could not download/verify Minecraft assets: {exc}")


def substitute(value, values):
    env_names = {"auth_uuid": "MC_UUID", "auth_access_token": "MC_ACCESS_TOKEN", "clientid": "MC_CLIENT_ID", "auth_xuid": "MC_XUID", "resolution_width": "MC_RESOLUTION_WIDTH", "resolution_height": "MC_RESOLUTION_HEIGHT", "quickPlayPath": "MC_QUICKPLAY_PATH", "quickPlaySingleplayer": "MC_QUICKPLAY_SINGLEPLAYER", "quickPlayMultiplayer": "MC_QUICKPLAY_MULTIPLAYER", "quickPlayRealms": "MC_QUICKPLAY_REALMS"}
    def replace(match):
        key = match.group(1)
        if key not in values or values[key] is None:
            fail(f"Minecraft metadata requires ${{{key}}}; set {env_names.get(key, 'a compatible launcher')}")
        return str(values[key])
    return re.sub(r"\$\{([^}]+)\}", replace, value)


def resolve_local_profile(mc_home, specification):
    if not specification:
        fail("Fabric profile is required")
    candidate = pathlib.Path(specification).expanduser()
    if candidate.is_file():
        return candidate.resolve()
    if not re.fullmatch(r"[A-Za-z0-9._-]+", specification):
        fail(f"invalid local Fabric profile ID: {specification}")
    path = mc_home / "versions" / specification / f"{specification}.json"
    if not path.is_file():
        fail(f"Fabric profile not found: {path}")
    return path.resolve()


def read_local_profile(mc_home, specification):
    path = resolve_local_profile(mc_home, specification)
    try:
        return json.loads(path.read_text(encoding="utf-8")), path
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read Fabric profile {path}: {exc}")


def metadata_asset_id(metadata):
    asset_index = metadata.get("assetIndex")
    if isinstance(asset_index, dict):
        return asset_index.get("id")
    return metadata.get("assets")


def lwjgl_versions(metadata):
    result = {}
    for library in metadata.get("libraries", []):
        parts = library.get("name", "").split(":")
        if len(parts) >= 3 and parts[0] == "org.lwjgl":
            result[parts[1]] = parts[2]
    return result


def validate_fabric_profile(base_metadata, profile):
    base_client = base_metadata.get("downloads", {}).get("client", {})
    profile_client = profile.get("downloads", {}).get("client", {})
    if base_client and profile_client:
        for key in ("sha1", "url"):
            if base_client.get(key) and profile_client.get(key) and base_client[key] != profile_client[key]:
                raise ValueError(f"Fabric profile conflicts with base client {key}")
    base_assets = metadata_asset_id(base_metadata)
    profile_assets = metadata_asset_id(profile)
    if base_assets and profile_assets and base_assets != profile_assets:
        raise ValueError(f"Fabric profile asset index {profile_assets} conflicts with base {base_assets}")
    base_lwjgl = lwjgl_versions(base_metadata)
    for name, version in lwjgl_versions(profile).items():
        if name in base_lwjgl and base_lwjgl[name] != version:
            raise ValueError(f"Fabric profile LWJGL {name}:{version} conflicts with base {name}:{base_lwjgl[name]}")


def profile_arguments(metadata, key):
    arguments = metadata.get("arguments", {})
    entries = list(arguments.get(key, []))
    if key == "jvm":
        entries += arguments.get("default-user-jvm", [])
        entries += arguments.get("default_user_jvm", [])
    result = []
    for entry in entries:
        result.extend(expand_entry(entry))
    return result


def ensure_launcher_profile(metadata_home, game_dir, version, profile_name):
    """Create installer-compatible local launcher profile metadata if absent."""
    profile_name = re.sub(r"[^A-Za-z0-9._-]+", "-", profile_name).strip("-") or version
    data = {
        "profiles": {
            profile_name: {
                "name": profile_name,
                "type": "custom",
                "lastVersionId": version,
                "gameDir": str(game_dir),
            }
        },
        "selectedProfile": profile_name,
        "version": 3,
    }
    game_dir.mkdir(parents=True, exist_ok=True)
    paths = [metadata_home / "launcher_profile.json", metadata_home / "launcher_profiles.json"]
    for path in paths:
        if path.exists():
            continue
        temporary = path.with_name(f".{path.name}.tmp")
        try:
            temporary.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            os.replace(temporary, path)
        finally:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass
    return paths[0]


def combined_library_metadata(chain, profiles):
    libraries = []
    seen = set()
    for item, _ in chain:
        for library in item.get("libraries", []):
            key = library.get("name", "") or artifact_path(library)
            if key not in seen:
                seen.add(key)
                libraries.append((False, library))
    for profile in profiles:
        for library in profile.get("libraries", []):
            key = library.get("name", "") or artifact_path(library)
            if key not in seen:
                seen.add(key)
                libraries.append((True, library))
    return libraries


def launch_configuration(version, fabric_profiles=None):
    fabric_profiles = fabric_profiles or []
    repo = pathlib.Path(__file__).resolve().parent.parent
    default_mc = pathlib.Path.home() / ".minecraft"
    mac_mc = pathlib.Path.home() / "Library" / "Application Support" / "minecraft"
    mc_home = pathlib.Path(os.environ.get("MINECRAFT_HOME", mac_mc if mac_mc.is_dir() else default_mc)).expanduser().resolve()
    native_dir = pathlib.Path(os.environ.get("MC_NATIVE_DIR", repo / "bin" / version)).expanduser().resolve()
    if not native_dir.is_dir():
        fail(f"native directory not found: {native_dir}; build this release first")
    chain = metadata_chain(mc_home, version)
    effective = {}
    for item, _ in chain:
        effective.update(item)
    profiles = []
    for specification in fabric_profiles:
        profile, path = read_local_profile(mc_home, specification)
        try:
            validate_fabric_profile(effective, profile)
        except ValueError as exc:
            fail(f"incompatible Fabric profile {path}: {exc}")
        profiles.append(profile)
    fabric = bool(profiles)
    profile_name = profiles[-1].get("id", version) if fabric else version
    game_dir = pathlib.Path(os.environ.get("MC_GAME_DIR", default_mc if fabric else mc_home)).expanduser().resolve()
    # Fabric Installer expects this file in the Minecraft metadata home.  Create
    # it for vanilla launches too, since the normal release wrapper may be the
    # first launcher command run on a fresh Solaris installation.
    ensure_launcher_profile(mc_home, game_dir, version, profile_name)
    if fabric:
        (game_dir / "mods").mkdir(parents=True, exist_ok=True)
        extraction_dir = game_dir / ".solarislwjgl" / "natives" / profile_name
        for name in ("java", "jna", "lwjgl", "netty"):
            (extraction_dir / name).mkdir(parents=True, exist_ok=True)
    else:
        extraction_dir = native_dir
    client_info = effective.get("downloads", {}).get("client")
    if not client_info or not client_info.get("url"):
        fail(f"client download metadata missing for {version}")
    try:
        client_rel = client_info.get("path") or f"versions/{version}/{version}.jar"
        client = safe_destination(mc_home, client_rel)
        download_file(client_info["url"], client, client_info.get("size"), client_info.get("sha1"), fabric=fabric)
        acquire_assets(mc_home, effective.get("assetIndex"))
    except SystemExit:
        raise
    except (OSError, ValueError, KeyError, TypeError) as exc:
        fail(f"could not obtain Minecraft files for {version}: {exc}")
    classpath = []
    for is_fabric, library in combined_library_metadata(chain, profiles):
        if not rules_allow(library.get("rules", [])):
            continue
        name = library.get("name", "")
        parts = name.split(":")
        if len(parts) > 3 and parts[3].startswith("natives-"):
            continue
        artifact = library.get("downloads", {}).get("artifact") or library.get("artifact") or {}
        rel = artifact_path(library)
        if not rel:
            continue
        try:
            jar = safe_destination(mc_home, f"libraries/{rel}")
            url = artifact.get("url")
            if not url:
                base = library.get("url") or DEFAULT_LIBRARY_URL
                url = urllib.parse.urljoin(base.rstrip("/") + "/", rel)
            download_file(url, jar, artifact.get("size"), artifact.get("sha1"), fabric=fabric and is_fabric)
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
    main_class = profiles[-1].get("mainClass", effective.get("mainClass")) if fabric else effective.get("mainClass")
    if not main_class:
        fail(f"mainClass is missing from metadata for {version}")
    args_source = profiles[-1] if fabric else effective
    jvm = profile_arguments(effective, "jvm")
    game = profile_arguments(args_source, "game")
    for profile in profiles:
        jvm.extend(profile_arguments(profile, "jvm"))
    if not game and effective.get("minecraftArguments"):
        game = shlex.split(effective["minecraftArguments"])
    if not jvm and not game:
        fail(f"no supported game arguments in metadata for {version}")
    values = {
        "auth_player_name": os.environ.get("MC_USERNAME", "Player"), "version_name": profile_name,
        "game_directory": str(game_dir), "assets_root": os.environ.get("MC_ASSETS_DIR", str(mc_home / "assets")),
        "assets_index_name": metadata_asset_id(effective), "auth_uuid": os.environ.get("MC_UUID"),
        "auth_access_token": os.environ.get("MC_ACCESS_TOKEN"), "clientid": os.environ.get("MC_CLIENT_ID"),
        "auth_xuid": os.environ.get("MC_XUID", ""), "user_type": os.environ.get("MC_USER_TYPE", "msa"),
        "version_type": os.environ.get("MC_VERSION_TYPE", "release"), "classpath": cp,
        "natives_directory": str(extraction_dir), "launcher_name": os.environ.get("MC_LAUNCHER_NAME", "SolarisSPARC"),
        "launcher_version": os.environ.get("MC_LAUNCHER_VERSION", "1"), "resolution_width": os.environ.get("MC_RESOLUTION_WIDTH"),
        "resolution_height": os.environ.get("MC_RESOLUTION_HEIGHT"), "quickPlayPath": os.environ.get("MC_QUICKPLAY_PATH"),
        "quickPlaySingleplayer": os.environ.get("MC_QUICKPLAY_SINGLEPLAYER"), "quickPlayMultiplayer": os.environ.get("MC_QUICKPLAY_MULTIPLAYER"),
        "quickPlayRealms": os.environ.get("MC_QUICKPLAY_REALMS"),
    }
    args = []
    skip_next = False
    for raw in jvm:
        if skip_next:
            skip_next = False
            continue
        if raw in ("-cp", "-classpath"):
            skip_next = True
            continue
        expanded = substitute(raw, values)
        if expanded.startswith(("-Djava.library.path=", "-Dorg.lwjgl.librarypath=")):
            continue
        args.append(expanded)
    args += [f"-Djava.library.path={native_dir}", f"-Dorg.lwjgl.librarypath={native_dir}", *vulkan_jvm_args(), "-cp", cp]
    game_args = [substitute(arg, values) for arg in game]
    return {"mc_home": mc_home, "native_dir": native_dir, "game_dir": game_dir, "extraction_dir": extraction_dir,
            "client": client, "classpath": classpath, "cp": cp, "main_class": main_class, "args": args,
            "game_args": game_args, "required_java": effective.get("javaVersion", {}).get("majorVersion"),
            "profile_name": profile_name, "fabric": fabric}


def parse_fabric_cli(argv):
    if not argv or argv[0] != "--fabric":
        if len(argv) != 1:
            fail("usage: launch-<version>.sh")
        return argv[0], []
    options = {}
    i = 1
    while i < len(argv):
        if argv[i] in ("--base-version", "--fabric-profile", "--loader-profile", "--profile"):
            if i + 1 >= len(argv):
                fail(f"missing value for {argv[i]}")
            options[argv[i]] = argv[i + 1]
            i += 2
        else:
            fail(f"unknown Fabric option: {argv[i]}")
    version = options.get("--base-version")
    profiles = [item for item in (options.get("--fabric-profile"), options.get("--loader-profile") or options.get("--profile")) if item]
    if not version or not profiles:
        fail("usage: launcher.py --fabric --base-version VERSION --loader-profile PROFILE")
    return version, profiles


def vanilla_main():
    if len(sys.argv) != 2:
        fail("usage: launch-<version>.sh")
    version = sys.argv[1]
    configuration = launch_configuration(version, [])
    java_home = pathlib.Path(os.environ.get("JAVA_HOME", "")).expanduser() if os.environ.get("JAVA_HOME") else None
    java = str(java_home / "bin" / "java") if java_home else shutil.which("java")
    if not java or not os.access(java, os.X_OK):
        fail("Java executable not found; set JAVA_HOME to a supported Solaris JDK")
    required_java = configuration["required_java"]
    if required_java:
        try:
            detected = subprocess.check_output([java, "-version"], stderr=subprocess.STDOUT, text=True)
            match = re.search(r'version "(?:1\\.)?(\\d+)', detected) or re.search(r'openjdk (\\d+)', detected)
            if match and int(match.group(1)) < int(required_java):
                fail(f"Minecraft {version} requires Java {required_java} or newer")
        except (OSError, subprocess.CalledProcessError):
            fail(f"cannot determine Java version from {java}")
    print(f"launcher: Minecraft {version}, Java {required_java or 'unspecified'}, natives={configuration['native_dir']}", file=sys.stderr)
    print(f"launcher: classpath contains {len(configuration['classpath'])} jars; credentials are not logged", file=sys.stderr)
    runtime_env = runtime_environment(configuration["native_dir"])
    log_vulkan_configuration(runtime_env)
    os.execve(java, [java, *configuration["args"], configuration["main_class"], *configuration["game_args"]], runtime_env)


def fabric_main():
    version, profiles = parse_fabric_cli(sys.argv[1:])
    configuration = launch_configuration(version, profiles)
    java_home = pathlib.Path(os.environ.get("JAVA_HOME", "")).expanduser() if os.environ.get("JAVA_HOME") else None
    java = str(java_home / "bin" / "java") if java_home else shutil.which("java")
    if not java or not os.access(java, os.X_OK):
        fail("Java executable not found; set JAVA_HOME to a supported Solaris JDK")
    required_java = configuration["required_java"]
    if required_java:
        try:
            detected = subprocess.check_output([java, "-version"], stderr=subprocess.STDOUT, text=True)
            match = re.search(r'version "(?:1\\.)?(\\d+)', detected) or re.search(r'openjdk (\\d+)', detected)
            if match and int(match.group(1)) < int(required_java):
                fail(f"Minecraft {version} requires Java {required_java} or newer")
        except (OSError, subprocess.CalledProcessError):
            fail(f"cannot determine Java version from {java}")
    print(f"launcher: Minecraft {version}{' with Fabric ' + configuration['profile_name'] if configuration['fabric'] else ''}, Java {required_java or 'unspecified'}, natives={configuration['native_dir']}", file=sys.stderr)
    print(f"launcher: classpath contains {len(configuration['classpath'])} jars; credentials are not logged", file=sys.stderr)
    runtime_env = runtime_environment(configuration["native_dir"])
    log_vulkan_configuration(runtime_env)
    os.execve(java, [java, *configuration["args"], configuration["main_class"], *configuration["game_args"]], runtime_env)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--fabric":
        fabric_main()
    else:
        vanilla_main()
