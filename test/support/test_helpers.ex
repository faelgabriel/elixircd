defmodule ElixIRCd.TestHelpers do
  @moduledoc """
  This module defines helper functions for use in tests.
  """

  use ExUnit.CaseTemplate

  @doc """
  Asserts that a file exists.
  """
  @spec assert_file(binary()) :: true
  def assert_file(file) do
    assert File.regular?(file), "Expected #{file} to exist, but does not"
  end

  @doc """
  Asserts that a file exists and optionally matches a pattern.
  """
  @spec assert_file(binary(), binary() | [binary()] | Regex.t() | (binary() -> any())) :: true
  def assert_file(file, match) do
    cond do
      is_binary(match) or is_struct(match, Regex) ->
        assert_file(file, &assert(&1 =~ match))

      is_function(match, 1) ->
        assert_file(file)
        match.(File.read!(file))
    end
  end

  @doc """
  Runs a function in a temporary directory.
  """
  @spec in_tmp(binary(), (-> any())) :: any
  def in_tmp(which, function) do
    base = Path.join([tmp_path(), random_string(10)])
    path = Path.join([base, to_string(which)])

    try do
      File.rm_rf!(path)
      File.mkdir_p!(path)
      File.cd!(path, function)
    after
      File.rm_rf!(base)
    end
  end

  @doc """
  Returns the path to the temporary directory.
  """
  @spec tmp_path() :: binary()
  def tmp_path do
    Path.expand("../../tmp", __DIR__)
  end

  @doc """
  Generates a random string of the given length.
  """
  @spec random_string(pos_integer()) :: binary()
  def random_string(len) do
    len |> :crypto.strong_rand_bytes() |> Base.url_encode64() |> binary_part(0, len)
  end
end
