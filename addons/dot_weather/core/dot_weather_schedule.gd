class_name DotWeatherSchedule
extends RefCounted

## Lightning, thunder and wind as pure functions of (the document's seed, a time).
##
## [b]Why this is how lightning stays in sync without a packet.[/b] The obvious design is a server
## that decides "lightning now" and tells every client. That costs a message per strike, arrives
## at a different moment for each client, is lost for a client that joins mid-storm, and does
## nothing for a replay or a spectator who seeks. Here nothing is ever sent: the strike list is a
## function of the document's seed and a clock every client already shares (the match time a
## game feeds in), so each client works out for itself that "there is a strike at 41.37 s, 312 m
## north-east of the centre". Two clients that agree on the time agree on the storm, a client that
## joins late sees the same storm from its first frame, and seeking a replay is just a different
## [param t].
##
## [b]Time is cut into slots[/b] of [member DotWeatherDoc.thunder_interval] seconds. Slot [code]n[/code]
## holds at most one strike, present with probability [member DotWeatherDoc.thunder_chance], placed
## between 25% and 75% of the way through its slot. A stateful countdown ("wait a random time, strike,
## repeat") cannot be asked about the middle of a match without simulating all of it, and its
## failure mode is the latch (one missed tick and it never fires again). A slot has no state to
## lose. The placement also bounds the pace: two strikes are always at least half an interval apart
## (1.5 s at the shortest), which is the guarantee that a flash, with its double flicker, never
## exceeds the three a second the accessibility guidance allows.
##
## [b]The strike has a place in the world, not on the screen[/b]: an angle and a distance from the
## document's centre, drawn from the same seed. So it is the same strike for everyone and each
## client sees it from where it stands: [method thunder_delay] differs per listener, and a player
## near the strike hears the thunder first.
##
## All draws are indexed ([method DotRandomStream.unit_at]), so asking about slot 900 does not
## need slots 0 to 899, and asking twice gives the same answer.

# Indices within a slot's block of draws. A block is 8 wide so a slot's draws never collide.
const _BLOCK := 8
const _PRESENT := 0
const _OFFSET := 1
const _ANGLE := 2
const _DISTANCE := 3
const _POWER := 4
const _SOUND := 5

## Where in its slot a strike falls, as fractions: the bound on how close two can be.
const EARLIEST := 0.25
const LATEST := 0.75


## The slot number that contains [param t].
static func slot_of(doc: DotWeatherDoc, t: float) -> int:
	return floori(t / doc.thunder_interval)


## The strike of slot [param n], or an empty dictionary when that slot has none.
##
## [code]{"slot", "time", "position": Vector3, "distance": float (from the centre),
## "power": 0.5 to 1, "sound": StringName}[/code]. [code]sound[/code] is one of the document's
## thunder sound ids, picked by the same seed, or empty.
static func strike(doc: DotWeatherDoc, n: int) -> Dictionary:
	if not doc.has_thunder or n < 0:
		return {}
	var s := doc.stream()
	var base := n * _BLOCK
	if not s.chance_at(base + _PRESENT, doc.thunder_chance):
		return {}
	var angle := s.unit_at(base + _ANGLE) * TAU
	# Square root so strikes spread over the ring's area, not crowd the inner edge.
	var u := s.unit_at(base + _DISTANCE)
	var lo2 := doc.thunder_min_distance * doc.thunder_min_distance
	var hi2 := doc.thunder_max_distance * doc.thunder_max_distance
	var dist := sqrt(lo2 + u * (hi2 - lo2))
	var sound: StringName = &""
	if not doc.ambience_thunder.is_empty():
		sound = doc.ambience_thunder[s.range_i_at(base + _SOUND, 0, doc.ambience_thunder.size() - 1)]
	return {
		"slot": n,
		"time": (float(n) + EARLIEST + s.unit_at(base + _OFFSET) * (LATEST - EARLIEST)) * doc.thunder_interval,
		"position": doc.thunder_centre + Vector3(cos(angle) * dist, 0.0, sin(angle) * dist),
		"distance": dist,
		"power": 0.5 + 0.5 * s.unit_at(base + _POWER),
		"sound": sound,
	}


## Every strike whose time is in ([param t0], [param t1]], in order.
static func strikes_between(doc: DotWeatherDoc, t0: float, t1: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not doc.has_thunder or t1 <= t0:
		return out
	for n in range(maxi(slot_of(doc, t0), 0), slot_of(doc, t1) + 1):
		var st := strike(doc, n)
		if not st.is_empty() and st["time"] > t0 and st["time"] <= t1:
			out.append(st)
	return out


## Seconds from a flash until its thunder reaches [param listener].
static func thunder_delay(doc: DotWeatherDoc, st: Dictionary, listener: Vector3) -> float:
	return listener.distance_to(st["position"]) / doc.speed_of_sound


## The longest a thunder can lag its flash for any listener within the document's range of the
## centre plus [param reach] metres, for sizing the look-back window of [method thunders_between].
static func max_delay(doc: DotWeatherDoc, reach: float = 2000.0) -> float:
	return (doc.thunder_max_distance + reach + doc.thunder_height) / doc.speed_of_sound


## Strikes whose thunder reaches [param listener] in ([param t0], [param t1]]: the flash was
## earlier, by the distance over the speed of sound. Each is the strike dictionary plus
## [code]"delay"[/code] and [code]"listener_distance"[/code].
static func thunders_between(doc: DotWeatherDoc, listener: Vector3, t0: float, t1: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not doc.has_thunder or t1 <= t0:
		return out
	for st in strikes_between(doc, t0 - max_delay(doc), t1):
		var delay := thunder_delay(doc, st, listener)
		var arrives: float = st["time"] + delay
		if arrives > t0 and arrives <= t1:
			var item := st.duplicate()
			item["delay"] = delay
			item["listener_distance"] = listener.distance_to(st["position"])
			out.append(item)
	return out


## How bright the flash of [param st] is at time [param t], 0 to 1 (times the strike's power):
## a sharp rise, a fall, and a second weaker flicker 0.14 s later, which is what lightning
## looks like and what a single smooth pulse does not. Zero outside the flash.
static func flash_envelope(doc: DotWeatherDoc, st: Dictionary, t: float) -> float:
	var d: float = t - float(st["time"])
	if d < 0.0 or d > doc.flash_duration:
		return 0.0
	var k := doc.flash_duration * 0.2
	var main := smoothstep(0.0, 0.02, d) * exp(-d / k)
	var d2 := d - 0.14
	var flicker := 0.6 * smoothstep(0.0, 0.02, d2) * exp(-d2 / k) if d2 > 0.0 else 0.0
	return clampf(main + flicker, 0.0, 1.0) * float(st["power"])


## The strongest flash at time [param t] among all strikes, 0 to 1, and the strike behind it.
## [param listener] dims strikes far from it (a flash far off lights the sky less); leave it
## [constant Vector3.INF] for the same brightness for everyone.
## Returns [code]{"level": float, "strike": Dictionary}[/code].
static func flash_at(doc: DotWeatherDoc, t: float, listener: Vector3 = Vector3.INF) -> Dictionary:
	var best := {"level": 0.0, "strike": {}}
	for st in strikes_between(doc, t - doc.flash_duration - 0.001, t):
		var level := flash_envelope(doc, st, t)
		if listener != Vector3.INF:
			level *= distance_dim(doc, listener.distance_to(st["position"]))
		if level > best["level"]:
			best = {"level": level, "strike": st}
	return best


## Brightness and loudness factor for a strike [param metres] away: 1 close, down to 0.2 far.
static func distance_dim(doc: DotWeatherDoc, metres: float) -> float:
	return clampf(1.0 - metres / (doc.thunder_max_distance * 1.5), 0.2, 1.0)


## The wind at time [param t]: the document's vector times one plus the gust. A gust is the
## positive part of two slow sines beating against each other, so gusts come and go unevenly
## and are never negative. A function of time and seed, so every client's trees lean together.
static func wind_at(doc: DotWeatherDoc, t: float) -> Vector3:
	if not doc.has_wind:
		return Vector3.ZERO
	var phase := doc.stream().unit_at(1 << 40) * TAU
	var p := doc.gust_period
	var gust := maxf(sin(TAU * t / p + phase) * sin(TAU * t / (p * 0.43) + 1.3), 0.0)
	return doc.wind_vector * (1.0 + doc.gust_strength * gust)
