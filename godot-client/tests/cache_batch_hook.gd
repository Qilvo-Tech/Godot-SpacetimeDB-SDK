extends SceneTree

class FixtureRow extends _ModuleTableType:
	var id: int
	var value: int

	func _init(p_id: int = 0, p_value: int = 0) -> void:
		id = p_id
		value = p_value

class OfflineClient extends SpacetimeDBClient:
	var token_connect_skipped: bool = false

	func _init_db(local_db: LocalDatabase) -> void:
		for table_name: StringName in [&"nearby", &"own", &"events"]:
			local_db._tables[table_name] = {}
			local_db._primary_key_cache[table_name] = &"id"
			local_db._is_event_table_cache[table_name] = table_name == &"events"

	func _load_token_or_request() -> void:
		token_connect_skipped = true

var _client: OfflineClient
var _db: LocalDatabase
var _batches: Array[SpacetimeDBCacheBatch] = []
var _trace: Array[String] = []
var _checks: Array[Dictionary] = []
var _failures: int = 0
var _expected_nearby: FixtureRow
var _expected_own: FixtureRow

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_client = OfflineClient.new()
	_client.debug_mode = false
	_client.schema_path = "res://probe_schema"
	_client.connection_options = SpacetimeDBConnectionOptions.new()
	_client.connection_options.monitor_mode = false
	root.add_child(_client)
	await _client.initialize_and_connect()
	_db = _client.get_local_database()
	_check("offline initialization avoids network and workers", _client.token_connect_skipped
		and not _client._connection._connection_requested and _client.deserializer_worker == null)
	_client.cache_batch_applied.connect(_on_batch)
	_client.row_inserted.connect(func(table_name: String, _row: Resource) -> void:
		_trace.append(table_name + ":signal-insert"))
	_client.row_updated.connect(func(table_name: String, _old_row: Resource, _new_row: Resource) -> void:
		_trace.append(table_name + ":signal-update"))
	_client.row_deleted.connect(func(table_name: String, _row: Resource) -> void:
		_trace.append(table_name + ":signal-delete"))
	_client.row_transactions_completed.connect(func(table_name: String) -> void:
		_trace.append(table_name + ":signal-complete"))
	_client.transaction_update_received.connect(func(_message: TransactionUpdateMessage) -> void:
		_trace.append("transaction-complete"))
	for table_name: StringName in [&"nearby", &"own"]:
		_db.subscribe_to_inserts(table_name, _on_insert.bind(table_name))
		_db.subscribe_to_updates(table_name, _on_update.bind(table_name))
		_db.subscribe_to_deletes(table_name, _on_delete.bind(table_name))
		_db.subscribe_to_transactions_completed(table_name, _on_complete.bind(table_name))

	var retained: FixtureRow = FixtureRow.new(99, 999)
	_db._tables[&"nearby"][retained.id] = retained
	var nearby_before: FixtureRow = FixtureRow.new(1, 10)
	var own_before: FixtureRow = FixtureRow.new(1, 100)
	_expected_nearby = nearby_before
	_expected_own = own_before
	var snapshot: SubscribeAppliedMessage = SubscribeAppliedMessage.new()
	snapshot.query_id.id = 7
	snapshot.tables = [_table("Nearby", [nearby_before]), _table("Own", [own_before])]
	_db.apply_database_subscription_applied(snapshot)
	_check("snapshot scope and phase", _last_batch().query_set_id == 7
		and _last_batch().phase == SpacetimeDBCacheBatch.Phase.SNAPSHOT)
	_check("snapshot reports decoded rows without retained stale rows", _last_batch().tables[0].inserts == [nearby_before]
		and _db.get_row_by_pk("nearby", 99) == retained)
	_check("snapshot callback order unchanged", _trace == ["batch:7:0", "nearby:insert", "nearby:signal-insert",
		"nearby:complete", "nearby:signal-complete", "own:insert", "own:signal-insert",
		"own:complete", "own:signal-complete"])

	_trace.clear()
	var nearby_after: FixtureRow = FixtureRow.new(1, 20)
	var own_after: FixtureRow = FixtureRow.new(1, 200)
	_expected_nearby = nearby_after
	_expected_own = own_after
	_db.apply_database_update(_transaction(7, [_table("nearby", [nearby_after], [nearby_before]),
		_table("own", [own_after], [own_before])]))
	var nearby_changes: SpacetimeDBCacheBatch.TableChanges = _last_batch().tables[0]
	_check("same-PK replacement retains decoded insert and delete", nearby_changes.inserts == [nearby_after]
		and nearby_changes.deletes == [nearby_before])
	_check("same-PK replacement records exact old/new resources", nearby_changes.updates.size() == 1
		and nearby_changes.updates[0].old_row == nearby_before and nearby_changes.updates[0].new_row == nearby_after)
	_check("same-PK replacement keeps new cache row", _db.get_row_by_pk("nearby", 1) == nearby_after)
	_check("replacement callback order unchanged", _trace == ["batch:7:1", "nearby:update", "nearby:signal-update",
		"nearby:complete", "nearby:signal-complete", "own:update", "own:signal-update",
		"own:complete", "own:signal-complete"])
	_expected_nearby = null
	_expected_own = null

	_db.unsubscribe_from_inserts(&"nearby", _on_insert.bind(&"nearby"))
	_db.unsubscribe_from_updates(&"nearby", _on_update.bind(&"nearby"))
	_db.unsubscribe_from_deletes(&"nearby", _on_delete.bind(&"nearby"))
	_db.unsubscribe_from_transactions_completed(&"nearby", _on_complete.bind(&"nearby"))
	_trace.clear()
	var listenerless: FixtureRow = FixtureRow.new(2, 30)
	_db.apply_database_update(_transaction(9, [_table("nearby", [listenerless])]))
	_check("listenerless insert still appears in batch", _last_batch().tables[0].inserts == [listenerless]
		and _trace == ["batch:9:1"])
	var listenerless_new: FixtureRow = FixtureRow.new(2, 40)
	_db.apply_database_update(_transaction(9, [_table("nearby", [listenerless_new], [listenerless])]))
	_check("listenerless replacement still appears in batch", _last_batch().tables[0].updates.size() == 1
		and _last_batch().tables[0].updates[0].old_row == listenerless
		and _last_batch().tables[0].updates[0].new_row == listenerless_new)
	_db.apply_database_update(_transaction(9, [_table("nearby", [], [listenerless_new])]))
	_check("listenerless deletion still appears in batch", _last_batch().tables[0].deletes == [listenerless_new]
		and _db.get_row_by_pk("nearby", 2) == null)

	_trace.clear()
	var leave: UnsubscribeAppliedMessage = UnsubscribeAppliedMessage.new()
	leave.query_id.id = 9
	leave.tables = [_table("nearby", [], [listenerless_new])]
	_db.apply_database_unsubscription_applied(leave)
	_check("leave scope includes deletion absent from retained cache", _last_batch().query_set_id == 9
		and _last_batch().phase == SpacetimeDBCacheBatch.Phase.UNSUBSCRIBE
		and _last_batch().tables[0].deletes == [listenerless_new] and _trace == ["batch:9:2"])

	_trace.clear()
	var subscription: SpacetimeDBSubscription = SpacetimeDBSubscription.create(_client, 44, [])
	_client.add_child(subscription)
	subscription.applied.connect(func() -> void: _trace.append("subscription-applied"))
	subscription.end.connect(func() -> void: _trace.append("subscription-ended"))
	_client._pending_subscriptions[44] = subscription
	var empty_snapshot: SubscribeAppliedMessage = SubscribeAppliedMessage.new()
	empty_snapshot.query_id.id = 44
	_client._handle_parsed_message(empty_snapshot)
	_check("empty snapshot identifies scope before applied callback", _last_batch().tables.is_empty()
		and _trace == ["batch:44:0", "subscription-applied"] and subscription.active)
	_trace.clear()
	var empty_leave: UnsubscribeAppliedMessage = UnsubscribeAppliedMessage.new()
	empty_leave.query_id.id = 44
	_client._handle_parsed_message(empty_leave)
	_check("empty leave identifies scope before end callback", _last_batch().tables.is_empty()
		and _trace == ["batch:44:2", "subscription-ended"] and subscription.ended)

	_trace.clear()
	var event: FixtureRow = FixtureRow.new(3, 50)
	_db.apply_database_update(_transaction(20, [_table("events", [event], [event])]))
	_check("event rows remain uncached and decoded", _db.count_all_rows("events") == 0
		and _last_batch().tables[0].inserts == [event] and _last_batch().tables[0].deletes == [event]
		and _last_batch().tables[0].updates.is_empty())
	_check("event callbacks retain original order", _trace == ["batch:20:1", "events:signal-insert", "events:signal-delete"])

	_trace.clear()
	var sets: TransactionUpdateMessage = TransactionUpdateMessage.new()
	sets.query_sets = [_transaction(31, [_table("nearby", [FixtureRow.new(4, 60)])]),
		_transaction(32, [_table("nearby", [FixtureRow.new(4, 70)])])]
	_client._handle_transaction_update(sets)
	_check("transaction preserves separate query-set scope and final callback", _trace == ["batch:31:1", "batch:32:1", "transaction-complete"]
		and _batches[-2].tables[0].inserts[0].get("value") == 60
		and _last_batch().tables[0].updates[0].old_row.get("value") == 60
		and _db.get_row_by_pk("nearby", 4).get("value") == 70)

	_trace.clear()
	var one_off: DatabaseUpdateData = DatabaseUpdateData.new()
	one_off.tables = [_table("nearby", [FixtureRow.new(5, 80)])]
	_db.apply_database_update(one_off)
	_check("saved one-off synthetic update has explicit no-query scope", _last_batch().query_set_id == SpacetimeDBCacheBatch.NO_QUERY_SET
		and _last_batch().phase == SpacetimeDBCacheBatch.Phase.TRANSACTION and _trace == ["batch:-1:1"])

	var batches_before_clear: int = _batches.size()
	_db.clear_local_db()
	_check("explicit cache clear keeps previous batch behavior", _batches.size() == batches_before_clear
		and _db.count_all_rows("nearby") == 0 and _db.count_all_rows("own") == 0)
	var result: Dictionary = {"passed": _failures == 0, "failed": _failures, "checks": _checks,
		"payload_uid": ResourceUID.id_to_text(669398707540095867)}
	print("CACHE_BATCH_CHECK ", JSON.stringify(result))
	var arguments: PackedStringArray = OS.get_cmdline_user_args()
	if not arguments.is_empty():
		var output: FileAccess = FileAccess.open(arguments[0], FileAccess.WRITE)
		output.store_string(JSON.stringify(result, "\t") + "\n")
	_client.free()
	quit(1 if _failures > 0 else 0)

func _on_batch(batch: SpacetimeDBCacheBatch) -> void:
	_batches.append(batch)
	_trace.append("batch:%d:%d" % [batch.query_set_id, batch.phase])
	if _expected_nearby != null:
		_check("batch sees complete nearby cache", _db.get_row_by_pk("nearby", 1) == _expected_nearby)
	if _expected_own != null:
		_check("batch sees complete own cache", _db.get_row_by_pk("own", 1) == _expected_own)

func _on_insert(_row: _ModuleTableType, table_name: StringName) -> void:
	_trace.append(String(table_name) + ":insert")

func _on_update(_old_row: _ModuleTableType, _new_row: _ModuleTableType, table_name: StringName) -> void:
	_trace.append(String(table_name) + ":update")

func _on_delete(_row: _ModuleTableType, table_name: StringName) -> void:
	_trace.append(String(table_name) + ":delete")

func _on_complete(table_name: StringName) -> void:
	_trace.append(String(table_name) + ":complete")

func _last_batch() -> SpacetimeDBCacheBatch:
	return _batches[-1]

func _table(table_name: String, inserts: Array[_ModuleTableType] = [], deletes: Array[_ModuleTableType] = []) -> TableUpdateData:
	var update: TableUpdateData = TableUpdateData.new()
	update.table_name = table_name
	update.inserts.assign(inserts)
	update.deletes.assign(deletes)
	return update

func _transaction(query_set_id: int, tables: Array[TableUpdateData]) -> DatabaseUpdateData:
	var update: DatabaseUpdateData = DatabaseUpdateData.new()
	update.query_id = QueryIdData.new(query_set_id)
	update.tables = tables
	return update

func _check(label: String, passed: bool) -> void:
	_checks.append({"case": label, "passed": passed})
	if not passed:
		_failures += 1
		push_error("CACHE_BATCH_CHECK: " + label)
