<h1 align="center">ElixIRCd</h1>

<p align="center">
  <a href="https://github.com/faelgabriel/elixircd/actions/workflows/elixir-ci.yml"><img src="https://github.com/faelgabriel/elixircd/actions/workflows/elixir-ci.yml/badge.svg" alt="Elixir CI"></a>
  <a href="https://github.com/faelgabriel/elixircd/actions/workflows/docker-ci.yml"><img src="https://github.com/faelgabriel/elixircd/actions/workflows/docker-ci.yml/badge.svg" alt="Docker CI"></a>
  <a href="https://coveralls.io/github/faelgabriel/elixircd?branch=main"><img src="https://img.shields.io/coverallsCoverage/github/faelgabriel/elixircd?label=Coverage" alt="Coveralls Status"></a>
  <a href="https://github.com/faelgabriel/elixircd/blob/main/LICENSE"><img src="https://img.shields.io/badge/License-AGPL-blue.svg" alt="License"></a>
</p>

## Introduction

ElixIRCd is an IRCd (Internet Relay Chat daemon) server implemented in Elixir. It is designed to provide a robust and highly concurrent IRC server environment. Its implementation makes use of the functional nature of Elixir and leverages the built-in concurrency and memory database capabilities of the Erlang VM (BEAM) and OTP (Open Telecom Platform) principles to deliver an efficient and reliable platform for IRC operations.

## Installation

To run the ElixIRCd server, ensure you have [Docker](https://docker.com/) installed.

### Build the Docker Image

First, build the Docker image using the following command:

```bash
docker build --target runtime --tag elixircd:beta .
```

### Run the Docker Container

Next, start the server container by running:

```bash
docker run --name elixircd \
  -p 6667:6667 \
  -p 6697:6697 \
  -p 6668:6668 \
  -p 6698:6698 \
  -v $(pwd)/priv:/app/priv \
  -d elixircd:beta
```

## Configuration

The server configuration is stored in the `config/runtime.exs` file. You can customize the server configuration by editing this file.

### Descriptions

- `server` - **Server Configuration:**
  - `name`: The name of your IRC server.
  - `hostname`: The hostname or domain name of your IRC server.
  - `password`: An optional server password. Set to `nil` if no password is required.
  - `motd`: The Message of the Day file. This is the message users will see when they connect to the server.

- `listeners` - **Network Configuration - Listeners for the server:**
  - `{ :tcp, [port: 6667] }`: Standard IRC port (6667).
  - `{ :tcp, [port: 6668] }`: Alternative IRC port (6668).
  - `{ :ssl, [port: 6697, keyfile: "priv/cert/selfsigned_key.pem", certfile: "priv/cert/selfsigned.pem"] }`: SSL-enabled IRC port (6697), with paths to the SSL key and certificate files.
  - `{ :ssl, [port: 6698, keyfile: "priv/cert/selfsigned_key.pem", certfile: "priv/cert/selfsigned.pem"] }`: Additional SSL-enabled IRC port (6698).

- `user` - **User Configuration:**
  - `timeout`: The duration (in milliseconds) before a user times out due to inactivity. Default is set to 180,000 ms (3 minutes).

- `ident_service` - **Features Configuration - Configuration for the ident service:**
  - `enabled`: Boolean value to enable or disable the ident service.
  - `timeout`: Timeout (in milliseconds) for ident service responses. Default is set to 5,000 ms (5 seconds).

- `admin_info` - **Administrative Contact Information:**
  - `server`: The name of your IRC server for contact purposes.
  - `location`: The location of your server.
  - `organization`: The name of the organization running the server.
  - `email`: The contact email address for server administrators.

- `operators` - **IRC Operators - A list of IRC operators, each with a username and a hashed password:**
  - `{"admin", "$argon2id$v=19$m=65536,t=3,p=4$FDb7o+zPhX+AIfcPDZ7O+g$IBllcYuvYr6dSuAb+qEuB72/YWwTwaTVhmFX2XKp76Q"}`: Example operator with a hashed password using the Argon2id algorithm.

### Full Default Configuration

```elixir
import Config

config :elixircd,
  # Server Configuration
  server: [
    name: "Server Example",
    hostname: "server.example.com",
    password: nil,
    motd: File.read("priv/motd.txt")
  ],
  # Network Configuration
  listeners: [
    # Standard IRC port
    {:tcp, [port: 6667]},
    # Alternative IRC port
    {:tcp, [port: 6668]},
    # SSL port
    {:ssl, [port: 6697, keyfile: "priv/cert/selfsigned_key.pem", certfile: "priv/cert/selfsigned.pem"]},
    # Additional SSL port
    {:ssl, [port: 6698, keyfile: "priv/cert/selfsigned_key.pem", certfile: "priv/cert/selfsigned.pem"]}
  ],
  # User Configuration
  user: [
    timeout: 180_000
  ],
  # Features Configuration
  ident_service: [
    enabled: true,
    timeout: 5_000
  ],
  # Administrative Contact Information
  admin_info: [
    server: "Server Example",
    location: "Server Location Here",
    organization: "Organization Name Here",
    email: "admin@example.com"
  ],
  # IRC Operators
  operators: [
    {"admin", "$argon2id$v=19$m=65536,t=3,p=4$FDb7o+zPhX+AIfcPDZ7O+g$IBllcYuvYr6dSuAb+qEuB72/YWwTwaTVhmFX2XKp76Q"}
  ]
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

## Developer Setup

ElixIRCd is written in Elixir, so you'll need to have Elixir and Erlang installed on your machine.
We recommend using [asdf](https://asdf-vm.com/) to easily install and manage the required versions.

### Install Dependencies with asdf

First, install `asdf` by following the instructions on the [asdf website](https://asdf-vm.com/). Then, add the necessary plugins and install the required versions:

```bash
asdf plugin-add erlang
asdf plugin-add elixir
asdf install
```

This will install the versions specified in the .tool-versions file.

## Contributing

We welcome contributions to ElixIRCd! If you have an issue or feature request, please open an issue on the issue tracker. Additionally, feel free to pick up any open issues that haven't been assigned yet. We warmly welcome your pull requests.

Please see the [contributing guidelines](https://github.com/faelgabriel/elixircd/blob/main/CONTRIBUTING.md) for details on how to contribute to this project.

## License

This project is licensed under the [AGPL License](https://github.com/faelgabriel/elixircd/blob/main/LICENSE).
