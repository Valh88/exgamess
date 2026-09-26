package gamessa.http;

/** Ответ HTTP. */
class HttpResponse {
	public var status:Int;
	public var body:String;

	public function new(status:Int, body:String) {
		this.status = status;
		this.body = body;
	}
}
