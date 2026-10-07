#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# Assert that the Initializer omod in this distro declares a usable <package>.
#
# WHY THIS EXISTS
#   A module's <package> in config.xml is not cosmetic metadata. OpenMRS resolves
#   a module's <require_module> entries by string-matching the required name
#   against Module.getPackageName(), which is that element, and there is no
#   fallback to the module id. A module that declares the right package under the
#   wrong name is therefore not merely mislabelled: every module that depends on
#   it refuses to start.
#
#   That is not hypothetical. Initializer 2.12.1-intuvance.1 was published under
#   the Maven groupId io.github.intuvance and derived <package> from those
#   coordinates, so it claimed io.github.intuvance.initializer while its classes
#   were, and still are, in org.openmrs.module.initializer. patientdocuments 1.1.0
#   requires org.openmrs.module.initializer 2.9.0, so it was silently skipped with
#   "cannot be started because it requires the following module(s): initializer
#   2.9.0" -- while the Initializer itself ran perfectly. Nothing failed. The
#   build succeeded, the healthcheck passed, and a module was simply absent.
#   2.12.1-intuvance.2 fixes the declaration.
#
# WHAT IT CHECKS
#   The declared <package> must equal the package of the declared <activator>.
#   That single comparison is the whole invariant, and it is self-anchoring: the
#   activator is the class OpenMRS instantiates to start the module, so it cannot
#   drift from the real Java package without the module failing to start outright
#   even when nothing depends on it.
#
# USAGE
#   deployment/verify-initializer-package.py <omod-or-jar> [omod-or-jar ...]
#
# Exit codes
#   0  every omod checked declares a package consistent with its activator
#   1  a mismatch, or a file whose package/activator could not be read
#   2  no files given
# ---------------------------------------------------------------------------
import os
import re
import sys
import zipfile


def read_identity(path):
    """Return (package, activator) declared by an omod/jar, or (None, None).

    omods are zip files carrying config.xml at the root; so are the module jars
    the OpenMRS SDK produces from them.
    """
    with zipfile.ZipFile(path) as archive:
        xml = archive.read("config.xml").decode("utf-8")

    # Strip XML comments before looking for tags. config.xml carries prose that
    # mentions <activator> by name, and a comment containing a complete
    # <package>...</package> pair would otherwise be read as the real element.
    xml = re.sub(r"<!--.*?-->", "", xml, flags=re.S)

    def tag(name):
        match = re.search(r"<%s>(.*?)</%s>" % (name, name), xml, re.S)
        return match.group(1).strip() if match else ""

    return tag("package"), tag("activator")


def check(path):
    try:
        package, activator = read_identity(path)
    except (zipfile.BadZipFile, KeyError) as exc:
        return "%s: cannot read config.xml (%s)" % (path, exc)

    if not package or not activator:
        return "%s: could not read <package>/<activator> from config.xml" % path

    if package != activator.rsplit(".", 1)[0]:
        return (
            "%s: declares <package>%s</package> but its activator is %s.\n"
            "    OpenMRS matches require_module against <package> only, with no\n"
            "    fallback to the module id, so every module declaring a dependency\n"
            "    on %s will refuse to start -- silently, and with no build failure."
            % (path, package, activator, activator.rsplit(".", 1)[0])
        )

    return None


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: %s <omod-or-jar> [...]\n" % os.path.basename(argv[0]))
        return 2

    failures = 0
    for path in argv[1:]:
        problem = check(path)
        if problem:
            print("FATAL: %s" % problem, file=sys.stderr)
            failures += 1
        else:
            print("initializer package OK: %s -> %s" % (path, read_identity(path)[0]))

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
