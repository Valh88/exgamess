package gamessa.storage;

#if js
/** localStorage (JS). */
class JsStorage implements IStorage {
	public function new() {}

	public function getItem(key:String):Null<String> {
		try {
			return js.Browser.window.localStorage.getItem(key);
		} catch (e:Dynamic) {
			return null;
		}
	}

	public function setItem(key:String, value:String):Void {
		try {
			js.Browser.window.localStorage.setItem(key, value);
		} catch (e:Dynamic) {}
	}

	public function removeItem(key:String):Void {
		try {
			js.Browser.window.localStorage.removeItem(key);
		} catch (e:Dynamic) {}
	}
}
#end
