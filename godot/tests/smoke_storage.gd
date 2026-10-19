extends RefCounted

## Each smoke process gets an isolated writable directory so it never depends on
## the host's Godot user data sandbox or on state left by another test run.

static func create(label: String) -> String:
	var base := OS.get_environment("TMPDIR").trim_suffix("/")
	if base.is_empty():
		base = "/tmp"
	var path := "%s/zhanqi-godot-%s-%s" % [base, label, OS.get_process_id()]
	var error := DirAccess.make_dir_recursive_absolute(path)
	if error != OK:
		push_error("cannot create smoke storage directory: %s (%s)" % [path, error])
	return path

static func cleanup(path: String) -> void:
	if path.is_empty():
		return
	_remove_tree(path)

static func _remove_tree(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		if entry != "." and entry != "..":
			var child := path.path_join(entry)
			if directory.current_is_dir():
				_remove_tree(child)
			else:
				DirAccess.remove_absolute(child)
		entry = directory.get_next()
	directory.list_dir_end()
	directory = null
	DirAccess.remove_absolute(path)
