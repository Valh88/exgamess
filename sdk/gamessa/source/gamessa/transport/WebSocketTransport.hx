package gamessa.transport;

import gamessa.util.Dispatcher;
import haxe.io.Bytes;
import hx.ws.Types;
import hx.ws.WebSocket as HxWebSocket;

/**
	WS-транспорт поверх hxWebSockets: JS (js.html.WebSocket) и все sys-таргеты
	(hl/cpp/neko). Подключение неблокирующее на всех платформах: на sys-таргетах
	TCP-коннект (DNS + connect) выполняется в отдельном потоке, поэтому
	`connect()` возвращается сразу. Неудача подключения (отказ, DNS,
	таймаут `connectTimeoutMs`) доставляется в `onError` + `onClose` через
	`Dispatcher.post` — `Room` обрабатывает её как обрыв (auto-reconnect).

	Колбэки доставляются через `Dispatcher.post` (см. комментарий там).
	После закрытия транспорт переиспользовать нельзя — создайте новый.
*/
class WebSocketTransport implements ITransport {
	public var onOpen:Null<Void->Void>;
	public var onMessage:Null<Bytes->Void>;
	public var onClose:Null<TransportClose->Void>;
	public var onError:Null<String->Void>;

	/** Таймаут установки соединения (до onOpen), мс. */
	public var connectTimeoutMs:Int = 10_000;

	final _ws:HxWebSocket;
	var _open:Bool = false;
	var _closing:Bool = false;
	var _notified:Bool = false;

	/**
		`verifyCert = false` — не проверять серверный сертификат при wss
		(dev-стенды с самоподписанным сертификатом; hl/cpp/neko). На js флаг
		не действует — сертификат проверяет браузер (доверие импортируется
		вручную). Прод с CA-сертификатом оставляет true (по умолчанию).
	*/
	public function new(url:String, verifyCert = true) {
		// immediateOpen=false: соединение открываем в connect(), после
		// назначения колбэков (на sys-таргетах поток чтения стартует в open())
		_ws = verifyCert ? new HxWebSocket(url, false) : new WebSocketNoVerify(url, false);
		#if !js
		// hx.ws на sys-таргетах шлёт рукопожатие абсолютным URI
		// ("GET ws://host/path"), который серверы отвергают
		// (RFC 9112 §3.2, Bandit) — подменяем на origin-form "path?query"
		_ws._fullUri = _ws._path + (_ws._search == null ? "" : _ws._search);
		#end
	}

	public function connect():Void {
		_ws.onopen = () -> {
			_open = true;
			if (onOpen != null)
				Dispatcher.post(() -> onOpen());
		};

		_ws.onmessage = (msg:MessageType) -> {
			var bytes:Bytes = switch (msg) {
				case BytesMessage(buffer): buffer.readAllAvailableBytes();
				case StrMessage(text): Bytes.ofString(text);
			}
			if (onMessage != null)
				Dispatcher.post(() -> onMessage(bytes));
		};

		#if js
		_ws.onclose = (e:js.html.CloseEvent) -> notifyClose(e.code, e.reason);
		_ws.onerror = (_:Dynamic) -> notifyError("websocket error");
		#else
		// hxWebSockets на sys-таргетах не различает коды закрытия
		_ws.onclose = () -> notifyClose(1006, "connection closed");
		_ws.onerror = (e:Dynamic) -> notifyError(Std.string(e));
		#end

		#if js
		_ws.open(); // неблокирующе: события придут асинхронно
		#else
		// TCP-коннект (DNS + connect) блокирующий внутри hx.ws — уносим
		// из вызвавшего потока, чтобы connect() не подвешивал игровой цикл
		_connectingThread();
		#end

		startWatchdog();
	}

	#if !js
	function _connectingThread():Void {
		sys.thread.Thread.create(() -> {
			try {
				_ws.open();
				// пока коннект шёл, транспорт могли закрыть (Room.leave/dispose)
				if (_closing)
					_ws.close();
			} catch (e:Dynamic) {
				if (!_closing && !_notified) {
					notifyError('connect failed: $e');
					notifyClose(1006, 'connect failed: $e');
				}
			}
		});
	}
	#end

	/** Ждёт onOpen не дольше connectTimeoutMs; затем закрывает попытку. */
	function startWatchdog():Void {
		var waited = 0;

		function check():Void {
			if (_open || _closing || _notified)
				return;

			if (waited >= connectTimeoutMs) {
				_closing = true;
				notifyError('connect timeout after ${connectTimeoutMs}ms');
				notifyClose(1006, "connect timeout");
				try {
					_ws.close(); // прерывает зависший коннект как умеет
				} catch (e:Dynamic) {}
				return;
			}

			waited += 100;
			haxe.Timer.delay(check, 100);
		}

		haxe.Timer.delay(check, 100);
	}

	public function send(data:Bytes):Void {
		#if js
		// BytesBuffer.getBytes() на js возвращает Bytes поверх ArrayBuffer
		// с запасом (правится только поле length), а hxWebSockets шлёт
		// getData() целиком — кадр уезжал бы с хвостом нулей и сервер
		// отвечал "invalid frame". sub() отдаёт ровно length байт.
		_ws.send(data.sub(0, data.length));
		#else
		_ws.send(data);
		#end
	}

	public function close():Void {
		_closing = true;
		_open = false;
		_ws.close();
	}

	public function isOpen():Bool {
		// hx.ws на sys-таргетах после рукопожатия остаётся в State.Head
		// (Body там не наступает), поэтому ориентируемся на свой флаг
		return _open;
	}

	// onClose — ровно один раз на жизнь транспорта
	function notifyClose(code:Int, reason:String):Void {
		if (_notified)
			return;
		_notified = true;
		_open = false;
		if (onClose != null)
			Dispatcher.post(() -> onClose(new TransportClose(code, reason)));
	}

	function notifyError(message:String):Void {
		if (_notified)
			return;
		if (onError != null)
			Dispatcher.post(() -> onError(message));
	}
}
