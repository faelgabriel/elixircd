# ---- Base Stage ----
# This stage sets up the base environment for both development and production stages.
FROM elixir:1.15.7-otp-25-alpine AS base

ENV LANG=C.UTF-8

RUN apk update && \
    apk add make

RUN mix local.hex --force && \
    mix local.rebar --force

WORKDIR /app

COPY mix.exs mix.lock ./

# ---- Development Stage ----
# This stage installs and compiles dependencies for the development environment.
FROM base AS development

ENV MIX_ENV=dev

RUN mix deps.get && \
    mix deps.compile

# Create certificate for SSL (self-signed for development)
RUN make ssl_keys

CMD ["/bin/sh"]

# ---- Production Build Application Stage ----
# This stage builds the production application by compiling the source code and generating a release.
FROM base AS production-build

ENV MIX_ENV=prod

RUN mix deps.get --only prod && \
    mix deps.compile

COPY config config/
COPY lib lib/

RUN mix do compile, release

# Create certificate for SSL (TODO: use Let's Encrypt for production)
RUN make ssl_keys

# ---- Production Run Application Stage ----
# This stage sets up the environment to run the built application in production, with a minimal image size.
FROM elixir:1.15.7-otp-25-alpine AS production

WORKDIR /app
RUN chown nobody /app

COPY --from=production-build --chown=nobody:root /app/_build/prod/rel/elixircd /app

USER nobody

CMD ["./bin/elixircd", "start"]
