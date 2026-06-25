defmodule Clementine.CancelTokenTest do
  use ExUnit.Case, async: true

  alias Clementine.CancelToken

  describe "new/0" do
    test "creates an un-cancelled token" do
      token = CancelToken.new()
      refute CancelToken.cancelled?(token)
    end

    test "returns independent tokens" do
      a = CancelToken.new()
      b = CancelToken.new()

      CancelToken.cancel(a)

      assert CancelToken.cancelled?(a)
      refute CancelToken.cancelled?(b)
    end
  end

  describe "cancel/1" do
    test "marks the token as cancelled" do
      token = CancelToken.new()
      assert CancelToken.cancel(token) == :ok
      assert CancelToken.cancelled?(token)
    end

    test "is idempotent" do
      token = CancelToken.new()
      CancelToken.cancel(token)
      CancelToken.cancel(token)
      assert CancelToken.cancelled?(token)
    end

    test "is observable from another process" do
      token = CancelToken.new()
      parent = self()

      spawn(fn ->
        CancelToken.cancel(token)
        send(parent, :cancelled)
      end)

      assert_receive :cancelled
      assert CancelToken.cancelled?(token)
    end
  end
end
