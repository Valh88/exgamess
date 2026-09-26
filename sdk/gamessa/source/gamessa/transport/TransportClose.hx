package gamessa.transport;

/** Причина закрытия соединения. */
class TransportClose {
	public var code:Int;
	public var reason:String;

	public function new(code:Int, reason:String = "") {
		this.code = code;
		this.reason = reason;
	}

	public function toString():String {
		return 'closed($code, "$reason")';
	}
}
