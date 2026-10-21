extends Node

## Exercises dot-weather with no renderer, which nearly all of it survives.
##
## What a headless run can check is the document, the seeded schedule (determinism, spacing,
## the flash-rate guarantee, thunder delay by distance), the signals the node emits, the fog it
## writes and restores, and the flash it applies to an Environment. It cannot check whether any
## of it looks right: render the demo (examples/weather_demo.tscn) and look.
##
## The suite counts sections run to their last line and the checks it made. Checks that need an
## optional addon (dot-fx, dot-lighting) are counted only when it is installed, so the same suite
## passes in a project that has neither.
##
## [codeblock]
## godot --headless --path . res://examples/weather_selftest.tscn
## [/codeblock]

const SECTIONS := 10
## Checks that always run.
const CHECKS_BASE := 114
## Extra checks when dot-fx is installed, and when dot-lighting is.
const CHECKS_FX := 4
const CHECKS_LIGHTING := 2

var _passed := 0
var _failed := 0
var _section_count := 0
var _quiet := false
var _quiet_failures := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run()


func _run() -> void:
	_line("dot-weather self-test (dot-fx %s, dot-lighting %s)" % [
		"installed" if DotWeather.fx_available() else "absent",
		"installed" if DotWeather.lighting_available() else "absent"])
	_line("")

	_test_document()
	_test_handoff()
	_test_schedule()
	_test_thunder()
	_test_flash_envelope()
	_test_wind()
	_test_node_events()
	_test_fog()
	_test_flash_on_environment()
	_test_armed()

	var expected := CHECKS_BASE
	if DotWeather.fx_available():
		expected += CHECKS_FX
	if DotWeather.lighting_available():
		expected += CHECKS_LIGHTING
	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])
	if _section_count != SECTIONS:
		_line("ERROR: %d of %d sections ran." % [_section_count, SECTIONS])
		get_tree().quit(1)
		return
	if _passed + _failed != expected:
		_line("ERROR: %d checks ran, expected %d." % [_passed + _failed, expected])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


# --- fixtures -----------------------------------------------------------------

func _storm(extra: Dictionary = {}) -> Dictionary:
	var d := {
		"seed": 77,
		"precipitation": {"kind": "rain", "density": 1.5, "colour": "#c8d8ff",
			"volumes": [{"min": [-40, 0, -40], "max": [40, 30, 40]}, {"center": [100, 5, 0], "size": [20, 10, 20]}]},
		"fog": {"colour": [0.5, 0.55, 0.62], "start": 8, "end": 120, "max_density": 0.9},
		"wind": {"vector": [3, 0, 1], "gust": 0.8, "gust_period": 9},
		"thunder": {"mean_interval": 10, "chance": 1.0, "centre": [0, 0, 0], "min_distance": 80,
			"max_distance": 800, "height": 220,
			"flash": {"sky": 1.5, "ambient": 0.8, "duration": 0.45}, "bolt": true, "speed_of_sound": 343},
		"ambience": {"loop": "amb_rain", "wind": "amb_wind", "thunder": ["thunder_a", "thunder_b"]},
	}
	d.merge(extra, true)
	return d


func _doc(extra: Dictionary = {}) -> DotWeatherDoc:
	var res := DotWeatherDoc.parse(_storm(extra))
	if not res.ok:
		push_error("fixture refused: " + res.error.message)
		return DotWeatherDoc.new()
	return res.value


func _same_strikes(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if a[i]["slot"] != b[i]["slot"] or a[i]["time"] != b[i]["time"] or a[i]["position"] != b[i]["position"]:
			return false
	return true


# --- 1 ------------------------------------------------------------------------

func _test_document() -> void:
	_section("A weather document parses, round-trips, and refuses what it does not know")

	var res := DotWeatherDoc.parse(_storm())
	_check(res.ok, "the full document parses")
	var d: DotWeatherDoc = res.value
	_check(d.has_precipitation and d.has_fog and d.has_wind and d.has_thunder and d.has_ambience,
		"and every section is marked present")
	_check(d.precip_kind == &"rain" and d.precip_volumes.size() == 2, "precipitation: kind and both volumes (min/max and center/size forms)")
	_check(d.precip_volumes[1] == AABB(Vector3(90, 0, -10), Vector3(20, 10, 20)), "a center+size volume becomes the right box")
	_check(is_equal_approx(d.fog_end, 120.0) and is_equal_approx(d.fog_max_density, 0.9), "fog in metres, with its maximum density")
	_check(d.ambience_thunder.size() == 2 and d.ambience_loop == &"amb_rain", "ambience ids are kept as ids, not sounds")

	var back := DotWeatherDoc.parse(d.to_dict())
	_check(back.ok and (back.value as DotWeatherDoc).to_dict() == d.to_dict(), "to_dict() parses back to the same document")

	var empty := DotWeatherDoc.parse({})
	_check(empty.ok and not (empty.value as DotWeatherDoc).has_thunder and not (empty.value as DotWeatherDoc).has_fog,
		"an empty document is valid and says it has nothing (absent is not zero)")

	# Unknown keys, at every level.
	var levels := [
		["top level", {"wether": 1}],
		["precipitation", {"precipitation": {"kind": "snow", "colour2": 1}}],
		["fog", {"fog": {"distance": 4}}],
		["wind", {"wind": {"speed": 4}}],
		["thunder", {"thunder": {"frequency": 4}}],
		["flash", {"thunder": {"flash": {"brightness": 1}}}],
		["ambience", {"ambience": {"rain": "x"}}],
	]
	for l in levels:
		var r := DotWeatherDoc.parse(l[1])
		_check(not r.ok and "unknown key" in r.error.message, "an unknown key is refused at the %s, naming it" % l[0])

	var bad := [
		["a kind that is neither snow nor rain", {"precipitation": {"kind": "hail"}}],
		["a negative density", {"precipitation": {"kind": "snow", "density": -1}}],
		["an inside-out volume", {"precipitation": {"kind": "snow", "volumes": [{"min": [1, 1, 1], "max": [0, 0, 0]}]}}],
		["a fog end before its start", {"fog": {"start": 50, "end": 10}}],
		["a wind vector of two numbers", {"wind": {"vector": [1, 2]}}],
		["a storm faster than the safe flash rate", {"thunder": {"mean_interval": 1.0}}],
		["a minimum distance beyond the maximum", {"thunder": {"min_distance": 500, "max_distance": 100}}],
		["a non-integer seed", {"seed": 1.5}],
		["a string where a number belongs", {"fog": {"end": "far"}}],
		["a non-id thunder sound", {"ambience": {"thunder": [3]}}],
	]
	for b in bad:
		_check(not DotWeatherDoc.parse(b[1]).ok, "refused: %s" % b[0])


# --- 2 ------------------------------------------------------------------------

func _test_handoff() -> void:
	_section("Precipitation is handed on in the shape dot-fx wants")
	var d := _doc()
	var p := d.precipitation_dict()
	_check(p["kind"] == "rain" and p["volumes"].size() == 2, "the handoff keeps the kind and the volumes")
	_check(p["wind"] == [3.0, 0.0, 1.0], "and folds the steady wind into it")
	_check(_doc({"precipitation": {"kind": "snow"}}).precipitation_dict()["volumes"].is_empty(), "no volumes stays 'everywhere'")
	_check(DotWeatherDoc.new().precipitation_dict().is_empty(), "a document without precipitation hands on nothing")

	if DotWeather.fx_available():
		var script: Script = load("res://addons/dot_fx/core/dot_fx_weather_def.gd")
		var fx_res: DotResult = script.call("parse", p)
		_check(fx_res.ok, "dot-fx accepts the handoff")
		var def: Variant = fx_res.value
		_check(def.volumes.size() == 2 and def.volumes[0] == d.precip_volumes[0], "and reads the same volumes")
		_check(def.wind == Vector3(3, 0, 1) and String(def.kind) == "rain", "and the same wind and kind")
		_check(is_equal_approx(def.density, 1.5) and def.colour.is_equal_approx(d.precip_colour), "and density and colour")


# --- 3 ------------------------------------------------------------------------

func _test_schedule() -> void:
	_section("The lightning schedule is a pure function of seed and time")
	var d := _doc()
	var a := DotWeatherSchedule.strikes_between(d, 0.0, 600.0)
	var b := DotWeatherSchedule.strikes_between(_doc(), 0.0, 600.0)
	_check(a.size() == 60, "chance 1.0 over 600 s at a 10 s interval is 60 strikes (%d)" % a.size())
	_check(_same_strikes(a, b), "two clients parsing the document get the same strikes: slot, time and place")

	var other := DotWeatherSchedule.strikes_between(_doc({"seed": 78}), 0.0, 600.0)
	_check(not _same_strikes(a, other), "a different seed is a different storm")

	# Statelessness: asking about the far future first changes nothing.
	var d2 := _doc()
	var far := DotWeatherSchedule.strike(d2, 9000)
	var first := DotWeatherSchedule.strike(d2, 0)
	_check(first["time"] == a[0]["time"] and far == DotWeatherSchedule.strike(d2, 9000), "slot 9000 can be asked first, and asked twice, with no effect on slot 0")

	# A late joiner or a replay seek gets the same strikes for the same window.
	var whole := DotWeatherSchedule.strikes_between(d, 100.0, 300.0)
	var parts := DotWeatherSchedule.strikes_between(d, 100.0, 217.3)
	parts.append_array(DotWeatherSchedule.strikes_between(d, 217.3, 300.0))
	_check(_same_strikes(whole, parts), "a window equals the concatenation of its halves (late join, seek)")

	var edge: Dictionary = a[3]
	_check(DotWeatherSchedule.strikes_between(d, edge["time"], edge["time"] + 0.001).is_empty(), "a window is open at its start")
	_check(DotWeatherSchedule.strikes_between(d, edge["time"] - 0.001, edge["time"]).size() == 1, "and closed at its end")

	var closest := 1e9
	var in_ring := true
	var in_slot := true
	var all := DotWeatherSchedule.strikes_between(d, 0.0, 6000.0)
	for i in range(all.size()):
		var st: Dictionary = all[i]
		var dist := Vector2(st["position"].x, st["position"].z).length()
		in_ring = in_ring and dist >= 79.9 and dist <= 800.1
		var frac: float = st["time"] / 10.0 - float(st["slot"])
		in_slot = in_slot and frac >= 0.25 - 1e-6 and frac <= 0.75 + 1e-6
		if i > 0:
			closest = minf(closest, st["time"] - all[i - 1]["time"])
	_check(in_ring, "every strike lies in the document's ring of distances")
	_check(in_slot, "and in the middle half of its slot")
	_check(closest >= 5.0 - 1e-6, "so two strikes are never closer than half an interval (closest %.2f s)" % closest)

	var rare := _doc({"thunder": {"mean_interval": 10, "chance": 0.3}})
	var n := DotWeatherSchedule.strikes_between(rare, 0.0, 20000.0).size()
	_check(n > 540 and n < 660, "chance 0.3 over 2000 slots gives about 600 strikes (%d)" % n)
	_check(DotWeatherSchedule.strikes_between(DotWeatherDoc.new(), 0.0, 600.0).is_empty(), "no thunder section, no strikes")
	_check(DotWeatherSchedule.strike(d, -1).is_empty(), "and no slot before time zero")
	var sounds := {}
	for st in all:
		sounds[st["sound"]] = true
	_check(sounds.has(&"thunder_a") and sounds.has(&"thunder_b") and sounds.size() == 2, "each strike picks one of the document's thunder ids, both get used")


# --- 4 ------------------------------------------------------------------------

func _test_thunder() -> void:
	_section("Thunder arrives later by distance, per listener")
	var d := _doc()
	var st: Dictionary = DotWeatherSchedule.strike(d, 5)
	var here := Vector3.ZERO
	var near: Vector3 = st["position"] + Vector3(10, 0, 0)
	var delay_here := DotWeatherSchedule.thunder_delay(d, st, here)
	var delay_near := DotWeatherSchedule.thunder_delay(d, st, near)
	_check(is_equal_approx(delay_here, st["distance"] / 343.0), "delay is distance over the speed of sound")
	_check(delay_near < delay_here, "a listener closer to the strike hears it first")

	var t0: float = st["time"] - 0.1
	var t1: float = st["time"] + delay_here + 0.1
	var heard := DotWeatherSchedule.thunders_between(d, here, t0, t1)
	_check(heard.size() == 1 and absf(heard[0]["delay"] - delay_here) < 1e-6, "the window around flash plus delay holds exactly that thunder")
	_check(DotWeatherSchedule.thunders_between(d, here, t0, st["time"] + delay_here - 0.01).is_empty(), "and none before it arrives")
	_check(DotWeatherSchedule.thunders_between(d, here, st["time"] + delay_here, st["time"] + delay_here + 5.0).is_empty()
		or DotWeatherSchedule.thunders_between(d, here, st["time"] + delay_here, st["time"] + delay_here + 5.0)[0]["slot"] != 5,
		"and not twice")
	# The flash was in an earlier window than the thunder: the look-back finds it.
	var late := DotWeatherSchedule.thunders_between(d, here, st["time"] + delay_here - 0.001, st["time"] + delay_here + 0.001)
	_check(late.size() == 1 and late[0]["slot"] == 5, "a thunder is found even though its flash was seconds earlier")
	var cover := true
	for slot in range(0, 40):
		var s: Dictionary = DotWeatherSchedule.strike(d, slot)
		var ar: float = s["time"] + DotWeatherSchedule.thunder_delay(d, s, Vector3(400, 0, -300))
		cover = cover and DotWeatherSchedule.thunders_between(d, Vector3(400, 0, -300), ar - 0.01, ar + 0.01).size() == 1
	_check(cover, "every one of 40 strikes is heard exactly once by a listener away from the centre")
	_check(DotWeatherSchedule.distance_dim(d, 0.0) == 1.0 and DotWeatherSchedule.distance_dim(d, 5000.0) == 0.2, "loudness falls with distance to a floor of 0.2")


# --- 5 ------------------------------------------------------------------------

func _test_flash_envelope() -> void:
	_section("A flash has an attack, a flicker and an end, and is rate-safe")
	var d := _doc()
	var st: Dictionary = DotWeatherSchedule.strike(d, 4)
	var t: float = st["time"]
	_check(DotWeatherSchedule.flash_envelope(d, st, t - 0.01) == 0.0, "no flash before the strike")
	_check(DotWeatherSchedule.flash_envelope(d, st, t + d.flash_duration + 0.01) == 0.0, "and none after its duration")
	var peak := 0.0
	for i in range(0, 90):
		peak = maxf(peak, DotWeatherSchedule.flash_envelope(d, st, t + i * 0.005))
	_check(peak > 0.4 and peak <= 1.0, "the peak is bright and never above 1 (%.2f)" % peak)
	var e_dip := DotWeatherSchedule.flash_envelope(d, st, t + 0.12)
	var e_flick := DotWeatherSchedule.flash_envelope(d, st, t + 0.16)
	_check(e_flick > e_dip, "a second flicker follows the first (%.2f after %.2f)" % [e_flick, e_dip])
	_check(DotWeatherSchedule.flash_at(d, t + 0.03)["level"] > 0.0 and DotWeatherSchedule.flash_at(d, t + 0.03)["strike"]["slot"] == 4, "flash_at finds the strike behind the brightness")
	_check(DotWeatherSchedule.flash_at(d, t + 0.03, Vector3(5000, 0, 0))["level"] < DotWeatherSchedule.flash_at(d, t + 0.03)["level"], "and dims a flash seen from far away")

	# Photosensitivity: at the shortest allowed interval, count rising edges in every second.
	var fast := _doc({"thunder": {"mean_interval": 3.0, "chance": 1.0}})
	var edges: Array[float] = []
	var prev := 0.0
	var t_s := 0.0
	while t_s < 300.0:
		var lvl: float = DotWeatherSchedule.flash_at(fast, t_s)["level"]
		if lvl > 0.3 and prev <= 0.3:
			edges.append(t_s)
		prev = lvl
		t_s += 0.01
	var worst := 0
	for i in range(edges.size()):
		var k := 0
		for j in range(i, edges.size()):
			if edges[j] - edges[i] < 1.0:
				k += 1
		worst = maxi(worst, k)
	_check(edges.size() > 50 and worst <= 3, "at the fastest storm no second holds more than 3 flashes (worst %d of %d)" % [worst, edges.size()])


# --- 6 ------------------------------------------------------------------------

func _test_wind() -> void:
	_section("Wind is a function of time that other systems can read")
	var d := _doc()
	_check(DotWeatherSchedule.wind_at(d, 12.5) == DotWeatherSchedule.wind_at(_doc(), 12.5), "the same wind at the same time on every client")
	var lo := 1e9
	var hi := 0.0
	var dir_ok := true
	for i in range(0, 2000):
		var w := DotWeatherSchedule.wind_at(d, i * 0.1)
		lo = minf(lo, w.length())
		hi = maxf(hi, w.length())
		dir_ok = dir_ok and w.normalized().is_equal_approx(d.wind_vector.normalized())
	var base := d.wind_vector.length()
	_check(lo >= base - 1e-4, "gusts only add to the wind (lowest %.2f, steady %.2f)" % [lo, base])
	_check(hi > base * 1.3 and hi <= base * (1.0 + d.gust_strength) + 1e-4, "and reach a peak within the document's gust strength (%.2f)" % hi)
	_check(dir_ok, "along the wind's own direction")
	_check(DotWeatherSchedule.wind_at(_doc({"wind": {"vector": [2, 0, 0]}}), 40.0) == Vector3(2, 0, 0), "no gust strength is a steady wind")
	_check(DotWeatherSchedule.wind_at(DotWeatherDoc.new(), 10.0) == Vector3.ZERO, "no wind section is no wind")


# --- 7 ------------------------------------------------------------------------

func _node() -> DotWeather:
	var w := DotWeather.new()
	w.config = DotWeatherConfig.new()
	add_child(w)
	return w


func _test_node_events() -> void:
	_section("The node emits lightning and thunder from the shared time, and nothing from the past")
	var w := _node()
	var flashes: Array = []
	var thunders: Array = []
	var ambience: Array = []
	w.lightning.connect(func(st: Dictionary, _lvl: float) -> void: flashes.append(st["slot"]))
	w.thunder.connect(func(snd: StringName, st: Dictionary, m: float, loud: float) -> void: thunders.append([snd, st["slot"], m, loud]))
	w.ambience_changed.connect(func(ids: Dictionary) -> void: ambience.append(ids))

	_check(w.describe() == "weather: none", "a node with no document says so")
	var res := w.apply(_storm())
	_check(res.ok and ambience.size() == 1 and ambience[0]["loop"] == &"amb_rain", "applying emits the ambience ids for the game to play")
	_check(w.doc != null and w.describe().begins_with("weather: seed 77"), "describe() names the document")

	var d: DotWeatherDoc = w.doc
	var st: Dictionary = DotWeatherSchedule.strike(d, 3)
	var delay := DotWeatherSchedule.thunder_delay(d, st, Vector3.ZERO)
	w.advance(0.016, Vector3.ZERO, st["time"] - 1.0)
	_check(flashes.is_empty() and thunders.is_empty(), "the first frame emits nothing, whatever time it is (a late joiner)")
	w.advance(0.016, Vector3.ZERO, st["time"] - 0.5)
	_check(flashes.is_empty(), "no lightning before the strike")
	w.advance(0.016, Vector3.ZERO, st["time"] + 0.02)
	_check(flashes == [3], "lightning is emitted once, in the frame its time passes")
	_check(thunders.is_empty(), "with no thunder yet")
	w.advance(0.016, Vector3.ZERO, st["time"] + delay - 0.02)
	_check(thunders.is_empty(), "thunder has not arrived just before its delay")
	w.advance(0.016, Vector3.ZERO, st["time"] + delay + 0.02)
	_check(thunders.size() == 1 and thunders[0][1] == 3, "thunder arrives after the delay, once")
	_check(thunders[0][0] in [&"thunder_a", &"thunder_b"] and absf(thunders[0][2] - st["distance"]) < 1e-3 and thunders[0][3] >= 0.2, "with the sound id, the metres and a loudness")
	w.advance(0.016, Vector3.ZERO, st["time"] + delay + 0.04)
	_check(flashes == [3] and thunders.size() == 1, "and a later frame repeats neither")

	var count := flashes.size()
	w.advance(0.016, Vector3.ZERO, 5000.0)
	_check(flashes.size() == count, "a jump of more than the step limit (a seek) replays nothing")
	w.advance(0.016, Vector3.ZERO, 12.0)
	_check(flashes.size() == count, "nor does going backwards")

	# Two clients with their own cameras agree on the flash and disagree on the thunder.
	var a := _node()
	var b := _node()
	a.apply(_storm())
	b.apply(_storm())
	var ta: Array = []
	var tb: Array = []
	a.thunder.connect(func(_s: StringName, _st: Dictionary, _m: float, _l: float) -> void: ta.append(a.current_time()))
	b.thunder.connect(func(_s: StringName, _st: Dictionary, _m: float, _l: float) -> void: tb.append(b.current_time()))
	var pa: Vector3 = st["position"] + Vector3(5, 0, 0)
	var pb: Vector3 = st["position"] + Vector3(600, 0, 0)
	var t: float = st["time"] - 0.3
	while t < st["time"] + 5.0:
		a.advance(0.05, pa, t)
		b.advance(0.05, pb, t)
		t += 0.05
	_check(ta.size() >= 1 and tb.size() >= 1 and ta[0] < tb[0], "the player standing at the strike hears it before the one 600 m away (%.2f s, %.2f s)" % [ta[0] if ta.size() else -1.0, tb[0] if tb.size() else -1.0])

	_check(w.wind().length() > 0.0, "the node reports the wind")
	w.clear()
	_check(w.doc == null and w.wind() == Vector3.ZERO and ambience.back().is_empty(), "clear() removes the document, the wind and tells the game to stop its loops")
	_check(not w.apply({"fog": {"nope": 1}}).ok and w.doc == null, "a bad document is refused and leaves the node as it was")
	_check(not DotWeather.can_render(), "headless: nothing is drawn")
	var h := _node()
	h.apply(_storm())
	_check(h.get_child_count() == 0, "so no precipitation node or bolt is built (the schedule still runs)")
	var own := _node()
	own.apply(_storm())
	own.advance(1.0, Vector3.ZERO)
	own.advance(1.0, Vector3.ZERO)
	_check(is_equal_approx(own.current_time(), 2.0), "with no match time given the node counts its own clock")
	for n in [w, a, b, h, own]:
		n.queue_free()


# --- 8 ------------------------------------------------------------------------

func _env_world() -> Array:
	var host := Node3D.new()
	add_child(host)
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = Sky.new()
	env.ambient_light_energy = 1.0
	env.background_energy_multiplier = 1.0
	env.fog_enabled = true
	env.fog_light_color = Color(1, 0, 0)
	env.fog_depth_begin = 3.0
	env.fog_depth_end = 33.0
	env.fog_density = 0.25
	we.name = "WorldEnvironment"
	we.environment = env
	host.add_child(we)
	return [host, env]


func _count_world_environments(root: Node) -> int:
	var n := 1 if root is WorldEnvironment else 0
	for c in root.get_children():
		n += _count_world_environments(c)
	return n


func _test_fog() -> void:
	_section("Fog is written onto the world's own environment and put back")
	var world := _env_world()
	var host: Node3D = world[0]
	var env: Environment = world[1]
	var w := DotWeather.new()
	w.config = DotWeatherConfig.new()
	w.environment_ref = DotNodeRef.of_path(NodePath("../WorldEnvironment"))
	host.add_child(w)
	_check(w.apply(_storm()).ok, "a document with fog applies")
	w.advance(0.016, Vector3.ZERO, 1.0)
	_check(env.fog_enabled and env.fog_light_color.is_equal_approx(Color(0.5, 0.55, 0.62)), "the fog colour is the document's")
	_check(is_equal_approx(env.fog_depth_begin, 8.0) and is_equal_approx(env.fog_depth_end, 120.0), "and its start and end are in metres, unconverted")
	_check(is_equal_approx(env.fog_density, 0.9) and env.fog_sky_affect == 0.0, "with the document's own maximum density and the sky left alone")
	_check(_count_world_environments(host) == 1, "no second WorldEnvironment was made")

	if DotWeather.lighting_available():
		var plain_env := Environment.new()
		w._apply_fog_plain(plain_env)
		_check(plain_env.fog_depth_end == env.fog_depth_end and plain_env.fog_density == env.fog_density
			and plain_env.fog_light_color == env.fog_light_color and plain_env.fog_depth_begin == env.fog_depth_begin
			and plain_env.fog_mode == env.fog_mode and plain_env.fog_sky_affect == env.fog_sky_affect,
			"the dot-lighting path and the plain fallback write the same fog")
		_check(DotAddonApi.build_level("dot_lighting") >= DotWeather.LIGHTING_LEVEL, "and at an API level that has apply_fog")
	w.clear()
	_check(env.fog_light_color.is_equal_approx(Color(1, 0, 0)) and is_equal_approx(env.fog_depth_end, 33.0) and is_equal_approx(env.fog_density, 0.25),
		"clear() puts the map's own fog back")

	# Fog replaced, then the document replaced: restored once, to the original.
	w.apply(_storm())
	w.advance(0.016, Vector3.ZERO, 1.0)
	w.apply(_storm({"fog": {"colour": [0, 1, 0], "start": 1, "end": 50}}))
	w.advance(0.016, Vector3.ZERO, 1.0)
	_check(is_equal_approx(env.fog_depth_end, 50.0), "a second document replaces the first")
	w.clear()
	_check(is_equal_approx(env.fog_depth_end, 33.0), "and clearing restores the map's fog, not the first document's")

	var plain_world := _env_world()
	var no_fog := DotWeather.new()
	no_fog.config = DotWeatherConfig.new()
	plain_world[0].add_child(no_fog)
	var before_end: float = plain_world[1].fog_depth_end
	no_fog.apply({"thunder": {"mean_interval": 10}})
	no_fog.advance(0.016, Vector3.ZERO, 1.0)
	_check(plain_world[1].fog_depth_end == before_end and plain_world[1].fog_enabled, "a document without fog leaves the map's fog alone")

	# The ref decides, not whichever environment the viewport happens to hold: a decoy world
	# is added first (so it is the active one) and the weather's ref points at the second.
	var decoy := _env_world()
	var target := _env_world()
	var aimed := DotWeather.new()
	aimed.config = DotWeatherConfig.new()
	aimed.environment_ref = DotNodeRef.of_path(NodePath("../WorldEnvironment"))
	target[0].add_child(aimed)
	aimed.apply(_storm())
	aimed.advance(0.016, Vector3.ZERO, 1.0)
	_check(is_equal_approx(target[1].fog_depth_end, 120.0), "environment_ref picks the environment to write")
	_check(is_equal_approx(decoy[1].fog_depth_end, 33.0), "and no other is touched")
	aimed.clear()
	for n in [decoy[0], target[0], plain_world[0], host]:
		n.free()

	var bare := DotWeather.new()
	bare.config = DotWeatherConfig.new()
	add_child(bare)
	bare.apply(_storm())
	bare.advance(0.016, Vector3.ZERO, 1.0)
	_check(_count_world_environments(bare) == 0 and bare.describe().contains("fog pending"), "with no environment anywhere it makes none and says the fog is pending")
	bare.free()


# --- 9 ------------------------------------------------------------------------

func _test_flash_on_environment() -> void:
	_section("A flash brightens the sky and ambient light, then restores them exactly")
	var world := _env_world()
	var env: Environment = world[1]
	var w := DotWeather.new()
	w.config = DotWeatherConfig.new()
	w.environment_ref = DotNodeRef.of_path(NodePath("../WorldEnvironment"))
	world[0].add_child(w)
	w.apply(_storm())
	var d: DotWeatherDoc = w.doc
	var st: Dictionary = DotWeatherSchedule.strike(d, 6)
	var cam: Vector3 = st["position"] + Vector3(30, 0, 0)
	w.advance(0.016, cam, st["time"] - 0.1)
	_check(is_equal_approx(env.ambient_light_energy, 1.0) and w.flash_level() == 0.0, "before the strike nothing is changed")
	w.advance(0.016, cam, st["time"] + 0.03)
	_check(env.ambient_light_energy > 1.0 and env.background_energy_multiplier > 1.0, "at the flash both the ambient light and the sky are brightened")
	_check(w.flash_level() > 0.0 and w.flash_level() <= 1.0, "by the reported level (%.2f)" % w.flash_level())
	w.advance(0.016, cam, st["time"] + 0.03)
	_check(env.ambient_light_energy <= 1.0 + d.flash_ambient + 1e-4, "and no frame stacks on the last: it is the base plus the bump, not the sum of frames")
	w.advance(0.016, cam, st["time"] + 0.8)
	_check(env.ambient_light_energy == 1.0 and env.background_energy_multiplier == 1.0, "after the flash both are exactly what the world had")

	var cfg := DotWeatherConfig.new()
	cfg.allow_flashes = false
	w.apply_config(cfg)
	var fired: Array = []
	w.lightning.connect(func(_s: Dictionary, _l: float) -> void: fired.append(1))
	w.advance(0.016, cam, st["time"] - 0.01)
	w.advance(0.016, cam, st["time"] + 0.03)
	_check(env.ambient_light_energy == 1.0 and w.flash_level() == 0.0, "a player who turned flashes off gets none")
	_check(fired.size() == 1, "while the game still hears the lightning event")
	cfg.allow_flashes = true
	cfg.flash_scale = 0.0
	w.advance(0.016, cam, st["time"] + 0.04)
	_check(env.ambient_light_energy == 1.0, "a flash scale of zero is the same as off")
	cfg.flash_scale = 0.5
	var half_t: float = st["time"] + 0.03
	w.advance(0.016, cam, half_t)
	var half := env.ambient_light_energy - 1.0
	cfg.flash_scale = 1.0
	w.advance(0.016, cam, half_t)
	var full := env.ambient_light_energy - 1.0
	_check(half > 0.0 and absf(half * 2.0 - full) < 1e-4, "half the flash scale is half the bump (%.3f, %.3f)" % [half, full])
	cfg.quality = 0
	w.advance(0.016, cam, half_t)
	_check(env.ambient_light_energy == 1.0, "quality off restores the world at once")
	cfg.quality = 2
	w.advance(0.016, cam, half_t)
	w.clear()
	_check(env.ambient_light_energy == 1.0 and env.background_energy_multiplier == 1.0, "clearing in the middle of a flash restores the world too")

	var geo := DotWeatherBolt.points(d, st, st["position"] + Vector3.UP * 220.0, st["position"])
	_check(geo.size() == 3 and geo[0].size() == DotWeatherBolt.SEGMENTS + 1, "a bolt is a trunk and two branches")
	_check(geo[0][0].is_equal_approx(st["position"] + Vector3.UP * 220.0) and geo[0][DotWeatherBolt.SEGMENTS].is_equal_approx(st["position"]), "from the cloud to the ground point, exactly")
	var geo2 := DotWeatherBolt.points(d, st, st["position"] + Vector3.UP * 220.0, st["position"])
	_check(geo[1] == geo2[1] and geo[0] == geo2[0], "and the same jags on every client")
	var m := DotWeatherBolt.mesh(geo, cam, 1.0)
	_check(m.get_surface_count() == 1, "the ribbon is one surface")
	world[0].free()


# --- 10 -----------------------------------------------------------------------

func _test_armed() -> void:
	_section("The suite is armed: a broken thing fails the checks that guard it")
	var d := _doc()
	var a := DotWeatherSchedule.strikes_between(d, 0.0, 300.0)
	_check(not _same_strikes(a, DotWeatherSchedule.strikes_between(_doc({"seed": 5}), 0.0, 300.0)),
		"the strike comparison tells two different storms apart")
	var broken: Array[Dictionary] = a.duplicate()
	var copy: Dictionary = broken[2].duplicate()
	copy["time"] = float(copy["time"]) + 0.001
	broken[2] = copy
	_check(not _same_strikes(a, broken), "and notices a strike a millisecond off")

	_quiet = true
	_quiet_failures = 0
	_check(DotWeatherDoc.parse({"surprise": 1}).ok, "(deliberately wrong) an unknown key accepted")
	_check(DotWeatherSchedule.strikes_between(d, 0.0, 600.0).size() == 61, "(deliberately wrong) a miscounted schedule")
	var spare := DotWeather.new()
	_check(spare.describe() == "weather: 1", "(deliberately wrong) a wrong description")
	spare.free()
	var caught := _quiet_failures
	_quiet = false
	_check(caught == 3, "the harness caught all %d deliberately wrong claims (%d)" % [3, caught])


# --- harness ------------------------------------------------------------------

func _section(title: String) -> void:
	_section_count += 1
	_line("")
	_line("%d. %s" % [_section_count, title])


func _check(cond: bool, label: String) -> void:
	if _quiet:
		if not cond:
			_quiet_failures += 1
		return
	if cond:
		_passed += 1
		_line("  ok    %s" % label)
	else:
		_failed += 1
		_line("  FAIL  %s" % label)


func _line(text: String) -> void:
	print(text)
