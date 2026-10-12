extends SceneTree

const ROW_SIZE: int = 24

class WireRow extends _ModuleTableType:
	const BSATN_TYPES: Dictionary[StringName, StringName] = {
		&"id": &"I64", &"value": &"F32", &"position": &"Vector3"}
	var id: int = 0
	var value: float = 0.0
	var position: Vector3 = Vector3.ZERO

class OfflineClient extends SpacetimeDBClient:
	func _init_db(db: LocalDatabase) -> void:
		db._schema.module_types[&"WireRow"] = WireRow
		for table: StringName in [&"nearby", &"alias", &"events", &"unkeyed"]:
			db._schema.module_table_name_to_type_name[table] = &"WireRow"
			db._tables[table] = {}
			db._primary_key_cache[table] = &"" if table == &"unkeyed" else &"id"
			db._is_event_table_cache[table] = table == &"events"

	func _load_token_or_request() -> void:
		pass

class OfflineConnection extends SpacetimeDBConnection:
	var send_result: Error = OK
	var sends: int = 0

	func send_bytes(_bytes: PackedByteArray) -> Error:
		sends += 1
		return send_result

	func disconnect_from_server(_code: int = 1000, _reason: String = "Client initiated disconnect") -> void:
		_is_connected = false
		disconnected.emit()

var _client: OfflineClient
var _db: LocalDatabase
var _writer: BSATNSerializer
var _reader: BSATNDeserializer
var _connection: OfflineConnection
var _unique: Dictionary = {}
var _index: _ModuleTableUniqueIndex
var _trace: Array[String] = []
var _batches: Array[SpacetimeDBCacheBatch] = []
var _checks: Array[Dictionary] = []
var _failures: int = 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_client = OfflineClient.new()
	_client.debug_mode = false
	_client.use_threading = false
	_client.schema_path = "res://probe_schema"
	_client.connection_options = SpacetimeDBConnectionOptions.new()
	_client.connection_options.monitor_mode = false
	root.add_child(_client)
	await _client.initialize_and_connect()
	_db = _client.get_local_database()
	_writer = _client._serializer
	_reader = _client._deserializer
	_client._connection.free()
	_connection = OfflineConnection.new(_client.connection_options, "offline")
	_connection._is_connected = true
	_client._connection = _connection
	_client.add_child(_connection)
	_connection.set_process(false)
	_connection.disconnected.connect(_client._on_transport_disconnected)
	_client._begin_connection_generation()
	_client._session_ready = true
	_index = _ModuleTableUniqueIndex.new()
	_index.set_meta(&"table_name", "nearby")
	_index.set_meta(&"field_name", "id")
	_index._connect_cache_to_db(_unique, _db)
	_client.cache_batch_applied.connect(func(batch: SpacetimeDBCacheBatch) -> void:
		_batches.append(batch)
		_trace.append("applied:%d" % batch.query_set_id))
	_client.cache_batch_completed.connect(func(batch: SpacetimeDBCacheBatch) -> void:
		_trace.append("completed:%d" % batch.query_set_id))
	_client.row_inserted.connect(func(table: String, _row: Resource) -> void: _trace.append("insert:" + table))
	_client.row_updated.connect(func(table: String, _old: Resource, _row: Resource) -> void: _trace.append("update:" + table))
	_client.row_deleted.connect(func(table: String, _row: Resource) -> void: _trace.append("delete:" + table))
	_client.transaction_update_received.connect(func(_message: TransactionUpdateMessage) -> void:
		_trace.append("transaction"))

	var first: PackedByteArray = _row_bytes(1, 1.0)
	var second: PackedByteArray = _row_bytes(1, 2.0)
	_snapshot(1, [first, first])
	_check("snapshot counts duplicates but emits one global insert", _db.count_all_rows("nearby") == 1
		and _trace.count("insert:nearby") == 1 and _batches[-1].tables[0].inserts.size() == 2
		and _batches[-1].query_set_changes[0].inserts.size() == 1)
	var duplicate_snapshot: SubscribeAppliedMessage = _decoded_snapshot(1, [first])
	_check("duplicate snapshot delivery for active ID rejects without double counting", not _db.apply_database_subscription_applied(duplicate_snapshot)
		and _db.count_all_rows("nearby") == 1)
	_trace.clear()
	_snapshot(2, [first])
	_check("second-set duplicate snapshot has only scoped insertion", _trace == ["applied:2", "completed:2"]
		and _batches[-1].query_set_changes[0].inserts.size() == 1)
	_trace.clear()
	_transaction([_query_set_update(1, [_table("nearby", [], [first])])])
	_check("partial route delete retains generated reads and unique index", _db.count_all_rows("nearby") == 1
		and _db.get_all_rows("nearby").size() == 1 and _unique.has(1)
		and _batches[-1].query_set_changes[0].deletes.is_empty() and not _trace.has("delete:nearby"))
	_trace.clear()
	_leave(2, false)
	_check("empty unsubscribe retires full set without deleting another route", _unique.has(1)
		and _batches[-1].tables.is_empty() and _batches[-1].query_set_changes[0].deletes.size() == 1)
	_trace.clear()
	_leave(1, true, [first])
	_check("last occurrence removes cache and generated unique index once", _db.count_all_rows("nearby") == 0
		and _unique.is_empty() and _trace.count("delete:nearby") == 1)

	for reverse: bool in [false, true]:
		_snapshot(3, [first])
		_snapshot(4, [])
		_trace.clear()
		var parts: Array[DatabaseUpdateData] = [_query_set_update(3, [_table("nearby", [], [first])]),
			_query_set_update(4, [_table("nearby", [second])])]
		if reverse:
			parts.reverse()
		_transaction(parts)
		var indexed_row: _ModuleTableType = _unique.get(1)
		_check("cross-set replacement has one net update in either order (%s)" % reverse,
			_trace.count("update:nearby") == 1 and not _trace.has("insert:nearby") and not _trace.has("delete:nearby")
			and _db.get_row_by_pk("nearby", 1).get(&"value") == 2.0 and indexed_row != null and indexed_row.get(&"value") == 2.0)
		_check("all applied hooks stage before global callback and matching completions (%s)" % reverse,
			_trace == (["applied:4", "applied:3", "update:nearby", "completed:4", "completed:3", "transaction"]
			if reverse else ["applied:3", "applied:4", "update:nearby", "completed:3", "completed:4", "transaction"]))
		_leave(3, false)
		_leave(4, false)

	_snapshot(5, [first])
	_snapshot(6, [])
	_trace.clear()
	_transaction([_query_set_update(5, [_table("nearby", [], [first])]), _query_set_update(6, [_table("nearby", [first])]),
		_query_set_update(6, [_table("nearby", [first], [first])])])
	_check("same-version handoff and repeated set parts coalesce hooks", _trace == ["applied:5", "applied:6",
		"completed:5", "completed:6", "transaction"] and _batches[-1].tables.size() == 2)
	_trace.clear()
	var before: _ModuleTableType = _db.get_row_by_pk("nearby", 1)
	var invalid: TransactionUpdateMessage = TransactionUpdateMessage.new()
	invalid.query_sets = [_query_set_update(6, [_table("nearby", [], [second])]), _query_set_update(5, [_table("alias", [second])])]
	_check("unknown old-version delete rejects all tables without hooks", not _db.apply_transaction_update(invalid)
		and _trace.is_empty() and _db.get_row_by_pk("nearby", 1) == before and _db.count_all_rows("alias") == 0)
	invalid.query_sets = [_query_set_update(6, [_table("nearby", [], [first, first])])]
	_check("count underflow preserves membership", not _db.apply_transaction_update(invalid)
		and _db.get_row_by_pk("nearby", 1) == before)
	invalid.query_sets = [_query_set_update(5, [_table("nearby", [second])])]
	_check("conflicting final PK versions are not last-writer wins", not _db.apply_transaction_update(invalid)
		and _db.get_row_by_pk("nearby", 1) == before)
	var no_keys: TableUpdateData = _table("nearby", [second])
	no_keys.insert_row_keys.clear()
	invalid.query_sets = [_query_set_update(5, [no_keys])]
	_check("missing exact keys reject without serializer fallback", not _db.apply_transaction_update(invalid))
	_transaction([_query_set_update(5, [_table("alias", [second])])])
	_check("two table names sharing one row type have separate caches", _db.get_row_by_pk("alias", 1).get(&"value") == 2.0
		and _db.get_row_by_pk("nearby", 1).get(&"value") == 1.0)
	_leave(5, false)
	_leave(6, false)

	var positive_zero: PackedByteArray = _row_bytes(2, 0.0)
	var negative_zero: PackedByteArray = positive_zero.duplicate()
	negative_zero[11] = 128
	_snapshot(7, [positive_zero])
	var changed_nested: PackedByteArray = negative_zero.duplicate()
	changed_nested.encode_float(12, 9.0)
	_transaction([_query_set_update(7, [_table("nearby", [negative_zero], [positive_zero])])])
	_check("signed zero is an exact-byte update", _batches[-1].tables[0].updates.size() == 1
		and positive_zero.hex_encode() != negative_zero.hex_encode())
	_transaction([_query_set_update(7, [_table("nearby", [changed_nested], [negative_zero])])])
	var nested_position: Vector3 = _db.get_row_by_pk("nearby", 2).get(&"position")
	_check("nested ordered fields remain part of the row version", nested_position.x == 9.0)
	_leave(7, false)

	_snapshot(13, [])
	_trace.clear()
	_transaction([_query_set_update(13, [_table("events", [first], [first]), _table("unkeyed", [first], [first])])])
	_check("event and no-PK rows stay uncached with raw callbacks", _db.count_all_rows("events") == 0
		and _db.count_all_rows("unkeyed") == 0 and _batches[-1].query_set_changes.is_empty()
		and _trace == ["applied:13", "insert:events", "delete:events", "insert:unkeyed", "delete:unkeyed", "completed:13", "transaction"])
	_trace.clear()
	_transaction([_query_set_update(13, [_table("events", [first]), _table("unkeyed", [first]), _table("events", [second])])])
	_check("byte-backed uncached A/B/A parts preserve wire callback order", _trace == ["applied:13",
		"insert:events", "insert:unkeyed", "insert:events", "completed:13", "transaction"])
	_snapshot(14, [])
	_trace.clear()
	_transaction([_query_set_update(13, [_table("events", [first])]), _query_set_update(14, [_table("unkeyed", [first])]),
		_query_set_update(13, [_table("events", [second])])])
	_check("repeated query-set parts retain uncached A/B/A order", _trace == ["applied:13", "applied:14",
		"insert:events", "insert:unkeyed", "insert:events", "completed:13", "completed:14", "transaction"])
	_leave(14, false)
	_leave(13, false)

	_snapshot(8, [first])
	var error_message: SubscriptionErrorMessage = SubscriptionErrorMessage.new()
	error_message.query_id = QueryIdData.new(8)
	_client._handle_parsed_message(error_message)
	_check("active SubscriptionError retires rows and handle", not _unique.has(1)
		and not _client.current_subscriptions.has(8) and not _db.has_active_query_sets())
	_snapshot(9, [first])
	var old_handle: SpacetimeDBSubscription = _client.current_subscriptions[9]
	var old_generation: int = _client._connection_generation
	_client.disconnect_db(false)
	_check("false disconnect retains offline rows and indexes", _db.get_row_by_pk("nearby", 1) != null and _unique.has(1))
	var late: SpacetimeDBClient.ParsedDelivery = SpacetimeDBClient.ParsedDelivery.new()
	late.generation = old_generation
	var late_transaction: TransactionUpdateMessage = TransactionUpdateMessage.new()
	late_transaction.query_sets = [_query_set_update(10, [_table("nearby", [second])])]
	late.message = late_transaction
	_client._result_queue.append(late)
	_connection._is_connected = true
	_client._begin_connection_generation()
	_trace.clear()
	_client.connected.connect(func(_identity: PackedByteArray, _token: String) -> void:
		_check("new connected callback sees empty generated cache/index", _unique.is_empty()
			and _db.count_all_rows("nearby") == 0 and not _db.has_active_query_sets()))
	_client._handle_delivery(IdentityTokenMessage.new(), _client._connection_generation)
	_snapshot(10, [])
	_client._process_results_asynchronously()
	_client._on_packet_decode_failed("old deferred failure", old_generation)
	_check("new generation retires handles and ignores queued old result", old_handle.ended
		and not old_handle.active and _unique.is_empty() and _client.current_subscriptions.has(10) and _client._session_ready)
	_leave(10, false)
	_snapshot(11, [])
	_check("active empty set rejects save at call boundary", _client.one_off_query("SELECT * FROM nearby", Callable(), true) == ERR_BUSY)
	var end_allowed: Array[bool] = []
	_client.current_subscriptions[11].end.connect(func() -> void:
		end_allowed.append(_client.one_off_query("SELECT * FROM nearby", Callable(), true) == OK))
	_leave(11, false)
	_check("save issued synchronously inside end sees retired bookkeeping", end_allowed == [true])
	_client._pending_one_off_query_callbacks.clear()

	var saved: OneOffQueryResponseMessage = _decoded_one_off(100, [first])
	_client._pending_one_off_query_callbacks[100] = SpacetimeDBPendingOneOffQuery.new(100,
		func(_response: OneOffQueryResponseMessage) -> void: pass, true)
	_client._handle_parsed_message(saved)
	_check("legal saved result is unscoped without pseudo membership", _db.get_row_by_pk("nearby", 1) != null
		and not _db.has_active_query_sets() and _batches[-1].query_set_id == SpacetimeDBCacheBatch.NO_QUERY_SET)
	_client._handle_transaction_update(TransactionUpdateMessage.new())
	_check("empty transaction preserves legal saved cache and session", _unique.has(1) and _client._session_ready)
	_connection.send_result = ERR_CANT_CONNECT
	var rejected_subscription: SpacetimeDBSubscription = _client.subscribe(["SELECT * FROM nearby"])
	_check("failed subscribe preserves saved rows", rejected_subscription.error == ERR_CANT_CONNECT and _unique.has(1))
	rejected_subscription.free()
	_connection.send_result = OK
	var accepted_subscription: SpacetimeDBSubscription = _client.subscribe(["SELECT * FROM nearby"])
	_check("accepted subscribe retires saved rows before its snapshot", _unique.is_empty() and _db.count_all_rows("nearby") == 0)
	_client._pending_subscriptions.erase(accepted_subscription.query_id)
	accepted_subscription.queue_free()
	var results_delivered: Array[bool] = []
	_client._pending_one_off_query_callbacks[101] = SpacetimeDBPendingOneOffQuery.new(101,
		func(_response: OneOffQueryResponseMessage) -> void:
			results_delivered.append(true)
			_client.subscribe(["SELECT * FROM nearby"]), true)
	_client._handle_parsed_message(_decoded_one_off(101, [second]))
	_check("response callback delivers results but new subscription rejects save", results_delivered == [true]
		and _db.count_all_rows("nearby") == 0 and not _client._pending_subscriptions.is_empty())
	_client._reset_connection_cache()
	_snapshot(12, [first])
	_client.disconnect_db(true)
	_check("explicit true disconnect clears rows/counts/index immediately", _unique.is_empty() and not _db.has_active_query_sets())
	await _malformed_packet_cases(first, second)

	var result: Dictionary = {"passed": _failures == 0, "failed": _failures, "checks": _checks,
		"scope": "offline exact-byte cache/lifecycle fixtures; no live server or worker thread"}
	print("CACHE_OVERLAP_CHECK ", JSON.stringify(result))
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty():
		var output: FileAccess = FileAccess.open(args[0], FileAccess.WRITE)
		output.store_string(JSON.stringify(result, "\t") + "\n")
	_client.free()
	quit(1 if _failures > 0 else 0)

func _malformed_packet_cases(first: PackedByteArray, second: PackedByteArray) -> void:
	_writer._reset_buffer()
	_writer.write_u8(SpacetimeDBServerMessage.SUBSCRIBE_APPLIED)
	_writer.write_u32_le(18)
	_writer.write_u32_le(18)
	_writer.write_u32_le(1)
	_writer.write_string_with_u32_len("nearby")
	_writer.write_u8(0)
	_writer.write_u16_le(20)
	_writer.write_u32_le(20)
	_writer.write_bytes(first.slice(0, 20))
	var vector_packet: PackedByteArray = _writer._spb.data_array.duplicate()
	var vector_message: Resource = _reader._parse_message_from_stream(_stream(vector_packet))
	_check("truncated Vector3 preserves first component read error without typed assignment", vector_message == null
		and _reader.has_error() and _reader.get_last_error() == "BSATNDeserializer Error: Attempted to read 4 bytes past end of buffer (size: 20). (at approx. position 20)")
	var failures: Array[int] = []
	_client.connection_error.connect(func(code: int, _reason: String) -> void: failures.append(code))
	_connection._is_connected = true
	_client._begin_connection_generation()
	_client._handle_delivery(IdentityTokenMessage.new(), _client._connection_generation)
	_snapshot(15, [first])
	var old_generation: int = _client._connection_generation
	var packet: PackedByteArray = _snapshot_packet(16, [second])
	packet.append_array(_malformed_snapshot_packet(16, first))
	var decoded: Array[Resource] = _client._parse_packet_and_get_resource(packet, old_generation)
	_check("valid packet prefix plus malformed row returns no partial messages", decoded.is_empty()
		and _db.get_row_by_pk("nearby", 1).get(&"value") == 1.0 and _unique.has(1))
	_check("current synchronous row failure invalidates session until resnapshot", failures == [ERR_PARSE_ERROR]
		and not _client._accepting_packets and not _client._session_ready and not _connection._is_connected)
	_client._handle_delivery(IdentityTokenMessage.new(), old_generation)
	_check("failed generation cannot seed or reset retained offline rows", not _client._session_ready and _unique.has(1))
	_connection._is_connected = true
	_client._begin_connection_generation()
	_client._handle_delivery(IdentityTokenMessage.new(), _client._connection_generation)
	_snapshot(17, [first])
	var was_processing: bool = _client.is_processing()
	_client.set_process(false)
	_client.use_threading = true
	decoded = _client._parse_packet_and_get_resource(_malformed_snapshot_packet(18, first), old_generation)
	await process_frame
	_client.use_threading = false
	_check("stale-origin deferred row failure cannot terminate new session", decoded.is_empty()
		and failures == [ERR_PARSE_ERROR] and _client._session_ready and _client._accepting_packets
		and _connection._is_connected and _unique.has(1) and _client.current_subscriptions.has(17))
	_client.use_threading = true
	decoded = _client._parse_packet_and_get_resource(_malformed_snapshot_packet(18, first), _client._connection_generation)
	await process_frame
	_client.use_threading = false
	_client.set_process(was_processing)
	_check("current-origin deferred row failure requires reconnect", decoded.is_empty()
		and failures == [ERR_PARSE_ERROR, ERR_PARSE_ERROR] and not _client._session_ready
		and not _client._accepting_packets and not _connection._is_connected and _unique.has(1))
	_connection._is_connected = true
	_client._begin_connection_generation()
	_client._handle_delivery(IdentityTokenMessage.new(), _client._connection_generation)
	var fresh_row: PackedByteArray = _row_bytes(2, 2.0)
	var control: SpacetimeDBSubscription = SpacetimeDBSubscription.create(_client, 21, [])
	_client.add_child(control)
	_client._pending_subscriptions[21] = control
	var valid_packet: PackedByteArray = PackedByteArray([SpacetimeDBConnection.CompressionPreference.NONE])
	valid_packet.append_array(_snapshot_packet(21, [fresh_row]))
	_client._on_websocket_message_received(valid_packet)
	_check("valid compression-path control applies through actual receive handler", _unique.has(2)
		and _client.current_subscriptions.has(21) and _client._accepting_packets)
	_connection._is_connected = true
	_client._begin_connection_generation()
	_client._handle_delivery(IdentityTokenMessage.new(), _client._connection_generation)
	_snapshot(22, [first])
	var pending: SpacetimeDBSubscription = SpacetimeDBSubscription.create(_client, 23, [])
	_client.add_child(pending)
	_client._pending_subscriptions[23] = pending
	valid_packet = PackedByteArray([SpacetimeDBConnection.CompressionPreference.NONE])
	valid_packet.append_array(_snapshot_packet(23, [fresh_row]))
	_client._on_websocket_message_received(PackedByteArray([255, 0]))
	_client._on_websocket_message_received(valid_packet)
	_check("synchronous compression failure rejects later packet before deferred work", _unique.has(1)
		and not _unique.has(2) and not _client.current_subscriptions.has(23)
		and failures == [ERR_PARSE_ERROR, ERR_PARSE_ERROR, ERR_PARSE_ERROR]
		and not _client._session_ready and not _client._accepting_packets and not _connection._is_connected)
	_client.disconnect_db(true)

func _snapshot_packet(scope: int, rows: Array[PackedByteArray]) -> PackedByteArray:
	_writer._reset_buffer()
	_writer.write_u8(SpacetimeDBServerMessage.SUBSCRIBE_APPLIED)
	_writer.write_u32_le(scope)
	_writer.write_u32_le(scope)
	_writer.write_u32_le(1)
	_writer.write_string_with_u32_len("nearby")
	_row_list(rows)
	return _writer._spb.data_array.duplicate()

func _malformed_snapshot_packet(scope: int, row: PackedByteArray) -> PackedByteArray:
	_writer._reset_buffer()
	_writer.write_u8(SpacetimeDBServerMessage.SUBSCRIBE_APPLIED)
	_writer.write_u32_le(scope)
	_writer.write_u32_le(scope)
	_writer.write_u32_le(1)
	_writer.write_string_with_u32_len("nearby")
	_writer.write_u8(0)
	_writer.write_u16_le(8)
	_writer.write_u32_le(8)
	_writer.write_bytes(row.slice(0, 8))
	return _writer._spb.data_array.duplicate()

func _row_bytes(id: int, value: float) -> PackedByteArray:
	_writer._reset_buffer()
	_writer.write_i64_le(id)
	_writer.write_f32_le(value)
	_writer.write_f32_le(1.0)
	_writer.write_f32_le(2.0)
	_writer.write_f32_le(3.0)
	return _writer._spb.data_array.duplicate()

func _row_list(rows: Array[PackedByteArray]) -> void:
	_writer.write_u8(0)
	_writer.write_u16_le(ROW_SIZE)
	_writer.write_u32_le(rows.size() * ROW_SIZE)
	for bytes: PackedByteArray in rows:
		_writer.write_bytes(bytes)

func _keys(rows: Array[PackedByteArray]) -> Array[String]:
	var keys: Array[String] = []
	for bytes: PackedByteArray in rows:
		keys.append(bytes.hex_encode())
	return keys

func _stream(bytes: PackedByteArray) -> StreamPeerBuffer:
	var stream: StreamPeerBuffer = StreamPeerBuffer.new()
	stream.big_endian = false
	stream.data_array = bytes
	return stream

func _table(name: String, inserts: Array[PackedByteArray] = [], deletes: Array[PackedByteArray] = []) -> TableUpdateData:
	_writer._reset_buffer()
	_writer.write_string_with_u32_len(name)
	_writer.write_u32_le(1)
	_writer.write_u8(0)
	_row_list(inserts)
	_row_list(deletes)
	_reader.clear_error()
	var table: TableUpdateData = _reader._read_table_update_instance(_stream(_writer._spb.data_array))
	var insert_keys: Array[String] = []
	var delete_keys: Array[String] = []
	for bytes: PackedByteArray in inserts:
		insert_keys.append(bytes.hex_encode())
	for bytes: PackedByteArray in deletes:
		delete_keys.append(bytes.hex_encode())
	_check("transaction decoder retains aligned exact bytes", table != null and not _reader.has_error()
		and table.insert_row_keys == insert_keys and table.delete_row_keys == delete_keys)
	return table

func _decoded_snapshot(scope: int, rows: Array[PackedByteArray]) -> SubscribeAppliedMessage:
	_writer._reset_buffer()
	_writer.write_u32_le(scope)
	_writer.write_u32_le(scope)
	_writer.write_u32_le(1)
	_writer.write_string_with_u32_len("nearby")
	_row_list(rows)
	_reader.clear_error()
	var message: SubscribeAppliedMessage = _reader._read_subscripton_applied_message(_stream(_writer._spb.data_array))
	_check("snapshot decoder retains every exact occurrence", message != null and not _reader.has_error()
		and message.tables[0].insert_row_keys == _keys(rows))
	return message

func _snapshot(scope: int, rows: Array[PackedByteArray]) -> void:
	var subscription: SpacetimeDBSubscription = SpacetimeDBSubscription.create(_client, scope, [])
	_client.add_child(subscription)
	_client._pending_subscriptions[scope] = subscription
	_client._handle_parsed_message(_decoded_snapshot(scope, rows))

func _leave(scope: int, with_payload: bool, rows: Array[PackedByteArray] = []) -> void:
	_writer._reset_buffer()
	_writer.write_u32_le(scope)
	_writer.write_u32_le(scope)
	_writer.write_u8(0 if with_payload else 1)
	if with_payload:
		_writer.write_u32_le(1)
		_writer.write_string_with_u32_len("nearby")
		_row_list(rows)
	_reader.clear_error()
	var message: UnsubscribeAppliedMessage = _reader._read_unsubscription_applied_message(_stream(_writer._spb.data_array))
	_check("unsubscribe decoder retains aligned payload bytes", message != null and not _reader.has_error()
		and (not with_payload or message.tables[0].delete_row_keys == _keys(rows)))
	_client._handle_parsed_message(message)

func _decoded_one_off(request: int, rows: Array[PackedByteArray]) -> OneOffQueryResponseMessage:
	_writer._reset_buffer()
	_writer.write_u32_le(request)
	_writer.write_u8(0)
	_writer.write_u32_le(1)
	_writer.write_string_with_u32_len("nearby")
	_row_list(rows)
	_reader.clear_error()
	var message: OneOffQueryResponseMessage = _reader._read_one_off_query_message(_stream(_writer._spb.data_array))
	_check("one-off decoder retains aligned exact bytes", message != null and not _reader.has_error()
		and message.result_ok[0].insert_row_keys == _keys(rows))
	return message

func _query_set_update(scope: int, tables: Array[TableUpdateData]) -> DatabaseUpdateData:
	var update: DatabaseUpdateData = DatabaseUpdateData.new()
	update.query_id = QueryIdData.new(scope)
	update.tables = tables
	return update

func _transaction(parts: Array[DatabaseUpdateData]) -> void:
	var message: TransactionUpdateMessage = TransactionUpdateMessage.new()
	message.query_sets = parts
	_client._handle_transaction_update(message)

func _check(label: String, passed: bool) -> void:
	_checks.append({"case": label, "passed": passed})
	if not passed:
		_failures += 1
		push_error("CACHE_OVERLAP_CHECK: " + label)
