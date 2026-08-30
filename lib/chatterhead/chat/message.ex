defmodule Chatterhead.Chat.Message do
  @moduledoc """
  One message in the single global room.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Chatterhead.Accounts.User

  @body_max 2000

  @type t :: %__MODULE__{}

  schema "messages" do
    field :body, :string

    belongs_to :user, User

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The maximum body length, enforced by `changeset/2`."
  @spec body_max() :: pos_integer()
  def body_max, do: @body_max

  @doc """
  Validates a message body.

  `user_id` is set on the struct by `Chatterhead.Chat.send_message/2` and is
  deliberately not castable here.
  """
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:body])
    |> update_change(:body, &trim_body/1)
    |> validate_required(:body)
    |> validate_length(:body, max: @body_max)
    |> assoc_constraint(:user)
  end

  defp trim_body(body) when is_binary(body), do: String.trim(body)
  defp trim_body(body), do: body
end
