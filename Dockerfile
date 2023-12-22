# ---- Base Stage ----
# This stage sets up the base environment for both development and production stages.
FROM elixir:1.15.7-otp-25-alpine AS base

ENV LANG=C.UTF-8

RUN apk update && \
    apk --no-cache add openssl make

RUN mix local.hex --force && \
    mix local.rebar --force

WORKDIR /app

COPY mix.exs mix.lock ./

# ---- Development Stage ----
# This stage installs and compiles dependencies for the development environment.
FROM base AS development

EXPOSE 6667
EXPOSE 6697

ENV MIX_ENV=dev

RUN mix deps.get && \
    mix deps.compile

CMD ["/bin/sh"]

# ---- Production Build Application Stage ----
# This stage builds the production application by compiling the source code and generating a release.
FROM base AS production-build

ENV MIX_ENV=prod

RUN mix deps.get && \
    mix deps.compile

COPY config config/
COPY lib lib/

RUN mix do compile, release

# ---- Production Run Application Stage ----
# This stage sets up the environment to run the built application in production with a minimal image size.
FROM elixir:1.15.7-otp-25-alpine AS production

EXPOSE 6667
EXPOSE 6697

WORKDIR /app
RUN chown nobody /app

COPY --from=production-build --chown=nobody:root /app/_build/prod/rel/elixircd /app

USER nobody

CMD ["./bin/elixircd", "start"]
