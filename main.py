from flask import Flask, request, jsonify

app = Flask(__name__)

@app.route('/webhook', methods=['POST'])
def webhook():
    data = request.json
    print("✅ Otrzymano alert z TradingView:", data)

    # Parsowanie sygnału
    direction = data.get("direction")
    symbol = data.get("symbol", "XAUUSD")
    qty_pct = float(data.get("quantity_pct", 30))
    sl = float(data.get("sl"))
    tp = float(data.get("tp"))

   place_order(direction, symbol, qty_pct, sl, tp)

    return jsonify({"status": "received"}), 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=10000)

import requests

CAPITAL_API_KEY = "TUTAJ_WKLEJ_SWÓJ_API_KEY"
CAPITAL_API_URL = "https://api-capital.backend-capital.com"

def place_order(direction, symbol, qty_pct, sl, tp):
    # 1. Uwierzytelnienie
    headers = {
        "X-CAP-API-KEY": O8gMfVZEJVzA77F9,
        "Content-Type": "application/json"
    }

    # 2. Ustal parametry zlecenia
    side = "BUY" if direction.lower() == "buy" else "SELL"
    quantity = 0.01  # docelowo przeliczymy to na podstawie qty_pct i salda

    # 3. Zbuduj body zlecenia
    order_data = {
        "epic": "CS.D.GOLD.CFD.IP",  # XAUUSD epic na Capital.com (standard CFD)
        "direction": side,
        "size": quantity,
        "orderType": "MARKET",
        "timeInForce": "FILL_OR_KILL",
        "stopLevel": round(abs(sl - tp), 2),
        "limitLevel": round(abs(tp - sl), 2),
        "currencyCode": "USD",
        "forceOpen": True
    }

    # 4. Wyślij zlecenie
    try:
        response = requests.post(f"{CAPITAL_API_URL}/positions", json=order_data, headers=headers)
        response.raise_for_status()
        print("✅ Zlecenie wysłane pomyślnie:", response.json())
    except requests.exceptions.RequestException as e:
        print("❌ Błąd przy wysyłaniu zlecenia:", e)
