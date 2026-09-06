// The `margins_ffiFFI` target is header-only: it carries the UniFFI
// header and module map that the generated Swift bindings import. Xcode's
// SwiftPM integration expects every C target to emit an object file, so
// this translation unit exists to give it one. The symbol is internal and
// stripped at link time.
int margins_ffi_ffi_target_placeholder(void) {
    return 0;
}
