defmodule Nugitea.Accounts.Sessions do
  @moduledoc """
  Web UI sign-in sessions: a random token in a cookie (`Nugitea.Router`),
  stored in sessions.json in the state dir only as its SHA-256 hash, with
  the account and an expiry. A session lasts 30 days from sign-in; signing
  out deletes it.
  """

  alias Nugitea.Accounts.JsonFile

  @name "sessions.json"
  @ttl 30 * 24 * 3600

  @doc "How long a session lasts, in seconds (also the cookie's max-age)."
  def ttl, do: @ttl

  @doc "Starts a session for the account; returns its token. Drops expired ones."
  def create(state_dir, user_id) do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    now = now()

    JsonFile.update(state_dir, @name, fn sessions ->
      sessions
      |> Map.reject(fn {_, s} -> s["expires"] <= now end)
      |> Map.put(hash(token), %{"user" => user_id, "expires" => now + @ttl})
    end)

    token
  end

  @doc "The account the token's session belongs to, or nil if none or expired."
  def lookup(state_dir, token) when is_binary(token) do
    case JsonFile.load(state_dir, @name)[hash(token)] do
      %{"user" => user, "expires" => expires} when is_integer(user) ->
        if expires > now(), do: user

      _ ->
        nil
    end
  end

  def lookup(_state_dir, _token), do: nil

  @doc "Ends the token's session, if there is one."
  def delete(state_dir, token) when is_binary(token),
    do: JsonFile.update(state_dir, @name, &Map.delete(&1, hash(token)))

  def delete(_state_dir, _token), do: :ok

  defp hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  defp now, do: System.system_time(:second)
end
