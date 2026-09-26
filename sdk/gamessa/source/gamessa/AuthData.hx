package gamessa;

/** Результат register/login: bearer-токен + пользователь (как в ответе сервера). */
class AuthData {
	public var token:String;
	public var user:Dynamic;

	public function new(token:String, user:Dynamic) {
		this.token = token;
		this.user = user;
	}

	public static function fromJson(data:Dynamic):AuthData {
		return new AuthData(data.token, data.user);
	}
}
