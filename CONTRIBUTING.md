# Contributing

Thanks for contributing. Three things to know before you open a pull request.

## Keep the data-store schema page current

[`demos/data-store/index.html`](./demos/data-store/index.html) is the visual
guide to the catalog's PostgreSQL schema. Any pull request that changes
[`demos/data-store/sql/`](./demos/data-store/sql/) in a way that adds, removes,
renames or retypes a table, view, column or function must update, in the same
pull request:

- the `schema-data` block in `demos/data-store/index.html`: the object itself,
  each column's `origin` (from sources, platform config, generated on write,
  derived cache, computed on read) and `by` (what sets it), plus its purpose,
  rules, `writtenBy`/`readBy`, edges, and the guided tour if the logic it
  explains changed;
- [`docs/data-store/reference.md`](./docs/data-store/reference.md);
- [`demos/data-store/flows.html`](./demos/data-store/flows.html) ("How it
  works") when the change alters a flow it walks through: defining a kind,
  ingesting an instance, permissions, or ownership propagation. Its example
  rows come from running those scenarios against the seed, so re-run them
  and update the rows.

`./demo.sh test` (in `demos/data-store/`) runs `check-page`, which compares the
page with the live database and fails, showing the difference, while they
disagree. It also fails if `flows.html` names a table, view or function that
isn't on the schema page. Changes to logic that leave the shape alone (a function body, a
rule) aren't caught by the check, so update the page's text for those by hand.

## License

This project is licensed under the [Apache License 2.0](./LICENSE). By
contributing you agree that your contributions will be licensed under the same
terms.

## Contributor License Agreement

All contributors must sign the [Individual Contributor License
Agreement](./CLA.md) once. The process is automated:

1. Open your pull request.
2. The CLA Assistant bot comments on the PR if you have not signed yet.
3. Reply with this exact comment:

       I have read the CLA Document and I hereby sign the CLA

4. The bot records your signature and the `CLA Assistant` check turns green.
   You never need to sign again for this repository.

If you are contributing on behalf of an employer, make sure you have your
employer's permission before signing (see section 4 of the CLA).
