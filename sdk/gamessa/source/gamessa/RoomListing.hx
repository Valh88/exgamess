package gamessa;

/** Запись листинга комнаты (`GET /api/rooms`). */
class RoomListing {
	public var roomId:String;
	public var roomName:Null<String>;
	public var clients:Int;
	public var maxClients:Dynamic; // Int | "infinity"
	public var locked:Bool;
	public var metadata:Dynamic;

	public function new(roomId:String, ?roomName:String) {
		this.roomId = roomId;
		this.roomName = roomName;
	}

	public static function fromJson(data:Dynamic):RoomListing {
		var listing = new RoomListing(data.room_id, data.room_name);
		listing.clients = data.clients;
		listing.maxClients = data.max_clients;
		listing.locked = data.locked == true;
		listing.metadata = data.metadata;
		return listing;
	}
}
