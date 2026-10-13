defmodule Nugitea.Modules.Structs.GitBlobResponse do
  @moduledoc """
  Represents the response structure for Git blob data.

  This module implements the GitBlobResponse structure used in Gitea's API
  for `GET .../git/blobs/:sha`.
  """

  defstruct [
    :sha,
    :size,
    :encoding,
    :content
  ]

  @type t :: %__MODULE__{
          sha: String.t(),
          size: integer,
          encoding: String.t(),
          content: String.t()
        }

  @doc """
  Creates a new GitBlobResponse struct with the given parameters.
  """
  def new(sha, size, content) do
    %__MODULE__{
      sha: sha,
      size: size,
      encoding: "base64",
      content: content
    }
  end
end
