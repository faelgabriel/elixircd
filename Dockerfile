# ---- Build Application Stage ----
# This stage builds the application by compiling the source code and generating a release.
FROM elixir:1.17.2-otp-27-alpine AS build

ENV LANG=C.UTF-8

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

# ---- Runtime Application Stage ----
# This stage sets up the environment to run the built application with a minimal image size.
FROM elixir:1.17.2-otp-27-alpine AS runtime

WORKDIR /app
RUN mkdir -p /app/priv
RUN chown -Rf nobody /app

COPY --from=build --chown=nobody:root /app/_build/prod/rel/elixircd /app

VOLUME /app/priv/

USER nobody

CMD ["./bin/elixircd", "start"]
