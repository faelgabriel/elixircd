# ElixIRCd

## Introduction

ElixIRCd is an IRCd (Internet Relay Chat daemon) server implemented in Elixir. It is designed to provide a robust, scalable, and highly concurrent IRCd server environment. Its implementation leverages the functional nature and concurrency model of Elixir to deliver an efficient and reliable platform for IRC operations.

## Contributing

Contributions to ElixIRCd are welcome! If you have an issue or feature request, please open an issue on the issue tracker. We warmly welcome your pull requests.

Please see the [contributing guidelines](https://github.com/faelgabriel/elixircd/blob/main/CONTRIBUTING.md) for details on how to contribute to this project.

## License

This project is licensed under the [AGPL License](https://github.com/faelgabriel/elixircd/blob/main/LICENSE).

# Features

## Classic IRCd Features
These features are based on traditional IRC protocols as outlined in the foundational RFCs for the IRC protocol. Key RFCs include RFC 1459 (Internet Relay Chat Protocol), RFC 2810 (IRC: Architecture), RFC 2811 (IRC: Channel Management), RFC 2812 (IRC: Client Protocol), and RFC 2813 (IRC: Server Protocol).

### Server Commands

- **NICK**: Set or change a user's nickname.
- **USER**: Specify username, hostname, servername, and real name.
- **JOIN**: Join a channel or create one if it doesn't exist.
- **PART**: Leave a channel.
- **MODE**: Set or unset user or channel modes.
- **TOPIC**: Set or get the topic of a channel.
- **NAMES**: List all visible nicknames on a channel.
- **LIST**: List channels and their topics.
- **INVITE**: Invite a user to a channel.
- **KICK**: Eject a user from a channel.
- **PRIVMSG**: Send private messages between users or to a channel.
- **NOTICE**: Send a message to a user or channel without automatic reply.
- **MOTD**: Request the Message of the Day from the server.
- **LUSERS**: Get statistics about the size of the network.
- **WHOIS**: Get information about a user.
- **WHO**: Get information about users on a server.
- **WHOWAS**: Get information about a user who has left.
- **AWAY**: Set an away message.
- **PING/PONG**: Test the presence of an active connection.
- **QUIT**: Disconnect from the server.
- **WALLOPS**: Distribute messages to users with 'wallop' privileges.
- **USERHOST**: Provide information about a list of nicknames.
- **ISON**: Check if specified users are online.
- **VERSION**: Respond to queries about the server's version.
- **STATS**: Provide server statistics.
- **LINKS**: List all server links in the IRC network.
- **TIME**: Provide the server's local time.
- **TRACE**: Trace routes to a specific server or user.
- **ADMIN**: Provide information about the server administrator.
- **INFO**: Provide information about the server.
- **KILL**: Allow operators to disconnect a user from the network.
- **REHASH**: Enable operators to reload the server's configuration.
- **RESTART**: Allow operators to restart the server.
- **SERVICE**: Handle registration of new services.

### Protocol Mechanics
- **Message Formatting**: Standard IRC message format.
- **Channel Types and Modes**: Public, private, secret channels, and various modes.
- **User Modes**: Different modes for users like invisible, operator, etc.
- **Connection Management**: Using PING/PONG for connection stability.

## IRCv3 Features
These features are based on the IRCv3 specifications, providing modern capabilities.

### Enhanced Commands and Extensions
- **SASL Authentication**: Secure authentication mechanism.
- **Multi-prefix**: Support for multiple status prefixes.
- **Account Tagging**: Associating messages with accounts.
- **Extended JOIN**: Additional information in JOIN messages.
- **Metadata Framework**: Arbitrary metadata associated with users or channels.
- **Message Tags**: Additional metadata in messages.
- **Batched Messages**: Sending messages in batches.
- **Capability negotiation**: Capability negotiation mechanism between clients and servers.
- **Client Capabilities**: Enhanced client capabilities negotiation.

### Advanced Protocol Mechanics
- **TLS Support**: For secure, encrypted connections.
- **WebSocket Support**: Enabling IRC over WebSockets for web clients.


<!-- ElixIRCd is a full IRC server implementation written in Elixir, taking advantage of its powerful features.

## Installation

### asdf

To install ElixIRCd, you'll need to have [asdf](https://asdf-vm.com/) installed. Once you have asdf installed, you can install the required Elixir version by running:

```bash
asdf install
```

After installing the correct Elixir version, you can install the dependencies by running:

```bash
mix deps.get
```

### Docker

To install ElixIRCd, you'll need to have [Docker](https://docker.com/) installed. Once you have Docker installed, you can start the required containers by running:

Dev:
```bash
docker compose up -d
```

Prod:
```bash
docker-compose -f docker-compose.yml -f docker-compose.prod.yml up
```


## Usage

To start the ElixIRCd server, run the following command:

```bash
mix run --no-halt
```

To start the ElixIRCd server in interactive mode, run the following command:

```bash
iex -S mix
```

This will start the Elixir environment and load your application's modules into the interactive shell. From here, you can interact with your application's processes directly and test your implementation.


## Generating selfsigned certificates
```bash
make ssl_keys
```
-->