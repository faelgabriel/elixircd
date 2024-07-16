# ---- Build Application Stage ----
# This stage builds the application by compiling the source code and generating a release.
FROM elixir:1.16.3-otp-26-alpine AS build

ENV LANG=C.UTF-8

RUN apk update && \
    apk --no-cache add build-base make

RUN mix local.hex --force && \
    mix local.rebar --force

WORKDIR /app

COPY mix.exs mix.lock ./

ENV MIX_ENV=prod

RUN mix deps.get && \
    mix deps.compile

COPY config config/
COPY lib lib/

RUN mix do compile, release

# ---- Runtime Application Stage ----
# This stage sets up the environment to run the built application with a minimal image size.
FROM elixir:1.16.1-otp-26-alpine AS runtime

EXPOSE 6667 6668 6697 6698

WORKDIR /app
RUN chown nobody /app

COPY --from=build --chown=nobody:root /app/_build/prod/rel/elixircd /app

VOLUME /app/priv/

USER nobody

CMD ["./bin/elixircd", "start"]
