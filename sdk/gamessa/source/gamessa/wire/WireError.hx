package gamessa.wire;

/** Ошибка разбора/кодирования кадра протокола. */
class WireError {
	public var message:String;

	public function new(message:String) {
		this.message = message;
	}
}
