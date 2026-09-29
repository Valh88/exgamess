package gamessa.http;

#if (hl || cpp || neko || php || python || eval || java || cs)
import haxe.io.Bytes;
import sys.net.Host;
import sys.net.Socket;
#if (hl || cpp || neko)
import sys.ssl.Socket as SecureSocket;
#end

/**
	Минимальный HTTP/1.1-клиент для sys-таргетов (hl/cpp/neko/eval).
	Запрос выполняется в отдельном потоке, колбэки срабатывают из него.
	JSON REST-вызовам этого достаточно; для тяжёлых сценариев подмените
	своей реализацией `IHttpClient`.
*/
class SysHttpClient implements IHttpClient {
	public var bearerToken:Null<String>;

	/** Таймаут соединения/чтения, мс. */
	public var timeoutMs:Int = 10_000;

	/**
		`false` — не проверять серверный сертификат при https
		(dev-стенды с самоподписанным сертификатом; hl/cpp/neko).
		Прод с CA-сертификатом оставляет true (по умолчанию).
	*/
	public var verifyCert:Bool = true;

	static final URL_RE = ~/^(\w+):\/\/([^\/:]+)(?::(\d+))?(\/.*)?$/;

	public function new() {}

	public function get(url:String, onSuccess:HttpResponse->Void, onError:HttpError->Void):Void {
		spawn("GET", url, null, onSuccess, onError);
	}

	public function post(url:String, body:String, onSuccess:HttpResponse->Void, onError:HttpError->Void):Void {
		spawn("POST", url, body, onSuccess, onError);
	}

	public function put(url:String, body:String, onSuccess:HttpResponse->Void, onError:HttpError->Void):Void {
		spawn("PUT", url, body, onSuccess, onError);
	}

	public function del(url:String, onSuccess:HttpResponse->Void, onError:HttpError->Void):Void {
		spawn("DELETE", url, null, onSuccess, onError);
	}

	function spawn(method:String, url:String, body:Null<String>, onSuccess:HttpResponse->Void, onError:HttpError->Void):Void {
		sys.thread.Thread.create(() -> {
			try {
				var response = doRequest(method, url, body);
				gamessa.util.Dispatcher.post(() -> onSuccess(response));
			} catch (e:HttpError) {
				gamessa.util.Dispatcher.post(() -> onError(e));
			} catch (e:Dynamic) {
				gamessa.util.Dispatcher.post(() -> onError(new HttpError('network error: $e')));
			}
		});
	}

	function doRequest(method:String, url:String, body:Null<String>):HttpResponse {
		if (!URL_RE.match(url))
			throw new HttpError('bad url: $url');

		var scheme = URL_RE.matched(1);
		var host = URL_RE.matched(2);
		var port = URL_RE.matched(3) == null ? (scheme == "https" ? 443 : 80) : Std.parseInt(URL_RE.matched(3));
		var path = URL_RE.matched(4);
		if (path == null || path == "")
			path = "/";

		var socket:Socket = makeSocket(scheme);
		socket.setTimeout(timeoutMs / 1000.0);
		socket.connect(new Host(host), port);

		var payload = body == null ? "" : body;
		var req = new StringBuf();
		req.add('$method $path HTTP/1.1\r\n');
		req.add('Host: $host:$port\r\n');
		req.add("Accept: application/json\r\n");
		if (payload != "")
			req.add('Content-Type: application/json\r\nContent-Length: ${Bytes.ofString(payload).length}\r\n');
		if (bearerToken != null)
			req.add('Authorization: Bearer $bearerToken\r\n');
		req.add("Connection: close\r\n\r\n");
		req.add(payload);

		socket.write(req.toString());

		var raw = new StringBuf();
		try {
			var chunk = socket.input.readAll();
			if (chunk != null)
				raw.add(chunk.toString());
		} catch (e:haxe.io.Eof) {}
		socket.close();

		return parseResponse(raw.toString());
	}

	function makeSocket(scheme:String):Socket {
		#if (hl || cpp || neko)
		if (scheme == "https") {
			var secure:SecureSocket = new SecureSocket();
			if (!verifyCert)
				secure.verifyCert = false;
			return secure;
		}
		#end
		if (scheme == "https")
			throw new HttpError("https is not supported on this target");
		return new Socket();
	}

	static function parseResponse(raw:String):HttpResponse {
		var sep = raw.indexOf("\r\n\r\n");
		if (sep < 0)
			throw new HttpError("malformed http response");

		var head = raw.substr(0, sep);
		var body = raw.substr(sep + 4);
		var lines = head.split("\r\n");
		var statusLine = lines[0].split(" ");
		if (statusLine.length < 2)
			throw new HttpError("malformed http status line");
		var status = Std.parseInt(statusLine[1]);

		var contentLength = -1;
		var chunked = false;
		for (i in 1...lines.length) {
			var header = lines[i].split(":");
			if (header.length < 2)
				continue;
			var name = StringTools.trim(header[0]).toLowerCase();
			var value = StringTools.trim(header.slice(1).join(":"));
			if (name == "content-length")
				contentLength = Std.parseInt(value);
			else if (name == "transfer-encoding" && value.toLowerCase() == "chunked")
				chunked = true;
		}

		if (chunked)
			body = dechunk(body);
		else if (contentLength >= 0 && body.length > contentLength)
			body = body.substr(0, contentLength);

		return new HttpResponse(status == null ? 0 : status, body);
	}

	static function dechunk(body:String):String {
		var out = new StringBuf();
		var pos = 0;
		while (pos < body.length) {
			var eol = body.indexOf("\r\n", pos);
			if (eol < 0)
				break;
			var size = Std.parseInt("0x" + body.substr(pos, eol - pos).split(";")[0]);
			if (size == null || size <= 0)
				break;
			out.add(body.substr(eol + 2, size));
			pos = eol + 2 + size + 2;
		}
		return out.toString();
	}
}
#end
