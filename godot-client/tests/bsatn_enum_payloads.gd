extends SceneTree

class PrimitivePayload extends RustEnum:
	const enum_options: Array[StringName] = [&"I16", &"F64", &"Bool", &"String"]

class NestedPayload extends RustEnum:
	const enum_options: Array[StringName] = [&"PrimitivePayload"]

var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	_check_payload(_primitive(0, 101), "0065003412", "i16 width and trailing field")
	_check_payload(_primitive(0, -32768), "0000803412", "signed i16 minimum")
	_check_payload(_primitive(0, 32767), "00ff7f3412", "signed i16 maximum")
	_check_payload(_primitive(1, 1.0), "01000000000000f03f3412", "f64 width and trailing field")
	_check_payload(_primitive(2, false), "02003412", "false payload")
	_check_payload(_primitive(2, true), "02013412", "true payload")
	_check_payload(_primitive(3, ""), "03000000003412", "empty string payload")
	_check_payload(_primitive(3, "A"), "0301000000413412", "string payload")
	var nested: NestedPayload = NestedPayload.new()
	nested.value = 0
	nested.data = _primitive(0, 101)
	_check_payload(nested, "000065003412", "nested enum payload")
	print("ENUM_PAYLOAD_CHECK ", JSON.stringify({"checks": _checks, "failures": _failures}))
	quit(0 if _failures == 0 else 1)


func _primitive(tag: int, payload: Variant) -> PrimitivePayload:
	var value: PrimitivePayload = PrimitivePayload.new()
	value.value = tag
	value.data = payload
	return value


func _check_payload(value: RustEnum, expected_hex: String, label: String) -> void:
	var serializer: BSATNSerializer = BSATNSerializer.new(null)
	var actual: PackedByteArray = serializer._serialize_arguments(
		[value, 0x1234], [&"Payload", &"U16"],
	)
	_checks += 1
	if serializer.has_error() or actual.hex_encode() != expected_hex:
		_failures += 1
		push_error("ENUM_PAYLOAD_CHECK: %s expected=%s actual=%s error=%s" % [
			label, expected_hex, actual.hex_encode(), serializer.get_last_error(),
		])
