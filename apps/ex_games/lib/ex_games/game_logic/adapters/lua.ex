defmodule ExGames.GameLogic.Adapters.Lua do
  @moduledoc """
  In-process Lua-адаптер: логика — Lua-скрипт, исполняемый VM пакета `lua`
  (tv-labs, чистый Elixir, песочница из коробки) внутри BEAM.

  ## Контракт скрипта (таблица `M`)

      M.init(args) -> state
      M.call(fn, args, state) -> new_state | {result, new_state}
      M.tick(dt, state) -> new_state | {result, new_state}

  `result` в паре — произвольный документ. Через `GameLogic.Server.call/4`
  его читает вызывающий; через `GameLogic.Server.tick/1` его читает мост
  `ExGames.Room.Logics.Lua` как список эффектов (см. там же соглашение
  «первое возвращённое значение — эффекты»).

  ## Документы

  Состояние и аргументы — msgpack-совместимые документы (map со строковыми
  ключами, list, binary, число, bool, nil). Lua-таблицы при возврате
  нормализуются: таблица с целыми ключами — список (дыры схлопываются),
  иначе map со строковыми ключами; функции/tref/userdata — ошибка с путём
  до значения (`validate_doc/1`).

  ## Опции

    * `:script` — путь к .lua-файлу (обязателен); это может быть и чанк
      `haxe -lua` (см. `doc/LUA_SCRIPTING.md`, «Общая логика сервера и клиента»);
    * `:args` — аргументы `M.init` (default `[]`);
    * `:haxe` — `true` ставит шимы рантайма Haxe до загрузки скрипта
      (`ExGames.GameLogic.Adapters.Lua.Shims`); для чистых Lua-скриптов не нужно;
    * `:max_instructions` — бюджет инструкций VM на один вызов (default 1_000_000);
    * `:max_call_depth` — глубина вызовов (default 200).

  ## Семантика

    * Состояние — документ, который Server передаёт в каждый вызов 4-м
      аргументом и хранит у себя (модель нативных адаптеров: краш/рестарт
      адаптера не теряет игру; `Server.state/1` читает этот документ).
      VM между вызовами хранит глобальное окружение скрипта (copy-on-write,
      ошибка вызова откатывает её к дозвовому виду).
    * Ошибка скрипта — `{:error, {:lua, message}}`.
    * Рестарт адаптера = свежий `M.init` (состояние не сохраняется).
  """

  @behaviour ExGames.GameLogic.Adapter

  alias __MODULE__.Shims

  defstruct [:lua, :state, :script]

  @default_max_instructions 1_000_000
  @default_max_call_depth 200

  @type doc :: nil | boolean() | number() | String.t() | list() | %{String.t() => doc()}
  @type t :: %__MODULE__{lua: Lua.t(), state: doc(), script: String.t()}

  # -------------------------------------------------------------------------

  @impl true
  def start_link(opts) do
    script = Keyword.fetch!(opts, :script)
    args = Keyword.get(opts, :args, [])

    # песочница включена в `Lua.new/1` по умолчанию (io/file/os/package/
    # load/require заблокированы); :sandboxed — список путей, не boolean
    lua =
      Lua.new(
        max_instructions: Keyword.get(opts, :max_instructions, @default_max_instructions),
        max_call_depth: Keyword.get(opts, :max_call_depth, @default_max_call_depth)
      )

    # шимы рантайма Haxe — до load_file: прелюдия чанка зовёт их при загрузке
    lua = if Keyword.get(opts, :haxe, false) == true, do: Shims.install(lua), else: lua

    with {:load, {:ok, lua}} <- {:load, load_file(lua, script)},
         {:init, {:ok, [state_pairs], lua}} <- {:init, call_m(lua, "init", [args])},
         {:doc, {:ok, doc}} <- {:doc, validate_doc(state_pairs)} do
      {:ok, %__MODULE__{lua: lua, state: doc, script: script}}
    else
      {:load, {:error, reason}} -> {:error, reason}
      {:init, {:error, e, _lua}} -> {:error, {:lua, Exception.message(e)}}
      {:doc, {:error, reason}} -> {:error, {:lua, "M.init: " <> reason}}
    end
  end

  @impl true
  def call(%__MODULE__{} = handle, fn_name, args, doc),
    do: invoke(%__MODULE__{handle | state: doc}, "call", [fn_name, args])

  @impl true
  def tick(%__MODULE__{} = handle, dt_ms, doc),
    do: invoke(%__MODULE__{handle | state: doc}, "tick", [dt_ms])

  @impl true
  def stop(_handle), do: :ok

  # -------------------------------------------------------------------------

  # Вызов M.<fname>; документ состояния передаётся последним аргументом.
  # Резолв M и сам вызов защищены: любая ошибка — {:error, {:lua, msg}},
  # состояние (документ) остаётся у Server прежним.
  defp invoke(%__MODULE__{} = handle, fname, args) do
    {encoded_args, lua} = Lua.encode_list!(handle.lua, args ++ [handle.state])

    case protected_call(lua, ["M", fname], encoded_args) do
      {:ok, results, new_lua} ->
        # результаты — сырые VM-значения (таблицы = tref): декодируем в
        # пары списков, затем нормализуем в документ
        case interpret_results(Enum.map(results, &Lua.decode!(new_lua, &1)), fname) do
          {:ok, result, doc} -> {:ok, result, doc}
          {:error, reason} -> {:error, {:lua, "M.#{fname}: " <> reason}}
        end

      {:error, e, _new_lua} ->
        {:error, {:lua, Exception.message(e)}}
    end
  end

  # 1 результат = новый state; 2 результата = {result, new_state}.
  defp interpret_results(results, _fname) do
    case results do
      [state_pairs] ->
        with {:ok, doc} <- validate_doc(state_pairs), do: {:ok, nil, doc}

      [result_pairs, state_pairs] ->
        with {:ok, result} <- validate_doc(result_pairs),
             {:ok, doc} <- validate_doc(state_pairs) do
          {:ok, result, doc}
        end

      other ->
        {:error, "expected 1 or 2 return values, got #{length(other)}"}
    end
  end

  defp call_m(lua, fname, args) do
    {encoded_args, lua} = Lua.encode_list!(lua, args)

    case protected_call(lua, ["M", fname], encoded_args) do
      {:ok, results, lua} -> {:ok, Enum.map(results, &Lua.decode!(lua, &1)), lua}
      {:error, e, lua} -> {:error, e, lua}
    end
  end

  # call_function/3 защищает только сам вызов: резолв пути (нет таблицы M
  # или функции) кидает Lua.RuntimeException мимо {:error, ...} — ловим.
  defp protected_call(lua, path, args) do
    Lua.call_function(lua, path, args)
  rescue
    e in [Lua.RuntimeException, Lua.CompilerException] -> {:error, e, lua}
  end

  # load_file!/2 кидает на ошибке компиляции/чтения — здесь это стартовая
  # ошибка адаптера, а не краш процесса.
  defp load_file(lua, script) do
    {:ok, Lua.load_file!(lua, script)}
  rescue
    e in [Lua.CompilerException, Lua.RuntimeException] -> {:error, {:lua, Exception.message(e)}}
  end

  # -------------------------------------------------------------------------
  # Документы: декодированная Lua → msgpack-совместимый документ
  # -------------------------------------------------------------------------

  @doc """
  Нормализует декодированное значение Lua в документ. Декодированная
  таблица — список пар `{key, value}`; все ключи целые → список (по
  возрастанию ключа, дыры схлопываются), иначе map со строковыми ключами.
  Пустая таблица — пустой map.
  """
  @spec validate_doc(term()) :: {:ok, doc()} | {:error, String.t()}
  def validate_doc(term), do: doc(term, "$")

  defp doc(nil, _path), do: {:ok, nil}
  defp doc(v, _path) when is_boolean(v), do: {:ok, v}
  defp doc(v, _path) when is_integer(v), do: {:ok, v}

  # NaN отсекается сравнением с самим собой, ±inf — границей max finite
  defp doc(v, path) when is_float(v) do
    if v == v and abs(v) <= Float.max_finite(),
      do: {:ok, v},
      else: {:error, "#{path}: non-finite number"}
  end

  defp doc(v, _path) when is_binary(v), do: {:ok, v}
  defp doc(pairs, path) when is_list(pairs), do: doc_table(pairs, path)
  defp doc({:tref, _}, path), do: {:error, "#{path}: table reference (cyclic?)"}
  defp doc({:userdata, _}, path), do: {:error, "#{path}: userdata"}

  defp doc(fun, path) when is_tuple(fun), do: {:error, "#{path}: function"}

  defp doc(other, path), do: {:error, "#{path}: unsupported type #{inspect(other)}"}

  defp doc_table([], _path), do: {:ok, %{}}

  defp doc_table(pairs, path) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if Enum.all?(keys, &is_integer/1) do
      values = pairs |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))

      values
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {v, i}, {:ok, acc} ->
        case doc(v, "#{path}[#{i}]") do
          {:ok, dv} -> {:cont, {:ok, [dv | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, list} -> {:ok, Enum.reverse(list)}
        error -> error
      end
    else
      pairs
      |> Enum.reduce_while({:ok, %{}}, fn {k, v}, {:ok, acc} ->
        case doc_key(k, path) do
          {:ok, key} ->
            case doc(v, "#{path}.#{key}") do
              {:ok, dv} -> {:cont, {:ok, Map.put(acc, key, dv)}}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp doc_key(k, _path) when is_binary(k), do: {:ok, k}
  defp doc_key(k, _path) when is_integer(k), do: {:ok, Integer.to_string(k)}
  defp doc_key(k, _path) when is_atom(k), do: {:ok, Atom.to_string(k)}

  defp doc_key(k, path), do: {:error, "#{path}: unsupported table key #{inspect(k)}"}
end
