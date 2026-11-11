defmodule Nugitea.Auth.Directory do
  @moduledoc """
  Authentication based on the directory structure in accounts.json.
  Uses `Directory.resolve_repo/2` to find repo paths and `Directory.effective_role/3`
  to determine access.
  """

  @behaviour Nugitea.Auth

  alias Nugitea.Accounts.Directory
  alias Nugitea.Accounts.Store

  @impl true
  def allow_pull?(user, repo_path), do: role(user, repo_path) != nil

  @impl true
  def allow_push?(user, repo_path), do: role(user, repo_path) in [:write, :maintain, :admin]

  # The user's (nil = anonymous) role on the repo, or nil when it doesn't
  # exist, they can't see it, or accounts.json can't be read.
  defp role(user, repo_path) do
    with {:ok, dir} <- Store.load(Nugitea.Accounts.state_dir()),
         repo_id when repo_id != nil <- Directory.resolve_repo(dir, repo_path) do
      Directory.effective_role(dir, user, repo_id)
    else
      _ -> nil
    end
  end
end
