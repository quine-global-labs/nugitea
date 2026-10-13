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
  def allow_pull?(user, repo_path) do
    # Load the directory from accounts.json
    case Store.load(Nugitea.Accounts.state_dir()) do
      {:ok, dir} ->
        # Resolve the repo path to find repository ID
        case Directory.resolve_repo(dir, repo_path) do
          nil ->
            false

          repo_id ->
            # Check if the user has an effective role
            case Directory.effective_role(dir, user, repo_id) do
              nil -> false
              _ -> true
            end
        end

      {:error, _} ->
        false
    end
  end

  @impl true
  def allow_push?(user, repo_path) do
    # Load the directory from accounts.json
    case Store.load(Nugitea.Accounts.state_dir()) do
      {:ok, dir} ->
        # Resolve the repo path to find repository ID
        case Directory.resolve_repo(dir, repo_path) do
          nil ->
            false

          repo_id ->
            # Check if the user has a role of :write or above
            case Directory.effective_role(dir, user, repo_id) do
              nil -> false
              role when role in [:read, :triage] -> false
              _ -> true
            end
        end

      {:error, _} ->
        false
    end
  end
end
