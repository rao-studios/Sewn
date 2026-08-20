#!/usr/bin/env python3
"""JSON bridge over the Tinker SDK for the SeerClient app.

Every subcommand prints exactly one JSON object to stdout. Errors print
{"error": "..."} and exit 1. Requires TINKER_API_KEY in the environment.
"""
import argparse
import json
import sys


def _client():
    import tinker
    return tinker.ServiceClient().create_rest_client()


def _dump(obj):
    def default(o):
        if hasattr(o, "model_dump"):
            return o.model_dump()
        if hasattr(o, "__dict__"):
            return o.__dict__
        return str(o)
    json.dump(obj, sys.stdout, default=default)
    sys.stdout.write("\n")


def main():
    parser = argparse.ArgumentParser(prog="tinker_helper")
    sub = parser.add_subparsers(dest="command", required=True)

    runs = sub.add_parser("list-runs")
    runs.add_argument("--limit", type=int, default=50)

    ckpts = sub.add_parser("list-checkpoints")
    ckpts.add_argument("--run", required=True)

    sub.add_parser("list-user-checkpoints")

    url = sub.add_parser("checkpoint-url")
    url.add_argument("--path", required=True)

    delete = sub.add_parser("delete-checkpoint")
    delete.add_argument("--path", required=True)

    publish = sub.add_parser("publish-checkpoint")
    publish.add_argument("--path", required=True)

    args = parser.parse_args()
    try:
        rc = _client()
        if args.command == "list-runs":
            result = rc.list_training_runs(limit=args.limit)
        elif args.command == "list-checkpoints":
            result = rc.list_checkpoints(args.run)
        elif args.command == "list-user-checkpoints":
            result = rc.list_user_checkpoints(limit=100)
        elif args.command == "checkpoint-url":
            result = rc.get_checkpoint_archive_url_from_tinker_path(args.path)
        elif args.command == "delete-checkpoint":
            result = rc.delete_checkpoint_from_tinker_path(args.path)
        elif args.command == "publish-checkpoint":
            result = rc.publish_checkpoint_from_tinker_path(args.path)
        else:
            raise ValueError(f"unknown command {args.command}")
        _dump({"ok": True, "result": result})
    except Exception as exc:  # noqa: BLE001 — bridge reports everything as JSON
        json.dump({"error": str(exc)}, sys.stdout)
        sys.stdout.write("\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
