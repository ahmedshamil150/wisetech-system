# Ultrasound Inventory

Inventory, movement and repair tracking for ultrasound machines, probes, printers and parts.
Flutter (Android + Web) with a Supabase (PostgreSQL) backend.

> This repository holds two versions of the system:
> the current **Flutter + Supabase app** in the repository root, and the original
> **Flask + SQLite prototype** under `app/` (see `README.legacy-flask.md`).

## Features

- **Dashboard** - live counts: in stock, with workshop, with dealer, in repair.
- **Inventory** - machines, probes, printers and parts; searchable, filterable, with full per-item history.
- **Movements** - send items to Workshop / Dealer / Customer. Picking a machine automatically takes its probes and printer along; receiving works the same way.
- **Records** - admin-managed reference data: products, brands, customers, dealers, batches.
- **Repairs** - anyone can log a customer machine on arrival (ours or theirs, plus its probes/printer) and mark it sent back with a date.
- **Roles** - Administrators manage reference data and stock; Viewers read everything and can still create movements and repairs.

## Tech

- Flutter 3.x, Riverpod for state, Supabase Flutter client.
- PostgreSQL schema + row-level security + RPCs in `supabase/migrations/`.
- `scripts/` - Python helpers that run SQL and maintenance tasks (`python scripts/run_sql.py <file.sql>`).

## Setup

```bash
flutter pub get
flutter run            # Android / device
flutter build web      # web bundle in build/web
flutter build apk      # Android APK
```

Backend settings live in `lib/core/config.dart` (Supabase URL + publishable anon key, safe to ship).
`.env` holds the service-role key and database password for the maintenance scripts - it is git-ignored.

## Deploy

- Android: `build/app/outputs/flutter-apk/app-release.apk`.
- Web: `build/web`, deployed to Vercel.
