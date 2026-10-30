# Security policy

This policy covers the open-source aisqltuner-index-tuner only. For
[AI SQL Tuner Studio](https://aisqltuner.com), the commercial desktop app, see its website.

## Supported versions

Only the latest version on `main` receives security fixes.

## Reporting a vulnerability

Please report vulnerabilities privately. Do not open a public issue.

Use GitHub's private vulnerability reporting: go to the
[Security tab](https://github.com/AI-SQL-Tuner/aisqltuner-index-tuner/security) and choose
**Report a vulnerability**.

Include:

- the affected procedure or file and the version or commit
- the SQL Server or Azure SQL platform and version
- steps to reproduce, or a proof of concept
- the impact you expect

We aim to acknowledge a report within 5 business days and to tell you what we plan to do about it
within 14 days. This is a best-effort target for a free, open source project, not a guarantee.

## In scope

- Any way to make `sp_AIIndexTuner` or `sp_AIIndexTuner_Apply` run SQL other than the `CREATE INDEX`
  and `DROP INDEX` statements it builds from validated fields. This includes SQL injection through
  object names, index names or other catalog data, and prompt injection through plan cache or Query
  Store text that changes what the procedures execute.
- Any way to bypass the change controls (`@AllowColumnstore`, `@AllowDropIndex`, `@MaxNewIndexes`),
  the apply thresholds (`@MinPriority`, `@MinConfidence`) or the drop safety checks described in
  the README.
- Disclosure of the endpoint credential or API key, or sending data to anywhere other than the
  Azure OpenAI endpoint you configure.

## Out of scope

- Incorrect or poor index recommendations. The model's output varies between runs and its `Script`
  column is never executed. Report these as ordinary issues.
- Data you choose to send to your own endpoint. The README's *Data disclosure* section lists what
  is sent, and `IncludeQueryText = 0` leaves out plan cache query text.
- Vulnerabilities in SQL Server, Azure SQL, Azure OpenAI or other Microsoft products. Report those
  to Microsoft.
- Issues that need `sysadmin` or equivalent rights the caller already has.

## Using the tool safely

- Run `@Mode = 'RECOMMEND'` (the default) first and review `AIIndexTuner.Recommendation`.
- Use a managed identity, or a key you can rotate, for the endpoint credential. Never commit a
  filled-in `setup/Configure-Endpoint.sql`.
- Grant only the permissions the README lists, and `ALTER` on tables only when you use `CREATE` mode.
- Test in a non-production database first.
