defmodule Nugitea.Accounts.Store do
  @moduledoc """
  Persists a `Nugitea.Accounts.Directory` as accounts.json in the app tier's
  state dir, in the same JSON shape rust_nugitea writes, so either can read
  the other's file. Every read reloads the file, so changes the CLI makes
  while the server runs show up without a restart.
  """

  alias Nugitea.Accounts.Directory

  def load(state_dir) do
    case File.read(file(state_dir)) do
      {:ok, json} -> {:ok, decode(json)}
      {:error, :enoent} -> {:ok, %Directory{}}
      {:error, reason} -> {:error, "read accounts.json: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Applies `fun` to the current directory and saves the result, unless it
  fails. `fun` returns `{:ok, dir}`, `{:ok, dir, value}` or `{:error, reason}`;
  `update` returns `:ok`, `{:ok, value}` or the error. Updates are serialized
  across every connected node.
  """
  def update(state_dir, fun) do
    path = file(state_dir)

    :global.trans({{__MODULE__, path}, self()}, fn ->
      with {:ok, dir} <- load(state_dir),
           result when elem(result, 0) == :ok <- fun.(dir) do
        File.mkdir_p!(state_dir)
        File.write!(path <> ".tmp", encode(elem(result, 1)))
        File.rename!(path <> ".tmp", path)
        if tuple_size(result) == 3, do: {:ok, elem(result, 2)}, else: :ok
      end
    end)
  end

  defp file(state_dir), do: Path.join(state_dir, "accounts.json")

  # ---- JSON, in serde's shape ------------------------------------------

  def encode(%Directory{} = d) do
    Jason.encode_to_iodata!(
      %{
        next_id: d.next_id,
        accounts: by_id(d.accounts, & &1),
        enterprises: by_id(d.enterprises, & &1),
        teams: by_id(d.teams, &%{&1 | members: by_id(&1.members, fn role -> role end)}),
        repos: by_id(d.repos, & &1),
        custom_roles: by_id(d.custom_roles, &%{&1 | permissions: Enum.sort(&1.permissions)}),
        org_members: by_id(d.org_members, &by_id(&1, fn role -> role end)),
        enterprise_roles: by_id(d.enterprise_roles, &by_id(&1, fn role -> role end)),
        blocks: d.blocks |> Enum.sort() |> Enum.map(&Tuple.to_list/1),
        grants: Enum.map(d.grants, &encode_grant/1)
      },
      pretty: true
    )
  end

  defp by_id(map, fun), do: Map.new(map, fn {id, v} -> {Integer.to_string(id), fun.(v)} end)

  defp encode_grant(g) do
    {pkind, pid} = g.principal
    {rkind, rid} = g.resource

    %{
      principal: %{kind: pkind, id: pid},
      resource: %{kind: rkind, id: rid},
      # serde's untagged GrantRole: a built-in role's name, or a custom role's id
      role:
        case g.role do
          {:custom, id} -> id
          role -> role
        end
    }
  end

  def decode(json) do
    j = Jason.decode!(json)

    %Directory{
      next_id: j["next_id"] || 0,
      accounts: from_id(j["accounts"], &decode_account/1),
      enterprises:
        from_id(j["enterprises"], &%{id: &1["id"], slug: &1["slug"], shortcode: &1["shortcode"]}),
      teams: from_id(j["teams"], &decode_team/1),
      repos:
        from_id(
          j["repos"],
          &%{
            id: &1["id"],
            owner: &1["owner"],
            slug: &1["slug"],
            visibility: atom(&1["visibility"]),
            topics: &1["topics"] || []
          }
        ),
      custom_roles: from_id(j["custom_roles"], &decode_custom_role/1),
      org_members: from_id(j["org_members"], &from_id(&1, fn r -> atom(r) end)),
      enterprise_roles: from_id(j["enterprise_roles"], &from_id(&1, fn r -> atom(r) end)),
      blocks: MapSet.new(j["blocks"] || [], &List.to_tuple/1),
      grants: Enum.map(j["grants"] || [], &decode_grant/1)
    }
  end

  defp from_id(nil, _fun), do: %{}
  defp from_id(map, fun), do: Map.new(map, fn {id, v} -> {String.to_integer(id), fun.(v)} end)

  defp decode_account(%{"kind" => "user"} = a) do
    %{
      id: a["id"],
      slug: a["slug"],
      visibility: atom(a["visibility"]),
      kind: :user,
      managed_by: a["managed_by"]
    }
  end

  defp decode_account(%{"kind" => "org"} = a) do
    %{
      id: a["id"],
      slug: a["slug"],
      visibility: atom(a["visibility"]),
      kind: :org,
      parent: a["parent"],
      enterprise: a["enterprise"],
      base_role: atom(a["base_role"])
    }
  end

  defp decode_team(t) do
    %{
      id: t["id"],
      org: t["org"],
      parent: t["parent"],
      slug: t["slug"],
      privacy: atom(t["privacy"]),
      members: from_id(t["members"], &atom/1)
    }
  end

  defp decode_custom_role(c) do
    %{
      id: c["id"],
      org: c["org"],
      name: c["name"],
      base: atom(c["base"]),
      permissions: MapSet.new(c["permissions"])
    }
  end

  defp decode_grant(g) do
    %{
      principal: {atom(g["principal"]["kind"]), g["principal"]["id"]},
      resource: {atom(g["resource"]["kind"]), g["resource"]["id"]},
      role: if(is_integer(g["role"]), do: {:custom, g["role"]}, else: atom(g["role"]))
    }
  end

  # Only names the model already uses; never mints new atoms from a file.
  defp atom(nil), do: nil
  defp atom(s), do: String.to_existing_atom(s)
end
