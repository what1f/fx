#ifndef LIBFX_SWIFT_SQLITE_H
#define LIBFX_SWIFT_SQLITE_H

#include <sqlite3.h>

static inline int fx_sqlite_bind_bytes(sqlite3_stmt *statement, int index, const void *bytes, int count) {
    return count == 0 ? sqlite3_bind_zeroblob(statement, index, 0)
                      : sqlite3_bind_blob(statement, index, bytes, count, SQLITE_TRANSIENT);
}

static inline int fx_sqlite_bind_string(sqlite3_stmt *statement, int index, const char *text, int count) {
    return sqlite3_bind_text(statement, index, text, count, SQLITE_TRANSIENT);
}

#endif
