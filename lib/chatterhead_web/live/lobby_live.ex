defmodule ChatterheadWeb.LobbyLive do
  @moduledoc """
  The landing page: the join form (for a visitor) or a link back to the room
  (for someone already joined), above the full list of users.

  The list is a plain assign here, all-offline. CHAT-8 subscribes to presence
  events and makes it live.
  """
  use ChatterheadWeb, :live_view

  alias Chatterhead.Accounts
  alias Chatterhead.Accounts.Roster
  alias Chatterhead.Accounts.User

  @impl true
  def mount(_params, _session, socket) do
    roster = Roster.build(Accounts.list_users(), %{})

    {:ok,
     socket
     |> assign(:roster, roster)
     |> assign(:form, to_form(Accounts.change_user(%User{})))}
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset = Accounts.change_user(%User{}, params)
    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
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
            maxlength="24"
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
