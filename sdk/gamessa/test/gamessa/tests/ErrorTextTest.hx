package gamessa.tests;

import gamessa.ErrorText;
import gamessa.MatchMakeError;
import utest.Assert;

/**
	Тексты ошибок по кодам: ru/en, фолбэк для неизвестных кодов, дописывание
	деталей.
*/
class ErrorTextTest extends utest.Test {
	public function new() {
		super();
	}

	function testRuMapping() {
		Assert.equals("Комната заполнена", ErrorText.ofCode(523));
		Assert.equals("Требуется вход в аккаунт", ErrorText.ofCode(401));
		Assert.equals("Нет соединения с сервером", ErrorText.ofCode(0));
		Assert.equals("Не удалось переподключиться", ErrorText.ofCode(4003));
	}

	function testEnMapping() {
		Assert.equals("The room is full", ErrorText.ofCode(523, "en"));
		Assert.equals("Sign in required", ErrorText.ofCode(401, "en"));
	}

	function testUserFacingAppendsDetails() {
		var err = new MatchMakeError(522, "no reservation");
		Assert.equals("Комната или сессия не найдены (no reservation)", ErrorText.userFacing(err));
		Assert.equals("Room or session not found", ErrorText.userFacing(new MatchMakeError(522, ""), "en"));
	}

	function testUnknownCodeFallback() {
		Assert.equals("Ошибка 499", ErrorText.ofCode(499));
		Assert.equals("Error 499", ErrorText.ofCode(499, "en"));
	}
}
