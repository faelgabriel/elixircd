# Build Application Stage: Builds the application by compiling the source code and generating a release.
FROM elixir:1.19.3-otp-28-alpine AS build

ENV LANG=C.UTF-8

RUN apk add --no-cache make gcc musl-dev

WORKDIR /app

COPY mix.exs mix.lock ./

ARG APP_VERSION
ENV APP_VERSION=${APP_VERSION}

ENV MIX_ENV=prod

RUN mix deps.get && \
    mix deps.compile

COPY config config/
COPY lib lib/

RUN mix do compile, release

# Runtime Application Stage: Sets up the environment to run the built application with a minimal image size.
FROM elixir:1.19.3-otp-28-alpine AS runtime

WORKDIR /app
RUN mkdir -p /app/data
RUN chown -Rf nobody /app

COPY --from=build --chown=nobody:root /app/_build/prod/rel/elixircd /app

VOLUME /app/data/

USER nobody

CMD ["./bin/elixircd", "start"]
