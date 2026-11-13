# The deployed image (nugitea.in.quineglobal.com): the Elixir server and the
# Nuxt frontend in one image, so they're always built from the same commit
# and pinned, bumped and deployed together. petersweb-infra runs it as two
# containers (nixos/arion-nugitea):
#
#   /app/bin/nugitea start                 the server: HTTP on 3080, SSH on
#                                          2222, state under /data (the default)
#   node /web/.output/server/index.mjs     the frontend, on 3000
#
# Built by .forgejo/workflows/images.yml. elixir_nugitea/Dockerfile and
# rust_nugitea/web/Dockerfile still build each on its own, for local runs.

FROM docker.io/library/elixir:1.19 AS server
ENV MIX_ENV=prod
WORKDIR /build
RUN mix local.hex --force && mix local.rebar --force
COPY elixir_nugitea/mix.exs elixir_nugitea/mix.lock ./
RUN mix deps.get --only prod && mix deps.compile
COPY elixir_nugitea/config config
COPY elixir_nugitea/lib lib
COPY elixir_nugitea/priv priv
RUN mix release

FROM docker.io/library/node:22-slim AS web
WORKDIR /build
COPY rust_nugitea/web/package.json rust_nugitea/web/package-lock.json ./
RUN npm install
COPY rust_nugitea/web/ .
RUN npm run build

# The same Debian as the server's build image: the release carries its own
# Erlang, linked against this libc and OpenSSL. The frontend needs only the
# node binary: Nuxt's .output bundles its dependencies.
FROM docker.io/library/debian:trixie-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends git openssh-client ca-certificates libssl3t64 libstdc++6 libncurses6 locales \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen
# erlexec needs SHELL set, or its helper exits at start (status 4).
ENV LANG=en_US.UTF-8 \
    SHELL=/bin/sh \
    NUGITEA_REPO_ROOT=/data/repos \
    NUGITEA_STATE_DIR=/data \
    NUGITEA_SSH_HOST_KEY_DIR=/data/ssh
# erlexec, which runs git, won't run as root.
RUN useradd --uid 10001 --home-dir /data --no-create-home nugitea \
    && mkdir /data && chown nugitea /data
COPY --from=web /usr/local/bin/node /usr/local/bin/node
COPY --from=web /build/.output /web/.output
COPY --from=server /build/_build/prod/rel/nugitea /app
USER nugitea
WORKDIR /data
EXPOSE 3080 2222 3000
CMD ["/app/bin/nugitea", "start"]
