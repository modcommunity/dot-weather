class_name DotWeatherDoc
extends RefCounted

## A map's everyday weather as a document: what falls, how thick the air is, which way it blows,
## whether it thunders, and which sounds go with it.
##
## [b]A document so a map can carry it.[/b] Every key is optional except that a document says
## something; a section that is absent is "this map has none of it" ([member has_precipitation]
## and the others), which is not the same as a section of zeros. Nothing here touches a renderer,
## so a dedicated server parses the very same document and runs the lightning schedule from it.
##
## [codeblock]
## {
##   "seed": 1234,                          # the lightning schedule's seed (default 0)
##   "precipitation": {                     # handed to dot-fx's DotFxWeather, volumes included
##     "kind": "rain",                      # "snow" or "rain"
##     "density": 1.2,                      # 0 to 4
##     "colour": "#c8d8ff",                 # html string or [r, g, b(, a)]
##     "volumes": [{"min": [-40, 0, -40], "max": [40, 30, 40]}]   # none = everywhere
##   },
##   "fog": {"colour": [0.5, 0.55, 0.62], "start": 8, "end": 120, "max_density": 0.9},   # metres
##   "wind": {"vector": [3, 0, 1], "gust": 0.8, "gust_period": 9},
##   "thunder": {
##     "mean_interval": 14,                 # seconds, 3 or more
##     "chance": 0.8,                       # of a strike in each interval
##     "centre": [0, 0, 0], "min_distance": 80, "max_distance": 900, "height": 220,
##     "flash": {"sky": 1.6, "ambient": 0.8, "duration": 0.45},
##     "bolt": true,
##     "speed_of_sound": 343
##   },
##   "ambience": {"loop": "amb_rain", "wind": "amb_wind", "thunder": ["thunder_a", "thunder_b"]}
## }
## [/codeblock]
##
## [b]Unknown keys are refused, at every level.[/b] A misspelt "volumes" would read as "everywhere"
## and a misspelt "mean_interval" as the default, and the storm would be wrong on every client
## in the same quiet way.
##
## Distances are metres. [method parse] returns a [DotResult] naming the key that was wrong, and
## [method to_dict] returns a document that parses back to the same thing.

const SNOW := &"snow"
const RAIN := &"rain"

## The most precipitation volumes one document may carry. Same ceiling as dot-fx.
const MAX_VOLUMES := 256

## The shortest mean interval between strikes. With the schedule's placement inside each interval
## (see [DotWeatherSchedule]) two strikes are never closer than half of this, so a flash never
## repeats faster than the three a second the accessibility guidance allows, double flicker included.
const MIN_INTERVAL := 3.0

const _TOP := ["seed", "precipitation", "fog", "wind", "thunder", "ambience"]
const _PRECIP := ["kind", "density", "colour", "volumes"]
const _FOG := ["colour", "start", "end", "max_density"]
const _WIND := ["vector", "gust", "gust_period"]
const _THUNDER := ["mean_interval", "chance", "centre", "min_distance", "max_distance", "height", "flash", "bolt", "speed_of_sound"]
const _FLASH := ["sky", "ambient", "duration"]
const _AMBIENCE := ["loop", "wind", "thunder"]

## The seed of the lightning schedule. Every client must hold the same one; it is the document's.
var seed_value: int = 0

var has_precipitation: bool = false
var precip_kind: StringName = SNOW
var precip_density: float = 1.0
var precip_colour: Color = Color(1, 1, 1, 1)
var precip_volumes: Array[AABB] = []

var has_fog: bool = false
var fog_colour: Color = Color(0.6, 0.65, 0.7)
var fog_start: float = 0.0
var fog_end: float = 100.0
var fog_max_density: float = 1.0

var has_wind: bool = false
## Metres per second, before gusts.
var wind_vector: Vector3 = Vector3.ZERO
## How much a gust adds to the wind: 0 none, 1 doubles it at its peak.
var gust_strength: float = 0.0
## Seconds between gusts, roughly.
var gust_period: float = 8.0

var has_thunder: bool = false
var thunder_interval: float = 15.0
var thunder_chance: float = 0.8
var thunder_centre: Vector3 = Vector3.ZERO
var thunder_min_distance: float = 60.0
var thunder_max_distance: float = 800.0
## How far above the strike point the bolt starts.
var thunder_height: float = 200.0
## How much the sky is brightened at a flash's peak, in units of the sky's own energy.
var flash_sky: float = 1.5
## How much the ambient light is brightened at a flash's peak.
var flash_ambient: float = 0.8
var flash_duration: float = 0.45
## Whether a visible bolt is drawn at all.
var bolt: bool = true
var speed_of_sound: float = 343.0

var has_ambience: bool = false
var ambience_loop: StringName = &""
var ambience_wind: StringName = &""
var ambience_thunder: Array[StringName] = []

var _stream: DotRandomStream = null


## A document from a dictionary, or a failure naming the key. Succeeds with a [DotWeatherDoc].
static func parse(data: Dictionary) -> DotResult:
	var bad := _unknown(data, _TOP, "weather")
	if bad != "":
		return _fail(bad)
	var d := DotWeatherDoc.new()

	if data.has("seed"):
		var s: Variant = data["seed"]
		if not (s is int or (s is float and is_finite(s) and s == floorf(s))):
			return _fail("weather: 'seed' must be an integer")
		d.seed_value = int(s)

	if data.has("precipitation"):
		var r := d._parse_precipitation(data["precipitation"])
		if not r.ok:
			return r
	if data.has("fog"):
		var r := d._parse_fog(data["fog"])
		if not r.ok:
			return r
	if data.has("wind"):
		var r := d._parse_wind(data["wind"])
		if not r.ok:
			return r
	if data.has("thunder"):
		var r := d._parse_thunder(data["thunder"])
		if not r.ok:
			return r
	if data.has("ambience"):
		var r := d._parse_ambience(data["ambience"])
		if not r.ok:
			return r
	return DotResult.success(d)


## The document this was parsed from, so one built in code can be saved with a map.
func to_dict() -> Dictionary:
	var out := {"seed": seed_value}
	if has_precipitation:
		var vs: Array = []
		for b in precip_volumes:
			vs.append({"min": _arr(b.position), "max": _arr(b.end)})
		out["precipitation"] = {
			"kind": String(precip_kind), "density": precip_density,
			"colour": "#" + precip_colour.to_html(precip_colour.a < 1.0), "volumes": vs,
		}
	if has_fog:
		out["fog"] = {"colour": "#" + fog_colour.to_html(false), "start": fog_start, "end": fog_end, "max_density": fog_max_density}
	if has_wind:
		out["wind"] = {"vector": _arr(wind_vector), "gust": gust_strength, "gust_period": gust_period}
	if has_thunder:
		out["thunder"] = {
			"mean_interval": thunder_interval, "chance": thunder_chance, "centre": _arr(thunder_centre),
			"min_distance": thunder_min_distance, "max_distance": thunder_max_distance, "height": thunder_height,
			"flash": {"sky": flash_sky, "ambient": flash_ambient, "duration": flash_duration},
			"bolt": bolt, "speed_of_sound": speed_of_sound,
		}
	if has_ambience:
		var ids: Array = []
		for t in ambience_thunder:
			ids.append(String(t))
		out["ambience"] = {"loop": String(ambience_loop), "wind": String(ambience_wind), "thunder": ids}
	return out


## The precipitation section in the shape dot-fx's weather document wants, with the wind's base
## vector folded in (dot-fx takes one steady wind). Empty when there is no precipitation.
func precipitation_dict() -> Dictionary:
	if not has_precipitation:
		return {}
	var vs: Array = []
	for b in precip_volumes:
		vs.append({"min": _arr(b.position), "max": _arr(b.end)})
	return {
		"kind": String(precip_kind), "density": precip_density,
		"colour": "#" + precip_colour.to_html(precip_colour.a < 1.0),
		"wind": _arr(wind_vector if has_wind else Vector3.ZERO), "volumes": vs,
	}


## The seeded stream every schedule draw comes from. Indexed draws advance nothing.
func stream() -> DotRandomStream:
	if _stream == null:
		_stream = DotRandomStream.new(seed_value, &"dot_weather")
	return _stream


func describe() -> String:
	var parts: PackedStringArray = []
	if has_precipitation:
		parts.append("%s x%.2f, %s" % [precip_kind, precip_density, "%d volumes" % precip_volumes.size() if not precip_volumes.is_empty() else "everywhere"])
	if has_fog:
		parts.append("fog %d to %d m" % [int(fog_start), int(fog_end)])
	if has_wind:
		parts.append("wind %s gust %.1f" % [wind_vector, gust_strength])
	if has_thunder:
		parts.append("thunder every ~%.0f s" % (thunder_interval / maxf(thunder_chance, 0.01)))
	if has_ambience:
		parts.append("ambience")
	return "seed %d: %s" % [seed_value, ", ".join(parts) if not parts.is_empty() else "clear"]


# --- sections -----------------------------------------------------------------

func _parse_precipitation(v: Variant) -> DotResult:
	if not (v is Dictionary):
		return _fail("weather: 'precipitation' must be an object")
	var sec: Dictionary = v
	var bad := _unknown(sec, _PRECIP, "weather.precipitation")
	if bad != "":
		return _fail(bad)
	var k := str(sec.get("kind", ""))
	if k != "snow" and k != "rain":
		return _fail("weather.precipitation: 'kind' must be \"snow\" or \"rain\", not '%s'" % k)
	precip_kind = StringName(k)
	var n: Variant = _num(sec.get("density", 1.0), 0.0, 4.0)
	if n == null:
		return _fail("weather.precipitation: 'density' must be a number from 0 to 4")
	precip_density = n
	if sec.has("colour"):
		var c: Variant = _colour(sec["colour"])
		if c == null:
			return _fail("weather.precipitation: 'colour' must be an html colour or [r, g, b(, a)]")
		precip_colour = c
	if sec.has("volumes"):
		var vs: Variant = sec["volumes"]
		if not (vs is Array):
			return _fail("weather.precipitation: 'volumes' must be an array")
		if vs.size() > MAX_VOLUMES:
			return _fail("weather.precipitation: %d volumes, at most %d" % [vs.size(), MAX_VOLUMES])
		for i in range(vs.size()):
			var box: Variant = _box(vs[i])
			if box == null:
				return _fail("weather.precipitation: volume %d needs min+max or center+size, finite and not inside out" % i)
			precip_volumes.append(box)
	has_precipitation = true
	return DotResult.success(null)


func _parse_fog(v: Variant) -> DotResult:
	if not (v is Dictionary):
		return _fail("weather: 'fog' must be an object")
	var sec: Dictionary = v
	var bad := _unknown(sec, _FOG, "weather.fog")
	if bad != "":
		return _fail(bad)
	if sec.has("colour"):
		var c: Variant = _colour(sec["colour"])
		if c == null:
			return _fail("weather.fog: 'colour' must be an html colour or [r, g, b]")
		fog_colour = Color(c.r, c.g, c.b, 1.0)
	var s: Variant = _num(sec.get("start", 0.0), 0.0, 100000.0)
	var e: Variant = _num(sec.get("end", 100.0), 0.0, 100000.0)
	var m: Variant = _num(sec.get("max_density", 1.0), 0.0, 1.0)
	if s == null or e == null or m == null:
		return _fail("weather.fog: 'start', 'end' (metres) and 'max_density' (0 to 1) must be numbers in range")
	if e <= s:
		return _fail("weather.fog: 'end' must be beyond 'start'")
	fog_start = s
	fog_end = e
	fog_max_density = m
	has_fog = true
	return DotResult.success(null)


func _parse_wind(v: Variant) -> DotResult:
	if not (v is Dictionary):
		return _fail("weather: 'wind' must be an object")
	var sec: Dictionary = v
	var bad := _unknown(sec, _WIND, "weather.wind")
	if bad != "":
		return _fail(bad)
	if sec.has("vector"):
		var w: Variant = _vec3(sec["vector"])
		if w == null:
			return _fail("weather.wind: 'vector' must be [x, y, z]")
		wind_vector = w
	var g: Variant = _num(sec.get("gust", 0.0), 0.0, 4.0)
	var p: Variant = _num(sec.get("gust_period", 8.0), 0.5, 600.0)
	if g == null or p == null:
		return _fail("weather.wind: 'gust' must be 0 to 4 and 'gust_period' 0.5 to 600 seconds")
	gust_strength = g
	gust_period = p
	has_wind = true
	return DotResult.success(null)


func _parse_thunder(v: Variant) -> DotResult:
	if not (v is Dictionary):
		return _fail("weather: 'thunder' must be an object")
	var sec: Dictionary = v
	var bad := _unknown(sec, _THUNDER, "weather.thunder")
	if bad != "":
		return _fail(bad)
	var iv: Variant = _num(sec.get("mean_interval", 15.0), MIN_INTERVAL, 3600.0)
	if iv == null:
		return _fail("weather.thunder: 'mean_interval' must be %.0f to 3600 seconds (a faster storm would flash faster than is safe to watch)" % MIN_INTERVAL)
	var ch: Variant = _num(sec.get("chance", 0.8), 0.01, 1.0)
	if ch == null:
		return _fail("weather.thunder: 'chance' must be 0.01 to 1")
	var dmin: Variant = _num(sec.get("min_distance", 60.0), 0.0, 100000.0)
	var dmax: Variant = _num(sec.get("max_distance", 800.0), 1.0, 100000.0)
	var ht: Variant = _num(sec.get("height", 200.0), 1.0, 100000.0)
	var sos: Variant = _num(sec.get("speed_of_sound", 343.0), 1.0, 100000.0)
	if dmin == null or dmax == null or ht == null or sos == null or dmax < dmin:
		return _fail("weather.thunder: 'min_distance' <= 'max_distance' (metres), 'height' and 'speed_of_sound' must be positive numbers")
	if sec.has("centre"):
		var c: Variant = _vec3(sec["centre"])
		if c == null:
			return _fail("weather.thunder: 'centre' must be [x, y, z]")
		thunder_centre = c
	if sec.has("flash"):
		var f: Variant = sec["flash"]
		if not (f is Dictionary):
			return _fail("weather.thunder: 'flash' must be an object")
		var fbad := _unknown(f, _FLASH, "weather.thunder.flash")
		if fbad != "":
			return _fail(fbad)
		var fs: Variant = _num(f.get("sky", 1.5), 0.0, 16.0)
		var fa: Variant = _num(f.get("ambient", 0.8), 0.0, 16.0)
		var fd: Variant = _num(f.get("duration", 0.45), 0.1, 3.0)
		if fs == null or fa == null or fd == null:
			return _fail("weather.thunder.flash: 'sky' and 'ambient' 0 to 16, 'duration' 0.1 to 3 seconds")
		flash_sky = fs
		flash_ambient = fa
		flash_duration = fd
	if sec.has("bolt"):
		if not (sec["bolt"] is bool):
			return _fail("weather.thunder: 'bolt' must be true or false")
		bolt = sec["bolt"]
	thunder_interval = iv
	thunder_chance = ch
	thunder_min_distance = dmin
	thunder_max_distance = dmax
	thunder_height = ht
	speed_of_sound = sos
	has_thunder = true
	return DotResult.success(null)


func _parse_ambience(v: Variant) -> DotResult:
	if not (v is Dictionary):
		return _fail("weather: 'ambience' must be an object")
	var sec: Dictionary = v
	var bad := _unknown(sec, _AMBIENCE, "weather.ambience")
	if bad != "":
		return _fail(bad)
	for key in ["loop", "wind"]:
		if sec.has(key) and not (sec[key] is String or sec[key] is StringName):
			return _fail("weather.ambience: '%s' must be a sound id string" % key)
	ambience_loop = StringName(str(sec.get("loop", "")))
	ambience_wind = StringName(str(sec.get("wind", "")))
	if sec.has("thunder"):
		var t: Variant = sec["thunder"]
		if not (t is Array):
			return _fail("weather.ambience: 'thunder' must be an array of sound ids")
		for id in t:
			if not (id is String or id is StringName):
				return _fail("weather.ambience: 'thunder' holds sound id strings only")
			ambience_thunder.append(StringName(str(id)))
	has_ambience = true
	return DotResult.success(null)


# --- helpers ------------------------------------------------------------------

static func _fail(message: String) -> DotResult:
	return DotResult.fail(DotError.CODE_INVALID, message)


## The first key of [param d] not in [param allowed], as a message, or "".
static func _unknown(d: Dictionary, allowed: Array, where: String) -> String:
	for key in d:
		if not (key is String) or not allowed.has(key):
			return "%s: unknown key '%s'" % [where, str(key)]
	return ""


## [param v] as a float in range, or null. A bool or a string is not a number.
static func _num(v: Variant, lo: float, hi: float) -> Variant:
	if not (v is float or v is int) or not is_finite(float(v)):
		return null
	var f := float(v)
	if f < lo or f > hi:
		return null
	return f


static func _arr(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


static func _vec3(v: Variant) -> Variant:
	if not (v is Array) or v.size() != 3:
		return null
	for n in v:
		if not (n is float or n is int) or not is_finite(float(n)):
			return null
	return Vector3(float(v[0]), float(v[1]), float(v[2]))


static func _colour(v: Variant) -> Variant:
	if v is String:
		if not Color.html_is_valid(v):
			return null
		return Color.html(v)
	if v is Array and (v.size() == 3 or v.size() == 4):
		for n in v:
			if not (n is float or n is int) or not is_finite(float(n)):
				return null
		return Color(float(v[0]), float(v[1]), float(v[2]), float(v[3]) if v.size() == 4 else 1.0)
	return null


static func _box(v: Variant) -> Variant:
	if not (v is Dictionary):
		return null
	var lo: Variant = null
	var hi: Variant = null
	if v.has("min") and v.has("max"):
		lo = _vec3(v["min"])
		hi = _vec3(v["max"])
	elif v.has("center") and v.has("size"):
		var c: Variant = _vec3(v["center"])
		var s: Variant = _vec3(v["size"])
		if c != null and s != null:
			lo = c - s * 0.5
			hi = c + s * 0.5
	if lo == null or hi == null:
		return null
	if hi.x <= lo.x or hi.y <= lo.y or hi.z <= lo.z:
		return null
	return AABB(lo, hi - lo)
