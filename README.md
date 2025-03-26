<div align="center">
  <img src="docs/images/elixircd.png" alt="ElixIRCd" width="180">
  <h1>ElixIRCd</h1>
</div>

<p align="center">
  <a href="https://github.com/faelgabriel/elixircd/actions/workflows/elixir-ci.yml?query=branch%3Amain"><img src="https://github.com/faelgabriel/elixircd/actions/workflows/elixir-ci.yml/badge.svg?branch=main&event=push" alt="Elixir CI"></a>
  <a href="https://github.com/faelgabriel/elixircd/actions/workflows/docker-build.yml?query=branch%3Amain"><img src="https://github.com/faelgabriel/elixircd/actions/workflows/docker-build.yml/badge.svg?branch=main&event=push" alt="Docker"></a>
  <a href="https://coveralls.io/github/faelgabriel/elixircd?branch=main"><img src="https://img.shields.io/coverallsCoverage/github/faelgabriel/elixircd?label=Coverage" alt="Coveralls Status"></a>
  <a href="https://github.com/faelgabriel/elixircd/blob/main/LICENSE"><img src="https://img.shields.io/badge/License-AGPL-blue.svg" alt="License"></a>
</p>

## Introduction

**ElixIRCd** is an IRCd (Internet Relay Chat daemon) server implemented in Elixir. It is designed to provide a robust and highly concurrent IRC server environment. Its implementation makes use of the functional nature of Elixir and leverages the built-in concurrency and memory database capabilities of the Erlang VM (BEAM) and OTP (Open Telecom Platform) principles to deliver an efficient and reliable platform for IRC operations.

## Table of Contents

- [Getting Started](#getting-started)
  - [Demo Server](#demo-server)
  - [Quick Start with Docker](#quick-start-with-docker)
  - [Start from the Source Code](#start-from-the-source-code)
- [Features](#features)
  - [Commands](#commands)
  - [Modes](#modes)
  - [Services](#services)
  - [IRCv3 Specifications](#ircv3-specifications)
  - [Server Capabilities](#server-capabilities)
- [Development](#development)
- [Contributing](#contributing)
- [License](#license)

## Getting Started

Running ElixIRCd with the official Docker image is straightforward. Alternatively, you can connect to the demo server to explore its features or build your own release package from the source code.

### Demo Server

The ElixIRCd demo server is a live instance of the server, allowing you to test and experience its features.

You can connect using any IRC client like [Smuxi](https://smuxi.im/) or a web-based client such as [Kiwi IRC](https://kiwiirc.com/nextclient/irc.elixircd.org/#elixircd)

- **Server**: `irc.elixircd.org`
- **Ports**: `6667` (plaintext) and `6697` (SSL/TLS)
- **WebSocket**: `8080` (HTTP) and `8443` (HTTPS)

### Quick Start with Docker

To quickly start the ElixIRCd server using [Docker](https://docs.docker.com/get-docker/) with the official [ElixIRCd image](https://hub.docker.com/r/faelgabriel/elixircd), run the following command:

```bash
docker run \
  -p 6667:6667 -p 6697:6697 -p 8080:8080 -p 8443:8443 \
  faelgabriel/elixircd
```

#### Remote Commands

```bash
# Connects to the running system via a remote shell
docker exec -it <container_name> ./bin/elixircd remote

# Gracefully stops the running system via a remote command
docker exec -it <container_name> ./bin/elixircd stop
```

#### Configuration

You can configure ElixIRCd by creating a `elixircd.exs` file and mounting it into the Docker container at `/app/data/config/`.

1. Create a `elixircd.exs` file based on the [default configuration](http://github.com/faelgabriel/elixircd/blob/main/data/config/elixircd.exs) and customize it as desired.

2. Start the ElixIRCd server with your configuration file by mounting it into the Docker container:

   ```bash
   docker run \
     -p 6667:6667 -p 6697:6697 -p 8080:8080 -p 8443:8443 \
     -v ./elixircd.exs:/app/data/config/elixircd.exs \
     faelgabriel/elixircd
   ```

#### SSL Certificates

For development and testing environments, ElixIRCd automatically generates self-signed certificates by default for SSL listeners configured with `keyfile: "data/cert/selfsigned_key.pem"` and `certfile: "data/cert/selfsigned.pem"`.

For production environments, you should configure SSL listeners with a valid certificate and key obtained from a trusted Certificate Authority (CA), and place them in your local `data/cert` folder before mounting them into the Docker container at `/app/data/cert/`.

1. Obtain an SSL certificate and key from a trusted Certificate Authority (CA), such as [Let's Encrypt](https://letsencrypt.org/).

2. Update your `elixircd.exs` configuration file with the paths to the obtained SSL certificate files (e.g., `data/cert/fullchain.pem`, `data/cert/privkey.pem`, and `data/cert/chain.pem`) in the listener configurations, and ensure these files are located in your local `cert/` folder:

   ```elixir
   # ... other configurations
   {:tls, [
      port: 6697,
      transport_options: [
        keyfile: Path.expand("data/cert/privkey.pem"),
        certfile: Path.expand("data/cert/fullchain.pem")
      ]
    ]}
    {:https, [
      port: 8443,
      kiwiirc_client: true,
      keyfile: Path.expand("data/cert/privkey.pem"),
      certfile: Path.expand("data/cert/fullchain.pem")
    ]}
   # ... other configurations
   ```

3. Start the ElixIRCd server with your configuration and certificate files by mounting the `cert/` folder into the Docker container at `/app/data/cert/`:

   ```bash
   docker run \
     -p 6667:6667 -p 6697:6697 -p 8080:8080 -p 8443:8443 \
     -v ./elixircd.exs:/app/data/config/elixircd.exs \
     -v ./cert/:/app/data/cert/ \
     faelgabriel/elixircd
   ```

#### Listener Configurations

ElixIRCd uses [ThousandIsland](https://hexdocs.pm/thousand_island/ThousandIsland.html) for TCP and TLS listeners, and [Bandit](https://hexdocs.pm/bandit/Bandit.html) for HTTP (WS) and HTTPS (WSS) listeners.

- **TCP and TLS Listeners** (`:tcp` and `:tls`): These use [ThousandIsland](https://hexdocs.pm/thousand_island/ThousandIsland.html) as the underlying server implementation. You can configure additional options as documented in the [ThousandIsland documentation](https://hexdocs.pm/thousand_island/ThousandIsland.html#t:options/0).

  ```elixir
  {:tcp, [
    port: 6667,
    # Additional ThousandIsland options
    num_acceptors: 100,
    num_connections: 10_000,
  ]}
  ```

- **HTTP and HTTPS Listeners** (`:http` and `:https`): These use [Bandit](https://hexdocs.pm/bandit/Bandit.html) as the underlying server implementation. You can configure additional options as documented in the [Bandit documentation](https://hexdocs.pm/bandit/Bandit.html#t:options/0).

  ```elixir
  {:http, [
    port: 8080,
    # Enables the built-in KiwiIRC web client
    kiwiirc_client: true,
    # Additional Bandit options
    thousand_island_options: [
      num_acceptors: 100,
      num_connections: 10_000,
    ]
  ]}
  ```

  The `kiwiirc_client` option, when set to `true`, enables a built-in web-based IRC client powered by [KiwiIRC](https://kiwiirc.com/). This allows users to connect to your IRC server directly through a web browser without needing to install a dedicated IRC client. When enabled, the web client is accessible by navigating to the HTTP/HTTPS address of your server in a web browser. **This option is available for HTTP and HTTPS listeners only.**

#### MOTD (Message of the Day)

You can set the Message of the Day by creating a `motd.txt` file mounting it into the Docker container at `/app/data/config/`.

1. Create a `motd.txt` file with your desired message of the day.

2. Start the ElixIRCd server with your MOTD file by mounting it into the Docker container:

   ```bash
   docker run \
     -p 6667:6667 -p 6697:6697 -p 8080:8080 -p 8443:8443 \
     # ... other volume mounts
     -v ./motd.txt:/app/data/config/motd.txt \
     faelgabriel/elixircd
   ```

### Start from the Source Code

To build your own ElixIRCd release from the source code and run the server, follow these steps:

1. Set up your development environment by following the instructions in the [Development - Setting Up Your Environment](#setting-up-your-environment) section.

2. Build a release package by running the following command, replacing `0.0.1` with the desired version:

   ```bash
   APP_VERSION=0.0.1 MIX_ENV=prod mix release
   ```

3. Start the ElixIRCd server by running the generated release:

   ```bash
   _build/prod/rel/elixircd/bin/elixircd start
   ```

## Features

ElixiRCd adheres to the traditional IRC protocols as outlined in the foundational RFCs for the IRC protocol, includes integrated IRC services, and supports IRCv3 specifications.

Key RFCs include [RFC 1459](https://datatracker.ietf.org/doc/html/rfc1459) (Internet Relay Chat Protocol), [RFC 2810](https://datatracker.ietf.org/doc/html/rfc2810) (IRC: Architecture), [RFC 2811](https://datatracker.ietf.org/doc/html/rfc2811) (IRC: Channel Management), [RFC 2812](https://datatracker.ietf.org/doc/html/rfc2812) (IRC: Client Protocol), [RFC 2813](https://datatracker.ietf.org/doc/html/rfc2813) (IRC: Server Protocol), and [RFC 7194](https://datatracker.ietf.org/doc/html/rfc7194) (Default Port for IRC via TLS/SSL).

> ✅ Implemented - ✴️ Partially implemented - ❌ Not implemented

### Commands

The commands are essential to the functionality of the ElixIRCd server, following standard IRC protocol for communication between clients and the server.

- **PASS**: Set a password for the connection. ✅
- **NICK**: Set or change a user's nickname. ✅
- **USER**: Specify username, hostname, servername, and real name. ✅
- **JOIN**: Join a channel or create one if it doesn't exist. ✅
- **PART**: Leave a channel. ✅
- **MODE**: Set or unset user or channel modes. ✅
- **TOPIC**: Set or get the topic of a channel. ✅
- **NAMES**: List all visible nicknames on a channel. ❌
- **LIST**: List channels and their topics. ✅
- **INVITE**: Invite a user to a channel. ✅
- **KICK**: Eject a user from a channel. ✅
- **PRIVMSG**: Send private messages between users or to a channel. ✅
- **NOTICE**: Send a message to a user or channel without automatic reply. ✅
- **MOTD**: Request the Message of the Day from the server. ✅
- **WHOIS**: Get information about a user. ✅
- **WHO**: Get information about users on a server. ✅
- **WHOWAS**: Get information about a user who has left. ✅
- **USERHOST**: Provide information about a list of nicknames. ✅
- **USERS**: List users logged into the server. ✅
- **AWAY**: Set an away message. ✅
- **PING/PONG**: Test the presence of an active connection. ✅
- **QUIT**: Disconnect from the server. ✅
- **LUSERS**: Get statistics about the size of the network. ✅
- **ISON**: Check if specified users are online. ✅
- **VERSION**: Respond to queries about the server's version. ✴️
- **STATS**: Provide server statistics. ✅
- **INFO**: Provide information about the server. ✅
- **TIME**: Provide the server's local time. ✅
- **TRACE**: Trace routes to a specific server or user. ✅
- **ADMIN**: Provide information about the server administrator. ✅
- **OPER**: Allow operators to gain elevated privileges on the server. ✅
- **WALLOPS**: Allow operators to distribute messages to users with 'wallop' privileges. ✅
- **KILL**: Allow operators to disconnect a user from the network. ✅
- **REHASH**: Enable operators to reload the server's configuration. ✅
- **RESTART**: Allow operators to restart the server. ✅
- **DIE**: Allow operators to shut down the server. ✅

### Modes

Modes can be applied to channels or users to modify their behaviors. These can be set by users who have the appropriate permissions or automatically by the server.

#### User Modes

- **+i (Invisible)**: Hides the user from WHO searches and WHOIS searches by those not in shared channels. ✅
- **+o (Operator)**: Provides elevated privileges for network management and oversight. ✅
- **+w (Wallops)**: Enables reception of global announcements or alerts from network operators. ✅
- **+Z (Secure Connection)**: Indicates the user's connection is encrypted with SSL/TLS. ✅

#### Channel Modes

- **+b (Ban)**: Prevents a user or host from joining the channel. ✅
- **+i (Invite Only)**: Restricts channel access to invited users only. ✅
- **+k (Key)**: Requires a password to join the channel. ✅
- **+l (Limit)**: Limits the number of users who can join the channel. ✅
- **+m (Moderated)**: Only users with voice or higher can send messages to the channel. ✅
- **+n (No External Messages)**: Prevents messages from users not in the channel. ✅
- **+o (Operator)**: Grants operator status to a user. ✅
- **+p (Private)**: Hides the channel from the LIST command. ✅
- **+s (Secret)**: Hides the channel from the LIST command and WHOIS searches. ✅
- **+t (Topic)**: Restricts the ability to change the channel topic to operators only. ✅
- **+v (Voice)**: Grants voice status to a user. ✅

### Services

ElixIRCd includes integrated IRC services, eliminating the need to connect external services to the server.

- **NickServ**: Register and manage nicknames. ❌
- **ChanServ**: Register and manage channels. ❌

### IRCv3 Specifications

The IRCv3 specifications add modern capabilities to the server. For more details, visit [ircv3.net](https://ircv3.net/).

#### Enhanced Commands and Extensions

- **Capability Negotiation**: Capability negotiation mechanism between clients and servers. ✴️
- **Message Tags**: Additional metadata in messages. ❌
- **Account Authentication and Registration**: Secure SASL authentication mechanism. ❌
- **Account Tracking**: Account notifications and tagging. ❌
- **Away Notifications**: Real-time notifications of user "away" status changes. ❌
- **Batches**: Sending messages in batches. ❌
- **Bot Mode**: Identification of bots in channels. ❌
- **Changing User Properties**: Dynamic updating of user properties. ❌
- **Client-Only Tags**: Attaching metadata to messages not transmitted to the server. ❌
- **Echo Message**: Clients receive a copy of their sent messages. ❌
- **Invite Notify**: Notifications when a user is invited to a channel. ❌
- **Labeled Responses**: Associating responses with sent commands. ❌
- **Listing Users**: Enhanced user information in channel queries. ❌
- **Message IDs**: Unique identifiers for messages. ❌
- **Monitor**: Efficient tracking of user online/offline status. ❌
- **Server Time**: Timestamp information for messages. ❌
- **Standard Replies**: Standardized format for server and client replies. ❌
- **Strict Transport Security (STS)**: Automatic TLS encryption upgrade. ❌
- **UTF8ONLY**: Indication of UTF-8 only traffic support. ❌
- **WebIRC**: Provision of real IP address for users connecting through gateways. ❌
- **WebSocket Protocol**: Enabling IRC over WebSockets for web clients. ❌

#### Commands

- **CAP**: Negotiate client capabilities with the server. ✴️
- **AUTHENTICATE**: Log in to a client account using SASL authentication. ❌
- **ACCOUNT**: Notify clients of friends' new logins. ❌
- **CHGHOST**: Notify clients about changes in friends' usernames and hostnames. ❌
- **INVITE**: Alert other clients when someone is invited to a channel. ❌
- **JOIN**: Extended to include usernames and hostnames in join messages. ❌
- **MONITOR**: Track when specific nicknames enter or leave the network. ❌
- **NAMES**: List nicknames on a channel, extended to include account names. ❌
- **TAGMSG**: Send messages with tags but without text content. ❌
- **WEBIRC**: Provide real IP addresses of clients connecting through a gateway. ❌
- **WHO**: Extended to allow clients to request additional information. ❌

### Server Capabilities

- **Connection Pooling**: Efficient management of a pool of connections. ✅
- **High Concurrency**: Efficient handling of multiple connections and messages. ✅
- **Horizontal Scalability**: Ability to scale out by adding more servers to a cluster. ❌
- **Server Linking**: Ability to connect multiple servers to form a network. ❌
- **SSL/TLS Support**: Secure communication using SSL or TLS. ✅
- **IPv6 Compatibility**: Support for both IPv4 and IPv6 connections. ✅
- **Rate Limiting**: Prevent abuse by controlling message rates. ❌
- **Connection Cloaking**: Mask users' IP addresses to enhance privacy. ❌

## Development

ElixIRCd is written in Elixir, so you'll need to have Elixir and Erlang installed on your machine. We recommend using [asdf](https://asdf-vm.com/) to easily install and manage Elixir and Erlang versions. Additionally, you need to have Git installed to clone the repository.

### Setting Up Your Environment

#### Clone the Git Repository

If you don't have `Git` installed, follow the GitHub's [Install Git](https://github.com/git-guides/install-git) guide.

Clone the ElixIRCd Git repository and navigate to the project directory:

```bash
git clone https://github.com/faelgabriel/elixircd.git
cd elixircd
```

#### Install Elixir and Erlang with asdf

If you don't have `asdf` installed, follow the instructions on the [asdf website](https://asdf-vm.com/).

Add the necessary plugins and install the required versions:

```bash
# Add the Erlang plugin to asdf
asdf plugin-add erlang
# Add the Elixir plugin to asdf
asdf plugin-add elixir
# Install the versions specified in the .tool-versions file
asdf install
```

#### Install Dependencies

To install the project dependencies, run:

```bash
mix deps.get
```

### Code Quality Assurance

Ensuring code quality assurance is essential for the stability of the project. You can run all the necessary checks, including compilation warnings, code formatting, linting, security analysis, dependency audits, documentation checks, and static analysis, with a single command:

```bash
mix check.all
```

### Running Tests

To run the test suite with code coverage, use:

```bash
mix test --cover
```

### Running Server in Interactive Mode

To start ElixIRCd in interactive mode, which is useful for development and debugging, run:

```bash
iex -S mix
```

This command starts an interactive Elixir shell (IEx) with your application running, allowing you to interact with your server in real-time.

## Contributing

We welcome contributions to ElixIRCd! If you have an issue or feature request, please open an issue on the issue tracker. Additionally, feel free to pick up any open issues that haven't been assigned yet. We warmly welcome your pull requests.

Please see the [contributing guidelines](https://github.com/faelgabriel/elixircd/blob/main/CONTRIBUTING.md) for details on how to contribute to this project.

## License

This project is licensed under the [AGPL License](https://github.com/faelgabriel/elixircd/blob/main/LICENSE).
