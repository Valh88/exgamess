package gamessa.script;

/**
	@:autoBuild-билдер ServerLogic (см. ServerLogic.hx).

	На всех таргетах генерирует в наследника:
	  * `__lower(e:Array<Effect>):Array<Dynamic>` — понижение эффектов
	    в сырые массивы контракта моста;
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

class ServerLogicBuilder {
	#if macro
	public static function build():Array<Field> {
		final cls = Context.getLocalClass().get();
		final fields = Context.getBuildFields();
		final lua = Context.defined("lua");

		final stateType:Null<Type> = try {
			final sup = cls.superClass;
			final supType = sup.t.get();
			if (supType.pack.join(".") == "gamessa.script" && supType.name == "ServerLogic" && sup.params.length > 0)
				sup.params[0]
			else
				null;
		} catch (_:Dynamic)
			null;

		final classRef = cls.pack.length == 0 ? cls.name : "__" + cls.pack.join("_") + "_" + cls.name;

		// __lower — на всех таргетах (клиент предсказывает эффекты)
		fields.push((macro class {
			public static function __lower(e:Array<Effect>):Array<Dynamic> {
				if (e == null)
					return null;
				return [
					for (x in e)
						switch (x) {
							case Broadcast(type, payload):
								["broadcast", type, payload];
							case SendTo(sid, type, payload):
								["send_to", sid, type, payload];
							case Kick(sid):
								["kick", sid];
							case Lock:
								["lock"];
							case Unlock:
								["unlock"];
							case SetMetadata(metadata):
								["set_metadata", metadata];
						}
				];
			}
		}).fields[0]);

		// __stateLua — литерал state-схемы из typedef'а
		final stateLua = stateType == null ? "{}" : typeToLua(stateType, cls.pos);
		fields.push((macro class {
			public static var __stateLua(default, null):String = $v{stateLua};
		}).fields[0]);

		if (lua) {
			cls.meta.add(":keep", [], cls.pos);

			final instCt = TPath({pack: cls.pack, name: cls.name});
			fields.push((macro class {
				static var __inst:$instCt;
			}).fields[0]);

			// __callWire — реальный Haxe-код (DCE его сохранит): здесь живут
			// ссылки на ScriptFn.fromWire и __lower, которые иначе вырезались бы,
			// т.к. упоминаются только в __lua__-строке биндинга
			final stateCt = stateType == null
				? (macro :Dynamic)
				: TypeTools.toComplexType(stateType);
			fields.push((macro class {
				static function __callWire(fn:String, a:Dynamic, s:$stateCt):Array<Dynamic> {
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

			fields.push((macro class {
				static function main() {
					__inst = new $clsPath();
					untyped __lua__($v{binding});
				}
			}).fields[0]);
		}

		return fields;
	}

	// -------------------------------------------------------------------

	static function typeToLua(t:Type, pos:Position):String {
		final t = TypeTools.follow(t, true);
		return switch (t) {
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
