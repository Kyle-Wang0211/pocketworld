# Design: SQLite exact transform v2 benchmark

The transform operates on an output copy and maps targeted COLMAP BLOB payloads
to their exact SQLite page and overflow-page spans. It never uses SQLite UPDATE,
VACUUM, export, or reserialization, because those operations would lose the
original file's physical bytes.

Forward order is descriptor track delta, keypoint float-bit byte-plane XOR,
matches uint32-column delta, then two-view uint32-column delta. Inverse order is
the exact reverse so that two-view indices are restored before descriptor-track
reconstruction needs them.

Every transformation preserves BLOB length and uses only XOR or modular integer
addition/subtraction. Unsupported schemas fail closed and delete the candidate.
The benchmark always restores the complete database and compares it against the
immutable input before measuring a candidate as valid.

The host result can reject but cannot admit production. A host winner proceeds
to one run in the existing independent benchmark bundle; the production bundle
and container remain out of scope.
