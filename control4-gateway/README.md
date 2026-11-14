# Building Gateway — sterownik Control4 → MQTT

Prototyp (v0.3.0) sterownika DriverWorks, który udostępnia urządzenia z projektu
Control4 przez MQTT. Jeden egzemplarz na kontroler (lokal). Sterownik łączy się
z brokerem na serwerze (w budynku lub w chmurze), publikuje stan urządzeń i wykonuje komendy.

**Stan:** przetestowany na atrapie API Control4 z prawdziwym brokerem MQTT, po TLS
i bez (`test/`, Lua 5.1), **nieuruchamiany jeszcze na prawdziwym kontrolerze**.

## Wymagania

- Control4 OS 2.10.0 lub nowszy. Sterownik ma własną obsługę MQTT 3.1.1 i JSON,
  więc nie korzysta z wbudowanego klienta MQTT (dostępnego dopiero w nowszych OS)
  i ten sam plik działa na wszystkich kontrolerach.
- Broker MQTT osiągalny z kontrolera (np. Mosquitto). Połączenie jest wychodzące
  z kontrolera, więc broker może być w chmurze; w lokalu nie trzeba przekierowywać portów.
- Composer Pro.

## Budowanie

```sh
./build.sh          # tworzy dist/building_gateway.c4z
python3 test/run_test.py   # testy (wymaga: pip install lupa amqtt paho-mqtt)
```

## Instalacja

1. Skopiuj `building_gateway.c4z` do katalogu sterowników Composera
   (`Documents\Control4\Drivers`).
2. W Composer Pro: *System Design* → wyszukaj **Building Gateway** → dodaj do projektu.
3. Ustaw właściwości:

| Właściwość | Znaczenie |
|---|---|
| Broker Address | adres IP lub nazwa serwera z brokerem |
| Port | domyślnie 8883 (TLS); bez szyfrowania zwykle 1883 |
| Encryption | `TLS` (domyślnie) lub `None` — bez szyfrowania tylko do testów w sieci lokalnej |
| Verify Certificate | `On` (domyślnie) — certyfikat brokera musi pochodzić od urzędu z pliku `ca.pem` |
| Username / Password | konto tego lokalu na brokerze |
| Unit ID | identyfikator lokalu, np. `101`; puste = adres MAC kontrolera |
| Device Filter | puste = wszystkie urządzenia; albo fragmenty nazw plików sterowników po przecinku, np. `light,thermostat,blind` |
| Debug | `On` = logi w zakładce Lua |

Akcje (zakładka *Actions*): **Reconnect**, **Rescan Devices**,
**Dump Devices To Lua Output** (wypisuje surowe dane o urządzeniach i zmiennych).

## Tematy MQTT

Prefiks: `c4/<Unit ID>/`

| Temat | Kierunek | Treść |
|---|---|---|
| `status` | → serwer | `online` / `offline` (retained, last will) |
| `devices` | → serwer | JSON: lista urządzeń z pokojami i zmiennymi (retained) |
| `state/<deviceId>/<varId>` | → serwer | bieżąca wartość zmiennej (retained) |
| `cmd` | serwer → | komenda w JSON |
| `cmd/result` | → serwer | `{"id":"…","ok":true}` lub `{"ok":false,"error":"…"}` |

Komenda dla urządzenia (nazwy komend i parametrów jak w Control4):

```json
{"id":"a1","device":41,"command":"RAMP_TO_LEVEL","params":{"LEVEL":60,"TIME":1000}}
```

Komenda dla samej bramki: `{"command":"RESCAN"}`.

`ok: true` oznacza, że komenda została przekazana urządzeniu; faktyczny skutek
widać po zmianie w `state/…`. Komendy do urządzeń spoza listy `devices` są odrzucane.

## Pierwszy test

```sh
# lokalny test bez szyfrowania: Encryption = None, Port = 1883
mosquitto_sub -h <serwer> -u <user> -P <hasło> -v -t 'c4/#'
mosquitto_pub -h <serwer> -u <user> -P <hasło> -t 'c4/101/cmd' \
  -m '{"id":"t1","device":41,"command":"TOGGLE"}'
```

## Szyfrowanie (TLS)

W paczce jest plik `driver/ca.pem` — certyfikat urzędu, którym sterownik sprawdza
tożsamość brokera. Domyślnie to **ISRG Root X1 (Let's Encrypt)**, więc broker
z certyfikatem Let's Encrypt zadziała bez zmian. Przy własnym urzędzie certyfikacji
podmień `driver/ca.pem` i przebuduj paczkę.

Do sprawdzenia na kontrolerze:

- czy OS 2.10 obsługuje TLS 1.2 — dokumentacja Control4 wymienia dla tego API tylko
  starsze wersje protokołu; jeśli nie, na brokerze trzeba dopuścić starszą wersję
  na porcie przeznaczonym dla kontrolerów;
- czy sprawdzana jest także nazwa hosta w certyfikacie, czy tylko podpis urzędu;
- `Verify Certificate = Off` szyfruje, ale nie chroni przed podstawionym serwerem —
  tylko do diagnostyki.

## Znane ograniczenia

- **QoS 0** — komunikaty nie są potwierdzane. Stan jest publikowany jako retained
  i w całości odświeżany po każdym ponownym połączeniu.
- Format danych zwracanych przez `C4:GetDevices` i `C4:GetDeviceVariables` na
  prawdziwym kontrolerze nie był weryfikowany — w razie pustej listy urządzeń
  uruchom akcję *Dump* i sprawdź wynik.
- Nieudane połączenie (zły adres, odrzucony certyfikat) jest zgłaszane dopiero po
  15 s jako `connection timed out`, bez podania przyczyny.
- Brak zdalnej aktualizacji sterownika.
