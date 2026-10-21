# dot-weather

This is the **weather** asset for TMC's **Dot** collection. It is the family's everyday-weather layer: snow, rain, thunderstorms, wind and fog, described per map as a document, so any game gets them by adding a node. The intense events stay in `natural-disasters`.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. These assets are open source under the MIT license.

**Please treat this as partially tested.** The headless suite passes, and the demo has been rendered under a software renderer and looked at, but nothing here has been in front of players yet.

## Use

```gdscript
var weather := DotWeather.new()
add_child(weather)
var res := weather.apply(map_document["weather"])      # a DotResult; a bad document is refused and names the key
weather.lightning.connect(func(strike, level): ...)     # a game may add a sound, a light, a shake
weather.thunder.connect(func(sound, strike, metres, loudness): audio.play(sound, loudness))
weather.ambience_changed.connect(func(ids): ...)        # {"loop": id, "wind": id}: start your own loops

# once a frame, with the camera and the clock every client shares:
weather.advance(delta, camera.global_position, match_time_seconds)
var wind: Vector3 = weather.wind()                      # for foliage, flags, smoke
```

A document (every section optional, unknown keys refused, distances in metres):

```json
{
  "seed": 1234,
  "precipitation": {"kind": "rain", "density": 1.2, "colour": "#c8d8ff", "volumes": [{"min": [-40, 0, -40], "max": [40, 30, 40]}]},
  "fog": {"colour": [0.5, 0.55, 0.62], "start": 8, "end": 120, "max_density": 0.9},
  "wind": {"vector": [3, 0, 1], "gust": 0.8, "gust_period": 9},
  "thunder": {"mean_interval": 14, "chance": 0.8, "centre": [0, 0, 0], "min_distance": 80, "max_distance": 900,
              "height": 220, "flash": {"sky": 1.6, "ambient": 0.8, "duration": 0.45}, "bolt": true},
  "ambience": {"loop": "amb_rain", "wind": "amb_wind", "thunder": ["thunder_a", "thunder_b"]}
}
```

## What it needs

- **dot-core**: required.
- **dot-fx** (API level 5 or newer): optional; draws the precipitation, volumes included.
- **dot-lighting** (API level 6 or newer): optional; writes the fog onto the world's existing environment.

A dedicated server with neither still parses documents, runs the lightning schedule and emits the signals.

## Lightning without a packet

The strikes are a pure function of the document's seed and the shared match time you pass to `advance()`, so every client agrees on when and where, a late joiner sees the same storm, and a replay can seek. Thunder arrives later by distance, per listener. [docs/design.md](docs/design.md#lightning-in-sync-without-networking) says why.

## Accessibility

Flashes can be turned off or scaled to zero (`DotWeatherConfig.allow_flashes`, `flash_scale`), and the fastest storm a document may describe never flashes more than three times in a second.

## Try it

```bash
godot --path . res://examples/weather_demo.tscn -- --mode rain      # snow, rain, fog, flash; keys 1 to 4
godot --headless --path . res://examples/weather_selftest.tscn
```

Screenshots from the demo under xvfb are in `screenshots/`.
