# You shall not pass (the endgame showcase)

An original fan-made recreation of the bridge scene, built with nothing but the Zomboid MCP: a permanent lava cavern
with a narrow stone bridge one floor up, the grey wizard standing guard, the fire demon waiting in the deep, and a
cutscene that plays whenever a player steps onto the bridge. Everything in this folder is generated (`make_art.py`),
no film or game assets. It runs as one persistent scene (`scene.lua`, the scene SDK in `docs/SCENES.md`) plus eight
runtime 3D models.

| file | what |
|---|---|
| `scene.lua` | the scene: builds the hall once (idempotent, recorded in `state`), re-creates lights and the two figures on every start, runs the cutscene on a trigger, tears everything down on request |
| `make_art.py` | writes `art/`: `.x` meshes (bridge pier + broken pier, rock pillar, stalagmite, lava slab, demon, wizard, wizard with the staff raised) and their painted PNG textures |
| `art/` | the generated meshes and textures (committed, so no Pillow is needed to run the scene) |

## What is built (all saved, transmitted world objects)

- **The hall**: a rectangle of `floors_burnt_01_0` floors, invisible `wall_n` / `wall_w` blockers around it (players,
  zombies and line of sight respect them), rock pillars (`ysnp_rock`, solid) outside the walls, five stalagmites, and
  twelve `ysnp_lava` slabs (flat 3×3-tile models) over the lava part with eight red lights.
- **The bridge**: real floor tiles (`floors_exterior_tilesandstone_01_0`) one level up on ten stone piers
  (`ysnp_pier`, 3 units tall = one floor), reached by north-facing stairs (`fixtures_stairs_01_8/9/10`) at both ends
  on the two landings, with invisible rails (`wall_n` / `wall_w` on the deck squares). `args.rails = false` leaves the
  edges open: falling lands you in the lava lake one floor down, which is walkable, so nobody gets stuck.
  `args.level = 0` is the flat fallback (deck on the ground, chasm squares `solidtrans`).
- **The figures**: `ysnp_wizard` and `ysnp_demon` are moving 3D entities (`entity3d_*`), so they can rise, fly and
  fall smoothly; they are re-spawned on every start and re-sent to every joining client by the mod.

## Running it

1. Upload the models once (they persist across restarts and are streamed to every client on join):

   ```
   for id in pier pier_broken rock stalagmite lava demon wizard wizard_up:
     model_upload {id: "ysnp_<id>", mesh_path: "<mod>/examples/scenes/you_shall_not_pass/art/ysnp_<id>.x",
                   png_path: "<mod>/examples/scenes/you_shall_not_pass/art/ysnp_<texture>.png", scale: 1}
   ```
   Textures: pier and pier_broken use `ysnp_stone.png`, rock and stalagmite `ysnp_rock.png`, lava `ysnp_lava.png`,
   the demon `ysnp_demon.png`, the wizards `ysnp_wizard.png` / `ysnp_wizard_up.png`.
   `events_poll {kinds: ["client_model"]}` shows each client's registration.
2. Pick an isolated, flat, uninhabited spot with the owner (the hall is 20×9 tiles plus a ring of pillars; the
   bridge runs west to east; `x, y` is the west end of the deck). Stand near it so the squares are loaded.
3. `scene_start {name: "ysnp", persistent: true, code: <scene.lua>, args: {x, y, z: 0, length: 14, cooldown: 180}}`.
   `scene_logs {name: "ysnp"}` lists every build step; `scene_list` shows `state.built`.
4. Walk onto the bridge: the cutscene. `scene_signal {name: "ysnp", signal: "play"}` runs it on demand.
5. Tuning: `args.face` rotates the flat figures towards the camera (default 45), `deck_floor` / `hall_floor` change
   the tiles, `length` the span (6 and up).

The installation is permanent: `scene_stop` only stops the ambience and the trigger (the world objects and the
models stay; `scene_start` again picks the built state up). `scene_signal {signal: "teardown"}` removes the models,
blockers, deck, stairs and rails and restores the original area from the snapshot taken on the first run.

## The cutscene (about 40 s)

Letterbox bars, thunder, a red glow: the demon rises out of the lava at the east end and flies at the wizard
("You cannot pass."); the wizard raises the staff, two white flashes and lightning, the title
"YOU SHALL NOT PASS!" over the bridge; the piers under the demon crack (broken-pier models), the demon falls
back into the deep and vanishes in embers; the staff comes down, the piers are whole again, the demon returns
to its place in the lava. Sounds are vanilla (`Thunder`, `ZombieThumpGeneric`). Verified offline in
`tests/sim/test_scenes.py`; the live picture (model facing, deck floor tile, pier height) is tuned with `args`.
