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

		final stateType:Null<Type> = try
		{
			final sup = cls.superClass;
			final supType = sup.t.get();
			if (supType.pack.join(".") == "gamessa.script" && supType.name == "ServerLogic" && sup.params.length > 0)
				sup.params[0]
			else
				null;
		} catch (_:Dynamic)
			null;

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

		if (lua)
		{
			cls.meta.add(":keep", [], cls.pos);

			final instCt = TPath({pack: cls.pack, name: cls.name});
			fields.push((macro class
				{
					static var __inst:$instCt;
				}).fields[0]);

			// __callWire — реальный Haxe-код (DCE его сохранит): здесь живут
			// ссылки на ScriptFn.fromWire и __lower, которые иначе вырезались бы,
			// т.к. упоминаются только в __lua__-строке биндинга
			final stateCt = stateType == null ? (macro :Dynamic) : TypeTools.toComplexType(stateType);
			fields.push((macro class
				{
					static function __callWire(fn:String, a:Dynamic, s:$stateCt):Array<Dynamic>
					{
						return __lower(__inst.call(gamessa.script.ScriptWire.fromWire(fn, a), s));
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
