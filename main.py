import os
import requests
from flask import Flask, request, jsonify

app = Flask(__name__)

# Ustawienia API Capital.com
CAPITAL_API_KEY = os.getenv("CAPITAL_API_KEY") or "O8gMfVZEJVzA77F9"
CAPITAL_API_URL = "https://api-capital.backend-capital.com"

# Endpoint webhooka z TradingView
@app.route('/webhook', methods=['POST'])
def webhook():
    data = request.json
    print("✅ Otrzymano alert z TradingView:", data)

    try:
        direction = data.get("direction")
        symbol = data.get("symbol", "XAUUSD")
        qty_pct = float(data.get("quantity_pct", 30))
        sl = float(data.get("sl"))
        tp = float(data.get("tp"))

        place_order(direction, symbol, qty_pct, sl, tp)
        return jsonify({"status": "received"}), 200

    except Exception as e:
        print("❌ Błąd przetwarzania webhooka:", e)
        return jsonify({"error": str(e)}), 400

# Funkcja pobierająca dostępne saldo
def get_account_balance():
    headers = {"X-CAP-API-KEY": CAPITAL_API_KEY}
    try:
        response = requests.get(f"{CAPITAL_API_URL}/accounts", headers=headers)
        data = response.json()
        return float(data["balance"]["available"])
    except Exception as e:
        print("❌ Błąd pobierania salda:", e)
        return 0.0

# Główna funkcja składania zlecenia
def place_order(direction, symbol, qty_pct, sl, tp):
    headers = {
        "X-CAP-API-KEY": CAPITAL_API_KEY,
        "Content-Type": "application/json"
    }

    side = "BUY" if direction.lower() == "buy" else "SELL"

    # 1. Pobierz saldo konta i wylicz wielkość pozycji
    balance = get_account_balance()
    risk_capital = balance * (qty_pct / 100)

    entry_price = (sl + tp) / 2
    nominal_value = entry_price * 100  # 1 lot = 100 uncji
    size = max(round(risk_capital / nominal_value, 2), 0.01)  # minimalnie 0.01

    # 2. Oblicz odległości TP/SL w pipsach (wartości level)
    stop_level = round(abs(entry_price - sl), 2)
    limit_level = round(abs(tp - entry_price), 2)

    print(f"📊 Saldo: ${balance:.2f} → ryzykujemy: ${risk_capital:.2f}")
    print(f"📈 Pozycja: {side}, Rozmiar: {size} lot, SL: {stop_level}, TP: {limit_level}")

    # 3. Zbuduj zlecenie
    order_data = {
        "epic": "CS.D.GOLD.CFD.IP",  # symbol XAUUSD w Capital.com
        "direction": side,
        "size": size,
        "orderType": "MARKET",
        "timeInForce": "FILL_OR_KILL",
        "stopLevel": stop_level,
        "limitLevel": limit_level,
        "currencyCode": "USD",
        "forceOpen": True
    }

    # 4. Wyślij zlecenie
    try:
        response = requests.post(f"{CAPITAL_API_URL}/positions", json=order_data, headers=headers)
        response.raise_for_status()
        print("✅ Zlecenie zrealizowane:", response.json())
    except requests.exceptions.RequestException as e:
        print("❌ Błąd przy składaniu zlecenia:", e)
