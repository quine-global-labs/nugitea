defmodule Nugitea.Accounts.Passwords do
  @moduledoc """
  Account passwords, for signing in to the web UI (`Nugitea.Router`'s
  `/-/session`). Git and the REST API don't take them: they take access
  tokens and SSH keys.

  Stored in passwords.json in the state dir, by account id, as
  `pbkdf2-sha256$<iterations>$<salt>$<hash>` (salt and hash in base64):
  PBKDF2-HMAC-SHA256 from OTP's own crypto, at OWASP's recommended 600,000
  iterations, which also makes each guess cost a few hundred milliseconds.
  """

  alias Nugitea.Accounts.JsonFile

  @name "passwords.json"
  @iterations 600_000
  @length 32

  @doc "Sets (or replaces) the account's password."
  def set(state_dir, user_id, password) when is_binary(password) and password != "" do
    salt = :crypto.strong_rand_bytes(16)
    hash = derive(password, salt, @iterations)

    entry =
      Enum.join(["pbkdf2-sha256", @iterations, Base.encode64(salt), Base.encode64(hash)], "$")

    JsonFile.update(state_dir, @name, &Map.put(&1, Integer.to_string(user_id), entry))
  end

  @doc """
  Whether `password` is the account's. False for an account without one, or
  no account (`nil`), after the same work as a real check, so the time taken
  doesn't tell which logins exist.
  """
  def verify(state_dir, user_id, password) when is_binary(password) do
    entry = user_id && JsonFile.load(state_dir, @name)[Integer.to_string(user_id)]

    case entry && String.split(entry, "$") do
      ["pbkdf2-sha256", iterations, salt, hash] ->
        with {iterations, ""} <- Integer.parse(iterations),
             {:ok, salt} <- Base.decode64(salt),
             {:ok, hash} <- Base.decode64(hash) do
          :crypto.hash_equals(derive(password, salt, iterations), hash)
        else
          _ -> false
        end

      _ ->
        derive(password, "nugitea-no-such-account", @iterations)
        false
    end
  end

  def verify(_state_dir, _user_id, _password), do: false

  @doc "A random password, for `nugitea user set-password`."
  def generate, do: :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)

  defp derive(password, salt, iterations),
    do: :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, @length)
end
