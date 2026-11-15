# Serwer — broker MQTT dla kontrolerów

Skrypty stawiają Mosquitto z TLS (certyfikat Let's Encrypt) na świeżym Ubuntu.
Reguły dostępu sprawdzone lokalnie na Mosquitto 2.0; sam `setup.sh` (certbot,
instalacja pakietów) **nie był jeszcze uruchamiany na prawdziwym serwerze**.

## Zanim zaczniesz

- Domena (np. `mqtt.twojadomena.pl`) z rekordem A wskazującym adres IPv4 serwera.
- W zaporze otwarte porty TCP: 22 (SSH), 80 (wystawienie i odnawianie certyfikatu),
  8883 (kontrolery).

## Uruchomienie

```sh
# na serwerze, jako root, w katalogu z tymi plikami
./setup.sh mqtt.twojadomena.pl twoj@email.pl
./add-unit.sh 101        # konto dla lokalu 101; wypisuje login i hasło
```

Wartości z `add-unit.sh` wpisz we właściwościach sterownika w Composerze:
*Broker Address* = domena, *Port* = 8883, *Encryption* = TLS, *Unit ID* i *Username*
= identyfikator lokalu, *Password* = wypisane hasło.

## Jak to jest zabezpieczone

- Port 8883 przyjmuje tylko połączenia TLS z loginem i hasłem.
- **Login kontrolera musi być równy jego Unit ID.** Kontroler ma dostęp wyłącznie do
  tematów `c4/<Unit ID>/…`, więc przejęcie jednego lokalu nie daje dostępu do innych.
- Konto `backend` widzi wszystkie lokale i łączy się tylko lokalnie (port 1883 na
  127.0.0.1). Jego hasło jest w `/root/c4-backend-password`.
- Certyfikat ma klucz RSA dla zgodności ze starszymi kontrolerami i odnawia się sam.

## Podgląd ruchu na serwerze

```sh
mosquitto_sub -h 127.0.0.1 -u backend -P "$(cat /root/c4-backend-password)" -v -t 'c4/#'
```
