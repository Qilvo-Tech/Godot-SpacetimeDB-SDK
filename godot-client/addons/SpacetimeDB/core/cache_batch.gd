class_name SpacetimeDBCacheBatch extends RefCounted

enum Phase { SNAPSHOT, TRANSACTION, UNSUBSCRIBE }

## Saved one-off queries have no subscription query set.
const NO_QUERY_SET: int = -1

class RowUpdate extends RefCounted:
	var old_row: _ModuleTableType
	var new_row: _ModuleTableType

	func _init(p_old_row: _ModuleTableType, p_new_row: _ModuleTableType) -> void:
		old_row = p_old_row
		new_row = p_new_row

class TableChanges extends RefCounted:
	var table_name: StringName
	## Borrowed decoded rows; raw parts retain occurrences, scoped deltas contain zero-crossings.
	## Row resources must not be mutated.
	var inserts: Array[_ModuleTableType] = []
	var deletes: Array[_ModuleTableType] = []
	## Global replacements on raw parts; scoped replacements on query_set_changes.
	var updates: Array[RowUpdate] = []

	func _init(p_table_name: StringName) -> void:
		table_name = p_table_name

var query_set_id: int
var phase: Phase
## Raw decoded wire parts, preserving duplicate occurrences and order.
var tables: Array[TableChanges] = []
## Per-set version-presence changes, independent of other sets' retention.
## Scoped replacement rows also appear in these inserts/deletes for source consumers.
var query_set_changes: Array[TableChanges] = []

func _init(p_query_set_id: int, p_phase: Phase) -> void:
	query_set_id = p_query_set_id
	phase = p_phase
