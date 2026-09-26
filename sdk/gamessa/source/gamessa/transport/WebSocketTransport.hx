package gamessa.transport;

import gamessa.util.Dispatcher;
import haxe.io.Bytes;
import hx.ws.Types;
import hx.ws.WebSocket as HxWebSocket;

/**
	WS-транспорт поверх hxWebSockets: JS (js.html.WebSocket) и все sys-таргеты
	(hl/cpp/neko — фоновый поток чтения внутри библиотеки). Все колбэки
	доставляются через `Dispatcher.post` (см. комментарий там).
*/
class WebSocketTransport implements ITransport {
	public var onOpen:Null<Void->Void>;
	public var onMessage:Null<Bytes->Void>;
	public var onClose:Null<TransportClose->Void>;
	public var onError:Null<String->Void>;

	final _ws:HxWebSocket;
	var _open:Bool = false;
	var _closing:Bool = false;

	public function new(url:String) {
		// immediateOpen=false: соединение открываем в connect(), после
		// назначения колбэков (на sys-таргетах поток чтения стартует в open())
		_ws = new HxWebSocket(url, false);
		// hx.ws шлёт рукопожатие абсолютным URI ("GET ws://host/path"),
		// который серверы отвергают (RFC 9112 §3.2, Bandit) — подменяем на
		// origin-form "path?query"
		_ws._fullUri = _ws._path + (_ws._search == null ? "" : _ws._search);
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
		_ws.onclose = (e:js.html.CloseEvent) -> {
			_open = false;
			if (onClose != null)
				Dispatcher.post(() -> onClose(new TransportClose(e.code, e.reason)));
		};
		_ws.onerror = (_:Dynamic) -> {
			if (onError != null)
				Dispatcher.post(() -> onError("websocket error"));
		};
		#else
		// hxWebSockets на sys-таргетах не различает коды закрытия
		_ws.onclose = () -> {
			if (!_closing)
				_open = false;
			if (onClose != null)
				Dispatcher.post(() -> onClose(new TransportClose(1006, "connection closed")));
		};
		_ws.onerror = (e:Dynamic) -> {
			if (onError != null)
				Dispatcher.post(() -> onError(Std.string(e)));
		};
		#end

		_ws.open();
	}

	public function send(data:Bytes):Void {
		_ws.send(data);
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
}
