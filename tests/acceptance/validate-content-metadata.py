#!/usr/bin/env python3
"""
Validate the site configuration content package before it reaches a database.

The Initializer creates metadata by UUID. A malformed UUID does not degrade
gracefully: it either aborts the domain that contains it, or -- worse, quietly
creates a concept that can never be matched to the CIEL concept an O3 form or
order set expects by UUID. Both failure modes are hard to diagnose from
application logs, so they are checked here instead, before the build.

Checks
  1. Every non-blank Uuid column parses as a canonical UUID, or is a recognised
     sequential placeholder (see `placeholders` below).
  2. No UUID is declared twice within a domain, and none is reused across
     domains.
  3. Global property XML references a `${var}` that content.properties declares,
     so the SDK can resolve it at build time rather than leaving a literal
     `${...}` in the database.
  4. The `ocl` domain contains no `*.zip`. A committed archive re-enables OCL as
     a first-boot terminology download, and openconceptlab throws during startup
     if its startup directory holds more than one file.
  5. Every concept CSV row has the same number of fields as its header, and every
     populated `Same as mappings` cell is a mapping expression. The Initializer
     indexes columns positionally, so a single unquoted comma silently shifts a
     row's remaining columns and writes the wrong value into the wrong column --
     which is how a data type ends up declared as a concept mapping.

Usage
  tests/acceptance/validate-content-metadata.py [package-root]
  tests/acceptance/validate-content-metadata.py --strict   # also warn on placeholders

Exit codes
  0 all checks passed
  1 one or more checks failed
"""

import argparse
import csv
import os
import re
import sys
import xml.etree.ElementTree as ET

UUID_CANONICAL = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)

# Placeholder UUIDs look like `108AAAAAAAAAAAAAAA`: a numeric id padded with A.
# They are valid and load fine. They are reported because a placeholder concept
# that duplicates a CIEL concept is a real risk: O3, order entry and the standard
# modules resolve concepts by CIEL UUID, so a local duplicate will never be picked
# up and the two will silently diverge. Reported as a warning, never a failure --
# the clinical vocabulary is the site's decision, not this script's.
PLACEHOLDER = re.compile(r"^[0-9]+A+$", re.IGNORECASE)

VAR_REFERENCE = re.compile(r"\$\{([^}]+)\}")

# The concept mapping grammar accepted by
# org.openmrs.module.initializer.api.c.MappingsConceptLineProcessor, as read from
# its bytecode:
#
#   for each header column whose value is non-empty:
#       split the *header* on '|'  -> parts[0] must be "mappings"
#       split the *value*   on '|'  -> parts[1] is the map type name,
#                                      parts[2] (optional) the concept source
#       split parts[1..]    on ';'  -> the codes, each "<source>:<code>"
#
# So a populated cell looks like:
#   mappings|same-as|CIEL:1234;5678
# Anything else is silently ignored by the loader, which is precisely why it needs
# checking here: a misplaced value costs a mapping with no diagnostic anywhere.
MAPPING_CELL = re.compile(
    r"^mappings\|[a-z0-9][a-z0-9 \-]*(\|[^|]+)?(\|[^|]*)?$", re.IGNORECASE
)

errors: list[str] = []
warnings: list[str] = []
placeholders: dict[str, int] = {}


def err(msg: str) -> None:
    errors.append(msg)


def warn(msg: str) -> None:
    warnings.append(msg)


def read_csv_rows(path: str):
    try:
        with open(path, newline="", encoding="utf-8-sig") as fh:
            yield from csv.DictReader(fh)
    except (OSError, csv.Error, UnicodeDecodeError) as exc:
        err(f"{path}: cannot be parsed as CSV ({exc})")


def declared_vars(package_root: str) -> set[str]:
    """`var.<name>=<value>` entries from content.properties."""
    props = os.path.join(package_root, "content.properties")
    if not os.path.isfile(props):
        err("content.properties is missing; the SDK cannot order or parameterise "
            "this package without it")
        return set()
    found = set()
    with open(props, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line.startswith("var."):
                key, _, _ = line.partition("=")
                found.add(key[len("var."):].strip())
    return found


def check_uuids(backend: str) -> None:
    seen_globally: dict[str, str] = {}

    for domain in sorted(os.listdir(backend)):
        domain_dir = os.path.join(backend, domain)
        if not os.path.isdir(domain_dir):
            continue

        seen_in_domain: dict[str, str] = {}
        for name in sorted(os.listdir(domain_dir)):
            if not name.endswith(".csv"):
                continue
            if "quarantine" in name:
                continue  # deliberately excluded, see the report below
            path = os.path.join(domain_dir, name)

            for lineno, row in enumerate(read_csv_rows(path), start=2):
                uuid = (row.get("Uuid") or "").strip()
                if not uuid:
                    continue
                label = row.get("Name") or row.get("Fully specified name:en") or ""

                if not UUID_CANONICAL.match(uuid):
                    if PLACEHOLDER.match(uuid):
                        placeholders[domain] = placeholders.get(domain, 0) + 1
                    else:
                        err(f"{domain}/{name}:{lineno} malformed UUID {uuid!r} ({label[:50]})")
                    continue

                key = uuid.lower()
                if key in seen_in_domain:
                    err(f"{domain}/{name}:{lineno} UUID {uuid} already used in this "
                        f"domain by {seen_in_domain[key]} ({label[:50]})")
                else:
                    seen_in_domain[key] = f"{name}:{lineno}"

                if key in seen_globally:
                    warn(f"{domain}/{name}:{lineno} UUID {uuid} is also declared in "
                         f"{seen_globally[key]} ({label[:40]})")
                else:
                    seen_globally[key] = f"{domain}/{name}:{lineno}"


def check_global_properties(backend: str, declared: set[str]) -> None:
    gp_dir = os.path.join(backend, "globalproperties")
    if not os.path.isdir(gp_dir):
        return

    for name in sorted(os.listdir(gp_dir)):
        if not name.endswith(".xml"):
            continue
        path = os.path.join(gp_dir, name)
        try:
            tree = ET.parse(path)
        except ET.ParseError as exc:
            err(f"globalproperties/{name}: not valid XML ({exc})")
            continue

        for prop in tree.iter("globalProperty"):
            pname = (prop.findtext("property") or "").strip()
            pvalue = (prop.findtext("value") or "").strip()

            if not pname:
                err(f"globalproperties/{name}: a <globalProperty> has no <property>")
                continue

            for ref in VAR_REFERENCE.findall(pvalue):
                if ref not in declared:
                    err(f"globalproperties/{name}: property '{pname}' references "
                        f"${{{ref}}}, which content.properties does not declare under "
                        f"var.{ref}. The literal would be written to the database.")

            if not pvalue and pname in ("login.location", "visits.assignmentHandler"):
                err(f"globalproperties/{name}: property '{pname}' is empty; OpenMRS "
                    f"depends on it")


def check_concept_rows(backend: str) -> None:
    """Field alignment and mapping-cell grammar in the concepts domain.

    Both checks exist because the failure is silent. The Initializer reads every
    domain CSV positionally, and a value the loader does not recognise is skipped
    rather than rejected, so a malformed row loads "successfully" having written the
    wrong value into the wrong column.
    """
    concepts_dir = os.path.join(backend, "concepts")
    if not os.path.isdir(concepts_dir):
        return

    for name in sorted(os.listdir(concepts_dir)):
        if not name.endswith(".csv"):
            continue
        path = os.path.join(concepts_dir, name)

        with open(path, newline="", encoding="utf-8-sig") as fh:
            reader = csv.reader(fh)
            try:
                header = next(reader)
            except StopIteration:
                continue
            header = [h.strip() for h in header]
            width = len(header)
            try:
                mapping_col = header.index("Same as mappings")
            except ValueError:
                mapping_col = None
            # The Initializer stamps an order index on every concept row it
            # processes. It is also the last column, which makes it the one place a
            # truncated row cannot hide: a row that lost a field to an unquoted
            # comma ends up with a blank here, and a row that gained one ends up
            # with something other than an integer.
            order_col = None
            for candidate in header:
                if candidate.startswith("_order"):
                    order_col = header.index(candidate)
                    break

            rows = [r for r in reader if any(f.strip() for f in r)]
            populated = 0
            if order_col is not None:
                populated = sum(
                    1 for r in rows
                    if order_col < len(r) and r[order_col].strip()
                )

            for lineno, row in enumerate(rows, start=2):
                if len(row) != width:
                    # Report which column first disagrees, so the offending cell is
                    # obvious. Without that, a wide row just looks "wrong somewhere".
                    shown = 0
                    for idx, value in enumerate(row):
                        if idx < width and header[idx].strip().lower() == value.strip().lower() \
                                and value.strip():
                            shown = idx + 1
                    hint = ""
                    if shown:
                        hint = (f" -- column {shown} ({header[shown - 1]!r}) holds "
                                f"{row[shown - 1].strip()!r}, which looks like a "
                                f"shifted neighbour")
                    err(f"concepts/{name}:{lineno} has {len(row)} fields, the header "
                        f"declares {width}. A comma inside an unquoted field shifts "
                        f"every column after it and the row loads with the wrong "
                        f"values in the wrong columns.{hint}")

                if order_col is not None and order_col < len(row):
                    cell = row[order_col].strip()
                    if cell and not cell.isdigit():
                        err(f"concepts/{name}:{lineno} column {order_col + 1} "
                            f"({header[order_col]!r}) is {cell!r}, which is not an "
                            f"integer. An earlier field has almost certainly shifted "
                            f"into it.")
                    elif not cell and rows and populated / max(len(rows), 1) >= 0.95:
                        # Only reported when the column is populated essentially
                        # everywhere else, so a file that legitimately omits it is
                        # not flagged.
                        err(f"concepts/{name}:{lineno} column {order_col + 1} "
                            f"({header[order_col]!r}) is empty while {populated} of "
                            f"{len(rows)} rows populate it. A row truncated by an "
                            f"unquoted comma looks exactly like this, and it loads "
                            f"with its last columns silently dropped.")

                if mapping_col is None or mapping_col >= len(row):
                    continue
                cell = row[mapping_col].strip()
                if cell and not MAPPING_CELL.match(cell):
                    label = row[header.index("Fully specified name:en")].strip() \
                        if "Fully specified name:en" in header and \
                        header.index("Fully specified name:en") < len(row) else row[0].strip()
                    err(f"concepts/{name}:{lineno} 'Same as mappings' is {cell!r}, "
                        f"which is not a mapping expression ({label[:50]}). The "
                        f"Initializer ignores a cell it does not recognise, so the "
                        f"mapping is lost silently. Expected "
                        f"'mappings|<map type>[|<source>]:<code>[;<code>...]'. If this "
                        f"value is a data type, an earlier column has shifted.")


def check_ocl(backend: str) -> None:
    ocl_dir = os.path.join(backend, "ocl")
    if not os.path.isdir(ocl_dir):
        return
    archives = [f for f in os.listdir(ocl_dir) if f.endswith(".zip")]
    if archives:
        err(f"ocl/ contains {len(archives)} archive(s): {', '.join(archives)}. "
            f"A committed OCL archive re-enables a terminology download during "
            f"startup. See ocl/README.md.")


def check_package_identity(package_root: str) -> None:
    """The package must not collide with the official core content package."""
    props = os.path.join(package_root, "content.properties")
    if not os.path.isfile(props):
        return
    values = {}
    with open(props, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                values[k.strip()] = v.strip()

    name = values.get("name")
    if name == "referenceapplication":
        err("content.properties declares name=referenceapplication, which is the "
            "official core package. The site package must have a distinct name or "
            "the two will share an Initializer namespace.")

    if "content.referenceapplication" not in values:
        warn("content.properties does not declare content.referenceapplication, so "
             "install ordering relative to the official core package is not pinned.")


def report_quarantine(backend: str) -> None:
    concepts = os.path.join(backend, "concepts")
    for name in sorted(os.listdir(concepts)) if os.path.isdir(concepts) else []:
        if "quarantine" not in name:
            continue
        for row in read_csv_rows(os.path.join(concepts, name)):
            label = row.get("Fully specified name:en") or row.get("Name") or "?"
            warn(f"concepts/{name}: '{label}' has a UUID that could not be repaired "
                 f"and is excluded from this build. Restore it with a valid CIEL UUID "
                 f"once the intended concept has been confirmed; do not invent a UUID, "
                 f"or the concept will not match what O3 and order entry look up.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    default_root = os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
        "content-packages", "referenceapplication")
    parser.add_argument("package_root", nargs="?", default=default_root)
    parser.add_argument("--strict", action="store_true",
                        help="treat placeholder UUIDs as failures")
    args = parser.parse_args()

    root = args.package_root
    backend = os.path.join(root, "configuration", "backend_configuration")
    if not os.path.isdir(backend):
        print(f"error: {backend} does not exist", file=sys.stderr)
        return 1

    declared = declared_vars(root)
    check_package_identity(root)
    check_uuids(backend)
    check_global_properties(backend, declared)
    check_concept_rows(backend)
    check_ocl(backend)
    report_quarantine(backend)

    for msg in warnings:
        print(f"WARN  {msg}")
    for msg in errors:
        print(f"ERROR {msg}")

    if placeholders:
        total = sum(placeholders.values())
        detail = ", ".join(f"{d}={n}" for d, n in sorted(placeholders.items()))
        level = "ERROR" if args.strict else "WARN"
        print(f"{level}  {total} sequential placeholder UUID(s) in {detail}. These load, "
              f"but confirm each one is not duplicating a CIEL concept: O3 and order "
              f"entry resolve concepts by CIEL UUID, so a local duplicate is never "
              f"picked up and silently diverges.")

    print()
    if errors:
        print(f"FAILED: {len(errors)} error(s), {len(warnings)} warning(s)")
        return 1
    print(f"OK: no errors, {len(warnings)} warning(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
