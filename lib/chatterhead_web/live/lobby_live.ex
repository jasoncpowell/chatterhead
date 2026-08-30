defmodule ChatterheadWeb.LobbyLive do
  @moduledoc """
  The landing page: the join form (for a visitor) or a link back to the room
  (for someone already joined), above a live list of every user and who is in
  the room right now.

  The lobby *observes* presence — it never tracks. It seeds `@roster` from a
  snapshot on mount, then folds the semantic `{:user_online, ...}` /
  `{:user_offline, ...}` events into it. It never sees a raw `presence_diff`.
  """
  use ChatterheadWeb, :live_view

  alias Chatterhead.Accounts
  alias Chatterhead.Accounts.Roster
  alias Chatterhead.Accounts.User
  alias ChatterheadWeb.Presence

  @impl true
  def mount(_params, _session, socket) do
    online =
      if connected?(socket) do
        # Subscribe *before* snapshotting: a join or leave in the gap would be
        # lost otherwise. A duplicated event is harmless — mark_online/2 and
        # mark_offline/2 are idempotent.
        Phoenix.PubSub.subscribe(Chatterhead.PubSub, Presence.events_topic())
        Presence.online_users()
      else
        %{}
      end

    {:ok,
     socket
     |> assign(:roster, Roster.build(Accounts.list_users(), online))
     |> assign(:form, to_form(Accounts.change_user(%User{})))}
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset = Accounts.change_user(%User{}, params)
    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  @impl true
  def handle_info({:user_online, user}, socket) do
    {:noreply, update(socket, :roster, &Roster.mark_online(&1, user))}
  end

  def handle_info({:user_offline, user}, socket) do
    {:noreply, update(socket, :roster, &Roster.mark_offline(&1, user))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto flex w-full max-w-md flex-1 flex-col gap-8 p-6">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight">Chatterhead</h1>
          <p class="text-sm text-base-content/60">One room. Pick a name and say hello.</p>
        </div>

        <.link
          :if={@current_scope}
          navigate={~p"/room"}
          class="rounded bg-primary px-4 py-2 text-center text-sm font-medium text-primary-content hover:opacity-90"
        >
          Back to the room &rarr;
        </.link>

        <.form
          :if={!@current_scope}
          for={@form}
          id="join-form"
          action={~p"/join"}
          phx-change="validate"
          class="flex flex-col gap-3"
        >
          <.input
            field={@form[:name]}
            type="text"
            label="Your name"
            autocomplete="off"
            maxlength={User.name_max()}
            required
          />
          <.button class="w-full">Join the chat</.button>
        </.form>

        <div>
          <h2 class="mb-1 text-xs font-semibold uppercase tracking-wide text-base-content/50">
            Everyone
          </h2>
          <.roster
            entries={Roster.entries(@roster)}
            counts={Roster.counts(@roster)}
            current_user_id={@current_scope && @current_scope.user.id}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end
end
