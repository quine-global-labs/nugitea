defmodule Nugitea.Modules.Structs.Pull do
  @moduledoc """
  Pull Request struct for Gitea-like API endpoints.
  """

  defstruct [
    :number,
    :title,
    :body,
    :state,
    :user,
    :head,
    :base,
    :merged,
    :created_at
  ]

  @type t :: %__MODULE__{
          number: integer,
          title: String.t(),
          body: String.t(),
          state: String.t(),
          user: map,
          head: map,
          base: map,
          merged: boolean,
          created_at: String.t()
        }
end
