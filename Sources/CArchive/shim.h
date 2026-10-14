// Declarations for the system libarchive (/usr/lib/libarchive.2.dylib). The macOS SDK ships its
// link stub (libarchive.tbd) but not archive.h, so the functions QuickPeek uses are declared here,
// copied from libarchive 3's public header. All of them exist since libarchive 3.2 (2016).
// libarchive is BSD-2-Clause licensed: https://github.com/libarchive/libarchive
#ifndef QUICKPEEK_CARCHIVE_SHIM_H
#define QUICKPEEK_CARCHIVE_SHIM_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <time.h>

struct archive;
struct archive_entry;

#define ARCHIVE_EOF 1
#define ARCHIVE_OK 0
#define ARCHIVE_RETRY (-10)
#define ARCHIVE_WARN (-20)
#define ARCHIVE_FAILED (-25)
#define ARCHIVE_FATAL (-30)

#define ARCHIVE_FORMAT_BASE_MASK 0xff0000
#define ARCHIVE_FORMAT_CPIO 0x10000
#define ARCHIVE_FORMAT_TAR 0x30000
#define ARCHIVE_FORMAT_ISO9660 0x40000
#define ARCHIVE_FORMAT_ZIP 0x50000
#define ARCHIVE_FORMAT_AR 0x70000
#define ARCHIVE_FORMAT_RAW 0x90000
#define ARCHIVE_FORMAT_XAR 0xA0000
#define ARCHIVE_FORMAT_LHA 0xB0000
#define ARCHIVE_FORMAT_CAB 0xC0000
#define ARCHIVE_FORMAT_RAR 0xD0000
#define ARCHIVE_FORMAT_7ZIP 0xE0000
#define ARCHIVE_FORMAT_RAR_V5 0x100000

#define AE_IFMT ((mode_t)0170000)
#define AE_IFREG ((mode_t)0100000)
#define AE_IFLNK ((mode_t)0120000)
#define AE_IFDIR ((mode_t)0040000)

struct archive *archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);
int archive_read_support_format_raw(struct archive *);
int archive_read_open_filename(struct archive *, const char *filename, size_t block_size);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *buffer, size_t length);
int archive_read_data_skip(struct archive *);
int archive_read_free(struct archive *);

const char *archive_error_string(struct archive *);
int archive_format(struct archive *);
int archive_filter_count(struct archive *);
const char *archive_filter_name(struct archive *, int index);
int archive_read_has_encrypted_entries(struct archive *);

const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
const char *archive_entry_symlink_utf8(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
int archive_entry_size_is_set(struct archive_entry *);
time_t archive_entry_mtime(struct archive_entry *);
int archive_entry_mtime_is_set(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);

#endif
