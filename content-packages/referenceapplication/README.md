# OpenMRS Reference Application Content

This content package contains the baseline metadata necessary to run a verison of O3. Please note that while
the metadata here is all that's _required_, this does not provide the metadata necessary for every feature to
work. That is because the metadata needed for various things, like the formulary or procedure catalog is
expected to be customized for most sites.

Additional metadata used in the O3 demo environments is contained in the Reference Application Demo content
package: https://github.com/openmrs/openmrs-content-referenceapplication-demo

Generally, the goal is to make the "referenceapplication" content package free from content that an
implementation might need to customize and to stick to only core content backing specific things. For example,
the O3 Login page requires that the "Login Location" tag be available (and associated with at least one
location), but locations vary by implementation and even site, so this package just contains the tag.
Similarly, the Immunization feature requires the CIEL Immunization History concept set to structure obs so
this is included but the list of immunizations should not be.

## Deploy

```
mvn clean verify

mvn clean deploy
```
