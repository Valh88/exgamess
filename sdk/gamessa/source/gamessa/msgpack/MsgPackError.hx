package gamessa.msgpack;

/** Ошибка разбора/кодирования msgpack. */
class MsgPackError {
	public var message:String;

	public function new(message:String) {
		this.message = message;
	}
}
