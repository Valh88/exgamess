package gamessa.http;

/** Ошибка HTTP (сеть или ответ сервера). */
class HttpError {
	public var message:String;
	public var status:Null<Int>;
	public var body:Null<String>;

	public function new(message:String, ?status:Int, ?body:String) {
		this.message = message;
		this.status = status;
		this.body = body;
	}

	public function toString():String {
		return status == null ? message : 'http $status: $message';
	}
}
