# Review plan: bugs and refactors

From a read-through of `lib/` on 2026-10-14, re-checked after pulling on
2026-10-15. The endpoints added in that pull (teams, deploy keys, repo search,
starred, milestones, mirror-sync) were only skimmed. Do these in order; each
step should come with a test that fails before the fix.

A note on the tests: many router tests only assert `status != 500` or
`200 or 404`, so they pass whether or not the route works, and some pass
only because of bug 2 (every repo 404s). Step 7 fixes that. Until then,
"tests pass" says little about the router.

## 1. Git option injection on the storage tier — done

User-supplied refs reached `git` as options. For example,
`GET /api/v1/repos/o/r/compare/--output=/tmp/x...main` wrote files on the
storage node without any login (`git log --output=`, `git diff --output=`,
`git archive --output=`).

- [x] `Storage.commits/3`, `archive/3`, `create_branch/3` reject refs that
      start with `-` (`no_leading_dash/1`); `archive/3` accepts only
      `zip | tar | tar.gz | tgz`.
- [x] `commits/3` puts the ref before the path filter's `--`. Before, a
      path filter made git read the ref as a second path and fail.
- [x] New `Storage.changed_files/3` / `Client.changed_files/3`. The
      compare route no longer passes user input to `run_git/2` and no
      longer runs `git` itself on the app tier with a relative path.
- [x] Tests in `test/nugitea/storage_test.exs`.

## 2. Repo path vs repo ID in the router — done

`Client.resolve/2` returns a canonical path (`"acme/api"`), but most routes
use it as a repo ID (`dir.repos[repo_id]`, `effective_role(dir, user,
repo_id)`), so `GET /repos/:o/:r`, `/permissions`, pulls, forks and issues
look up the wrong key. Routes also build `"#{owner}/#{repo}"` from the URL
instead of the canonical path, so `ACME/api` fails on a case-sensitive disk.

Worse than first thought: `Client.resolve/2` also requires a `.git`
suffix, so every one of these routes returned 404 for every repo.

- [x] New `find_repo/4` in the router returns `{id, canonical_path}`, or
      nil when the repo is missing or the caller can't see it. All 24
      routes use the ID for the directory and the path for storage. This
      also adds the read check that branches, raw, archive, diff and
      compare never had (they were only safe because they always 404'd).
- [x] A repo that was never PATCHed no longer raises a KeyError on
      `description` / `website`.

## 3. Authentication

- [x] `authenticate` plug: sets `conn.assigns.user_id` from
      `Authorization: token|Bearer` or basic auth (`Tokens.lookup_token/2`);
      nil when no header is sent, 401 with `WWW-Authenticate` for a bad token.
- [x] `GET /api/v1/user` uses that user instead of hard-coded `nil`.
- [x] The git HTTP routes pass that user to `Nugitea.Auth.allow?/3`.
- [ ] Add access checks to routes that have none: `PATCH /repos/:o/:r`
      (anyone can change visibility), creating and editing PRs, forks.
      Issue PATCH should need write access, not read.
- [ ] `/permissions`: handle `:triage` and `:maintain` (CaseClauseError).

## 4. SSH

- [ ] `Channel.init/1` doesn't put `user_id` in its state, so
      `state.user_id` crashes on every exec. Carry the authenticated user
      over from `is_auth_key/3`.
- [ ] `is_auth_key/3` gets the username as a charlist; convert it before
      calling `Directory.resolve/2`.
- [ ] Save `user_keys` in `Accounts.Store` (with `pull_requests`, `issues`,
      repo `description`/`website`), or keys are lost on the next save.

## 5. How callers use `Store.update/2`

`update/2` returns `:ok` when the change gives back just `{:ok, dir}`;
callers that match `{:ok, updated_dir}` crash with a CaseClauseError.

- [x] Router `DELETE /api/v1/repos/...` (it also deleted `nil` from disk:
      now it uses the canonical path it resolved).
- [ ] CLI `repo set-topics` and `repo delete`; router `PATCH /repos/:o/:r`,
      `PATCH .../pulls/:index`, `PATCH .../issues/:index`. These are now
      reachable, so they crash instead of returning 404.
- [ ] CLI `grant` and `user add-key` pass `fn _ -> new_dir end` (a bare
      struct, not `{:ok, dir}`), so nothing is saved, and they load outside
      the lock. Do the change inside the update function.
- [ ] CLI `team create` (passes the org path as the team path),
      `team add-member` (looks the team up with `D.resolve`, which only
      knows accounts), `grant` (uses `D.resolve` for repos, a string role,
      always a user principal and a repo resource). Make unknown names
      fail instead of passing `nil` along.

## 6. Other correctness

- [ ] Push detection in `Storage.exchange/5`: the "after" snapshot uses
      the relative repo path; compare to the `{:ok, refs}` tuple; check
      only on `:DOWN`; report deleted refs; hook it to webhooks.
      `Webhooks.Payload.push/4` crashes on `[]` and hard-codes the owner.
- [ ] Archive route: `*archive` is a list; split the ref from a
      `.zip`/`.tar.gz` suffix (refs may contain dots) and pass `tar.gz`.
      Raw route: `*path` is a list; join it with `/`.
- [ ] Compare route: JSON-encode commits as maps (keyword lists crash
      Jason); return 400 when there's no `...` (MatchError today).
- [ ] `Storage.branch/2`: `for-each-ref` matches by prefix (`feat` returns
      `feat/x`); use an exact ref. `create_branch/3` overwrites an
      existing branch; pass the zero OID as the old value.
- [ ] `commit_diff/2` on a root commit (diff against the empty tree).
      `info_refs/3` crashes on any git failure.
- [ ] Forks: record the fork in the directory (`fork_of`); `GET .../forks`
      should read `fork_of`, not `:parent`.
- [ ] Issue and PR IDs collide within a second; use per-repo numbers.
      `update_issue/4` compares the state against atoms but receives
      strings.
- [ ] `Tokens`: lock and write atomically like the other stores; fix the
      `||` / `|>` precedence in `list_user_tokens/2`; use URL-safe Base64.
- [ ] `data/tokens.json` and `test_team_endpoints.exs` were committed by
      the loop; probably remove them and add `data/` to `.gitignore`.

## 7. Tests that actually test

- [x] The flaky `token create` CLI test: `router_test`, `cli_test` and
      `webhook_test` ran `async: true` while changing the global
      `:state_dir` / `:repo_root`, so they raced. They now run serially.
- [x] Router tests for find-by-canonical-name, private repo 404 vs owner
      200 (token, Bearer and basic auth), `GET /api/v1/user`, bad token
      401, owner delete.

- [ ] Rewrite the router tests that assert `status != 500` or
      `200 or 404` to set up a real repo and assert exact statuses and
      bodies.
- [ ] `Auth.Directory` tests: public, private, owner, stranger (as the
      backlog asked), not just a repo that doesn't exist.

## 8. Simplifying refactors

- [ ] One `repo_json(dir, id, role)`, used by every route that returns a
      repo (about 70 lines are currently copied 6+ times).
- [ ] A `json/3` helper, plus `with` chains over `{:error, status, msg}`
      (as the git routes do), to flatten the nested `case`s. Move the API
      into `Nugitea.API` under `/api/v1`, so `/repos/...` and
      `/api/v1/repos/...` are no longer mixed.
- [ ] `Auth.Directory`: one `role_for/2`, shared by pull and push.
- [ ] Storage: one push-detection function; parse `size/1` in one pass;
      `commits/3` returns maps, as its doc says; `archive/3` uses
      `capture/2`.
- [ ] `SSH.Keys.get_user_key` → `Enum.find`; one token-hash helper;
      remove the no-op mappers in `Accounts.Store.encode/1`; update the
      out-of-date moduledocs; use or delete the `Modules.Structs.*` structs.
