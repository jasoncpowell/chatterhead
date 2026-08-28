defmodule Chatterhead.Accounts.User do
  @moduledoc """
  A participant, identified only by a claimed name.

  Names are unique case-insensitively (the `name` column is `citext`), trimmed,
  internal whitespace collapsed, and bounded to 24 characters.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @name_max 24

  schema "users" do
    field :name, :string
    field :last_seen_at, :utc_datetime

    # has_many :messages is added in CHAT-3, once Chatterhead.Chat.Message exists.

    timestamps(type: :utc_datetime)
  end

  @doc """
  Validates a claimed name.

  `last_seen_at` is written programmatically by the presence client (CHAT-4)
  and is deliberately not castable here.
  """
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:name])
    |> update_change(:name, &normalize_name/1)
    |> validate_required(:name)
    |> validate_length(:name, min: 1, max: @name_max)
    |> validate_format(:name, ~r/^[^\p{C}]+$/u, message: "must not contain control characters")
    |> unique_constraint(:name)
  end

  defp normalize_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.replace(~r/\s+/u, " ")
  end

  defp normalize_name(name), do: name
end
