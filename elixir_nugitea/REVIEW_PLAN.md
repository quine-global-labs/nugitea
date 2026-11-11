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
- [x] Access checks on routes that had none (in the `Nugitea.API`
      rewrite): PATCH repo and topics need admin; editing PRs and issues,
      and mirror-sync, need write; opening a PR or forking needs a login;
      forking into an org needs org ownership.
- [x] `/permissions` handles `:triage` and `:maintain`.

## 3b. Found by the e2e suite — done

`e2e/` (see its README) walks the real server and web UI, and found these
on its first runs:

- [x] `/graphql` had no body parser, so the JSON POSTs the Nuxt frontend
      sends were parsed as GraphQL text: the web UI showed nothing at all.
      Parse JSON for `/graphql` only.
- [x] The default authorizer was `AllowAll`: anyone could push to any repo
      over HTTP, and the web UI listed private repos to anonymous visitors.
      `Nugitea.Auth.Directory` is now the default; a denied anonymous git
      request gets 401 with `WWW-Authenticate`, so git retries with
      credentials (and a bad token then fails). The GraphQL schema tests
      opt back into `AllowAll`.
- [x] Query params were never fetched: `raw?ref=` crashed, and `?state=`
      (pulls) and `?q=` (search) were silently ignored. Fetched for every
      route now.
- [x] Raw and archive treated their glob params (lists) as strings. Archive
      also split `v1.0.zip` into ref `0`, and served uncompressed tar as
      gzip.
- [x] `Auth.Directory`: one `role/2` shared by pull and push.
- [x] `mix nugitea seed FILE`: declarative starting state, used by the
      e2e suite.

## 4. SSH

- [ ] `Channel.init/1` doesn't put `user_id` in its state, so
      `state.user_id` crashes on every exec. Carry the authenticated user
      over from `is_auth_key/3`.
- [x] `is_auth_key/3`: a deploy key check accepted *any* key for a user
      owning a repo with a deploy key, and user keys could never match
      (OTP passes a decoded key; stored keys are strings). Now
      `Keys.authorized?/3` decodes and compares, and handles the charlist
      login.
- [ ] Deploy keys: they no longer log in (one would act as the repo owner
      on all their repos). Support them with a per-repo check at exec time.
- [x] `Accounts.Store` saves `user_keys`, `pull_requests`, `issues`,
      `milestones` and repo `description`/`website`.

## 5. How callers use `Store.update/2`

`update/2` returns `:ok` when the change gives back just `{:ok, dir}`;
callers that match `{:ok, updated_dir}` crash with a CaseClauseError.

- [x] Router `DELETE /api/v1/repos/...` (it also deleted `nil` from disk:
      now it uses the canonical path it resolved).
- [x] The API routes (all rewritten around one `change/1` helper).
- [ ] CLI `repo set-topics` and `repo delete`.
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
- [x] Archive and raw glob params (see 3b).
- [x] Compare route: commits as maps; 400 without `...`.
- [ ] `Storage.branch/2`: `for-each-ref` matches by prefix (`feat` returns
      `feat/x`); use an exact ref. `create_branch/3` overwrites an
      existing branch; pass the zero OID as the old value.
- [ ] `commit_diff/2` on a root commit (diff against the empty tree).
      `info_refs/3` crashes on any git failure.
- [x] Forks are recorded in the directory (`fork_of`) and listed from it.
- [ ] Issue and PR IDs collide within a second; use per-repo numbers.
      (The API now converts an issue's `state` to the atom
      `update_issue/4` expects.)
- [ ] There's no route to create an issue or a milestone.
- [ ] `Tokens`: lock and write atomically like the other stores; fix the
      `||` / `|>` precedence in `list_user_tokens/2`; use URL-safe Base64.
- [x] `elixir_nugitea/data/` (accounts.json, tokens.json and the SSH host
      *private key*) is untracked and ignored. The key is still in git
      history: rotate it anywhere it was deployed.

## 7. Tests that actually test

- [x] The flaky `token create` CLI test: `router_test`, `cli_test` and
      `webhook_test` ran `async: true` while changing the global
      `:state_dir` / `:repo_root`, so they raced. They now run serially.
- [x] Router tests for find-by-canonical-name, private repo 404 vs owner
      200 (token, Bearer and basic auth), `GET /api/v1/user`, bad token
      401, owner delete.

- [x] `test/nugitea/api_test.exs`: every REST route against a real
      fixture, with exact statuses and bodies (14 of its 24 tests failed
      against the old router).
- [ ] Delete the remaining `status != 500` / `200 or 404` tests in
      `router_test.exs`, which `api_test.exs` now covers properly.
- [ ] `Auth.Directory` tests: public, private, owner, stranger (as the
      backlog asked), not just a repo that doesn't exist.

## 8. Simplifying refactors

- [x] The REST API moved to `Nugitea.API` under `/api/v1` (the old
      unprefixed `/repos/...` routes are gone): one `repo_json/3`, `with`
      chains over `{:error, status, message}`, Gitea-style JSON errors.
      Router plus API went from 3,191 lines to about 1,000.
- [x] `Auth.Directory`: one `role/2`, shared by pull and push.
- [ ] Storage: one push-detection function; parse `size/1` in one pass;
      `commits/3` returns maps, as its doc says; `archive/3` uses
      `capture/2`.
- [x] Deleted dead code: `Modules.Structs.*`, `Directory.get_branch_tip`
      (fake SHAs), `router.ex.backup`, `test_team_endpoints.exs`,
      `AGENTS_SUMMARY.md`; `SSH.Keys.get_user_key` is gone with the rewrite.
- [ ] One token-hash helper; remove the remaining no-op mappers in
      `Accounts.Store.encode/1`.
- [ ] One helper for the four JSON stores (accounts, webhooks, mirrors,
      tokens), with the lock and atomic write `Tokens` lacks.
