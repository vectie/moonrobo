# Streamed checkpoint blobs

This package stores one numeric field per raw little-endian sidecar. `BlobDescriptor`
records a safe basename, dtype (`f64le`, `i32le`, or `u8`), shape, element count,
byte length, and SHA-256. Rank 1–4 shapes may contain a zero dimension; scalar
empty-rank shapes are rejected. A blob is capped at 64 GiB. Each encoded or
decoded chunk is at most 64 KiB; typed values and encoded bytes coexist, so
transient payload memory is at least about 128 KiB plus metadata. A caller can
retain callback arrays, which is outside this package's memory bound.

Use `write_f64le`, `write_i32le`, or `write_u8` with an indexed chunk producer.
The writer uses a new `.partial` file, syncs it, and publishes the final basename
without replacement. A fresh checkpoint generation should be published only
after all sidecars and its metadata have been written. On restore, call
`verify_blob` for every descriptor before mutating model state, then use the
matching `read_*` callback API. Readers verify SHA-256 before delivering values
and rehash the delivered bytes through the same open file descriptor. The
callbacks are not transactional: an in-place file edit during the second pass
can still deliver values before the final digest fails. Restore into isolated
staging and commit only after every read succeeds. Readers never allocate an
entire blob.

The codec preserves every F64 bit pattern, including signed zero and NaN
payloads. Field owners must enforce their own finite-value and shape semantics
before committing restored state. This package does not change the v1 JSON
checkpoint format or training memory guard. Roots are resolved to canonical
paths; final filenames must be safe basenames of at most 247 UTF-8 bytes to
leave room for the `.partial` staging suffix. This is not a security boundary
against a malicious process concurrently replacing filesystem entries.
