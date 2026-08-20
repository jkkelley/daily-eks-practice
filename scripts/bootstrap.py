#!/usr/bin/env python3
"""Bootstrap Terraform from a single config file.

Reads scripts/config.toml (falls back to scripts/config.example.toml), merges
[common] + [<env>], writes the env's config.auto.tfvars.json (which Terraform
auto-loads), then runs terraform. On `init` it also injects the S3 backend
(bucket/key/region) from [backend] via -backend-config, since backend blocks
cannot use variables. This is the only source of values - there are no defaults
in any variables.tf, and nothing user-specific is hardcoded.

Log lines go to stderr so `... output -raw <name>` stays clean on stdout.

Usage:
  python3 scripts/bootstrap.py <dev|bootstrap-oidc> [--generate-only] [tf args...]
  python3 scripts/bootstrap.py <env> --print <key>     # emit one merged value

Examples:
  python3 scripts/bootstrap.py dev init -input=false
  python3 scripts/bootstrap.py dev plan
  python3 scripts/bootstrap.py dev apply
  python3 scripts/bootstrap.py dev --print aws_profile
"""
import ipaddress
import json
import subprocess
import sys
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11
    try:
        import tomli as tomllib  # type: ignore
    except ModuleNotFoundError:
        sys.exit("bootstrap: needs Python 3.11+ (stdlib tomllib) or `pip install tomli`.")

REPO = Path(__file__).resolve().parent.parent
CONFIG = REPO / "scripts" / "config.toml"
CONFIG_EXAMPLE = REPO / "scripts" / "config.example.toml"

ENV_DIRS = {
    "dev": REPO / "terraform" / "envs" / "dev",
    "bootstrap-oidc": REPO / "terraform" / "bootstrap-oidc",
}
ENV_TABLE = {"dev": "dev", "bootstrap-oidc": "bootstrap_oidc"}
# S3 state key per env (backend blocks can't use variables, so we inject these).
BACKEND_KEYS = {
    "dev": "dev/terraform.tfstate",
    "bootstrap-oidc": "bootstrap/terraform.tfstate",
}


def log(msg: str) -> None:
    print(msg, file=sys.stderr)


def deep_merge(base: dict, over: dict) -> dict:
    out = dict(base)
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def public_ip() -> str | None:
    """This machine's public IPv4 as the internet sees it, or None.

    Uses AWS's checkip because the tfvars this feeds are consumed by an AWS security
    group, so the address that matters is the one AWS observes. Stdlib only - the repo
    deliberately has no Python dependencies.
    """
    import urllib.request

    try:
        with urllib.request.urlopen("https://checkip.amazonaws.com", timeout=10) as r:
            ip = r.read().decode().strip()
    except Exception:
        return None
    try:
        ipaddress.IPv4Address(ip)
    except ValueError:
        return None
    return ip


# Terraform subcommands that read existing state and never consume the tfvars.
READ_ONLY_ACTIONS = {"output", "show", "state", "version", "providers", "graph"}


def needs_auto_cidrs(rest: list[str]) -> bool:
    """Whether this invocation actually consumes drill_allowed_cidrs.

    Resolving the "auto" sentinel costs an HTTPS round trip with a 10s timeout, and
    bootstrap.py is invoked for far more than applies. `Makefile` runs two
    `--print` lookups through `$(shell ...)` on EVERY target, and `scripts/git-seed.py`
    reads terraform outputs. Paying for a lookup there means `make help` does two
    network calls, and offline it stalls for the full timeout or dies complaining
    about CIDRs while it was only ever asked for a profile name.

    A read-only action still rewrites config.auto.tfvars.json, so after one the file
    holds the unresolved sentinel. That is safe because every action that consumes it
    - init, plan, apply, destroy - resolves first, and this repo never runs terraform
    bare. A stray bare plan would fail loudly on an invalid CIDR rather than quietly
    widening the allow list, which is the direction an error here has to fail in.
    """
    if rest and rest[0] == "--print":
        return len(rest) > 1 and rest[1] == "drill_allowed_cidrs"
    if rest and rest[0] in READ_ONLY_ACTIONS:
        return False
    return True


def resolve_auto_cidrs(merged: dict) -> None:
    """Replace the "auto" sentinel in drill_allowed_cidrs with this machine's /32.

    Residential addresses are DHCP-assigned, so a pinned literal goes stale on a lease
    change and locks you out of your own drill with no error message - the browser just
    hangs. Resolving at plan time means the allow list cannot drift from reality.

    Literals are left alone: a static IP or a CI runner has no meaningful "your IP".
    """
    cidrs = merged.get("drill_allowed_cidrs")
    if not isinstance(cidrs, list) or "auto" not in cidrs:
        return
    ip = public_ip()
    if ip is None:
        sys.exit(
            "bootstrap: drill_allowed_cidrs is [\"auto\"] but your public IP could not be "
            "determined (no network?). Set a literal CIDR in scripts/config.toml, or retry."
        )
    merged["drill_allowed_cidrs"] = [f"{ip}/32" if c == "auto" else c for c in cidrs]
    log("bootstrap: drill_allowed_cidrs \"auto\" resolved to your current public /32")


def find_placeholders(d: dict, prefix: str = "") -> list:
    """(dotted_key, value) pairs for string values still holding a <placeholder>."""
    found = []
    for k, v in d.items():
        key = f"{prefix}{k}"
        if isinstance(v, dict):
            found += find_placeholders(v, key + ".")
        elif isinstance(v, str) and "<" in v and ">" in v:
            found.append((key, v))
    return found


def load_config() -> dict:
    cfg_path = CONFIG if CONFIG.exists() else CONFIG_EXAMPLE
    if not cfg_path.exists():
        sys.exit("bootstrap: no scripts/config.toml or scripts/config.example.toml found")
    if cfg_path == CONFIG_EXAMPLE:
        log("bootstrap: using scripts/config.example.toml (copy it to scripts/config.toml to customize)")
    with open(cfg_path, "rb") as f:
        return tomllib.load(f)


def backend_config_flags(env: str, backend: dict) -> list[str]:
    flags = []
    bucket = backend.get("bucket", "")
    if "/" in bucket:
        sys.exit(
            "bootstrap: [backend].bucket must be the bare bucket name (no '/'). "
            "Put a folder path in [backend].key_prefix instead."
        )
    if bucket:
        flags.append(f"-backend-config=bucket={bucket}")
    key = BACKEND_KEYS[env]
    prefix = backend.get("key_prefix", "").strip("/")
    if prefix:
        key = f"{prefix}/{key}"
    flags.append(f"-backend-config=key={key}")
    if backend.get("region"):
        flags.append(f"-backend-config=region={backend['region']}")
    return flags


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0

    env = argv[0]
    rest = argv[1:]
    if env not in ENV_DIRS:
        sys.exit(f"bootstrap: unknown env '{env}' (expected dev | bootstrap-oidc)")

    cfg = load_config()
    backend = cfg.get("backend", {})
    if env == "bootstrap-oidc":  # standalone: only its own table
        merged = cfg.get(ENV_TABLE[env], {})
    else:
        merged = deep_merge(cfg.get("common", {}), cfg.get(ENV_TABLE[env], {}))
    if not merged:
        sys.exit(f"bootstrap: no config found for env '{env}'")

    if needs_auto_cidrs(rest):
        resolve_auto_cidrs(merged)

    # --print <key>: emit one merged value (for Makefile $(shell)); no side effects.
    if rest and rest[0] == "--print":
        if len(rest) < 2:
            sys.exit("bootstrap: --print needs a key")
        val = merged.get(rest[1])
        if val is None:
            sys.exit(f"bootstrap: key '{rest[1]}' not set for env '{env}'")
        sys.stdout.write(val if isinstance(val, str) else json.dumps(val))
        sys.stdout.write("\n")
        return 0

    generate_only = False
    if rest and rest[0] == "--generate-only":
        generate_only = True
        rest = rest[1:]

    out_file = ENV_DIRS[env] / "config.auto.tfvars.json"
    out_file.write_text(json.dumps(merged, indent=2, sort_keys=True) + "\n")
    log(f"bootstrap: wrote {out_file.relative_to(REPO)} ({len(merged)} vars) for env '{env}'")

    if generate_only or not rest:
        if not rest and not generate_only:
            log("bootstrap: tfvars generated; no terraform action requested.")
        return 0

    # Preflight: for a real (AWS-touching) action, stop with actionable guidance
    # if the config still has <placeholder> values, instead of a cryptic TF error.
    real_actions = {"init", "plan", "apply", "destroy", "refresh", "import"}
    if rest[0] in real_actions and "-backend=false" not in rest:
        placeholders = find_placeholders(merged)
        placeholders += [
            (f"[backend].{k}", v)
            for k, v in backend.items()
            if isinstance(v, str) and "<" in v and ">" in v
        ]
        if placeholders:
            log("")
            log(f"bootstrap: cannot '{rest[0]}' - your config still has placeholder values to fill:")
            for key, val in placeholders:
                log(f"    {key} = {val}")
            log("")
            log("  1) cp scripts/config.example.toml scripts/config.toml")
            log("  2) edit scripts/config.toml and replace every <...> with your real value")
            log("     ([backend].bucket = an S3 bucket you created; aws_profile; github owner/repo)")
            log("")
            log("  No AWS needed for static checks: `make -f Makefile.test test` or `... ministack`.")
            return 2

    tf = ["terraform", f"-chdir={ENV_DIRS[env]}"]
    # Inject the S3 backend on `init` (unless the caller disabled the backend).
    # -reconfigure: the ministack tests leave a cached LOCAL backend in
    # .terraform/, and switching back to S3 would otherwise demand a migration.
    if rest[0] == "init" and "-backend=false" not in rest:
        extra = [] if "-reconfigure" in rest else ["-reconfigure"]
        cmd = tf + ["init"] + extra + backend_config_flags(env, backend) + rest[1:]
    else:
        cmd = tf + rest
    log("bootstrap: " + " ".join(cmd))
    return subprocess.call(cmd)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
