ARG ELIXIR_IMAGE=hexpm/elixir:1.20.4-erlang-29.0.6-alpine-3.24.1

# Build release
FROM ${ELIXIR_IMAGE} AS build

ENV LANG=C.UTF-8

RUN apk upgrade --no-cache && \
    apk add --no-cache make gcc musl-dev

WORKDIR /app

COPY mix.exs mix.lock ./

ARG APP_VERSION
ENV APP_VERSION=${APP_VERSION}

ENV MIX_ENV=prod

RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get --check-locked && \
    mix deps.compile

COPY config config/
COPY lib lib/

RUN mix compile --warnings-as-errors && \
    mix release

# Run release
FROM ${ELIXIR_IMAGE} AS runtime

WORKDIR /app
RUN apk upgrade --no-cache && \
    mkdir -p /app/data && \
    chown -Rf nobody /app

COPY --from=build --chown=nobody:root /app/_build/prod/rel/elixircd /app

VOLUME /app/data/

USER nobody

CMD ["./bin/elixircd", "start"]
