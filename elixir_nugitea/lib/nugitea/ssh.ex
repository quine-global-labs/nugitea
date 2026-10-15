defmodule Nugitea.SSH do
  @moduledoc """
  The app tier's SSH transport for clone and push (`git clone
  ssh://host:2222/owner/name.git`), on OTP's own SSH server. Like the HTTP
  side it runs no git: it resolves the repo, asks `Nugitea.Auth`, and streams
  the session to a git exchange on the storage tier, both ways at once (SSH's
  git protocol is interactive, unlike smart HTTP's request/response).

  No logins yet, so any public key is accepted: `Keys.is_auth_key/3` is the
  seam for real key checks, as `Nugitea.Auth` is for repo access.
  """

  @host_key "ssh_host_ed25519_key"

  def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}

  def start_link do
    dir = Application.fetch_env!(:nugitea, :ssh_host_key_dir)
    ensure_host_key(dir)

    {:ok, daemon} =
      :ssh.daemon(Application.fetch_env!(:nugitea, :ssh_port),
        system_dir: String.to_charlist(dir),
        key_cb: {__MODULE__.Keys, []},
        auth_methods: ~c"publickey",
        ssh_cli: {__MODULE__.Channel, []}
      )

    Process.link(daemon)
    {:ok, daemon}
  end

  defp ensure_host_key(dir) do
    path = Path.join(dir, @host_key)

    unless File.exists?(path) do
      File.mkdir_p!(dir)

      {_, 0} =
        System.cmd("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "nugitea", "-f", path])
    end
  end

  defmodule Keys do
    @moduledoc false
    @behaviour :ssh_server_key_api

    @impl true
    def host_key(algorithm, opts), do: :ssh_file.host_key(algorithm, opts)

    @impl true
    def is_auth_key(key, user, _opts) do
      case Nugitea.Accounts.Store.load(Nugitea.Accounts.state_dir()) do
        {:ok, dir} -> authorized?(dir, user, key)
        {:error, _} -> false
      end
    end

    @doc """
    Whether `key` (a decoded public key, as OTP passes it) is one of the SSH
    keys stored for the login `user` (a charlist from OTP, or a string).

    Deploy keys don't log in: one would act as its repo's owner, with access
    to all their repos, so they need checking per repo at exec time instead.
    """
    def authorized?(dir, user, key) do
      case Nugitea.Accounts.Directory.resolve(dir, to_string(user)) do
        nil ->
          false

        user_id ->
          keys = Nugitea.Accounts.Directory.get_user_keys(dir, user_id) || []
          Enum.any?(keys, &(decode(&1.key) == key))
      end
    end

    # Stored keys are `authorized_keys` lines: "ssh-ed25519 AAAA... comment".
    defp decode(line) do
      case :ssh_file.decode(line, :auth_keys) do
        [{key, _attrs} | _] -> key
        _ -> nil
      end
    rescue
      _ -> nil
    end
  end

  defmodule Channel do
    @moduledoc false
    @behaviour :ssh_server_channel

    alias Nugitea.Accounts
    alias Nugitea.Storage.Client

    @verbs %{"git-upload-pack" => "upload-pack", "git-receive-pack" => "receive-pack"}

    @impl true
    def init(_), do: {:ok, %{exchange: nil, protocol: nil}}

    @impl true
    def handle_msg({:ssh_channel_up, _channel, _cm}, state), do: {:ok, state}

    # git's output, from the storage tier.
    def handle_msg({ref, :output, chunk}, %{exchange: %{ref: ref}} = s) do
      :ssh_connection.send(s.cm, s.channel, chunk)
      {:ok, s}
    end

    def handle_msg({ref, :exit, status}, %{exchange: %{ref: ref}} = s) do
      :ssh_connection.exit_status(s.cm, s.channel, status)
      :ssh_connection.send_eof(s.cm, s.channel)
      {:stop, s.channel, s}
    end

    def handle_msg(_msg, state), do: {:ok, state}

    @impl true
    # `git` sends GIT_PROTOCOL (e.g. "version=2") as an env request before exec.
    def handle_ssh_msg({:ssh_cm, cm, {:env, ch, want_reply, var, value}}, state) do
      :ssh_connection.reply_request(cm, want_reply, :success, ch)

      case IO.iodata_to_binary(var) do
        "GIT_PROTOCOL" -> {:ok, %{state | protocol: IO.iodata_to_binary(value)}}
        _ -> {:ok, state}
      end
    end

    def handle_ssh_msg({:ssh_cm, cm, {:exec, ch, want_reply, cmd}}, state) do
      state = Map.merge(state, %{cm: cm, channel: ch})

      case start(List.to_string(cmd), state) do
        {:ok, exchange} ->
          :ssh_connection.reply_request(cm, want_reply, :success, ch)
          {:ok, %{state | exchange: exchange}}

        {:error, msg} ->
          :ssh_connection.send(cm, ch, 1, "nugitea: #{msg}\n")
          :ssh_connection.reply_request(cm, want_reply, :failure, ch)
          :ssh_connection.exit_status(cm, ch, 1)
          :ssh_connection.send_eof(cm, ch)
          {:stop, ch, state}
      end
    end

    def handle_ssh_msg({:ssh_cm, _, {:data, _ch, 0, data}}, %{exchange: ex} = state)
        when ex != nil do
      Client.input(ex, data)
      {:ok, state}
    end

    def handle_ssh_msg({:ssh_cm, _, {:eof, _ch}}, %{exchange: ex} = state) when ex != nil do
      Client.eof(ex)
      {:ok, state}
    end

    def handle_ssh_msg({:ssh_cm, _, {:closed, ch}}, state), do: {:stop, ch, state}

    # Shells, ptys and the rest: only git commands are served.
    def handle_ssh_msg({:ssh_cm, cm, {:shell, ch, want_reply}}, state) do
      :ssh_connection.reply_request(cm, want_reply, :failure, ch)
      {:stop, ch, state}
    end

    def handle_ssh_msg(_msg, state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state), do: :ok

    defp start(cmd, state) do
      with {:ok, verb, raw} <- parse(cmd),
           {:ok, dir} <- Accounts.Store.load(Accounts.state_dir()),
           {:ok, repo} <- found(Client.resolve(dir, raw), raw),
           :ok <-
             if(Nugitea.Auth.allow?(verb, state.user_id, repo),
               do: :ok,
               else: {:error, "forbidden"}
             ) do
        {:ok, Client.start_exchange(repo, verb, protocol: state.protocol)}
      end
    end

    defp found(nil, raw), do: {:error, "repository #{inspect(raw)} not found"}
    defp found(repo, _raw), do: {:ok, repo}

    defp parse(cmd) do
      case OptionParser.split(cmd) do
        [verb, repo] when is_map_key(@verbs, verb) -> {:ok, @verbs[verb], repo}
        [verb | _] -> {:error, "unsupported command #{inspect(verb)}"}
        [] -> {:error, "unsupported command"}
      end
    end
  end
end
