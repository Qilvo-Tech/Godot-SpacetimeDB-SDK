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
	## Decoded wire rows, including rows already retained or removed by another set.
	## Row resources are borrowed from the raw cache and must not be mutated.
	var inserts: Array[_ModuleTableType] = []
	var deletes: Array[_ModuleTableType] = []
	## Cache replacements; each new_row is also present in inserts.
	var updates: Array[RowUpdate] = []

	func _init(p_table_name: StringName) -> void:
		table_name = p_table_name

var query_set_id: int
var phase: Phase
var tables: Array[TableChanges] = []

func _init(p_query_set_id: int, p_phase: Phase) -> void:
	query_set_id = p_query_set_id
	phase = p_phase
