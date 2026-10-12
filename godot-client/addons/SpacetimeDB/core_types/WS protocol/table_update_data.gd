@tool
class_name TableUpdateData extends Resource

#enum TableTypeEnum{
	#persistent,
	#event,        ## only insert
	#subscription  ## only insert and table name
	#}
@export var table_id: int = -1 # u32
@export var table_name: String
@export var num_rows: int = -1 # u64
#@export var TableType: TableTypeEnum
@export var inserts: Array[Resource] # Array of specific table row resources
@export var deletes: Array[Resource] # Array of specific table row resources (e.g., Message, User)
## Exact incoming BSATN bytes as immutable full hex strings, aligned with rows.
var insert_row_keys: Array[String] = []
var delete_row_keys: Array[String] = []
