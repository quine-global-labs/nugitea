defmodule Nugitea.Storage.Client do
  @moduledoc """
  How the app tier reaches the storage tier: plain calls to `Nugitea.Storage`
  on the storage node, over Erlang distribution. This module is the whole
  internal API between the tiers.
  """

  alias Nugitea.Accounts.Directory
  alias Nugitea.Names
  alias Nugitea.Storage

  def exists?(path), do: call(:exists?, [path])
  def list, do: call(:list, [])
  def init_bare(path), do: call(:init_bare, [path])
  def run_git(path, args), do: call(:run_git, [path, args])
  def info_refs(path, service, protocol), do: call(:info_refs, [path, service, protocol])
  def branches(path), do: call(:branches, [path])
  def tree(path, ref, subpath), do: call(:tree, [path, ref, subpath])
  def blob(path, ref, subpath), do: call(:blob, [path, ref, subpath])
  def files(path, ref), do: call(:files, [path, ref])
  def delete(path), do: call(:delete, [path])
  def default_branch(path), do: call(:default_branch, [path])
  def set_default_branch(path, branch), do: call(:set_default_branch, [path, branch])
  def size(path), do: call(:size, [path])
  def commits(path, ref, opts), do: call(:commits, [path, ref, opts])
  def commit_diff(path, sha), do: call(:commit_diff, [path, sha])
  def commit_patch(path, sha), do: call(:commit_patch, [path, sha])
  def branch_tips(path), do: call(:branch_tips, [path])
  def branch(path, branch_name), do: call(:branch, [path, branch_name])
  def create_branch(path, name, from_ref), do: call(:create_branch, [path, name, from_ref])

  @doc """
  Resolves client-supplied wire form (`ACME/platform/api.git`) against the
  accounts directory to the canonical path of a repo that exists, or nil.
  """
  def resolve(dir, raw) do
    with path when path != nil <- Names.from_wire_form(raw),
         id when id != nil <- Directory.resolve_repo(dir, path),
         canonical = Directory.repo_path(dir, id),
         true <- exists?(canonical) do
      canonical
    else
      _ -> nil
    end
  end

  @doc """
  Starts a git exchange on the storage node (see `Nugitea.Storage.exchange/5`)
  and returns a handle: feed git's input with `input/2` and `eof/1`; its
  output arrives in the caller's mailbox as `{ref, :output, chunk}` and then
  `{ref, :exit, status}`. The storage process is linked to the caller, so if
  either side dies, so does the other.
  """
  def start_exchange(path, service, opts \\ []) do
    ref = make_ref()

    worker =
      Node.spawn_link(storage_node(), Storage, :exchange, [self(), ref, path, service, opts])

    %{worker: worker, ref: ref}
  end

  def input(%{worker: w, ref: ref}, chunk), do: send(w, {ref, :input, chunk})
  def eof(%{worker: w, ref: ref}), do: send(w, {ref, :eof})

  @doc "Ends the input and returns git's output as a stream (for request/response use)."
  def output(%{ref: ref} = exchange) do
    eof(exchange)

    Stream.unfold(nil, fn nil ->
      receive do
        {^ref, :output, chunk} -> {chunk, nil}
        {^ref, :exit, _status} -> nil
      end
    end)
  end

  defp call(fun, args), do: :erpc.call(storage_node(), Storage, fun, args)

  def storage_node, do: Application.fetch_env!(:nugitea, :storage_node) || Node.self()
end
