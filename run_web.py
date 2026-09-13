from app import create_app
from app.config import config

app = create_app()

if __name__ == "__main__":
    # Dev server only. In production, run via gunicorn (see systemd unit).
    app.run(host=config.WEB_HOST, port=config.WEB_PORT)
