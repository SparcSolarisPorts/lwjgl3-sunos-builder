# lwjgl3-sunos-builder

LWJGL3 native builder for SPARC Solaris. Release mappings are in
`versions.conf`; snapshots are intentionally not targets.

`AGENTS.TXT` identifies the local source and native inputs. The builder copies
sources into `work/` before applying patches, so local checkouts are not
modified. It uses Solaris `/usr/xpg4/bin/sh` and preserves native symlinks.

```sh
# Prepare patched GLFW in work/ (does not compile it)
./build.sh 1.20.1 glfw

# Stage the Minecraft native set and existing GLFW build binaries
./build.sh 1.20.1 natives existing

# SDL3 Vulkan patches are selected only for 26.3+
./build.sh 26.3 glfw lwjgl3 sdl3
```

Generated binaries are placed under ignored `bin/<version>/`; intermediate
copies are under ignored `work/<version>/`. Set `GLFW_SRC`, `LWJGL_SRC`,
`SDL3_SRC`, `GLFW_BUILD`, `NATIVES_SRC`, or `OUT` to override local paths.
