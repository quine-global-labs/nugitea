defmodule Nugitea.Accounts.JsonFile do
  @moduledoc """
  A JSON object in the state dir, for the small secret stores
  (`Nugitea.Accounts.Passwords`, `Nugitea.Accounts.Sessions`): read whole,
  updated under a lock held across every connected node, written to a temp
  file and renamed into place, readable by its owner only.
  """

  @doc "The file's object, or `%{}` when it's missing or unreadable."
  def load(state_dir, name) do
    with {:ok, json} <- File.read(Path.join(state_dir, name)),
         {:ok, %{} = map} <- Jason.decode(json) do
      map
    else
      _ -> %{}
    end
  end

  @doc """
  Replaces the object with `fun.(object)`, or, when `fun` returns
  `{object, value}`, with `object`, returning `value`. Returns `:ok` or the
  value.
  """
  def update(state_dir, name, fun) do
    path = Path.join(state_dir, name)

    :global.trans({{__MODULE__, path}, self()}, fn ->
      {map, result} =
        case fun.(load(state_dir, name)) do
          {%{} = map, value} -> {map, value}
          %{} = map -> {map, :ok}
        end

      File.mkdir_p!(state_dir)
      tmp = path <> ".tmp"
      File.write!(tmp, Jason.encode!(map, pretty: true))
      File.chmod!(tmp, 0o600)
      File.rename!(tmp, path)
      result
    end)
  end
end
