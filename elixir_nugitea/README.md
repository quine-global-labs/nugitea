# elixir_nugitea

An Elixir port of `rust_nugitea`, at feature parity with it: the same split
into an app tier and a storage tier (GitLab and Gitaly), but the tiers talk
over Erlang distribution instead of an internal protocol written by hand.

```
git client --HTTP/SSH--> [app node]   --Erlang distribution-->  [storage node]
                          Router (smart HTTP, /graphql)           Storage
                          SSH, mirror scheduler                   (owns repo root, runs git)
                          accounts.json, mirrors.json

                         [web: Nuxt frontend, rust_nugitea/web] --/graphql--> [app node]
```

`Nugitea.Storage.Client` is the entire internal API: `:erpc.call/4` for plain
calls, and a linked process plus messages for streaming a git exchange.

## What it does

- Smart-HTTP and SSH clone, fetch and push, including protocol v2 and
  gzipped requests, at any owner depth (`org/sub-org/name`).
- Users, orgs (nested), teams, enterprises, grants and blocks
  (`Nugitea.Accounts.Directory`), stored as accounts.json in the same JSON
  shape rust_nugitea writes. Not enforced yet: `Nugitea.Auth` allows all.
- Pull and push mirrors, synced by a scheduler (`Nugitea.Mirror`).
- The GitHub-shaped GraphQL API the Nuxt frontend uses, loaded from the
  frontend's own schema.graphql (`priv/schema.graphql`), with GraphiQL at
  `/graphql`.
- Git hooks installed on every repo (stubs for now).

## Run

```sh
mix deps.get
mix nugitea user create alice
mix nugitea repo create alice/demo
mix nugitea serve        # HTTP :3080, SSH :2222
```

Split across two nodes (any two hosts sharing an Erlang cookie):

```sh
NUGITEA_ROLE=storage elixir --sname storage -S mix nugitea serve
NUGITEA_ROLE=app NUGITEA_STORAGE_NODE=storage@$(hostname -s) elixir --sname app -S mix nugitea serve
mix nugitea --storage-node storage@$(hostname -s) repo create alice/demo
```

Commands: `serve`, `user create|list`, `org create|list`, `repo create|list`,
`mirror add-pull|add-push`, `graphql-schema`. See `Nugitea.CLI`.

| Variable | Default | |
|---|---|---|
| `NUGITEA_ROLE` | `all` | `all`, `app` or `storage` |
| `NUGITEA_REPO_ROOT` | `./data/repos` | storage tier: bare repos |
| `NUGITEA_STATE_DIR` | `./data` | app tier: accounts.json, mirrors.json |
| `NUGITEA_HTTP_PORT` / `NUGITEA_SSH_PORT` | `3080` / `2222` | |
| `NUGITEA_SSH_HOST_KEY_DIR` | `./data/ssh` | generated on first start |
| `NUGITEA_STORAGE_NODE` | | required with `NUGITEA_ROLE=app` |

Connected Erlang nodes trust each other completely, the same trust Gitaly
gives GitLab's app tier: keep the distribution port private.

## Notes

- git runs under `erlexec`, which can close git's stdin while still reading
  its stdout; plain Erlang ports can't, and both smart HTTP (stateless-rpc)
  and SSH need that.
- Unlike rust_nugitea, the Git-Protocol header also reaches the ref
  advertisement, so HTTP clients get protocol v2.
- Input to the storage node isn't flow-controlled: a large push to a slow
  storage node queues in memory.
