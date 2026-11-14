# Building Gateway — sterownik Control4 → MQTT

Prototyp (v0.1.0) sterownika DriverWorks, który udostępnia urządzenia z projektu
Control4 przez MQTT. Jeden egzemplarz na kontroler (lokal). Sterownik łączy się
z brokerem na serwerze budynku, publikuje stan urządzeń i wykonuje komendy.

**Stan:** logika przetestowana na atrapie API (`test/`), **nieuruchamiana jeszcze
na prawdziwym kontrolerze**.

## Wymagania

- Wbudowany klient MQTT (`C4:MQTT`). Dokumentacja Control4 podaje go jako dostępny
  od OS 4.0.0; otwarty sterownik `finitelabs/control4-mqtt` deklaruje działanie od
  OS 3.3. Na starszym systemie sterownik pokaże w polu *Status*:
  `MQTT API not available on this OS version`.
- Broker MQTT osiągalny z kontrolera (np. Mosquitto).
- Composer Pro.

## Budowanie

```sh
./build.sh          # tworzy dist/building_gateway.c4z
python3 test/run_test.py   # testy na atrapie (wymaga: pip install lupa)
```

## Instalacja

1. Skopiuj `building_gateway.c4z` do katalogu sterowników Composera
   (`Documents\Control4\Drivers`).
2. W Composer Pro: *System Design* → wyszukaj **Building Gateway** → dodaj do projektu.
3. Ustaw właściwości:

| Właściwość | Znaczenie |
|---|---|
| Broker Address | adres IP lub nazwa serwera z brokerem |
| Port | domyślnie 1883 |
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
mosquitto_sub -h <serwer> -u <user> -P <hasło> -v -t 'c4/#'
mosquitto_pub -h <serwer> -u <user> -P <hasło> -t 'c4/101/cmd' \
  -m '{"id":"t1","device":41,"command":"TOGGLE"}'
```

## Znane ograniczenia

- **Brak TLS** — login i hasło idą otwartym tekstem; do czasu dodania TLS używać
  tylko w wydzielonej sieci budynku.
- Format danych zwracanych przez `C4:GetDevices` i `C4:GetDeviceVariables` na
  prawdziwym kontrolerze nie był weryfikowany — w razie pustej listy urządzeń
  uruchom akcję *Dump* i sprawdź wynik.
- Brak zdalnej aktualizacji sterownika.
