# Punkt wejścia dla hostingów z Phusion Passenger (np. cPanel "Setup Python App").
# Inne hostingi uruchamiają aplikację komendą: gunicorn -w 1 -b 0.0.0.0:8000 app:app
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from app import app as application  # noqa: E402
