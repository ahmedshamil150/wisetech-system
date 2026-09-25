# Ultrasound Inventory

A local, offline inventory and equipment-management system for an ultrasound machine supplier. The application uses Flask, SQLite, server-rendered HTML, CSS, and vanilla JavaScript.

## Stage 1 foundation

The current stage provides:

- Flask application factory and local SQLite connection handling
- Relational SQLite schema for batches, company equipment, customers, workshops, dealers, movements, sales, and repair jobs
- Empty dashboard with navigation shell and database-backed summary counts
- No demo inventory or fake business records
- Windows startup script

Workflow pages and inventory actions will be added in later stages.

## Requirements

- Windows with Python 3.10 or newer
- No XAMPP, MySQL, cloud database, or internet connection required after dependencies are installed

## Install and start

Open Command Prompt or PowerShell in this project folder:

```powershell
py -3 -m venv .venv
.venv\Scripts\python -m pip install -r requirements.txt
.venv\Scripts\python run.py
```

Then open http://127.0.0.1:5000/ in a browser. The database is initialized automatically on first start.

Alternatively, double-click `start.bat` after creating the virtual environment and installing dependencies.

## Database

The SQLite database is stored at `instance/inventory.db`. The schema is defined in `app/schema.sql`. To explicitly initialize or reinitialize the schema without deleting existing data:

```powershell
.venv\Scripts\python -m flask --app run.py init-db
```

The schema uses `CREATE TABLE IF NOT EXISTS`, so initialization does not remove existing records.

## Backup and restore

The database is a single SQLite file and can be copied while the application is stopped:

```powershell
Copy-Item instance\inventory.db backups\inventory-YYYY-MM-DD.db
```

To restore, stop the application, keep a copy of the current database, and replace `instance\inventory.db` with the backup file. Backup and restore buttons will be added in a later stage with confirmation safeguards.

## Project structure

```text
app/
  __init__.py          Application factory
  database.py          SQLite connection and initialization helpers
  schema.sql           Relational database schema
  routes.py            Flask routes
  templates/           Server-rendered pages
  static/              CSS and JavaScript
instance/
  inventory.db         Local SQLite database, created on first start
backups/               Recommended location for manual database copies
run.py                 Development entry point
start.bat              Windows startup helper
requirements.txt       Python dependencies
```
