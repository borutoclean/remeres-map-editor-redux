# Tibi4 AI Map Tools — Remere's Redux

Experimental port of our earlier Canary Remere's tools to the newer Redux architecture. **Use a backup of your OTBM** and treat the pull request as untested until CI and Windows runtime checks pass.

## Scripts in Scripts menu

- **Gemini AI Map Builder** (`scripts/gemini_map_builder.lua`): Sends a limited list of permitted server item IDs and a compact description of a target map area to the official Gemini API. Checks item validity, coordinates, ground, occupancy and limits; asks confirmation, then applies in one undoable transaction. Defaults to `gemini-2.5-flash`, configurable. API key is separate from Gemini/Antigravity subscriptions and may be billed.
- **Multi-Sprite Structure Composer** (`scripts/structure_composer.lua`): Build templates with up to 220 server item IDs using row-major, column-major, snake, greedy image-border matching, manual relative positions or saved layouts. See actual item sprites on a preview. Supports position transformations, save/load, collision preflight and Ctrl+Z.
- **Sprite ID Inspector** (`scripts/sprite_id_inspector.lua`): Gallery of server item IDs or client appearance IDs; finds server item IDs corresponding to client appearances. Can copy valid server item IDs.
- **AI Mapping Self Test** (`scripts/ai_map_self_test.lua`): Read-only smoke tests of the Lua/native extensions and preview.

## Native Lua Image extensions

Redux already correctly renders a `GameSprite` at its native resolution, including multi-cell transparent images. This port **preserves Redux's rendering implementation** and adds methods without overwriting it:

```lua
Image.composeItems(width, height, {{id = 100, x = 0, y = 0}})
Image.edgeCost(firstServerItemId, secondServerItemId, "right")
Image.autoArrange({100, 101, 102, 103}, 2, 2)
```

These methods need a **new executable compiled from this branch**; installing Lua alone is not sufficient for Structure Composer or the complete Self Test.

### The 46967–47146 experiment

Inclusive interval **46967–47146** contains exactly **180 IDs**. Try 15×12 or 12×15 as provisional grid dimensions. Neither is verified as the correct arrangement.

**IMPORTANT:** A client appearance/sprite ID is not necessarily a placeable **server item ID**. Run Sprite ID Inspector first if item validation fails. The edge matcher is a **greedy heuristic**, not a reliable visual reconstruction system: it only uses directly comparable 32×32 edge pixels and does not deduce semantic structures from the scene. Never infer real dimensions from the numeric range alone.

## Build on Windows

This Redux repository provides `build_windows.bat`. From a checkout of `feat/tibi4-ai-map-tools`, install a compatible Visual Studio toolchain, CMake and vcpkg, then run the batch script. Logs are written to `build.log`. Follow the Redux main README for prerequisites.

Existing builds of Redux lack `Image.composeItems`, `Image.edgeCost`, and `Image.autoArrange`, so they cannot run the new structure preview/composition fully.

## Runtime test checklist

1. Verify that GitHub Actions builds complete. This is a compiler check, not a Windows GUI validation.
2. Open a **copy** of an OTBM with correct Canary client definitions and press **Scripts > AI Mapping Self Test**. Fix any failed checks before proceeding.
3. Run Sprite ID Inspector for a small known range and confirm item/appearance ID mapping.
4. Preview a manual 2×2 or 4×4 structure. Save/load a template, and compare it with actual map tiles.
5. Use an area whose tiles already have ground, with collision blocking enabled, and apply the small layout. Confirm Ctrl+Z undoes the changes.
6. Try the 180-ID range only after the small test works; check both row-major and heuristic previews.
7. Optionally test Gemini generation in a disposable area using your own official Gemini API key. Leave key persistence disabled on shared computers.

No live Windows binary run or Gemini API call was performed while authoring this port. Keep the PR as draft until validated.

## Future work

Real tile overlay preview, richer terrain semantic catalog, item sprite image exports, exact multipart structure identification, and intelligent hunt decoration require additional development and visual verification.
