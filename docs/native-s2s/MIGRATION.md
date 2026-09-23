# First installation and schema policy

No released ElixIRCd version has used the native S2S identity schema. The first
deployment starts from the current clean Mnesia schema; migration of a
pre-release native S2S database is not part of this release. Existing generic
ElixIRCd boot-time schema upgrades remain separate from native S2S.

Before enabling the native endpoint:

1. Stop any previous local process and remove only the local development
   database directory when starting a fresh installation.
2. Run the current schema bootstrap and confirm that every table has the
   attributes and type compiled into this release.
3. Review the configured SID, boot, roster, service authority, certificate
   pins, and policy epoch before opening the listener.
4. Start one endpoint, verify the local health projection, then add one
   configured edge at a time.

The bootstrap creates the current tables, validates their attributes and table
types, and fails on an incompatible existing table. It never uses the
recreate option during a normal application boot and never silently clears an
existing table to make an incompatible schema pass.

Registrations, grouped aliases, channel access, memos, and jobs are local
datasets. Linking servers does not select or merge those datasets. Choose and
consolidate an authority before enabling global services, and keep a separate
operator backup of any dataset changed during that maintenance work.

The native endpoint is disabled by default. A certificate or roster change
requires a controlled restart or the supported configuration reload path, and
the endpoint must remain closed until the profile and current schema checks
pass.

This policy is deliberately narrower than a rolling upgrade procedure because
the product has not been released with an older native identity schema.
