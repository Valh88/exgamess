defmodule ExGames.Matchmaker do
  @moduledoc """
  Матчмейкер: реестр типов комнат + листинг живых комнат + брони мест.

  Двухфазный join (по образцу Colyseus):

      1. `join_or_create(room_name, auth_data, options)` — HTTP-вызов;
         возвращает `%ExGames.Matchmaker.Reservation{}` с `room_id` и
         `session_id` (место уже забронировано в комнате с TTL).
      2. Клиент подключается транспортом по `room_id`/`session_id`
         (`ExGames.Room.Server.attach/4`).

  Регистрация типов комнат — `define_room/3` (обычно в application- Boot):

      ExGames.Matchmaker.define_room("arena", MyGame.Arena, filter_by: ["mode"])

  Гонка параллельных `join_or_create` исключена: создание комнаты происходит
  внутри GenServer (сериализация), листинг живёт в ETS под его владением.
  """

  use GenServer

  alias ExGames.Id
  alias ExGames.Rooms
  alias ExGames.Room.Server

  require Logger

  @typedoc "Бронь места: результат шага 1 двухфазного join."
  @type reservation :: %__MODULE__.Reservation{
          room_name: String.t(),
          room_id: Id.id(),
          session_id: Id.id()
        }

  @typedoc "Опции регистрации типа комнаты."
  @type define_opts :: [filter_by: [String.t()], name: String.t()]

  @ets :ex_games_matchmaker_rooms
  @seat_ttl 15_000

  # -------------------------------------------------------------------------
  # Публичный API
  # -------------------------------------------------------------------------

  @doc "Регистрирует тип комнаты. Возвращает :ok (идемпотентно)."
  @spec define_room(String.t(), module(), define_opts()) :: :ok
  def define_room(room_name, module, opts \\ []) when is_binary(room_name) do
    GenServer.call(__MODULE__, {:define, room_name, module, opts})
  end

  @doc "Зарегистрированные типы комнат: %{name => module}."
  @spec definitions() :: %{String.t() => module()}
  def definitions do
    GenServer.call(__MODULE__, :definitions)
  end

  @doc """
  Найти подходящую комнату или создать новую, забронировать место.
  `options` фильтруются по `filter_by` типа (остальные ключи игнорируются
  при поиске, но передаются в комнату).
  """
  @spec join_or_create(String.t(), term(), map()) ::
          {:ok, reservation()}
          | {:error, :unknown_room_type | :auth_failed | :locked | :draining | term()}
  def join_or_create(room_name, auth_data, options \\ %{}) do
    if draining?(),
      do: {:error, :draining},
      else: GenServer.call(__MODULE__, {:join_or_create, room_name, auth_data, options}, 10_000)
  end

  @doc "Создать новую комнату независимо от свободных мест."
  @spec create(String.t(), term(), map()) ::
          {:ok, reservation()} | {:error, :unknown_room_type | :auth_failed | :draining | term()}
  def create(room_name, auth_data, options \\ %{}) do
    if draining?(),
      do: {:error, :draining},
      else: GenServer.call(__MODULE__, {:create, room_name, auth_data, options}, 10_000)
  end

  @doc "Присоединиться только к существующей комнате (без создания)."
  @spec join(String.t(), term(), map()) ::
          {:ok, reservation()}
          | {:error, :unknown_room_type | :no_room | :auth_failed | :draining | term()}
  def join(room_name, auth_data, options \\ %{}) do
    if draining?(),
      do: {:error, :draining},
      else: GenServer.call(__MODULE__, {:join, room_name, auth_data, options}, 10_000)
  end

  @doc """
  Присоединиться к комнате по конкретному `room_id` (без поиска по типу).
  Комната может быть и не из матчмейкера (`room_name` брони будет `nil`).
  """
  @spec join_by_id(Id.id(), term(), map()) ::
          {:ok, reservation()}
          | {:error, :unknown_room | :locked | :full | :draining | term()}
  def join_by_id(room_id, auth_data, options \\ %{}) do
    if draining?() do
      {:error, :draining}
    else
      session_id = Id.session_id()

      case Server.reserve_seat(room_id, session_id, auth_data, options) do
        :ok ->
          {:ok,
           %__MODULE__.Reservation{
             room_name: room_name_for(room_id),
             room_id: room_id,
             session_id: session_id
           }}

        {:error, _reason} = err ->
          err
      end
    end
  end

  # Нода сливает трафик (ExGames.Runtime.Drain) — новых игроков не берём.
  defp draining?, do: ExGames.Runtime.Drain.draining?()

  @doc "Листинг комнат заданного типа (для лобби)."
  @spec query(String.t()) :: {:ok, [map()]} | {:error, :unknown_room_type}
  def query(room_name) do
    GenServer.call(__MODULE__, {:query, room_name})
  end

  @doc "Все листинги всех типов (для LobbyRoom)."
  @spec all_listings() :: [map()]
  def all_listings do
    case :ets.whereis(@ets) do
      :undefined ->
        []

      _ ->
        :ets.tab2list(@ets)
        |> Enum.filter(fn {key, _} -> key != :__definitions__ end)
        |> Enum.map(fn {_room_id, listing} -> listing end)
    end
  end

  @doc false
  # Обновляет листинг комнаты в ETS (вызывается Room.Server на join/leave).
  @spec refresh_listing(Id.id()) :: :ok
  def refresh_listing(room_id) do
    case :ets.lookup(@ets, room_id) do
      [{_, %{room_name: room_name}}] when is_binary(room_name) ->
        case Server.listing(room_id) do
          {:ok, listing} ->
            listing = listing |> Map.put(:room_name, room_name) |> Map.delete(:module)
            :ets.insert(@ets, {room_id, listing})
            :ok

          {:error, _} ->
            :ets.delete(@ets, room_id)
            :ok
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  @doc false
  @spec table() :: atom()
  def table, do: @ets

  @doc "PubSub-топик для событий листинга (подписка лобби)."
  @spec lobby_topic() :: String.t()
  def lobby_topic, do: "ex_games:lobby"

  # -------------------------------------------------------------------------
  # GenServer
  # -------------------------------------------------------------------------

  def start_link(_arg) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    ets =
      :ets.new(@ets, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        keypos: 1
      ])

    :ets.insert(ets, {:__definitions__, {%{}, %{}}})
    {:ok, %{ets: ets, monitors: %{}}}
  end

  @impl true
  def handle_call({:define, room_name, module, opts}, _from, state) do
    # :__definitions__ => {definitions_map, filter_by_map}
    [{_, {definitions, filter_by}}] = :ets.lookup(@ets, :__definitions__)

    :ets.insert(
      @ets,
      {:__definitions__,
       {Map.put(definitions, room_name, module),
        Map.put(filter_by, room_name, Keyword.get(opts, :filter_by, []))}}
    )

    {:reply, :ok, state}
  end

  def handle_call(:definitions, _from, state) do
    [{_, {defs, _}}] = :ets.lookup(@ets, :__definitions__)
    {:reply, defs, state}
  end

  def handle_call({:join_or_create, room_name, auth_data, options}, _from, state) do
    result =
      with :ok <- known_type?(room_name),
           :ok <- filter_has_required?(room_name, options) do
        case pick_room(room_name, options) do
          {:ok, room_id} ->
            reserve(room_name, room_id, auth_data, options)

          :error ->
            case start_room(room_name, options) do
              {:ok, room_id} -> reserve(room_name, room_id, auth_data, options)
              {:error, _} = err -> err
            end
        end
      end

    {:reply, result, state}
  end

  def handle_call({:create, room_name, auth_data, options}, _from, state) do
    result =
      with :ok <- known_type?(room_name) do
        case start_room(room_name, options) do
          {:ok, room_id} -> reserve(room_name, room_id, auth_data, options)
          {:error, _} = err -> err
        end
      end

    {:reply, result, state}
  end

  def handle_call({:join, room_name, auth_data, options}, _from, state) do
    result =
      with :ok <- known_type?(room_name) do
        case pick_room(room_name, options) do
          {:ok, room_id} -> reserve(room_name, room_id, auth_data, options)
          :error -> {:error, :no_room}
        end
      end

    {:reply, result, state}
  end

  def handle_call({:query, room_name}, _from, state) do
    with :ok <- known_type?(room_name) do
      listings =
        all_listings()
        |> Enum.filter(fn listing -> listing.room_name == room_name end)

      {:reply, {:ok, listings}, state}
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  # -------------------------------------------------------------------------
  # Внутреннее
  # -------------------------------------------------------------------------

  # Чтение definitions напрямую из ETS (не через GenServer.call — избегаем
  # self-call из handle_call).
  defp definitions! do
    case :ets.lookup(@ets, :__definitions__) do
      [{_, {defs, _}}] -> defs
      _ -> %{}
    end
  end

  defp known_type?(room_name) do
    if Map.has_key?(definitions!(), room_name) do
      :ok
    else
      {:error, :unknown_room_type}
    end
  end

  defp filter_has_required?(_room_name, _options), do: :ok

  # Выбирает подходящую комнату: не locked, есть места, совпадают фильтры.
  # Сортировка: наименее заполненная первой.
  defp pick_room(room_name, options) do
    filter_keys = get_filter_keys(room_name)

    candidates =
      all_listings()
      |> Enum.filter(fn listing ->
        listing.room_name == room_name and not listing.locked and
          listing.clients < listing.max_clients and
          filters_match?(listing.metadata, options, filter_keys)
      end)
      |> Enum.sort_by(&fill_ratio/1)

    case candidates do
      [] -> :error
      [listing | _] -> {:ok, listing.room_id}
    end
  end

  defp fill_ratio(%{max_clients: :infinity, clients: clients}), do: {clients, 999_999}
  defp fill_ratio(%{clients: clients, max_clients: max}), do: {clients, max}

  defp get_filter_keys(room_name) do
    [{_, {_defs, filter_by}}] = :ets.lookup(@ets, :__definitions__)
    Map.get(filter_by, room_name, [])
  end

  defp filters_match?(_metadata, _options, []), do: true

  defp filters_match?(metadata, options, filter_keys) do
    Enum.all?(filter_keys, fn key ->
      case Map.fetch(options, key) do
        {:ok, value} -> Map.get(metadata, key) == value
        :error -> true
      end
    end)
  end

  defp start_room(room_name, options) do
    module = Map.fetch!(definitions!(), room_name)

    filter_keys = get_filter_keys(room_name)

    # фильтры попадают в метаданные комнаты — по ним потом ищем в листинге
    create_options = Map.take(options, filter_keys)

    opts = [options: create_options, room_name: room_name]

    case Rooms.start(module, opts) do
      {:ok, room_id} ->
        Logger.debug("[ex_games] created room #{room_id} (#{room_name})")

        # листинг публикует сама комната в init (room_name из opts);
        # здесь только мониторим, чтобы подчистить ETS при смерти комнаты
        monitor_room(room_id)

        {:ok, room_id}

      {:error, _reason} = err ->
        err
    end
  end

  # Следим за комнатой: падение/закрытие → чистка листинга.
  defp monitor_room(room_id) do
    case Rooms.lookup(room_id) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        GenServer.cast(__MODULE__, {:track, room_id, ref})
        :ok

      :error ->
        :ok
    end
  end

  @impl true
  def handle_cast({:track, room_id, ref}, state) do
    {:noreply, %{state | monitors: Map.put(state.monitors, ref, room_id)}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {room_id, monitors} = Map.pop(state.monitors, ref)

    if room_id do
      :ets.delete(@ets, room_id)
      :telemetry.execute([:ex_games, :matchmaker, :room_gone], %{}, %{room_id: room_id})
    end

    {:noreply, %{state | monitors: monitors}}
  end

  defp reserve(room_name, room_id, auth_data, options) do
    session_id = Id.session_id()

    case Server.reserve_seat(room_id, session_id, auth_data, options, @seat_ttl) do
      :ok ->
        {:ok,
         %__MODULE__.Reservation{
           room_name: room_name,
           room_id: room_id,
           session_id: session_id
         }}

      {:error, _reason} = err ->
        err
    end
  end

  # Имя типа комнаты из листинга ETS (nil для комнат вне матчмейкера).
  defp room_name_for(room_id) do
    case :ets.lookup(@ets, room_id) do
      [{_, listing}] -> Map.get(listing, :room_name)
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
