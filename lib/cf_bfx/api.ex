defmodule CfBfx.API do

  require Logger

  @max_req_per_minute 10
  @retry_count (60 / @max_req_per_minute)

  #---------------------------------------------------------------------------------------------------------------------
  # public functions
  #---------------------------------------------------------------------------------------------------------------------
  def connect_auth_ws_v2() do
    {:ok, client} = DynamicSupervisor.start_child(
      CF.WebsocketSupervisor,
      {CfBfx.Websocket, ["wss://api.bitfinex.com/ws/2", %{}]}
    )
    {:ok, api_key, api_secret, nonce} = get_auth_args()
    json_login_payload = create_ws_login_json_payload(api_key, api_secret, nonce)
    Logger.debug("Initiating WS Conn")
    CfBfx.Websocket.send(client, :text, json_login_payload)
    {:ok, client}
  end

  def get_account_info_v1() do
    invoke_private_api_v1("/v1/account_infos", %{})
  end

  def create_funding_offer_v1(currency, amount, rate, period) do
    params = %{
      currency: currency,
      amount: to_string(amount),
      rate: to_string(rate),
      period: period,
      direction: "lend"
    }
    invoke_private_api_v1("/v1/offer/new", params)
  end

  def get_active_offers_v1() do
    invoke_private_api_v1("/v1/offers", %{})
  end

  def cancel_offer_v1(offer_id) do
    invoke_private_api_v1("/v1/offer/cancel", %{offer_id: offer_id})
  end

  #TODO move common part to invoke_private_api_v2
  def get_wallet_balances_v2(api_key, api_secret, nonce) do
    api_path = "/v2/auth/r/wallets"
    body = "{}"
    auth_payload = "/api/" <> api_path <> to_string(nonce) <> body
    auth_sig = create_auth_sig(api_secret, auth_payload)
    url = "https://api.bitfinex.com" <> api_path
    headers = ["Content-Type": "application/json", "bfx-nonce": nonce, "bfx-apikey": api_key, "bfx-signature": auth_sig]
    Logger.info("private api v2 url: #{inspect url} post_data #{inspect body}")
    check_http_response(HTTPoison.post(url, body, headers))
  end

  def get_funding_book(currency, bids \\ "50", asks \\ "50") do
    invoke_public_api_v1("/v1/lendbook/" <> currency <> "?limit_bids=" <> bids <> "&limit_asks=" <> asks)
  end

  def get_trade_ticker_v2(currency) do
    {
      :ok,
      [
        bid,
        bid_size,
        ask,
        ask_size,
        daily_change,
        daily_change_perc,
        last_price,
        volume,
        high,
        low
      ]
    } = if currency == "XAUT" do
      invoke_public_api_v2("/v2/ticker/" <> "t" <> currency <> ":USD")
    else
      invoke_public_api_v2("/v2/ticker/" <> "t" <> currency <> "USD")
    end
    {
      :ok,
      %{
        bid: bid,
        bid_size: bid_size,
        ask: ask,
        ask_size: ask_size,
        daily_change: daily_change,
        daily_change_perc: daily_change_perc,
        last_price: last_price,
        volume: volume,
        high: high,
        low: low
      }
    }
  end

  def get_funding_ticker_v2(currency) do
    {
      :ok,
      [
        frr,
        bid,
        bid_period,
        bid_size,
        ask,
        ask_period,
        ask_size,
        daily_change,
        daily_change_perc,
        last_price,
        volume,
        high,
        low,
        _,
        _,
        _,
      ]
    } = invoke_public_api_v2("/v2/ticker/" <> "f" <> currency)
    {
      :ok,
      %{
        frr: frr,
        bid: bid,
        bid_period: bid_period,
        bid_size: bid_size,
        ask: ask,
        ask_period: ask_period,
        ask_size: ask_size,
        daily_change: daily_change,
        daily_change_perc: daily_change_perc,
        last_price: last_price,
        volume: volume,
        high: high,
        low: low
      }
    }
  end

  #---------------------------------------------------------------------------------------------------------------------
  # private functions
  #---------------------------------------------------------------------------------------------------------------------
  defp invoke_private_api_v1(path, params) do
    retry_req(&do_invoke_private_api_v1/1, [path, params])
  end

  defp do_invoke_private_api_v1([path, params]) do
    {:ok, api_key, api_secret, nonce} = get_auth_args()
    nonce_str = to_string(nonce)
    endpoint = "https://api.bitfinex.com"
    url = endpoint <> path

    post_data = Map.merge(params, %{request: path, nonce: nonce_str})
    auth_payload = post_data
                   |> Jason.encode!()
                   |> Base.encode64
    auth_sig = create_auth_sig(api_secret, auth_payload)

    # Transform the data into list-of-tuple format required by HTTPoison.
    post_data = Map.to_list(post_data)
    headers = [{"X-BFX-APIKEY", api_key}, {"X-BFX-PAYLOAD", auth_payload}, {"X-BFX-SIGNATURE", auth_sig}]
    Logger.info("private api v1 url: #{inspect url} post_data #{inspect post_data}")
    HTTPoison.post(url, {:form, post_data}, headers)
  end

  defp invoke_public_api_v1(path) do
    url = "https://api.bitfinex.com" <> path
    Logger.info("public api v1 url: #{inspect url}")
    retry_req(&HTTPoison.get/1, url)
  end

  defp invoke_public_api_v2(path) do
    url = "https://api-pub.bitfinex.com" <> path
    Logger.info("public api v2 url: #{inspect url}")
    retry_req(&HTTPoison.get/1, url)
  end

  defp retry_req(req_fun, params, retry_count \\ @retry_count)
  defp retry_req(req_fun, params, 1) do
    http_resp = req_fun.(params)
    check_http_response(http_resp)
  end
  defp retry_req(req_fun, params, retry_count) do
    http_resp = req_fun.(params)
    case check_http_response(http_resp) do
      {:error, {429, _body}} ->
        Process.sleep(round(60000 / @max_req_per_minute))
        retry_req(req_fun, params, retry_count - 1)
      response -> response
    end
  end

  defp check_http_response({:ok, %HTTPoison.Response{status_code: 200, body: json_body}}) do
    body = Jason.decode!(json_body)
    Logger.info("Bitfinex Response: {200, #{inspect body}}")
    {:ok, body}
  end
  defp check_http_response({:ok, %HTTPoison.Response{status_code: status_code, body: json_body}}) do
    body = case Jason.decode(json_body) do
      {:ok, decodedBody} -> decodedBody
      {:error, _} -> json_body
    end
    Logger.warn("Bitfinex Response: {#{inspect status_code}, #{inspect body}}")
    {:error, {status_code, body}}
  end
  defp check_http_response(error) do
    Logger.error(error)
    error
  end

  defp get_auth_args() do
    api_key = System.get_env("api_key")
    api_secret = System.get_env("api_secret")
    nonce = DateTime.to_unix(DateTime.utc_now(), :microsecond)
    {:ok, api_key, api_secret, nonce}
  end

  defp create_ws_login_json_payload(api_key, api_secret, nonce) do
    auth_payload = "AUTH" <> to_string(nonce)
    auth_sig = create_auth_sig(api_secret, auth_payload)

    payload = %{
      "event" => "auth",
      "apiKey" => api_key,
      "authSig" => auth_sig,
      "authPayload" => auth_payload,
      "authNonce" => nonce,
      "filter" => [
        #"trading",               # orders, positions, trades
        #"trading-tBTCUSD",       # tBTCUSD orders, positions, trades
        "funding", # offers, credits, loans, funding trades
        #"funding-fBTC",          # fBTC offers, credits, loans, funding trades
        "wallet", # wallet
        #"wallet-exchange-BTC",   # Exchange BTC wallet changes
        #"algo",                  # algorithmic orders
        "balance", # balance (tradable balance, ...)
        "notify"                  # notifications
      ]
    }
    Jason.encode!(payload)
  end

  defp create_auth_sig(api_secret, auth_payload) do
    :crypto.hmac(:sha384, api_secret, auth_payload)
    |> Base.encode16
    |> String.downcase
  end

end