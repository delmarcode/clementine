defmodule Clementine.InterruptReasonTest do
  use ExUnit.Case, async: true

  alias Clementine.InterruptReason

  test "the standard code set is closed and known" do
    assert :lease_expired in InterruptReason.codes()
    assert :claim_timeout in InterruptReason.codes()
    assert :drain in InterruptReason.codes()
    assert :suspension_expired in InterruptReason.codes()
  end

  test "new/2 builds standard reasons with optional detail" do
    assert %InterruptReason{code: :lease_expired, detail: nil} =
             InterruptReason.new(:lease_expired)

    assert %InterruptReason{code: :deadline_exceeded, detail: "ran 12m"} =
             InterruptReason.new(:deadline_exceeded, "ran 12m")
  end

  test "new/2 accepts the app escape hatch" do
    assert %InterruptReason{code: {:app, :budget_blown}} =
             InterruptReason.new({:app, :budget_blown})
  end

  test "new/2 refuses to mint unknown mechanism vocabulary" do
    assert_raise FunctionClauseError, fn -> InterruptReason.new(:made_up_code) end
  end
end
