package gamessa.storage;

#if (hl || cpp || neko || php || python || eval || java || cs)
import haxe.Json;
import sys.FileSystem;
import sys.io.File;

/**
	Файловое key-value хранилище для sys-таргетов: один JSON-файл
	`<dir>/<filename>`, читается при создании, перезаписывается на запись.
*/
class FileStorage implements IStorage {
	final path:String;
	var data:Map<String, String>;

	public function new(?dir:String, ?filename:String) {
		if (dir == null)
			dir = Sys.getCwd();
		if (filename == null)
			filename = ".gamessa_storage.json";
		if (dir.length > 0 && !StringTools.endsWith(dir, "/") && !StringTools.endsWith(dir, "\\"))
			dir += "/";
		path = dir + filename;

		data = new Map();
		try {
			if (FileSystem.exists(path)) {
				var parsed:Dynamic = Json.parse(File.getContent(path));
				for (key in Reflect.fields(parsed))
					data.set(key, Reflect.field(parsed, key));
			}
		} catch (e:Dynamic) {
			data = new Map();
		}
	}

	public function getItem(key:String):Null<String> {
		return data.get(key);
	}

	public function setItem(key:String, value:String):Void {
		data.set(key, value);
		flush();
	}

	public function removeItem(key:String):Void {
		if (data.remove(key))
			flush();
	}

	function flush():Void {
		var obj = {};
		for (key in data.keys())
			Reflect.setField(obj, key, data.get(key));
		try {
			File.saveContent(path, Json.stringify(obj));
		} catch (e:Dynamic) {}
	}
}
#end
