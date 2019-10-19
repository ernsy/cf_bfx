defmodule CfBfx.Application do
  @moduledoc false



  use Application

  def start(_type, _args) do
    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: CF.WebsocketSupervisor},
      CfBfx.Server
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: CfBfx.Supervisor]
    Supervisor.start_link(children, opts)
  end
end