/* calc_sums.c - message digests calculating and printing functions */

#include "calc_sums.h"
#include "hash_print.h"
#include "output.h"
#include "parse_cmdline.h"
#include "platform.h"
#include "rhash_main.h"
#include "win_utils.h"
#include "librhash/rhash.h"
#include "librhash/rhash_torrent.h"
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h> /* free() */
#include <string.h>
#ifdef _WIN32
# include <fcntl.h>  /* _O_BINARY */
# include <io.h>
#endif


/*=========================================================================
 * Hash identifiers functions
 *=========================================================================*/

/**
 * Convert 64-bit hash_mask to a sequence of hash function identifiers.
 *
 * @param hash_mask bit mask
 * @param max_count maximum space in the hash_ids array
 * @param hash_ids array to store sequence of hash function identifiers
 * @param out_count count of stored hash function identifiers
 * @return -1 on error, 0 otherwise
 */
int hash_mask_to_hash_ids(uint64_t hash_mask, unsigned max_count,
	unsigned* hash_ids, unsigned* out_count)
{
	unsigned count;
	if (!hash_ids || !out_count)
		return -1;
	for (count = 0; hash_mask; count++) {
		uint64_t bit64 = hash_mask & -hash_mask;
		if (count == max_count)
			return -1;
		hash_ids[count] = bit64_to_hash_id(bit64);
		hash_mask ^= bit64;
	}
	*out_count = count;
	return 0;
}

static uint64_t hash_ids_to_hash_mask(size_t count, unsigned* hash_ids)
{
	uint64_t hash_mask = 0;
	size_t i;
	for (i = 0; i < count; i++)
		hash_mask |= hash_id_to_bit64(hash_ids[i]);
	return hash_mask;
}

/**
 * Enable openssl implementation for algorithms selected by the hash_mask.
 *
 * @param hash_mask bit mask for enabled hash functions
 * @return -1 on error, 0 otherwise
 */
int set_openssl_enabled_hash_mask(uint64_t hash_mask)
{
	unsigned hash_ids[64];
	unsigned count;
	size_t res;
	hash_mask &= ~OPENSSL_MASK_VALID_BIT; /* remove validity bit */
	if (hash_mask_to_hash_ids(hash_mask, 64, hash_ids, &count) < 0)
		return -1;
	rhash_set_openssl_enabled(count, hash_ids);
	res = rhash_get_openssl_enabled(0, NULL);
	return (res != RHASH_ERROR ? (int)res : -1);
}

#define unknown_bit 0x8000000000000000

/**
 * Return hash_mask for algorithms supported by openssl.
 ^
 * @return bit mask for supported hash functions
 */
uint64_t get_openssl_supported_hash_mask(void)
{
	static uint64_t supported = unknown_bit;
	if (supported == unknown_bit) {
		unsigned hash_ids[64];
		size_t count = rhash_get_openssl_supported(64, hash_ids);
		if (count != RHASH_ERROR)
			supported = hash_ids_to_hash_mask(count, hash_ids);
		supported &= ~unknown_bit;
	}
	return supported;
}

/**
 * Return hash_mask for algorithms supported by openssl.
 ^
 * @return bit mask for supported hash functions
 */
uint64_t get_all_supported_hash_mask(void)
{
	static uint64_t hash_mask = unknown_bit;
	if (hash_mask == unknown_bit) {
		unsigned hash_ids[64];
		size_t count = rhash_get_all_algorithms(64, hash_ids);
		RSH_REQUIRE(count != RHASH_ERROR, "failed to get all supported algorithms\n");
		hash_mask = hash_ids_to_hash_mask(count, hash_ids);
		hash_mask &= ~unknown_bit;
	}
	return hash_mask;
}

/*=========================================================================
 * Hash calculation functions
 *=========================================================================*/

/**
 * Initialize BTIH hash function. Unlike other algorithms BTIH
 * requires more data for correct computation.
 *
 * @param info the file data
 */
static void init_btih_data(struct file_info* info)
{
	assert((info->rctx->hash_mask & RHASH_BTIH) != 0);

	if (opt.flags & (OPT_BT_PRIVATE | OPT_BT_TRANSMISSION)) {
		unsigned options = (opt.flags & OPT_BT_PRIVATE ? RHASH_TORRENT_OPT_PRIVATE : 0)
			| (opt.flags & OPT_BT_TRANSMISSION ? RHASH_TORRENT_OPT_TRANSMISSION : 0);
		rhash_torrent_set_options(info->rctx, options);
	}

	rhash_torrent_add_file(info->rctx, file_get_print_path(info->file, FPathUtf8 | FPathNotNull), info->size);
	rhash_torrent_set_program_name(info->rctx, get_bt_program_name());

	if (opt.bt_announce) {
		size_t i;
		for (i = 0; i < opt.bt_announce->size; i++) {
			rhash_torrent_add_announce(info->rctx, (const char*)opt.bt_announce->array[i]);
		}
	}

	if (opt.bt_piece_length) {
		rhash_torrent_set_piece_length(info->rctx, opt.bt_piece_length);
	}
	else if (opt.bt_batch_file && rhash_data.batch_size) {
		rhash_torrent_set_batch_size(info->rctx, rhash_data.batch_size);
	}
}

/**
 * (Re)-initialize RHash context, to calculate message digests.
 *
 * @param info the file data
 */
static void re_init_rhash_context(struct file_info* info)
{
	if (rhash_data.rctx != 0) {
		if (IS_MODE(MODE_CHECK | MODE_CHECK_EMBEDDED) && rhash_data.last_hash_mask != info->hash_mask) {
			/* a set of hash algorithms has changed from the previous run */
			rhash_free(rhash_data.rctx);
			rhash_data.rctx = 0;
		} else {
			info->rctx = rhash_data.rctx;

			if (opt.bt_batch_file) {
				/* add another file to the torrent batch */
				rhash_torrent_add_file(info->rctx, file_get_print_path(info->file, FPathUtf8 | FPathNotNull), info->size);
				return;
			} else {
				rhash_reset(rhash_data.rctx);
			}
		}
	}

	if (rhash_data.rctx == 0) {
		uint64_t hash_mask = info->hash_mask;
		if (rhash_data.last_hash_mask != hash_mask) {
			unsigned count = 0;
			RSH_REQUIRE(hash_mask_to_hash_ids(hash_mask, 64, rhash_data.hash_ids, &count) >= 0,
				"failed to convert hash ids\n");
			rhash_data.hash_ids_count = count;
			rhash_data.last_hash_mask = hash_mask;
		}
		rhash_data.rctx = rhash_init_multi(rhash_data.hash_ids_count, rhash_data.hash_ids);
		info->rctx = rhash_data.rctx;
		RSH_REQUIRE(rhash_data.rctx, "failed to initialize hash context\n");
	}

	if (info->hash_mask & hash_id_to_bit64(RHASH_BTIH)) {
		/* re-initialize BitTorrent data */
		init_btih_data(info);
	}
}

/**
 * Calculate message digests simultaneously, according to the info->hash_mask.
 * Calculated message digests are stored in info->rctx.
 *
 * @param info file data
 * @return 0 on success, -1 on fail with error code stored in errno
 */
int calc_sums(struct file_info* info)
{
	int fd = -1;
	int res;

	assert(info->file);
	if (FILE_ISSTDIN(info->file)) {
		fd = 0;
#ifdef _WIN32
		/* using 0 instead of _fileno(stdin). _fileno() is undefined under 'gcc -ansi' */
		if (setmode(fd, _O_BINARY) < 0)
			return -1;
#endif
	} else {
		if (IS_MODE(MODE_CHECK | MODE_CHECK_EMBEDDED) && FILE_ISDIR(info->file)) {
			errno = EISDIR;
			return -1;
		}

		info->size = info->file->size; /* total size, in bytes */

		if (!info->hash_mask)
			return 0;

		if (!FILE_ISDATA(info->file)) {
			fd = file_open(info->file, FOpenReadBin);
			/* quietly skip unreadble files */
			if (fd < 0)
				return -1;
		}
	}

	re_init_rhash_context(info);
	/* store initial msg_size, for correct calculation of percents */
	info->msg_offset = info->rctx->msg_size;

	/* read and hash file content */
	if (FILE_ISDATA(info->file))
		res = rhash_update(info->rctx, info->file->data, (size_t)info->file->size);
	else {
		if (percents_output->update != 0) {
			rhash_set_callback(info->rctx, (rhash_callback_t)percents_output->update, info);
		}
		res = rhash_update_fd(info->rctx, fd, RHASH_MAX_FILE_SIZE);
	}
	if (res != -1 && !opt.bt_batch_file)
		rhash_final(info->rctx, 0); /* finalize hashing */

	/* store really processed data size */
	info->size = info->rctx->msg_size - info->msg_offset;
	rhash_data.total_size += info->size;

	if (fd >= 0 && !FILE_ISSTDIN(info->file))
		close(fd);
	return res;
}

/* functions to calculate and print file sums */

/**
 * Search for a crc32 checksum in the given file name.
 *
 * @param file the file, which filename is checked
 * @param crc32 pointer to integer to receive parsed checksum
 * @return non zero if crc32 was found, zero otherwise
 */
int find_embedded_crc32(file_t* file, unsigned* crc32)
{
	const char* filepath = file_get_print_path(file, FPathUtf8 | FPathNotNull);
	const char* e = filepath + strlen(filepath) - 10;
	unsigned char raw[4];

	/* search for the sum enclosed in brackets */
	for (; e >= filepath && !IS_PATH_SEPARATOR(*e); e--) {
		if ((*e == '[' && e[9] == ']') || (*e == '(' && e[9] == ')')) {
			const char* p = e + 8;
			for (; p > e && IS_HEX(*p); p--);
			if (p == e) {
				rhash_hex_to_byte(e + 1, raw, 8);
				*crc32 = ((unsigned)raw[0] << 24) | ((unsigned)raw[1] << 16) |
					((unsigned)raw[2] << 8) | (unsigned)raw[3];
				return 1;
			}
			e -= 9;
		}
	}
	return 0;
}

/**
 * Rename the given file by inserting its crc32 sum enclosed into square braces
 * and placing it right before the file extension.
 *
 * @param info pointer to the data of the file to rename
 * @return 0 on success, -1 on fail with error code stored in errno
 */
int rename_file_by_embeding_crc32(struct file_info* info)
{
	int res = -1;
	unsigned crc32;
	file_t new_file;
	char suffix[12];
	char* suffix_start = suffix;

	if (FILE_ISSPECIAL(info->file))
		return 0; /* do nothing on stdin or a command-line message */

	assert((info->rctx->hash_mask & RHASH_CRC32) != 0);
	rhash_print(suffix + 2, info->rctx, RHASH_CRC32,
		(opt.flags & OPT_LOWERCASE ? 0 : RHPR_UPPERCASE));

	/* check if filename already contains a CRC32 sum */
	if (find_embedded_crc32(info->file, &crc32)) {
		/* compare with calculated CRC32 */
		if (crc32 == get_crc32(info->rctx))
			return 0;
		/* TRANSLATORS: sample filename with embedded CRC32: file_[A1B2C3D4].mkv */
		log_warning(_("wrong embedded CRC32, should be %s\n"), suffix + 2);
	}
	suffix[1] = '[';
	suffix[10] = ']';
	suffix[11] = 0;
	if (opt.embed_crc_delimiter && *opt.embed_crc_delimiter)
		suffix[0] = *opt.embed_crc_delimiter;
	else
		suffix_start++;

	memset(&new_file, 0, sizeof(new_file));
	if (file_modify_path(&new_file, info->file, suffix_start, FModifyInsertBeforeExtension) < 0 &&
			file_modify_path(&new_file, info->file, suffix_start, FModifyAppendSuffix) < 0) {
		/* impossible situation: AppendSuffix can't fail, so not translating this error */
		log_error_msg_file_t("impossible: failed to rename file: %s\n", info->file);
	} else if (file_rename(info->file, &new_file) < 0) {
		log_error(_("can't move %s to %s: %s\n"),
			file_get_print_path(info->file, FPathPrimaryEncoding | FPathNotNull),
			file_get_print_path(&new_file, FPathPrimaryEncoding | FPathNotNull), strerror(errno));
	} else {
		/* store the new path */
		file_swap(info->file, &new_file);
		res = 0;
	}
	file_cleanup(&new_file);
	return res;
}

/**
 * Save torrent file to the given path.
 * In a case of fail, the error will be logged.
 *
 * @param torrent_file the path to save torrent file to
 * @param rctx the context containing torrent data
 * @return 0 on success, -1 on fail
 */
int save_torrent_to(file_t* torrent_file, struct rhash_context* rctx)
{
	FILE* fd;
	int res = 0;

	const rhash_str* text = rhash_torrent_generate_content(rctx);
	if (!text) {
		errno = ENOMEM;
		log_error_file_t(torrent_file);
		return -1;
	}

	/* make backup copy of the existing torrent file, ignore errors */
	file_move_to_bak(torrent_file);

	/* write the torrent file */
	fd = file_fopen(torrent_file, FOpenWrite | FOpenBin);
	if (fd && text->length == fwrite(text->str, 1, text->length, fd) &&
			!ferror(fd) && fflush(fd) == 0)
	{
		/* TRANSLATORS: printed when a torrent file is saved */
		log_msg_file_t(_("%s saved\n"), torrent_file);
	} else {
		log_error_file_t(torrent_file);
		res = -1;
	}
	if (fd)
		fclose(fd);
	return res;
}

/**
 * Save torrent file.
 * In a case of fail, the error will be logged.
 *
 * @param info information about the hashed file
 * @return 0 on success, -1 on fail
 */
static int save_torrent(struct file_info* info)
{
	int res;
	/* append .torrent extension to the file path */
	file_t torrent_file;
	file_modify_path(&torrent_file, info->file, ".torrent", FModifyAppendSuffix);
	res = file_modify_path(&torrent_file, info->file, ".torrent", FModifyAppendSuffix);
	if (res >= 0)
		res = save_torrent_to(&torrent_file, info->rctx);
	file_cleanup(&torrent_file);
	return res;
}

/**
 * Calculate and print file message digests using printf format.
 * In a case of fail, the error will be logged.
 *
 * @param out the output stream to print results to
 * @param out the name of the output stream
 * @param file the file to calculate sums for
 * @param print_path the path to print
 * @return 0 on success, -1 on input error, -2 on results output error
 */
int calculate_and_print_sums(FILE* out, file_t* out_file, file_t* file)
{
	struct file_info info;
	timedelta_t timer;
	int res = 0;

	/* skip directories */
	if (FILE_ISDIR(file))
		return 0;

	memset(&info, 0, sizeof(info));
	info.file = file;
	info.size = file->size; /* total size, in bytes */
	info.hash_mask = opt.hash_mask;

	/* initialize percents output */
	if (init_percents(&info) < 0) {
		log_error_file_t(&rhash_data.out_file);
		return -2;
	}
	rsh_timer_start(&timer);

	if (info.hash_mask) {
		print_verbose_algorithms(rhash_data.log, info.hash_mask);
		/* calculate sums */
		if (calc_sums(&info) < 0) {
			/* print i/o error */
			log_error_file_t(file);
			res = -1;
		}
		if (rhash_data.stop_flags) {
			report_interrupted();
			return 0;
		}
	}

	info.time = rsh_timer_stop(&timer);
	finish_percents(&info, res);

	if ((opt.flags & OPT_EMBED_CRC) && res == 0) {
		/* rename the file */
		rename_file_by_embeding_crc32(&info);
	}

	if (IS_MODE(MODE_TORRENT) && !opt.bt_batch_file && res == 0) {
		if (save_torrent(&info) < 0)
			res = -2;
	}

	if (IS_MODE(MODE_UPDATE) && rhash_data.is_sfv && res == 0) {
		/* updating SFV file: print SFV header line */
		if (print_sfv_header_line(out, out_file->mode, file) < 0) {
			log_error_file_t(out_file);
			res = -2;
		}
		if (opt.verbose) {
			print_sfv_header_line(rhash_data.log, rhash_data.log_file.mode, file);
			fflush(rhash_data.log);
		}
	}

	if (rhash_data.print_list && res == 0) {
		if (!opt.bt_batch_file) {
			if (print_line(out, out_file->mode, rhash_data.print_list, &info) < 0) {
				log_error_file_t(out_file);
				res = -2;
			}
			/* print the calculated line to stderr/log-file if verbose */
			else if (IS_MODE(MODE_UPDATE) && opt.verbose) {
				print_line(rhash_data.log, rhash_data.log_file.mode, rhash_data.print_list, &info);
			}
		}

		if ((opt.flags & OPT_SPEED) && info.hash_mask) {
			print_file_time_stats(&info);
		}
	}
	return res;
}

/*=========================================================================
 * Benchmark functions
 *=========================================================================*/

/**
 * Calculate message digest of specified hash function(s) for a repeated message chunk.
 *
 * @param hash_ids_count count of hash functions
 * @param hash_ids array hash function identifiers
 * @param message a message chunk to hash
 * @param msg_size message chunk size
 * @param count number of chunks
 * @param out computed hash
 * @return 1 on success, 0 on error
 */
static int benchmark_loop(unsigned hash_ids_count, unsigned hash_ids[],
	const unsigned char* message, size_t msg_size, int count, unsigned char* out)
{
	int i;
	rhash ctx = rhash_init_multi(hash_ids_count, hash_ids);
	if (!ctx)
		return 0;

	/* process the repeated message buffer */
	for (i = 0; i < count && !rhash_data.stop_flags; i++) {
		rhash_update(ctx, message, msg_size);
	}
	rhash_final(ctx, out);
	rhash_free(ctx);
	return 1;
}

#if defined(_MSC_VER)
#define ALIGN_DATA(n) __declspec(align(n))
#elif defined(__GNUC__)
#define ALIGN_DATA(n) __attribute__((aligned (n)))
#else
#define ALIGN_DATA(n) /* do nothing */
#endif

/* define read_tsc() if possible */
#if defined(__i386__) || defined(_M_IX86) || \
	defined(__x86_64__) || defined(_M_AMD64) || defined(_M_X64)

#if defined( _MSC_VER ) /* if MS VC */
# include <intrin.h>
# pragma intrinsic( __rdtsc )
# define read_tsc() __rdtsc()
# define HAVE_TSC
#elif defined( __GNUC__ ) /* if GCC */
static uint64_t read_tsc(void) {
	unsigned long lo, hi;
	__asm volatile("rdtsc" : "=a" (lo), "=d" (hi));
	return (((uint64_t)hi) << 32) + lo;
}
# define HAVE_TSC
#endif /* _MSC_VER, __GNUC__ */
#endif /* x86/amd64 arch */

void run_benchmark(uint64_t hash_mask, unsigned flags)
{
	unsigned char ALIGN_DATA(64) message[8192]; /* 8 KiB */
	timedelta_t timer;
	int i, j;
	size_t sz_mb, msg_size;
	uint64_t time, total_time = 0;
	const int rounds = 4;
	const char* hash_name = "";
	unsigned hash_ids[64];
	unsigned hash_ids_count = 0;
	unsigned char out[130];
#ifdef HAVE_TSC
	double cpb = 0;
#endif /* HAVE_TSC */

#ifdef _WIN32
	set_benchmark_cpu_affinity(); /* set CPU affinity to improve test results */
#endif
	if (!(flags & BENCHMARK_RAW))
		print_verbose_algorithms(rhash_data.out, hash_mask);

	/* set message size for fast and slow hash functions */
	msg_size = 1073741824 / 2;
	if (hash_mask & (RHASH_WHIRLPOOL | RHASH_SNEFRU128 | RHASH_SNEFRU256 | RHASH_SHA3_224 | RHASH_SHA3_256 | RHASH_SHA3_384 | RHASH_SHA3_512)) {
		msg_size /= 8;
	} else if (hash_mask & (RHASH_GOST94 | RHASH_GOST94_CRYPTOPRO | RHASH_SHA384 | RHASH_SHA512)) {
		msg_size /= 2;
	}
	sz_mb = msg_size / (1 << 20); /* size in MiB */

	if (hash_mask && (hash_mask & (hash_mask - 1)) == 0) {
		hash_name = rhash_get_name(bit64_to_hash_id(hash_mask));
		if (!hash_name) hash_name = ""; /* unsupported hash function */
	}
	RSH_REQUIRE(hash_mask_to_hash_ids(hash_mask, 64, hash_ids, &hash_ids_count) >= 0,
		"failed to convert hash ids\n");

	for (i = 0; i < (int)sizeof(message); i++)
		message[i] = i & 0xff;

	for (j = 0; j < rounds && !rhash_data.stop_flags; j++) {
		rsh_timer_start(&timer);
		benchmark_loop(hash_ids_count, hash_ids, message, sizeof(message),
			(int)(msg_size / sizeof(message)), out);

		time = rsh_timer_stop(&timer);
		total_time += time;

		if ((flags & BENCHMARK_RAW) == 0 && !rhash_data.stop_flags) {
			rsh_fprintf(rhash_data.out, "%s %u MiB calculated in %.3f sec, %.3f MBps\n",
				hash_name, (unsigned)sz_mb, (time / 1000.0), (double)sz_mb * 1000.0 / time);
			fflush(rhash_data.out);
		}
	}

#if defined(HAVE_TSC)
	/* measure the CPU "clocks per byte" speed */
	if ((flags & BENCHMARK_CPB) != 0 && !rhash_data.stop_flags) {
		unsigned int c1 = -1, c2 = -1;
		unsigned volatile long long cy0, cy1, cy2;
		int msg_size = 128 * 1024;

		/* make 200 tries */
		for (i = 0; i < 200; i++) {
			cy0 = read_tsc();
			benchmark_loop(hash_ids_count, hash_ids, message, sizeof(message), msg_size / sizeof(message), out);
			cy1 = read_tsc();
			benchmark_loop(hash_ids_count, hash_ids, message, sizeof(message), msg_size / sizeof(message), out);
			benchmark_loop(hash_ids_count, hash_ids, message, sizeof(message), msg_size / sizeof(message), out);
			cy2 = read_tsc();

			cy2 -= cy1;
			cy1 -= cy0;
			c1 = (unsigned int)(c1 > cy1 ? cy1 : c1);
			c2 = (unsigned int)(c2 > cy2 ? cy2 : c2);
		}
		cpb = ((c2 - c1) + 1) / (double)msg_size;
	}
#endif /* HAVE_TSC */

	if (rhash_data.stop_flags) {
		report_interrupted();
		return;
	}

	if (flags & BENCHMARK_RAW) {
		/* output result in a "raw" machine-readable format */
		rsh_fprintf(rhash_data.out, "%s\t%u\t%.3f\t%.3f",
			hash_name, ((unsigned)sz_mb * rounds), total_time / 1000.0, (double)(sz_mb * rounds) * 1000.0 / total_time);
#if defined(HAVE_TSC)
		if (flags & BENCHMARK_CPB) {
			rsh_fprintf(rhash_data.out, "\t%.2f", cpb);
		}
#endif /* HAVE_TSC */
		rsh_fprintf(rhash_data.out, "\n");
	} else {
		rsh_fprintf(rhash_data.out, "%s %u MiB total in %.3f sec, %.3f MBps",
			hash_name, ((unsigned)sz_mb * rounds), total_time / 1000.0, (double)(sz_mb * rounds) * 1000.0 / total_time);
#if defined(HAVE_TSC)
		if (flags & BENCHMARK_CPB) {
			rsh_fprintf(rhash_data.out, ", CPB=%.2f", cpb);
		}
#endif /* HAVE_TSC */
		rsh_fprintf(rhash_data.out, "\n");
	}
}
