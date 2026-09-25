from pathlib import Path

from flask import Flask

from .database import init_app, init_db
from .routes import main
from . import receive  # noqa: F401  (registers /receive on the main blueprint)
from . import ops      # noqa: F401  (registers send/return/sale routes)
from . import partners  # noqa: F401 (registers workshops/dealers management)
from . import movements  # noqa: F401  (registers movement centre + item movements)


def create_app(test_config=None):
    project_root = Path(__file__).resolve().parent.parent
    app = Flask(__name__, instance_relative_config=True)
    app.config.from_mapping(
        SECRET_KEY="local-inventory-development-key",
        DATABASE=Path(app.instance_path) / "inventory.db",
    )

    if test_config is not None:
        app.config.update(test_config)

    Path(app.instance_path).mkdir(parents=True, exist_ok=True)
    init_app(app)
    app.register_blueprint(main)

    with app.app_context():
        init_db()

    return app
