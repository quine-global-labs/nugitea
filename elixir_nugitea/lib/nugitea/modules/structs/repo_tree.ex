defmodule Nugitea.Modules.Structs.GitTreeResponse do
  @moduledoc """
  Represents the response structure for Git tree data.

  This module implements the GitTreeResponse structure used in Gitea's API
  for `GET /api/v1/repos/:owner/:repo/git/trees/:sha?recursive=true`.
  """

  defstruct [
    :sha,
    :url,
    :tree,
    :truncated
  ]

  @type t :: %__MODULE__{
          sha: String.t(),
          url: String.t(),
          tree: [
            %{
              path: String.t(),
              mode: String.t(),
              type: String.t(),
              sha: String.t(),
              size: integer | nil
            }
          ],
          truncated: boolean
        }

  @doc """
  Creates a new GitTreeResponse struct with the given parameters.
  """
  def new(sha, url, tree, truncated) do
    %__MODULE__{
      sha: sha,
      url: url,
      tree: tree,
      truncated: truncated
    }
  end
end
