defmodule Nugitea.Storage.Client do
  @moduledoc """
  How the app tier reaches the storage tier: plain calls to `Nugitea.Storage`
  on the storage node, over Erlang distribution. This module is the whole
  "internal API" between the tiers.
  """

  alias Nugitea.Storage

  def create(path), do: call(:create, [path])
  def list, do: call(:list, [])
  def exists?(path), do: call(:exists?, [path])
  def advertise_refs(path, service), do: call(:advertise_refs, [path, service])
  def fetch(path, url), do: call(:fetch, [path, url])
  def push_mirror(path, url), do: call(:push_mirror, [path, url])

  @doc """
  Starts one smart-HTTP exchange on the storage node. Feed it the request
  body with `send_body/2`, then read git's output from `response/1`. The
  storage process is linked to the caller: if either dies, so does the other.
  """
  def start_serve(path, service) do
    ref = make_ref()
    worker = Node.spawn_link(storage_node(), Storage, :serve, [self(), ref, path, service])
    %{worker: worker, ref: ref, service: service}
  end

  def send_body(%{worker: worker, ref: ref}, chunk), do: send(worker, {ref, :body, chunk})

  @doc "Ends the request body and returns git's output as a stream of binaries."
  def response(%{worker: worker, ref: ref, service: service}) do
    send(worker, {ref, :eof})

    Stream.unfold(nil, fn nil ->
      receive do
        {^ref, :data, chunk} -> {chunk, nil}
        {^ref, :exit, 0} -> nil
        {^ref, :exit, status} -> raise "#{service} exited with #{status}"
      end
    end)
  end

  defp call(fun, args), do: :erpc.call(storage_node(), Storage, fun, args)

  defp storage_node, do: Application.fetch_env!(:nugitea, :storage_node) || Node.self()
end
