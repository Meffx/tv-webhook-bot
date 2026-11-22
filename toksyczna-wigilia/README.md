# Toksyczna Wigilia

Losowanie prezentowe, w którym każdy losuje na własnym telefonie. Mały serwer Flask + SQLite, bez zewnętrznych zależności poza Flaskiem.

## Jak to działa
1. Organizator wchodzi w **Panel organizatora** (przycisk na dole strony), loguje się tokenem i dodaje osoby (imię, e-mail opcjonalnie), pary oraz budżet.
2. Klika **Otwórz losowanie** i wysyła uczestnikom link do strony.
3. Uczestnik wybiera swoje imię, wpisuje e-mail i klika **Losuj**. Widzi wynik na ekranie i (jeśli skonfigurowano SMTP) dostaje kopię mailem.
4. Losowanie można zrobić tylko raz. Osoba, która już losowała, jest wyszarzona na liście i nie da się jej wybrać ponownie, więc wynik trzeba zapamiętać (albo zachować mail).

Zasady losowania: nikt nie wylosuje siebie ani osoby z własnej pary, a opcjonalnie A→B wyklucza B→A. Serwer wybiera odbiorcę tak, żeby reszta osób zawsze mogła jeszcze dokończyć losowanie. Organizator nie widzi, kto kogo wylosował.

## Uruchomienie
```
pip install -r requirements.txt
ADMIN_TOKEN=twoj-dlugi-token gunicorn -w 1 -b 0.0.0.0:8000 app:app
```
Użyj jednego procesu roboczego (`-w 1`) lub kilku, baza i tak blokuje zapis na czas losowania.

## Zmienne środowiskowe
| Zmienna | Opis |
|---|---|
| `ADMIN_TOKEN` | **Wymagana.** Hasło do panelu organizatora. Bez niego panel jest wyłączony. |
| `DB_PATH` | Ścieżka pliku SQLite (domyślnie `data/wigilia.db`). Umieść ją na dysku, który nie jest czyszczony przy restarcie. |
| `TITLE` | Tytuł (domyślnie „Toksyczna Wigilia”). |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `SMTP_FROM` | Opcjonalnie: wysyłka kopii wyniku mailem (port 465 = SSL, inne = STARTTLS). Bez nich wynik widać tylko na ekranie. |
| `PORT` | Port przy uruchomieniu `python app.py`. |

## Uwagi
- Jeśli nie podasz e-maili w panelu, uczestnik wpisuje dowolny adres, więc ktoś mógłby wybrać cudze imię. Żeby temu zapobiec, wpisz e-maile w panelu: wtedy serwer sprawdza zgodność adresu.
- Stronę warto serwować po HTTPS (token i e-maile idą przez sieć).
