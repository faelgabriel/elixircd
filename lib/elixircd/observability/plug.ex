defmodule ElixIRCd.Observability.Plug do
  @moduledoc "Private operational HTTP endpoints."

  import Plug.Conn

  alias ElixIRCd.Observability

  @doc "Returns the immutable Plug options."
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @doc "Serves private operational routes."
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{method: "GET", request_path: "/health/live"} = conn, _opts) do
    respond(conn, 200, "ok\n")
  end

  def call(%Plug.Conn{method: "GET", request_path: "/health/ready"} = conn, _opts) do
    case Observability.readiness() do
      :ok -> respond(conn, 200, "ready\n")
      {:error, reason} -> respond(conn, 503, "unavailable: #{reason}\n")
    end
  end

  def call(%Plug.Conn{method: "GET", request_path: "/metrics"} = conn, _opts) do
    conn
    |> put_resp_content_type("text/plain; version=0.0.4; charset=utf-8")
    |> send_resp(200, Observability.scrape())
  end

  def call(conn, _opts), do: respond(conn, 404, "not found\n")

  defp respond(conn, status, body) do
    conn |> put_resp_content_type("text/plain") |> send_resp(status, body)
  end
end
