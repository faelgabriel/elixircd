<h1 align="center">ElixIRCd</h1>

<p align="center">
  <a href="https://github.com/faelgabriel/elixircd/actions/workflows/elixir-ci.yml?query=branch%3Amain"><img src="https://github.com/faelgabriel/elixircd/actions/workflows/elixir-ci.yml/badge.svg?branch=main&event=push" alt="Elixir CI"></a>
  <a href="https://github.com/faelgabriel/elixircd/actions/workflows/docker-build.yml?query=branch%3Amain"><img src="https://github.com/faelgabriel/elixircd/actions/workflows/docker-build.yml/badge.svg?branch=main&event=push" alt="Docker"></a>
  <a href="https://coveralls.io/github/faelgabriel/elixircd?branch=main"><img src="https://img.shields.io/coverallsCoverage/github/faelgabriel/elixircd?label=Coverage" alt="Coveralls Status"></a>
  <a href="https://github.com/faelgabriel/elixircd/blob/main/LICENSE"><img src="https://img.shields.io/badge/License-AGPL-blue.svg" alt="License"></a>
</p>

## Introduction

ElixIRCd is an IRCd (Internet Relay Chat daemon) server implemented in Elixir. It is designed to provide a robust and highly concurrent IRC server environment. Its implementation makes use of the functional nature of Elixir and leverages the built-in concurrency and memory database capabilities of the Erlang VM (BEAM) and OTP (Open Telecom Platform) principles to deliver an efficient and reliable platform for IRC operations.

## Quick Start

To quickly start the ElixIRCd server using [Docker](https://docs.docker.com/get-docker/), run the following command:

```bash
docker run \
  -p 6667:6667 -p 6668:6668 -p 6697:6697 -p 6698:6698 \
  faelgabriel/elixircd
```

### Configuration

You can configure ElixIRCd by creating a `runtime.exs` file and mounting it into the Docker container at `/app/config/`.

1. Create a `runtime.exs` file based on the [default configuration](http://github.com/faelgabriel/elixircd/blob/main/config/runtime.exs), and customize it as needed.

2. Start the ElixIRCd server with your configuration file by mounting it into the Docker container:

```bash
docker run \
  -p 6667:6667 -p 6668:6668 -p 6697:6697 -p 6698:6698 \
  -v ./runtime.exs:/app/config/ \
  faelgabriel/elixircd
```

### SSL Certificates

ElixIRCd automatically generates self-signed certificates for SSL listeners configured with `keyfile: "priv/cert/selfsigned_key.pem"` and `certfile: "priv/cert/selfsigned.pem"`.

For production environments, you should configure SSL listeners with a valid certificate and key obtained from a trusted Certificate Authority (CA), and mount them into the Docker container at `/app/priv/cert/`.

1. Obtain an SSL certificate and key from a trusted Certificate Authority (CA), such as [Let's Encrypt](https://letsencrypt.org/).

2. Update your `runtime.exs` configuration file with the paths to the obtained SSL certificate and key. For this example, we are using the filenames `trusted_key.pem` and `trusted_cert.pem`.

```elixir
# ... other configurations
{:ssl, [port: 6697, keyfile: "priv/cert/trusted_key.pem", certfile: "priv/cert/trusted_cert.pem"]},
{:ssl, [port: 6698, keyfile: "priv/cert/trusted_key.pem", certfile: "priv/cert/trusted_cert.pem"]}
# ... other configurations
```

3. Start the ElixIRCd server with your configuration and certificate files by mounting them into the Docker container:

```bash
docker run \
  -p 6667:6667 -p 6668:6668 -p 6697:6697 -p 6698:6698 \
  -v ./runtime.exs:/app/config/ \
  -v ./trusted_key.pem:/app/priv/cert/ \
  -v ./trusted_cert.pem:/app/priv/cert/ \
  faelgabriel/elixircd
```

### MOTD (Message of the Day)

To set the Message of the Day, create a `motd.txt` file and mount it into the Docker container at `/app/config/`.

1. Create a `motd.txt` file containing your desired message.

2. Start the ElixIRCd server with your MOTD file by mounting it into the Docker container:

```bash
docker run \
  -p 6667:6667 -p 6668:6668 -p 6697:6697 -p 6698:6698 \
  -v ./motd.txt:/app/config/ \
  # ... other volume mounts
  faelgabriel/elixircd
```

## Features

These features are based on traditional IRC protocols as outlined in the foundational RFCs for the IRC protocol. Key RFCs include [RFC 1459](https://datatracker.ietf.org/doc/html/rfc1459) (Internet Relay Chat Protocol), [RFC 2810](https://datatracker.ietf.org/doc/html/rfc2810) (IRC: Architecture), [RFC 2811](https://datatracker.ietf.org/doc/html/rfc2811) (IRC: Channel Management), [RFC 2812](https://datatracker.ietf.org/doc/html/rfc2812) (IRC: Client Protocol), [RFC 2813](https://datatracker.ietf.org/doc/html/rfc2813) (IRC: Server Protocol), and [RFC 7194](https://datatracker.ietf.org/doc/html/rfc7194) (Default Port for IRC via TLS/SSL).

> ✅ Implemented - ✴️ Partially implemented - ❌ Not implemented

### Server Commands (Client-to-Server)

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
- **PING/PONG**: Test the presence of an active connection. ✅
- **QUIT**: Disconnect from the server. ✅
- **LUSERS**: Get statistics about the size of the network. ✅
- **ISON**: Check if specified users are online. ✅
- **VERSION**: Respond to queries about the server's version. ✅
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
- **SERVICE**: Allow operators to register services on the network. ❌

### Server Commands (Server-to-Server)

- **SERVLIST**: List services currently connected to the network. ❌
- **LINKS**: List all server links in the IRC network. ❌
- **CONNECT**: Allow operators to connect a server to the network. ❌
- **SQUIT**: Allow operators to disconnect a server from the network gracefully. ❌
- **SQUERY**: Allow servers to send queries to other servers. ❌
- **ERROR**: Allow servers to report errors to other servers. Also used before ending client connections. ❌
- **SERVER**: Allow servers to introduce themselves to other servers on the network. ❌

## Modes

Modes can be applied to channels or users to modify their behaviors. These can be set by users who have the appropriate permissions or automatically by the server.

> ✅ Implemented - ✴️ Partially implemented - ❌ Not implemented

### User Modes

- **+i (Invisible)**: Hides the user from WHO searches and WHOIS searches by those not in shared channels. ✅
- **+o (Operator)**: Provides elevated privileges for network management and oversight. ✅
- **+w (Wallops)**: Enables reception of global announcements or alerts from network operators. ✅
- **+Z (Secure Connection)**: Indicates the user's connection is encrypted with SSL/TLS. ✅

### Channel Modes

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

## IRCv3 Features / Capabilities

These features are based on the IRCv3 specifications, providing modern capabilities. More information at [ircv3.net](https://ircv3.net/).

> ✅ Implemented - ✴️ Partially implemented - ❌ Not implemented

### Enhanced Commands and Extensions

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

### Server Commands (Client-to-Server)

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

## Development

ElixIRCd is written in Elixir, so you'll need to have Elixir and Erlang installed on your machine.

We recommend using [asdf](https://asdf-vm.com/) to easily install and manage the required versions.

### Install Elixir and Erlang with asdf

First, install `asdf` by following the instructions on the [asdf website](https://asdf-vm.com/). Then, add the necessary plugins and install the required versions:

```bash
# Add the Erlang plugin to asdf
asdf plugin-add erlang
# Add the Elixir plugin to asdf
asdf plugin-add elixir
# Install the versions specified in the .tool-versions file
asdf install
```

### Install Dependencies

To install the project dependencies, run:

```bash
mix deps.get
```

### Quality and Reliability Checks

Ensuring high code quality and reliability is essential for the stability of the project. You can run all the necessary checks, including compilation warnings, code formatting, linting, security analysis, dependency audits, documentation checks, and static analysis, with a single command:

```bash
mix check.all
```

### Running Tests

To run the test suite with code coverage, use:

```bash
mix test --cover
```

### Running the Server in Interactive Mode

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
