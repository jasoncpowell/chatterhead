defmodule Chatterhead.Accounts.Roster.Entry do
  @moduledoc """
  One row of the roster: a user, whether they are online right now, and — when
  offline — when they were last seen. `last_seen_at` is `nil` for a user who has
  never been online.
  """

  @type t :: %__MODULE__{
          id: integer(),
          name: String.t(),
          online?: boolean(),
          last_seen_at: DateTime.t() | nil
        }

  @enforce_keys [:id, :name]
  defstruct [:id, :name, :last_seen_at, online?: false]
end
