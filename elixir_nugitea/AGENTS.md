# Working on elixir_nugitea (for coding agents)

You are working on `elixir_nugitea`, a small Gitea-like git server in Elixir.
Read README.md first for the architecture. Work only inside this directory.

## Check your work

Run these from `elixir_nugitea/`. All three must pass before you are done:

```sh
mix format
mix compile --warnings-as-errors
mix test
```

If a check fails, read the error, fix the code, and run the checks again.
Never delete or weaken an existing test to make it pass.

## Layout

- `lib/nugitea/storage.ex`: the storage tier. The only code that runs `git`
  or touches repos on disk.
- `lib/nugitea/storage/client.ex`: how everything else calls the storage tier.
  Never call `Nugitea.Storage` directly from other modules.
- `lib/nugitea/accounts/directory.ex`: users, orgs, teams, repos, grants. Pure
  functions: every change returns `{:ok, dir}`, `{:ok, dir, id}` or
  `{:error, reason}`.
- `lib/nugitea/accounts/store.ex`: saves the directory as accounts.json.
- `lib/nugitea/router.ex`: HTTP (git smart HTTP and `/graphql`).
- `lib/nugitea/ssh.ex`: SSH transport.
- `lib/nugitea/mirror.ex`: pull/push mirrors and their scheduler.
- `lib/nugitea/cli.ex`: `mix nugitea ...` commands.
- `lib/nugitea/graphql/`: GraphQL resolvers. The types come from
  `priv/schema.graphql`; do not edit that file.
- `test/`: ExUnit tests. Tests that need files use `@moduletag :tmp_dir`.

## Rules

- Do one task, the one you were given. Keep the change small.
- Every task adds or extends a test that proves it works.
- Follow the style of the surrounding code. Match its comments and naming.
- Don't add dependencies to mix.exs unless the task says so.
- Don't edit `priv/schema.graphql`, `AGENTS.md` or `BACKLOG.md`.
- Don't run `git commit`, `git push` or anything that changes git history;
  the loop that runs you commits your work after checking it.
- Don't use the network except `mix deps.get`.
- When you are done, reply with a short summary of what you changed.
