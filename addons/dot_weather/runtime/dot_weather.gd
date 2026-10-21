class_name DotWeather
extends Node3D

## A map's everyday weather, from a [DotWeatherDoc]: add the node, [method apply] the document,
## call [method advance] once a frame.
##
## [codeblock]
## var w := DotWeather.new()
## add_child(w)
## var res := w.apply(map_document["weather"])        # a DotResult; a bad document leaves it off
## w.lightning.connect(func(strike, level): ...)       # a game may add a light, a sound, a shake
## w.thunder.connect(func(sound, strike, metres, loudness): audio.play(sound, loudness))
## # once a frame, with the camera and the clock every client shares:
## w.advance(delta, camera.global_position, match_time_seconds)
## [/codeblock]
##
## [b]Precipitation is dot-fx's, fog is dot-lighting's, and both are optional.[/b] When dot-fx is
## in the build the precipitation section is handed to its weather node (volumes and all); when
## dot-lighting is in the build the fog is written onto the world's existing [Environment] by
## the same code that writes a map's lighting, never a second [WorldEnvironment]. Neither is
## named in this file, so a headless server with neither still parses documents, runs the
## schedule, answers [method wind] and emits [signal lightning] and [signal thunder]. The
## addons are reached by path and API level ([method fx_available], [method lighting_available]).
##
## [b]Lightning is not networked.[/b] [method advance] takes the shared match time, and the strikes
## are a function of the document's seed and that time ([DotWeatherSchedule]). Pass a negative
## [param match_time] (the default) and the node counts its own clock from zero, which is right
## for a single-player game and wrong for anything that must agree.
##
## [b]Nothing runs in [code]_process[/code][/b]: the game calls [method advance], as with dot-fx.

const CHANNEL := "weather"

## OFF draws nothing (no precipitation, flash or bolt) but the schedule, wind and signals run.
enum Quality { OFF, LOW, HIGH }

## Fog is applied from this alone when dot-lighting is absent; the path of the optional rig.
const _FX_SCRIPT := "res://addons/dot_fx/runtime/dot_fx_weather.gd"
const _LIGHT_RIG := "res://addons/dot_lighting/runtime/dot_light_rig.gd"
const _LIGHT_DOC := "res://addons/dot_lighting/core/dot_light_document.gd"

## The API levels of the optional addons this needs (what introduced what is used).
const FX_LEVEL := 5
const LIGHTING_LEVEL := 6

## A time step larger than this (a seek, a pause, a late join) skips events rather than replaying
## them: thirty seconds of thunder in one frame is not a storm.
const MAX_STEP := 5.0

## Emitted once at the moment a strike's flash begins, whatever the quality or accessibility
## settings (a game may still want the event). [param strike] is a [DotWeatherSchedule] strike.
signal lightning(strike: Dictionary, level: float)

## Emitted when a strike's thunder reaches the camera: flash time plus distance over the speed of
## sound. [param sound] is one of the document's thunder ids ([code]&""[/code] if none),
## [param loudness] is 0.2 to 1 by distance. The game plays it through dot-audio.
signal thunder(sound: StringName, strike: Dictionary, metres: float, loudness: float)

## Emitted when a document is applied or cleared: [code]{"loop": id, "wind": id}[/code] (empty
## strings for none, an empty dictionary when cleared). The game starts or stops its own loops.
signal ambience_changed(ids: Dictionary)

## Forwarded from dot-fx when its weather node says the camera entered or left a precipitation
## volume: the moment to fade the ambience loop.
signal ambience_inside_changed(inside: bool)

## The world's [WorldEnvironment]. Empty finds the viewport's own environment.
@export var environment_ref: DotNodeRef = null

## The camera [method advance_with_camera] follows.
@export var camera_ref: DotNodeRef = null

## Quality and accessibility. A game assigns its own, or lets [method apply_config] do it.
@export var config: DotWeatherConfig = DotWeatherConfig.new()

var doc: DotWeatherDoc = null

var _fx: Node3D = null
var _fx_quality: int = -1
var _fx_density: float = -1.0
var _clock: float = 0.0
var _last_t: float = 0.0
var _have_t: bool = false
var _wind: Vector3 = Vector3.ZERO
var _time: float = 0.0

var _env: Environment = null
var _fog_dirty: bool = false
var _fog_saved: Dictionary = {}
var _env_warned: bool = false
var _ref_warned: bool = false

var _flashing: bool = false
var _flash_base: Dictionary = {}
var _flash_level: float = 0.0
var _bolt: MeshInstance3D = null
var _bolt_slot: int = -1


## Whether dot-fx is in this build at a level that has the weather node.
static func fx_available() -> bool:
	return DotAddonApi.build_level("dot_fx") >= FX_LEVEL


## Whether dot-lighting is in this build at a level that can write fog onto an environment.
static func lighting_available() -> bool:
	return DotAddonApi.build_level("dot_lighting") >= LIGHTING_LEVEL


## Whether this process can draw. False on a dedicated server or any headless run.
static func can_render() -> bool:
	return not DotPlatform.is_headless()


## Takes the quality tier and accessibility switches from [param cfg].
func apply_config(cfg: DotWeatherConfig) -> void:
	config = cfg


## Validates [param data] (a dictionary, or an already parsed [DotWeatherDoc]) and sets up from
## it. A bad document is refused with a WARN and leaves the previous weather alone.
func apply(data: Variant) -> DotResult:
	var parsed: DotWeatherDoc = null
	if data is DotWeatherDoc:
		parsed = data
	elif data is Dictionary:
		var res := DotWeatherDoc.parse(data)
		if not res.ok:
			DotLog.warn(CHANNEL, "weather document refused", {"why": res.error.message})
			return res
		parsed = res.value
	else:
		return DotResult.fail(DotError.CODE_INVALID, "weather: apply() takes a Dictionary or a DotWeatherDoc")
	setup(parsed)
	return DotResult.success(parsed)


## Uses [param d]. Replaces whatever weather was set up, restoring the fog first.
func setup(d: DotWeatherDoc) -> void:
	_teardown()
	doc = d
	_have_t = false
	_clock = 0.0
	_fog_dirty = d.has_fog
	if d.has_precipitation:
		_build_fx()
	DotLog.info(CHANNEL, "weather set", {"doc": d.describe(), "fx": _fx != null, "fog_via": "dot-lighting" if lighting_available() else "plain"})
	ambience_changed.emit({"loop": d.ambience_loop, "wind": d.ambience_wind} if d.has_ambience else {})


## Removes the weather: precipitation gone, the world's own fog and light put back.
func clear() -> void:
	_teardown()
	doc = null
	_wind = Vector3.ZERO
	ambience_changed.emit({})


## Once a frame. [param camera_pos] places the precipitation and the thunder's delay;
## [param match_time] is the shared clock in seconds (negative: use this node's own clock).
func advance(delta: float, camera_pos: Vector3, match_time: float = -1.0) -> void:
	if doc == null:
		return
	if match_time >= 0.0:
		_time = match_time
	else:
		_clock += delta
		_time = _clock
	_wind = DotWeatherSchedule.wind_at(doc, _time)
	_sync_fx(delta, camera_pos)
	_apply_fog()
	_events(camera_pos)
	_update_flash(camera_pos)


## [method advance] with the camera from [member camera_ref].
func advance_with_camera(delta: float, match_time: float = -1.0) -> void:
	var cam := camera_ref.resolve_or_null(self) as Camera3D if camera_ref != null else get_viewport().get_camera_3d()
	if cam == null:
		return
	advance(delta, cam.global_position, match_time)


## The wind now, in metres per second: for foliage, flags, projectiles, smoke. Zero with no wind.
func wind() -> Vector3:
	return _wind


## The flash brightness applied this frame, 0 to 1 (after the player's flash scale).
func flash_level() -> float:
	return _flash_level


## The time the last [method advance] used.
func current_time() -> float:
	return _time


## One line for a console or a debug overlay.
func describe() -> String:
	if doc == null:
		return "weather: none"
	return "weather: %s | precip %s, fog %s, quality %s, wind %s, flash %.2f, t=%.1f" % [
		doc.describe(),
		("drawn by dot-fx" if _fx != null else ("not drawn (dot-fx absent or no display)" if doc.has_precipitation else "none")),
		("on" if _env != null and _env.fog_enabled and doc.has_fog else ("pending" if _fog_dirty else "none")),
		Quality.keys()[clampi(config.quality, 0, 2)], _wind, _flash_level, _time,
	]


# --- internals ----------------------------------------------------------------

func _build_fx() -> void:
	if not fx_available() or not can_render():
		DotLog.debug(CHANNEL, "precipitation kept, not drawn", {"fx": fx_available(), "display": can_render()})
		return
	var script: Script = load(_FX_SCRIPT)
	_fx = script.new() as Node3D
	add_child(_fx)
	_fx_quality = -1
	_fx_density = -1.0
	var res: Variant = _fx.call("apply", doc.precipitation_dict())
	if res is DotResult and not (res as DotResult).ok:
		DotLog.warn(CHANNEL, "dot-fx refused the precipitation", {"why": (res as DotResult).error.message})
		_fx.queue_free()
		_fx = null
		return
	if _fx.has_signal("audible_changed"):
		_fx.connect("audible_changed", func(_sound: StringName, inside: bool) -> void: ambience_inside_changed.emit(inside))


func _sync_fx(delta: float, camera_pos: Vector3) -> void:
	if _fx == null:
		return
	# dot-fx marks itself dirty on every set, so only touch it when something changed.
	if config.quality != _fx_quality:
		_fx_quality = config.quality
		_fx.set("quality", config.quality)
	if not is_equal_approx(config.density_scale, _fx_density):
		_fx_density = config.density_scale
		_fx.set("density_scale", config.density_scale)
	_fx.call("advance", delta, camera_pos)


func _find_env() -> Environment:
	if not is_inside_tree():
		return null
	if environment_ref != null:
		var res := environment_ref.resolve(self)
		var we: WorldEnvironment = res.value as WorldEnvironment if res.ok else null
		if we != null and we.environment != null:
			return we.environment
		if not _ref_warned:
			_ref_warned = true
			DotLog.warn(CHANNEL, "environment_ref found no WorldEnvironment with an Environment; using the viewport's", {"ref": environment_ref.describe()})
	var w := get_viewport().find_world_3d() if get_viewport() != null else null
	return w.environment if w != null else null


func _apply_fog() -> void:
	if not _fog_dirty:
		return
	var env := _find_env()
	if env == null:
		if not _env_warned:
			_env_warned = true
			DotLog.warn(CHANNEL, "no world environment to write fog onto; the fog waits for one (weather never makes a second)")
		return
	_env = env
	_fog_saved = _snapshot_fog(env)
	if lighting_available():
		var light_doc: Variant = (load(_LIGHT_DOC) as Script).call("from_dictionary", {"fog": {
			"enabled": true, "colour": [doc.fog_colour.r, doc.fog_colour.g, doc.fog_colour.b],
			"start": doc.fog_start, "end": doc.fog_end, "max_density": doc.fog_max_density}})
		(load(_LIGHT_RIG) as Script).call("apply_fog", env, light_doc, 1.0)
	else:
		_apply_fog_plain(env)
	_fog_dirty = false


## What dot-lighting's rig writes, for a build without it. A test pins the two together.
func _apply_fog_plain(env: Environment) -> void:
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = doc.fog_colour
	env.fog_depth_begin = doc.fog_start
	env.fog_depth_end = maxf(doc.fog_end, doc.fog_start + 1.0)
	env.fog_density = clampf(doc.fog_max_density, 0.0, 1.0)
	env.fog_depth_curve = 1.0
	env.fog_sky_affect = 0.0


static func _snapshot_fog(env: Environment) -> Dictionary:
	return {
		"fog_enabled": env.fog_enabled, "fog_mode": env.fog_mode, "fog_light_color": env.fog_light_color,
		"fog_depth_begin": env.fog_depth_begin, "fog_depth_end": env.fog_depth_end,
		"fog_density": env.fog_density, "fog_depth_curve": env.fog_depth_curve,
		"fog_sky_affect": env.fog_sky_affect,
	}


func _events(camera_pos: Vector3) -> void:
	var t := _time
	if _have_t and t > _last_t and t - _last_t <= MAX_STEP:
		for st in DotWeatherSchedule.strikes_between(doc, _last_t, t):
			lightning.emit(st, DotWeatherSchedule.flash_envelope(doc, st, t))
		for th in DotWeatherSchedule.thunders_between(doc, camera_pos, _last_t, t):
			thunder.emit(th["sound"], th, th["listener_distance"], DotWeatherSchedule.distance_dim(doc, th["listener_distance"]))
	_last_t = t
	_have_t = true


func _flash_allowed() -> bool:
	return config.quality > 0 and config.allow_flashes and config.flash_scale > 0.0


func _update_flash(camera_pos: Vector3) -> void:
	if not doc.has_thunder:
		_end_flash()
		return
	var env := _env if _env != null else _find_env()
	if env == null or not _flash_allowed():
		_end_flash()
		return
	_env = env
	var f := DotWeatherSchedule.flash_at(doc, _time, camera_pos)
	var level: float = f["level"] * config.flash_scale
	_flash_level = level
	if level <= 0.0:
		_end_flash()
		return
	if not _flashing:
		_flashing = true
		_flash_base = {"bg": env.background_energy_multiplier, "amb": env.ambient_light_energy}
	env.background_energy_multiplier = _flash_base["bg"] + level * doc.flash_sky
	env.ambient_light_energy = _flash_base["amb"] + level * doc.flash_ambient
	_draw_bolt(f["strike"], camera_pos, level)


func _end_flash() -> void:
	_flash_level = 0.0
	if _flashing and _env != null:
		_env.background_energy_multiplier = _flash_base["bg"]
		_env.ambient_light_energy = _flash_base["amb"]
	_flashing = false
	if _bolt != null:
		_bolt.visible = false
	_bolt_slot = -1


func _draw_bolt(st: Dictionary, camera_pos: Vector3, level: float) -> void:
	if not doc.bolt or config.quality < Quality.HIGH or not can_render() or st.is_empty():
		return
	if _bolt == null:
		_bolt = MeshInstance3D.new()
		_bolt.top_level = true
		_bolt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.disable_fog = true
		mat.albedo_color = Color(0.85, 0.9, 1.0, 1.0)
		_bolt.material_override = mat
		add_child(_bolt)
	var mat2 := _bolt.material_override as StandardMaterial3D
	mat2.albedo_color.a = clampf(level * 1.4, 0.0, 1.0)
	if _bolt_slot != int(st["slot"]):
		_bolt_slot = int(st["slot"])
		var ground: Vector3 = st["position"]
		var top := ground + Vector3.UP * doc.thunder_height
		var metres := camera_pos.distance_to(ground)
		_bolt.mesh = DotWeatherBolt.mesh(DotWeatherBolt.points(doc, st, top, ground), camera_pos, 0.25 + metres * 0.006)
	_bolt.visible = true


func _teardown() -> void:
	_end_flash()
	if _bolt != null:
		_bolt.queue_free()
		_bolt = null
	if _fx != null:
		_fx.queue_free()
		_fx = null
	if _env != null and not _fog_saved.is_empty():
		for key in _fog_saved:
			_env.set(key, _fog_saved[key])
	_fog_saved = {}
	_fog_dirty = false
	_env_warned = false
	_env = null
