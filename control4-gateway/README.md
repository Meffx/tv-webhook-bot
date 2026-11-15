# Building Gateway — sterownik Control4 → MQTT

Prototyp (v0.4.0) sterownika DriverWorks, który udostępnia urządzenia z projektu
Control4 przez MQTT. Jeden egzemplarz na kontroler (lokal). Sterownik łączy się
z brokerem na serwerze (w budynku lub w chmurze), publikuje stan urządzeń i wykonuje komendy.

**Stan:** przetestowany na atrapie API Control4 z prawdziwym brokerem MQTT, po TLS
i bez (`test/`, Lua 5.1). Na prawdziwym kontrolerze (EA-3) potwierdzone: sterownik
się ładuje, a lista urządzeń i zmiennych ma oczekiwany format. Połączenie z brokerem
i sterowanie na kontrolerze **nie były jeszcze sprawdzane**.

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
| Device Filter | puste = wszystkie obsługiwane typy; albo fragmenty nazw plików sterowników po przecinku, np. `light,blind`, żeby zawęzić |
| Debug | `On` = logi w zakładce Lua |

Akcje (zakładka *Actions*): **Reconnect**, **Rescan Devices**,
**Dump Devices To Lua Output** (wypisuje urządzenia i zmienne, które zostałyby
opublikowane — bez ukrytych zmiennych i bez pomijanych sterowników).

## Które urządzenia są udostępniane

Tylko rozpoznane typy, po nazwie sterownika proxy:

| Typ (`type`) | Sterownik proxy | Pole `kind` | Najważniejsze zmienne |
|---|---|---|---|
| `light` | `light_v2.c4i` | — (`dimmable`: true/false) | 1000 `LIGHT_STATE`, 1001 `Brightness Percent` |
| `blind` | `blind.c4i` | — | 1004 `Level`, 1005 `Target Level`, 1000 `Open`, 1002 `Stopped` |
| `thermostat` | `thermostatV2.c4i` | — | 1131 `TEMPERATURE_C`, 1133 `HEAT_SETPOINT_C`, 1104 `HVAC_MODE`, 1107 `HVAC_STATE` |
| `contact` | `contactsingle_*_c4.c4i` | np. `watersensor`, `motionsensor`, `windowcontactsensor`, `doorcontactsensor`, `smokedetector` | 1000 `ContactState` |
| `relay` | `relaycontact_*_c4.c4i`, `relaysingle_*_c4.c4i` | np. `garagedoor`, `electronicgate` | 1000 `RelayState` |

Pozostałe sterowniki (kamery, domofon, usługi głosowe, multimedia, procedury) są
pomijane niezależnie od *Device Filter*, bo trzymają w zmiennych hasła i kody
parowania. Z tego samego powodu nie są publikowane zmienne oznaczone jako ukryte.

Komendy wysyła się na identyfikator proxy (ten z listy `devices`). Typowe komendy
Control4 — **do potwierdzenia na urządzeniach**:

| Typ | Komendy |
|---|---|
| `light` | `ON`, `OFF`, `TOGGLE`, `RAMP_TO_LEVEL` `{LEVEL, TIME}` |
| `blind` | `SET_LEVEL_TARGET` `{LEVEL_TARGET}`, `UP`, `DOWN`, `STOP` |
| `thermostat` | `SET_SETPOINT_HEAT` `{CELSIUS}`, `SET_MODE_HVAC` `{MODE}` |
| `relay` | `OPEN`, `CLOSE`, `TOGGLE`, `TRIGGER` `{TIME}` |

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
- Nieudane połączenie (zły adres, odrzucony certyfikat) jest zgłaszane dopiero po
  15 s jako `connection timed out`, bez podania przyczyny.
- Brak zdalnej aktualizacji sterownika.
