defmodule Nugitea.Names do
  @moduledoc """
  Repo-path parsing and validation, no I/O. Shared by the app tier (which
  only ever sees repo paths) and the storage tier (which validates before
  touching disk), so "what makes a repo path safe" is decided in one place.

  A repo path is `owner/name`, or `org/sub-org/.../name` under nested orgs:
  one or more owner segments, then the repo name.
  """

  # GitLab's subgroup depth limit.
  @max_owner_depth 20

  @doc """
  A single path segment (account slug or repo name): starts with a letter,
  digit or `_`, then letters, digits, `_`, `-` or `.`. The storage tier's
  only defence against path traversal, since it trusts its caller.
  """
  def validate(name) do
    if name =~ ~r/\A[A-Za-z0-9_][A-Za-z0-9_.-]*\z/,
      do: :ok,
      else: {:error, "invalid repo name #{inspect(name)}"}
  end

  @doc """
  A full `owner[/sub-org...]/name`. Owner segments can't end in `.git`, so a
  bare repo's directory is never mistaken for an owner's, or vice versa.
  """
  def validate_repo_path(path) do
    segs = String.split(path, "/")
    {owners, _name} = Enum.split(segs, -1)

    cond do
      length(segs) < 2 or length(segs) > @max_owner_depth + 1 -> bad(path)
      Enum.any?(segs, &(validate(&1) != :ok)) -> bad(path)
      Enum.any?(owners, &String.ends_with?(String.downcase(&1), ".git")) -> bad(path)
      true -> :ok
    end
  end

  defp bad(path), do: {:error, "invalid repo name #{inspect(path)}"}

  @doc """
  Turns client-supplied wire form (`/acme/api.git` over SSH, `acme/api.git`
  over HTTP) into a safe repo path, or nil.
  """
  def from_wire_form(raw) do
    path =
      case raw do
        "/" <> rest -> rest
        _ -> raw
      end

    with true <- String.ends_with?(path, ".git"),
         path = String.slice(path, 0..-5//1),
         :ok <- validate_repo_path(path) do
      path
    else
      _ -> nil
    end
  end
end
