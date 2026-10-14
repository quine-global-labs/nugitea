# Backlog

Work toward Gitea's functionality, one small task at a time. The agent loop
takes the first unchecked task, and checks it off once the change passes
`mix format`, `mix compile --warnings-as-errors` and `mix test`. A task it
can't finish is marked `[!]` and skipped; with none left, it picks a feature
from Gitea itself. Keep each task on one line, small enough to finish in one
sitting, with a test.

## Gitea's API, step by step

JSON field names follow Gitea's API structs, in modules/structs/ of Gitea's
source (a subset of the fields is fine). The API lives in `Nugitea.API` under
`/api/v1` once the first task here is done; tests use `Plug.Test` with a tmp
state dir and repo root, as test/nugitea/router_test.exs does.

### Clean up

- [!] Delete the stray `lib/nugitea/router.ex.backup`, and save each repo's `description` and `website` in accounts.json (`Nugitea.Accounts.Store.encode/1` and `decode/1`, defaulting to "" when missing). Test that a repo's description and website survive `Store.update/2` then `Store.load/1`.
- [!] Give pull requests Gitea-style numbers: replace the timestamp `id` in `Directory.create_pull_request` with `number`, the next integer in that repo starting at 1, and save `pull_requests` in accounts.json (`Store.encode/1` and `decode/1`, dates as ISO 8601 strings). Test the numbering (1 then 2 in one repo, 1 in another) and that pull requests survive a save and load.

### API foundation

- [!] Move the JSON API out of `Nugitea.Router` into a new `Nugitea.API` (`use Plug.Router`), forwarded at `/api/v1` before the `/*glob` git routes, with a `json(conn, status, data)` helper; move the existing `/repos/:owner/:repo...` routes and their tests to `/api/v1/repos/...`. Unknown API paths get 404 with `{"message": "not found"}`. Test the 404 and one moved route.
- [x] Add `GET /api/v1/version` to `Nugitea.API`, returning `{"version": ...}` from `Application.spec(:nugitea, :vsn)`, like Gitea's `ServerVersion` (modules/structs/miscellaneous.go). Test it.
- [!] Add API authentication to `Nugitea.API`: a plug that reads `Authorization: token TOKEN`, `Authorization: Bearer TOKEN`, or basic auth with the token as the password, looks it up with `Nugitea.Accounts.Tokens.lookup_token/2`, and sets `conn.assigns.user_id` (nil without a header). An unknown token gets 401. Test all three header forms, no header, and a bad token.
- [x] Add `GET /api/v1/user`, returning the authenticated user as `{"id", "login"}` (a subset of Gitea's `User`, modules/structs/user.go), or 401 when anonymous. Test both.
- [x] Use the authenticated user in the existing repo routes: `GET /api/v1/repos/:owner/:repo` and its `/permissions` pass `conn.assigns.user_id` to `Directory.effective_role/3` instead of nil, and answer 404 when the role is nil (a private repo the caller can't see). Test a private repo as anonymous (404) and as its owner (200).
- [x] Add `GET /api/v1/users/:username` (`{"id", "login"}`; 404 for an unknown login or an org) and `GET /api/v1/users/:username/repos` (the repos the user owns that the caller can see, in the same JSON as `GET /api/v1/repos/:owner/:repo`). Test both, including that a private repo is hidden from anonymous callers.
- [x] Add `GET /api/v1/orgs/:org` (`{"id", "name", "visibility"}`, a subset of Gitea's `Organization`, modules/structs/org.go) and `GET /api/v1/orgs/:org/repos` (only repos the caller can see). Test both.
- [x] Add `GET /api/v1/orgs/:org/members` (the members' `{"id", "login"}`, using `Directory.org_member?/3`) and `GET /api/v1/orgs/:org/teams` (`[{"id", "name"}]`). Test both.
- [!] Add `POST /api/v1/user/repos` (`{"name", "private", "description"}`): creates the repo under the authenticated user with `Directory.add_repo/4` and `Client.init_bare/1`, and answers 201 with the repo JSON; 401 when anonymous, 409 when it exists. Test all three.
- [!] Add `POST /api/v1/orgs/:org/repos`, like `POST /api/v1/user/repos` but owned by the org; only an org owner (`Directory.org_role/3` is `:owner`) may create one, others get 403. Test an owner, a member and an anonymous caller.
- [!] Add `GET /api/v1/repos/search?q=TEXT&limit=N`: the repos whose `owner/name` contains TEXT, ignoring case, that the caller can see, as `{"ok": true, "data": [repo, ...]}` like Gitea. Test matching, the limit, and that a private repo is hidden.

### Repos on the storage tier

- [x] Add `Storage.delete(path)` and `Client.delete(path)`, which remove a bare repo's directory and refuse any path outside the repo root. Test it in test/nugitea/storage_test.exs. (Storage only: no CLI or API yet.)
- [x] Add `Directory.delete_repo(dir, repo_id)`, which removes the repo, the grants on it and its pull requests. Test it.
- [x] Add `DELETE /api/v1/repos/:owner/:repo` (admin role required; 204) and `mix nugitea repo delete PATH`, both using `Directory.delete_repo/2` and then `Client.delete/1`. Test the API route.
- [x] Add `Storage.default_branch(path)` (`git symbolic-ref --short HEAD`) and `Storage.set_default_branch(path, branch)` (refusing a branch that doesn't exist), with `Client` wrappers. Test both.
- [!] Show `default_branch` in `GET /api/v1/repos/:owner/:repo`, and make it settable with `PATCH /api/v1/repos/:owner/:repo` (`{"default_branch": ...}`) and `mix nugitea repo set-default-branch PATH BRANCH`, using `Client.set_default_branch/2`. Test the PATCH.
- [x] Add `Storage.size(path)` (KiB, `size` plus `size-pack` from `git count-objects -v`) and report it as `size` in `GET /api/v1/repos/:owner/:repo` instead of 0; set `empty` from whether the repo has any branches. Test with an empty and a non-empty repo.

### Git data

- [x] Add `Storage.commits(path, ref, opts)` (opts `limit`, `skip`, `path`) using `git log` with a NUL-separated `--format`, returning `%{sha, parents, author_name, author_email, author_date, committer_name, committer_email, committer_date, message}`, plus `Client.commits/3`. Test it on a repo with three commits, including limit and skip.
- [!] Add `GET /api/v1/repos/:owner/:repo/commits?sha=REF&limit=N&page=P&path=FILE` in the shape of Gitea's `Commit` (modules/structs/repo_commit.go: `sha`, `commit.message`, `commit.author{name,email,date}`, `parents[].sha`), using `Client.commits/3`; the ref defaults to the default branch. Test it.
- [!] Add `GET /api/v1/repos/:owner/:repo/git/commits/:sha`: one commit in the same shape, plus `files[].filename` and `stats{additions,deletions,total}` from `git show --numstat --format=`; 404 for an unknown sha. Test it.
- [x] Add `GET /api/v1/repos/:owner/:repo/git/commits/:sha.diff` and `.patch` as text/plain, from `git diff SHA^ SHA` (a root commit diffs against the empty tree) and `git format-patch -1 --stdout SHA`, through new `Storage` and `Client` functions. Test both.
- [x] Add `Storage.branch_tips(path)` (`git for-each-ref` with refname, objectname and subject) and `GET /api/v1/repos/:owner/:repo/branches` and `/branches/:branch`, as Gitea's `Branch` (modules/structs/repo_branch.go: `name`, `commit.id`, `commit.message`). Test both, and 404 for a missing branch.
- [x] Add `Storage.create_branch(path, name, from_ref)` (`git branch`, checking the name with `git check-ref-format --branch`) and `POST /api/v1/repos/:owner/:repo/branches` (`{"new_branch_name", "old_ref_name"}`; 201; 409 when it exists; write access required). Test it.
- [!] Add `Storage.delete_branch(path, name)` and `DELETE /api/v1/repos/:owner/:repo/branches/:branch` (204; 403 for the default branch; 404 when missing; write access required). Test it.
- [!] Add `Storage.tags(path)` (name, the commit it points to, and the message of an annotated tag; newest first) and `GET /api/v1/repos/:owner/:repo/tags` and `/tags/:tag`, as Gitea's `Tag` (modules/structs/repo_tag.go). Test with a lightweight and an annotated tag.
- [x] Add `Storage.create_tag(path, name, target, message)` (annotated when the message isn't empty, tagged by "nugitea <nugitea@localhost>") and `Storage.delete_tag(path, name)`, with `POST /api/v1/repos/:owner/:repo/tags` (`{"tag_name", "target", "message"}`) and `DELETE .../tags/:tag`. Test both.
- [x] Add `GET /api/v1/repos/:owner/:repo/raw/*path?ref=REF`, returning the blob's bytes from `Client.blob/3` as `application/octet-stream`, or `text/plain; charset=utf-8` when they're valid UTF-8; the ref defaults to the default branch. Test a text file, a nested path and a missing file (404).
- [!] Add `GET /api/v1/repos/:owner/:repo/contents/*path?ref=REF` (and `/contents` for the root) as Gitea's `ContentsResponse` (modules/structs/repo_file.go): for a file `name, path, sha, type: "file", size, encoding: "base64", content`; for a directory, a list of its entries without content. Test a file and a directory.
- [x] Add `GET /api/v1/repos/:owner/:repo/git/trees/:sha?recursive=true` as Gitea's `GitTreeResponse` (modules/structs/repo_tree.go) and `GET .../git/blobs/:sha` as `GitBlobResponse` (`sha, size, encoding: "base64", content`; modules/structs/git_blob.go). Test both.
- [!] Add `Storage.commit_file(path, branch, file_path, content, message, author)`, which commits one file to a branch without a work tree: `git hash-object -w --stdin`, a temporary index (`GIT_INDEX_FILE`) from `git read-tree BRANCH`, `git update-index --add --cacheinfo`, `git write-tree`, `git commit-tree -p BRANCH`, then `git update-ref` with the old sha. It also handles a branch that doesn't exist yet (no parent). Test that the commit and file appear, and that it fails if the branch moved in between.
- [!] Add `POST /api/v1/repos/:owner/:repo/contents/*path` (create; 422 when the file exists) and `PUT` (update; needs the file's current `sha`, 409 when it doesn't match), taking Gitea's `CreateFileOptions` and `UpdateFileOptions` (modules/structs/repo_file.go: `content` in base64, `message`, `branch`), using `Storage.commit_file/6`; write access required. Test create, update and a stale sha.
- [!] Add `Storage.delete_file(path, branch, file_path, message, author)` (as `commit_file`, with `git update-index --remove`) and `DELETE /api/v1/repos/:owner/:repo/contents/*path` (`{"sha", "message", "branch"}`; write access required). Test it.
- [x] Add `GET /api/v1/repos/:owner/:repo/compare/:basehead`, where basehead is `BASE...HEAD`: the commits in `BASE..HEAD` (as the commits route shows them), `total_commits`, and the changed `files` (`git diff --name-status BASE...HEAD`). Test it with two branches.
- [!] Add `GET /api/v1/repos/:owner/:repo/languages`: bytes per language on the default branch, from `git ls-tree -r -l`, mapping file extensions with a small table in a new `Nugitea.Languages` module (Elixir, Erlang, Go, Rust, JavaScript, TypeScript, Python, Ruby, C, C++, Java, Shell, HTML, CSS), as `{"Elixir": 1234}`. Test it, including that unknown extensions are left out.
- [x] Add `GET /api/v1/repos/:owner/:repo/archive/:archive`, where archive is `REF.zip` or `REF.tar.gz`, via `Storage.archive(path, ref, format)` running `git archive --prefix=NAME/`. Test that the zip starts with `PK` and the tar.gz with gzip's magic bytes.

### Access control

- [x] Add `Nugitea.Auth.Directory` (`@behaviour Nugitea.Auth`): `allow_pull?(user, repo_path)` loads accounts.json, resolves the repo with `Directory.resolve_repo/2` and is true when `Directory.effective_role/3` isn't nil; `allow_push?(user, repo_path)` is true for `:write` and above. Test a public repo, a private one, its owner and a stranger. Don't make it the default yet.
- [x] Pass the user through `Nugitea.Auth`: make `allow?/2` `allow?(service, user, repo)`, and have `Nugitea.Router`'s git routes read basic auth (the token as the password, via `Tokens.lookup_token/2`) and pass the user id: nil without a header, 401 with `WWW-Authenticate: Basic realm="nugitea"` for a bad token. The SSH caller passes nil for now. Test the router with a good and a bad token.
- [x] In `Nugitea.SSH`, pass the user whose key authenticated the session to `Nugitea.Auth.allow?/3` instead of nil, keeping that user in the connection's state. Test the lookup from key to user.
- [!] Make `Nugitea.Auth.Directory` the default authorizer, keeping `AllowAll` in the test config only where tests need it. When an anonymous git HTTP request is denied, answer 401 with `WWW-Authenticate` so git asks for credentials. Test `info/refs` for a private repo anonymously (401) and with a token (200).
- [!] Add archived repos: `Directory.set_archived(dir, repo_id, bool)`, saved in accounts.json, shown as `archived` in `GET /api/v1/repos/:owner/:repo`, settable with `PATCH` (`{"archived": true}`) and `mix nugitea repo archive PATH` / `unarchive PATH`; `Nugitea.Auth.Directory.allow_push?/2` is false for an archived repo. Test the directory, the store round trip, the PATCH and the push check.

### Repo settings

- [!] Manage topics like Gitea: `PUT /api/v1/repos/:owner/:repo/topics` (`{"topics": [...]}` replaces them), `PUT .../topics/:topic` and `DELETE .../topics/:topic`, checking each topic as Gitea does (lowercase letters, digits and dashes, starting with a letter or digit, at most 35 characters; at most 25 topics; 422 otherwise). Test valid, invalid and too many topics.
- [!] Add collaborators: `GET /api/v1/repos/:owner/:repo/collaborators` (users with a direct grant on the repo), `PUT .../collaborators/:user` (`{"permission": "read" | "write" | "admin"}`, via `Directory.grant/4`), `DELETE .../collaborators/:user` (`Directory.revoke/3`) and `GET .../collaborators/:user/permission`. Changing them needs admin. Test add, list, permission and remove.
- [!] Rename a repo with `PATCH /api/v1/repos/:owner/:repo` (`{"name": NEW}`): `Directory.rename_repo(dir, repo_id, slug)` (checked with `Nugitea.Names`; 409 when the name is taken) and `Storage.rename(from, to)` with a `Client` wrapper. Test the directory part, the storage part and the PATCH.
- [!] Transfer a repo with `POST /api/v1/repos/:owner/:repo/transfer` (`{"new_owner": LOGIN}`): `Directory.transfer_repo(dir, repo_id, owner_id)` and `Storage.rename/2`. It needs admin on the repo, and ownership of the target when that's an org. Test it.
- [x] Add forks: `Storage.fork(src, dest)` (`git clone --bare --no-local`, then the hooks that `init_bare` installs) and a `fork_of` repo id on repos in the directory, saved in accounts.json. Test the storage part and the field's round trip. (API next.)
- [x] Add `POST /api/v1/repos/:owner/:repo/forks` (optional `{"organization", "name"}`), creating a fork under the caller or the org with `Storage.fork/2` and answering 202 with the repo JSON (`fork: true`, `parent`: the source repo), and `GET .../forks`. Test both.
- [!] Add stars: `Nugitea.Stars` keeping `user_id -> [repo_id]` in stars.json in the state dir; `PUT` and `DELETE /api/v1/user/starred/:owner/:repo` (204), `GET /api/v1/user/starred/:owner/:repo` (204, or 404 when not starred), `GET /api/v1/repos/:owner/:repo/stargazers`, and `stars_count` in the repo JSON. Test them.
- [x] Add `GET /api/v1/user/blocks`, `PUT /api/v1/user/blocks/:username` and `DELETE /api/v1/user/blocks/:username` (204), using the existing `Directory.block/3` and `Directory.unblock/3`. Test block, list and unblock.

### Issues

- [!] Add issues: `Nugitea.Issues` keeping each repo's issues in issues.json in the state dir (`%{number, title, body, state: :open | :closed, author, created_at, updated_at, closed_at}`), with `create/4`, `get/3`, `list/3` (filtered by state) and `update/4`. Numbers start at 1 in each repo and are shared with pull requests, as in Gitea: a new one takes the next number after both. Test it.
- [!] Add `POST /api/v1/repos/:owner/:repo/issues` (`{"title", "body"}`; 201; authentication required), `GET .../issues?state=open|closed|all&page=P&limit=N` and `GET .../issues/:index`, in the shape of Gitea's `Issue` (modules/structs/issue.go: number, title, body, state, user.login, created_at, updated_at, closed_at, comments). Test create, the state filter, get, and 404.
- [x] Add `PATCH /api/v1/repos/:owner/:repo/issues/:index` (`{"title", "body", "state"}`; by its author or anyone with write access), setting `closed_at` when it's closed and clearing it when it's reopened. Test an edit, closing, reopening, and 403 for a user with only read access.
- [!] Add issue comments: `GET` and `POST /api/v1/repos/:owner/:repo/issues/:index/comments`, and `PATCH` and `DELETE .../issues/comments/:id` (by the comment's author or a repo admin), with ids unique in the repo, as Gitea's `Comment` (modules/structs/issue_comment.go). Include `comments` (the count) in the issue JSON. Test them.
- [!] Add repo labels: `Nugitea.Labels` (labels.json: per repo `%{id, name, color, description}`), `GET` and `POST /api/v1/repos/:owner/:repo/labels`, `PATCH` and `DELETE .../labels/:id`, as Gitea's `Label` (modules/structs/issue_label.go), accepting only `#rrggbb` colors (422 otherwise). Test them.
- [!] Put labels on issues: `GET`, `POST` (adds) and `PUT` (replaces) `/api/v1/repos/:owner/:repo/issues/:index/labels` (`{"labels": [ids]}`), `DELETE .../issues/:index/labels/:id`, and `GET .../issues?labels=a,b` filtering by label names. Deleting a repo label removes it from its issues. Test them.
- [!] Add milestones: `GET` and `POST /api/v1/repos/:owner/:repo/milestones`, `GET`, `PATCH` and `DELETE .../milestones/:id` (`title, description, due_on, state`), as Gitea's `Milestone` (modules/structs/issue_milestone.go) with `open_issues` and `closed_issues` counts; an issue's `milestone` is set through the issue PATCH. Test them.

### Pull requests

- [x] Add `GET /api/v1/repos/:owner/:repo/pulls?state=open|closed|all` and `GET .../pulls/:index`, in the shape of Gitea's `PullRequest` (modules/structs/pull.go: number, title, body, state, user, head{ref, sha}, base{ref, sha}, merged, created_at), with the branch shas from `Storage.branch_tips/1`. Test them.
- [!] Add `Storage.merge_check(path, base, head)` using `git merge-tree --write-tree BASE HEAD`: `{:ok, tree_sha}` when it merges cleanly, `{:conflict, files}` when it doesn't. Show it as `mergeable` in the pull request JSON. Test a clean merge and a conflict.
- [!] Add `Storage.merge(path, base, head, message, author, style)` for the styles `:merge` (`git commit-tree` with both parents on the `merge-tree` result), `:squash` (one parent) and `:fast_forward_only`, finishing with `git update-ref` against the base's old sha. Test all three styles and a conflict.
- [!] Add `POST /api/v1/repos/:owner/:repo/pulls/:index/merge` (`{"Do": "merge" | "squash" | "fast-forward-only", "MergeMessageField"}`; write access required), merging with `Storage.merge/6` and marking the pull request merged with `merged_at` and `merge_commit_sha` (405 when it isn't open or can't merge), and `GET .../pulls/:index/merge` (204 when merged, 404 when not). Test them.
- [!] Add `GET /api/v1/repos/:owner/:repo/pulls/:index.diff` and `.patch` (`git diff BASE...HEAD` and `git format-patch --stdout BASE..HEAD`), `GET .../pulls/:index/commits` and `GET .../pulls/:index/files`. Test them.
- [ ] Add `PATCH /api/v1/repos/:owner/:repo/pulls/:index` (`title, body, state, base`) and let the issue comment routes take a pull request's number too, since they share numbers. Test closing and reopening a pull request, and a comment on one.

### Releases

- [ ] Add releases: `Nugitea.Releases` (releases.json: per repo `%{id, tag_name, target_commitish, name, body, draft, prerelease, author, created_at, published_at}`), `GET` and `POST /api/v1/repos/:owner/:repo/releases`, and `GET`, `PATCH` and `DELETE .../releases/:id`, as Gitea's `Release` (modules/structs/release.go), creating the tag with `Storage.create_tag/4` when it doesn't exist. Test them.
- [ ] Add `GET /api/v1/repos/:owner/:repo/releases/latest` (the newest that's neither a draft nor a prerelease) and `GET .../releases/tags/:tag`, and hide drafts from users without write access. Test them.

### Webhooks and statuses

- [ ] Add `GET` and `POST /api/v1/repos/:owner/:repo/hooks`, and `GET`, `PATCH` and `DELETE .../hooks/:id`, on top of `Nugitea.Webhooks.Store` (giving hooks ids if they lack them), as Gitea's `Hook` (modules/structs/hook.go: id, type "gitea", config.url, config.content_type, events, active); admin required. Test them.
- [ ] Report pushes from the storage tier without a hook script: in `Storage.exchange` for receive-pack, snapshot `git for-each-ref` before and after, and when anything changed, send `{ref, :pushed, [%{ref, before, after}]}` to `reply_to`; the router and SSH log it. Test that a push through `Client.start_exchange` delivers the update.
- [ ] Add `Nugitea.Webhooks.Payload.push(dir, repo_id, updates, pusher)`, building Gitea's `PushPayload` (modules/structs/hook.go: ref, before, after, compare_url, commits, repository, pusher), and `Nugitea.Webhooks.sign(body, secret)`, the hex HMAC-SHA256 for the `X-Gitea-Signature` header. Test both against fixed inputs.
- [ ] Deliver push webhooks: when the storage tier reports a push, POST the payload with `:httpc` to each of the repo's active hooks (headers `X-Gitea-Event: push`, `X-Gitea-Delivery`, and `X-Gitea-Signature` when there's a secret) from a `Task.Supervisor` child, retrying 3 times with backoff. Test it against a local Bandit server.
- [ ] Add commit statuses: `Nugitea.Statuses` (statuses.json), `POST /api/v1/repos/:owner/:repo/statuses/:sha` (`state`: pending, success, error, failure or warning; `target_url`, `description`, `context`; write access required), `GET .../statuses/:sha`, and `GET .../commits/:ref/status` (the combined state: the worst of the latest status per context), as Gitea's `CommitStatus` (modules/structs/status.go). Test them.

### Users, teams, keys, mirrors

- [ ] Add `GET /api/v1/teams/:id`, `GET /api/v1/teams/:id/members`, and `PUT` and `DELETE /api/v1/teams/:id/members/:username` (org owners only), using `Directory.set_team_member/4`, as Gitea's `Team` (modules/structs/org_team.go). Test them.
- [ ] Add `GET` and `POST /api/v1/user/keys`, `DELETE /api/v1/user/keys/:id` and `GET /api/v1/users/:username/keys` on top of `Directory.add_user_key/3`, giving keys ids and SHA256 fingerprints (as `ssh-keygen -l` prints them); 422 for a malformed key. Test them.
- [ ] Add deploy keys: `Nugitea.DeployKeys` (deploy_keys.json: per repo `%{id, title, key, read_only}`), `GET` and `POST /api/v1/repos/:owner/:repo/keys` and `DELETE .../keys/:id` (admin required), as Gitea's `DeployKey` (modules/structs/repo_key.go). Test them. (SSH next.)
- [ ] Let deploy keys log in over SSH: `Nugitea.SSH.Keys.is_auth_key/3` also accepts deploy keys, and a session authenticated with one may pull only its repo, and push to it only when the key isn't read-only. Test the decision for both kinds of key and another repo.
- [ ] Add `mix nugitea mirror list`, printing `direction repo url interval` per mirror from `Nugitea.Mirror.all/0`, sorted by repo. Test it with `ExUnit.CaptureIO` and a tmp state dir.
- [ ] Add `POST /api/v1/repos/:owner/:repo/mirror-sync` (write access required), running `Nugitea.Mirror.sync/1` for the repo's pull mirror (404 when it has none), and show `mirror: true` and `original_url` in the repo JSON for pull mirrors. Test it with a file:// source repo.
- [ ] Add `POST /api/v1/repos/migrate` (`{"clone_addr", "repo_name", "repo_owner", "mirror", "private"}`): creates the repo, fetches everything from clone_addr on the storage tier (`Storage.fetch_all(path, url)`: `git fetch --prune URL +refs/*:refs/*`), and with `mirror: true` also adds a pull mirror. Test it with a file:// source repo.
- [ ] Support `auto_init` when creating repos through the API: with `{"auto_init": true, "default_branch": "main"}`, commit a README.md holding `# NAME` and the description with `Storage.commit_file/6`, and point HEAD at that branch. Test that the branch and file exist.

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
- [x] Add GET `/repos/:owner/:repo` endpoint to `Nugitea.Router` that returns comprehensive repository information similar to Gitea's API. The endpoint should return basic repository metadata including: name, owner, visibility, description, size, commit count, branch count, and permissions. This requires implementing the following in the app tier:
- [x] Add a GET /repos/:owner/:repo/topics endpoint to Nugitea.Router that returns a JSON array of topic strings for the specified repository, using existing Directory functions to retrieve the topics from accounts.json and following the patterns already established in the codebase (like the existing /repos/:owner/:repo endpoint). The implementation should:
- [!] Implement full Repository metadata response in the GET /repos/:owner/:repo endpoint to match Gitea's API structure, including proper size calculation using Git, commit count from git log, branch information, and complete permissions structure with all fields defined properly, with a corresponding test in test/nugitea/router_test.exs.
- [x] Enhance Repository Statistics API in elixir_nugitea
- [x] Add support for creating pull requests via API endpoint `POST /repos/:owner/:repo/pulls` and CLI command `mix nugitea repo create-pull-request`, which will allow users to submit a pull request from a branch or commit to another branch or repository. This feature should track PRs in the accounts directory, return PR information in the `/repos/:owner/:repo` endpoint (including commit count, size, and git metadata), and be testable with existing test infrastructure.
- [x] Implement a complete GET /repos/:owner/:repo API endpoint in Nugitea.Router that returns proper repository information including commit count, size calculated from Git history, branch count, updated permissions structure with all fields defined properly, by calling into the storage tier for metadata and using existing Directory functions to determine access, with comprehensive tests matching Gitea's API structure.
- [x] Add a PATCH /repos/:owner/:repo endpoint to Nugitea.Router that allows editing repository properties (description, visibility, website) by calling into Directory.update_repo/4 and adding the appropriate route test with Plug.Test.
- [!] Add POST /repos/:owner/:repo/topics endpoint to Nugitea.Router that supports adding a single topic to a repository (like Gitea's API) using existing storage functionality, matching Gitea's API specification exactly.
