defmodule ChatterheadWeb.ChatComponents do
  @moduledoc """
  Function components shared by the lobby and the room: the status dot, the
  roster, a message row, and the relative "last seen" label.

  Built on the shipped `core_components.ex` and the daisyUI theme tokens, not a
  from-scratch design system.
  """
  use Phoenix.Component

  @doc """
  A small filled (online) or hollow (offline) status indicator with an
  accessible label.
  """
  attr :online?, :boolean, required: true

  def status_dot(assigns) do
    ~H"""
    <span
      class={[
        "inline-block size-2 shrink-0 rounded-full",
        if(@online?, do: "bg-success", else: "border border-base-content/40")
      ]}
      role="img"
      aria-label={if(@online?, do: "online", else: "offline")}
    />
    """
  end

  @doc """
  The roster: an "Online (n)" section above an "Offline (n)" section. `entries`
  is the sorted list from `Chatterhead.Accounts.Roster.entries/1`.
  """
  attr :entries, :list, required: true
  attr :counts, :map, required: true
  attr :current_user_id, :any, default: nil

  def roster(assigns) do
    {online, offline} = Enum.split_with(assigns.entries, & &1.online?)
    assigns = assign(assigns, online: online, offline: offline)

    ~H"""
    <div id="roster" class="flex flex-col gap-5 overflow-y-auto p-4">
      <.roster_group
        title="Online"
        count={@counts.online}
        entries={@online}
        current_user_id={@current_user_id}
      />
      <.roster_group
        title="Offline"
        count={@counts.offline}
        entries={@offline}
        current_user_id={@current_user_id}
      />
    </div>
    """
  end

  attr :title, :string, required: true
  attr :count, :integer, required: true
  attr :entries, :list, required: true
  attr :current_user_id, :any, required: true

  defp roster_group(assigns) do
    ~H"""
    <div>
      <h3 class="mb-2 text-xs font-semibold uppercase tracking-wide text-base-content/50">
        {@title} ({@count})
      </h3>
      <ul class="flex flex-col">
        <li
          :for={entry <- @entries}
          id={"roster-user-#{entry.id}"}
          data-online={to_string(entry.online?)}
          class="flex items-center gap-2 rounded px-2 py-1 text-sm"
        >
          <.status_dot online?={entry.online?} />
          <span class="truncate">
            {entry.name}<span
              :if={entry.id == @current_user_id}
              class="text-base-content/50"
            >&nbsp;(you)</span>
          </span>
          <span :if={not entry.online?} class="ml-auto shrink-0 text-xs text-base-content/40">
            {last_seen_label(entry.last_seen_at)}
          </span>
        </li>
      </ul>
    </div>
    """
  end

  @doc """
  One message row: initials avatar, author, an absolute `HH:MM` timestamp (full
  timestamp in the `title`), and the body. The current user's own rows get a
  subtle tint. The body is rendered by HEEx, which escapes it.

  The timestamp is server-rendered in UTC, then swapped to the viewer's local
  time by the `.LocalTime` hook below -- the server has no notion of the
  browser's time zone. `phx-update="ignore"` keeps LiveView from reverting the
  hook's DOM write on a future patch (AGENTS.md: any hook that manages its own
  DOM needs it); a stream item's timestamp never changes after insert, so
  `mounted/0` alone is enough, with no `updated/0` to keep in sync.
  """
  attr :message, :map, required: true
  attr :current_user_id, :any, default: nil

  def message(assigns) do
    ~H"""
    <div class={[
      "flex gap-3 px-2 py-1.5",
      @message.user_id == @current_user_id && "rounded bg-base-200/60"
    ]}>
      <.avatar name={@message.user.name} />
      <div class="min-w-0 flex-1">
        <div class="flex items-baseline gap-2">
          <span class="text-sm font-medium">{@message.user.name}</span>
          <time
            id={"message-time-#{@message.id}"}
            phx-hook=".LocalTime"
            phx-update="ignore"
            datetime={DateTime.to_iso8601(@message.inserted_at)}
            title={Calendar.strftime(@message.inserted_at, "%Y-%m-%d %H:%M:%S UTC")}
            class="text-xs text-base-content/40"
          >
            {Calendar.strftime(@message.inserted_at, "%H:%M")}
          </time>
        </div>
        <p class="whitespace-pre-wrap break-words text-sm">{@message.body}</p>
      </div>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalTime">
      export default {
        mounted() {
          const date = new Date(this.el.getAttribute("datetime"))
          if (!Number.isNaN(date.getTime())) {
            this.el.textContent = date.toLocaleTimeString([], {hour: "2-digit", minute: "2-digit"})
          }
        }
      }
    </script>
    """
  end

  attr :name, :string, required: true

  defp avatar(assigns) do
    assigns = assign(assigns, :initials, initials(assigns.name))

    ~H"""
    <span
      class="flex size-8 shrink-0 items-center justify-center rounded-full bg-base-300 text-xs font-medium"
      aria-hidden="true"
    >
      {@initials}
    </span>
    """
  end

  @doc """
  A relative label for when a user was last online. `nil` — a user who has never
  connected — reads "Never joined".
  """
  @spec last_seen_label(DateTime.t() | nil) :: String.t()
  def last_seen_label(nil), do: "Never joined"

  def last_seen_label(%DateTime{} = at) do
    seconds = DateTime.diff(DateTime.utc_now(), at, :second)

    cond do
      seconds < 60 -> "just now"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      seconds < 172_800 -> "yesterday"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp initials(name) do
    name
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
  end
end
