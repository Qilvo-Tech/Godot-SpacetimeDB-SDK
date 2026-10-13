extends SceneTree

class ReferenceDecoder extends BSATNDeserializer:
	func _read_native_arraylike(spb: StreamPeerBuffer, kind: StringName) -> Variant:
		if kind != &"Vector3":
			return super._read_native_arraylike(spb, kind)
		var components: Array[float] = []
		for _index: int in range(3):
			var component: float = _parse_generic_type(spb, &"F32")
			if has_error():
				return null
			components.append(component)
		return Vector3(components[0], components[1], components[2])

var _checks: int = 0
var _failed: int = 0

func _initialize() -> void:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("", "res://tests/fixtures/vector3_schema", false)
	var candidate: BSATNDeserializer = BSATNDeserializer.new(schema, null)
	var reference: ReferenceDecoder = ReferenceDecoder.new(schema, null)
	var patterns: Array[String] = ["00000080000000000000803f", "0000807f000080ff0000c07f",
		"01000000ffff7f000000803f", "000060c00000003f000000c1"]
	for pattern: String in patterns:
		for big_endian: bool in [false, true]:
			var bytes: PackedByteArray = pattern.hex_decode()
			bytes.append_array(PackedByteArray([4, 3, 2, 1]))
			var a: StreamPeerBuffer = _stream(bytes, big_endian)
			var b: StreamPeerBuffer = _stream(bytes, big_endian)
			var actual: Vector3 = candidate._read_native_arraylike(a, &"Vector3")
			var expected: Vector3 = reference._read_native_arraylike(b, &"Vector3")
			var actual_array: PackedVector3Array = PackedVector3Array([actual])
			var expected_array: PackedVector3Array = PackedVector3Array([expected])
			_check(actual_array.to_byte_array() == expected_array.to_byte_array(), "float bit equivalence")
			_check(a.get_position() == b.get_position() and a.get_position() == 12, "vector boundary")
			_check(a.get_u32() == 0x01020304 and b.get_u32() == 0x01020304, "little endian and trailing field")
	print("VECTOR3_EXPECTED_ERRORS_BEGIN")
	for length: int in range(12):
		candidate.clear_error()
		reference.clear_error()
		var bytes: PackedByteArray = PackedByteArray()
		bytes.resize(length)
		var a: StreamPeerBuffer = _stream(bytes, false)
		var b: StreamPeerBuffer = _stream(bytes, false)
		var actual: Variant = candidate._read_native_arraylike(a, &"Vector3")
		var expected: Variant = reference._read_native_arraylike(b, &"Vector3")
		_check(actual == null and expected == null and candidate.has_error() and reference.has_error(), "truncation retained error")
		_check(a.get_position() == b.get_position() and candidate.get_last_error() == reference.get_last_error(), "truncated component error parity")
	print("VECTOR3_EXPECTED_ERRORS_END")
	print("VECTOR3_EQUIVALENCE ", JSON.stringify({"checks": _checks, "failed": _failed}))
	quit(1 if _failed else 0)

func _stream(bytes: PackedByteArray, big_endian: bool) -> StreamPeerBuffer:
	var stream: StreamPeerBuffer = StreamPeerBuffer.new()
	stream.data_array = bytes
	stream.big_endian = big_endian
	return stream

func _check(passed: bool, label: String) -> void:
	_checks += 1
	if not passed:
		_failed += 1
		push_error("VECTOR3_EQUIVALENCE: " + label)
