defmodule ExGamesWebWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use ExGamesWebWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar px-4 sm:px-6 lg:px-8">
      <div class="flex-1">
        <a href="/" class="flex-1 flex w-fit items-center gap-2">
          <img src={~p"/images/logo.svg"} width="36" />
          <span class="text-sm font-semibold">v{Application.spec(:phoenix, :vsn)}</span>
        </a>
      </div>
      <div class="flex-none">
        <ul class="flex flex-column px-1 space-x-4 items-center">
          <li>
            <a href="https://phoenixframework.org/" class="btn btn-ghost">Website</a>
          </li>
          <li>
            <a href="https://github.com/phoenixframework/phoenix" class="btn btn-ghost">GitHub</a>
          </li>
          <li>
            <.theme_toggle />
          </li>
          <li>
            <a href="https://phoenix.hexdocs.pm/overview.html" class="btn btn-primary">
              Get Started <span aria-hidden="true">&rarr;</span>
            </a>
          </li>
        </ul>
      </div>
    </header>

    <main class="px-4 py-20 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-2xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Лейаут тёмной консоли админ-панели: sidebar с навигацией
  (`ExGamesWebWeb.Admin.Nav`), topbar с текущим администратором.

      <Layouts.admin flash={@flash} admin_user={@admin_user} current_path="/admin">
        ...
      </Layouts.admin>

  `bare` — центрированная карточка без sidebar (страница логина).
  """
  attr :flash, :map, required: true
  attr :admin_user, :any, default: nil
  attr :current_path, :string, default: nil
  attr :bare, :boolean, default: false

  slot :inner_block, required: true

  def admin(assigns) do
    ~H"""
    <div
      :if={!@bare}
      class="min-h-screen bg-slate-950 text-slate-200 antialiased"
    >
      <%!-- Консоль центрирована (max-w-7xl): сайдбар не прилипает к краю
           вьюпорта, а встаёт вровень с контентом --%>
      <div class="mx-auto flex w-full max-w-7xl">
      <%!-- Затемняющая подложка под выехавшим меню (только мобильные):
           тап по ней закрывает --%>
      <div
        id="admin-sidebar-backdrop"
        class="fixed inset-0 z-30 hidden bg-black/60 lg:hidden"
        aria-hidden="true"
        phx-click={
          JS.toggle(to: "#admin-sidebar", in: "flex", out: "hidden")
          |> JS.toggle(to: "#admin-sidebar-backdrop", in: "block", out: "hidden")
        }
      >
      </div>

      <%!-- Сайдбар: на узких экранах скрыт, выезжает по гамбургеру
           (JS.toggle, чисто клиентски); на lg+ — постоянный --%>
      <aside
        id="admin-sidebar"
        phx-hook=".AdminSidebar"
        class="fixed inset-y-0 left-0 z-40 hidden w-60 shrink-0 flex-col border-r border-slate-800 bg-slate-950 shadow-2xl shadow-black/50 lg:static lg:z-auto lg:flex lg:shadow-none lg:bg-slate-900/60"
      >
        <div class="flex items-center gap-2 border-b border-slate-800 px-5 py-4">
          <img src={~p"/images/logo.svg"} width="26" alt="" />
          <span class="font-semibold tracking-wide text-slate-100">ExGames</span>
          <span class="rounded bg-indigo-950 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wider text-indigo-300">
            admin
          </span>
          <button
            class="ml-auto inline-flex rounded-lg p-1.5 text-slate-500 transition-colors hover:bg-slate-800 hover:text-slate-200 lg:hidden"
            aria-label="Закрыть меню"
            phx-click={
              JS.toggle(to: "#admin-sidebar", in: "flex", out: "hidden")
              |> JS.toggle(to: "#admin-sidebar-backdrop", in: "block", out: "hidden")
            }
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <nav class="flex-1 space-y-1 overflow-y-auto px-3 py-4">
          <.admin_nav_link
            :for={item <- ExGamesWebWeb.Admin.Nav.items()}
            item={item}
            current_path={@current_path}
          />
        </nav>

        <div class="border-t border-slate-800 px-5 py-4">
          <div class="truncate text-sm text-slate-300">{@admin_user && @admin_user.username}</div>
          <.link
            href={~p"/admin/logout"}
            method="delete"
            class="mt-1 inline-flex items-center gap-1.5 text-xs text-slate-500 transition-colors hover:text-rose-300"
          >
            <.icon name="hero-arrow-left-on-rectangle" class="size-3.5" /> Выйти
          </.link>
        </div>
      </aside>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".AdminSidebar">
        export default {
          mounted() {
            this.onKey = (e) => {
              if (e.key !== "Escape" || this.el.classList.contains("hidden"))
                return;

              this.el.classList.add("hidden");
              this.el.classList.remove("flex");

              const backdrop = document.getElementById("admin-sidebar-backdrop");
              if (backdrop) {
                backdrop.classList.add("hidden");
                backdrop.classList.remove("block");
              }
            };

            // JS.toggle управляет инлайн-стилем display, который перебивает
            // lg:flex — после resize до десктопа сбрасываем инлайны,
            // иначе меню «пропадает» до перезагрузки страницы
            this.onResize = () => {
              if (window.innerWidth < 1024)
                return;

              this.el.style.display = "";

              const backdrop = document.getElementById("admin-sidebar-backdrop");
              if (backdrop)
                backdrop.style.display = "";
            };

            window.addEventListener("keydown", this.onKey);
            window.addEventListener("resize", this.onResize);
          },

          destroyed() {
            window.removeEventListener("keydown", this.onKey);
            window.removeEventListener("resize", this.onResize);
          }
        }
      </script>

      <div class="flex min-w-0 flex-1 flex-col">
        <%!-- Мобильный топбар с гамбургером (на lg+ скрыт) --%>
        <div class="flex items-center gap-3 border-b border-slate-800 bg-slate-900/60 px-4 py-3 lg:hidden">
          <button
            id="admin-menu-toggle"
            class="inline-flex items-center justify-center rounded-lg border border-slate-700 p-2 text-slate-300 transition-colors hover:bg-slate-800"
            aria-label="Показать/скрыть меню"
            phx-click={
              JS.toggle(to: "#admin-sidebar", in: "flex", out: "hidden")
              |> JS.toggle(to: "#admin-sidebar-backdrop", in: "block", out: "hidden")
            }
          >
            <.icon name="hero-bars-3" class="size-5" />
          </button>
          <span class="font-semibold tracking-wide text-slate-100">ExGames</span>
          <span class="rounded bg-indigo-950 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wider text-indigo-300">
            admin
          </span>
        </div>

        <main class="px-5 py-6 sm:px-8 lg:px-12 lg:py-8">
          {render_slot(@inner_block)}
        </main>
      </div>
      </div>

      <.flash_group flash={@flash} />
    </div>

    <div
      :if={@bare}
      class="flex min-h-screen items-center justify-center bg-slate-950 p-4 text-slate-200"
    >
      <div class="w-full max-w-sm">
        {render_slot(@inner_block)}
      </div>
      <.flash_group flash={@flash} />
    </div>
    """
  end

  attr :item, :map, required: true
  attr :current_path, :string, default: nil

  defp admin_nav_link(assigns) do
    ~H"""
    <.link
      navigate={@item.path}
      class={[
        "flex items-center gap-2.5 rounded-lg px-3 py-2 text-sm transition-colors",
        @current_path == @item.path &&
          "bg-indigo-950/70 font-medium text-indigo-200 border border-indigo-900/60",
        @current_path != @item.path &&
          "text-slate-400 border border-transparent hover:bg-slate-800 hover:text-slate-200"
      ]}
    >
      <.icon name={@item.icon} class="size-4 shrink-0" />
      {@item.label}
    </.link>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
