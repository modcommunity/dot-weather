# Design

## What this is, and what it is not

Everyday weather as a document: precipitation, fog, wind, thunder and the sound ids that go with them. A map carries one document; a game adds a `DotWeather` node, applies it and calls `advance()` once a frame.

It is **not** the intense events (those stay in `natural-disasters`, which can later build on this), not the simulation (grip on a wet road, a blown-off hat are the game's, which reads `wind()` and the signals), and not art or sound (it names sound ids and plays none).

## The document

One dictionary, every section optional, unknown keys refused at every level (see `DotWeatherDoc`). A section that is absent means "this map has none", which is not a section of zeros. Distances are metres.

| Section | Becomes |
| --- | --- |
| `precipitation` | handed to dot-fx's `DotFxWeather` (volumes and all), with the steady wind folded in |
| `fog` | written onto the world's `Environment` through dot-lighting |
| `wind` | `DotWeather.wind()` and `DotWeatherSchedule.wind_at()`: a vector plus gusts, for other systems to read |
| `thunder` | the lightning schedule, the flash, an optional bolt, and thunder delayed by distance |
| `ambience` | sound ids, emitted as signals, never played |

The precipitation section is validated by this addon's own parser, which repeats dot-fx's rules instead of calling it, on purpose: a server without dot-fx must accept or refuse exactly what a client with it does, or a map would load on one and not the other. The suite parses the handoff with dot-fx's parser when it is installed, which is what keeps the copy honest.

## Lightning in sync without networking

The obvious design is a server that decides "lightning now" and tells everyone. It costs a message per strike, arrives at a different moment for each client, is simply lost for a client that joins mid-storm, and cannot be scrubbed in a replay or by a spectator.

Here nothing is sent. The strikes are a **pure function of the document's seed and a time every client already shares**, which a game feeds into `advance(delta, camera, match_time)` (the server tick over the tick rate, or dot-match's elapsed time). Each client works out for itself that there is a strike at 41.37 s, 312 m north-east of the centre. Two clients that agree on the time agree on the storm; a late joiner sees the same storm from its first frame; a replay seek is a different `t`.

How it stays a function: time is cut into slots of `mean_interval` seconds. Slot `n` holds at most one strike, present with probability `chance`, placed 25% to 75% of the way through its slot, at an angle and distance from the document's centre. Every draw is an indexed draw of dot-core's `DotRandomStream` (`unit_at(index)`), which advances nothing, so asking about slot 9000 first changes nothing about slot 0. A countdown scheduler ("wait a random time, strike, repeat") cannot be asked about the middle of a match without simulating the start, and it has the family's latch failure: one missed tick and it never fires again. A slot has no state to lose.

The strike has a place in the world, not on the screen, so the same strike is seen from where each player stands. The flash is the same moment for everyone and dims with distance. **Thunder is the flash time plus distance over the speed of sound, per listener**: the player at the strike hears it at once, the one 600 m away two seconds later. `thunders_between(listener, t0, t1)` looks back far enough to find the strikes whose flash was earlier than the window.

What the node does about time: the first `advance` only records it (a late joiner is not handed thirty seconds of thunder), a step of more than `MAX_STEP` (5 s) or backwards (a seek) skips events, and a negative `match_time` means the node's own clock, right for single player and wrong for anything that must agree. The tick rate and float precision of the shared time are the game's: two clients disagreeing by a frame disagree by a frame of flash.

## The flash rate is guaranteed by construction

Lightning is a full-screen brightness change, and the accepted guidance is no more than three general flashes in any one second. The document refuses `mean_interval` under 3 s, and the middle-half placement means consecutive strikes are at least half an interval apart (1.5 s), each with a double flicker 0.14 s after the first. The suite samples the fastest storm over five minutes and counts rising edges in every second. On top of that `DotWeatherConfig.allow_flashes` and `flash_scale` are player settings that reach zero; the `lightning` signal still fires so a game can keep its own feedback.

## Optional addons, by path and level

dot-fx and dot-lighting are optional. A script that names `DotFxWeather` or `DotLightRig` fails to parse in a build without them, and that failure takes the whole file with it. So neither is named: `DotWeather` asks `DotAddonApi.build_level("dot_fx") >= 5` and `("dot_lighting") >= 6`, loads the script by path, and talks to it with `new()`, `call()`, `set()` and `connect()`. This also keeps dot-ci from deriving a hard requirement on them.

Without dot-fx the precipitation is kept in the document and not drawn. Without dot-lighting the fog is written by `_apply_fog_plain`, which sets the same eight `Environment` fields; the suite compares the two paths field by field.

## Fog belongs to the lighting

There is exactly one `WorldEnvironment` in a world and it is the lighting's. Weather therefore never builds one: it writes onto the `Environment` it finds (`environment_ref`, else the viewport's) through `DotLightRig.apply_fog(env, doc, metres_per_unit)`, the same function that writes a map's own fog (added for this, dot-lighting API level 6, and `environment()` now calls it). That keeps one opinion on what the numbers mean: the fog's own maximum density rather than 1.0, the sky left unfogged, depth rather than volumetric.

The map's own fog fields are snapshotted before weather writes and put back by `clear()` or by replacing the document, so weather is something a map has for a while, not a one-way edit. With no environment anywhere the fog waits (and says so in `describe()`); it never creates one.

**Fog is not in the quality tier or the player settings.** It is the world's atmosphere and how far anyone can see, so a setting that turns it off is an advantage and a different match for that player. Quality OFF drops precipitation, flashes and bolts only.

## The flash

A flash adds `level * flash_sky` to `background_energy_multiplier` and `level * flash_ambient` to `ambient_light_energy` over a base captured when the flash begins, and writes the base back when it ends. It is a bump over a base rather than a multiplier of the current value, so a frame that runs twice cannot stack and a day cycle changing the base mid-flash is the only thing it fights (and a flash is under half a second). A visible bolt (a jagged ribbon from the cloud to the strike point, two branches, additive, no fog) is drawn at the HIGH tier on a machine that can render; its shape is deterministic in the seed and the slot, its facing is per client.

## Nothing in `_process`

As with dot-fx: the game calls `advance()`. The node has no `_process`, so a server that wants only the schedule calls it at its own rate and a client calls it from its camera code.

## Things deliberately not here

- **Simulation.** No grip, no damage, no wind force on bodies. `wind()` and the signals are the interface.
- **Sound.** Ids out, a game plays them through dot-audio. The loop's fade near a precipitation volume is `ambience_inside_changed`.
- **Networking of any kind.** That is the point.
- **Gusts in the particles.** dot-fx takes one steady wind. If it grows a per-frame wind uniform this node can feed `wind()` into it.
- **Transitions between weathers** (clear to storm over a minute). A game that wants one applies a sequence of documents or, better, asks for a `blend` field here when two games need it.
- **Dynamic lights.** The flash is ambient and sky, not a light at the bolt; no consumer has asked.
