# End-to-end tests

One Cypress walkthrough of nugitea as its users see it, against a real
server and the real web frontend:

1. browse the seeded repos and an org in the web UI (private repos hidden);
2. push a commit over smart HTTP: a bad token is refused, the owner's works;
3. read the pushed files in the web UI and through the REST API;
4. check a private repo 404s for anonymous callers and other users;
5. delete a repo: refused for a non-owner, done for the owner.

## Running

```sh
nix run .#e2e                 # headless
nix run .#e2e -- --headed     # extra arguments go to `cypress run`
```

That's the whole setup. The flake pins Elixir, Node and git; Cypress is
pinned by `package-lock.json`. Everything else is provisioned per run by
[`run.sh`](run.sh):

- a fresh temp dir holds all server state (accounts.json, tokens.json, the
  bare repos, the SSH host key) and is removed afterwards;
- [`seed.json`](seed.json) declares the starting state (users, orgs and
  their members, repos and their visibility, who gets an API token) and is
  applied with `mix nugitea seed`, which prints the issued tokens for the
  spec to read;
- nugitea (`mix nugitea serve`) and the Nuxt frontend
  (`rust_nugitea/web`, built and run from `.output`) start on their own
  ports and are stopped at the end;
- git runs with no user or system config, `main` as the default branch,
  and no credential prompts.

Ports default to 3080 (HTTP), 2223 (SSH) and 3000 (web); override them with
`NUGITEA_E2E_HTTP_PORT`, `NUGITEA_E2E_SSH_PORT` and `NUGITEA_E2E_WEB_PORT`.

To work on the spec interactively, start the servers as `run.sh` does, then
`npx cypress open` here with the same `NUGITEA_E2E_*` variables
(see `cypress.config.js`).

## Notes

- The tests in `cypress/e2e/flow.cy.js` run in order and build on each
  other: server state carries over, only the browser is reset.
- Cypress 16 removed `Cypress.env()` and `cy.exec()`: values come in through
  `expose` in `cypress.config.js`, and git runs through the `git` task
  (Node `spawnSync`, no shell).
- Verified on macOS (aarch64-darwin). On Linux, the Cypress binary npm
  downloads needs the usual system libraries (GTK, NSS, ...), which NixOS
  doesn't provide globally.
