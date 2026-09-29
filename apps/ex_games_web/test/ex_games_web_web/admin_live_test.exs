defmodule ExGamesWebWeb.AdminLiveTest do
  @moduledoc """
  Админ-панель: сессионная auth-гвардия, вход через trigger-action,
  страницы users/rooms/online, действия (бан, роли, lock/dispose).
  """

  use ExGamesWebWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ExGames.Account

  setup do
    {:ok, admin} =
      Account.register(%{
        "username" => "root_#{System.unique_integer([:positive])}",
        "password" => "secret123"
      })

    {:ok, _role, _} = Account.grant_role(admin, :admin)

    on_exit(fn ->
      for %{room_id: rid} <- ExGames.Matchmaker.all_listings() do
        ExGames.Rooms.stop(rid)
      end
    end)

    %{admin: Account.fetch_user_by_id(admin.id) |> elem(1)}
  end

  defp admin_conn(conn, admin) do
    init_test_session(conn, %{"admin_uid" => admin.id})
  end

  # -------------------------------------------------------------------------
  # Auth-гвардия и вход
  # -------------------------------------------------------------------------

  test "аноним на /admin → редирект на /admin/login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/admin/login"}}} = live(conn, "/admin")
  end

  test "не-админ на /admin → редирект", %{conn: conn} do
    {:ok, user} = Account.register(%{"username" => "player1", "password" => "secret123"})

    assert {:error, {:redirect, %{to: "/admin/login"}}} =
             live(init_test_session(conn, %{"admin_uid" => user.id}), "/admin")
  end

  test "админ видит dashboard", %{conn: conn, admin: admin} do
    {:ok, view, _html} = admin_conn(conn, admin) |> live("/admin")

    assert has_element?(view, "#drain-status")
    assert has_element?(view, "#room-types")
    assert render(view) =~ "Обзор"
  end

  test "страница логина рендерится", %{conn: conn} do
    conn = get(conn, "/admin/login")
    assert html_response(conn, 200) =~ "ExGames Admin"
  end

  test "вход админом через trigger-action → редирект в панель", %{conn: conn, admin: admin} do
    {:ok, view, _html} = live(conn, "/admin/login")

    form =
      form(view, "#admin-login-form", %{
        "login" => %{"username" => admin.username, "password" => "secret123"}
      })

    render_submit(form)
    conn = follow_trigger_action(form, conn)

    assert redirected_to(conn) == "/admin"
  end

  test "вход обычным игроком → отказ, редирект обратно на логин", %{conn: conn} do
    {:ok, _user} = Account.register(%{"username" => "player2", "password" => "secret123"})
    {:ok, view, _html} = live(conn, "/admin/login")

    form =
      form(view, "#admin-login-form", %{
        "login" => %{"username" => "player2", "password" => "secret123"}
      })

    render_submit(form)
    conn = follow_trigger_action(form, conn)

    assert redirected_to(conn) == "/admin/login"
  end

  test "выход очищает сессию", %{conn: conn, admin: admin} do
    conn =
      admin_conn(conn, admin)
      |> delete("/admin/logout")

    assert redirected_to(conn) == "/admin/login"

    assert {:error, {:redirect, %{to: "/admin/login"}}} =
             live(conn |> recycle() |> init_test_session(%{}), "/admin")
  end

  # -------------------------------------------------------------------------
  # Пользователи
  # -------------------------------------------------------------------------

  test "список и поиск", %{conn: conn, admin: admin} do
    suffix = System.unique_integer([:positive])
    {:ok, _} = Account.register(%{"username" => "bobuser_#{suffix}", "password" => "secret123"})

    {:ok, view, _html} = admin_conn(conn, admin) |> live("/admin/users")

    # админ может быть не на первой странице (в тестовой БД много юзеров) —
    # сначала фильтр по нему, затем по bobuser
    view
    |> element("#user-filters")
    |> render_change(%{"filter" => %{"search" => admin.username}})

    assert render(view) =~ admin.username

    view
    |> element("#user-filters")
    |> render_change(%{"filter" => %{"search" => "bobuser_#{suffix}"}})

    html = render(view)
    assert html =~ "bobuser_#{suffix}"
    # имя админа остаётся в топбаре сайдбара — проверяем, что его СТРОКА
    # таблицы ушла
    refute html =~ "href=\"/admin/users/#{admin.id}\""
  end

  test "бан с причиной и разбан", %{conn: conn, admin: admin} do
    {:ok, victim} = Account.register(%{"username" => "victim", "password" => "secret123"})

    {:ok, view, _html} = admin_conn(conn, admin) |> live("/admin/users")

    # victim за пределами первой страницы — подводим поиском
    view |> element("#user-filters") |> render_change(%{"filter" => %{"search" => "victim"}})

    view
    |> element("button[phx-click='ask_ban'][phx-value-id='#{victim.id}']")
    |> render_click()

    view
    |> element("#ban-form")
    |> render_submit(%{"ban" => %{"reason" => "спам в чате"}})

    {:ok, banned} = Account.fetch_user_by_id(victim.id)
    assert banned.banned_at
    assert banned.ban_reason == "спам в чате"

    # разбан
    view
    |> element("button[phx-click='unban'][phx-value-id='#{victim.id}']")
    |> render_click()

    {:ok, unbanned} = Account.fetch_user_by_id(victim.id)
    refute unbanned.banned_at
  end

  test "отмена бана: submit после cancel не банит (кнопка type=button)", %{conn: conn, admin: admin} do
    {:ok, victim} = Account.register(%{"username" => "victim2", "password" => "secret123"})

    {:ok, view, _html} = admin_conn(conn, admin) |> live("/admin/users")

    view |> element("#user-filters") |> render_change(%{"filter" => %{"search" => "victim2"}})

    view
    |> element("button[phx-click='ask_ban'][phx-value-id='#{victim.id}']")
    |> render_click()

    # «Отмена» + дошедший следом submit формы (тот самый баг: кнопка без
    # type внутри формы сабмитит) — юзер должен остаться небаненым
    view
    |> element("#ban-form button[phx-click='cancel_ban']")
    |> render_click()

    assert {:ok, user} = Account.fetch_user_by_id(victim.id)
    refute user.banned_at
    refute render(view) =~ "Забанить"
  end

  test "выдача и снятие роли", %{conn: conn, admin: admin} do
    {:ok, user} = Account.register(%{"username" => "promotee", "password" => "secret123"})

    {:ok, view, _html} = admin_conn(conn, admin) |> live("/admin/users")

    view |> element("#user-filters") |> render_change(%{"filter" => %{"search" => "promotee"}})

    view
    |> element("#grant-role-#{user.id}")
    |> render_change(%{"role" => "moderator"})

    {:ok, user} = Account.fetch_user_by_id(user.id)
    assert Account.has_role?(user, :moderator)

    view
    |> element(
      "button[phx-click='revoke_role'][phx-value-id='#{user.id}'][phx-value-role='moderator']"
    )
    |> render_click()

    {:ok, user} = Account.fetch_user_by_id(user.id)
    refute Account.has_role?(user, :moderator)
  end

  test "детали пользователя: рейтинги и сейвы", %{conn: conn, admin: admin} do
    {:ok, _} = Account.save_data(admin.id, "profile", %{"level" => 5})
    {:ok, other} = Account.register(%{"username" => "rival", "password" => "secret123"})
    {:ok, _} = Account.record_match("arena", %{admin.id => :win, other.id => :loss})

    {:ok, view, _html} = admin_conn(conn, admin) |> live("/admin/users/#{admin.id}")

    assert render(view) =~ "arena"
    assert render(view) =~ "profile"
    assert has_element?(view, "#user-saves")
  end

  # -------------------------------------------------------------------------
  # Комнаты
  # -------------------------------------------------------------------------

  test "список комнат: lock и dispose", %{conn: conn, admin: admin} do
    ExGames.Matchmaker.define_room("admin_test", ExGamesWeb.Test.Room)
    {:ok, reservation} = ExGames.Matchmaker.create("admin_test", %{"user_id" => admin.id}, %{})
    room_id = reservation.room_id

    {:ok, view, _html} = admin_conn(conn, admin) |> live("/admin/rooms")

    assert render(view) =~ room_id

    # lock
    view
    |> element("button[phx-click='lock'][phx-value-id='#{room_id}']")
    |> render_click()

    assert {:ok, %{locked: true}} = ExGames.Room.Server.listing(room_id)

    # unlock
    view
    |> element("button[phx-click='unlock'][phx-value-id='#{room_id}']")
    |> render_click()

    assert {:ok, %{locked: false}} = ExGames.Room.Server.listing(room_id)

    # dispose с подтверждением
    view
    |> element("button[phx-click='ask_dispose'][phx-value-id='#{room_id}']")
    |> render_click()

    view
    |> element("button[phx-click='dispose'][phx-value-id='#{room_id}']")
    |> render_click()

    refute ExGames.Rooms.alive?(room_id)
  end

  test "детали комнаты: клиенты и панель состояния", %{conn: conn, admin: admin} do
    ExGames.Matchmaker.define_room("admin_test", ExGamesWeb.Test.Room)
    {:ok, reservation} = ExGames.Matchmaker.create("admin_test", %{"user_id" => admin.id}, %{})
    room_id = reservation.room_id

    {:ok, view, _html} = admin_conn(conn, admin) |> live("/admin/rooms/#{room_id}")

    assert render(view) =~ "ExGamesWeb.Test.Room"
    assert has_element?(view, "#room-clients")

    # панель состояния рендерится всегда: либо снапшот, либо пометка «пусто»
    assert render(view) =~ "Состояние (set_state)"
    assert has_element?(view, "#room-state-snapshot") || has_element?(view, "#room-state-empty")
  end

  # -------------------------------------------------------------------------
  # Онлайн
  # -------------------------------------------------------------------------

  test "presence: трекнутый пользователь виден", %{conn: conn, admin: admin} do
    ExGames.Presence.track_user("ann", %{"username" => "ann", "room_id" => nil})

    {:ok, view, _html} = admin_conn(conn, admin) |> live("/admin/online")

    assert render(view) =~ "ann"
  end
end
