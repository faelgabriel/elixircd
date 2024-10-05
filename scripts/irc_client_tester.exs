defmodule IrcClientTester do
  @moduledoc """
  IRC client that connects multiple users to a server using plain text TCP connections for load testing purposes.
  It sends a random NICK and USER command to the server and waits for the "End of /MOTD command" message.

  Usage:
  ```
  elixir scripts/irc_client_tester.exs <server> <port> <num_users> <keep_alive_seconds>
  ```
  """

  def start(server, port, num_users, keep_alive_seconds) do
    IO.puts(
      "Starting IRC client to connect to #{server}:#{port} with #{num_users} users, keeping connections alive for #{keep_alive_seconds} seconds."
    )

    tasks =
      Enum.map(1..num_users, fn user_number ->
        Task.async(fn -> connect(server, port, keep_alive_seconds, user_number) end)
      end)

    # Wait for all tasks to finish
    Enum.each(tasks, fn task ->
      Task.await(task, 60_000)
    end)

    IO.puts("All users have finished their connections.")
  end

  defp connect(server, port, keep_alive_seconds, user_number) do
    IO.puts("User #{user_number}: Connecting to #{server}:#{port}...")

    # Set options without a specific timeout
    opts = [:binary, active: false]

    case :gen_tcp.connect(String.to_charlist(server), port, opts, 5_000) do
      {:ok, socket} ->
        nick = random_nick()
        user = "user" <> nick

        IO.puts("User #{user_number}: Connected. Sending NICK #{nick} and USER #{user} commands.")

        send_data(socket, "NICK #{nick}\r\n")
        send_data(socket, "USER #{user} 0 * :#{user}\r\n")

        wait_for_mode_message(socket, user_number)

        IO.puts("User #{user_number}: Connection established. Keeping alive for #{keep_alive_seconds} seconds.")
        :timer.sleep(keep_alive_seconds * 1_000)

        IO.puts("User #{user_number}: Time expired. Closing connection.")
        :gen_tcp.close(socket)

      {:error, reason} ->
        IO.puts("User #{user_number}: Failed to connect to #{server}:#{port} - #{inspect(reason)}")
    end
  end

  defp send_data(socket, data) do
    case :gen_tcp.send(socket, data) do
      :ok -> IO.puts("Data sent: #{String.trim(data)}")
      {:error, reason} -> IO.puts("Failed to send data: #{reason}")
    end
  end

  defp wait_for_mode_message(socket, user_number) do
    receive_loop(socket, user_number)
  end

  defp receive_loop(socket, user_number) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, message} ->
        IO.puts("User #{user_number}: Received message: #{String.trim(message)}")

        if String.contains?(message, "End of /MOTD command") do
          IO.puts("User #{user_number}: 'End of /MOTD command' message received. Stopping reception loop.")
        else
          # Continue waiting for the "End of /MOTD command" message
          receive_loop(socket, user_number)
        end

      {:error, reason} ->
        IO.puts("User #{user_number}: Error receiving message - #{inspect(reason)}")
    end
  end

  defp random_nick() do
    "n" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  end
end

# Read arguments from the command line
[server, port, num_users, keep_alive_seconds] = System.argv()
port = String.to_integer(port)
num_users = String.to_integer(num_users)
keep_alive_seconds = String.to_integer(keep_alive_seconds)

# Start the client
IrcClientTester.start(server, port, num_users, keep_alive_seconds)
