extends SceneTree

var _failed: bool = false


func _initialize() -> void:
	var decoder: BSATNDeserializer = BSATNDeserializer.new(null, null)
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(262144)
	for index: int in bytes.size():
		bytes[index] = index % 256
	var stream: StreamPeerBuffer = _byte_stream(bytes)
	stream.put_u32(123456)
	stream.seek(0)
	var started: int = Time.get_ticks_usec()
	var decoded: PackedByteArray = decoder._parse_generic_type(stream, &"vec_U8")
	var byte_ms: float = float(Time.get_ticks_usec() - started) / 1000.0
	_expect(decoded == bytes and not decoder.has_error(), "large byte vector values")
	_expect(decoder.read_u32_le(stream) == 123456, "byte vector stream boundary")

	stream = _byte_stream(PackedByteArray())
	stream.seek(0)
	decoded = decoder._parse_generic_type(stream, &"vec_U8")
	_expect(decoded.is_empty() and not decoder.has_error(), "empty byte vector")
	stream = StreamPeerBuffer.new()
	stream.put_u32(2)
	stream.put_u32(3)
	stream.put_data(PackedByteArray([0, 127, 255]))
	stream.put_u32(1)
	stream.put_u8(42)
	stream.seek(0)
	var nested: Array[PackedByteArray] = []
	nested.assign(Array(decoder._parse_generic_type(stream, &"vec_vec_U8")))
	var first: PackedByteArray = nested[0]
	var second: PackedByteArray = nested[1]
	_expect(first == PackedByteArray([0, 127, 255]) and second == PackedByteArray([42]), "nested byte vectors")

	stream = StreamPeerBuffer.new()
	stream.put_u32(262144)
	var packed: PackedFloat32Array = PackedFloat32Array()
	packed.resize(262144)
	for index: int in packed.size():
		packed[index] = float(index % 1024) * 0.25 - 128.0
	stream.put_data(packed.to_byte_array())
	stream.put_u32(654321)
	stream.seek(0)
	started = Time.get_ticks_usec()
	var floats: Array[float] = decoder._parse_generic_type(stream, &"vec_F32")
	var float_ms: float = float(Time.get_ticks_usec() - started) / 1000.0
	_expect(PackedFloat32Array(floats) == packed and not decoder.has_error(), "large float vector values")
	_expect(decoder.read_u32_le(stream) == 654321, "float vector stream boundary")
	stream = StreamPeerBuffer.new()
	stream.put_u32(0)
	stream.seek(0)
	floats = decoder._parse_generic_type(stream, &"vec_F32")
	_expect(floats.is_empty() and not decoder.has_error(), "empty float vector")
	stream = StreamPeerBuffer.new()
	stream.put_u32(3)
	stream.put_float(-INF)
	stream.put_float(INF)
	stream.put_float(NAN)
	stream.seek(0)
	floats = decoder._parse_generic_type(stream, &"vec_F32")
	_expect(floats[0] == -INF and floats[1] == INF and is_nan(floats[2]), "float special values")

	print("VECTOR_DECODE_EXPECTED_ERRORS_BEGIN")
	stream = _byte_stream(PackedByteArray([1, 2]))
	stream.data_array = stream.data_array.slice(0, 5)
	stream.seek(0)
	decoded = decoder._parse_generic_type(stream, &"vec_U8")
	_expect(decoder.has_error() and decoded.is_empty(), "truncated byte vector rejected")
	decoder.clear_error()
	stream = StreamPeerBuffer.new()
	stream.put_u32(BSATNDeserializer.MAX_BYTE_ARRAY_LEN + 1)
	stream.seek(0)
	decoded = decoder._parse_generic_type(stream, &"vec_U8")
	_expect(decoder.has_error() and decoded.is_empty(), "oversized byte vector rejected")
	decoder.clear_error()
	stream = StreamPeerBuffer.new()
	stream.put_u32(2)
	stream.put_float(1.0)
	stream.seek(0)
	floats = decoder._parse_generic_type(stream, &"vec_F32")
	_expect(decoder.has_error() and floats.is_empty(), "truncated float vector rejected")
	decoder.clear_error()
	stream = StreamPeerBuffer.new()
	stream.put_u32(ceili(float(BSATNDeserializer.MAX_BYTE_ARRAY_LEN) / 4.0) + 1)
	stream.seek(0)
	floats = decoder._parse_generic_type(stream, &"vec_F32")
	_expect(decoder.has_error() and floats.is_empty(), "oversized float vector rejected")
	print("VECTOR_DECODE_EXPECTED_ERRORS_END")
	print("VECTOR_DECODE_CHECK ", JSON.stringify({"passed": not _failed, "elements": 262144,
		"byte_decode_ms": byte_ms, "float_decode_ms": float_ms}))
	quit(1 if _failed else 0)


func _byte_stream(bytes: PackedByteArray) -> StreamPeerBuffer:
	var stream: StreamPeerBuffer = StreamPeerBuffer.new()
	stream.put_u32(bytes.size())
	stream.put_data(bytes)
	return stream


func _expect(passed: bool, label: String) -> void:
	if not passed:
		_failed = true
		push_error("VECTOR_DECODE_CHECK: " + label)
