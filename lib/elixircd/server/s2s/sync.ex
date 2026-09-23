defmodule ElixIRCd.Server.S2S.Sync do
  @moduledoc """
  Bounded ENP/1 network snapshot capture, page construction and staging.

  A snapshot is an explicit projection captured at one local output cut. The
  module does not read Mnesia or send bytes; callers provide committed rows and
  publish the returned frames through their one link writer.
  """

  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.JSON
  alias ElixIRCd.Server.S2S.Schema

  @page_size 256
  @max_staged_rows 65_536
  @max_staged_bytes 128 * 1_048_576

  @type snapshot :: %{
          sync_id: Identity.id(),
          cut: non_neg_integer(),
          rows: [map()],
          page_size: pos_integer()
        }

  @doc "Orders explicit export projections according to the ENP dependency contract."
  @spec ordered_rows(map()) :: {:ok, [map()]} | {:error, term()}
  def ordered_rows(projections) when is_map(projections) do
    keys = [:topology, :policy, :users, :channels, :memberships, :status, :markers]

    with :ok <- validate_projection_keys(projections, keys),
         rows <- Enum.flat_map(keys, &Map.get(projections, &1, [])),
         :ok <- validate_rows(rows) do
      {:ok, rows}
    end
  end

  def ordered_rows(_projections), do: {:error, :invalid_snapshot_projection}

  @doc "Captures a bounded explicit snapshot from already committed projections."
  @spec capture(Identity.id(), non_neg_integer(), map(), keyword()) :: {:ok, snapshot()} | {:error, term()}
  def capture(sync_id, cut, projections, options \\ []) do
    page_size = Keyword.get(options, :page_size, @page_size)

    cond do
      not Identity.valid_id?(sync_id) ->
        {:error, :invalid_sync_id}

      not Identity.valid_uint?(cut) ->
        {:error, :invalid_cut}

      not is_integer(page_size) or page_size < 1 or page_size > @page_size ->
        {:error, :invalid_page_size}

      true ->
        with {:ok, rows} <- ordered_rows(projections),
             true <- length(rows) <= @max_staged_rows,
             :ok <- validate_dependency_order(rows) do
          {:ok, %{sync_id: sync_id, cut: cut, rows: rows, page_size: page_size}}
        else
          false -> {:error, :snapshot_rows_too_large}
          {:error, _} = error -> error
        end
    end
  end

  @doc "Builds begin, rows and end frames with an exact page-body digest."
  @spec frames(snapshot(), pos_integer()) ::
          {:ok, %{frames: [map()], bodies: [binary()], digest: String.t(), next_n: pos_integer()}}
          | {:error, term()}
  def frames(snapshot, start_n \\ 1)

  def frames(%{sync_id: sync_id, cut: cut, rows: rows, page_size: page_size}, start_n)
      when is_integer(start_n) and start_n > 0 do
    pages = Enum.chunk_every(rows, page_size)

    begin = %{
      "t" => "sync",
      "n" => start_n,
      "phase" => "begin",
      "sync_id" => sync_id,
      "scope" => "network",
      "cut" => cut
    }

    {row_frames, bodies, next_n} =
      pages
      |> Enum.with_index()
      |> Enum.map_reduce(start_n + 1, fn {page_rows, page}, n ->
        frame = %{
          "t" => "sync",
          "n" => n,
          "phase" => "rows",
          "sync_id" => sync_id,
          "scope" => "network",
          "page" => page,
          "rows" => page_rows
        }

        body = JSON.encode(frame)
        {{frame, body}, n + 1}
      end)
      |> then(fn {pairs, next_n} ->
        {Enum.map(pairs, &elem(&1, 0)), Enum.map(pairs, &elem(&1, 1)), next_n}
      end)

    digest = digest(bodies)

    ending = %{
      "t" => "sync",
      "n" => next_n,
      "phase" => "end",
      "sync_id" => sync_id,
      "scope" => "network",
      "pages" => length(pages),
      "rows" => length(rows),
      "sha256" => digest
    }

    all_frames = [begin | row_frames] ++ [ending]

    case Enum.reduce_while(all_frames, :ok, fn frame, :ok ->
           case Schema.validate_frame(frame) do
             :ok -> {:cont, :ok}
             {:error, _} = error -> {:halt, error}
           end
         end) do
      :ok -> {:ok, %{frames: all_frames, bodies: bodies, digest: digest, next_n: next_n + 1}}
      {:error, _} = error -> error
    end
  end

  def frames(_snapshot, _start_n), do: {:error, :invalid_snapshot}

  @doc "Builds the direct-link snapshot acknowledgement after a successful apply."
  @spec ack(Identity.id(), pos_integer(), String.t()) :: {:ok, map()} | {:error, term()}
  def ack(sync_id, n, digest) when is_integer(n) and n > 0 and is_binary(digest) do
    frame = %{"t" => "sync", "n" => n, "phase" => "ack", "sync_id" => sync_id, "scope" => "network", "sha256" => digest}
    if Schema.validate_frame(frame) == :ok, do: {:ok, frame}, else: {:error, :invalid_ack}
  end

  @doc "Verifies page ordering, counts and the digest of canonical received bodies."
  @spec verify([map() | {map(), binary()}]) ::
          {:ok, %{sync_id: Identity.id(), rows: [map()], digest: String.t()}} | {:error, term()}
  def verify(frames) when is_list(frames) do
    with {:ok, begin, page_pairs, ending} <- split_frames(frames),
         :ok <- verify_page_numbers(page_pairs),
         rows <- Enum.flat_map(page_pairs, &elem(&1, 0)["rows"]),
         :ok <- validate_rows(rows),
         :ok <- validate_dependency_order(rows),
         digest <- digest(Enum.map(page_pairs, &elem(&1, 1))),
         true <- digest == ending["sha256"],
         true <- length(page_pairs) == ending["pages"],
         true <- Enum.reduce(page_pairs, 0, &(&2 + length(elem(&1, 0)["rows"]))) == ending["rows"] do
      {:ok, %{sync_id: begin["sync_id"], rows: rows, digest: digest}}
    else
      false -> {:error, :snapshot_digest_or_count_mismatch}
      {:error, _} = error -> error
    end
  end

  def verify(_frames), do: {:error, :invalid_snapshot_frames}

  @doc "Creates a bounded receiver staging context."
  @spec new_staging(Identity.id(), keyword()) :: map()
  def new_staging(sync_id, options \\ []) do
    %{
      sync_id: sync_id,
      cut: nil,
      pages: %{},
      page_bodies: %{},
      rows: 0,
      bytes: 0,
      max_rows: Keyword.get(options, :max_rows, @max_staged_rows),
      max_bytes: Keyword.get(options, :max_bytes, @max_staged_bytes)
    }
  end

  @doc "Stages one begin or rows frame without publishing any state."
  @spec stage(map(), map(), binary() | nil) :: {:ok, map()} | {:error, term()}
  def stage(%{sync_id: sync_id, cut: nil} = staging, %{"phase" => "begin", "sync_id" => sync_id, "cut" => cut}, _body) do
    if Identity.valid_uint?(cut), do: {:ok, %{staging | cut: cut}}, else: {:error, :invalid_snapshot_begin}
  end

  def stage(
        %{sync_id: sync_id, cut: cut, pages: pages} = staging,
        %{"phase" => "rows", "sync_id" => sync_id, "page" => page, "rows" => rows} = frame,
        body
      )
      when not is_nil(cut) and is_list(rows) do
    body = body || JSON.encode(frame)

    cond do
      not is_integer(page) or page < 0 ->
        {:error, :invalid_page}

      Map.has_key?(pages, page) ->
        {:error, :duplicate_page}

      byte_size(body) + staging.bytes > staging.max_bytes ->
        {:error, :snapshot_staging_bytes}

      length(rows) + staging.rows > staging.max_rows ->
        {:error, :snapshot_staging_rows}

      true ->
        {:ok,
         %{
           staging
           | pages: Map.put(pages, page, rows),
             page_bodies: Map.put(staging.page_bodies, page, body),
             rows: staging.rows + length(rows),
             bytes: staging.bytes + byte_size(body)
         }}
    end
  end

  def stage(_staging, _frame, _body), do: {:error, :invalid_staging_phase}

  @doc "Finishes a staging context only after all pages, dependencies and digest checks pass."
  @spec finish(map(), map()) ::
          {:ok, %{cut: non_neg_integer(), rows: [map()], digest: String.t()}} | {:error, term()}
  def finish(%{sync_id: sync_id} = staging, %{
        "phase" => "end",
        "sync_id" => sync_id,
        "pages" => pages,
        "rows" => rows,
        "sha256" => expected
      }) do
    ordered_pages = Enum.sort_by(staging.pages, &elem(&1, 0))
    page_numbers = Enum.map(ordered_pages, &elem(&1, 0))
    bodies = Enum.map(ordered_pages, fn {page, _rows} -> Map.fetch!(staging.page_bodies, page) end)
    all_rows = Enum.flat_map(ordered_pages, &elem(&1, 1))

    cond do
      not Identity.valid_uint?(pages) or not Identity.valid_uint?(rows) or not is_binary(expected) ->
        {:error, :invalid_snapshot_end}

      staging.cut == nil ->
        {:error, :snapshot_begin_missing}

      page_numbers != Enum.to_list(0..(pages - 1)) and not (pages == 0 and page_numbers == []) ->
        {:error, :snapshot_page_gap}

      length(ordered_pages) != pages or length(all_rows) != rows ->
        {:error, :snapshot_count_mismatch}

      digest(bodies) != expected ->
        {:error, :snapshot_digest_mismatch}

      validate_dependency_order(all_rows) != :ok ->
        {:error, :snapshot_dependency_order}

      true ->
        {:ok, %{cut: staging.cut, rows: all_rows, digest: expected}}
    end
  end

  def finish(_staging, _frame), do: {:error, :invalid_snapshot_end}

  @doc "Computes the lowercase SHA-256 digest used by sync end/ack."
  @spec digest([binary()]) :: String.t()
  def digest(bodies) do
    bodies
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @doc "Checks the fixed dependency order of a complete export."
  @spec validate_dependency_order([map()]) :: :ok | {:error, term()}
  def validate_dependency_order(rows) do
    rows
    |> Enum.map(&row_rank/1)
    |> Enum.reduce_while(-1, fn rank, previous ->
      if rank < previous, do: {:halt, {:error, :dependency_order}}, else: {:cont, rank}
    end)
    |> case do
      {:error, _} = error -> error
      _ -> :ok
    end
  end

  defp validate_projection_keys(projections, keys) do
    if Enum.all?(Map.keys(projections), &(&1 in keys)), do: :ok, else: {:error, :unknown_snapshot_projection}
  end

  defp validate_rows(rows) when is_list(rows) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case Schema.validate_row(row) do
        :ok -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, :invalid_snapshot_row}}
      end
    end)
  end

  defp validate_rows(_rows), do: {:error, :invalid_snapshot_rows}

  defp split_frames(frames) do
    normalized =
      Enum.map(frames, fn
        {frame, body} when is_map(frame) and is_binary(body) -> %{frame: frame, body: body}
        frame when is_map(frame) -> %{frame: frame, body: JSON.encode(frame)}
        _other -> %{frame: %{}, body: <<>>}
      end)

    case normalized do
      [%{frame: %{"phase" => "begin", "t" => "sync"} = begin} | rest] ->
        case List.pop_at(rest, -1) do
          {nil, _} ->
            {:error, :snapshot_end_missing}

          {%{frame: ending} = ending_entry, page_frames} ->
            if Schema.validate_frame(begin) == :ok and Schema.validate_frame(ending) == :ok and
                 ending["sync_id"] == begin["sync_id"] and ending["phase"] == "end" and
                 Enum.all?(page_frames, fn %{frame: frame} ->
                   frame["phase"] == "rows" and frame["sync_id"] == begin["sync_id"]
                 end) do
              {:ok, begin, Enum.map(page_frames, fn %{frame: frame, body: body} -> {frame, body} end),
               ending_entry.frame}
            else
              {:error, :snapshot_phase_order}
            end

          _ ->
            {:error, :snapshot_end_missing}
        end

      _ ->
        {:error, :snapshot_begin_missing}
    end
  end

  defp verify_page_numbers(page_pairs) do
    expected = if page_pairs == [], do: [], else: Enum.to_list(0..(length(page_pairs) - 1))

    if Enum.map(page_pairs, &elem(&1, 0)["page"]) == expected and
         Enum.all?(page_pairs, fn {frame, _body} -> Schema.validate_frame(frame) == :ok end),
       do: :ok,
       else: {:error, :snapshot_page_gap}
  end

  defp row_rank(%{"kind" => kind}) do
    cond do
      String.starts_with?(kind, "topology.") -> 0
      kind == "policy.change" or String.starts_with?(kind, "policy.cache.") -> 1
      kind == "user.put" or kind == "user.quit" -> 2
      String.starts_with?(kind, "channel.") -> 3
      kind == "memberships.put" -> 4
      kind == "member.status" -> 5
      kind == "merge.begin" or kind == "merge.end" or kind == "merge.abort" or kind == "invite.notice" -> 6
      true -> 7
    end
  end

  defp row_rank(_row), do: 99
end
