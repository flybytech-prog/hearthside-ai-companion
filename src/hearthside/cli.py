from __future__ import annotations

import argparse
import json
import re
from collections.abc import Sequence

from . import __version__
from .core import portowner, vault, webdata
from .core.catalog import PROVIDER_IDS
from .core.snapshot import catalog_snapshot, collect_snapshot, detect_snapshot

# Largest applet id or profile generation the plasmoid may pass.
MAX_INT_ARGUMENT = 2**31
_INT_ARGUMENT = re.compile(r"[0-9]{1,10}")
_PORT_ARGUMENT = re.compile(r"[0-9]{1,5}")


def _bounded_int(value: str) -> int:
    """A plain decimal 0..2**31: no sign, spaces, underscores or other digits."""
    if not _INT_ARGUMENT.fullmatch(value) or int(value) > MAX_INT_ARGUMENT:
        raise argparse.ArgumentTypeError("expected an integer from 0 to 2147483648")
    return int(value)


def _port(value: str) -> int:
    """A plain decimal TCP port 1..65535: no sign, spaces, underscores or other digits."""
    if not _PORT_ARGUMENT.fullmatch(value) or not portowner.MIN_PORT <= int(value) <= portowner.MAX_PORT:
        raise argparse.ArgumentTypeError("expected a port from 1 to 65535")
    return int(value)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        prog="hearthside",
        description="Read local AI CLI sessions and print subscription usage as JSON.",
    )
    result.add_argument("--json", action="store_true", help="Print JSON (the default).")
    result.add_argument(
        "--providers",
        metavar="IDS",
        help="Comma-separated tracked provider IDs.",
    )
    result.add_argument(
        "--catalog",
        action="store_true",
        help="Print the provider catalog without reading credentials or using the network.",
    )
    result.add_argument(
        "--detect",
        action="store_true",
        help="Print the catalog and installed provider IDs without reading credentials or using the network.",
    )
    result.add_argument(
        "--web-data",
        choices=("prepare", "remove", "purge"),
        help="Create or delete a Chat tab profile folder inside the unlocked encrypted folder; "
        "purge deletes the encrypted folder (no network, no credentials).",
    )
    result.add_argument(
        "--store",
        choices=webdata.STORES,
        help="Profile store for --web-data prepare/remove (only 'encrypted').",
    )
    result.add_argument("--applet", type=_bounded_int, metavar="N", help="Applet id for --web-data.")
    result.add_argument("--generation", type=_bounded_int, metavar="G", help="Generation for --web-data prepare.")
    result.add_argument("--keep", type=_bounded_int, metavar="G", help="Generation --web-data remove keeps.")
    result.add_argument(
        "--vault",
        choices=vault.OPERATIONS,
        help="Manage the passphrase-encrypted Chat folder (no network, no credentials).",
    )
    result.add_argument(
        "--port-owner",
        type=_port,
        metavar="PORT",
        help="Say whether you, a trusted system account, another user, or nobody listens on "
        "this loopback port (reads /proc/net only; no network, no credentials).",
    )
    result.add_argument("--version", action="version", version=__version__)
    return result


def _check_helper_arguments(args: argparse.Namespace, argument_parser: argparse.ArgumentParser) -> None:
    """--web-data, --vault and --port-owner stand alone; the web options need --web-data."""
    snapshot_options = [
        name for name, used in (
            ("--json", args.json),
            ("--providers", args.providers is not None),
            ("--catalog", args.catalog),
            ("--detect", args.detect),
        ) if used
    ]
    web_options = [
        name for name, used in (
            ("--store", args.store is not None),
            ("--applet", args.applet is not None),
            ("--generation", args.generation is not None),
            ("--keep", args.keep is not None),
        ) if used
    ]
    if args.port_owner is not None:
        others = snapshot_options + web_options + [
            name for name, used in (
                ("--web-data", args.web_data is not None),
                ("--vault", args.vault is not None),
            ) if used
        ]
        if others:
            argument_parser.error(f"{others[0]} cannot be combined with --port-owner")
        return
    if args.web_data is None and args.vault is None:
        if web_options:
            argument_parser.error(f"{web_options[0]} needs --web-data")
        return
    if args.web_data is not None and args.vault is not None:
        argument_parser.error("--web-data and --vault cannot be combined")
    if snapshot_options:
        argument_parser.error(f"{snapshot_options[0]} cannot be combined with --web-data or --vault")
    if args.vault is not None:
        if web_options:
            argument_parser.error(f"{web_options[0]} needs --web-data")
        return
    if args.web_data == "purge":
        if web_options:
            argument_parser.error(f"{web_options[0]} cannot be combined with --web-data purge")
        return
    if args.store is None or args.applet is None:
        argument_parser.error("--web-data needs --store and --applet")
    if args.web_data == "prepare":
        if args.generation is None:
            argument_parser.error("--web-data prepare needs --generation")
        if args.keep is not None:
            argument_parser.error("--keep is only for --web-data remove")
    elif args.generation is not None:
        argument_parser.error("--generation is only for --web-data prepare")


def _provider_ids(value: str | None, argument_parser: argparse.ArgumentParser):
    if value is None:
        return None
    ids = [item.strip() for item in value.split(",") if item.strip()]
    invalid = [item for item in ids if item not in PROVIDER_IDS]
    if invalid:
        argument_parser.error(f"unsupported provider(s): {', '.join(invalid)}")
    return list(dict.fromkeys(ids))


def main(argv: Sequence[str] | None = None) -> int:
    argument_parser = parser()
    args = argument_parser.parse_args(argv)
    _check_helper_arguments(args, argument_parser)
    if args.port_owner is not None:
        payload = _port_owner_reply(args.port_owner)
    elif args.web_data == "purge":
        payload = _helper_reply(vault.purge)
    elif args.web_data is not None:
        payload = _helper_reply(lambda: webdata.run(
            args.web_data, args.store, args.applet, generation=args.generation, keep=args.keep,
        ))
    elif args.vault is not None:
        payload = _helper_reply(lambda: vault.run(args.vault))
    elif args.catalog:
        payload = catalog_snapshot()
    elif args.detect:
        payload = detect_snapshot()
    else:
        payload = collect_snapshot(
            provider_ids=_provider_ids(args.providers, argument_parser),
        )
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    return 0


def _helper_reply(action) -> dict[str, object]:
    """Run a --web-data/--vault action; any surprise becomes a bare error code.

    No traceback, path or message may reach stdout or stderr.
    """
    try:
        return action()
    except Exception:  # noqa: BLE001 - fail closed with a code only
        return {"ok": False, "error": "os-error"}


def _port_owner_reply(port: int) -> dict[str, object]:
    """The owner word only; any surprise fails closed as unreadable."""
    try:
        return portowner.run(port)
    except Exception:  # noqa: BLE001 - fail closed with a code only
        return {"ok": False, "error": "unreadable"}


def print_json() -> int:
    """Console-script compatibility entry point."""
    return main()
