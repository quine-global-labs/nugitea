defmodule Nugitea.Accounts.Tokens do
  @moduledoc """
  Access tokens for Nugitea accounts.

  Tokens are stored as SHA-256 hashes in the `tokens.json` file in the state directory,
  mapped to user IDs. The original token values are not stored, only their hashes.
  """

  @doc """
  Creates a new access token for a user and returns the token value.
  """
  def create_token(state_dir, user_id) do
    # Generate a random token (we'll use a library function for this)
    token = :crypto.strong_rand_bytes(32) |> Base.encode64()

    # Create SHA-256 hash of the token 
    hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

    # Load existing tokens
    user_map = load_tokens(state_dir)

    # Add the new token mapping
    updated_user_map =
      Map.put(user_map, user_id, MapSet.put(user_map[user_id] || MapSet.new(), hash))

    # Save back to disk
    save_tokens(state_dir, updated_user_map)

    token
  end

  @doc """
  Looks up a token and returns the associated user ID if valid.
  """
  def lookup_token(state_dir, token_value) do
    # Create SHA-256 hash of the token value
    hash = :crypto.hash(:sha256, token_value) |> Base.encode16(case: :lower)

    # Load existing tokens  
    user_map = load_tokens(state_dir)

    # Find which user this token belongs to
    case Enum.find(user_map, fn {_user_id, token_set} -> hash in token_set end) do
      nil -> nil
      {user_id, _token_set} -> user_id
    end
  end

  @doc """
  Lists all tokens for a user.
  """
  def list_user_tokens(state_dir, user_id) do
    user_map = load_tokens(state_dir)

    user_map[user_id] ||
      MapSet.new()
      |> Enum.map(fn hash ->
        # We can't get the actual token back since we only store hashes
        # but for testing purposes we could return "token_hash:#{hash}"
        hash
      end)
  end

  @doc """
  Removes a token by its value.
  """
  def delete_token(state_dir, token_value) do
    # Create SHA-256 hash of the token value
    hash = :crypto.hash(:sha256, token_value) |> Base.encode16(case: :lower)

    # Load existing tokens
    user_map = load_tokens(state_dir)

    # Find which user this token belongs to, if any
    case Enum.find(user_map, fn {_user_id, token_set} -> hash in token_set end) do
      nil ->
        # Token doesn't exist, nothing to do
        :ok

      {user_id, _token_set} ->
        # Remove from user's token set
        user_token_set = Map.get(user_map, user_id, MapSet.new())
        updated_user_token_set = MapSet.delete(user_token_set, hash)
        updated_user_map = Map.put(user_map, user_id, updated_user_token_set)

        # Save back to disk
        save_tokens(state_dir, updated_user_map)
    end
  end

  # Internal helper functions
  defp load_tokens(state_dir) do
    tokens_file = Path.join(state_dir, "tokens.json")

    case File.read(tokens_file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"user_map" => user_map_json}} ->
            # Convert string-based keys back to proper types
            Map.new(user_map_json, fn {k, v} ->
              {String.to_integer(k), MapSet.new(v)}
            end)

          _ ->
            # Invalid JSON, return empty map  
            %{}
        end

      _ ->
        # File doesn't exist or can't be read, return empty map
        %{}
    end
  end

  defp save_tokens(state_dir, user_map) do
    tokens_file = Path.join(state_dir, "tokens.json")

    encoded_data = %{
      "user_map" =>
        Map.new(user_map, fn {k, v} ->
          {Integer.to_string(k), MapSet.to_list(v)}
        end)
    }

    File.mkdir_p!(state_dir)
    File.write!(tokens_file, Jason.encode!(encoded_data, pretty: true))
  end
end
