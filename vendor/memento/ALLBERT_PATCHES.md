# Allbert Patch Notes For Memento

Source: Hex `:memento` 0.5.0.

This vendored copy exists because `:memento` 0.5.0 defines
`Memento.Table.record/0` as a typespec, and Elixir 1.19 treats `record/0` as a
built-in type. The Hex package therefore fails before Allbert's v0.41 developer
efficiency benchmark can run.

Allbert patch:

- rename the vendored type `Memento.Table.record/0` to
  `Memento.Table.memento_record/0`
- update internal specs and docs in the vendored copy to use
  `memento_record/0`
- leave runtime Mnesia/table/query behavior unchanged

The repo-level decision record is
`docs/adr/0050-vendored-memento-compatibility-override.md`.

Remove this vendored copy only after upstream Memento or Jido no longer requires
the compatibility override and the v0.41 release gate remains green.
