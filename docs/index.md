<h1 align="center">ElixIRCd</h1>

<p align="center">
  <a href="https://github.com/faelgabriel/elixircd/actions/workflows/elixir-ci.yml"><img src="https://github.com/faelgabriel/elixircd/actions/workflows/elixir-ci.yml/badge.svg" alt="Elixir CI"></a>
  <a href="https://github.com/faelgabriel/elixircd/actions/workflows/docker-ci.yml"><img src="https://github.com/faelgabriel/elixircd/actions/workflows/docker-ci.yml/badge.svg" alt="Docker CI"></a>
  <a href="https://coveralls.io/github/faelgabriel/elixircd?branch=main"><img src="https://img.shields.io/coverallsCoverage/github/faelgabriel/elixircd?label=Coverage" alt="Coveralls Status"></a>
  <a href="https://github.com/faelgabriel/elixircd/blob/main/LICENSE"><img src="https://img.shields.io/badge/License-AGPL-blue.svg" alt="License"></a>
</p>

## Introduction

ElixIRCd is an IRCd (Internet Relay Chat daemon) server implemented in Elixir. It is designed to provide a robust, scalable, and highly concurrent IRC server environment. Its implementation leverages the functional nature and concurrency model of Elixir to deliver an efficient and reliable platform for IRC operations.

## Status

ElixIRCd is currently under development.

## Installation

To install ElixIRCd, you will need to have Elixir installed on your system. You can find installation instructions for Elixir [here](https://elixir-lang.org/install.html).

<b>Configuration</b>

ElixIRCd is configured using a configuration file. The default configuration file is located at `config/config.exs`. You can modify this file to suit your needs. The configuration file is used to specify the server name, server description, server ports, and other server settings.

## Features

These features are based on traditional IRC protocols as outlined in the foundational RFCs for the IRC protocol. Key RFCs include [RFC 1459](https://datatracker.ietf.org/doc/html/rfc1459) (Internet Relay Chat Protocol), [RFC 2810](https://datatracker.ietf.org/doc/html/rfc2810) (IRC: Architecture), [RFC 2811](https://datatracker.ietf.org/doc/html/rfc2811) (IRC: Channel Management), [RFC 2812](https://datatracker.ietf.org/doc/html/rfc2812) (IRC: Client Protocol), [RFC 2813](https://datatracker.ietf.org/doc/html/rfc2813) (IRC: Server Protocol), and [RFC 7194](https://datatracker.ietf.org/doc/html/rfc7194) (Default Port for IRC via TLS/SSL).

## Contributing

Contributions to ElixIRCd are welcome! If you have an issue or feature request, please open an issue on the issue tracker. We warmly welcome your pull requests.

Please see the [contributing guidelines](https://github.com/faelgabriel/elixircd/blob/main/CONTRIBUTING.md) for details on how to contribute to this project.

## License

This project is licensed under the [AGPL License](https://github.com/faelgabriel/elixircd/blob/main/LICENSE).
