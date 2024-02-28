<h1 align="center">ElixIRCd</h1>

<p align="center">
  <a href="https://github.com/faelgabriel/elixircd/actions/workflows/elixir-ci.yml"><img src="https://github.com/faelgabriel/elixircd/actions/workflows/elixir-ci.yml/badge.svg" alt="Elixir CI"></a>
  <a href="https://github.com/faelgabriel/elixircd/actions/workflows/docker-ci.yml"><img src="https://github.com/faelgabriel/elixircd/actions/workflows/docker-ci.yml/badge.svg" alt="Docker CI"></a>
  <a href="https://coveralls.io/github/faelgabriel/elixircd?branch=main"><img src="https://img.shields.io/coverallsCoverage/github/faelgabriel/elixircd?label=Coverage" alt="Coveralls Status"></a>
  <a href="https://github.com/faelgabriel/elixircd/blob/main/LICENSE"><img src="https://img.shields.io/badge/License-AGPL-blue.svg" alt="License"></a>
</p>

## Introduction

ElixIRCd is an IRCd (Internet Relay Chat daemon) server implemented in Elixir. It is designed to provide a robust, scalable, and highly concurrent IRC server environment. Its implementation makes use of the functional nature of Elixir and leverages the built-in concurrency and memory database capabilities of the Erlang VM to deliver an efficient and reliable platform for IRC operations.

## Status

ElixIRCd is currently under active development. The project is being developed in the open, and we welcome contributions from the community.

The project is currently in the early stages of development, and many features are not yet implemented. We are working to implement the core features of the IRC protocol and will continue to add support for modern IRCv3 features.

## Contributing

Contributions to ElixIRCd are welcome! If you have an issue or feature request, please open an issue on the issue tracker. Additionally, feel free to pick up any open issues that haven't been assigned yet. We warmly welcome your pull requests.

Please see the [contributing guidelines](https://github.com/faelgabriel/elixircd/blob/main/CONTRIBUTING.md) for details on how to contribute to this project.

## Features

These features are based on traditional IRC protocols as outlined in the foundational RFCs for the IRC protocol. Key RFCs include [RFC 1459](https://datatracker.ietf.org/doc/html/rfc1459) (Internet Relay Chat Protocol), [RFC 2810](https://datatracker.ietf.org/doc/html/rfc2810) (IRC: Architecture), [RFC 2811](https://datatracker.ietf.org/doc/html/rfc2811) (IRC: Channel Management), [RFC 2812](https://datatracker.ietf.org/doc/html/rfc2812) (IRC: Client Protocol), [RFC 2813](https://datatracker.ietf.org/doc/html/rfc2813) (IRC: Server Protocol), and [RFC 7194](https://datatracker.ietf.org/doc/html/rfc7194) (Default Port for IRC via TLS/SSL).

> ✅ Implemented - ✴️ Partially implemented - ❌ Not implemented

### Protocol Mechanics

- **Message Formatting**: Standard IRC message format. ✅
- **Message Handling**: Routing and delivery of messages. ✅
- **Message Types**: Different types of messages, e.g., PRIVMSG, NOTICE. ✅
- **Channel Control**: Creating, joining, and leaving channels. ✅
- **Channel Types and Modes**: Public, private, secret channels, and various modes. ✴️
- **Channel Topics**: Managing and displaying channel topics. ❌
- **Channel Lists**: Retrieving lists of available channels. ❌
- **Nicknames**: Rules for nickname registration and uniqueness. ❌
- **User Modes**: Different modes for users like invisible, operator, etc. ✴️
- **User Lists**: Obtaining lists of users in channels. ✅
- **Bans and Kicks**: Rules for user removal from channels. ❌
- **Privileges**: Granting operator and user privileges. ❌
- **CTCP (Client-to-Client Protocol)**: Custom commands and queries. ❌
- **Idle Time Tracking**: Monitoring user activity and idle times. ✴️
- **Connection Management**: Using PING/PONG for connection stability. ✅
- **Error Handling**: How errors and exceptional conditions are managed. ✅
- **Motd (Message of the Day)**: Customization of server-wide announcements and informational messages. ✴️
- **Server Statistics**: Gathering and reporting network and server statistics. ❌
- **Oper Commands**: Special commands for server operators (IRCops). ❌
- **TLS Protocol**: For secure, encrypted connections. ✅

### Server Commands

- **NICK**: Set or change a user's nickname. ✅
- **USER**: Specify username, hostname, servername, and real name. ✅
- **JOIN**: Join a channel or create one if it doesn't exist. ✅
- **PART**: Leave a channel. ✅
- **MODE**: Set or unset user or channel modes. ✴️
- **TOPIC**: Set or get the topic of a channel. ❌
- **NAMES**: List all visible nicknames on a channel. ✅
- **LIST**: List channels and their topics. ❌
- **INVITE**: Invite a user to a channel. ❌
- **KICK**: Eject a user from a channel. ❌
- **PRIVMSG**: Send private messages between users or to a channel. ✅
- **NOTICE**: Send a message to a user or channel without automatic reply. ✅
- **MOTD**: Request the Message of the Day from the server. ✴️
- **LUSERS**: Get statistics about the size of the network. ❌
- **WHOIS**: Get information about a user. ✅
- **WHO**: Get information about users on a server. ❌
- **WHOWAS**: Get information about a user who has left. ❌
- **AWAY**: Set an away message. ❌
- **PING/PONG**: Test the presence of an active connection. ✅
- **QUIT**: Disconnect from the server.
- **WALLOPS**: Distribute messages to users with 'wallop' privileges. ❌
- **USERHOST**: Provide information about a list of nicknames. ✅
- **ISON**: Check if specified users are online. ❌
- **VERSION**: Respond to queries about the server's version. ❌
- **STATS**: Provide server statistics. ❌
- **LINKS**: List all server links in the IRC network. ❌
- **TIME**: Provide the server's local time. ❌
- **TRACE**: Trace routes to a specific server or user. ❌
- **ADMIN**: Provide information about the server administrator. ❌
- **INFO**: Provide information about the server. ❌
- **KILL**: Allow operators to disconnect a user from the network. ❌
- **REHASH**: Enable operators to reload the server's configuration. ❌
- **RESTART**: Allow operators to restart the server. ❌
- **SERVICE**: Handle registration of new services. ❌
- **OPER**: Allow operators to gain elevated privileges on the server. ❌
- **SQUIT**: Allow operators to disconnect a server from the network gracefully. ❌

## IRCv3 Features

These features are based on the IRCv3 specifications, providing modern capabilities. More information at [ircv3.net](https://ircv3.net/).

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

### Server Commands

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

## Installation

To run ElixIRCd server, you'll need to have [Docker](https://docker.com/) installed. Once you have Docker installed, you can start the server container by running:

```bash
docker build --target production --tag elixircd:production .
docker run -p 6667:6667 -p 6697:6697 --name elixircd -d elixircd:production
```

> Once the ElixiRCd has a stable release, we will provide the Docker image on Docker Hub.

### SSL

To run the server using SSL, you'll need to have a valid certificate and private key files. By default, the server expects the following files:

```
Private key: priv/ssl/key.pem
Certificate: priv/ssl/cert.crt
```

To customize, see the `ssl_keyfile` and `ssl_certfile` configurations.

## Development

### Environment

To set up the development environment, you need to have [Docker](https://docker.com/) or [asdf](https://asdf-vm.com/) installed.

#### Docker

```bash
docker build --target development --tag elixircd:development .
docker run -it -p 6667:6667 -v $(pwd):/app -v deps:/app/deps -v build:/app/_build --name elixircd_dev -d elixircd:development
```

#### asdf

```bash
asdf plugin-add erlang
asdf plugin-add elixir
asdf install
```

### SSL

For development, you can create a self-signed certificate:

```
mkdir -p priv/ssl/
openssl req -x509 -newkey rsa:4096 -keyout priv/ssl/key.pem -out priv/ssl/cert.crt -days 365 -nodes -subj "/CN=localhost"
```

### Usage

To install dependencies and set up the database, run the following commands:

```bash
mix deps.get
mix db.setup
```

To start the ElixIRCd server in interactive mode, run the following command:

```bash
iex -S mix
```

## License

This project is licensed under the [AGPL License](https://github.com/faelgabriel/elixircd/blob/main/LICENSE).
