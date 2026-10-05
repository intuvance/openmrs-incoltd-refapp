# `ocl/` — OpenConceptLab subscription archives

This directory is intentionally empty of `*.zip` files.

The Initializer's `ocl` domain imports any OCL dictionary archive (`*.zip`) placed
here. The `openconceptlab` module also scans a separate startup directory
(`openconceptlab.oclLoadAtStartupPath`) and throws an `IllegalStateException` during
module startup if that directory contains more than one file, or a file that is not a
single `*.zip`. Populating either location turns OCL back into a first-boot
terminology download, which this distribution deliberately avoids.

## When to use this directory

Only to seed terminology that is genuinely absent from CIEL and from the pre-populated
database, and only for a site that controls its own OCL instance.

- Prefer an existing CIEL concept. Do not add a local concept that duplicates a CIEL
  one — the O3 frontend, order entry and several modules reference CIEL concepts by
  hard-coded UUID, so a duplicate will not be picked up and will silently diverge.
- Place the archive here only if you also provide a matching
  `globalProperties/ocl.xml` with an authenticated `openconceptlab.subscriptionUrl`,
  and you accept a slow first startup.

## Required global properties for a self-hosted OCL

```
openconceptlab.subscriptionUrl = https://api.ocls.example.org/users/<user>/collections/<collection>
openconceptlab.token          = <subscriber token>
```

Use the `api.` host form. The token is sent as an `Authorization: Token <token>`
header and is discarded across HTTP redirects, so a redirecting proxy in front of OCL
will silently degrade you to anonymous access.

Tokens are secrets. They belong in deployment configuration or Docker secrets, never
in this repository.
