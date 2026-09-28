# Alpine 3.24's musl rejects OTP's signal stack on some CPUs.
ARG ELIXIR_IMAGE=hexpm/elixir:1.20.4-erlang-29.0.6-alpine-3.23.5
ARG RUNTIME_IMAGE=alpine:3.23

# Build release
FROM ${ELIXIR_IMAGE} AS build

ENV LANG=C.UTF-8 MIX_ENV=prod

RUN apk upgrade --no-cache && \
    apk add --no-cache make gcc musl-dev ca-certificates

WORKDIR /app

COPY mix.exs mix.lock ./
COPY config config/

RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get --only prod --check-locked && \
    mix deps.compile

COPY lib lib/
COPY bin bin/
COPY rel rel/

ARG APP_VERSION
ENV APP_VERSION=${APP_VERSION}

RUN mix compile --warnings-as-errors && \
    mix release

# Run release
FROM ${RUNTIME_IMAGE} AS runtime

ENV LANG=C.UTF-8

RUN apk upgrade --no-cache && \
    apk add --no-cache ca-certificates libstdc++ ncurses-libs libcrypto3 libssl3 lksctp-tools

WORKDIR /app
RUN mkdir -p /app/data && \
    chown nobody:nogroup /app/data

COPY --from=build /app/_build/prod/rel/elixircd /app

VOLUME /app/data/

USER nobody:nogroup

CMD ["./bin/elixircd", "start"]
