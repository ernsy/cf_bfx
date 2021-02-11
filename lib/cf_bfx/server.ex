defmodule CfBfx.Server do
  @moduledoc false

  use GenServer
  require Logger
  alias CfBfx.API, as: API

  @minimum_fund_amount 50.01
  @check_offer_period 60000 * 10
  @check_ws_conn_period 60000 * 5
  @reset_period 60000 * 30
  @offer_volume_threshold_percent 1 / 24 / 6

  defguardp is_fiat(currency) when currency == "USD" or currency == "GBP"

  #---------------------------------------------------------------------------------------------------------------------
  # API
  #---------------------------------------------------------------------------------------------------------------------

  def handle_ws_frame(msg) do
    GenServer.cast(__MODULE__, msg)
  end

  def check_all_available_funding_balances() do
    GenServer.cast(__MODULE__, :check_all_available_funding_balances)
  end

  def update_reserve_balance(currency, balance) do
    GenServer.cast(__MODULE__, {:update_reserve_balance, currency, balance})
  end

  #---------------------------------------------------------------------------------------------------------------------
  # genserver callbacks
  #---------------------------------------------------------------------------------------------------------------------

  def start_link(state) do
    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  def init(_opts) do
    Logger.info("Starting Application...")
    :ok = cancel_all_active_offers()
    {:ok, client} = API.connect_auth_ws_v2()
    {:ok, _table} = :dets.open_file(:disk_storage, [type: :set])
    Process.send_after(self(), :check_offers, @check_offer_period)
    keep_alive_timer = Process.send_after(self(), :reset_ws_conn, @check_ws_conn_period)
    Process.send_after(self(), :reset_ws_conn, @reset_period)
    state = %{
      wallets: %{},
      ws_client: client,
      keep_alive_timer: keep_alive_timer
    }
    {:ok, state}
  end

  def handle_call(_msg, _from, state) do
    {:reply, :ok, state}
  end

  def handle_cast([_, "wu", [_, "GBP", _, _, _ | _]], state) do
    {:noreply, state}
  end

  def handle_cast(
        [
          _chan_id,
          frame_type,
          [wallet_type, currency, _balance, _unsettled_interest, _balance_available | _] = frame_body
        ],
        %{wallets: wallets0} = state
      ) when frame_type == "wu" do
    Logger.info("wu frame_body: #{inspect frame_body}")
    {:ok, wallets1} = update_wallets([frame_body], wallets0)
    if wallet_type == "funding" do
      wallet = get_in(wallets1, [wallet_type, currency])
      process_available_funding_balance(currency, wallet)
    end
    {:noreply, %{state | wallets: wallets1}}
  end
  def handle_cast(
        [_chan_id, frame_type, frame_body],
        %{:wallets => wallets0} = state
      ) when frame_type == "ws" do
    {:ok, wallets1} = update_wallets(frame_body, wallets0)
    {:noreply, %{state | wallets: wallets1}}
  end
  def handle_cast(:check_all_available_funding_balances, %{wallets: wallets} = state) do
    Enum.each(
      Map.get(wallets, "funding", %{}),
      &process_available_funding_balance/2
    )
    {:noreply, state}
  end
  # heartbeat
  def handle_cast([_chan_id_, "hb"] = msg, %{keep_alive_timer: old_timer} = state) do
    Process.cancel_timer(old_timer)
    Logger.debug("cast msg hb: #{inspect msg}")
    timer = Process.send_after(self(), :reset_ws_conn, @check_ws_conn_period)
    {:noreply, %{state | keep_alive_timer: timer}}
  end
  def handle_cast({:update_reserve_balance, currency, reserve_balance}, state) do
    :ok = :dets.insert(:disk_storage, {currency, reserve_balance})
    cancel_all_active_offers()
    {:noreply, state}
  end
  def handle_cast(msg, state) do
    Logger.debug("cast msg: #{inspect msg}")
    {:noreply, state}
  end

  def handle_info(:check_offers, state) do
    cancel_all_active_offers()
    Process.send_after(self(), :check_offers, @check_offer_period)
    {:noreply, state}
  end
  def handle_info(:reset_ws_conn, %{ws_client: ws_client} = state) do
    Logger.debug("reset")
    DynamicSupervisor.terminate_child(CF.WebsocketSupervisor, ws_client)
    {:ok, new_ws_client} = API.connect_auth_ws_v2()
    Process.send_after(self(), :reset_ws_conn, @reset_period)
    {:noreply, %{state | ws_client: new_ws_client}}
  end
  def handle_info(msg, state) do
    Logger.debug("info msg: #{inspect msg}")
    {:noreply, state}
  end

  def terminate(_reason, _state) do
    :dets.close(:disk_storage)
  end

  #---------------------------------------------------------------------------------------------------------------------
  # private functions
  #---------------------------------------------------------------------------------------------------------------------

  defp cancel_all_active_offers() do
    case API.get_active_offers_v1() do
      {:ok, offers} ->
        Enum.each(
          offers,
          fn
            (%{"currency" => "GBP"}) -> :ok
            (%{"id" => id}) -> API.cancel_offer_v1(id)
          end
        )
      _ ->
        :ok
    end
  end

  defp update_wallets([], wallets) do
    {:ok, wallets}
  end
  defp update_wallets(
         [[wallet_type, currency, balance, unsettled_interest, balance_available | _] | rest_wallets],
         wallets0
       ) do
    wallets1 = put_in(
      wallets0,
      Enum.map([wallet_type, currency], &Access.key(&1, %{})),
      %{balance: balance, unsettled_interest: unsettled_interest, balance_available: balance_available}
    )
    update_wallets(rest_wallets, wallets1)
  end

  defp process_available_funding_balance(_currency, %{:balance_available => balance_available})
       when is_nil(balance_available) do
    :ok
  end
  defp process_available_funding_balance(currency, %{:balance_available => balance_available}) when is_fiat(currency) do
    exchange_rate = get_usd_exchange_rate(currency)
    process_available_funding_balance(currency, balance_available, exchange_rate)
  end
  defp process_available_funding_balance(currency, %{:balance_available => balance_available}) do
    {:ok, ticker} = API.get_trade_ticker_v2(currency)
    process_available_funding_balance(currency, balance_available, ticker.bid)
  end
  defp process_available_funding_balance(_currency, _balance_available, exchange_rate) when is_nil(exchange_rate) do
    :ok
  end
  defp process_available_funding_balance(currency, balance_available, exchange_rate) do
    offer_amount = calc_offer_amount(balance_available, currency)
    maybe_create_funding_offer(currency, offer_amount, exchange_rate)
  end

  defp calc_offer_amount(balance_available, currency) do
    case :dets.lookup(:disk_storage, currency) do
      [{_currency, reserve_balance}] when not is_nil(balance_available) ->
        balance_available - reserve_balance - 0.00000001
      _ ->
        balance_available
    end
  end

  defp maybe_create_funding_offer(currency, amount, exch_rate) when amount * exch_rate >= @minimum_fund_amount  do
    {:ok, ticker} = API.get_funding_ticker_v2(currency)
    {:ok, funding_book} = API.get_funding_book(currency, "0", "5000")
    asks = funding_book["asks"]
    {:ok, funding_offer_rate} = calc_funding_offer_rate(asks, ticker.volume, @offer_volume_threshold_percent)
    period = cond do
      funding_offer_rate >= 20 -> 120
      funding_offer_rate >= 15 -> 30
      true -> 2
    end
    API.create_funding_offer_v1(currency, amount, funding_offer_rate, period)
  end
  defp maybe_create_funding_offer(currency, amount, exch_rate) do
    Logger.debug("no order: #{inspect currency} balance: #{inspect amount} ex_rate: #{inspect exch_rate}")
  end

  defp calc_funding_offer_rate(asks, volume, threshold_percent) do
    volume_threshold = volume * threshold_percent
    Enum.reduce_while(
      asks,
      0,
      fn (ask, prev_sum) ->
        amount = String.to_float(ask["amount"])
        sum = prev_sum + amount
        if sum >= volume_threshold do
          {:halt, {:ok, String.to_float(ask["rate"]) - 1.0e-6}}
        else
          {:cont, sum}
        end
      end
    )
  end

  #---------------------------------------------------------------------------------------------------------------------
  # exchange rate api
  #---------------------------------------------------------------------------------------------------------------------
  defp get_usd_exchange_rate(currency) when currency == "USD" do
    1.0
  end
  defp get_usd_exchange_rate(currency) do
    url = "https://api.exchangeratesapi.io/latest?base=" <> currency
    {:ok, %HTTPoison.Response{status_code: 200, body: body}} = HTTPoison.get(url)
    rates = Jason.decode!(body)
    get_in(rates, ["rates", "USD"])
  end

end
