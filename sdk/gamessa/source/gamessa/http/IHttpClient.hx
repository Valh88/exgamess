package gamessa.http;

/**
	HTTP-клиент для auth/matchmake-вызовов. Реализации: `FetchHttpClient` (JS),
	`SysHttpClient` (hl/cpp/neko/eval). Колбэки могут срабатывать из другого
	потока (см. реализацию).

	`bearerToken` добавляется как `Authorization: Bearer <token>` (если задан).
*/
interface IHttpClient {
	var bearerToken:Null<String>;

	function get(url:String, onSuccess:HttpResponse->Void, onError:HttpError->Void):Void;
	function post(url:String, body:String, onSuccess:HttpResponse->Void, onError:HttpError->Void):Void;
	function del(url:String, onSuccess:HttpResponse->Void, onError:HttpError->Void):Void;
}
