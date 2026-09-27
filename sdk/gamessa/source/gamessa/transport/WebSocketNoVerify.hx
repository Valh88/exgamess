package gamessa.transport;

#if (hl || cpp || neko)
import hx.ws.SocketImpl;
import hx.ws.WebSocket;

/**
	WS-сокет, не проверяющий серверный сертификат при wss. Для dev-стендов с
	самоподписанным сертификатом; создаётся транспортом при `verifyCert = false`.
	Создавать сокет нужно целиком в override `createSocket()` — конструктор
	`hx.ws.WebSocket` вызывает его до присвоения полей подкласса, поэтому флаг
	не параметр, а отдельный класс (официальный паттерн из README hxWebSockets).

	Альтернатива на весь процесс — `sys.ssl.Socket.DEFAULT_VERIFY_CERT = false`.
	Прод с сертификатом из доверенного CA не требует ни того, ни другого.
*/
class WebSocketNoVerify extends WebSocket {
	override private function createSocket():SocketImpl {
		if (_protocol == "wss") {
			var socket:sys.ssl.Socket = cast super.createSocket();
			socket.verifyCert = false;
			return socket;
		}
		return super.createSocket();
	}
}
#else
// На таргетах без sys.ssl (js — сертификат проверяет браузер, eval/прочие)
// псевдоним: имя валидно везде, проверка не отключается.
typedef WebSocketNoVerify = hx.ws.WebSocket;
#end
