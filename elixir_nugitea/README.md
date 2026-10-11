# elixir_nugitea

PROTOTYPE. An Elixir take on `rust_nugitea`'s design, to see whether it's
simpler: the same split into an app tier and a storage tier (GitLab and
Gitaly), but the tiers talk over Erlang distribution instead of an internal
protocol written by hand.

```
git client --HTTP--> [app node]  --Erlang distribution-->  [storage node]
                      Nugitea.Router                         Nugitea.Storage
                      (smart HTTP, repo API)                 (owns repo root, runs git)
```

`Nugitea.Storage.Client` is the entire internal API: `:erpc.call/4` for
plain calls, and `Node.spawn_link/4` plus messages for streaming a git
exchange. In `rust_nugitea` that role takes `storage_client.rs`,
`storage_server.rs` and `git_exec_tcp.rs`.

## What it does

- Smart-HTTP clone, fetch and push (`git clone http://host:3080/owner/name.git`),
  including gzipped upload-pack requests, as Gitea's
  `routers/web/repo/githttp.go` serves them.
- Repo paths of any depth: `name`, `owner/name`, `org/sub-org/name`.
- Create repos: `curl -d path=owner/name http://host:3080/api/repos`.
- `Nugitea.Storage.fetch/2` and `push_mirror/2` for pull and push mirrors
  (no scheduler yet).
- An index page listing clone URLs.

Not yet: SSH, mirror scheduling, accounts, a web UI beyond the index.

## Run

One node with both tiers, like Gitea:

```sh
mix deps.get
NUGITEA_REPO_ROOT=./data mix run --no-halt
```

Split across two nodes (same machine here; any two hosts sharing an Erlang
cookie work):

```sh
NUGITEA_ROLE=storage NUGITEA_REPO_ROOT=./data elixir --sname storage -S mix run --no-halt
NUGITEA_ROLE=app NUGITEA_STORAGE_NODE=storage@$(hostname -s) elixir --sname app -S mix run --no-halt
```

| Variable | Default | |
|---|---|---|
| `NUGITEA_ROLE` | `all` | `all`, `app` or `storage` |
| `NUGITEA_REPO_ROOT` | `./data` | where the storage tier keeps bare repos |
| `NUGITEA_HTTP_PORT` | `3080` | app tier |
| `NUGITEA_STORAGE_NODE` | | required with `NUGITEA_ROLE=app` |

Connected Erlang nodes trust each other completely, the same trust Gitaly
gives GitLab's app tier: keep the distribution port private.

## Notes

- A request body is spooled to a temp file on the storage node before git
  runs: an Erlang port can't close git's stdin while still reading its
  stdout, and stateless-rpc git reads stdin to EOF first.
- Body chunks are sent to the storage node without flow control. Fine on a
  LAN; a large push to a slow storage node would queue in memory.
