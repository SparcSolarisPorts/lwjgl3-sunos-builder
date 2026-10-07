# Patch sets

Patches are applied to copied source trees under `work/<version>`; external
checkouts are never modified.

- `glfw/3.6.0/0001-sunos-disable-wayland.patch` disables Wayland by default
  on SunOS while retaining the X11 backend. It is usable with the checked-out
  GLFW CMakeLists.txt because the option context is unchanged.
- `lwjgl3/` is reserved for source-version-specific LWJGL3 patches.
- `sdl3/` is reserved for SDL3 Vulkan patches required by Minecraft 26.3 and
  later.
- jemalloc and other native patches will be added only after their source
  checkouts are available.

The builder intentionally fails when a requested source checkout is missing;
it does not fabricate or silently skip a native build.
