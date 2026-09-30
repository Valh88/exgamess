defmodule ExGamesWebWeb.AdminComponents do
  @moduledoc """
  Компоненты тёмной консоли админ-панели. Чистый Tailwind (без daisyUI)
  по правилу проекта: свой уникальный дизайн, полный контроль над
  бейджами, картами и плотными таблицами (со streams).
  """

  use Phoenix.Component

  # -------------------------------------------------------------------------
  # Стат-карта (dashboard)
  # -------------------------------------------------------------------------

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :tone, :string, default: "default", doc: "default | ok | warn | danger"
  attr :hint, :string, default: nil
  attr :navigate, :string, default: nil, doc: "путь раздела — карта становится ссылкой"

  def stat_card(assigns) do
    assigns = assign_new(assigns, :link?, fn a -> a.navigate != nil end)

    ~H"""
    <.link
      :if={@link?}
      navigate={@navigate}
      class={[
        "block rounded-xl border px-5 py-4 transition-colors cursor-pointer",
        @tone == "default" &&
          "border-slate-800 bg-slate-900/60 hover:border-indigo-800 hover:bg-slate-900",
        @tone == "ok" &&
          "border-emerald-900 bg-emerald-950/40 hover:border-emerald-700 hover:bg-emerald-950/70",
        @tone == "warn" &&
          "border-amber-900 bg-amber-950/40 hover:border-amber-700 hover:bg-amber-950/70",
        @tone == "danger" &&
          "border-rose-900 bg-rose-950/40 hover:border-rose-700 hover:bg-rose-950/70"
      ]}
    >
      <.stat_card_body label={@label} value={@value} tone={@tone} hint={@hint} />
    </.link>

    <div
      :if={!@link?}
      class={[
        "rounded-xl border px-5 py-4",
        @tone == "default" && "border-slate-800 bg-slate-900/60",
        @tone == "ok" && "border-emerald-900 bg-emerald-950/40",
        @tone == "warn" && "border-amber-900 bg-amber-950/40",
        @tone == "danger" && "border-rose-900 bg-rose-950/40"
      ]}
    >
      <.stat_card_body label={@label} value={@value} tone={@tone} hint={@hint} />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :tone, :string, required: true
  attr :hint, :string, default: nil

  defp stat_card_body(assigns) do
    ~H"""
    <div class="text-xs uppercase tracking-wider text-slate-500">{@label}</div>
    <div class={[
      "mt-1 text-3xl font-semibold tabular-nums",
      @tone == "default" && "text-slate-100",
      @tone == "ok" && "text-emerald-300",
      @tone == "warn" && "text-amber-300",
      @tone == "danger" && "text-rose-300"
    ]}>
      {@value}
    </div>
    <div :if={@hint} class="mt-1 text-xs text-slate-500">{@hint}</div>
    """
  end

  # -------------------------------------------------------------------------
  # Бейдж (роли, статусы)
  # -------------------------------------------------------------------------

  attr :tone, :string, default: "slate", doc: "slate | green | red | amber | indigo"
  attr :rest, :global, doc: "например, title для нативного tooltip"

  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium",
        @tone == "slate" && "bg-slate-800 text-slate-300",
        @tone == "green" && "bg-emerald-950 text-emerald-300 border border-emerald-900",
        @tone == "red" && "bg-rose-950 text-rose-300 border border-rose-900",
        @tone == "amber" && "bg-amber-950 text-amber-300 border border-amber-900",
        @tone == "indigo" && "bg-indigo-950 text-indigo-300 border border-indigo-900"
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  # -------------------------------------------------------------------------
  # Панель-карточка с заголовком
  # -------------------------------------------------------------------------

  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil
  attr :class, :string, default: nil

  slot :inner_block, required: true
  slot :actions

  def panel(assigns) do
    ~H"""
    <section class={["rounded-xl border border-slate-800 bg-slate-900/60", @class]}>
      <header
        :if={@title || @subtitle || @actions != []}
        class="flex items-center justify-between gap-4 border-b border-slate-800 px-5 py-3"
      >
        <div>
          <h2 :if={@title} class="font-medium text-slate-200">{@title}</h2>
          <p :if={@subtitle} class="mt-0.5 text-xs text-slate-500">{@subtitle}</p>
        </div>
        <div class="flex items-center gap-2">{render_slot(@actions)}</div>
      </header>
      <div class="px-5 py-4">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  # -------------------------------------------------------------------------
  # Кнопки (тёмные, контурные/опасные)
  # -------------------------------------------------------------------------

  attr :kind, :string, default: "default", doc: "default | primary | danger | ghost"
  attr :disabled, :boolean, default: false

  # дефолт "button": кнопка внутри <.form> без type сабмитит форму
  # (браузерный дефолт submit) — сабмит только явно type="submit"
  attr :type, :string, default: "button"

  attr :rest, :global,
    include: ~w(phx-click phx-value-id phx-value-role href navigate method confirm title)

  slot :inner_block, required: true

  def admin_button(assigns) do
    ~H"""
    <button
      type={@type}
      disabled={@disabled}
      class={[
        "inline-flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-sm font-medium transition-colors",
        "disabled:cursor-not-allowed disabled:opacity-40",
        @kind == "default" && "border border-slate-700 bg-slate-800 text-slate-200 hover:bg-slate-700",
        @kind == "primary" && "bg-indigo-600 text-white hover:bg-indigo-500",
        @kind == "danger" && "border border-rose-900 bg-rose-950 text-rose-300 hover:bg-rose-900",
        @kind == "ghost" && "text-slate-400 hover:text-slate-200 hover:bg-slate-800"
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  # -------------------------------------------------------------------------
  # Плотная таблица (с поддержкой LiveView streams)
  # -------------------------------------------------------------------------

  attr :id, :string, required: true
  attr :rows, :list, required: true, doc: "список строк или %LiveStream{}"
  attr :row_id, :any, default: nil, doc: "fn row -> DOM id (для streams обязателен)"
  attr :empty, :string, default: "Пусто"

  # table-fixed: ширины колонок задаются классами col[:class] и не зависят
  # от содержимого строк — не «съезжают» при перерисовке ячеек
  attr :fixed, :boolean, default: false
  attr :min_w, :string, default: nil, doc: "min-width таблицы при fixed (напр. \"760px\")"

  slot :col, required: true do
    attr :label, :string
    attr :class, :string
  end

  slot :action, doc: "кнопки действий в последней колонке (row доступен как @row)"

  def admin_table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    assigns =
      assign_new(assigns, :stream?, fn a -> is_struct(a.rows, Phoenix.LiveView.LiveStream) end)

    ~H"""
    <div class="overflow-x-auto rounded-xl border border-slate-800">
      <table
        style={@min_w && "min-width: #{@min_w}"}
        class={["w-full text-sm", @fixed && "table-fixed"]}
      >
        <thead>
          <tr class="border-b border-slate-800 bg-slate-900 text-left text-xs uppercase tracking-wider text-slate-500">
            <th :for={col <- @col} class={["px-4 py-2.5 font-medium", col[:class]]}>{col[:label]}</th>
            <th :if={@action != []} class="px-4 py-2.5 text-right font-medium">Действия</th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={@stream? && "stream"} class="divide-y divide-slate-800/70">
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            class="group transition-colors hover:bg-slate-800/50"
          >
            <td :for={col <- @col} class="px-4 py-2.5 text-slate-300">
              {render_slot(col, item(row, assigns))}
            </td>
            <td :if={@action != []} class="px-4 py-2.5 text-right">
              <div class="flex justify-end gap-2">{render_slot(@action, item(row, assigns))}</div>
            </td>
          </tr>
          <tr :if={@rows == []}>
            <td
              colspan={length(@col) + if(@action != [], do: 1, else: 0)}
              class="px-4 py-8 text-center text-sm text-slate-500"
            >
              {@empty}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # stream-строки приходят парами {dom_id, item}, обычные списки — элементами
  defp item({_id, item}, _assigns), do: item
  defp item(row, _assigns), do: row

  # -------------------------------------------------------------------------
  # Мелочи
  # -------------------------------------------------------------------------

  attr :dt, :any, default: nil, doc: "DateTime | NaiveDateTime | nil"

  def datetime(assigns) do
    ~H"""
    <span class="tabular-nums text-slate-400">{format_dt(@dt)}</span>
    """
  end

  defp format_dt(nil), do: "—"

  defp format_dt(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%d.%m.%Y %H:%M")
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%d.%m.%Y %H:%M UTC")
  defp format_dt(_), do: "—"
end
