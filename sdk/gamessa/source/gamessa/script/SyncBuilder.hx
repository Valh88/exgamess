package gamessa.script;

#if macro
import haxe.macro.ComplexTypeTools;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import haxe.macro.TypeTools;
#end

/**
	@:autoBuild-билдер Sync (см. Sync.hx). Для каждого наследника:

	* валидирует и обрабатывает @:rpc-методы: тело переименовывается в
	  `__im_<имя>` (выполняется на сервере), классифицируется по типу
	  возврата — `Void`/`Array<Effect>` = send-метод (путь call), любой
	  другой = request-метод (путь reply, значение уходит клиенту);
	* генерирует `messages()` из имён @:rpc (если не задан вручную) —
	  она попадает в `M.schema.messages` биндинга;
	* генерирует `call` (если не задан вручную): Message → send-@:rpc
	  по имени кадра с декодом аргументов из payload, Join/Leave →
	  хуки `onJoin`/`onLeave`; перед диспетчеризацией заполняет
	  `this.state`/`this.caller`;
	* генерирует `reply` (если не задан вручную): Request → request-@:rpc
	  по имени, возвращённое значение уходит запросившему; null = «нет
	  обработчика» (мост ответит ошибкой);
	* генерирует стабы: на сервере (`-D gamessa-server`) — делегация в
	  `__im_<имя>` (локальный вызов из других @:rpc-тел), на клиенте —
	  отправка через `room`: send → `room.send`, request →
	  `room.request` с колбэками результата.

	Порядок с `ServerLogicBuilder` не важен: M-биндинг ссылается на
	`messages()`/`__callWire` по имени из runtime-строки, а типизация
	всех полей происходит после всех авто-билдов.
**/
#if macro
typedef Rpc =
{
	name:String,
	args:Array<FunctionArg>,
	ret:Null<ComplexType>,
	isSend:Bool,
}

class SyncBuilder
{
	public static function build():Array<Field>
	{
		final cls = Context.getLocalClass().get();

		// TState, с которым Sync инстанцирован для этого класса; null —
		// сам Sync (или не наследник) — не обрабатываем
		final syncState = syncStateType(cls);
		if (syncState == null)
			return Context.getBuildFields();

		final fields = Context.getBuildFields();
		final pos = cls.pos;
		final server = Context.defined("gamessa-server");
		final stateCt = try TypeTools.toComplexType(syncState) catch (_:Dynamic) (macro :Dynamic);

		final rpcs:Array<Rpc> = [];

		for (f in fields)
		{
			if (!hasMeta(f, ":rpc"))
				continue;

			final fn = switch (f.kind)
			{
				case FFun(fn): fn;

				case _:
					Context.fatalError('@:rpc "${f.name}" должен быть методом', f.pos);
			}

			if (!Lambda.has(f.access, APublic))
				Context.fatalError('@:rpc метод "${f.name}" должен быть public', f.pos);
			if (Lambda.has(f.access, AStatic))
				Context.fatalError('@:rpc метод "${f.name}" не должен быть static', f.pos);
			if (fn.ret == null)
				Context.fatalError('@:rpc метод "${f.name}" должен объявлять тип возврата', f.pos);
			for (a in fn.args)
				if (a.opt)
					Context.fatalError('@:rpc метод "${f.name}": optional-аргументы не поддерживаются', f.pos);

			final retType = try ComplexTypeTools.toType(fn.ret) catch (_:Dynamic) null;
			if (retType == null)
				Context.fatalError('@:rpc метод "${f.name}": не удалось разрешить тип возврата', f.pos);

			final isSend = switch (Context.followWithAbstracts(retType, true))
			{
				case TAbstract(_.get() => {name: "Void"}, _): true;

				case TInst(_.get() => {pack: [], name: "Array"}, [p]):
					switch (p)
					{
						case TEnum(t, _): t.get().pack.join(".") == "gamessa.script" && t.get().name == "Effect";

						case _: false;
					}

				case _: false;
			}

			// тело — под служебным именем; стаб будет добавлен позже
			f.name = "__im_" + f.name;
			f.meta = [for (m in f.meta) if (m.name != ":rpc") m];

			rpcs.push(
				{
					name: f.name.substr("__im_".length),
					args: fn.args,
					ret: fn.ret,
					isSend: isSend
				});
		}

		if (rpcs.length == 0)
			return fields;

		final send = [for (r in rpcs) if (r.isSend) r];
		final request = [for (r in rpcs) if (!r.isSend) r];

		// messages() — из имён @:rpc (порядок объявления)
		if (!hasField(fields, "messages"))
			fields.push(
				{
					name: "messages",
					access: [APublic, AStatic],
					kind: FFun(
						{
							args: [],
							ret: macro :Array<String>,
							expr: macro return $v{[for (r in rpcs) r.name]},
						}),
					pos: pos,
					meta: [],
				});

		// call() — Message → send-@:rpc по имени кадра; Join/Leave → хуки
		if (!hasField(fields, "call"))
			fields.push(
				{
					name: "call",
					access: [APrivate, AOverride],
					kind: FFun(
						{
							args: [
								{name: "fn", type: macro :gamessa.script.ScriptFn}, {name: "s", type: stateCt},],
							ret: macro :Array<gamessa.script.Effect>,
							expr: macro
							{
								this.state = s;

								switch (fn)
								{
									case Message(type, sid, payload):
										this.caller = sid;
										$b{dispatchChain(send, pos)};

									case Join(sid, auth):
										this.caller = sid;
										return onJoin(sid, auth);

									case Leave(sid, reason):
										this.caller = sid;
										return onLeave(sid, reason);

									case _:
										return null;
								}
							},
						}),
					pos: pos,
					meta: [],
				});

		// reply() — Request → request-@:rpc по имени, значение — ответ
		if (!hasField(fields, "reply"))
			fields.push(
				{
					name: "reply",
					access: [APrivate, AOverride],
					kind: FFun(
						{
							args: [
								{name: "fn", type: macro :gamessa.script.ScriptFn}, {name: "s", type: stateCt},],
							ret: macro :Dynamic,
							expr: macro
							{
								this.state = s;

								switch (fn)
								{
									case Request(type, sid, payload):
										this.caller = sid;
										$b{dispatchChain(request, pos)};

									case _:
										return null;
								}
							},
						}),
					pos: pos,
					meta: [],
				});

		// стабы (public, исходные имена)
		for (r in rpcs)
			fields.push(stubField(r, server, pos));

		return fields;
	}

	// -------------------------------------------------------------------

	/**
		if-цепочка диспетчера @:rpc-методов: `if (type == "x") { декод
		аргументов; return __im_x(...); }`, в конце — null («не наш»).
		Для send-методов это эффекты, для request — значение-ответ.
	**/
	static function dispatchChain(rpcs:Array<Rpc>, pos:Position):Array<Expr>
	{
		final stmts:Array<Expr> = [];
		for (r in rpcs)
		{
			final body = decodeArgs(r, pos).concat([
				{expr: EReturn(callIm(r, pos)), pos: pos}]);
			stmts.push(macro if (type == $v{r.name}) $b{body});
		}
		stmts.push(macro return null);
		return stmts;
	}

	static function hasMeta(f:Field, name:String):Bool
		return f.meta != null && Lambda.exists(f.meta, m -> m.name == name);

	/** Декод аргументов из payload: типизированные локалы из полей документа. */
	static function decodeArgs(r:Rpc, pos:Position):Array<Expr>
		return [
			for (a in r.args)
				{
					expr: EVars([
						{
							name: a.name,
							type: a.type,
							expr: macro Reflect.field(payload, $v{a.name}),
						}
					]),
					pos: pos,
				}
		];

	static function callIm(r:Rpc, pos:Position):Expr
	{
		final args:Array<Expr> = [
			for (a in r.args)
				macro $i{a.name}
		];
		return {expr: ECall({expr: EConst(CIdent("__im_" + r.name)), pos: pos}, args), pos: pos};
	}

	/** Стаб @:rpc-метода: сервер — делегация в __im_; клиент — отправка через room. */
	static function stubField(r:Rpc, server:Bool, pos:Position):Field
	{
		final payloadObj:Expr =
			{
				expr: EObjectDecl([for (a in r.args) {field: a.name, expr: macro $i{a.name}}]),
				pos: pos,
			};

		if (server)
		{
			return {
				name: r.name,
				access: [APublic],
				kind: FFun({args: copyArgs(r.args), ret: r.ret, expr: {expr: EReturn(callIm(r, pos)), pos: pos}}),
				pos: pos,
				meta: [],
			};
		}

		if (r.isSend)
			return {
				name: r.name,
				access: [APublic],
				kind: FFun({args: copyArgs(r.args), ret: macro :Void, expr: macro this.room.send($v{r.name}, $payloadObj)}),
				pos: pos,
				meta: [],
			};

		// request-стаб: результат через колбэк (значение — документ провода)
		final args = copyArgs(r.args).concat([
			{name: "onResult", opt: true, type: macro :Dynamic->Void},
			{name: "onError", opt: true, type: macro :gamessa.MatchMakeError->Void},
		]);

		return {
			name: r.name,
			access: [APublic],
			kind: FFun(
				{
					args: args,
					ret: macro :Void,
					expr: macro this.room.request($v{r.name}, $payloadObj, null, onResult == null ? (function(_v:Dynamic):Void
					{
					}) : onResult, onError == null ? (function(_e:gamessa.MatchMakeError):Void
					{
					}) : onError),
				}),
			pos: pos,
			meta: [],
		};
	}

	static function copyArgs(args:Array<FunctionArg>):Array<FunctionArg>
		return [
			for (a in args)
				{name: a.name, opt: false, type: a.type}
		];

	static function hasField(fields:Array<Field>, name:String):Bool
		return Lambda.exists(fields, f -> f.name == name);

	/**
		TState, с которым `gamessa.script.Sync` инстанцирован для `cls`
		(подстановка параметров по цепочке, как в ServerLogicBuilder);
		null — cls не наследник Sync (например, сам Sync).
	**/
	static function syncStateType(root:ClassType):Null<Type>
	{
		var cls = root;
		var subst:Map<String, Type> = new Map();

		while (cls != null)
		{
			final sup = cls.superClass;
			if (sup == null)
				return null;
			final supCls = sup.t.get();

			final resolved = [for (t in sup.params) substParam(t, subst)];

			if (supCls.pack.join(".") == "gamessa.script" && supCls.name == "Sync")
				return resolved[0];

			subst = new Map();
			for (i in 0...supCls.params.length)
				if (i < resolved.length)
					subst.set(supCls.params[i].name, resolved[i]);

			cls = supCls;
		}

		return null;
	}

	// формальный параметр в позиции Type — TInst класса с kind KTypeParameter
	static function isTypeParamClass(ct:ClassType):Bool
		return switch (ct.kind)
		{
			case KTypeParameter(_): true;
			case _: false;
		}

	static function substParam(t:Type, subst:Map<String, Type>):Type
	{
		final t = TypeTools.follow(t, true);
		return switch (t)
		{
			case TInst(t, _) if (isTypeParamClass(t.get()) && subst.exists(t.get().name)):
				subst.get(t.get().name);

			case _:
				t;
		}
	}
}
#end
