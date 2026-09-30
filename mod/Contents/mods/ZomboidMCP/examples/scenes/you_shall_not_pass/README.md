# You shall not pass (the endgame showcase)

An original fan-made recreation of the bridge scene, built with nothing but the Zomboid MCP: a permanent lava cavern
with a narrow stone bridge one floor up, the grey wizard standing guard, the fire demon waiting in the lava below, and a
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
- **The arena** (`clear_radius` > 0): every square within that many tiles of the hall centre (level `z`) is cleared
  down to its floor (trees, bushes, grass, flowers, boulders, fences, wrecks, furniture: every non-floor object
  except items on the ground and the scene's own blockers) and gets one uniform floor, `arena_floor` (default
  `blends_natural_01_0`, bright sand: it reads apart from the burnt hall, the lava and the stone deck). It runs in
  slices of 200 squares per tick (each slice on the main coroutine through `try`), so radius 40 (about 4 850
  squares) takes about 25 ticks. Only loaded squares can be cleared: the owner (or anybody) must be near; squares
  that were not loaded are counted in the log and the next start finishes them. The arena is **permanent**:
  `restoreArea` never removes floors and a snapshot covers at most 900 squares, so the teardown leaves it (it only
  brings the hall's own margin back from the snapshot). `state.arena_radius` / `state.arena_floor` record it: a
  restart does nothing, a re-run with a bigger radius clears only the new ring, another `arena_floor` re-lays it.
- **The figures**: `ysnp_wizard` and `ysnp_demon` are moving 3D entities (`entity3d_*`), so they can rise, fly and
  fall smoothly; they are re-spawned on every start and re-sent to every joining client by the mod. Both are real
  low-poly 3D meshes (wizard 2.17 tiles tall, about 1.2 players; demon 4.57 tall with a 6.4-tile wingspan). The
  demon stands on the lava two tiles south of the far end (the 3D layer has no depth against the world, so it is
  kept on the camera side of the piers); the wizard is turned 30 degrees east of `face`, the demon 30 degrees west,
  so they half-face each other.
- **New art for a running hall**: `model_upload` the changed ids again (same names: a new generation), then
  re-spawn the figures (`entity3d_spawn` with the ids and positions from `entity3d_list`, or restart the scene:
  a built hall only re-creates lights and figures).

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
3. `scene_start {name: "ysnp", persistent: true, code: <scene.lua>, args: {x, y, z: 0, length: 14, cooldown: 180, clear_radius: 40}}`.
   `scene_logs {name: "ysnp"}` lists every build step; `scene_list` shows `state.built`.
4. Walk onto the bridge: the cutscene. `scene_signal {name: "ysnp", signal: "play"}` runs it on demand.
5. Tuning: the args below.

| arg | default | what |
|---|---|---|
| `x`, `y` | 10 tiles north of the first player | the west end of the bridge deck |
| `z` | 0 | ground level of the hall |
| `length` | 14 | bridge length in tiles (6 and up); the hall is `length + 6` by 9 tiles |
| `cooldown` | 180 | seconds between two cutscenes |
| `face` | 45 | camera-facing rotation of the figures, degrees (wizard `face + 30`, demon `face - 30`) |
| `rails` | true | invisible rails along the deck (`false` leaves the edges open) |
| `level` | 1 | 1: bridge one floor up with stairs; 0: flat fallback (deck on the ground, chasm blocked) |
| `clear_margin` | 6 | vegetation-free ring around the hall (trees would overhang it) |
| `clear_radius` | 0 (off) | the arena: clear and floor every square within this radius of the hall centre (permanent) |
| `arena_floor` | `blends_natural_01_0` | the arena floor tile (sand; `floors_exterior_tilesandstone_01_48` or `blends_street_01_48` are light paving / concrete) |
| `deck_floor` | `floors_exterior_tilesandstone_01_0` | the bridge deck tile |
| `hall_floor` | `floors_burnt_01_0` | the hall floor tile |

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
