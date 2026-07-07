defmodule Clementine.GuidesTest do
  @moduledoc """
  Keeps the hexdocs guides in lockstep with the code: every `elixir`
  fence in `guides/*.md` must at least parse, and every complete module
  sample compiles for real — so a renamed function, changed arity, or
  dropped option in the library breaks the guide's sample here, not in an
  adopter's cold read.

  The contract with the guides:

    * A fenced block whose code begins with `defmodule` is compiled with
      `Code.compile_string/2`. Compiler diagnostics must all be about the
      guides' placeholder host app (the `MyApp`/`MyAppWeb` namespace —
      undefined-module warnings for host functions the samples call);
      any other diagnostic (an undefined `Clementine.*` function, a
      behaviour mismatch, an unused variable) fails the suite.
    * An HTML comment `<!-- guide-sample: parse-only -->` immediately
      before a fence downgrades it to a syntax check — for samples that
      `use` host modules that cannot exist here (`MyAppWeb`, the
      conformance-suite `use` that would register live ExUnit tests).
    * Every other block (config snippets, expression fragments) gets the
      syntax check.

  Compilation is sequential per guide, so later samples may call modules
  defined by earlier samples in the same guide; everything a guide
  defines is purged before the next guide runs (two guides may show
  different stages of the same module).
  """

  # Compiled guide modules are global state; keep the file serial.
  use ExUnit.Case, async: false

  @guides Path.wildcard("guides/*.md")

  @parse_only_marker ~r/^<!--\s*guide-sample:\s*parse-only\s*-->\s*$/
  @host_app_namespace ~r/MyApp/

  # The wildcard runs at compile time; if guides/ ever empties out, the
  # extras comparison below fails against mix.exs's non-empty list.
  test "every guide is wired into mix docs extras" do
    extras = Keyword.fetch!(Mix.Project.config(), :docs)[:extras]
    listed = Enum.map(extras, fn {path, _opts} -> to_string(path) end)

    assert Enum.sort(listed) == Enum.sort(@guides)
  end

  for path <- @guides do
    test "code samples in #{path} compile against the current API" do
      verify_guide!(unquote(path))
    end
  end

  defp verify_guide!(path) do
    blocks = extract_blocks(File.read!(path))
    assert blocks != [], "#{path} contains no elixir samples"

    compiled =
      Enum.flat_map(blocks, fn block ->
        case mode(block) do
          :compile -> compile!(path, block)
          :parse -> parse!(path, block)
        end
      end)

    for {module, _bytecode} <- compiled do
      :code.purge(module)
      :code.delete(module)
    end
  end

  defp mode(%{marker: :parse_only}), do: :parse

  defp mode(%{code: code}) do
    if code |> String.trim_leading() |> String.starts_with?("defmodule") do
      :compile
    else
      :parse
    end
  end

  defp parse!(path, %{code: code, line: line}) do
    Code.string_to_quoted!(code, file: path, line: line)
    []
  rescue
    e in [SyntaxError, TokenMissingError] ->
      flunk("guide sample at #{path}:#{line} does not parse:\n\n#{Exception.message(e)}")
  end

  defp compile!(path, %{code: code, line: line}) do
    {result, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          {:ok, Code.compile_string(code, path)}
        rescue
          e -> {:error, e}
        end
      end)

    case result do
      {:ok, compiled} ->
        assert_only_host_app_diagnostics!(path, line, diagnostics)
        compiled

      {:error, e} ->
        flunk("""
        guide sample at #{path}:#{line} does not compile:

        #{Exception.message(e)}

        #{Enum.map_join(diagnostics, "\n", & &1.message)}
        """)
    end
  end

  # Undefined-function warnings about the placeholder host app are the
  # point of the convention; anything else is a drifted or sloppy sample.
  defp assert_only_host_app_diagnostics!(path, line, diagnostics) do
    offending = Enum.reject(diagnostics, &(&1.message =~ @host_app_namespace))

    assert offending == [],
           """
           guide sample at #{path}:#{line} produced diagnostics that are not \
           about the placeholder MyApp host:

           #{Enum.map_join(offending, "\n\n", & &1.message)}
           """
  end

  # Fenced-block scanner: tracks the parse-only marker on the line
  # directly above an opening fence, and the block's starting line for
  # failure messages.
  defp extract_blocks(markdown) do
    markdown
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({:closed, nil, []}, &scan_line/2)
    |> then(fn {state, _open, blocks} ->
      assert state == :closed, "unterminated code fence"
      Enum.reverse(blocks)
    end)
  end

  defp scan_line({line, number}, {:closed, marker, blocks}) do
    cond do
      line =~ @parse_only_marker ->
        {:closed, :parse_only, blocks}

      String.starts_with?(line, "```") ->
        lang = line |> String.trim_leading("`") |> String.trim()
        {:open, %{lang: lang, marker: marker, line: number + 1, lines: []}, blocks}

      true ->
        {:closed, nil, blocks}
    end
  end

  defp scan_line({line, _number}, {:open, block, blocks}) do
    if String.starts_with?(line, "```") do
      blocks =
        if block.lang == "elixir" do
          code = block.lines |> Enum.reverse() |> Enum.join("\n")
          [%{marker: block.marker, line: block.line, code: code} | blocks]
        else
          blocks
        end

      {:closed, nil, blocks}
    else
      {:open, %{block | lines: [line | block.lines]}, blocks}
    end
  end
end
