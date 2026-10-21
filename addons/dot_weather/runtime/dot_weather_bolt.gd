class_name DotWeatherBolt
extends RefCounted

## The mesh of a visible lightning bolt: a jagged ribbon from cloud to ground with two branches,
## turned to face a viewer. Pure geometry, so it is built and measured without a renderer.
##
## The shape comes from the strike's own slot and the document's seed, so every client draws
## the same jags. The ribbon's facing and width come from where the viewer stands, which differs
## per client by design (a bolt seen from the side is a line, seen end-on it is nothing).

const SEGMENTS := 18


## The polyline of the main trunk and two branches as arrays of points, from [param top] down to
## [param bottom]. Deterministic in [param doc] and [param st].
static func points(doc: DotWeatherDoc, st: Dictionary, top: Vector3, bottom: Vector3) -> Array[PackedVector3Array]:
	var s := doc.stream().stream_for(&"bolt", int(st["slot"]))
	var trunk := PackedVector3Array()
	var length := top.distance_to(bottom)
	var jag := length * 0.045
	for i in range(SEGMENTS + 1):
		var f := float(i) / SEGMENTS
		var p := top.lerp(bottom, f)
		if i > 0 and i < SEGMENTS:
			p += Vector3(s.next_range_f(-jag, jag), 0.0, s.next_range_f(-jag, jag))
		trunk.append(p)
	var out: Array[PackedVector3Array] = [trunk]
	for b in range(2):
		var from_i := s.next_range_i(SEGMENTS / 3, SEGMENTS * 2 / 3)
		var branch := PackedVector3Array()
		var p: Vector3 = trunk[from_i]
		var drift := Vector3(s.next_range_f(-1.0, 1.0), 0.0, s.next_range_f(-1.0, 1.0)).normalized() * length * 0.03
		branch.append(p)
		for j in range(1, 7):
			p += Vector3(0.0, -length / SEGMENTS * 0.9, 0.0) + drift + Vector3(s.next_range_f(-jag, jag), 0.0, s.next_range_f(-jag, jag)) * 0.5
			branch.append(p)
		out.append(branch)
	return out


## An ArrayMesh of triangles for [param lines], [param width] metres wide, facing [param viewer].
static func mesh(lines: Array[PackedVector3Array], viewer: Vector3, width: float) -> ArrayMesh:
	var verts := PackedVector3Array()
	var indices := PackedInt32Array()
	for li in range(lines.size()):
		var line := lines[li]
		# Branches are thinner than the trunk.
		var w := width * (1.0 if li == 0 else 0.45)
		for i in range(line.size()):
			var to_viewer := viewer - line[i]
			var side := Vector3.UP.cross(to_viewer)
			side = side.normalized() if side.length_squared() > 1e-6 else Vector3.RIGHT
			# Taper towards the ground end.
			var taper := 1.0 - 0.6 * float(i) / maxf(line.size() - 1, 1)
			var base := verts.size()
			verts.append(line[i] - side * w * 0.5 * taper)
			verts.append(line[i] + side * w * 0.5 * taper)
			if i > 0:
				indices.append_array(PackedInt32Array([base - 2, base - 1, base, base - 1, base + 1, base]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = indices
	var m := ArrayMesh.new()
	if verts.size() >= 4:
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m
