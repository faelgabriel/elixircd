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
  - [Server Features](#server-features)
- [Development](#development)
- [Contributing](#contributing)
- [License](#license)

## Getting Started

Running ElixIRCd with the official Docker image is straightforward. Alternatively, you can connect to the demo server to explore its features or build your own release package from the source code.

### Demo Server

The ElixIRCd demo server is a live instance of the server, allowing you to test and experience its features.

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

You can configure ElixIRCd by creating a `elixircd.exs` file and mounting it into the Docker container at `/app/config/`.

1. Create a `elixircd.exs` file based on the [default configuration](http://github.com/faelgabriel/elixircd/blob/main/config/elixircd.exs) and customize it as desired.

2. Start the ElixIRCd server with your configuration file by mounting it into the Docker container:

   ```bash
   docker run \
     -p 6667:6667 -p 6697:6697 -p 8080:8080 -p 8443:8443 \
     -v ./elixircd.exs:/app/config/elixircd.exs \
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
      keyfile: Path.expand("data/cert/privkey.pem"),
      certfile: Path.expand("data/cert/fullchain.pem")
    ]}
   # ... other configurations
   ```

3. Start the ElixIRCd server with your configuration and certificate files by mounting the `cert/` folder into the Docker container at `/app/data/cert/`:

   ```bash
   docker run \
     -p 6667:6667 -p 6697:6697 -p 8080:8080 -p 8443:8443 \
     -v ./elixircd.exs:/app/config/elixircd.exs \
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
    # Additional Bandit options
    thousand_island_options: [
      num_acceptors: 100,
      num_connections: 10_000,
    ]
  ]}
  ```

#### MOTD (Message of the Day)

You can set the Message of the Day by creating a `motd.txt` file mounting it into the Docker container at `/app/config/`.

1. Create a `motd.txt` file with your desired message of the day.

2. Start the ElixIRCd server with your MOTD file by mounting it into the Docker container:

   ```bash
   docker run \
     -p 6667:6667 -p 6697:6697 -p 8080:8080 -p 8443:8443 \
     # ... other volume mounts
     -v ./motd.txt:/app/config/motd.txt \
     faelgabriel/elixircd
   ```

#### Full Configuration Example

Check the [default configuration](http://github.com/faelgabriel/elixircd/blob/main/config/elixircd.exs) for a full configuration example.

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
- **NAMES**: List all visible nicknames on a channel. ✅
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
- **ACCEPT**: Manage a list of users allowed to bypass +g (Caller ID) restrictions. ✅
- **PING/PONG**: Test the presence of an active connection. ✅
- **QUIT**: Disconnect from the server. ✅
- **LUSERS**: Get statistics about the size of the network. ✅
- **ISON**: Check if specified users are online. ✅
- **SILENCE**: Manage a list of users whose messages are blocked. ✅
- **VERSION**: Respond to queries about the server's version. ✅
- **STATS**: Provide server statistics. ✅
- **INFO**: Provide information about the server. ✅
- **TIME**: Provide the server's local time. ✅
- **TRACE**: Trace routes to a specific server or user. ✅
- **ADMIN**: Provide information about the server administrator. ✅
- **OPER**: Allow operators to gain elevated privileges on the server. ✅
- **WALLOPS**: Allow operators to distribute messages to users with 'wallop' privileges. ✅
- **OPERWALL**: Send messages to operators only. ✅
- **GLOBOPS**: Send global operator messages to all operators on the network. ✅
- **KILL**: Allow operators to disconnect a user from the network. ✅
- **REHASH**: Enable operators to reload the server's configuration. ✅
- **RESTART**: Allow operators to restart the server. ✅
- **DIE**: Allow operators to shut down the server. ✅

### Modes

Modes can be applied to channels or users to modify their behaviors. These can be set by users who have the appropriate permissions or automatically by the server.

#### User Modes

These modes apply to users globally, affecting their visibility, privileges, and access across the server.

- **+B (Bot)**: Marks the user as a bot. ✅
- **+g (Caller ID)**: Blocks private messages from users not on your accept list. ✅
- **+H (Hide Operator)**: Hides operator status from non-operators in WHOIS. ✅
- **+i (Invisible)**: Hides the user from WHO and WHOIS searches by those not in shared channels. ✅
- **+o (Operator)**: Provides elevated privileges for network management and oversight. ✅
- **+p (Hide channels)**: Hides channels the user is in from WHOIS except for shared channels. ✅
- **+r (Registered)**: Indicates the user is registered and identified with services. ✅
- **+R (Registered Only)**: Only allows messages from registered users. ✅
- **+s (Snomask)**: Allows reception of server notices. ✅
- **+w (Wallops)**: Enables reception of global announcements or alerts from network operators. ✅
- **+x (Cloaked Hostname)**: Masks the user's hostname for privacy. ✅
- **+Z (Secure Connection)**: Indicates the user's connection is encrypted with SSL/TLS. ✅

#### Channel Modes

These modes apply to channels and define behavior, restrictions, and access rules.

- **+C (No CTCP)**: Blocks CTCP messages to the channel. ✅
- **+c (No Colors)**: Blocks messages with colors. ✅
- **+d (Delay Message)**: Requires users to wait before sending messages after joining. ✅
- **+i (Invite Only)**: Restricts channel access to invited users only. ✅
- **+j (Join Throttle)**: Limits the rate of joins to the channel. ✅
- **+k (Key)**: Requires a password to join the channel. ✅
- **+l (Limit)**: Limits the number of users who can join the channel. ✅
- **+m (Moderated)**: Only users with voice or higher can send messages to the channel. ✅
- **+M (Registered Only Speak)**: Only registered users may speak. ✅
- **+n (No External Messages)**: Prevents messages from users not in the channel. ✅
- **+O (Oper Only)**: Restricts channel access to IRC operators only. ✅
- **+p (Private)**: Hides the channel from the LIST command. ✅
- **+r (Registered Channel)**: Indicates the channel is registered with services. ✅
- **+R (Registered Only Join)**: Only registered users may join the channel. ✅
- **+s (Secret)**: Hides the channel from the LIST command and WHOIS searches. ✅
- **+t (Topic)**: Restricts topic changes to users with operator privileges. ✅
- **+T (No NOTICEs)**: Blocks NOTICE messages in the channel. ✅
- **+u (Auditorium)**: Hides join/part/quit messages except for users with voice or higher. ✅
- **+z (Secure Only)**: Restricts channel access to users with secure connections only. ✅

#### Channel List Modes

These modes use lists to manage exceptions and access control in channels.

- **+b (Ban)**: Prevents a user or host from joining the channel. ✅
- **+e (Ban Exception)**: Exempts users from channel bans. ✅
- **+I (Invite Exception)**: Exempts users from invite-only restriction. ✅

#### Channel User Modes

These modes are assigned to users within a specific channel and determine their privileges or status.

- **+o (Operator)**: Grants standard moderator privileges. ✅
- **+v (Voice)**: Allows speaking in moderated channels. ✅

### Services

ElixIRCd includes integrated IRC services, eliminating the need to connect external services to the server.

#### NickServ

NickServ allows users to register and manage nicknames, providing authentication and nickname protection services.

- **HELP**: Display help information and available commands. ✅
- **REGISTER**: Register a nickname with a password. ✅
- **VERIFY**: Verify a registered nickname via email confirmation. ✅
- **IDENTIFY**: Authenticate with a registered nickname. ✅
- **LOGOUT**: Log out from a registered nickname. ✅
- **GHOST**: Disconnect a user using your registered nickname. ✅
- **REGAIN**: Regain your registered nickname from another user. ✅
- **RELEASE**: Release a nickname that is being held for you. ✅
- **RECOVER**: Forcefully disconnect another user using nickname and reclaim it. ❌
- **DROP**: Delete a registered nickname permanently. ✅
- **INFO**: Display information about a registered nickname. ✅
- **SET**: Configure settings for your registered nickname. ✅
- **ACCESS**: Manage the access list for your nickname. ❌
- **ALIST**: Display channels or nicknames associated with your account. ❌
- **STATUS**: Check the identification status of one or more nicknames. ❌
- **GROUP**: Group a nickname with your current registered nickname. ❌
- **UNGROUP**: Remove a nickname from your group. ❌
- **LISTCHANS**: List channels where you have access. ❌

#### ChanServ

ChanServ allows users to register and manage channels, providing channel administration and access control services.

- **HELP**: Display help information and available commands. ✅
- **REGISTER**: Register a channel with ChanServ. ✅
- **DROP**: Delete a registered channel permanently. ✅
- **INFO**: Display information about a registered channel. ✅
- **SET**: Configure settings for a registered channel. ✅
- **TRANSFER**: Transfer ownership of a registered channel to another user. ✅
- **ACCESS**: Manage the channel access list. ❌
- **ALIST**: Display channel access list entries. ❌
- **FLAGS**: Manage user flags and permissions for the channel. ❌
- **OP**: Grant operator status to a user in the channel. ❌
- **DEOP**: Remove operator status from a user in the channel. ❌
- **VOICE**: Grant voice status to a user in the channel. ❌
- **DEVOICE**: Remove voice status from a user in the channel. ❌
- **KICK**: Kick a user from the channel. ❌
- **BAN**: Ban a user or hostmask from the channel. ❌
- **UNBAN**: Remove a ban on a user or hostmask. ❌
- **INVITE**: Invite a user to the channel. ❌
- **TOPIC**: Change the channel topic. ❌
- **CLEAR**: Clear various channel settings (modes, bans, ops, etc.). ❌
- **STATUS**: Check a user's access level in the channel. ❌
- **SYNC**: Synchronize channel modes with the access list. ❌

### IRCv3 Specifications

The IRCv3 specifications add modern capabilities to the server. For more details, visit [ircv3.net](https://ircv3.net/).

#### Enhanced Commands and Extensions

- **Capability Negotiation**: Capability negotiation mechanism between clients and servers. ✅
- **Bot Mode**: Identification of bots in channels. ✅
- **Changing User Properties**: Dynamic updating of user properties. ✅
- **Listing Users**: Enhanced user information in channel queries. ✅
- **WebIRC**: Provision of real IP address for users connecting through gateways. ✅
- **WebSocket Protocol**: Enabling IRC over WebSockets for web clients. ✅

#### Commands

- **CAP**: Negotiate client capabilities with the server. ✅
- **AUTHENTICATE**: Authenticate a user using SASL mechanisms. ❌
- **ACCOUNT**: Notify clients when a user's account status changes. ✅
- **CHGHOST**: Forcefully change a user's ident and hostname. ✅
- **INVITE**: Extended to optionally include account information. ❌
- **JOIN**: Extended to include account name and real name in join messages. ❌
- **MONITOR**: Track when specific nicknames go online or offline. ❌
- **NAMES**: Extended to include account names when supported. ✅
- **TAGMSG**: Send messages with tags but without text content. ✅
- **WEBIRC**: Allow gateways to pass real client IP and hostname to the server. ✅
- **WHO**: Extended to include additional information (WHOX). ❌
- **BATCH**: Group related messages for batch delivery. ❌
- **SETNAME**: Allow clients to change their real name (GECOS). ✅

#### Capabilities

- **Account Authentication and Registration** (sasl): Secure SASL authentication mechanism. ❌
- **Account Tag** (account-tag): Attach account name to messages via IRCv3 message tags. ✅
- **Account Tracking** (account-notify): Account notifications and tagging. ✅
- **Away Notifications** (away-notify): Real-time notifications of user "away" status changes. ✅
- **Batches** (batch): Sending messages in batches. ❌
- **Capability Notifications** (cap-notify): Notify clients when server capabilities change dynamically. ❌
- **Change Host** (chghost): Real-time notifications when a user's hostname changes. ✅
- **Client-Only Tags** (client-tags): Attaching metadata to messages not transmitted to the server. ✅
- **Echo Message** (echo-message): Clients receive a copy of their sent messages. ❌
- **Extended Join** (extended-join): Extended JOIN messages with account name and real name. ❌
- **Extended Names** (uhnames): Adds full user hostmasks to NAMES replies. ✅
- **Extended User Mode** (extended-uhlist): Adds additional user modes in WHO and related replies. ✅
- **Invite Notify** (invite-notify): Notifications when a user is invited to a channel. ❌
- **Labeled Responses** (labeled-response): Associating responses with sent commands. ❌
- **Message IDs** (msgid): Unique identifiers for messages. ✅
- **Message Tags** (message-tags): Additional metadata in messages. ✅
- **Monitor** (monitor): Efficient tracking of user online/offline status. ❌
- **Multi-Prefix** (multi-prefix): Display multiple status prefixes for users in channel responses. ✅
- **Server Time** (server-time): Timestamp information for messages. ✅
- **Set Name** (setname): Allow clients to change their real name during the session. ✅
- **Standard Replies** (standard-replies): Standardized format for server and client replies. ❌
- **Strict Transport Security (sts)** (sts): Automatic TLS encryption upgrade. ❌
- **UTF-8 Only** (utf8only): Configurable support for UTF-8 only traffic. ✅

### Server Features

- **Connection Pooling**: Efficient management of a pool of connections. ✅
- **High Concurrency**: Efficient handling of multiple connections and messages. ✅
- **Horizontal Scalability**: Ability to scale out by adding more servers to a cluster. ❌
- **Server Linking**: Ability to connect multiple servers to form a network. ❌
- **SSL/TLS Support**: Secure communication using SSL or TLS. ✅
- **IPv6 Compatibility**: Support for both IPv4 and IPv6 connections. ✅
- **Rate Limiting**: Prevent floods of connections and messages with burst support. ✅
- **Connection Cloaking**: Mask users' IP addresses to enhance privacy. ✅

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
mix check
```

### Running Tests

To run the test suite with code coverage, use:

```bash
mix test --cover
```

### Building and Running the Docker Image Locally

To build and run the ElixIRCd Docker image locally, use:

```bash
docker build -t elixircd .
docker run -p 6667:6667 -p 6697:6697 -p 8080:8080 -p 8443:8443 elixircd
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
