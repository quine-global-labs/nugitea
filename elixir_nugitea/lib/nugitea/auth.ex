defmodule Nugitea.Auth do
  @moduledoc """
  The access-control seam. Nothing logs in yet, so the only implementation
  is `AllowAll`, but the HTTP, SSH and GraphQL front ends ask this rather
  than deciding themselves, so real auth can be added without touching them.
  The implementation is the `:authorizer` app setting.
  """

  @callback allow_pull?(user :: integer | nil, repo :: String.t()) :: boolean
  @callback allow_push?(user :: integer | nil, repo :: String.t()) :: boolean

  def allow?("upload-pack", repo), do: impl().allow_pull?(nil, repo)
  def allow?("receive-pack", repo), do: impl().allow_push?(nil, repo)
  def allow_pull?(repo), do: impl().allow_pull?(nil, repo)

  defp impl, do: Application.get_env(:nugitea, :authorizer, Nugitea.Auth.AllowAll)
end

defmodule Nugitea.Auth.AllowAll do
  @moduledoc "Permits every pull and push. The default."
  @behaviour Nugitea.Auth

  @impl true
  def allow_pull?(_user, _repo), do: true

  @impl true
  def allow_push?(_user, _repo), do: true
end
