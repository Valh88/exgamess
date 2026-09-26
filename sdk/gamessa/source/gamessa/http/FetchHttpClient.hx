package gamessa.http;

#if js
import js.Browser;

/** HTTP-клиент на window.fetch (JS). */
class FetchHttpClient implements IHttpClient {
	public var bearerToken:Null<String>;

	public function new() {}

	function request(method:String, url:String, ?body:String, onSuccess:HttpResponse->Void, onError:HttpError->Void):Void {
		var headers = new js.html.Headers();
		headers.set("Accept", "application/json");
		if (body != null)
			headers.set("Content-Type", "application/json");
		if (bearerToken != null)
			headers.set("Authorization", 'Bearer $bearerToken');

		var init:Dynamic = {method: method, headers: headers};
		if (body != null)
			init.body = body;

		Browser.window.fetch(url, init).then(function(response:js.html.Response) {
			response.text().then(function(text:String) {
				if (response.ok)
					onSuccess(new HttpResponse(response.status, text));
				else
					onError(new HttpError('request failed', response.status, text));
			}, function(err:Dynamic) {
				onError(new HttpError('failed to read response: $err'));
			});
		}, function(err:Dynamic) {
			onError(new HttpError('network error: $err'));
		});
	}

	public function get(url:String, onSuccess:HttpResponse->Void, onError:HttpError->Void):Void {
		request("GET", url, null, onSuccess, onError);
	}

	public function post(url:String, body:String, onSuccess:HttpResponse->Void, onError:HttpError->Void):Void {
		request("POST", url, body, onSuccess, onError);
	}

	public function del(url:String, onSuccess:HttpResponse->Void, onError:HttpError->Void):Void {
		request("DELETE", url, null, onSuccess, onError);
	}
}
#end
