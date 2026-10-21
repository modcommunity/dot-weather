# dot-weather

The family's everyday-weather layer: snow, rain, thunderstorms, wind and fog, described per map as a document, so any game gets them by adding a node. Intense events (a tornado, a flood) stay in [natural-disasters](../natural-disasters), which may later build on this.

Read the family [CLAUDE.md](../../CLAUDE.md) first.

**The distributable is `addons/dot_weather/`.** It requires [dot-core](../dot-core) and nothing else. [dot-fx](../dot-fx) (draws the precipitation) and [dot-lighting](../dot-lighting) (writes the fog) are **optional**: a build with neither still parses documents, runs the lightning schedule, answers `wind()` and emits `lightning` and `thunder`. For local development link all three, gitignored (`ln -s ../../dot-core/addons/dot_core addons/dot_core`, and the same for `dot_fx` and `dot_lighting`).

## Read before

| Read | Before |
| --- | --- |
| [docs/design.md](docs/design.md) | changing anything: why lightning needs no packets, the optional-addon rule, what fog is not allowed to be, the flash-rate guarantee, what is deliberately not here |

## Layout

| Path | What |
| --- | --- |
| `core/dot_weather_doc.gd` | `DotWeatherDoc`: the document; `parse() -> DotResult` (unknown keys refused at every level), `to_dict()`, `precipitation_dict()`, `describe()` |
| `core/dot_weather_schedule.gd` | `DotWeatherSchedule`: pure functions of (seed, time): `strike`, `strikes_between`, `thunders_between`, `flash_at`, `wind_at` |
| `core/dot_weather_config.gd` | `DotWeatherConfig`: quality, density scale, `allow_flashes`, `flash_scale` (a `DotConfig`) |
| `runtime/dot_weather.gd` | `DotWeather`: the node; `apply`, `setup`, `clear`, `advance`, `wind`, `describe`; signals `lightning`, `thunder`, `ambience_changed`, `ambience_inside_changed` |
| `runtime/dot_weather_bolt.gd` | `DotWeatherBolt`: the bolt's polyline and ribbon mesh (pure geometry) |
| `dot_weather_api.gd` | the API level (`DotAddonApi` rule) |
| `examples/weather_selftest.tscn` | the suite |
| `examples/weather_demo.tscn` | snow, rain with lightning, fog, and a held flash (`--mode`, `--shot`) |

Paths except `examples/` are in `addons/dot_weather/`.

## Running and testing

The family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)), then `timeout 120 godot --headless --path . res://examples/weather_selftest.tscn`. The suite counts sections and checks, and the checks that need an optional addon are counted only when it is installed (the same suite passes in a project that has neither: link only dot-core into a scratch project and run it). The last section is the armed one: it makes deliberately wrong claims and asserts the harness caught them. The suite cannot see whether anything looks right: after changing anything that draws, render the demo under xvfb (`--mode snow|rain|fog|flash --shot file.png`) and look.

## Rules that bite

- **Never name a `DotFx*` or `DotLight*` class in a script here.** A named class from an absent addon is a parse error in the whole file. They are reached by path (`load(...)`, `.new()`, `Object.call`) behind `fx_available()` and `lighting_available()` (API levels 5 and 6). [design](docs/design.md#optional-addons-by-path-and-level)
- **Lightning is never sent.** It is a pure function of the document's seed and the shared match time a game passes to `advance()`. Anything that adds state to the schedule (a countdown, a random stream that advances) breaks late join, seeking and agreement. [design](docs/design.md#lightning-in-sync-without-networking)
- **Fog is written onto the existing `Environment` through `DotLightRig.apply_fog`, never a second `WorldEnvironment`**, and the map's own fog is put back by `clear()`. [design](docs/design.md#fog-belongs-to-the-lighting)
- **The shortest storm is 3 s per interval** and a strike sits in the middle half of its slot, so two are at least 1.5 s apart: the three-flashes-a-second guarantee lives in the document's range check and the schedule's placement, and a test counts it. [design](docs/design.md#the-flash-rate-is-guaranteed-by-construction)
- **A flash changes the sky and ambient energy by a bump over a captured base and restores it exactly**; it never accumulates from frame to frame, and `allow_flashes`/`flash_scale` reach zero.
- Call `advance()` yourself; nothing runs in `_process`.
- A newly created node gets an auto name like `@WorldEnvironment@3`, so a `DotNodeRef` path to it needs `name` set first (the suite hit this).

## Open items

- No game uses it yet. Two games carry their own per-zone weather (a tick-driven draw of sky, wind, storm and fog for gameplay grip); that is prior art this does not replace: they decide *what the weather is* in a zone (simulation), this draws *a* weather. Folding them in means a game converting its zone draw into a `DotWeatherDoc` per zone; nightly item `weather-adopt`.
- Gusts reach `wind()` only; dot-fx's precipitation takes one steady wind, so flakes do not yet lean in a gust.
- Not registered in the family yet: `dot-bootstrap/projects.tsv`, `dot-server-deploy` `ADDONS_ALL`, `setup.ps1`, check lists.
