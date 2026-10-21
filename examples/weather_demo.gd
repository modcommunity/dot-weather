extends Node3D

## Snow, rain with lightning, and fog on a small stage, through DotWeather and nothing else.
##
## Run it under a display; headless it draws nothing, which is the point of
## [method DotWeather.can_render].
##
## [codeblock]
## godot --path . res://examples/weather_demo.tscn -- --mode rain
## xvfb-run -a godot --path . res://examples/weather_demo.tscn -- --mode flash --shot /tmp/flash.png
## [/codeblock]
##
## Modes: [code]snow[/code], [code]rain[/code] (the default: a storm, in real time), [code]fog[/code]
## and [code]flash[/code] (a storm held at the instant of a strike, for a screenshot). Keys: 1 to 4
## switch mode, Q cycles the quality, F toggles flashes.

const STEP := 1.0 / 60.0

var _weather := DotWeather.new()
var _cam := Camera3D.new()
var _env := Environment.new()
var _mode := "rain"
var _shot_path := ""
var _frames := 0
var _base_time := 0.0
var _fixed_time := false


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		if args[i] == "--mode" and i + 1 < args.size():
			_mode = args[i + 1]
		elif args[i] == "--shot" and i + 1 < args.size():
			_shot_path = args[i + 1]

	_env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky.sky_material = sky_mat
	_env.sky = sky
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = _env
	add_child(we)

	_build_stage()

	_weather.environment_ref = DotNodeRef.of_path(NodePath("../WorldEnvironment"))
	add_child(_weather)
	_weather.lightning.connect(func(st: Dictionary, _l: float) -> void: print("lightning slot ", st["slot"], " at ", st["position"]))
	_weather.thunder.connect(func(snd: StringName, _st: Dictionary, m: float, loud: float) -> void: print("thunder ", snd, " ", int(m), " m, loudness ", snappedf(loud, 0.01)))
	_cam.position = Vector3(0, 3, 7)
	_cam.fov = 80.0
	_cam.far = 600.0
	add_child(_cam)
	_cam.look_at(Vector3(0, 4.5, -30))
	_cam.make_current()
	_set_mode(_mode)


func _set_mode(mode: String) -> void:
	_mode = mode
	_frames = 0
	var storm := {"mean_interval": 6, "chance": 1.0, "centre": [0, 0, -120], "min_distance": 30, "max_distance": 90,
		"height": 160, "flash": {"sky": 2.2, "ambient": 1.4, "duration": 0.5}, "bolt": true}
	var docs := {
		"snow": {"seed": 3, "precipitation": {"kind": "snow", "density": 2.0, "colour": "#ffffff"},
			"fog": {"colour": [0.78, 0.82, 0.88], "start": 5, "end": 140, "max_density": 0.85},
			"wind": {"vector": [1.2, 0, 0.3], "gust": 0.6}},
		"rain": {"seed": 3, "precipitation": {"kind": "rain", "density": 1.6, "colour": [0.75, 0.85, 1.0, 0.6]},
			"fog": {"colour": [0.32, 0.36, 0.42], "start": 10, "end": 220, "max_density": 0.8},
			"wind": {"vector": [3, 0, 0.5], "gust": 0.8}, "thunder": storm,
			"ambience": {"loop": "amb_rain", "thunder": ["thunder_a", "thunder_b"]}},
		"fog": {"seed": 3, "fog": {"colour": [0.62, 0.66, 0.7], "start": 4, "end": 70, "max_density": 1.0}},
	}
	docs["flash"] = docs["rain"]
	var doc: Dictionary = docs[mode].duplicate(true)
	# The held-flash mode picks a seed whose second strike lands in front of the camera, so the
	# bolt is in the picture, and sets the clock so a strike is 0.05 s old on frame 90.
	_fixed_time = mode == "flash"
	if _fixed_time:
		for sd in range(1, 400):
			doc["seed"] = sd
			var d := DotWeatherDoc.parse(doc).value as DotWeatherDoc
			var st := DotWeatherSchedule.strike(d, 2)
			if st["position"].z < -70.0 and absf(st["position"].x) < 18.0:
				_base_time = st["time"] + 0.05 - 90.0 * STEP
				break
	var res := _weather.apply(doc)
	if not res.ok:
		push_error("weather demo: " + res.error.message)
	_set_background(mode)
	print(_weather.describe())


func _set_background(mode: String) -> void:
	var m := _env.sky.sky_material as ProceduralSkyMaterial
	var grey := mode == "rain" or mode == "flash"
	m.sky_top_color = Color(0.1, 0.12, 0.17) if grey else (Color(0.55, 0.62, 0.7) if mode == "snow" else Color(0.5, 0.58, 0.68))
	m.sky_horizon_color = Color(0.3, 0.34, 0.4) if grey else (Color(0.78, 0.82, 0.88) if mode == "snow" else Color(0.62, 0.66, 0.7))
	m.ground_horizon_color = m.sky_horizon_color
	m.ground_bottom_color = m.sky_horizon_color * 0.8
	_env.ambient_light_color = Color(0.45, 0.48, 0.55) if grey else Color(0.75, 0.78, 0.82)
	_env.ambient_light_energy = 0.55 if grey else 0.9


func _build_stage() -> void:
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(500, 500)
	floor_mesh.mesh = plane
	floor_mesh.material_override = _mat(Color(0.28, 0.31, 0.27))
	add_child(floor_mesh)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	# Houses and posts at several distances, so fog and rain have something to fade.
	for i in range(26):
		var z := -8.0 - i * 9.0
		for side in [-1, 1]:
			var h := rng.randf_range(3.0, 9.0)
			var w := rng.randf_range(4.0, 8.0)
			var m := MeshInstance3D.new()
			var b := BoxMesh.new()
			b.size = Vector3(w, h, w)
			m.mesh = b
			m.material_override = _mat(Color.from_hsv(rng.randf(), 0.15, rng.randf_range(0.5, 0.85)))
			m.position = Vector3(side * rng.randf_range(10.0, 16.0), h * 0.5, z)
			add_child(m)
	var tree_mat := _mat(Color(0.18, 0.4, 0.2))
	for i in range(14):
		var m := MeshInstance3D.new()
		var c := CylinderMesh.new()
		c.top_radius = 0.0
		c.bottom_radius = 1.6
		c.height = 5.0
		m.mesh = c
		m.material_override = tree_mat
		m.position = Vector3(rng.randf_range(-6, 6), 2.5, -14.0 - i * 14.0)
		add_child(m)


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	return m


func _process(delta: float) -> void:
	_frames += 1
	# A fixed step in the shot modes so the capture is the same frame every run.
	var t := _base_time + _frames * STEP if _fixed_time else -1.0
	_weather.advance(STEP if _shot_path != "" else delta, _cam.global_position, t)
	if _shot_path != "" and _frames == 90:
		get_viewport().get_texture().get_image().save_png(_shot_path)
		print("saved ", _shot_path, " | ", _weather.describe())
		get_tree().quit()


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed:
		return
	match k.keycode:
		KEY_1: _set_mode("snow")
		KEY_2: _set_mode("rain")
		KEY_3: _set_mode("fog")
		KEY_4: _set_mode("flash")
		KEY_Q: _weather.config.quality = (_weather.config.quality + 2) % 3
		KEY_F: _weather.config.allow_flashes = not _weather.config.allow_flashes
