defmodule Nugitea.Storage do
  @moduledoc """
  The storage tier: owns the repo root and runs every git process, the way
  Gitaly does for GitLab. It trusts its caller; access checks happen once, in
  the app tier, before anything gets here.

  These functions run on the storage node. The app tier reaches them through
  `Nugitea.Storage.Client`, which is Erlang distribution and nothing else: no
  protocol of our own. With NUGITEA_ROLE=all the "remote" node is this one.

  Repos are addressed by path: `name`, or `owner/name`, `org/sub-org/name`...
  """

  @services %{"git-upload-pack" => "upload-pack", "git-receive-pack" => "receive-pack"}

  def services, do: Map.keys(@services)

  def create(path) do
    with {:ok, dir} <- dir(path) do
      if File.exists?(dir) do
        {:error, :exists}
      else
        File.mkdir_p!(Path.dirname(dir))
        {_, 0} = System.cmd("git", ["init", "--bare", "--quiet", "--initial-branch=main", dir])
        :ok
      end
    end
  end

  def list do
    root = root()

    Path.wildcard(Path.join(root, "**/*.git"))
    |> Enum.map(&(&1 |> Path.relative_to(root) |> String.trim_trailing(".git")))
    |> Enum.sort()
  end

  def exists?(path) do
    case dir(path) do
      {:ok, dir} -> File.dir?(dir)
      {:error, _} -> false
    end
  end

  @doc "The ref advertisement that starts a smart-HTTP exchange (`GET .../info/refs`)."
  def advertise_refs(path, service) do
    with {:ok, dir} <- dir(path),
         {:ok, cmd} <- command(service),
         true <- File.dir?(dir) || {:error, :not_found} do
      {out, 0} = System.cmd("git", [cmd, "--stateless-rpc", "--advertise-refs", dir])
      {:ok, out}
    end
  end

  @doc """
  One smart-HTTP request/response (`POST .../git-upload-pack` or
  `git-receive-pack`). Started on this node by the app tier, which sends the
  request body as `{ref, :body, chunk}` messages then `{ref, :eof}`; git's
  output goes back to `reply_to` as `{ref, :data, chunk}`, then
  `{ref, :exit, status}`.

  The body is spooled to a temp file because an Erlang port can't close
  git's stdin while still reading its stdout, and stateless-rpc git reads
  stdin to EOF before answering.
  """
  def serve(reply_to, ref, path, service) do
    {:ok, dir} = dir(path)
    {:ok, cmd} = command(service)
    tmp = Path.join(System.tmp_dir!(), "nugitea-#{System.unique_integer([:positive])}")

    try do
      File.open!(tmp, [:write, :raw, :binary], &receive_body(&1, ref))

      port =
        Port.open({:spawn_executable, System.find_executable("sh")}, [
          :binary,
          :exit_status,
          args: ["-c", ~s(exec git "$0" --stateless-rpc "$1" < "$2"), cmd, dir, tmp]
        ])

      forward_output(port, reply_to, ref)
    after
      File.rm(tmp)
    end
  end

  defp receive_body(file, ref) do
    receive do
      {^ref, :body, chunk} ->
        :ok = IO.binwrite(file, chunk)
        receive_body(file, ref)

      {^ref, :eof} ->
        :ok
    end
  end

  defp forward_output(port, reply_to, ref) do
    receive do
      {^port, {:data, chunk}} ->
        send(reply_to, {ref, :data, chunk})
        forward_output(port, reply_to, ref)

      {^port, {:exit_status, status}} ->
        send(reply_to, {ref, :exit, status})
    end
  end

  @doc "Fetch everything from `url` into the repo, pruning what's gone (a pull mirror)."
  def fetch(path, url) do
    with {:ok, dir} <- dir(path) do
      git(dir, ["fetch", "--prune", "--tags", url, "+refs/heads/*:refs/heads/*"])
    end
  end

  @doc "Make `url` an exact copy of the repo (a push mirror)."
  def push_mirror(path, url) do
    with {:ok, dir} <- dir(path), do: git(dir, ["push", "--mirror", "--force", url])
  end

  defp git(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, status} -> {:error, {status, out}}
    end
  end

  defp command(service) do
    case @services do
      %{^service => cmd} -> {:ok, cmd}
      _ -> {:error, :bad_service}
    end
  end

  # Each segment is a plain name; nothing like "..", ".hidden" or "a/../b".
  defp dir(path) do
    segments = String.split(path, "/")

    if segments != [] and Enum.all?(segments, &(&1 =~ ~r/^[A-Za-z0-9_-][A-Za-z0-9._-]*$/)) do
      {:ok, Path.join(root(), path <> ".git")}
    else
      {:error, :bad_path}
    end
  end

  defp root, do: Application.fetch_env!(:nugitea, :repo_root)
end
