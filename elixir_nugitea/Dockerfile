# nugitea as a release: one node running both tiers (NUGITEA_ROLE=all, the
# default), HTTP on 3080 and SSH on 2222. State lives under /data
# (accounts, tokens, the SSH host key, the repos): mount a volume there.
#
# Admin commands run in the live node:
#   bin/nugitea rpc 'Nugitea.CLI.main(["user", "create", "alice"])'
FROM docker.io/library/elixir:1.19 AS build
ENV MIX_ENV=prod
WORKDIR /build
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile
COPY config config
COPY lib lib
COPY priv priv
RUN mix release

# The same Debian as the build image: the release carries its own Erlang,
# linked against this libc and OpenSSL.
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
COPY --from=build /build/_build/prod/rel/nugitea /app
USER nugitea
WORKDIR /data
EXPOSE 3080 2222
CMD ["/app/bin/nugitea", "start"]
