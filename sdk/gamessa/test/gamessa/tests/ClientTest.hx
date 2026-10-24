package gamessa.tests;

import gamessa.Client;
import gamessa.http.HttpError;
import gamessa.http.HttpResponse;
import gamessa.http.IHttpClient;
import utest.Assert;
import utest.Async;

/**
	HTTP-ретраи временных сбоев (`Client.httpRetries`): скриптованный фейк
	клиента выдаёт ошибки по очереди; проверяем число попыток и исход.
*/
class ClientTest extends utest.Test {
	public function new() {
		super();
	}

	function testTransientErrorsRetried(async:Async) {
		var http = new FakeHttp([
			Fail(new HttpError("boom", 500)),
			Fail(new HttpError("network down")), // status null — сеть
			Ok(makeResponse(200, '{"rooms":[]}'))
		]);

		var client = new Client("http://x", http, null);
		client.httpRetries = 2;
		client.httpRetryDelayMs = 10;

		client.getAvailableRooms(rooms -> {
			Assert.equals(0, rooms.length);
			Assert.equals(3, http.calls);
			async.done();
		}, err -> {
			Assert.fail('should succeed after retries: $err');
			async.done();
		});
	}

	function testPermanentErrorFailsImmediately(async:Async) {
		var http = new FakeHttp([Fail(new HttpError("nope", 401))]);

		var client = new Client("http://x", http, null);
		client.httpRetries = 5;
		client.httpRetryDelayMs = 10;

		client.getAvailableRooms(_ -> {
			Assert.fail("should not succeed");
			async.done();
		}, err -> {
			Assert.equals(401, err.code);
			Assert.equals(1, http.calls);
			async.done();
		});
	}

	function testRetriesOffByDefault(async:Async) {
		var http = new FakeHttp([Fail(new HttpError("boom", 503))]);

		var client = new Client("http://x", http, null);

		client.getAvailableRooms(_ -> {
			Assert.fail("should not succeed");
			async.done();
		}, err -> {
			Assert.equals(503, err.code);
			Assert.equals(1, http.calls);
			async.done();
		});
	}

	function test429IsTransient(async:Async) {
		var http = new FakeHttp([
			Fail(new HttpError("slow down", 429)),
			Ok(makeResponse(200, '{"rooms":[]}'))
		]);

		var client = new Client("http://x", http, null);
		client.httpRetries = 1;
		client.httpRetryDelayMs = 10;

		client.getAvailableRooms(_ -> {
			Assert.equals(2, http.calls);
			async.done();
		}, err -> {
			Assert.fail('429 should be retried: $err');
			async.done();
		});
	}

	static function makeResponse(status:Int, body:String):HttpResponse {
		return new HttpResponse(status, body);
	}
}

private enum FakeOutcome {
	Fail(err:HttpError);
	Ok(res:HttpResponse);
}

private class FakeHttp implements IHttpClient {
	public var bearerToken:Null<String> = null;

	public var calls:Int = 0;
	var outcomes:Array<FakeOutcome>;

	public function new(outcomes:Array<FakeOutcome>) {
		this.outcomes = outcomes.copy();
	}

	public function get(url:String, onSuccess:HttpResponse->Void, onError:HttpError->Void):Void {
		next(onSuccess, onError);
	}

	public function post(url:String, body:String, onSuccess:HttpResponse->Void, onError:HttpError->Void):Void {
		next(onSuccess, onError);
	}

	public function put(url:String, body:String, onSuccess:HttpResponse->Void, onError:HttpError->Void):Void {
		next(onSuccess, onError);
	}

	public function del(url:String, onSuccess:HttpResponse->Void, onError:HttpError->Void):Void {
		next(onSuccess, onError);
	}

	function next(onSuccess:HttpResponse->Void, onError:HttpError->Void):Void {
		calls++;

		if (outcomes.length == 0) {
			onError(new HttpError("no script"));
			return;
		}

		switch (outcomes.shift()) {
			case Fail(err):
				onError(err);
			case Ok(res):
				onSuccess(res);
		}
	}
}
