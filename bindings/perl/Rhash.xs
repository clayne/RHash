#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <rhash.h>
#include <rhash_torrent.h>

typedef unsigned long long ulonglong;

/* helper macros and functions */
#define BASE32_LENGTH(size) (((size) * 8 + 4) / 5)
#define BASE64_LENGTH(size) ((((size) + 2) / 3) * 4)

void verify_single_bit_hash_id(unsigned hash_id, CV* cv)
{
	const char* error;
	const GV *gv;
	const char *func_name;

	if(0 == (hash_id & RHASH_ALL_HASHES)) {
		error = "%s: unsupported hash_id = 0x%x";
	} else if(0 != (hash_id & (hash_id - 1))) {
		error = "%s: hash_id is not a single bit: 0x%x";
	} else {
		return; /* success */
	}

	gv = CvGV(cv);
	func_name = (gv ? GvNAME(gv) : "Rhash");
	croak(error, func_name, hash_id);
}

/* allocate a perl string scalar variable, containing str_len + 1 bytes */
SV * allocate_string_buffer(STRLEN str_len)
{
	SV * sv = newSV(str_len); /* allocates (str_len + 1) bytes */
	SvPOK_only(sv);
	SvCUR_set(sv, str_len);
	return sv;
}

MODULE = Crypt::Rhash      PACKAGE = Crypt::Rhash

##############################################################################
# Initialize LibRHash in the module bootstrap function

BOOT:
	rhash_library_init();

##############################################################################
# perl bindings for Hi-level functions

SV *
rhash_msg_wrapper(hash_id, message)
		unsigned	hash_id
	PROTOTYPE: $$
	PREINIT:
		STRLEN length;
		unsigned char out[264];
		int res;
	INPUT:
		char* message = SvPV(ST(1), length);
	CODE:
		verify_single_bit_hash_id(hash_id, cv);
		res = rhash_msg(hash_id, message, length, out);
		if(res < 0) {
			croak("%s: %s", "rhash_msg_wrapper", strerror(errno));
		}
		RETVAL = newSVpv((char*)out, rhash_get_digest_size(hash_id));
	OUTPUT:
		RETVAL

SV *
rhash_file_wrapper(hash_id, filepath)
		unsigned hash_id
		char * filepath
	PROTOTYPE: $$
	PREINIT:
		int res;
		unsigned char out[264];
	CODE:
		verify_single_bit_hash_id(hash_id, cv);
		res = rhash_file(hash_id, filepath, out);
		if(res < 0) {
			croak("%s: %s: %s", "rhash_file", filepath, strerror(errno));
		}
		RETVAL = newSVpv((char*)out, rhash_get_digest_size(hash_id));
	OUTPUT:
		RETVAL

##############################################################################
# perl bindings for Low-level functions

struct rhash_context *
rhash_init_multi_wrapper(AV* array)
	PROTOTYPE: $
	PREINIT:
		unsigned hash_ids[64];
		size_t length = 0;
		int i;
	CODE:
		for (i = 0; i <= av_len(array); i++) {
			SV** elem = av_fetch(array, i, 0);
			if (elem != NULL) {
				if (length >= (sizeof(hash_ids)/sizeof(*hash_ids)))
					croak("too many hash identifiers passed");
				hash_ids[length] = (unsigned)SvNV(*elem);
				length++;
			}
		}
		if (length == 0)
			croak("at least one hash identifier must be passed");
		RETVAL = rhash_init_multi(length, hash_ids);
	OUTPUT:
		RETVAL

int
rhash_update(ctx, message)
		struct rhash_context * ctx
	PROTOTYPE: $$
	PREINIT:
		STRLEN length;
	INPUT:
		char* message = SvPV(ST(1), length);
	CODE:
		RETVAL = rhash_update(ctx, message, length);
	OUTPUT:
		RETVAL

int
rhash_final(ctx)
		struct rhash_context * ctx
	PROTOTYPE: $
	CODE:
		RETVAL = rhash_final(ctx, 0);
	OUTPUT:
		RETVAL

void
rhash_reset(ctx)
		struct rhash_context * ctx
	PROTOTYPE: $

void
rhash_free(ctx)
		struct rhash_context * ctx
	PROTOTYPE: $

SV *
rhash_print_wrapper(ctx, hash_id, flags = 0)
		struct rhash_context * ctx
		unsigned hash_id
		int flags
	PROTOTYPE: $$;$
	PREINIT:
		int len;
		char out[264];
	CODE:
		if(hash_id != 0) verify_single_bit_hash_id(hash_id, cv);

		len = rhash_print(out, ctx, hash_id, flags);

		/* set exact length to support raw output (RHPR_RAW) */
		RETVAL = newSVpv(out, len);
	OUTPUT:
		RETVAL

SV *
rhash_print_magnet_wrapper(ctx, filename, hash_mask)
		struct rhash_context * ctx
		SV * filename
		SV * hash_mask
	PROTOTYPE: $;$$
	PREINIT:
		/* process undefined values */
		char * name = (SvOK(filename) ? SvPV_nolen(filename) : 0);
		unsigned mask = (SvOK(hash_mask) ? (unsigned)SvUV(hash_mask) : RHASH_ALL_HASHES);
		size_t buf_size;
	CODE:
		/* allocate a string buffer and print magnet link into it */
		buf_size = rhash_print_magnet(0, name, ctx, mask, RHPR_FILESIZE);
		RETVAL = allocate_string_buffer(buf_size - 1);
		rhash_print_magnet(SvPVX(RETVAL), name, ctx, mask, RHPR_FILESIZE);

		/* note: length(RETVAL) = (buf_size - 1),
		 * so the following call is not required:
		 * SvCUR_set(RETVAL, strlen(SvPVX(RETVAL))); */
	OUTPUT:
		RETVAL

unsigned
rhash_get_hash_id(ctx)
		struct rhash_context * ctx
	PROTOTYPE: $
	CODE:
		RETVAL = ctx->hash_id;
	OUTPUT:
		RETVAL

ulonglong
rhash_get_hashed_length(ctx)
		struct rhash_context * ctx
	PROTOTYPE: $
	CODE:
		RETVAL = ctx->msg_size;
	OUTPUT:
		RETVAL

##############################################################################
# Information functions

int
count()
	CODE:
		RETVAL = rhash_count();
	OUTPUT:
		RETVAL

SV *
librhash_version_string()
	PREINIT:
		unsigned version;
	CODE:
		version = rhash_get_version();
		RETVAL = allocate_string_buffer(20);
		sprintf(SvPVX(RETVAL), "%u.%u.%u", (version >> 24) & 255, (version >> 16) & 255, (version >> 8) & 255);
		SvCUR_set(RETVAL, strlen(SvPVX(RETVAL)));
	OUTPUT:
		RETVAL

int
librhash_version()
	CODE:
		RETVAL = rhash_get_version();
	OUTPUT:
		RETVAL

int
is_base32(hash_id)
		unsigned hash_id
	PROTOTYPE: $
	CODE:
		RETVAL = rhash_is_base32(hash_id);
	OUTPUT:
		RETVAL

int
get_digest_size(hash_id)
		unsigned hash_id
	PROTOTYPE: $
	CODE:
		RETVAL = rhash_get_digest_size(hash_id);
	OUTPUT:
		RETVAL

int
get_hash_length(hash_id)
		unsigned hash_id
	PROTOTYPE: $
	CODE:
		RETVAL = rhash_get_hash_length(hash_id);
	OUTPUT:
		RETVAL

const char *
get_name(hash_id)
		unsigned hash_id
	PROTOTYPE: $
	CODE:
		RETVAL = rhash_get_name(hash_id);
	OUTPUT:
		RETVAL

##############################################################################
# Hash printing functions

##############################################################################
# Hash conversion functions

SV *
raw2hex(bytes)
	PROTOTYPE: $
	PREINIT:
		STRLEN size;
	INPUT:
		unsigned char * bytes = (unsigned char*)SvPV(ST(0), size);
	CODE:
		RETVAL = allocate_string_buffer(size * 2);
		rhash_print_bytes(SvPVX(RETVAL), bytes, size, RHPR_HEX);
	OUTPUT:
		RETVAL

SV *
raw2base32(bytes)
	PROTOTYPE: $
	PREINIT:
		STRLEN size;
	INPUT:
		unsigned char * bytes = (unsigned char*)SvPV(ST(0), size);
	CODE:
		RETVAL = allocate_string_buffer(BASE32_LENGTH(size));
		rhash_print_bytes(SvPVX(RETVAL), bytes, size, RHPR_BASE32);
	OUTPUT:
		RETVAL

SV *
raw2base64(bytes)
	PROTOTYPE: $
	PREINIT:
		STRLEN size;
	INPUT:
		unsigned char * bytes = (unsigned char*)SvPV(ST(0), size);
	CODE:
		RETVAL = allocate_string_buffer(BASE64_LENGTH(size));
		rhash_print_bytes(SvPVX(RETVAL), bytes, size, RHPR_BASE64);
	OUTPUT:
		RETVAL

##############################################################################
# BTIH / BitTorrent support functions

void
rhash_bt_add_filename(ctx, filename, filesize)
		struct rhash_context * ctx
		char * filename
		ulonglong filesize
	PROTOTYPE: $$$
	CODE:
		rhash_torrent_add_file(ctx, filename, filesize);

void
rhash_bt_set_piece_length(ctx, piece_length)
		struct rhash_context * ctx
		unsigned piece_length
	PROTOTYPE: $$
	CODE:
		rhash_torrent_set_piece_length(ctx, piece_length);

void
rhash_bt_set_private(ctx)
		struct rhash_context * ctx
	PROTOTYPE: $
	CODE:
		rhash_torrent_set_options(ctx, RHASH_TORRENT_OPT_PRIVATE);

SV *
rhash_bt_get_torrent_text(ctx)
		struct rhash_context * ctx
	PROTOTYPE: $
	PREINIT:
		const rhash_str* text;
	CODE:
		text = rhash_torrent_generate_content(ctx);
		if(!text) {
			XSRETURN_UNDEF;
		}
		RETVAL = newSVpv(text->str, text->length);
	OUTPUT:
		RETVAL
