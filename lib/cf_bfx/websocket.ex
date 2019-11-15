defmodule CfBfx.Websocket do
  @moduledoc false

  use WebSockex
  require Logger

  def send(client, type, msg) do
    WebSockex.send_frame(client, {type, msg})
  end

  def start_link([url, state]) do
    WebSockex.start_link(url, __MODULE__, state)
  end

  def handle_connect(conn, state) do
    Logger.debug "Connected - conn: #{inspect conn}"
    {:ok, state}
  end

  def handle_frame({_type, frame_body}, state) do
    decoded_frame_body = Jason.decode!(frame_body)
    Logger.debug("decoded_frame_body #{inspect decoded_frame_body}")
    CfBfx.Server.handle_ws_frame(decoded_frame_body)
    {:ok, state}
  end

  def handle_cast({:send, frame}, state) do
    {:reply, frame, state}
  end

end
