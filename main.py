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

    print(f"→ Zlecenie: {direction} {symbol} | SL: {sl} | TP: {tp} | Rozmiar: {qty_pct}%")

    return jsonify({"status": "received"}), 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=10000)
