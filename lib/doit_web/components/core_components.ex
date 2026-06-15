defmodule DoItWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: DoItWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-hook="AutoDismissFlash"
      data-kind={@kind}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="toast toast-top toast-end z-50"
      {@rest}
    >
      <div class={[
        "alert w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap",
        @kind == :info && "alert-info",
        @kind == :error && "alert-error"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button type="button" class="group self-start cursor-pointer" aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :any
  attr :variant, :string, values: ~w(primary)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    # The app's solid-emerald CTA (not daisyUI's btn-primary/btn-soft, whose
    # soft tint read as dark-on-dark in both themes). One look, both modes.
    assigns =
      assign_new(assigns, :class, fn ->
        "inline-flex items-center justify-center gap-1 px-3 py-1.5 rounded text-sm font-medium bg-emerald-600 text-white hover:bg-emerald-700 disabled:opacity-60 cursor-pointer"
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://hexdocs.pm/phoenix_html/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || "w-full select", @errors != [] && (@error_class || "select-error")]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || "w-full textarea",
            @errors != [] && (@error_class || "textarea-error")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "password"} = assigns) do
    assigns = assign_new(assigns, :id, fn -> nil end)

    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <div class="relative">
          <input
            type="password"
            name={@name}
            id={@id}
            value={Phoenix.HTML.Form.normalize_value("password", @value)}
            class={[
              @class || "w-full input pr-10",
              @errors != [] && (@error_class || "input-error")
            ]}
            {@rest}
          />
          <button
            type="button"
            id={"#{@id}-toggle"}
            phx-hook="PasswordToggle"
            data-input-id={@id}
            aria-label="Show password"
            tabindex="-1"
            class="absolute inset-y-0 right-0 flex items-center pr-3 text-zinc-500 hover:text-zinc-800 dark:text-zinc-400 dark:hover:text-zinc-100"
          >
            <.icon name="hero-eye" class="w-5 h-5 password-eye" />
            <.icon name="hero-eye-slash" class="w-5 h-5 password-eye-slash hidden" />
          </button>
        </div>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full input",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table table-zebra">
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
          <th :if={@action != []}>
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={@row_click && "hover:cursor-pointer"}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  # Data-driven keyboard-shortcut list — add a key here and it shows in the help
  # overlay automatically (m02.03 .07.2.1).
  @shortcuts [
    {"Enter", "Open the selected task's details — or reopen the last task; again to close"},
    {"Space", "Expand / collapse the selected task"},
    {"↑ ↓", "Select the previous / next task"},
    {"← →", "Select the parent / first child"},
    {"Alt + ↑ ↓ ← →", "Reorder, or dedent / indent, the selected task"},
    {"N", "New subtask of the selected task"},
    {"S", "New sibling of the selected task"},
    {"P / A", "Step priority / assignee (Shift to step back)"},
    {"Alt + P / A", "Focus the priority / assignee field"},
    {"Del", "Delete the selected task (with confirmation)"},
    {"?", "Show this help"}
  ]

  @doc """
  The keyboard-shortcuts help overlay: a hidden modal listing every shortcut.
  Opened by `?` or a "⌨ shortcuts" affordance, closed by Escape / backdrop / X.
  Toggled entirely client-side via the `ShortcutsOverlay` hook; data-driven from
  the `@shortcuts` list above.
  """
  def shortcuts_overlay(assigns) do
    assigns = assign(assigns, :shortcuts, @shortcuts)

    ~H"""
    <div
      id="shortcuts-overlay"
      phx-hook="ShortcutsOverlay"
      class="hidden fixed inset-0 z-50 flex items-center justify-center p-4"
    >
      <div class="absolute inset-0 bg-black/50" data-close aria-hidden="true"></div>
      <div class="relative z-10 w-full max-w-md max-h-[80vh] overflow-y-auto rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 p-5 shadow-xl">
        <div class="flex items-center justify-between mb-3">
          <h2 class="font-medium text-zinc-800 dark:text-zinc-100">Keyboard shortcuts</h2>
          <button
            type="button"
            data-close
            aria-label="Close"
            class="inline-flex items-center justify-center w-7 h-7 rounded bg-red-500/30 hover:bg-red-500/50 text-white"
          >
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </div>
        <dl class="space-y-2">
          <div :for={{keys, label} <- @shortcuts} class="flex items-baseline justify-between gap-4">
            <dt class="flex-none">
              <kbd class="px-1.5 py-0.5 rounded border border-zinc-300 dark:border-zinc-600 bg-zinc-50 dark:bg-zinc-800 text-xs font-medium text-zinc-700 dark:text-zinc-200">
                {keys}
              </kbd>
            </dt>
            <dd class="text-sm text-zinc-600 dark:text-zinc-300 text-right">{label}</dd>
          </div>
        </dl>
      </div>
    </div>
    """
  end

  @doc """
  A small info icon that reveals an explanatory popover on click and
  light-dismisses on click-away. Reusable for "explain a UI rule" moments —
  why a control is disabled, how a value is derived.

  ## Examples

      <.info_hint id="calc-hint" label="How do the methods differ?">
        Leaf average: every leaf counts equally, however deep it sits.
      </.info_hint>
  """
  attr :id, :string, required: true
  attr :label, :string, default: "More information"
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def info_hint(assigns) do
    ~H"""
    <span class="inline-flex items-center">
      <%!-- Native Popover API: the panel renders in the browser's top layer,
           escaping any overflow-y-auto ancestor (it used to get clipped and
           force scrollbars inside the pane). Light dismiss is built in; the
           Popover hook places it next to the trigger, clamped to the
           viewport. --%>
      <button
        type="button"
        aria-label={@label}
        popovertarget={"#{@id}-pop"}
        class={["text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-200", @class]}
      >
        <.icon name="hero-information-circle" class="w-4 h-4" />
      </button>
      <div
        id={"#{@id}-pop"}
        popover
        phx-hook="Popover"
        role="tooltip"
        class="w-64 rounded-md border border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-800 p-3 text-xs font-normal not-italic text-zinc-600 dark:text-zinc-300 shadow-lg"
      >
        {render_slot(@inner_block)}
      </div>
    </span>
    """
  end

  @doc """
  Botanical icon set (Lucide source). Tree on Lists, branch on parent tasks,
  leaf on leaf tasks, grove on Initiatives. Used by M02's row layout to
  carry the visual metaphor reserved in `docs/ProductSpec.md` § Visual
  Metaphor.

      <.botanical_icon kind={:grove} class="w-5 h-5" />
      <.botanical_icon kind={:tree} />
      <.botanical_icon kind={:branch} />
      <.botanical_icon kind={:leaf} />
  """
  attr :kind, :atom, values: [:grove, :tree, :branch, :leaf], required: true
  attr :class, :string, default: "w-4 h-4"

  def botanical_icon(%{kind: :grove} = assigns) do
    ~H"""
    <svg
      class={@class}
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <path d="M10 10v.2A3 3 0 0 1 8.9 16H5a3 3 0 0 1-1-5.8V10a3 3 0 0 1 6 0Z" />
      <path d="M7 16v6" />
      <path d="M13 19v3" />
      <path d="M12 19h8.3a1 1 0 0 0 .7-1.7L18 14h.3a1 1 0 0 0 .7-1.7L16 9h.2a1 1 0 0 0 .8-1.7L13 3l-1.4 1.5" />
    </svg>
    """
  end

  def botanical_icon(%{kind: :tree} = assigns) do
    ~H"""
    <svg
      class={@class}
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <path d="M8 19a4 4 0 0 1-2.24-7.32A3.5 3.5 0 0 1 9 6.03V6a3 3 0 1 1 6 0v.04a3.5 3.5 0 0 1 3.24 5.65A4 4 0 0 1 16 19Z" />
      <path d="M12 19v3" />
    </svg>
    """
  end

  def botanical_icon(%{kind: :branch} = assigns) do
    ~H"""
    <svg
      class={@class}
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.75"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <path d="M3 21 C 8 17, 13 12, 21 4" />
      <path d="M9 14 L 6 10.5" />
      <path d="M15 8 L 12 4.5" />
      <g class="text-emerald-600 dark:text-emerald-400" fill="currentColor" stroke="none">
        <ellipse cx="5.4" cy="10" rx="1.4" ry="2.4" transform="rotate(-35 5.4 10)" />
        <ellipse cx="11.4" cy="4" rx="1.4" ry="2.4" transform="rotate(-35 11.4 4)" />
        <ellipse cx="20.6" cy="3.4" rx="1.4" ry="2.4" transform="rotate(-35 20.6 3.4)" />
      </g>
    </svg>
    """
  end

  def botanical_icon(%{kind: :leaf} = assigns) do
    ~H"""
    <svg
      class={@class}
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <path d="M11 20A7 7 0 0 1 9.8 6.1C15.5 5 17 4.48 19 2c1 2 2 4.18 2 8 0 5.5-4.78 10-10 10Z" />
      <path d="M2 21c0-3 1.85-5.36 5.08-6C9.5 14.52 12 13 13 12" />
    </svg>
    """
  end

  @doc """
  Tailwind classes for a role badge (owner / editor / viewer), shared by the
  Initiatives index card and the ultrawide left-rail entry so the colors stay
  in one place.
  """
  def role_badge_class("owner"),
    do: "bg-emerald-100 text-emerald-800 dark:bg-emerald-900/40 dark:text-emerald-300"

  def role_badge_class("editor"),
    do: "bg-blue-100 text-blue-800 dark:bg-blue-900/40 dark:text-blue-300"

  def role_badge_class(_),
    do: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300"

  @doc """
  Generated initials avatar (m02.04 §1.11) — a colored disc with the user's
  initials. No uploads in M02: the color is derived deterministically from
  the user id, so a user looks the same everywhere they appear (member list,
  assignee chip, activity log, presence).

  Size via `class` (the default suits inline text rows). `avatar_bg/1` and
  `initials/1` are public so optimistic-echo call sites can mirror the same
  derivation into data attributes.
  """
  attr :user, :map, required: true
  attr :online, :boolean, default: false, doc: "bright-green dot: user has this initiative open"
  attr :class, :string, default: "w-5 h-5 text-[10px]"
  attr :rest, :global

  def avatar(assigns) do
    ~H"""
    <span
      class={[
        "avatar-emboss relative inline-flex flex-none items-center justify-center rounded-full font-semibold select-none",
        @class
      ]}
      style={"background-image: #{avatar_bg(@user)}; color: #{avatar_fg(@user)}"}
      title={if @online, do: "#{@user.name} (here now)", else: @user.name}
      {@rest}
    >
      {initials(@user)}
      <%!-- em-sized so it scales with the avatar, floored at 6px so it pops. --%>
      <span
        :if={@online}
        data-online-dot
        class="absolute -bottom-px -right-px w-[0.55em] min-w-1.5 h-[0.55em] min-h-1.5 rounded-full bg-green-400 ring-1 ring-white dark:ring-zinc-900"
        aria-hidden="true"
      >
      </span>
    </span>
    """
  end

  # Four deterministic, independently-cycling channels: dark gradient start,
  # dark gradient end, gradient angle, pale text tint. Hex values (not
  # Tailwind classes) so client-side echoes copy them straight into inline
  # styles. Palette sizes are pairwise coprime (10 / 9 / 7) indexed by
  # rem(id, size), and the angle steps by 137° (coprime to 360 — the golden
  # angle), so sequential user ids walk thousands of distinct looks before
  # any repeat — and any pale tint stays legible on any dark gradient.
  @avatar_bgs ~w(#059669 #0284c7 #7c3aed #e11d48 #d97706 #4f46e5 #0d9488 #c026d3 #ea580c #65a30d)
  @avatar_grads ~w(#2563eb #9333ea #dc2626 #ca8a04 #0891b2 #db2777 #16a34a #4338ca #b45309)
  @avatar_fgs ~w(#a7f3d0 #bae6fd #ddd6fe #fecdd3 #fde68a #f5d0fe #d9f99d)

  def avatar_bg(%{id: id}) do
    "linear-gradient(#{rem(id * 137, 360)}deg, #{pick(@avatar_bgs, id)}, #{pick(@avatar_grads, id)})"
  end

  def avatar_fg(%{id: id}), do: pick(@avatar_fgs, id)

  defp pick(palette, id), do: Enum.at(palette, rem(id, length(palette)))

  # Generational/honorific suffixes ignored when picking the surname initial
  # ("Alvin Cubbins III" → AC, "Doris Fitzgerald Jr." → DF). Bare "i" stays
  # off the list — too likely to be a real trailing initial.
  @name_suffixes ~w(jr jnr sr snr esq ii iii iv v vi vii viii ix x)

  def initials(%{name: name} = user) when is_binary(name) do
    words = name |> String.split() |> drop_trailing_suffixes()

    case Enum.map(words, &String.first/1) do
      [] -> initials_from_username(user)
      [first] -> String.upcase(first)
      [first | rest] -> String.upcase(first <> List.last(rest))
    end
  end

  def initials(user), do: initials_from_username(user)

  defp drop_trailing_suffixes([_ | _] = words) do
    normalized = words |> List.last() |> String.trim_trailing(".") |> String.downcase()

    if normalized in @name_suffixes and length(words) > 1 do
      words |> List.delete_at(-1) |> drop_trailing_suffixes()
    else
      words
    end
  end

  defp drop_trailing_suffixes(words), do: words

  defp initials_from_username(%{username: username}) when is_binary(username),
    do: username |> String.slice(0, 2) |> String.upcase()

  defp initials_from_username(_), do: "?"

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(DoItWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(DoItWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
