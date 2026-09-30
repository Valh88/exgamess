package gamessa.script;

/**
	@:autoBuild-билдер ServerLogic (см. ServerLogic.hx).

	На всех таргетах генерирует в наследника:
	  * `__lower(e:Array<Effect>):Array<Dynamic>` — понижение эффектов
		в сырые массивы контракта моста. Строится интроспекцией enum'а
		`Effect` по конвенции: тег = snake_case(имя конструктора),
		аргументы — по порядку объявления. Новый конструктор в enum'е
		получает понижение автоматически; за применение на сервере
		отвечает whitelist моста (`apply_effect/2` в
		ExGames.Room.Logics.Lua) — это отдельная осознанная правка;
	  * `__stateLua:String` — литерал state-схемы, выведенный из typedef'а
		TState (Int/Float→number, String→string, Bool→boolean,
		DynamicAccess<X>→{map=X}, Array<X>→{list=X}, структура→таблица,
		Dynamic→"any").

	Дополнительно под `-lua`:
	  * `@:keep` на классе (DCE вырезал бы методы, на которые ссылается
		только __lua__-биндинг);
	  * `static main()`: создаёт экземпляр, публикует его в Lua-глобал
		`__logic_inst` и собирает контракт M (init/call/tick + schema,
		где messages берутся из статической `messages()` наследника).
**/
#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import haxe.macro.TypeTools;
#end

class ServerLogicBuilder
{
	#if macro
	public static function build():Array<Field>
	{
		final cls = Context.getLocalClass().get();
		final fields = Context.getBuildFields();
		final lua = Context.defined("lua");

		final stateType:Null<Type> = serverLogicStateType(cls);
		// абстрактный уровень цепочки (сам Sync<TState>): конкретный документ
		// неизвестен — Lua-машинерию (main/биндинг) не генерируем, он и не
		// точка входа; __lower/__stateLua безвредны и остаются
		final concrete = stateType != null && !isTypeParam(stateType);

		final classRef = cls.pack.length == 0 ? cls.name : "__" + cls.pack.join("_") + "_" + cls.name;

		// __lower — на всех таргетах (клиент предсказывает эффекты);
		// строится из enum'а Effect, а не захардкожено
		fields.push(lowerEffectField(cls.pos));

		// __stateLua — литерал state-схемы из typedef'а
		final stateLua = stateType == null ? "{}" : typeToLua(stateType, cls.pos);
		fields.push((macro class
			{
				public static var __stateLua(default, null):String = $v{stateLua};
			}).fields[0]);

		if (lua && concrete)
		{
			cls.meta.add(":keep", [], cls.pos);

			final instCt = TPath({pack: cls.pack, name: cls.name});
			fields.push((macro class
				{
					static var __inst:$instCt;
				}).fields[0]);

			// __callWire — реальный Haxe-код (DCE его сохранит): здесь живут
			// ссылки на ScriptWire.fromWire/__lower/reply, которые иначе
			// вырезались бы, т.к. упоминаются только в __lua__-строке биндинга.
			// Request-вызов идёт в reply(): возвращается само ЗНАЧЕНИЕ-ОТВЕТ
			// (мост в этом потоке не применяет эффекты, а отвечает клиенту);
			// null — «обработчика нет».
			final stateCt = TypeTools.toComplexType(stateType);
			fields.push((macro class
				{
					static function __callWire(fn:String, a:Dynamic, s:$stateCt):Dynamic
					{
						final wire:gamessa.script.ScriptFn = gamessa.script.ScriptWire.fromWire(fn, a);
						if (gamessa.script.ScriptWire.isRequest(wire))
							return __inst.reply(wire, s);
						return __lower(__inst.call(wire, s));
					}
				}).fields[0]);

			final binding = [
				'__logic_inst = $classRef.__inst',
				'M = {}',
				'function M.init(a) return __hx_toplain(__logic_inst:init(a)) end',
				'function M.call(fn, a, s) return __hx_toplain($classRef.__callWire(fn, a, s)), __hx_toplain(s) end',
				'function M.tick(dt, s) __logic_inst:tick(dt, s); return nil, __hx_toplain(s) end',
				'M.schema = { messages = __hx_toplain($classRef.messages()), state = $stateLua }',
			].join("\n");

			final clsPath:TypePath = {pack: cls.pack, name: cls.name};

			fields.push((macro class
				{
					static function main()
					{
						__inst = new $clsPath();
						untyped __lua__($v{binding});
					}
				}).fields[0]);
		}

		return fields;
	}

	/**
		Тип состояния ServerLogic<TState> для класса `cls` с подъёмом по
		всей цепочке наследования и подстановкой параметров: у
		промежуточных классов (`class Sync<T> extends ServerLogic<T>`,
		`class ChatSync extends Sync<ChatState>`) прямой родитель — не
		ServerLogic, а его формальный параметр надо разрешить через
		аргумент, с которым он инстанцирован у наследника.
	**/
	static function serverLogicStateType(root:ClassType):Null<Type>
	{
		var cls = root;
		// привязки формальных параметров текущего уровня (root — конкретный)
		var subst:Map<String, Type> = new Map();

		while (cls != null)
		{
			final sup = cls.superClass;
			if (sup == null)
				return null;
			final supCls = sup.t.get();

			final resolved = [for (t in sup.params) substParam(t, subst)];

			if (supCls.pack.join(".") == "gamessa.script" && supCls.name == "ServerLogic")
				return resolved[0];

			// следующий уровень: его параметры связаны аргументами этого
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

	static function isTypeParam(t:Type):Bool
		return switch (TypeTools.follow(t, true))
		{
			case TInst(t, _): isTypeParamClass(t.get());
			case _: false;
		}

	// -------------------------------------------------------------------

	/**
		Поле `__lower`, сгенерированное из enum'а Effect: каждому
		конструктору — `case Ctor(a, b): ["ctor_tag", a, b];`
		(тег = snake_case имени, аргументы по порядку объявления).
	**/
	static function lowerEffectField(pos:Position):Field
	{
		final et = switch (Context.getType("gamessa.script.Effect"))
		{
			case TEnum(t, _):
				t.get();

			case _:
				Context.fatalError("gamessa.script.Effect должен быть enum", pos);
		}

		// порядок — из et.names (объявление), поля — из constructs
		final cases = [
			for (name in et.names)
			{
				final ctor = et.constructs[name];
				// аргументы конструктора enum'а лежат в его типе как TFun
				final args = switch (ctor.type)
				{
					case TFun(fargs, _):
						[for (a in fargs) {expr: EConst(CIdent(a.name)), pos: pos}];

					case _:
						[];
				}
				final ctorExpr = {expr: EConst(CIdent(name)), pos: pos};
				// паттерн нуль-аргументного конструктора — `Lock`, не `Lock()`
				final pattern = args.length == 0 ? ctorExpr :
					{expr: ECall(ctorExpr, args), pos: pos};
				{
					values: [pattern],
					guard: null,
					expr:
						{
							expr: EArrayDecl([
								{expr: EConst(CString(snakeCase(name))), pos: pos}].concat(args)),
							pos: pos
						}
				}
			}
		];

		final subject:Expr = {expr: EConst(CIdent("x")), pos: pos};
		final switchExpr:Expr = {expr: ESwitch(subject, cases, null), pos: pos};

		return {
			name: "__lower",
			access: [APublic, AStatic],
			kind: FFun(
				{
					args: [
						{name: "e", type: macro :Array<Effect>}],
					ret: macro :Array<Dynamic>,
					expr: macro
					{
						if (e == null)
							return null;
						return [for (x in e) $e{switchExpr}];
					}
				}),
			pos: pos,
			meta: []
		};
	}

	/** Broadcast → "broadcast", SetMetadata → "set_metadata". */
	static function snakeCase(name:String):String
	{
		final buf = new StringBuf();
		for (i in 0...name.length)
		{
			final ch = name.charAt(i);
			if (ch >= "A" && ch <= "Z")
			{
				if (i > 0)
					buf.addChar("_".code);
				buf.add(ch.toLowerCase());
			} else
			{
				buf.add(ch);
			}
		}
		return buf.toString();
	}

	static function typeToLua(t:Type, pos:Position):String
	{
		final t = TypeTools.follow(t, true);
		return switch (t)
		{
			// String в macro API — TInst (класс), Int/Float/Bool — TAbstract
			case TInst(_.get() => {pack: [], name: "String"}, _):
				'"string"';
			case TAbstract(_.get() => {pack: [], name: "Int" | "Float"}, _):
				'"number"';
			case TAbstract(_.get() => {pack: [], name: "String"}, _):
				'"string"';
			case TAbstract(_.get() => {pack: [], name: "Bool"}, _):
				'"boolean"';
			case TAbstract(_.get() => {pack: ["haxe"], name: "DynamicAccess"}, [inner]):
				'{ map = ${typeToLua(inner, pos)} }';
			case TInst(_.get() => {pack: [], name: "Array"}, [inner]):
				'{ list = ${typeToLua(inner, pos)} }';
			case TAnonymous(_.get() => anon):
				final parts = [for (f in anon.fields) '${f.name} = ${typeToLua(f.type, pos)}'];
				'{ ${parts.join(", ")} }';
			case _:
				'"any"';
		}
	}
	#end
}
