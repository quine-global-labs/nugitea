defmodule Nugitea.Mirror do
  @moduledoc """
  Pull and push mirrors: periodically `git fetch --prune --tags mirror`
  (pull) or `git push --mirror -f mirror` (push), against a remote set up
  with `git remote add --mirror=fetch|push`, as Gitea's
  services/mirror/mirror_{pull,push}.go do. Runs on the app tier; git runs
  on the storage tier. Each repo has at most one mirror per direction.

  Configured mirrors live in mirrors.json in the state dir (`Store`), and
  `Scheduler` syncs the ones that are due.
  """

  alias Nugitea.Storage.Client

  @remote "mirror"

  def add_pull(repo, url, interval_seconds), do: configure(repo, url, interval_seconds, :pull)
  def add_push(repo, url, interval_seconds), do: configure(repo, url, interval_seconds, :push)

  defp configure(repo, url, interval_seconds, direction) do
    if Client.exists?(repo) do
      # Fine if there was no remote yet.
      Client.run_git(repo, ["remote", "remove", @remote])

      with :ok <-
             Client.run_git(repo, [
               "remote",
               "add",
               "--mirror=#{direction_flag(direction)}",
               @remote,
               url
             ]) do
        __MODULE__.Store.add(%{
          repo: repo,
          remote_url: url,
          direction: direction,
          interval_seconds: interval_seconds,
          last_sync_unix: 0
        })
      end
    else
      {:error, "repo #{inspect(repo)} does not exist"}
    end
  end

  defp direction_flag(:pull), do: "fetch"
  defp direction_flag(:push), do: "push"

  @doc "Runs one sync now."
  def sync(%{direction: :pull, repo: repo}),
    do: Client.run_git(repo, ["fetch", "--prune", "--tags", @remote])

  def sync(%{direction: :push, repo: repo}),
    do: Client.run_git(repo, ["push", "--mirror", "-f", @remote])
end

defmodule Nugitea.Mirror.Store do
  @moduledoc "mirrors.json in the state dir, in rust_nugitea's format."

  def all do
    case File.read(file()) do
      {:ok, json} ->
        json
        |> Jason.decode!(keys: :atoms)
        |> Enum.map(&%{&1 | direction: String.to_existing_atom(&1.direction)})

      {:error, :enoent} ->
        []
    end
  end

  @doc "Registers a mirror, replacing any with the same repo and direction."
  def add(entry), do: change(fn entries -> Enum.reject(entries, &same?(&1, entry)) ++ [entry] end)

  @doc "Records when a mirror last synced."
  def touch(entry, unix) do
    change(fn entries ->
      Enum.map(entries, &if(same?(&1, entry), do: %{&1 | last_sync_unix: unix}, else: &1))
    end)
  end

  defp same?(a, b), do: a.repo == b.repo and a.direction == b.direction

  defp change(fun) do
    :global.trans({{__MODULE__, file()}, self()}, fn ->
      File.mkdir_p!(Path.dirname(file()))
      File.write!(file() <> ".tmp", Jason.encode_to_iodata!(fun.(all()), pretty: true))
      File.rename!(file() <> ".tmp", file())
    end)
  end

  defp file, do: Path.join(Nugitea.Accounts.state_dir(), "mirrors.json")
end

defmodule Nugitea.Mirror.Scheduler do
  @moduledoc """
  Every 30 seconds, starts a sync for each mirror whose interval has
  elapsed, unless one for that mirror is still running.
  """
  use GenServer
  require Logger

  alias Nugitea.Mirror

  @tick :timer.seconds(30)

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    send(self(), :tick)
    # mirror key -> sync task's monitor ref
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, running) do
    Process.send_after(self(), :tick, @tick)
    now = System.os_time(:second)

    running =
      for m <- Mirror.Store.all(),
          now >= m.last_sync_unix + m.interval_seconds,
          not Map.has_key?(running, {m.direction, m.repo}),
          into: running do
        {_pid, ref} = spawn_monitor(fn -> sync(m) end)
        {{m.direction, m.repo}, ref}
      end

    {:noreply, running}
  end

  def handle_info({:DOWN, ref, :process, _, _}, running) do
    {:noreply, running |> Enum.reject(fn {_, r} -> r == ref end) |> Map.new()}
  end

  defp sync(m) do
    with {:error, reason} <- Mirror.sync(m) do
      Logger.warning("mirror sync #{m.direction} #{m.repo}: #{reason}")
    end

    Mirror.Store.touch(m, System.os_time(:second))
  end
end
