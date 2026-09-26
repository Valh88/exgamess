package gamessa;

/** Бронь места (результат matchmake-вызова, шаг 1 двухфазного join). */
class SeatReservation {
	public var roomName:Null<String>;
	public var roomId:String;
	public var sessionId:String;

	/** Выдаётся комнатой в кадре JoinRoom, не приходит по HTTP. */
	public var reconnectionToken:Null<String>;

	public function new(roomId:String, sessionId:String, ?roomName:String) {
		this.roomId = roomId;
		this.sessionId = sessionId;
		this.roomName = roomName;
	}

	public static function fromJson(data:Dynamic):SeatReservation {
		return new SeatReservation(data.room_id, data.session_id, data.room_name);
	}

	public function toString():String {
		return 'SeatReservation($roomId, $sessionId)';
	}
}
