-- Фикстура: счётчик с полным набором путей вызова (для lua_adapter_test).
-- Контракт: одиночное возвращаемое значение = новый state; пара = {result, state}.
M = {}

function M.init(args)
  return { count = 0, ticks = 0, label = args[1] or "none" }
end

function M.call(fn, args, state)
  if fn == "add" then
    state.count = state.count + args[1]
    return { op = "add", total = state.count }, state
  elseif fn == "get" then
    return state
  elseif fn == "nested" then
    return {
      label = args[1],
      inner = { a = 1, list = { 10, 20, 30 } },
      flags = { true, false },
    }, state
  elseif fn == "cyrillic" then
    return { text = "Привет, мир!" }, state
  elseif fn == "numbers" then
    return { i = 1 + 1, f = 1 / 2 }, state
  elseif fn == "cyclic" then
    local t = {}
    t.self = t
    return t, state
  elseif fn == "array_with_holes" then
    return { [1] = "a", [2] = "b", [4] = "d" }, state
  elseif fn == "fail" then
    error("boom", 0)
  elseif fn == "infinite" then
    return { x = 1 / 0 }, state
  elseif fn == "sandbox" then
    os.execute("echo pwned")
  elseif fn == "loop" then
    while true do end
  end
  return state
end

function M.tick(dt, state)
  state.ticks = state.ticks + dt
  -- {эффекты, state}: result читается драйвером тиков (мост/тест) как эффекты
  return { "broadcast", "ticked", { ticks = state.ticks } }, state
end
