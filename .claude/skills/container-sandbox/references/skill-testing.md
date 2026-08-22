# Testing skills and their bundled scripts

This is the reference for testing the executable parts of a skill or agent in this repo.
It exists because the main `SKILL.md` covers npm, Terraform, Kind, and full-stack compose, but not the plain-script case: a skill that ships a few Python or Bash files and claims they do something.

**Every command that verifies a skill runs inside Podman. No exceptions, including a one-line `python3 --version`.**

Running a skill's script on the host is how you end up shipping a script that only works on your machine, silently depends on a package you happen to have installed, or writes files where you did not expect.
The container is not ceremony. It is the only way the claim "this works" means anything to the next person who clones the repo.

---

## The invocation pattern

Three properties make a skill test trustworthy.
Each maps to one flag.

| Property                                  | Flag                               | What it proves                                    |
| ----------------------------------------- | ---------------------------------- | ------------------------------------------------- |
| The script does not reach the network     | `--network=none`                   | A "stdlib only, no pip installs" claim is real    |
| The script does not mutate its own source | `-v .:/skill:ro,Z`                 | Reruns are clean; the skill is not self-modifying |
| Outputs land where documented             | separate writable `-v ...:/work:Z` | No stray files in the skill directory             |

Plus `--userns=keep-id` so anything written to the mounted scratch directory is owned by you, not root.

```bash
podman run --rm --userns=keep-id --network=none \
  -v "$PWD:/skill:ro,Z" \
  -v "$SCRATCH:/work:Z" \
  -w /work \
  docker.io/library/python:3.12-slim \
  sh -c '<test commands>'
```

Pick the smallest image that matches the skill's declared floor.
A skill that says "Python 3.9+" is tested on `python:3.12-slim`, not on whatever the host has.
Reuse an image already present in `podman images` before pulling a new one.

---

## What "tested" means for a skill

A skill's scripts are tested when all four of these have run in the container and passed.
Three of the four are about failure, because a validator that never rejects anything is not a validator.

1. **Happy path exits 0.** Feed it the example input from the skill's own documentation. If the docs contain an example that the script rejects, the docs are wrong and that is a finding.
2. **Bad input exits non-zero.** Hand it something structurally invalid and assert the exit code is not 0. Assert on the exit code, not on whether error text appeared.
3. **Determinism, where the skill claims it.** Run the same input twice into two output files and `cmp` them. If a skill's whole value proposition is "same input, same output", an untested claim is a marketing line.
4. **Every entry point at least loads.** `--help` on each script catches import errors and syntax errors in files the happy path never touched.

---

## Good and bad examples

### Exit codes

The most common way a skill test lies is by not checking the exit code at all.

**Bad.** The pipe swallows the exit code, so this passes whether the validator returned 0 or 1:

```bash
python3 validate_brief.py bad.json | tail -3
```

**Bad.** `$PIPESTATUS` is a bashism. The `sh` in `python:3.12-slim` is dash, and this prints `Bad substitution` and aborts the run:

```bash
python3 validate_brief.py bad.json | tail -3; echo "exit=${PIPESTATUS[0]}"
```

**Good.** Redirect the noise, capture the code, state the expectation inline so a wrong result is obvious in the log:

```bash
python3 validate_brief.py bad.json >/dev/null 2>&1
echo "negative-test exit=$?  (want 1)"
```

If you need bash features, ask for bash explicitly: `podman run ... bash -c '...'` on an image that has it.
Do not assume `sh` is bash.

### Negative tests

**Bad.** Asserts that the script failed, but not that it failed for the right reason. A typo in the filename produces the same "pass":

```bash
python3 validate_brief.py bad.json && echo FAIL || echo "rejected, good"
```

**Good.** Assert the exit code and that the specific rule fired:

```bash
python3 validate_brief.py bad.json >out.txt 2>&1
echo "exit=$?  (want 1)"
grep -q "scope 'backend' produces a diagram" out.txt && echo "correct rule fired"
```

### Determinism

**Bad.** Eyeballing two runs proves nothing about the bytes:

```bash
python3 plan.py brief.json --out p1.json
python3 plan.py brief.json --out p2.json
echo "looks the same"
```

**Good.** `cmp` fails loudly and returns non-zero:

```bash
python3 plan.py brief.json --out p1.json >/dev/null
python3 plan.py brief.json --out p2.json >/dev/null
cmp p1.json p2.json && echo "byte-identical OK"
```

### Test fixtures

**Bad.** A hand-written fixture that drifts from the documented example. It tests a shape no user will ever supply:

```bash
echo '{"project":"x","scope":"frontend"}' > brief.json
```

**Good.** Extract the fixture from the skill's own documentation, so the test fails when the docs go stale:

````bash
python3 - <<'PY'
import json, re
src = open("/skill/references/intake-questions.md").read()
block = re.search(r"```json\n(.*?)```", src, re.S).group(1)
json.dump(json.loads(block), open("brief.json", "w"), indent=2)
PY
````

### Where output goes

**Bad.** Writes into the skill directory, leaving untracked junk that can get committed:

```bash
podman run --rm -v "$PWD:/skill:Z" -w /skill <image> sh -c 'python3 scripts/plan.py brief.json --out build-plan.json'
```

**Good.** Skill mounted read-only, outputs forced into a scratch mount. A script that tries to write next to itself fails here, which is the point:

```bash
podman run --rm --userns=keep-id -v "$PWD:/skill:ro,Z" -v "$SCRATCH:/work:Z" -w /work <image> \
  sh -c 'python3 /skill/scripts/plan.py brief.json --out build-plan.json'
```

---

## Bash scripts

The examples above are Python.
A skill whose scripts are shell has a different set of ways to fail, and they are worth naming because most of them pass silently on the host.

### Ask for bash explicitly

`python:3.12-slim` and `debian:stable-slim` both have `/bin/sh` as **dash**.
Arrays, `[[ ]]`, `mapfile`, `PIPESTATUS` and `${var,,}` all fail there.

```bash
podman run --rm ... docker.io/library/debian:stable-slim bash -c '<checks>'
```

Running the suite under `sh` produces failures that have nothing to do with the code under test, which is worse than no suite because it trains people to ignore it.

### `set -e` kills scripts in ways the host hides

The most common shell bug in a skill is not logic - it is a command that returns non-zero as its *value* while `set -e` is on.

**`((count++))` returns exit 1 when `count` is 0**, because post-increment evaluates to the old value.
So does `((n > max)) && max=$n` when the test is false, and `[[ -n $x ]] && return 0` when `x` is empty.

```bash
# Bad - exits the script the first time count is 0
((count++))

# Good
count=$((count + 1))

# Bad - exits the script whenever the test is false
[[ -n $PS_SCRATCH ]] && return 0

# Good
if [[ -n $PS_SCRATCH ]]; then return 0; fi
```

A case that walks a loop containing one of these dies mid-iteration and still reports exit 0 to a careless check, so **assert on the observable outcome**, not just the exit code:

```bash
bash script.sh --project "$p" >/dev/null 2>&1
echo "exit=$?  (want 0)"
grep -c '^id: ' "$p/FILE.md"   # did it actually write anything?
```

### Quote substitution patterns and replacements

Two bash behaviours corrupt data silently, and neither is visible by reading the code:

```bash
# bash 5.2: a bare & in the REPLACEMENT expands to whatever the pattern matched
s=${s//-->/--&gt;}      # produces ---->gt;
s=${s//-->/"$ESCAPE"}  # correct - quoted replacement is literal

# an unquoted [ ] in the PATTERN is a glob class matching one space
line=${line/- [ ]/- [x]}       # never matches "- [ ]"
line=${line/"- [ ]"/"- [x]"}   # correct
```

Pin both with a regression test.
Nothing about either is guessable from the source six months later.

### Test the concurrency claim if the script takes a lock

A script that allocates IDs or appends to a shared file must be run in parallel, not just twice in a row:

```bash
for i in $(seq 1 8); do bash script.sh --project "$p" ... >/dev/null 2>&1 & done
wait
total=$(grep -cE '^id: ' "$p/FILE.md")
unique=$(grep -oE '^id: [A-Z]+-[0-9]{4}' "$p/FILE.md" | sort -u | wc -l)
echo "total=$total unique=$unique  (want both 8)"
```

Assert on both counts.
Distinctness alone passes when a write is lost; the total alone passes when two writers reuse an ID.

### `--help` on every entry point, including subcommand dispatchers

A script shaped `tool.sh <subcommand> [flags]` will consume `--help` as the subcommand unless it is handled before dispatch:

```bash
(($#)) || { usage; exit 2; }
case ${1-} in --help | -h) usage; exit 0 ;; esac   # before the dispatch
command="$1"; shift
```

This is a real bug found by exactly this check, in a script whose happy path was fully green.

### Injected time, for determinism

A script that stamps timestamps cannot be `cmp`-compared across runs unless the clock is injectable:

```bash
ps_now() {
  if [[ -n ${SCAFFOLD_NOW-} ]]; then printf '%s' "$SCAFFOLD_NOW"; else date -Iseconds; fi
}
```

Then two runs into two files can be compared byte for byte.
Without it, "deterministic" is an untested claim.

### Prove the read-only mount

`-v "$PWD:/skill:ro,Z"` stops a script writing beside itself, but the guarantee is only demonstrated by comparing the directory before and after:

```bash
before=$(find "$SKILL_DIR" -type f | sort)
podman run ... # the suite
after=$(find "$SKILL_DIR" -type f | sort)
[[ $before == "$after" ]] || { echo "FAIL: skill directory changed"; exit 1; }
```

### A worked example

`claude/skills/project-scaffold/testing/` is a full suite built to this pattern: `run-tests.sh` as the only entry point, `assert.sh` for the vocabulary, one file per case, and `SOP.md` explaining what each case asserts and why its failure would matter.

---

## Skills with no executable code

A skill that is only Markdown still gets a check, and it still runs in the container.
Verify that every bundled resource the `SKILL.md` references actually exists, since a reference to a deleted file is the most common rot in a docs-only skill:

```bash
podman run --rm --network=none -v "$PWD:/skill:ro,Z" -w /skill \
  docker.io/library/python:3.12-slim \
  python3 -c '
import pathlib, re, sys
root = pathlib.Path("/skill")
text = (root / "SKILL.md").read_text()
refs = set(re.findall(r"(?:references|scripts)/[\w.-]+", text))
missing = sorted(r for r in refs if not (root / r).exists())
print(f"checked {len(refs)} bundled refs; missing:", missing or "none")
sys.exit(1 if missing else 0)
'
```

Match only the bundled `references/` and `scripts/` prefixes.
A broader regex over every path-shaped string also matches files the skill instructs the _user_ to create in _their_ project, such as `test/init.py`, and reports them as missing on every run.
A check that cries wolf gets ignored, which is worse than no check.

---

## Reporting

Report what actually ran, in the container, with real exit codes.
Per root `CLAUDE.md` Rule 12, "tested" is wrong if any check was skipped.
If a check could not run - no image, no Podman, a dependency the sandbox cannot provide - say which check was skipped and why, rather than quietly reporting the subset that passed.

---

## When the skill's scripts need system tools

The pattern above assumes a stock slim image already carries everything the skill needs.
That holds for a stdlib-only Python script.
It does not hold for a Bash skill that shells out to `jq`, `git`, `rsync`, or anything else absent from `python:3.12-slim` and `debian:stable-slim` alike.

Do **not** solve this by `apt-get install` inside the test command.
That needs the network, which means dropping `--network=none`, which throws away the guarantee that the skill reaches nothing at runtime.
The install would also re-run on every single case.

Build a purpose-built image instead.
The build is the only step allowed to fetch; the cases still run offline.

```dockerfile
# testing/Containerfile
#
# Pinned by digest per root CLAUDE.md Rule 15. Repin deliberately:
#   podman image inspect docker.io/library/debian:stable-slim \
#     --format '{{index .RepoDigests 0}}'
FROM docker.io/library/debian@sha256:<digest>   # debian:stable-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends bash jq git ca-certificates \
  && rm -rf /var/lib/apt/lists/*
```

The runner builds it only when it is missing, then runs the cases offline as before:

```bash
if ! podman image exists "$IMAGE"; then
  podman build -t "$IMAGE" -f "$SKILL_DIR/testing/Containerfile" "$SKILL_DIR/testing"
fi
podman run --rm --userns=keep-id --network=none ... "$IMAGE" bash -c '...'
```

If the skill's scripts make commits, give the image a fixed git identity too, or every case inherits whoever is running it and the suite stops being reproducible.

## Stubbing an external CLI

When a script's behaviour depends on what an external tool *reports* - `gh` saying whether a PR merged, `kubectl` saying whether a pod is ready - the tool is not a dependency to install.
It is the input under test.

Install a stub on `PATH` and control its answer per case:

```bash
gh_stub() {
  local dir="$1" state="$2" sha="${3-abc123}"   # ${3-} not ${3:-}: "" must stay ""
  mkdir -p "$dir"
  cat >"$dir/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"--json state"*)       printf '$state\n' ;;
  *"--json mergeCommit"*) printf '$sha\n' ;;
esac
STUB
  chmod +x "$dir/gh"
}
export PATH="$(gh_stub "$WORK/stub" OPEN):$PATH"
```

`${3-default}` rather than `${3:-default}` matters more than it looks.
`:-` substitutes the default when the argument is the empty string, so a case written to test "merged, but with no merge commit" silently tests a valid SHA instead and passes for the wrong reason.
That exact bug shipped in the first draft of the work-order suite and was only caught because the assertion expected a refusal and got a success.

## Testing a destructive path

A script that runs `git branch -D`, `git push --delete`, or `rm -rf` needs its destructive path exercised, not reasoned about.
"We are senior enough not to need that test" is precisely backwards: the blast radius is what justifies the test.

Give it a real repository with a real bare remote, inside the container:

```bash
git init --bare -q "$d.git"
git init -q "$d" && git -C "$d" remote add origin "$d.git"
git -C "$d" commit -qm seed --allow-empty && git -C "$d" push -q -u origin main
```

Two cases carry the weight, and the refusal is the more important of the two:

1. **The tool reports "not safe" → the script refuses and nothing is destroyed.** Assert the branch still exists and no file moved. This is the case that protects real work.
2. **The tool reports "safe" → the script completes.** Make the fixture *genuinely* consistent - if the stub claims a PR merged, actually merge the branch into the bare origin first. A fixture that asserts on a world which cannot exist will pass while the real path is broken.

Point 2 is not hypothetical either.
The work-order suite originally stubbed `MERGED` without performing the merge, which hid a real bug: checking out `main` replaces the ticket file on disk, so the status verified before the checkout said nothing about the file being held afterwards.
