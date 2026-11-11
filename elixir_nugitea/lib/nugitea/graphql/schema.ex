defmodule Nugitea.GraphQL.Schema do
  @moduledoc """
  A GitHub-schema-compatible GraphQL API for browsing owners and repo
  contents, queried by the Nuxt frontend (rust_nugitea/web). The types come
  straight from the frontend's schema.graphql (copied to priv/; a test keeps
  the copy identical), so the two can't drift; this module only attaches
  resolvers. See rust_nugitea's graphql.rs for the GitHub mapping and the
  nested-org extensions (`parentOrganization`, `subOrganizations`,
  top-level `repositories`, `files`).
  """
  use Absinthe.Schema

  alias Nugitea.GraphQL.Resolvers, as: R

  @sdl_path Path.join(__DIR__, "../../../priv/schema.graphql") |> Path.expand()
  @external_resource @sdl_path

  # schema.graphql re-declares the built-in @include/@skip, which Absinthe
  # already defines.
  import_sdl(
    @sdl_path
    |> File.read!()
    |> String.replace(~r/^"""\n[^"]*\n"""\ndirective [^\n]*\n/m, "")
  )

  defp resolvers do
    %{
      query: %{
        repository: &R.repository/3,
        repository_owner: &R.repository_owner/3,
        user: &R.user/3,
        organization: &R.organization/3,
        resource: &R.resource/3,
        repositories: &R.all_repositories/3
      },
      repository: %{
        owner: &R.repo_owner/3,
        default_branch_ref: &R.default_branch_ref/3,
        refs: &R.refs/3,
        files: &R.files/3,
        object: &R.object/3
      },
      user: %{repositories: &R.owned_repositories/3},
      organization: %{
        repositories: &R.owned_repositories/3,
        parent_organization: &R.parent_organization/3,
        sub_organizations: &R.sub_organizations/3
      }
    }
  end

  @impl Absinthe.Schema
  def hydrate(%Absinthe.Blueprint.Schema.FieldDefinition{identifier: field}, [
        %{identifier: type} | _
      ]) do
    case get_in(resolvers(), [type, field]) do
      nil -> []
      resolver -> {:resolve, resolver}
    end
  end

  # Interfaces: every object carries its concrete type.
  def hydrate(%Absinthe.Blueprint.Schema.InterfaceTypeDefinition{}, _ancestors) do
    {:resolve_type, &R.resolve_type/2}
  end

  def hydrate(_node, _ancestors), do: []
end
