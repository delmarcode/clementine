defmodule Clementine.Runs.LoopConformanceTest do
  @moduledoc """
  The loop battery against the durable runtime and the library's own
  Postgres: `Clementine.LoopCase`'s matrix rows L1–L17, children through
  the start path, the `{:cancel, tag}` action, the loop sweep's verdicts,
  and the lane matrix.
  """

  use Clementine.LoopCase, repo: Clementine.TestRepo, moduletag: :postgres
end
