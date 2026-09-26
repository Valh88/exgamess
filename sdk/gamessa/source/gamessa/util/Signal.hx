package gamessa.util;

/**
	Мини-сигнал (мультидиспетчер) для колбэков Room/Client.
	Подписка возвращает функцию отписки.
*/
class Signal<T> {
	var handlers:Array<T->Void> = [];

	public function new() {}

	public function add(handler:T->Void):Void->Void {
		handlers.push(handler);
		return () -> remove(handler);
	}

	public function remove(handler:T->Void):Void {
		handlers.remove(handler);
	}

	public function dispatch(value:T):Void {
		// копия: обработчик может отписаться в теле
		for (handler in handlers.copy())
			handler(value);
	}

	public function clear():Void {
		handlers.resize(0);
	}
}
