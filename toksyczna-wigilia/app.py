"""Toksyczna Wigilia: losowanie prezentowe, w którym każdy losuje na własnym telefonie.

Dane trzyma SQLite, wyniki losowania zna tylko serwer. Organizator zarządza listą
osób w panelu chronionym tokenem ADMIN_TOKEN. Organizator nie widzi, kto kogo wylosował.
"""
import hmac
import html
import os
import random
import re
import smtplib
import sqlite3
import ssl
import sys
from email.message import EmailMessage
from itertools import combinations

from flask import Flask, jsonify, request, send_from_directory

BASE = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.getenv("DB_PATH", os.path.join(BASE, "data", "wigilia.db"))
ADMIN_TOKEN = os.getenv("ADMIN_TOKEN", "")
TITLE = os.getenv("TITLE", "Toksyczna Wigilia")

SMTP_HOST = os.getenv("SMTP_HOST", "")
SMTP_PORT = int(os.getenv("SMTP_PORT", "587"))
SMTP_USER = os.getenv("SMTP_USER", "")
SMTP_PASS = os.getenv("SMTP_PASS", "")
SMTP_FROM = os.getenv("SMTP_FROM", SMTP_USER)

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
rng = random.SystemRandom()
app = Flask(__name__, static_folder=None)


# ---------- baza ----------
def db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    con = sqlite3.connect(DB_PATH, timeout=15, isolation_level=None)
    con.row_factory = sqlite3.Row
    con.executescript(
        """
        CREATE TABLE IF NOT EXISTS people(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE COLLATE NOCASE,
            email TEXT,
            drawn_to INTEGER REFERENCES people(id)
        );
        CREATE TABLE IF NOT EXISTS pairs(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            a INTEGER NOT NULL, b INTEGER NOT NULL, UNIQUE(a, b)
        );
        CREATE TABLE IF NOT EXISTS config(key TEXT PRIMARY KEY, value TEXT);
        """
    )
    return con


def cfg(con):
    c = {r["key"]: r["value"] for r in con.execute("SELECT key, value FROM config")}
    return {
        "budget": int(c.get("budget", "70")),
        "no_mutual": c.get("no_mutual", "1") == "1",
        "opened": c.get("opened", "0") == "1",
    }


def set_cfg(con, key, value):
    con.execute("INSERT INTO config(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, str(value)))


# ---------- losowanie ----------
def banned_set(con):
    return {frozenset((r["a"], r["b"])) for r in con.execute("SELECT a, b FROM pairs")}


def can_give(g, r, assigned, banned, no_mutual):
    if g == r or frozenset((g, r)) in banned:
        return False
    if no_mutual and assigned.get(r) == g:
        return False
    return True


def complete(ids, assigned, banned, no_mutual):
    """Czy da się dokończyć losowanie od obecnego stanu (przeszukiwanie z nawrotami)."""
    left = [i for i in ids if i not in assigned]
    if not left:
        return True
    taken = set(assigned.values())
    # najpierw osoby z najmniejszą liczbą możliwości
    def opts(g):
        return [r for r in ids if r not in taken and can_give(g, r, assigned, banned, no_mutual)]
    g = min(left, key=lambda x: len(opts(x)))
    for r in opts(g):
        assigned[g] = r
        if complete(ids, assigned, banned, no_mutual):
            del assigned[g]
            return True
        del assigned[g]
    return False


def pick_for(con, giver):
    """Wybiera losowo odbiorcę dla `giver`, tak by całe losowanie dało się dokończyć."""
    people = [r["id"] for r in con.execute("SELECT id FROM people")]
    assigned = {r["id"]: r["drawn_to"] for r in con.execute("SELECT id, drawn_to FROM people WHERE drawn_to IS NOT NULL")}
    c = cfg(con)
    banned = banned_set(con)
    taken = set(assigned.values())
    cands = [r for r in people if r not in taken and can_give(giver, r, assigned, banned, c["no_mutual"])]
    rng.shuffle(cands)
    for r in cands:
        assigned[giver] = r
        ok = complete(people, assigned, banned, c["no_mutual"])
        del assigned[giver]
        if ok:
            return r
    return None


def solvable(con):
    people = [r["id"] for r in con.execute("SELECT id FROM people")]
    return len(people) >= 3 and complete(people, {}, banned_set(con), cfg(con)["no_mutual"])


# ---------- mail ----------
def mail_enabled():
    return bool(SMTP_HOST and SMTP_FROM)


def build_email(giver, receiver, budget):
    """Zwraca (tekst, html). HTML jest prosty (tabele, style inline), żeby działał w programach pocztowych."""
    text = f"Cześć {giver}!\n\nW losowaniu \"{TITLE}\" kupujesz prezent dla: {receiver}.\n"
    if budget:
        text += f"Budżet: {budget} zł.\n"
    text += "\nTo wiadomość automatyczna. Nie pokazuj jej nikomu, losowanie jest tajne.\n"

    e = html.escape
    display = "'Arial Narrow','Helvetica Neue',Impact,Arial,sans-serif"
    mono = "'Courier New',Courier,monospace"
    ink, red, tape = "#17130f", "#d4251c", "#f5c400"
    stripes = "".join(
        f'<td width="5%" height="14" bgcolor="{tape if i % 2 == 0 else ink}" style="font-size:0;line-height:0">&nbsp;</td>'
        for i in range(20)
    )
    budget_row = (
        f'<tr><td style="padding:0 28px 18px;font-family:{mono};font-size:13px;letter-spacing:1px;text-transform:uppercase;color:#5d564b">'
        f"Budżet na prezent: {int(budget)} zł</td></tr>"
        if budget else ""
    )
    page = f"""<!doctype html>
<html lang="pl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{e(TITLE)}</title></head>
<body style="margin:0;padding:0;background:#c59a6b">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" bgcolor="#c59a6b"><tr><td align="center" style="padding:0 12px 32px">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" bgcolor="{red}" style="max-width:560px"><tr>
    <td align="center" style="padding:16px 12px 40px;font-family:{mono};font-size:11px;letter-spacing:3px;text-transform:uppercase;color:#ffffff">Nie otwierać przed 24.12</td></tr></table>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" bgcolor="#fbfaf6" style="max-width:560px;margin-top:-24px;border:3px solid {ink}">
    <tr><td style="border-bottom:3px solid {ink}"><table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr>{stripes}</tr></table></td></tr>
    <tr><td style="padding:22px 28px 18px;border-bottom:3px solid {ink}">
      <div style="font-family:{display};font-weight:bold;font-size:44px;line-height:44px;text-transform:uppercase;color:{ink}">{e(TITLE)}</div>
      <div style="margin-top:8px;font-family:{mono};font-size:11px;letter-spacing:1px;text-transform:uppercase;color:#5d564b">Karta losowania prezentów &middot; edycja 2026 &middot; poufne</div>
    </td></tr>
    <tr><td style="padding:24px 28px 4px;font-family:{mono};font-size:12px;letter-spacing:2px;text-transform:uppercase;color:#5d564b">{e(giver)}</td></tr>
    <tr><td style="padding:0 28px;font-family:{display};font-weight:bold;font-size:24px;letter-spacing:1px;text-transform:uppercase;color:{ink}">kupujesz prezent dla</td></tr>
    <tr><td style="padding:8px 28px 14px;font-family:{display};font-weight:bold;font-size:64px;line-height:64px;text-transform:uppercase;color:{red};word-break:break-word">{e(receiver)}</td></tr>
    {budget_row}
    <tr><td style="padding:0 28px 26px"><span style="display:inline-block;border:3px solid {red};padding:2px 10px;font-family:{display};font-weight:bold;font-size:18px;letter-spacing:3px;text-transform:uppercase;color:{red}">Poufne</span></td></tr>
    <tr><td style="padding:16px 28px;border-top:2px solid {ink};font-family:Arial,sans-serif;font-size:13px;line-height:19px;color:#5d564b">
      To wiadomość automatyczna. Nie pokazuj jej nikomu, losowanie jest tajne. Losowania nie można powtórzyć, więc zachowaj ten mail.</td></tr>
  </table>
</td></tr></table>
</body></html>"""
    return text, page


def send_mail(to, giver, receiver, budget):
    if not mail_enabled():
        return False
    msg = EmailMessage()
    msg["Subject"] = f"{TITLE}: Twój wynik losowania"
    msg["From"] = SMTP_FROM
    msg["To"] = to
    text, page = build_email(giver, receiver, budget)
    msg.set_content(text)
    msg.add_alternative(page, subtype="html")
    try:
        if SMTP_PORT == 465:
            with smtplib.SMTP_SSL(SMTP_HOST, SMTP_PORT, context=ssl.create_default_context(), timeout=15) as s:
                if SMTP_USER:
                    s.login(SMTP_USER, SMTP_PASS)
                s.send_message(msg)
        else:
            with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=15) as s:
                s.starttls(context=ssl.create_default_context())
                if SMTP_USER:
                    s.login(SMTP_USER, SMTP_PASS)
                s.send_message(msg)
        return True
    except Exception as e:  # nie przerywamy losowania, gdy poczta nie działa
        print("Błąd wysyłki maila:", e, file=sys.stderr)
        return False


# ---------- API uczestnika ----------
@app.get("/")
def index():
    return send_from_directory(os.path.join(BASE, "static"), "index.html")


@app.get("/api/state")
def state():
    con = db()
    c = cfg(con)
    people = [{"id": r["id"], "name": r["name"], "drawn": r["drawn_to"] is not None} for r in con.execute("SELECT id, name, drawn_to FROM people ORDER BY name")]
    return jsonify(title=TITLE, budget=c["budget"], opened=c["opened"], people=people, mail=mail_enabled())


@app.post("/api/draw")
def draw():
    data = request.get_json(silent=True) or {}
    email = str(data.get("email", "")).strip().lower()
    try:
        pid = int(data.get("person_id"))
    except (TypeError, ValueError):
        return jsonify(error="Wybierz swoje imię."), 400
    if not EMAIL_RE.match(email):
        return jsonify(error="Wpisz poprawny adres e-mail."), 400

    con = db()
    con.execute("BEGIN IMMEDIATE")  # blokada: dwa losowania naraz nie wejdą sobie w drogę
    try:
        c = cfg(con)
        me = con.execute("SELECT * FROM people WHERE id=?", (pid,)).fetchone()
        if not c["opened"]:
            con.execute("ROLLBACK"); return jsonify(error="Losowanie jeszcze się nie zaczęło."), 403
        if not me:
            con.execute("ROLLBACK"); return jsonify(error="Nie ma takiej osoby."), 404
        stored = (me["email"] or "").lower()
        if stored and stored != email:
            con.execute("ROLLBACK"); return jsonify(error="Ten e-mail nie pasuje do wybranej osoby."), 403

        if me["drawn_to"] is not None:
            con.execute("ROLLBACK"); return jsonify(error="Ta osoba już losowała. Losowania nie można powtórzyć."), 409

        target = pick_for(con, pid)
        if target is None:
            con.execute("ROLLBACK"); return jsonify(error="Nie da się wylosować przy obecnych ustawieniach. Napisz do organizatora."), 409
        con.execute("UPDATE people SET drawn_to=?, email=COALESCE(email, ?) WHERE id=?", (target, email, pid))
        rcv = con.execute("SELECT name FROM people WHERE id=?", (target,)).fetchone()
        con.execute("COMMIT")
    except Exception:
        try:
            con.execute("ROLLBACK")
        except sqlite3.OperationalError:
            pass
        raise
    emailed = send_mail(email, me["name"], rcv["name"], c["budget"])
    return jsonify(to=rcv["name"], already=False, budget=c["budget"], emailed=emailed)


# ---------- API organizatora ----------
def admin_ok():
    given = request.headers.get("X-Admin-Token", "")
    return bool(ADMIN_TOKEN) and hmac.compare_digest(given.encode(), ADMIN_TOKEN.encode())


@app.before_request
def guard():
    if request.path.startswith("/api/admin") and not admin_ok():
        return jsonify(error="Zły token organizatora." if ADMIN_TOKEN else "Ustaw zmienną ADMIN_TOKEN na serwerze."), 401


def started(con):
    return con.execute("SELECT 1 FROM people WHERE drawn_to IS NOT NULL").fetchone() is not None


def admin_view(con):
    c = cfg(con)
    people = [dict(id=r["id"], name=r["name"], email=r["email"] or "", drawn=r["drawn_to"] is not None) for r in con.execute("SELECT * FROM people ORDER BY name")]
    names = {p["id"]: p["name"] for p in people}
    pairs = [dict(id=r["id"], a=names.get(r["a"], "?"), b=names.get(r["b"], "?")) for r in con.execute("SELECT * FROM pairs")]
    return dict(config=c, people=people, pairs=pairs, started=started(con), mail=mail_enabled(), solvable=solvable(con))


@app.get("/api/admin/state")
def admin_state():
    return jsonify(admin_view(db()))


def locked(con):
    if started(con):
        return jsonify(error="Ktoś już losował. Zmiany są zablokowane. Możesz zresetować losowanie."), 409
    return None


@app.post("/api/admin/people")
def admin_add_person():
    con = db()
    if (r := locked(con)):
        return r
    d = request.get_json(silent=True) or {}
    name = str(d.get("name", "")).strip()[:40]
    email = str(d.get("email", "")).strip().lower()
    if not name:
        return jsonify(error="Wpisz imię."), 400
    if email and not EMAIL_RE.match(email):
        return jsonify(error="Zły adres e-mail."), 400
    try:
        con.execute("INSERT INTO people(name, email) VALUES(?, ?)", (name, email or None))
    except sqlite3.IntegrityError:
        return jsonify(error="Takie imię już jest."), 409
    set_cfg(con, "opened", 0)
    return jsonify(admin_view(con))


@app.delete("/api/admin/people/<int:pid>")
def admin_del_person(pid):
    con = db()
    if (r := locked(con)):
        return r
    con.execute("DELETE FROM pairs WHERE a=? OR b=?", (pid, pid))
    con.execute("DELETE FROM people WHERE id=?", (pid,))
    set_cfg(con, "opened", 0)
    return jsonify(admin_view(con))


@app.post("/api/admin/pairs")
def admin_add_pair():
    con = db()
    if (r := locked(con)):
        return r
    d = request.get_json(silent=True) or {}
    try:
        a, b = sorted((int(d.get("a")), int(d.get("b"))))
    except (TypeError, ValueError):
        return jsonify(error="Wybierz dwie osoby."), 400
    if a == b:
        return jsonify(error="Wybierz dwie różne osoby."), 400
    con.execute("INSERT OR IGNORE INTO pairs(a, b) VALUES(?, ?)", (a, b))
    set_cfg(con, "opened", 0)
    return jsonify(admin_view(con))


@app.delete("/api/admin/pairs/<int:pid>")
def admin_del_pair(pid):
    con = db()
    if (r := locked(con)):
        return r
    con.execute("DELETE FROM pairs WHERE id=?", (pid,))
    set_cfg(con, "opened", 0)
    return jsonify(admin_view(con))


@app.post("/api/admin/config")
def admin_config():
    con = db()
    d = request.get_json(silent=True) or {}
    if "budget" in d:
        try:
            set_cfg(con, "budget", max(0, int(d["budget"])))
        except (TypeError, ValueError):
            return jsonify(error="Budżet musi być liczbą."), 400
    if "no_mutual" in d:
        if (r := locked(con)):
            return r
        set_cfg(con, "no_mutual", 1 if d["no_mutual"] else 0)
        set_cfg(con, "opened", 0)
    if "opened" in d:
        if d["opened"]:
            if not solvable(con):
                return jsonify(error="Przy tych osobach i parach nie da się wylosować (potrzeba min. 3 osób)."), 409
            set_cfg(con, "opened", 1)
        elif not started(con):
            set_cfg(con, "opened", 0)
        else:
            return jsonify(error="Ktoś już losował, nie można zamknąć losowania."), 409
    return jsonify(admin_view(con))


@app.post("/api/admin/reset")
def admin_reset():
    d = request.get_json(silent=True) or {}
    if d.get("confirm") != "RESET":
        return jsonify(error='Wpisz "RESET", żeby potwierdzić.'), 400
    con = db()
    con.execute("UPDATE people SET drawn_to=NULL")
    set_cfg(con, "opened", 0)
    return jsonify(admin_view(con))


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8000")))
