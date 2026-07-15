class_name SpacetimeDBSchema extends Resource

var module_name: StringName = ""
var module_types: Dictionary[StringName, GDScript] = {}
var module_tables: Dictionary[StringName, GDScript] = {}
var module_table_name_to_type_name: Dictionary[StringName, StringName]
var core_types: Dictionary[StringName, GDScript] = {}

var debug_mode: bool = false # Controls verbose debug printing

func _init(p_module_name: String, p_schema_path: String = "res://spacetime_bindings/schema", p_debug_mode: bool = false) -> void:
	debug_mode = p_debug_mode
	module_name = p_module_name.to_snake_case()
	module_types = {}
	# Load module type files
	_load_files("%s/types" % p_schema_path, module_types)
	# Load module table files
	module_tables = {}
	_load_files("%s/tables" % p_schema_path, module_tables)
	# Load core types if they are defined as Resources with scripts
	core_types = {}
	_load_files("res://addons/SpacetimeDB/core_types", core_types, true)
	load_table_types()

func _load_files(path: String, dict:Dictionary[StringName, GDScript], is_core: bool = false) -> void:
	var files := ResourceLoader.list_directory(path)
	var dirs := DirAccess.get_directories_at(path)
	if files.is_empty() and dirs.is_empty():
		printerr("SpacetimeDBSchema: Schema directory does not exist: ", path)
		return
	if debug_mode:
		prints("path", path, "start loading")

	# handle nested folders
	for dir_name in dirs:
		_load_files(path.path_join(dir_name), dict, is_core)

	for file_name in files:
		#skip non script files
		if not file_name.ends_with(".gd"):
			if debug_mode and not file_name.ends_with(".uid"):
				prints("file_name", file_name, "doesn't end in .gd. skipped")
			continue

		var script_path := path.path_join(file_name)
		if not is_core and not file_name.begins_with(module_name):
			if debug_mode:
				prints("path", script_path, "is not part of core or module %s. skipped" % module_name)
			continue

		if not ResourceLoader.exists(script_path):
			printerr("SpacetimeDBSchema: Script file not found or inaccessible: ", script_path, " (Original name: ", file_name, ")")
			continue

		var script := ResourceLoader.load(script_path, "GDScript") as GDScript

		if script and script.can_instantiate():
			if script.get_global_name().is_empty():
				printerr("SpacetimeDBSchema: Script file doesn't have a class_name: ", script_path)
				continue
			dict.set(script.get_global_name(), script)
			if debug_mode:
				prints("script", script_path, "loaded")
		else:
			printerr("SpacetimeDBSchema: Script file found but can't instantiate (there is an error inside this file): ", script_path)

	if debug_mode:
		prints("path:", path, "finished loading")

func load_table_types():
	for type_script:GDScript in module_types.values():
		var type = type_script.new()
		if type is RustEnum:
			continue
		for table_name in type.table_names:
			module_table_name_to_type_name.set(table_name, type_script.get_global_name())

func get_type_script(type_name: StringName) -> GDScript:
	return module_types.get(type_name)

func get_table_script(table_name: StringName) -> GDScript:
	return module_tables.get(table_name)

func get_core_type_script(core_type_name :StringName) -> GDScript:
	return core_types.get(core_type_name)

func get_type_of_table_name(table_name:StringName) -> StringName:
	return module_table_name_to_type_name.get(table_name.to_snake_case(), &"")
