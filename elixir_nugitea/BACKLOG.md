# Backlog

Work toward Gitea's functionality, one small task at a time. The daily agent
loop takes the first unchecked task, and checks it off once the change passes
`mix format`, `mix compile --warnings-as-errors` and `mix test`. A task it
can't finish is marked `[!]` and skipped. Add tasks at the end, or reorder;
keep each one small enough to finish in one sitting, with a test.

## Test what exists

- [x] Test `Nugitea.CLI.parse_duration/1` in `test/nugitea/cli_test.exs`: "30s", "5m", "2h", and errors for "", "5", "5x", "-1m".
- [x] Test `Nugitea.Mirror.Store` in `test/nugitea/mirror_test.exs` with a tmp state dir: `add/1` replaces an entry with the same repo and direction, and `touch/2` updates only the matching entry's `last_sync_unix`.
- [x] Test `Nugitea.Storage.branches/1`, `tree/3`, `blob/3` and `files/2` in `test/nugitea/storage_test.exs` against a repo made with `Storage.init_bare/1` plus one pushed commit (build it with `git` in the tmp dir and push to the bare repo's path).
- [!] Test the GraphQL `object(expression:)` field for a tree and for a blob in `test/nugitea/graphql_test.exs`, using a real repo as in the previous task.
- [x] Test `Nugitea.Router` with `Plug.Test` in `test/nugitea/router_test.exs`: `info/refs` with a bad `service` is 400; an unknown repo is 404; a known repo's `info/refs` is 200 with content type `application/x-git-upload-pack-advertisement`.

## Small features

- [x] Add a `GET /healthz` route to `Nugitea.Router` that returns 200 "ok", with a test.
- [!] Add `mix nugitea mirror list`, printing `direction repo url interval_seconds` per mirror, with a test of the output (use `ExUnit.CaptureIO`).
- [!] Add `Nugitea.Mirror.remove(repo, direction)`: removes the git remote and the mirrors.json entry; plus `mix nugitea mirror remove REPO pull|push`. Test it.
- [!] Add `Nugitea.Accounts.Directory.delete_repo(dir, repo_id)` (also dropping grants on that repo), and `mix nugitea repo delete PATH`, which deletes the bare repo on the storage tier through a new `Storage.delete/1` and `Client.delete/1`. Test the directory part and the storage part.
- [x] Add `mix nugitea team create ORG SLUG` and `mix nugitea team add-member ORG/SLUG USER`, using the existing `Directory.add_team/5` and `set_team_member/4`. Test them.
- [x] Add `mix nugitea org add-member ORG USER [--role member|owner|billing_manager]`, using `Directory.set_org_member/4`. Test it.
- [x] Add `mix nugitea grant USER|ORG/TEAM REPO_OR_ORG_PATH ROLE` using `Directory.grant/4`. Test it.

## Access control

- [!] Add `Nugitea.Auth.Directory`, an authorizer (`@behaviour Nugitea.Auth`) that loads accounts.json and allows a pull when `Directory.effective_role(dir, nil, repo_id)` is not nil (anonymous user) and denies every push for now. Test it with public and private repos. Don't make it the default yet.
- [x] Give `Nugitea.Auth` callbacks a user argument (`allow_pull?(user, repo)`, `allow_push?(user, repo)`, user is a user id or nil) and update every caller and `AllowAll`. Callers pass nil for now. Tests still pass.
- [x] Add access tokens: `Nugitea.Accounts.Tokens` storing SHA-256 hashes of random tokens in tokens.json in the state dir, mapped to user ids; `mix nugitea token create USER` prints a new token. Test create and lookup.
- [!] In `Nugitea.Router`, read HTTP basic auth (any username, token as password), look up the user with `Tokens`, and pass the user id to `Nugitea.Auth`. Unknown tokens get 401. Test with `Plug.Test`.
- [x] Add SSH keys: `mix nugitea user add-key USER "ssh-ed25519 AAAA..."` stores the key in accounts state; `Nugitea.SSH.Keys.is_auth_key/3` accepts only stored keys, and the channel passes the key's user to `Nugitea.Auth`. Test the key store.
- [!] Make `Nugitea.Auth.Directory` the default authorizer, allowing pushes when the user's effective role is `:write` or higher. Update tests.

## Repos

- [!] Add a `description` to repos in `Directory` (default ""), saved in accounts.json, settable with `mix nugitea repo set-description PATH TEXT`. Test it.
- [!] Add archived repos: `Directory.set_archived(dir, repo_id, bool)`, `mix nugitea repo archive PATH`; `Nugitea.Auth.Directory` denies pushes to archived repos. Test it.
- [!] Add a default branch per repo: `mix nugitea repo set-default-branch PATH BRANCH` runs `git symbolic-ref HEAD refs/heads/BRANCH` on the storage tier. Test it.

## Webhooks

- [x] Add `Nugitea.Webhooks.Store` (webhooks.json in the state dir: repo path, URL, secret) and `mix nugitea webhook add REPO URL [--secret S]` / `webhook list`. Test the store.
- [!] Make the `post-receive` hook report pushed refs to the app tier: the hook script passes its stdin to `Nugitea.Storage` (design the smallest way), which notifies the app node. Test that a push records the ref updates.
- [!] Deliver webhooks: on a push, POST a JSON payload (repo, ref, before, after) to each webhook URL with an `X-Nugitea-Signature` HMAC-SHA256 header when a secret is set, retrying 3 times. Test with a local Bandit server.

## Picked by the agent from Gitea

- [!] Add support for repository topics in nugitea by implementing `mix nugitea repo set-topics PATH "topic1 topic2"` CLI command, supporting repository-level topics stored in accounts.json (following the pattern of existing features like description and archived status), with a corresponding HTTP API endpoint to retrieve topics using GET /repos/{owner}/{repo}/topics, and related tests for both command-line functionality and API retrieval.
- [!] Add a GET /repos/:owner/:repo endpoint in Nugitea.Router that returns basic repository statistics including commit count, size, and git metadata by calling into the storage tier to gather this information. This should be a simple one-file addition with tests and should not require new dependencies or schema changes, keeping it within the existing pattern of the codebase.
- [x] Add repository topics support to elixir_nugitea. This includes adding a `topics` field to repos in `Nugitea.Accounts.Directory`, implementing `mix nugitea repo set-topics PATH "topic1 topic2"` CLI command, and adding a GET `/repos/{owner}/{repo}/topics` API endpoint to retrieve the topics of a repository. The implementation should follow existing patterns from features like description and archived status, keeping to the code structure and avoiding new dependencies or schema changes. Tests must be added to prove the functionality works.
- [!] Add HTTP API endpoint for repository statistics to elixir_nugitea, implementing GET `/repos/:owner/:repo` that returns basic repository statistics like commit count, size, and git metadata. This follows the pattern of Gitea's repository API endpoint and matches what was described as a missing feature in the comparison with Gitea's API offerings.
- [x] Add a GET /repos/:owner/:repo/permissions endpoint to Nugitea.Router that returns the current user's permission level (read, write, admin) for the repository, using existing Directory.effective_role/3 to determine access and returning JSON {\"permission\": \"read|write|admin|none\"} with appropriate HTTP status codes. Test with Plug.Test and include a test case where anonymous users get 'none' permissions.
- [!] Add a GET /repos/:owner/:repo endpoint to Nugitea.Router that returns basic repository information (name, owner, visibility, description, size, commit count, etc.) by calling into the storage tier for metadata and using existing Directory functions to determine access. The implementation should follow existing patterns in the codebase and return JSON with appropriate HTTP status codes. Tests must be added to verify it works correctly.
- [ ] Add GET `/repos/:owner/:repo` endpoint to `Nugitea.Router` that returns comprehensive repository information similar to Gitea's API. The endpoint should return basic repository metadata including: name, owner, visibility, description, size, commit count, branch count, and permissions. This requires implementing the following in the app tier:
