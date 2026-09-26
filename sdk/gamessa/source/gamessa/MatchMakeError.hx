package gamessa;

/**
	Ошибка matchmake/HTTP-слоя. Коды — протокольные 520–526 и HTTP 4xx/5xx
	(см. doc/PROTOCOL.md и FallbackController на сервере).
*/
class MatchMakeError {
	public var code:Int;
	public var message:String;

	public function new(code:Int, message:String) {
		this.code = code;
		this.message = message;
	}

	/** Разбирает JSON-ответ сервера: {"error": {code, message}} или
		ECTO-ошибки {"errors": {field: [messages]}}. */
	public static function fromJson(status:Int, body:String):MatchMakeError {
		try {
			var parsed:Dynamic = haxe.Json.parse(body);
			if (parsed != null && parsed.error != null)
				return new MatchMakeError(parsed.error.code, parsed.error.message);
			if (parsed != null && parsed.errors != null) {
				var parts:Array<String> = [];
				for (field in Reflect.fields(parsed.errors)) {
					var msgs:Dynamic = Reflect.field(parsed.errors, field);
					var text = Std.isOfType(msgs, Array) ? (msgs : Array<Dynamic>).join(", ") : Std.string(msgs);
					parts.push('$field: $text');
				}
				return new MatchMakeError(status, parts.join("; "));
			}
		} catch (e:Dynamic) {}
		return new MatchMakeError(status, body);
	}

	public function toString():String {
		return 'MatchMakeError($code, $message)';
	}
}
