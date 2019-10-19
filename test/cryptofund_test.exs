defmodule CryptofundTest do
  use ExUnit.Case
  doctest Cryptofund

  test "greets the world" do
    assert Cryptofund.hello() == :world
  end
end
