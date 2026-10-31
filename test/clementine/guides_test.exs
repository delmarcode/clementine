defmodule Clementine.GuidesTest do
  @moduledoc """
  Keeps the README, the hexdocs guides, and `usage-rules.md` in lockstep
  with the code: every `elixir` fence in them must at least parse, and
  every complete module sample compiles for real — so a renamed function,
  changed arity, or dropped option in the library breaks the sample here,
  not in an adopter's cold read.

  The contract with the samples:

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
    * An HTML comment `<!-- guide-sample: run -->` immediately before an
      expression sample evaluates it, in process, against a scripted
      model that answers every call with text. Its bindings carry to the
      next run sample in the same file. Only a sample that needs no
      database, Oban, or API key can run.
    * Every other block (config snippets, expression fragments) gets the
      syntax check.

  Compilation is sequential per file, so later samples may call modules
  defined by earlier samples in the same file; everything a file
  defines is purged before the next file runs (two guides may show
  different stages of the same module).

  Every relative link in those files resolves: the file it names exists,
  and a `#fragment` names a heading in it, slugged the way GitHub slugs
  headings.
  """

  # Compiled guide modules and the global model stub are shared state;
  # keep the file serial.
  use ExUnit.Case, async: false

  @extras Path.wildcard("guides/*.md") ++ ["usage-rules.md"]

  # The README is the repository's front door on GitHub. It is not a docs
  # extra (`mix docs` lands on Getting Started), so it is checked here but
  # not listed in mix.exs.
  @guides @extras ++ ["README.md"]

  @parse_only_marker ~r/^<!--\s*guide-sample:\s*parse-only\s*-->\s*$/
  @run_marker ~r/^<!--\s*guide-sample:\s*run\s*-->\s*$/
  @host_app_namespace ~r/MyApp/
  @link ~r/\]\(([^)\s]+)\)/
  @scheme ~r/^[a-z][a-z0-9+.-]*:/i

  # The model a run sample talks to: every call answers with text.
  setup do
    Mox.set_mox_global()

    Mox.stub(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
      [
        {:text_delta, "A scripted answer."},
        {:message_delta, %{"stop_reason" => "end_turn"},
         %{"input_tokens" => 10, "output_tokens" => 4}}
      ]
    end)

    :ok
  end

  # The wildcard runs at compile time; if guides/ ever empties out, the
  # extras comparison below fails against mix.exs's non-empty list.
  test "every guide is wired into mix docs extras" do
    extras = Keyword.fetch!(Mix.Project.config(), :docs)[:extras]
    listed = Enum.map(extras, fn {path, _opts} -> to_string(path) end)

    assert Enum.sort(listed) == Enum.sort(@extras)
  end

  for path <- @guides do
    test "code samples in #{path} compile against the current API" do
      verify_guide!(unquote(path))
    end

    test "relative links in #{path} resolve" do
      verify_links!(unquote(path))
    end
  end

  defp verify_guide!(path) do
    blocks = extract_blocks(File.read!(path))
    assert blocks != [], "#{path} contains no elixir samples"

    {compiled, _binding} =
      Enum.flat_map_reduce(blocks, [], fn block, binding ->
        case mode(block) do
          :compile -> {compile!(path, block), binding}
          :parse -> {parse!(path, block), binding}
          :run -> {[], run!(path, block, binding)}
        end
      end)

    for {module, _bytecode} <- compiled do
      :code.purge(module)
      :code.delete(module)
    end
  end

  defp mode(%{marker: :parse_only}), do: :parse
  defp mode(%{marker: :run}), do: :run

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

  # Evaluated as a reader would type it into IEx: a failed match or a
  # raise is a sample that no longer works. Output is captured.
  defp run!(path, %{code: code, line: line}, binding) do
    {result, _output} =
      ExUnit.CaptureIO.with_io(fn ->
        Code.with_diagnostics(fn ->
          try do
            {:ok, Code.eval_string(code, binding, file: path, line: line)}
          rescue
            e -> {:error, Exception.format(:error, e, __STACKTRACE__)}
          end
        end)
      end)

    case result do
      {{:ok, {_value, binding}}, diagnostics} ->
        assert_only_host_app_diagnostics!(path, line, diagnostics)
        binding

      {{:error, message}, _diagnostics} ->
        flunk("guide sample at #{path}:#{line} does not run:\n\n#{message}")
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

      line =~ @run_marker ->
        {:closed, :run, blocks}

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

  defp verify_links!(path) do
    broken =
      path
      |> File.read!()
      |> prose_lines()
      |> Enum.flat_map(fn line ->
        # Inline code may hold `](` without being a link.
        line = String.replace(line, ~r/`[^`]*`/, "")
        for [_, target] <- Regex.scan(@link, line), not (target =~ @scheme), do: target
      end)
      |> Enum.flat_map(fn target ->
        case broken_link(path, target) do
          nil -> []
          reason -> ["#{target} (#{reason})"]
        end
      end)

    assert broken == [], "#{path} links to what does not exist:\n\n" <> Enum.join(broken, "\n")
  end

  defp broken_link(path, target) do
    {file, fragment} =
      case String.split(target, "#", parts: 2) do
        [file, fragment] -> {file, fragment}
        [file] -> {file, nil}
      end

    resolved = if file == "", do: path, else: Path.join(Path.dirname(path), file)

    cond do
      not File.exists?(resolved) -> "no such file"
      is_nil(fragment) -> nil
      fragment in anchors(File.read!(resolved)) -> nil
      true -> "no such heading in #{resolved}"
    end
  end

  # GitHub's heading ids: lowercased, punctuation dropped, each space a
  # hyphen, and a repeated id suffixed -1, -2, ...
  defp anchors(markdown) do
    markdown
    |> prose_lines()
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\#{1,6}\s+(.+?)\s*$/, line) do
        [_, heading] -> [slug(heading)]
        nil -> []
      end
    end)
    |> Enum.map_reduce(%{}, fn slug, seen ->
      count = Map.get(seen, slug, 0)
      id = if count == 0, do: slug, else: "#{slug}-#{count}"
      {id, Map.put(seen, slug, count + 1)}
    end)
    |> elem(0)
  end

  defp slug(heading) do
    heading
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{M}\p{N}\s_-]/u, "")
    |> String.replace(" ", "-")
  end

  # The lines outside code fences, where links and headings live.
  defp prose_lines(markdown) do
    markdown
    |> String.split("\n")
    |> Enum.reduce({false, []}, fn line, {fenced?, lines} ->
      cond do
        line |> String.trim_leading() |> String.starts_with?("```") -> {not fenced?, lines}
        fenced? -> {fenced?, lines}
        true -> {fenced?, [line | lines]}
      end
    end)
    |> then(fn {_fenced?, lines} -> Enum.reverse(lines) end)
  end
end
