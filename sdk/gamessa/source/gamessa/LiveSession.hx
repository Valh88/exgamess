package gamessa;

/**
	Живая сессия пользователя (результат `Client.mySessions`): комната, где
	он сейчас онлайн. `roomName` может быть null (комната создана вне
	матчмейкера).
*/
class LiveSession {
	public var roomId:String;
	public var roomName:Null<String>;
	public var username:Null<String>;

	public function new(roomId:String, ?roomName:String, ?username:String) {
		this.roomId = roomId;
		this.roomName = roomName;
		this.username = username;
	}

	public function toString():String {
		return 'LiveSession($roomId, $roomName)';
	}
}
