# Kontekst projektu — stan na 2026-11-15

Skrót wcześniejszej rozmowy, dla nowej sesji. Szczegóły techniczne są w
`README.md` (sterownik) i `server/README.md` (serwer).

## Cel

Własna aplikacja do sterowania inteligentnym budynkiem opartym na Control4,
zamiast aplikacji Control4. Właściciel jest instalatorem (dealerem) i ma Composer Pro.

- Około 300 kontrolerów, po jednym na lokal; **każdy lokal ma własne łącze internetowe**.
- Część kontrolerów ma stary system: **OS 2.10.0 i 2.10.6**.
- Aplikacja ma być dla wielu użytkowników (mieszkańcy widzą swój lokal, administracja całość).
- Urządzenia: ściemniacze, przekaźniki, rolety, okna, termostaty, czujniki zalania.

## Podjęte decyzje

1. **Sterownik na każdym kontrolerze** (`driver/`, plik `.c4z`) łączy się wychodząco
   z serwerem przez MQTT po TLS. W lokalach nie trzeba otwierać żadnych portów.
   Odrzucone: Home Assistant, biblioteka `pyControl4` (wymaga chmury Control4 i 300 kont).
2. **Serwer w chmurze**: Hetzner, Helsinki, Ubuntu 26.04. Domena: `mqtt.automatify.pl`.
3. **Broker Mosquitto** z certyfikatem Let's Encrypt; każdy kontroler ma własne konto
   ograniczone do tematów `c4/<Unit ID>/…` (login = Unit ID).
4. Aplikacja docelowo jako PWA + backend z kontami i uprawnieniami — **jeszcze nie zaczęta**.

## Co jest zrobione

- **Sterownik v0.4.0** — własna implementacja MQTT 3.1.1 i JSON (działa od OS 2.10),
  TLS przez dynamiczne połączenie sieciowe, weryfikacja certyfikatu plikiem `driver/ca.pem`
  (ISRG Root X1). Udostępnia tylko światła, rolety, termostaty, czujniki i przekaźniki,
  bez ukrytych zmiennych.
- **Testy** (`test/run_test.py`): sterownik na atrapie API Control4, z prawdziwym brokerem,
  po TLS i bez. Przechodzą.
- **Skrypty serwera** (`server/setup.sh`, `server/add-unit.sh`): reguły dostępu sprawdzone
  lokalnie na Mosquitto 2.0.

## Co potwierdzono na prawdziwym sprzęcie

- Sterownik ładuje się na kontrolerze testowym (EA-3) i poprawnie czyta urządzenia i zmienne.
- Każde urządzenie występuje dwa razy: sterownik sprzętowy (bez zmiennych) i proxy
  (ze zmiennymi). Komendy wysyła się na identyfikator proxy.
- W tym projekcie sekcje podlewania są skonfigurowane jako światła, a stacja pogodowa
  jako termostat.

## Czego jeszcze NIE sprawdzono

- Połączenia sterownika z brokerem i sterowania urządzeniami na prawdziwym kontrolerze.
- TLS na kontrolerze z OS 2.10 (czy obsługuje TLS 1.2; czy sprawdza nazwę hosta).
- `server/setup.sh` na prawdziwym serwerze (instalacja pakietów, certbot).
- Nazw komend dla rolet i termostatów na sterownikach Infigate i Beckhoff.

## Stan serwera

- Serwer w Hetznerze jest utworzony, **bez klucza SSH** (hasło roota przyszło e-mailem).
- Niewiadome, do sprawdzenia: czy rekord DNS `mqtt.automatify.pl` (typ A) już wskazuje
  na serwer; czy zapora w panelu Hetznera jest ustawiona.

## Następne kroki

1. Rekord DNS: `mqtt` typu A → adres IPv4 serwera (robi właściciel w panelu domeny).
2. Wgrać klucz SSH (`ssh-keygen -t ed25519`, `ssh-copy-id root@ADRES_IP`), potem wyłączyć
   logowanie hasłem (`PasswordAuthentication no` w `/etc/ssh/sshd_config.d/00-keys-only.conf`).
3. Zapora: TCP 22, 80 (certyfikat), 8883 (kontrolery); później 443 dla aplikacji.
4. `apt update && apt upgrade`, potem na serwerze:
   `./setup.sh mqtt.automatify.pl <e-mail właściciela>` i `./add-unit.sh test1`.
5. W Composerze ustawić sterownik: Broker Address `mqtt.automatify.pl`, Port 8883,
   Encryption TLS, Verify Certificate On, Unit ID i Username `test1`, hasło z `add-unit.sh`.
6. Sprawdzić pole *Status* i podgląd `mosquitto_sub` na serwerze; przy `connection timed out`
   spróbować z Verify Certificate Off, żeby odróżnić problem certyfikatu od problemu TLS.
7. Powtórzyć test na kontrolerze z OS 2.10.0.
8. Dopiero potem: backend (konta, lokale, uprawnienia, dziennik) i aplikacja PWA.

## Uwagi

- Haseł i tokenów nie wklejać do rozmowy ani do repozytorium. We wcześniejszym zrzucie
  z kontrolera znalazły się hasło kamery i kod parowania HomeKit — właściciel powinien je zmienić.
- Gałąź robocza: `claude/smart-building-control4-gateway-3c4n26`. Nie tworzyć pull requesta
  bez prośby właściciela.
- Repozytorium `tv-webhook-bot` dotyczy innego projektu; ten kod żyje w katalogu
  `control4-gateway/` i docelowo może trafić do osobnego repozytorium.
