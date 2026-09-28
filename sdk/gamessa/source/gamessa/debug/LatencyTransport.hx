package gamessa.debug;

import gamessa.Client;
import gamessa.SeatReservation;
import gamessa.transport.ITransport;
import gamessa.transport.TransportClose;
import gamessa.transport.WebSocketTransport;
import haxe.io.Bytes;

/**
	Параметры имитации сети.
**/
typedef LatencyConfig = {
	/** Базовая задержка одного направления, мс. */
	var delay:Float;

	/** Разброс ±jitter вокруг delay, мс (0/undefined — без джиттера). */
	@:optional var jitter:Float;

	/** Доля потерянных исходящих кадров, 0..1 (undefined — без потерь). */
	@:optional var dropRate:Float;
}

/**
	Дев-обёртка над транспортом: имитирует задержку, джиттер и потерю кадров —
	аналог `latencySimulation` в Colyseus. Только для разработки/тестов.

	Задержка применяется к обоим направлениям: кадры клиента уходят позже,
	кадры сервера (и события close/error) доставляются позже; `dropRate`
	теряет только исходящие кадры. Обёртка надёжнее держать в одном месте —
	точке `connectRoom`, лаги будут с первого кадра:

	```haxe
	var room = client.connectRoom(res,
		LatencyTransport.wrapWebSocket(client, res, {delay: 150, jitter: 50}));
	```

	Ограничение: при auto-reconnect Room создаёт транспорт сам, без обёртки —
	переподключение идёт без имитации лага.
**/
class LatencyTransport implements ITransport {
	public var onOpen:Null<Void->Void>;
	public var onMessage:Null<Bytes->Void>;
	public var onClose:Null<TransportClose->Void>;
	public var onError:Null<String->Void>;

	var base:ITransport;
	var config:LatencyConfig;

	/** Удобство для стандартного WS-транспорта: строит и оборачивает его разом. */
	public static function wrapWebSocket(client:Client, reservation:SeatReservation, config:LatencyConfig):LatencyTransport {
		var ws = new WebSocketTransport(client.roomWsUrl(reservation.roomId, reservation.sessionId), client.verifyCert);
		return new LatencyTransport(ws, config);
	}

	public function new(base:ITransport, config:LatencyConfig) {
		this.base = base;
		this.config = config;
	}

	public function connect():Void {
		// к этому моменту Room уже назначил наши обработчики — оборачиваем
		// события базового транспорта с задержкой
		base.onOpen = () -> if (onOpen != null) onOpen();
		base.onMessage = bytes -> later(() -> if (onMessage != null) onMessage(bytes));
		base.onClose = close -> later(() -> if (onClose != null) onClose(close));
		base.onError = message -> later(() -> if (onError != null) onError(message));
		base.connect();
	}

	public function send(data:Bytes):Void {
		if (config.dropRate != null && Math.random() < config.dropRate)
			return;
		later(() -> base.send(data));
	}

	public function close():Void {
		base.close();
	}

	public function isOpen():Bool {
		return base.isOpen();
	}

	function later(fn:Void->Void):Void {
		var delay = config.delay;
		if (config.jitter != null && config.jitter > 0)
			delay += (Math.random() * 2 - 1) * config.jitter;

		if (delay <= 0) {
			fn();
		} else {
			haxe.Timer.delay(fn, Std.int(delay));
		}
	}
}
