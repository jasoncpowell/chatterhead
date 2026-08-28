defmodule Chatterhead.Accounts.Scope do
  @moduledoc """
  The identity carried through a request and a LiveView socket.

  Mirrors the `Scope` struct `phx.gen.auth` generates in Phoenix 1.8: one
  obvious place for identity (and any future authorization) to live, rather
  than threading a bare `%User{}` through every context call.
  """

  alias Chatterhead.Accounts.User

  @type t :: %__MODULE__{user: User.t()}

  defstruct [:user]

  @doc """
  Builds a scope for a joined user, or `nil` for an anonymous visitor.
  """
  @spec for_user(User.t() | nil) :: t() | nil
  def for_user(%User{} = user), do: %__MODULE__{user: user}
  def for_user(nil), do: nil
end
