defmodule Nugitea.Webhooks.Store do
  @moduledoc """
  Persists webhook information as webhooks.json in the app tier's state dir.
  """

  def load(state_dir) do
    case File.read(file(state_dir)) do
      {:ok, json} -> {:ok, decode(json)}
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, "read webhooks.json: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Applies `fun` to the current webhook list and saves the result, unless it fails.
  """
  def update(state_dir, fun) do
    path = file(state_dir)

    :global.trans({{__MODULE__, path}, self()}, fn ->
      with {:ok, webhooks} <- load(state_dir),
           new_webhooks = fun.(webhooks) do
        File.mkdir_p!(state_dir)
        File.write!(path <> ".tmp", encode(new_webhooks))
        File.rename!(path <> ".tmp", path)
        {:ok, new_webhooks}
      end
    end)
  end

  defp file(state_dir), do: Path.join(state_dir, "webhooks.json")

  # ---- JSON ----------------------------------------------------------

  def encode(webhooks) do
    Jason.encode_to_iodata!(
      Enum.map(webhooks, fn {repo, webhook} ->
        %{
          repo: repo,
          url: webhook.url,
          secret: webhook.secret
        }
      end),
      pretty: true
    )
  end

  def decode(json) do
    json
    |> Jason.decode!()
    |> Enum.into(%{}, fn webhook ->
      repo = webhook["repo"]

      data = %{
        url: webhook["url"],
        secret: webhook["secret"]
      }

      {repo, data}
    end)
  end
end
