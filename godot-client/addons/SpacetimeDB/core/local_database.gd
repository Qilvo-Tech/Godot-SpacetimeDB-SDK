class_name LocalDatabase extends Node

class RowVersion extends RefCounted:
	var row: _ModuleTableType
	var primary_key: Variant
	var count: int = 0

class VersionDelta extends RefCounted:
	var row: _ModuleTableType
	var primary_key: Variant
	var amount: int = 0
	var raw_owner: SpacetimeDBCacheBatch.TableChanges

class TableDelta extends RefCounted:
	var table_name: StringName
	var primary_key_field: StringName
	var versions: Dictionary[String, VersionDelta] = {}

class SetDelta extends RefCounted:
	var batch: SpacetimeDBCacheBatch
	var tables: Dictionary[StringName, TableDelta] = {}
	var retired: bool = false

# Only changed versions are staged; _tables is the positive-version PK projection.
var _memberships: Dictionary[int, Dictionary] = {}
var _versions: Dictionary[StringName, Dictionary] = {}
var _pk_versions: Dictionary[StringName, Dictionary] = {}
var _has_saved_rows: bool = false
var _last_apply_error: String = ""

var _tables: Dictionary[String, Dictionary] = {}
var _primary_key_cache: Dictionary = {}
var _is_event_table_cache: Dictionary = {}
var _schema: SpacetimeDBSchema
## it should be "MainModuleClient" but the info is not available before codegen.
var _module:SpacetimeDBClient

var _cached_normalized_table_names: Dictionary = {}
var _insert_listeners_by_table: Dictionary = {}
var _update_listeners_by_table: Dictionary = {}
var _delete_listeners_by_table: Dictionary = {}
var _delete_key_listeners_by_table: Dictionary = {}
var _transactions_completed_listeners_by_table: Dictionary = {}

signal row_inserted(table_name: String, row: _ModuleTableType)
signal row_updated(table_name: String, old_row: _ModuleTableType, new_row: _ModuleTableType)
signal row_deleted(table_name: String, row: _ModuleTableType)
signal row_transactions_completed(table_name: String)
## All tables in one query set have been applied; raw callbacks have not run yet.
signal cache_batch_applied(batch: SpacetimeDBCacheBatch)
## Paired with cache_batch_applied after all raw row and completion callbacks.
signal cache_batch_completed(batch: SpacetimeDBCacheBatch)

func _init(p_schema: SpacetimeDBSchema, module:SpacetimeDBClient):
	# Initialize _tables dictionary with known table names
	_schema = p_schema
	_module = module
	for table_name in _schema.module_table_name_to_type_name.keys():
		_tables.set(table_name, {})


func subscribe_to_inserts(table_name: StringName, callable: Callable):
	if not _insert_listeners_by_table.has(table_name):
		_insert_listeners_by_table[table_name] = []
	if not _insert_listeners_by_table[table_name].has(callable):
		_insert_listeners_by_table[table_name].append(callable)


func unsubscribe_from_inserts(table_name: StringName, callable: Callable):
	if _insert_listeners_by_table.has(table_name):
		_insert_listeners_by_table[table_name].erase(callable)
		if _insert_listeners_by_table[table_name].is_empty():
			_insert_listeners_by_table.erase(table_name)

func subscribe_to_updates(table_name: StringName, callable: Callable):
	if not _update_listeners_by_table.has(table_name):
		_update_listeners_by_table[table_name] = []
	if not _update_listeners_by_table[table_name].has(callable):
		_update_listeners_by_table[table_name].append(callable)

func unsubscribe_from_updates(table_name: StringName, callable: Callable):
	if _update_listeners_by_table.has(table_name):
		_update_listeners_by_table[table_name].erase(callable)
		if _update_listeners_by_table[table_name].is_empty():
			_update_listeners_by_table.erase(table_name)

func subscribe_to_deletes(table_name: StringName, callable: Callable):
	if not _delete_listeners_by_table.has(table_name):
		_delete_listeners_by_table[table_name] = []
	if not _delete_listeners_by_table[table_name].has(callable):
		_delete_listeners_by_table[table_name].append(callable)

func unsubscribe_from_deletes(table_name: StringName, callable: Callable):
	if _delete_listeners_by_table.has(table_name):
		_delete_listeners_by_table[table_name].erase(callable)
		if _delete_listeners_by_table[table_name].is_empty():
			_delete_listeners_by_table.erase(table_name)

func subscribe_to_transactions_completed(table_name: StringName, callable: Callable):
	if not _transactions_completed_listeners_by_table.has(table_name):
		_transactions_completed_listeners_by_table[table_name] = []
	if not _transactions_completed_listeners_by_table[table_name].has(callable):
		_transactions_completed_listeners_by_table[table_name].append(callable)

func unsubscribe_from_transactions_completed(table_name: StringName, callable: Callable):
	if _transactions_completed_listeners_by_table.has(table_name):
		_transactions_completed_listeners_by_table[table_name].erase(callable)
		if _transactions_completed_listeners_by_table[table_name].is_empty():
			_transactions_completed_listeners_by_table.erase(table_name)

# --- Primary Key Handling ---
# Finds and caches the primary key field name for a given schema
func _get_primary_key_field(table_name_lower: String) -> StringName:
	if _primary_key_cache.has(table_name_lower):
		return _primary_key_cache[table_name_lower]

	if not _schema.get_type_of_table_name(table_name_lower):
		printerr("LocalDatabase: No schema found for table '", table_name_lower, "' to determine PK.")
		return &"" # Return empty StringName

	var table_type := _schema.get_type_of_table_name(table_name_lower)
	var schema := _schema.get_type_script(table_type)
	var instance = schema.new() # Need instance for metadata/properties

	if instance:
		var pk_field: StringName = instance["primary_key"]
		_primary_key_cache[table_name_lower] = pk_field
		return pk_field

	#printerr("LocalDatabase: Could not determine primary key for table '", table_name_lower, "'. Add metadata or use convention.")
	print_debug("LocalDatabase: table %s has no primary_key" % table_name_lower)
	_primary_key_cache[table_name_lower] = &"" # Cache failure
	return &""

func get_is_event(table_name_original: StringName) -> bool:
	var table_script = _schema.get_table_script((_schema.module_name +"_"+ table_name_original).to_pascal_case()+"Table")
	var table_instance = table_script.new()
	var is_event:bool = table_instance.get_meta("is_event") == "true"
	_is_event_table_cache[table_name_original] = is_event
	return is_event

func get_last_apply_error() -> String:
	return _last_apply_error

func has_active_query_sets() -> bool:
	return not _memberships.is_empty()

func _reject_update(reason: String) -> bool:
	_last_apply_error = reason
	return false

func _new_set(query_set_id: int, phase: SpacetimeDBCacheBatch.Phase) -> SetDelta:
	var staged: SetDelta = SetDelta.new()
	staged.batch = SpacetimeDBCacheBatch.new(query_set_id, phase)
	return staged

func apply_database_subscription_applied(message: SubscribeAppliedMessage) -> bool:
	if message == null:
		return _reject_update("Missing subscription snapshot")
	if _memberships.has(message.query_id.id):
		return _reject_update("Snapshot for an active query set")
	var staged: SetDelta = _new_set(message.query_id.id, SpacetimeDBCacheBatch.Phase.SNAPSHOT)
	for table: TableUpdateData in message.tables:
		staged.batch.tables.append(_batch_table_changes(table))
	return _apply_managed([staged], [message.tables])

func apply_database_unsubscription_applied(message: UnsubscribeAppliedMessage) -> bool:
	if message == null:
		return _reject_update("Missing unsubscribe result")
	return retire_query_set(message.query_id.id, message.tables)

func retire_query_set(query_set_id: int, raw_tables: Array[TableUpdateData] = []) -> bool:
	if not _memberships.has(query_set_id):
		return _reject_update("Retirement of an unknown query set")
	var staged: SetDelta = _new_set(query_set_id, SpacetimeDBCacheBatch.Phase.UNSUBSCRIBE)
	staged.retired = true
	for table: TableUpdateData in raw_tables:
		staged.batch.tables.append(_batch_table_changes(table))
	return _apply_managed([staged], [raw_tables])

func retire_all_query_sets() -> bool:
	var sets: Array[SetDelta] = []
	var raw: Array[Array] = []
	for query_set_id: int in _memberships:
		var staged: SetDelta = _new_set(query_set_id, SpacetimeDBCacheBatch.Phase.UNSUBSCRIBE)
		staged.retired = true
		sets.append(staged)
		raw.append([])
	return _apply_managed(sets, raw)

func retire_saved_rows() -> void:
	if _has_saved_rows:
		clear_local_db()

func apply_database_update(update: DatabaseUpdateData) -> bool:
	if update == null:
		return _reject_update("Missing database update")
	if update.query_id == null:
		if has_active_query_sets():
			return _reject_update("Saved query cannot share managed membership")
		_last_apply_error = ""
		var batch: SpacetimeDBCacheBatch = SpacetimeDBCacheBatch.new(
			SpacetimeDBCacheBatch.NO_QUERY_SET, SpacetimeDBCacheBatch.Phase.TRANSACTION)
		var changes: Array[Dictionary] = []
		for table: TableUpdateData in update.tables:
			var raw: SpacetimeDBCacheBatch.TableChanges = _batch_table_changes(table)
			changes.append(apply_table_update(table, raw))
			batch.tables.append(raw)
		_has_saved_rows = true
		cache_batch_applied.emit(batch)
		emit_db_callbacks(changes)
		cache_batch_completed.emit(batch)
		return true
	var transaction: TransactionUpdateMessage = TransactionUpdateMessage.new()
	transaction.query_sets.append(update)
	return apply_transaction_update(transaction)

func apply_transaction_update(transaction: TransactionUpdateMessage) -> bool:
	var sets: Array[SetDelta] = []
	var raw: Array[Array] = []
	var callback_order: Array[TableUpdateData] = []
	var positions: Dictionary[int, int] = {}
	for update: DatabaseUpdateData in transaction.query_sets:
		if update.query_id == null:
			if transaction.query_sets.size() != 1:
				return _reject_update("Unscoped query mixed with subscription transaction")
			return apply_database_update(update)
		var query_set_id: int = update.query_id.id
		if not _memberships.has(query_set_id):
			return _reject_update("Transaction for an unknown query set")
		var index: int = positions.get(query_set_id, -1)
		if index < 0:
			index = sets.size()
			positions[query_set_id] = index
			sets.append(_new_set(query_set_id, SpacetimeDBCacheBatch.Phase.TRANSACTION))
			raw.append([])
		for table: TableUpdateData in update.tables:
			sets[index].batch.tables.append(_batch_table_changes(table))
			raw[index].append(table)
			callback_order.append(table)
	return _apply_managed(sets, raw, callback_order)

func _table_delta(tables: Dictionary[StringName, TableDelta], name: StringName) -> TableDelta:
	if not tables.has(name):
		var table: TableDelta = TableDelta.new()
		table.table_name = name
		table.primary_key_field = _get_primary_key_field(name)
		tables[name] = table
	return tables[name]

func _is_keyed(name: StringName) -> bool:
	if not _tables.has(name):
		return false
	var is_event: bool = _is_event_table_cache.get(name, false)
	if not _is_event_table_cache.has(name):
		is_event = get_is_event(name)
	return not is_event and _get_primary_key_field(name) != &""

func _stage_version(table: TableDelta, key: String, row: _ModuleTableType, amount: int,
		owner: SpacetimeDBCacheBatch.TableChanges = null) -> bool:
	if key.is_empty() or row == null:
		return _reject_update("Missing exact BSATN row version")
	var primary_key: Variant = row.get(table.primary_key_field)
	var committed: Dictionary = _versions.get(table.table_name, {})
	if primary_key == null:
		return _reject_update("Keyed row has no primary key")
	if not table.versions.has(key):
		var delta: VersionDelta = VersionDelta.new()
		var existing: RowVersion = committed.get(key)
		delta.row = existing.row if existing != null else row
		delta.primary_key = existing.primary_key if existing != null else primary_key
		if delta.primary_key != primary_key:
			return _reject_update("One BSATN version has inconsistent primary keys")
		table.versions[key] = delta
	var value: VersionDelta = table.versions[key]
	if value.primary_key != primary_key:
		return _reject_update("One BSATN version has inconsistent primary keys")
	value.amount += amount
	if amount > 0 and value.raw_owner == null:
		if not committed.has(key):
			value.row = row
		value.raw_owner = owner
	return true

func _scope_counts(query_set_id: int, name: StringName) -> Dictionary:
	var membership: Dictionary = _memberships.get(query_set_id, {})
	return membership.get(name, {})

func _logical_changes(table: TableDelta, before: Dictionary, is_global: bool) -> SpacetimeDBCacheBatch.TableChanges:
	var changes: SpacetimeDBCacheBatch.TableChanges = SpacetimeDBCacheBatch.TableChanges.new(table.table_name)
	for key: String in table.versions:
		var delta: VersionDelta = table.versions[key]
		var old_count: int = 0
		if is_global:
			var version: RowVersion = before.get(key)
			old_count = version.count if version != null else 0
		else:
			old_count = before.get(key, 0)
		var new_count: int = old_count + delta.amount
		if old_count == 0 and new_count > 0:
			changes.inserts.append(delta.row)
		elif old_count > 0 and new_count == 0:
			changes.deletes.append(delta.row)
	var removed: Dictionary = {}
	for row: _ModuleTableType in changes.deletes:
		removed[row.get(table.primary_key_field)] = row
	for row: _ModuleTableType in changes.inserts:
		var old_row: _ModuleTableType = removed.get(row.get(table.primary_key_field))
		if old_row != null:
			changes.updates.append(SpacetimeDBCacheBatch.RowUpdate.new(old_row, row))
	return changes

func _semantic_callbacks(changes: SpacetimeDBCacheBatch.TableChanges, primary_key: StringName) -> Dictionary[String, Array]:
	var paired: Dictionary = {}
	var result: Dictionary[String, Array] = {"table_name": [changes.table_name], "inserts": [], "updates": [], "deletes": []}
	for pair: SpacetimeDBCacheBatch.RowUpdate in changes.updates:
		paired[pair.new_row.get(primary_key)] = true
		if _update_listeners_by_table.has(changes.table_name):
			result["updates"].append([pair.old_row, pair.new_row])
	for row: _ModuleTableType in changes.inserts:
		if not paired.has(row.get(primary_key)) and _insert_listeners_by_table.has(changes.table_name):
			result["inserts"].append([row])
	for row: _ModuleTableType in changes.deletes:
		if not paired.has(row.get(primary_key)) and _delete_listeners_by_table.has(changes.table_name):
			result["deletes"].append([row])
	return result

func _apply_managed(sets: Array[SetDelta], raw_sets: Array[Array], raw_callback_order: Array[TableUpdateData] = []) -> bool:
	_last_apply_error = ""
	if sets.is_empty():
		return true
	if _has_saved_rows:
		return _reject_update("Saved rows must retire before managed membership")
	var global_tables: Dictionary[StringName, TableDelta] = {}
	var callback_order: Array[TableUpdateData] = []
	callback_order.assign(raw_callback_order)
	if callback_order.is_empty():
		for parts: Array in raw_sets:
			callback_order.append_array(parts)
	var table_order: Array[StringName] = []
	for index: int in range(sets.size()):
		var staged: SetDelta = sets[index]
		for part_index: int in range(raw_sets[index].size()):
			var part: TableUpdateData = raw_sets[index][part_index]
			var owner: SpacetimeDBCacheBatch.TableChanges = staged.batch.tables[part_index]
			var name: StringName = owner.table_name
			if not _tables.has(name):
				printerr("LocalDatabase: Received update for unknown table: ", name)
				continue
			if not table_order.has(name):
				table_order.append(name)
			if not _is_keyed(name):
				continue
			if staged.retired:
				_table_delta(staged.tables, name)
				continue # Retirement uses stored counts, never the optional dropped-row payload.
			if part.inserts.size() != part.insert_row_keys.size() or part.deletes.size() != part.delete_row_keys.size():
				return _reject_update("BSATN version keys are not aligned with keyed rows")
			var table: TableDelta = _table_delta(staged.tables, name)
			for row_index: int in range(part.inserts.size()):
				if not _stage_version(table, part.insert_row_keys[row_index], part.inserts[row_index], 1, owner):
					return false
	# Rust cache reconciliation stages inserts first, including reversed query-set parts.
	for index: int in range(sets.size()):
		var staged: SetDelta = sets[index]
		if not staged.retired:
			for part: TableUpdateData in raw_sets[index]:
				var name: StringName = StringName(part.table_name.to_snake_case())
				if not _is_keyed(name):
					continue
				var table: TableDelta = staged.tables[name]
				for row_index: int in range(part.deletes.size()):
					if not _stage_version(table, part.delete_row_keys[row_index], part.deletes[row_index], -1):
						return false
		if staged.retired:
			var stored: Dictionary = _memberships[staged.batch.query_set_id]
			for name: StringName in stored:
				if not table_order.has(name):
					table_order.append(name)
				var table: TableDelta = _table_delta(staged.tables, name)
				var counts: Dictionary = stored[name]
				for key: String in counts:
					var version: RowVersion = _versions[name][key]
					if not _stage_version(table, key, version.row, -int(counts[key])):
						return false
		for name: StringName in staged.tables:
			var table: TableDelta = staged.tables[name]
			var counts: Dictionary = _scope_counts(staged.batch.query_set_id, name)
			var aggregate: TableDelta = _table_delta(global_tables, name)
			for key: String in table.versions:
				var delta: VersionDelta = table.versions[key]
				if int(counts.get(key, 0)) + delta.amount < 0:
					return _reject_update("Unknown BSATN version delete or query-set count underflow")
				if not _stage_version(aggregate, key, delta.row, delta.amount, delta.raw_owner):
					return false
			staged.batch.query_set_changes.append(_logical_changes(table, counts, false))
	var projections: Dictionary[StringName, Dictionary] = {}
	var callbacks_by_table: Dictionary[StringName, Dictionary] = {}
	for name: StringName in global_tables:
		var table: TableDelta = global_tables[name]
		var versions: Dictionary = _versions.get(name, {})
		var touched_pks: Dictionary = {}
		for key: String in table.versions:
			var delta: VersionDelta = table.versions[key]
			var previous: RowVersion = versions.get(key)
			var total: int = previous.count if previous != null else 0
			if total + delta.amount < 0:
				return _reject_update("Global BSATN version count underflow")
			touched_pks[delta.primary_key] = ""
		var old_projection: Dictionary = _pk_versions.get(name, {})
		for pk: Variant in touched_pks:
			var old_key: String = old_projection.get(pk, "")
			if not old_key.is_empty():
				var previous: RowVersion = versions[old_key]
				var delta: VersionDelta = table.versions.get(old_key)
				if previous.count + (delta.amount if delta != null else 0) > 0:
					touched_pks[pk] = old_key
		for key: String in table.versions:
			var delta: VersionDelta = table.versions[key]
			var previous: RowVersion = versions.get(key)
			var total: int = previous.count if previous != null else 0
			if total + delta.amount > 0:
				var winner: String = touched_pks[delta.primary_key]
				if not winner.is_empty() and winner != key:
					return _reject_update("Conflicting surviving BSATN versions for one primary key")
				touched_pks[delta.primary_key] = key
		projections[name] = touched_pks
		var changes: SpacetimeDBCacheBatch.TableChanges = _logical_changes(table, versions, true)
		callbacks_by_table[name] = _semantic_callbacks(changes, table.primary_key_field)
		for pair: SpacetimeDBCacheBatch.RowUpdate in changes.updates:
			var key: String = touched_pks[pair.new_row.get(table.primary_key_field)]
			var delta: VersionDelta = table.versions[key]
			if delta.raw_owner != null:
				delta.raw_owner.updates.append(pair)
	var callbacks: Array[Dictionary] = []
	var emitted_keyed: Dictionary[StringName, bool] = {}
	# Repeated query-set parts coalesce membership, but uncached callbacks keep wire order.
	for part: TableUpdateData in callback_order:
		var name: StringName = StringName(part.table_name.to_snake_case())
		if not _tables.has(name):
			continue
		if _is_keyed(name):
			if callbacks_by_table.has(name) and not emitted_keyed.has(name):
				callbacks.append(callbacks_by_table[name])
				emitted_keyed[name] = true
		else:
			var change: Dictionary = {"table_name": [name], "inserts": [], "updates": [], "deletes": []}
			for row: _ModuleTableType in part.inserts:
				change["inserts"].append([row])
			for row: _ModuleTableType in part.deletes:
				change["deletes"].append([row])
			callbacks.append(change)
	for name: StringName in table_order:
		if callbacks_by_table.has(name) and not emitted_keyed.has(name):
			callbacks.append(callbacks_by_table[name])
	# No committed row or count changes precede complete-transaction validation.
	for staged: SetDelta in sets:
		var query_set_id: int = staged.batch.query_set_id
		if not _memberships.has(query_set_id):
			_memberships[query_set_id] = {}
		var membership: Dictionary = _memberships[query_set_id]
		for name: StringName in staged.tables:
			if not membership.has(name):
				membership[name] = {}
			var counts: Dictionary = membership[name]
			var table: TableDelta = staged.tables[name]
			for key: String in table.versions:
				var delta: VersionDelta = table.versions[key]
				var total: int = int(counts.get(key, 0)) + delta.amount
				if total == 0:
					counts.erase(key)
				else:
					counts[key] = total
		if staged.retired:
			_memberships.erase(query_set_id)
	for name: StringName in global_tables:
		if not _versions.has(name):
			_versions[name] = {}
		if not _pk_versions.has(name):
			_pk_versions[name] = {}
		var versions: Dictionary = _versions[name]
		var table: TableDelta = global_tables[name]
		for key: String in table.versions:
			var delta: VersionDelta = table.versions[key]
			var version: RowVersion = versions.get(key)
			if version == null:
				version = RowVersion.new()
				version.row = delta.row
				version.primary_key = delta.primary_key
			version.count += delta.amount
			if version.count == 0:
				versions.erase(key)
			else:
				versions[key] = version
		var projection: Dictionary = _pk_versions[name]
		var rows: Dictionary = _tables[name]
		var touched_pks: Dictionary = projections[name]
		for pk: Variant in touched_pks:
			var key: String = touched_pks[pk]
			if key.is_empty():
				projection.erase(pk)
				rows.erase(pk)
			else:
				projection[pk] = key
				var version: RowVersion = versions[key]
				rows[pk] = version.row
	for staged: SetDelta in sets:
		cache_batch_applied.emit(staged.batch)
	emit_db_callbacks(callbacks)
	for staged: SetDelta in sets:
		cache_batch_completed.emit(staged.batch)
	return true

func _batch_table_changes(table_update: TableUpdateData) -> SpacetimeDBCacheBatch.TableChanges:
	var table_changes: SpacetimeDBCacheBatch.TableChanges = SpacetimeDBCacheBatch.TableChanges.new(
		StringName(table_update.table_name.to_snake_case()))
	table_changes.inserts.assign(table_update.inserts)
	table_changes.deletes.assign(table_update.deletes)
	return table_changes

func emit_db_callbacks(changes:Array[Dictionary]):
	for change in changes:
		var table_name = change.get("table_name", ["__null__"])[0]
		if table_name == "__null__":
			continue
		for insert: Array in change.get("inserts", []):
			for listener: Callable in _insert_listeners_by_table.get(table_name, []):
				if not listener.is_valid():
					_insert_listeners_by_table.erase(listener)
					push_error("LocalDB: insert callback is not valid: skipped")
					continue
				listener.call(insert[0])
			row_inserted.emit(table_name, insert[0])

		for update: Array in change.get("updates", []):
			for listener: Callable in _update_listeners_by_table.get(table_name, []):
				if not listener.is_valid():
					_update_listeners_by_table.erase(listener)
					push_error("LocalDB: insert callback is not valid: skipped")
					continue
				listener.call(update[0], update[1])
			row_updated.emit(table_name, update[0], update[1])

		for delete: Array in change.get("deletes", []):
			for listener: Callable in _delete_listeners_by_table.get(table_name, []):
				if not listener.is_valid():
					_delete_listeners_by_table.erase(listener)
					push_error("LocalDB: delete callback is not valid: skipped")
					continue
				listener.call(delete[0])
			row_deleted.emit(table_name, delete[0])

		if _transactions_completed_listeners_by_table.has(table_name):
			for listener: Callable in _transactions_completed_listeners_by_table.get(table_name, []):
				if not listener.is_valid():
					_transactions_completed_listeners_by_table.erase(listener)
					push_error("LocalDB: Transaction complete callback is not valid: skipped")
					continue
				listener.call()
			row_transactions_completed.emit(table_name)

func apply_table_update(table_update: TableUpdateData, batch_changes: SpacetimeDBCacheBatch.TableChanges = null) -> Dictionary[String,Array]:
	var table_name_original: StringName = StringName(table_update.table_name.to_snake_case())

	if not _tables.has(table_name_original):
		printerr("LocalDatabase: Received update for unknown table: ", table_name_original)
		return {"table_name": [table_name_original],
				"inserts": [],
				"updates": [],
				"deletes": []}
	var is_event: bool
	if _is_event_table_cache.has(table_name_original):
		is_event = _is_event_table_cache[table_name_original]
	else:
		is_event = get_is_event(table_name_original)
	var pk_field: StringName
	if _primary_key_cache.has(table_name_original):
		pk_field = _primary_key_cache[table_name_original]
	else:
		pk_field = _get_primary_key_field(table_name_original)
		_primary_key_cache[table_name_original] = pk_field
	if pk_field == &"" or is_event:
		var inserts_no_pk: Array = []
		for row in table_update.inserts:
			inserts_no_pk.append([row])
		var deletes_no_pk: Array = []
		for row in table_update.deletes:
			deletes_no_pk.append([row])
		var changes :Dictionary[String, Array] = {"table_name": [table_name_original],
			"inserts": inserts_no_pk,
			"updates": [],
			"deletes": deletes_no_pk}
		return changes

	var table_dict: Dictionary = _tables[table_name_original]

	var inserted_pks_set: Dictionary = {} # { pk_value: true }
	var inserts_to_emit: Array
	var updates_to_emit: Array
	var deletes_to_emit: Array
	for inserted_row: _ModuleTableType in table_update.inserts:
		var pk_value = inserted_row.get(pk_field)
		if pk_value == null:
			push_error("LocalDatabase: Inserted row for table '", table_name_original, "' has null PK value for field '", pk_field, "'. Skipping.")
			continue
		inserted_pks_set[pk_value] = true
		var prev_row_resource: _ModuleTableType = table_dict.get(pk_value, null)
		table_dict[pk_value] = inserted_row
		if prev_row_resource != null:
			if batch_changes != null:
				batch_changes.updates.append(SpacetimeDBCacheBatch.RowUpdate.new(prev_row_resource, inserted_row))
			if _update_listeners_by_table.has(table_name_original):
				updates_to_emit.append([prev_row_resource,inserted_row])
		else:
			if _insert_listeners_by_table.has(table_name_original):
				inserts_to_emit.append([inserted_row])

	for deleted_row: _ModuleTableType in table_update.deletes:
		var pk_value = deleted_row.get(pk_field)
		if pk_value == null:
			push_warning("LocalDatabase: Deleted row for table '", table_name_original, "' has null PK value for field '", pk_field, "'. Skipping.")
			continue
		if not inserted_pks_set.has(pk_value):
			if table_dict.erase(pk_value):
				if _delete_listeners_by_table.has(table_name_original):
					deletes_to_emit.append([deleted_row])

	var changes :Dictionary[String, Array]= {"table_name": [table_name_original],
				"inserts": inserts_to_emit,
				"updates": updates_to_emit,
				"deletes": deletes_to_emit}
	return changes

func clear_local_db():
	_memberships.clear()
	_versions.clear()
	_pk_versions.clear()
	_has_saved_rows = false
	var all_deletes_to_emit: Array[Dictionary]
	for table in _tables:
		var deletes_to_emit:Array
		for row in get_all_rows(table):
			deletes_to_emit.append([row])
		_tables[table].clear()
		all_deletes_to_emit.append({"table_name": [table],
				"inserts": [],
				"updates": [],
				"deletes": deletes_to_emit})
	emit_db_callbacks(all_deletes_to_emit)

# --- Access Methods ---
func get_row_by_pk(table_name: String, primary_key_value) -> _ModuleTableType:
	var table_name_lower: String = table_name
	if _tables.has(table_name_lower):
		return _tables[table_name_lower].get(primary_key_value)
	return null

func get_all_rows(table_name: String) -> Array[_ModuleTableType]:
	var rows: Array = _get_all_rows_untyped(table_name)
	var typed_result_array: Array[_ModuleTableType] = []
	typed_result_array.assign(rows)

	return typed_result_array

func count_all_rows(table_name: String) -> int:
	var rows: Array = _get_all_rows_untyped(table_name)
	return rows.size()

func _get_all_rows_untyped(table_name: String) -> Array:
	var table_name_lower: String = table_name
	if _tables.has(table_name_lower):
		var table_dict: Dictionary = _tables[table_name_lower]
		return table_dict.values()

	return []
