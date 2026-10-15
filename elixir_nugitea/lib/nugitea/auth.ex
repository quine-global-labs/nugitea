defmodule Nugitea.Auth do
  @moduledoc """
  The access-control seam: the HTTP, SSH and GraphQL front ends ask this
  rather than deciding themselves. The implementation is the `:authorizer`
  app setting; the default, `Nugitea.Auth.Directory`, follows repo
  visibility and grants in accounts.json. `AllowAll` permits everything.
  """

  @callback allow_pull?(user :: integer | nil, repo :: String.t()) :: boolean
  @callback allow_push?(user :: integer | nil, repo :: String.t()) :: boolean

  def allow?("upload-pack", user, repo), do: impl().allow_pull?(user, repo)
  def allow?("receive-pack", user, repo), do: impl().allow_push?(user, repo)
  def allow_pull?(repo), do: impl().allow_pull?(nil, repo)

  defp impl, do: Application.get_env(:nugitea, :authorizer, Nugitea.Auth.Directory)
end

defmodule Nugitea.Auth.AllowAll do
  @moduledoc "Permits every pull and push."
  @behaviour Nugitea.Auth

  @impl true
  def allow_pull?(_user, _repo), do: true

  @impl true
  def allow_push?(_user, _repo), do: true
end
